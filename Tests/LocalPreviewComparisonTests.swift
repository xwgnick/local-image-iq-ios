import XCTest
import Foundation
import Photos
import UIKit
import CoreGraphics
import CoreImage
import ImageIO
@testable import LocalImageIQ

/// Request-image callbacks and generated pixels only. Never construct a Photos
/// client, query authorization, load a model, open a database or read an asset.
final class LocalPreviewComparisonTests: XCTestCase {
    private let revision = PhotoRevision(id: "synthetic-comparison", modificationTime: 123, creationTime: 100)
    private let authorization = PHAuthorizationStatus.limited.rawValue

    func testFixedOrderUsesSequentialIndependentLocalOptionsAndPreservesSnapshot() async throws {
        func requireComparison<T: LocalPreviewComparing>(_: T.Type) {}
        requireComparison(PhotoLibraryClient.self) // Conformance only; no client initialization.
        XCTAssertEqual(LocalPreviewMode.allCases, [.fast224, .quality224, .quality480])
        XCTAssertEqual(LocalPreviewMode.allCases.map(\.shortEdge), [224, 224, 480])

        let started = (1...3).map { XCTestExpectation(description: "Request \($0) started") }
        let script = LocalComparisonScript(stages: [[], [], []], onRequest: { number in
            if (1...3).contains(number) { started[number - 1].fulfill() }
        })
        let run = startComparison(script)
        defer { run.stop() }
        for number in 1...3 {
            await fulfillment(of: [started[number - 1]], timeout: 3)
            XCTAssertEqual(script.plans.count, number, "The next request must wait for this callback.")
            XCTAssertNil(run.result.value, "A partial comparison must not be published.")
            script.complete(PHImageRequestID(number), with: [.init()])
        }
        let report = try await finish(run)
        XCTAssertEqual(report.photoID, revision.id)
        XCTAssertEqual(report.revision, revision)
        XCTAssertEqual(report.authorizationRawValue, authorization)
        XCTAssertEqual(report.entries.map(\.mode), [.fast224, .quality224, .quality480])
        let plans = script.plans
        XCTAssertEqual(plans.count, 3)
        guard plans.count == 3, report.entries.count == 3 else { return }
        let sizes = [CGSize(width: CGFloat(224) * 4032 / 3024, height: 224),
                     CGSize(width: CGFloat(224) * 4032 / 3024, height: 224),
                     CGSize(width: 640, height: 480)]
        for index in 0..<3 {
            assertPlan(plans[index], target: sizes[index], delivery: index == 0 ? .fastFormat : .highQualityFormat)
            XCTAssertEqual(report.entries[index].requestedSize, sizes[index])
        }
        XCTAssertFalse(plans[0].options === plans[1].options)
        XCTAssertFalse(plans[0].options === plans[2].options)
        XCTAssertFalse(plans[1].options === plans[2].options)
        XCTAssertTrue(script.cancelledIDs.isEmpty)
        XCTAssertEqual(script.pendingCount, 0)
    }

    func testFast224OptionsMatchTheActualProductionLocalPreviewLoader() async throws {
        let image = try syntheticImage()
        let baseline = LocalComparisonScript(stages: [[.init(image: image)]])
        let target = PreviewImageLoader.targetSize(pixelWidth: 4032, pixelHeight: 3024)
        let baselineRun = begin(baseline) {
            try await PreviewImageLoader.load(targetSize: target, networkAllowed: false,
                request: { baseline.request($0, $1, $2, $3) }, cancel: { baseline.cancel($0) })
        }
        let baselineImage = try await finish(baselineRun)
        let comparison = LocalComparisonScript(stages: Array(repeating: [.init(image: image)], count: 3))
        let report = try await compare(comparison)
        XCTAssertEqual(baseline.plans.count, 1)
        let expected = try XCTUnwrap(baseline.plans.first)
        let actual = try XCTUnwrap(comparison.plans.first)
        assertPlan(expected, target: target, delivery: .fastFormat)
        XCTAssertEqual(actual.targetSize, expected.targetSize)
        XCTAssertEqual(actual.contentMode, expected.contentMode)
        XCTAssertEqual(actual.options.deliveryMode, expected.options.deliveryMode)
        XCTAssertEqual(actual.options.resizeMode, expected.options.resizeMode)
        XCTAssertEqual(actual.options.version, expected.options.version)
        XCTAssertEqual(actual.options.isNetworkAccessAllowed, expected.options.isNetworkAccessAllowed)
        XCTAssertEqual(actual.options.isSynchronous, expected.options.isSynchronous)
        XCTAssertFalse(actual.options === expected.options)
        let preview = try XCTUnwrap(report.entries.first?.preview)
        XCTAssertTrue(preview.cgImage === baselineImage.cgImage)
        XCTAssertEqual(preview.orientation, baselineImage.orientation)
        XCTAssertEqual(preview.source, baselineImage.source)
    }

    func testTargetSizeKeepsFloatingAspectRatioAndInvalidMetadataUsesFiniteFallback() {
        XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: 3024, height: 4032, shortEdge: 224),
                       CGSize(width: 224, height: CGFloat(224) * 4032 / 3024))
        XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: 4032, height: 3024, shortEdge: 480),
                       CGSize(width: 640, height: 480))
        XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: 9, height: 9, shortEdge: 480),
                       CGSize(width: 480, height: 480))
        for (width, height) in [(0, 20), (20, 0), (-1, 20), (20, -1), (0, 0)] {
            XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: width, height: height, shortEdge: 480),
                           CGSize(width: 480, height: 480))
        }
        for edge in [0, -7] {
            XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: 7, height: 3, shortEdge: edge),
                           CGSize(width: CGFloat(224) * 7 / 3, height: 224))
            XCTAssertEqual(LocalPreviewComparisonLoader.targetSize(width: 0, height: 3, shortEdge: edge),
                           CGSize(width: 224, height: 224))
        }
    }

    func testActualCGPixelsOrientationAndUnknownFalseTrueDegradationArePreservedWithoutUpscaling() async throws {
        let image = try syntheticImage(width: 7, height: 3, scale: 3, orientation: .rightMirrored)
        let script = LocalComparisonScript(stages: [
            [.init(image: image)],
            [.init(image: image, info: [PHImageResultIsDegradedKey: false])],
            [.init(image: image, info: [PHImageResultIsDegradedKey: true])]
        ])
        let report = try await compare(script)
        let flags: [Bool?] = [nil, false, true]
        XCTAssertEqual(report.entries.count, 3)
        for (entry, flag) in zip(report.entries, flags) {
            let preview = try XCTUnwrap(entry.preview)
            XCTAssertTrue(preview.cgImage === image.cgImage, "Keep the original pixel object, not a resized or rotated copy.")
            XCTAssertEqual(preview.cgImage.width, 7)
            XCTAssertEqual(preview.cgImage.height, 3)
            XCTAssertEqual(preview.orientation, .rightMirrored)
            XCTAssertEqual(preview.photokitDegraded, flag)
            XCTAssertEqual(preview.requestedSize, entry.requestedSize)
            XCTAssertEqual(preview.source, .localReducedPreview)
            XCTAssertNil(entry.issue)
        }
    }

    func testHighQualityDegradedOneShotCompletesAndSourceDependsOnActualPixels() async throws {
        let image = try syntheticImage(width: 224, height: 224)
        let script = LocalComparisonScript(stages: [
            [.init(image: image)],
            [.init(image: image, info: [PHImageResultIsDegradedKey: true])],
            [.init(image: image, info: [PHImageResultIsDegradedKey: false])]
        ])
        let report = try await compare(script, width: 100, height: 100)
        XCTAssertEqual(script.plans.count, 3, "No second high-quality callback is supplied or needed.")
        XCTAssertEqual(report.entries.map { $0.preview?.source }, [.localPreview, .localReducedPreview, .localReducedPreview])
        XCTAssertEqual(report.entries.map { $0.preview?.photokitDegraded }, [nil, true, false])
        for entry in report.entries {
            let preview = try XCTUnwrap(entry.preview)
            XCTAssertTrue(preview.cgImage === image.cgImage)
            XCTAssertEqual(preview.cgImage.width, 224, "The 480 request must not fabricate 480 pixels.")
            XCTAssertEqual(preview.cgImage.height, 224)
            XCTAssertNil(entry.issue)
        }
    }

    func testNilNilDegradedNilAndUnreadableImageEachCompleteEntryAndContinue() async throws {
        let script = LocalComparisonScript(stages: [
            [.init()], [.init(info: [PHImageResultIsDegradedKey: true])], [.init(image: UIImage())]
        ])
        let report = try await compare(script)
        XCTAssertEqual(script.plans.count, 3)
        XCTAssertEqual(report.entries.count, 3)
        for entry in report.entries {
            XCTAssertNil(entry.preview)
            XCTAssertEqual(entry.issue, LocalPreviewComparisonLoader.issueUnavailable)
        }
    }

    func testGenericErrorsAreSanitizedWithoutLeakingDescriptionsPathsOrIdentifiers() async throws {
        let marker = "SYNTHETIC_SECRET_NOT_AN_ASSET"
        let errors = [
            NSError(domain: "SyntheticDiagnosticFailure", code: 8,
                    userInfo: [NSLocalizedDescriptionKey: marker, NSFilePathErrorKey: "/synthetic/\(marker).jpg"]),
            NSError(domain: "NotThePhotosDomain", code: 3164, userInfo: [NSLocalizedDescriptionKey: marker]),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired,
                    userInfo: [NSLocalizedDescriptionKey: marker])
        ]
        let script = LocalComparisonScript(stages: errors.map { [.init(info: [PHImageErrorKey: $0])] })
        let report = try await compare(script)
        XCTAssertEqual(script.plans.count, 3)
        XCTAssertEqual(report.entries.count, 3)
        for entry in report.entries {
            XCTAssertNil(entry.preview)
            XCTAssertEqual(entry.issue, "PhotoKit could not provide this local preview.")
            XCTAssertFalse((entry.issue ?? "").contains(marker))
            XCTAssertFalse((entry.issue ?? "").contains("/synthetic/"))
        }
    }

    func testCloudFlagAndPhotos3164BecomeLocalNeedsNetworkEntriesWithoutRetry() async throws {
        let networkError = NSError(domain: PHPhotosErrorDomain, code: 3164)
        let script = LocalComparisonScript(stages: [
            [.init(info: [PHImageResultIsInCloudKey: true])],
            [.init(info: [PHImageErrorKey: networkError])],
            [.init(info: [PHImageResultIsInCloudKey: true, PHImageErrorKey: networkError])]
        ])
        let report = try await compare(script)
        XCTAssertEqual(script.plans.count, 3)
        XCTAssertEqual(report.entries.count, 3)
        for entry in report.entries {
            XCTAssertNil(entry.preview)
            XCTAssertEqual(entry.issue, LocalPreviewComparisonLoader.issueNeedsNetwork)
        }
        XCTAssertTrue(script.plans.allSatisfy { !$0.options.isNetworkAccessAllowed })
    }

    func testCloudFlagDoesNotMaskGenericFailureWhileUsablePixelsWinOverBoth() async throws {
        let image = try syntheticImage()
        let generic = NSError(domain: "SyntheticDiagnosticFailure", code: 8)
        let script = LocalComparisonScript(stages: [
            [.init(info: [PHImageResultIsInCloudKey: true, PHImageErrorKey: generic])],
            [.init(image: image, info: [PHImageResultIsInCloudKey: true, PHImageErrorKey: generic])],
            [.init(image: image, info: [PHImageResultIsInCloudKey: true,
                                      PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164)])]
        ])
        let report = try await compare(script)
        XCTAssertEqual(report.entries.count, 3)
        let first = try XCTUnwrap(report.entries.first)
        XCTAssertNil(first.preview)
        // A cloud flag does not turn an unrelated error into a network requirement.
        XCTAssertEqual(first.issue, LocalPreviewComparisonLoader.issueFailed)
        for entry in report.entries.dropFirst() {
            let preview = try XCTUnwrap(entry.preview)
            XCTAssertTrue(preview.cgImage === image.cgImage)
            XCTAssertNil(entry.issue)
        }
        XCTAssertEqual(script.plans.count, 3)
        XCTAssertTrue(script.plans.allSatisfy { !$0.options.isNetworkAccessAllowed })
    }

    func testCallbackCancellationAbortsWholeComparisonEvenWithPixelsAndInvalidSnapshot() async throws {
        let image = try syntheticImage()
        let infos: [[AnyHashable: Any]] = [
            [PHImageCancelledKey: true, PHImageResultIsInCloudKey: true,
             PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164)],
            [PHImageErrorKey: CancellationError()],
            [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue)],
            [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)],
            [PHImageErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        ]
        for info in infos {
            let snapshot = LocalComparisonSnapshot(revision: revision, authorization: authorization)
            let script = LocalComparisonScript(stages: [
                [.init(image: image)], [.init(image: image, info: info)], [.init(image: image)]
            ], onRequest: { number in
                if number == 2 { snapshot.changeRevision() }
            })
            do {
                _ = try await compare(script, validate: { snapshot.isCurrent })
                XCTFail("Cancellation must discard the completed first preview, not publish a partial report.")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.plans.count, 2, "Cancellation must not start high-quality 480.")
        }
    }

    func testTaskCancellationOfHeldSecondRequestIgnoresLateSuccessAndStartsNoLaterRequest() async throws {
        let image = try syntheticImage()
        let started = XCTestExpectation(description: "Second request is held")
        let script = LocalComparisonScript(stages: [[.init(image: image)], [], [.init(image: image)]],
                                           onRequest: { if $0 == 2 { started.fulfill() } })
        let run = startComparison(script)
        defer { run.stop() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(script.plans.count, 2)
        XCTAssertNil(run.result.value)
        run.task.cancel()
        script.complete(2, with: [.init(image: image), .init()])
        do { _ = try await finish(run); XCTFail("Late success must not publish a cancelled comparison.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(script.plans.count, 2)
        XCTAssertEqual(script.cancelledIDs, [2])
        XCTAssertEqual(script.pendingCount, 0)
    }

    func testCancellationBeforeRequestIDCancelsEventualIDWithNoCallbackOrRacingSuccess() async throws {
        let image = try syntheticImage()
        let secondReplies: [[LocalComparisonScript.Reply]] = [[], [.init(image: image)]]
        for replies in secondReplies {
            let script = LocalComparisonScript(stages: [[.init(image: image)], replies, [.init(image: image)]],
                                               cancelBeforeIDAt: 2)
            do { _ = try await compare(script); XCTFail("Pre-ID task cancellation must abort the whole comparison.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.cancelledIDs, [2])
            XCTAssertEqual(script.plans.count, 2)
            XCTAssertEqual(script.pendingCount, 0, "Cleanup must release callbacks even when none was delivered.")
        }
    }

    func testAlreadyCancelledTaskStartsNoRequests() async {
        let script = LocalComparisonScript(stages: [[.init()], [.init()], [.init()]])
        let revision = self.revision
        let authorization = self.authorization
        let run = begin(script) {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalPreviewComparisonLoader.compare(
                id: revision.id, revision: revision, authorizationRawValue: authorization,
                pixelWidth: 7, pixelHeight: 3,
                request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) }, validate: { true })
        }
        do { _ = try await finish(run); XCTFail("Expected cancellation before the first request.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(script.plans.isEmpty)
        XCTAssertTrue(script.cancelledIDs.isEmpty)
    }

    func testDuplicateCallbacksKeepFirstPixelsMetadataAndMissingEntry() async throws {
        let first = try syntheticImage(width: 7, height: 3, orientation: .left)
        let later = try syntheticImage(width: 11, height: 5, orientation: .down)
        let script = LocalComparisonScript(stages: [
            [.init(image: first, info: [PHImageResultIsDegradedKey: false]),
             .init(image: later, info: [PHImageResultIsDegradedKey: true]),
             .init(info: [PHImageErrorKey: AppFailure.permission])],
            [.init(), .init(image: later), .init(info: [PHImageResultIsInCloudKey: true])],
            [.init(image: first, info: [PHImageResultIsDegradedKey: true]),
             .init(info: [PHImageCancelledKey: true]), .init(image: later)]
        ])
        let report = try await compare(script)
        XCTAssertEqual(report.entries.count, 3)
        guard report.entries.count == 3 else { return }
        let fast = try XCTUnwrap(report.entries[0].preview)
        XCTAssertTrue(fast.cgImage === first.cgImage)
        XCTAssertEqual(fast.orientation, .left)
        XCTAssertEqual(fast.photokitDegraded, false)
        XCTAssertNil(report.entries[0].issue)
        XCTAssertNil(report.entries[1].preview)
        XCTAssertEqual(report.entries[1].issue, LocalPreviewComparisonLoader.issueUnavailable)
        let high = try XCTUnwrap(report.entries[2].preview)
        XCTAssertTrue(high.cgImage === first.cgImage)
        XCTAssertEqual(high.orientation, .left)
        XCTAssertEqual(high.photokitDegraded, true)
        XCTAssertNil(report.entries[2].issue)
        XCTAssertEqual(script.plans.count, 3)
    }

    func testRevisionOrAuthorizationChangeWhileAwaitingPreviewAbortsWithoutPublishingPartialReport() async throws {
        let image = try syntheticImage()
        for changeAuthorization in [false, true] {
            let snapshot = LocalComparisonSnapshot(revision: revision, authorization: authorization)
            let started = XCTestExpectation(description: "First preview completed; second is held")
            let script = LocalComparisonScript(stages: [[.init(image: image)], [], [.init(image: image)]],
                                               onRequest: { if $0 == 2 { started.fulfill() } })
            let run = startComparison(script, validate: { snapshot.isCurrent })
            defer { run.stop() }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertEqual(script.plans.count, 2)
            XCTAssertNil(run.result.value)
            if changeAuthorization { snapshot.changeAuthorization() }
            else { snapshot.changeRevision() }
            XCTAssertFalse(snapshot.isCurrent)
            script.complete(2, with: [.init(image: image)])
            var published: LocalPreviewComparison?
            do { published = try await finish(run); XCTFail("An invalid snapshot must throw, not return entries.") }
            catch AppFailure.photo { }
            catch { XCTFail("Expected snapshot invalidation, not \(error).") }
            XCTAssertNil(published)
            XCTAssertEqual(script.plans.count, 2)
            XCTAssertEqual(script.pendingCount, 0)
        }
    }

    func testPermissionFailureAbortsEvenWithUsablePixelsAndCloudMetadata() async throws {
        let image = try syntheticImage()
        let errors: [Error] = [AppFailure.permission,
            NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue),
            NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessRestricted.rawValue)]
        for error in errors {
            let script = LocalComparisonScript(stages: [
                [.init(image: image)],
                [.init(image: image, info: [PHImageErrorKey: error, PHImageResultIsInCloudKey: true])],
                [.init(image: image)]
            ])
            do { _ = try await compare(script); XCTFail("Permission errors must abort instead of becoming diagnostic entries.") }
            catch AppFailure.permission { }
            catch { XCTFail("Expected permission failure, not \(error).") }
            XCTAssertEqual(script.plans.count, 2)
        }
    }

    func testEveryUIImageOrientationMapsWithoutRotatingCGPixels() async throws {
        let mappings: [(UIImage.Orientation, CGImagePropertyOrientation)] = [
            (.up, .up), (.upMirrored, .upMirrored), (.down, .down), (.downMirrored, .downMirrored),
            (.left, .left), (.leftMirrored, .leftMirrored), (.right, .right), (.rightMirrored, .rightMirrored)
        ]
        for (input, expected) in mappings {
            let image = try syntheticImage(width: 7, height: 3, scale: 2, orientation: input)
            let script = LocalComparisonScript(stages: Array(repeating: [.init(image: image)], count: 3))
            let report = try await compare(script)
            XCTAssertEqual(report.entries.count, 3)
            for entry in report.entries {
                let preview = try XCTUnwrap(entry.preview)
                XCTAssertEqual(preview.orientation, expected)
                XCTAssertTrue(preview.cgImage === image.cgImage)
                XCTAssertEqual(preview.cgImage.width, 7)
                XCTAssertEqual(preview.cgImage.height, 3)
            }
        }
    }

    func testFiniteCIImageConvertsActualExtentAndColorWithoutUpscalingOrBakingOrientation() async throws {
        let pixels = try TestFixtures.image(width: 7, height: 3) { _, _ in (19, 71, 203) }
        let ciImage = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(translationX: 9, y: 13))
        let image = UIImage(ciImage: ciImage, scale: 2, orientation: .right)
        XCTAssertNil(image.cgImage)
        let script = LocalComparisonScript(stages: Array(repeating: [.init(image: image)], count: 3))
        let report = try await compare(script)
        let context = CIContext()
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertEqual(report.entries.count, 3)
        for entry in report.entries {
            let preview = try XCTUnwrap(entry.preview)
            XCTAssertEqual(preview.cgImage.width, 7)
            XCTAssertEqual(preview.cgImage.height, 3)
            XCTAssertEqual(preview.orientation, .right)
            XCTAssertNil(preview.photokitDegraded)
            XCTAssertEqual(preview.source, .localReducedPreview)
            XCTAssertNil(entry.issue)
            var sample = [UInt8](repeating: 0, count: 4)
            try sample.withUnsafeMutableBytes { bytes in
                let address = try XCTUnwrap(bytes.baseAddress)
                context.render(CIImage(cgImage: preview.cgImage), toBitmap: address, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
            }
            for (actual, expected) in zip(sample, [19, 71, 203, 255]) {
                XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 2)
            }
        }
    }

    private func syntheticImage(width: Int = 7, height: Int = 3, scale: CGFloat = 1,
                                orientation: UIImage.Orientation = .up) throws -> UIImage {
        let pixels = try TestFixtures.image(width: width, height: height) { x, y in
            (UInt8((x * 19) % 256), UInt8((y * 71) % 256), 203)
        }
        return UIImage(cgImage: pixels, scale: scale, orientation: orientation)
    }

    private func assertPlan(_ plan: LocalComparisonScript.Plan, target: CGSize,
                            delivery: PHImageRequestOptionsDeliveryMode,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.targetSize, target, file: file, line: line)
        XCTAssertEqual(plan.contentMode, .aspectFit, file: file, line: line)
        XCTAssertEqual(plan.options.deliveryMode, delivery, file: file, line: line)
        XCTAssertEqual(plan.options.resizeMode, .fast, file: file, line: line)
        XCTAssertEqual(plan.options.version, .current, file: file, line: line)
        XCTAssertFalse(plan.options.isNetworkAccessAllowed, file: file, line: line)
        XCTAssertFalse(plan.options.isSynchronous, file: file, line: line)
    }

    private func compare(_ script: LocalComparisonScript, width: Int = 4032, height: Int = 3024,
                         validate: @escaping @Sendable () -> Bool = { true }) async throws -> LocalPreviewComparison {
        try await finish(startComparison(script, width: width, height: height, validate: validate))
    }

    private func startComparison(_ script: LocalComparisonScript, width: Int = 4032, height: Int = 3024,
                                 validate: @escaping @Sendable () -> Bool = { true }) -> LocalComparisonRun<LocalPreviewComparison> {
        let revision = self.revision
        let authorization = self.authorization
        return begin(script) {
            try await LocalPreviewComparisonLoader.compare(
                id: revision.id, revision: revision, authorizationRawValue: authorization,
                pixelWidth: width, pixelHeight: height,
                request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) }, validate: validate)
        }
    }

    private func begin<Value: Sendable>(_ script: LocalComparisonScript,
                                        operation: @escaping @Sendable () async throws -> Value) -> LocalComparisonRun<Value> {
        let finished = XCTestExpectation(description: "Synthetic preview operation completed")
        let result = LocalComparisonResult<Value>()
        let task = Task {
            do { result.store(.success(try await operation())) }
            catch { result.store(.failure(error)) }
            finished.fulfill()
        }
        let run = LocalComparisonRun(task: task, finished: finished, result: result, script: script)
        addTeardownBlock { run.stop() }
        return run
    }

    private func finish<Value: Sendable>(_ run: LocalComparisonRun<Value>) async throws -> Value {
        defer { run.stop() }
        // XCTest-only deadline. Never await task.value after a timeout: a broken
        // one-shot policy must fail this test rather than hang the test process.
        await fulfillment(of: [run.finished], timeout: 3)
        return try XCTUnwrap(run.result.value, "The callback policy did not complete within the XCTest deadline.").get()
    }
}

/// All mutable script state is locked. Empty stages hold callbacks for explicit
/// release; callbacks are always invoked outside the lock, including teardown.
private final class LocalComparisonScript: @unchecked Sendable {
    struct Reply {
        var image: UIImage? = nil
        var info: [AnyHashable: Any]? = nil
    }
    struct Plan {
        let targetSize: CGSize
        let contentMode: PHImageContentMode
        let options: PHImageRequestOptions
    }
    private let lock = NSLock()
    private let stages: [[Reply]]
    private let cancelBeforeIDAt: Int?
    private let onRequest: @Sendable (Int) -> Void
    private var storedPlans: [Plan] = []
    private var storedCancelledIDs: [PHImageRequestID] = []
    private var held: [PHImageRequestID: PreviewImageLoader.Callback] = [:]
    private var closed = false

    init(stages: [[Reply]], cancelBeforeIDAt: Int? = nil, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.stages = stages
        self.cancelBeforeIDAt = cancelBeforeIDAt
        self.onRequest = onRequest
    }

    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return storedPlans }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return storedCancelledIDs }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    func request(_ target: CGSize, _ mode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping PreviewImageLoader.Callback) -> PHImageRequestID {
        lock.lock()
        let index = storedPlans.count
        let id = PHImageRequestID(index + 1)
        storedPlans.append(Plan(targetSize: target, contentMode: mode, options: options))
        let replies = !closed && index < stages.count ? stages[index] : [Reply(info: [PHImageCancelledKey: true])]
        if replies.isEmpty { held[id] = callback }
        lock.unlock()
        onRequest(index + 1)
        for reply in replies { callback(reply.image, reply.info) }
        if cancelBeforeIDAt == index + 1 { withUnsafeCurrentTask { $0?.cancel() } }
        return id
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        storedCancelledIDs.append(id)
        // Deliberately keep a held callback to exercise late PhotoKit delivery.
    }

    func complete(_ id: PHImageRequestID, with replies: [Reply]) {
        lock.lock()
        let callback = held.removeValue(forKey: id)
        lock.unlock()
        for reply in replies { callback?(reply.image, reply.info) }
    }

    func releaseHeldCallbacks() {
        lock.lock()
        closed = true
        let callbacks = Array(held.values)
        held.removeAll()
        lock.unlock()
        for callback in callbacks { callback(nil, [PHImageCancelledKey: true]) }
    }
}

/// Matches the extension's revision + raw-authorization validation seam without
/// calling PhotoKit. A limited-to-authorized transition is still invalidation.
private final class LocalComparisonSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let expectedRevision: PhotoRevision
    private let expectedAuthorization: Int
    private var revision: PhotoRevision
    private var authorization: Int

    init(revision: PhotoRevision, authorization: Int) {
        expectedRevision = revision
        expectedAuthorization = authorization
        self.revision = revision
        self.authorization = authorization
    }

    var isCurrent: Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == expectedRevision && authorization == expectedAuthorization
    }

    func changeRevision() {
        lock.lock(); defer { lock.unlock() }
        revision = PhotoRevision(id: revision.id, modificationTime: revision.modificationTime + 1,
                                 creationTime: revision.creationTime)
    }

    func changeAuthorization() {
        lock.lock(); defer { lock.unlock() }
        authorization = PHAuthorizationStatus.authorized.rawValue
    }
}

private final class LocalComparisonResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
    func store(_ result: Result<Value, Error>) { lock.lock(); defer { lock.unlock() }; stored = result }
}

/// Task cancellation and XCTestExpectation fulfillment are thread-safe; the
/// result and callback store have their own locks. Cleanup is idempotent.
private struct LocalComparisonRun<Value: Sendable>: @unchecked Sendable {
    let task: Task<Void, Never>
    let finished: XCTestExpectation
    let result: LocalComparisonResult<Value>
    let script: LocalComparisonScript

    func stop() {
        task.cancel()
        script.releaseHeldCallbacks()
    }
}