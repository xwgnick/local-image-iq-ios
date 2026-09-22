import XCTest
import Photos
import UIKit
import CoreImage
import ImageIO
@testable import LocalImageIQ

final class IndexingImageRequestTests: XCTestCase {
    private let target = CGSize(width: 448, height: 224)

    func testCacheVersionAndSourceContract() {
        XCTAssertEqual(IndexImagePolicy.version, "photokit-preview-v1")
        XCTAssertEqual(IndexImagePolicy.cacheVersion(modelVersion: "model-v2"), "model-v2|photokit-preview-v1")
        XCTAssertEqual(IndexingImage.Source.localPreview.rawValue, "localPreview")
        XCTAssertEqual(IndexingImage.Source.localReducedPreview.rawValue, "localReducedPreview")
        XCTAssertEqual(IndexingImage.Source.networkPreview.rawValue, "networkPreview")
        // Verify conformance without constructing a client or touching the user's library.
        func requireIndexing<T: PhotoLibraryIndexing>(_: T.Type) {}
        requireIndexing(PhotoLibraryClient.self)
    }

    func testTargetPreservesAspectRatioWith224PixelShortEdge() {
        XCTAssertEqual(PreviewImageLoader.targetSize(pixelWidth: 4032, pixelHeight: 3024),
                       CGSize(width: CGFloat(224) * 4 / 3, height: 224))
        XCTAssertEqual(PreviewImageLoader.targetSize(pixelWidth: 3024, pixelHeight: 4032),
                       CGSize(width: 224, height: CGFloat(224) * 4 / 3))
        XCTAssertEqual(PreviewImageLoader.targetSize(pixelWidth: 4000, pixelHeight: 4000),
                       CGSize(width: 224, height: 224))
        XCTAssertEqual(PreviewImageLoader.targetSize(pixelWidth: 40, pixelHeight: 20), target)
        XCTAssertEqual(PreviewImageLoader.targetSize(pixelWidth: 0, pixelHeight: 20),
                       CGSize(width: 224, height: 224))
    }

    func testAllowedNetworkStillRequestsLocalFastPreviewFirstAndAcceptsDegradedOnce() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        let requests = PreviewRequestScript(stages: [[
            .init(image: image, info: [PHImageResultIsDegradedKey: true]),
            .init(image: nil, info: [PHImageErrorKey: photosError(3164)]),
            .init(image: image)
        ]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertEqual(result.source, .localReducedPreview)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(requests.plans.count, 1)
        let plan = try XCTUnwrap(requests.plans.first)
        assertPlan(plan, network: false)
        XCTAssertTrue(requests.cancelledIDs.isEmpty)
    }

    func testSingleDegradedCallbackCompletesWithoutWaitingForBetterPixels() async throws {
        let requests = PreviewRequestScript(stages: [[.init(image: try syntheticImage(),
                                                          info: [PHImageResultIsDegradedKey: true])]])
        let result = try await load(requests)
        XCTAssertEqual(result.source, .localReducedPreview)
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testFullSizeLocalPixelsNeedNoNetworkOrDataAPI() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        let requests = PreviewRequestScript(stages: [[.init(image: image)]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertEqual(result.source, .localPreview)
        XCTAssertTrue(result.cgImage === image.cgImage)
        // The injected surface supplies ONLY requestImage-style previews; there is
        // no original-data provider, and retaining the exact CGImage proves no encode/decode.
        XCTAssertEqual(requests.plans.count, 1)
        XCTAssertFalse(requests.plans[0].options.isNetworkAccessAllowed)
    }

    func testSmallPixelsAreReducedEvenWithoutDegradedFlag() async throws {
        let requests = PreviewRequestScript(stages: [[.init(image: try syntheticImage())]])
        let result = try await load(requests)
        XCTAssertEqual(result.source, .localReducedPreview)
    }

    func testUsableLocalPixelsWinOverCloudFlagAnd3164() async throws {
        let image = try syntheticImage()
        for networkAllowed in [false, true] {
            let requests = PreviewRequestScript(stages: [[.init(image: image, info: [
                PHImageResultIsInCloudKey: true, PHImageErrorKey: photosError(3164)
            ])]])
            let result = try await load(requests, networkAllowed: networkAllowed)
            XCTAssertTrue(result.cgImage === image.cgImage)
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testUsablePixelsWinOverOtherErrorMetadataExceptCancellation() async throws {
        let image = try syntheticImage()
        let requests = PreviewRequestScript(stages: [[.init(image: image, info: [
            PHImageErrorKey: NSError(domain: "SyntheticPhotoError", code: 8)
        ])]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testMissing3164WithoutCloudFlagIsCloudOnlyWhenOffline() async {
        let requests = PreviewRequestScript(stages: [[.init(info: [PHImageErrorKey: photosError(3164)])]])
        do {
            _ = try await load(requests)
            XCTFail("A network-required local resource must be classified as cloud-only.")
        } catch AppFailure.cloudOnly {
            XCTAssertEqual(requests.plans.count, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testNilImageWithCloudFlagWithoutErrorIsCloudOnlyWhenOffline() async {
        let requests = PreviewRequestScript(stages: [[.init(info: [PHImageResultIsInCloudKey: true])]])
        do {
            _ = try await load(requests)
            XCTFail("Expected cloud-only.")
        } catch AppFailure.cloudOnly {
            XCTAssertEqual(requests.plans.count, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testPlainNilAndDegradedNilCompleteAsPhotoErrorsNotCloudOnly() async {
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: true]]
        for info in infos {
            let requests = PreviewRequestScript(stages: [[.init(info: info)]])
            do {
                _ = try await load(requests)
                XCTFail("A nil callback must complete, not wait for a second callback.")
            } catch AppFailure.photo {
                XCTAssertEqual(requests.plans.count, 1)
            } catch { XCTFail("Unknown availability must not be called cloud-only: \(error)") }
        }
    }

    func testMissingLocalResourceFallsBackOnlyWithExplicitNetworkPermission() async throws {
        let localInfos: [[AnyHashable: Any]?] = [
            [PHImageErrorKey: photosError(3164)],
            [PHImageResultIsInCloudKey: true],
            nil,
            [PHImageResultIsDegradedKey: true]
        ]
        for info in localInfos {
            let requests = PreviewRequestScript(stages: [
                [.init(info: info)], [.init(image: try syntheticImage())]
            ])
            let result = try await load(requests, networkAllowed: true)
            XCTAssertEqual(result.source, .networkPreview)
            XCTAssertEqual(requests.plans.count, 2)
            guard requests.plans.count == 2 else { continue }
            assertPlan(requests.plans[0], network: false)
            assertPlan(requests.plans[1], network: true)
            XCTAssertFalse(requests.plans[0].options === requests.plans[1].options)
        }
    }

    func testGenericPermissionAndAuthenticationErrorsArePreservedWithoutFallback() async {
        let errors: [Error] = [
            NSError(domain: "SyntheticPhotoError", code: 8),
            photosError(PHPhotosError.Code.accessUserDenied.rawValue),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired),
            AppFailure.permission,
            NSError(domain: "NotThePhotosDomain", code: 3164)
        ]
        for expected in errors {
            let requests = PreviewRequestScript(stages: [[.init(info: [
                PHImageErrorKey: expected, PHImageResultIsInCloudKey: true
            ])]])
            do {
                _ = try await load(requests, networkAllowed: true)
                XCTFail("Unrelated errors must not cause a network retry.")
            } catch {
                XCTAssertEqual((error as NSError).domain, (expected as NSError).domain)
                XCTAssertEqual((error as NSError).code, (expected as NSError).code)
            }
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testNetworkErrorsIncluding3164AreNotMisclassifiedAsCloudOnlyOrRetried() async {
        for expected in [photosError(3164), NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)] {
            let requests = PreviewRequestScript(stages: [
                [.init(info: [PHImageErrorKey: photosError(3164)])],
                [.init(info: [PHImageErrorKey: expected, PHImageResultIsInCloudKey: true])]
            ])
            do {
                _ = try await load(requests, networkAllowed: true)
                XCTFail("Expected the real network error.")
            } catch {
                XCTAssertEqual((error as NSError).domain, expected.domain)
                XCTAssertEqual((error as NSError).code, expected.code)
            }
            XCTAssertEqual(requests.plans.count, 2)
        }
    }

    func testNetworkNilCompletesWithoutFurtherRetry() async {
        let requests = PreviewRequestScript(stages: [
            [.init()], [.init(info: [PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true])]
        ])
        do {
            _ = try await load(requests, networkAllowed: true)
            XCTFail("Expected no network preview.")
        } catch AppFailure.photo {
            XCTAssertEqual(requests.plans.count, 2)
        } catch { XCTFail("Network nil must not be reported as offline cloud-only: \(error)") }
    }

    func testCancellationMetadataWinsOverUsablePixelsAndNeverFallsBack() async throws {
        let image = try syntheticImage()
        let infos: [[AnyHashable: Any]] = [
            [PHImageCancelledKey: true, PHImageResultIsInCloudKey: true, PHImageErrorKey: photosError(3164)],
            [PHImageErrorKey: CancellationError()],
            [PHImageErrorKey: photosError(PHPhotosError.Code.userCancelled.rawValue)],
            [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)],
            [PHImageErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        ]
        for info in infos {
            let requests = PreviewRequestScript(stages: [[.init(image: image, info: info)]])
            do {
                _ = try await load(requests, networkAllowed: true)
                XCTFail("Cancellation must win over the image.")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testAlreadyCancelledTaskDoesNotStartARequest() async {
        let requests = PreviewRequestScript(stages: [[.init()]])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PreviewImageLoader.load(targetSize: CGSize(width: 224, height: 224), networkAllowed: true,
                request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(requests.plans.isEmpty)
    }

    func testCancellationBeforeRequestIDWithNoCallbackCancelsEventualID() async {
        let requests = PreviewRequestScript(stages: [[]], cancelBeforeID: true)
        let task = previewTask(requests)
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testTaskCancellationRacingSynchronousSuccessWinsBeforeReturn() async throws {
        let requests = PreviewRequestScript(stages: [[.init(image: try syntheticImage())]], cancelBeforeID: true)
        let task = previewTask(requests)
        do { _ = try await task.value; XCTFail("A cancelled task must not return pixels.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testTaskCancellationRacingErrorWinsAndDoesNotStartFallback() async {
        for expected in [photosError(3164), NSError(domain: "SyntheticPhotoError", code: 8)] {
            let requests = PreviewRequestScript(stages: [[.init(info: [PHImageErrorKey: expected])]], cancelBeforeID: true)
            let task = previewTask(requests)
            do { _ = try await task.value; XCTFail("Cancellation must win over a concurrent error.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.cancelledIDs, [1])
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testTaskCancellationAfterRequestStartsIgnoresLateCallback() async throws {
        let started = expectation(description: "Preview requested")
        let pending = PendingPreviewRequest(started: started)
        let task = Task {
            try await PreviewImageLoader.load(targetSize: CGSize(width: 224, height: 224), networkAllowed: true,
                request: { _, _, _, callback in pending.start(callback) }, cancel: { pending.cancel($0) })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        pending.complete(try syntheticImage())
        do { _ = try await task.value; XCTFail("Late pixels must not override task cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(pending.cancelledIDs, [71])
    }

    func testUIImageRightOrientationIsPreservedWithoutRotatingOrReencoding() async throws {
        let image = try syntheticImage(orientation: .right)
        let requests = PreviewRequestScript(stages: [[.init(image: image)]])
        let result = try await load(requests)
        XCTAssertEqual(result.orientation, .right)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(result.cgImage.width, 32)
        XCTAssertEqual(result.cgImage.height, 16)
    }

    func testAllUIImageOrientationsMapToImageIOOrientations() async throws {
        let mappings: [(UIImage.Orientation, CGImagePropertyOrientation)] = [
            (.up, .up), (.upMirrored, .upMirrored), (.down, .down), (.downMirrored, .downMirrored),
            (.left, .left), (.leftMirrored, .leftMirrored), (.right, .right), (.rightMirrored, .rightMirrored)
        ]
        for (input, expected) in mappings {
            let requests = PreviewRequestScript(stages: [[.init(image: try syntheticImage(orientation: input))]])
            let result = try await load(requests)
            XCTAssertEqual(result.orientation, expected)
        }
    }

    func testCIImageBackedPreviewRendersFiniteExtentAndPreservesOrientation() async throws {
        let pixels = try TestFixtures.image(width: 32, height: 16) { _, _ in (19, 71, 203) }
        let ciImage = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(translationX: 9, y: 13))
        let image = UIImage(ciImage: ciImage, scale: 2, orientation: .right)
        XCTAssertNil(image.cgImage)
        let requests = PreviewRequestScript(stages: [[.init(image: image)]])
        let result = try await load(requests)
        XCTAssertEqual(result.cgImage.width, 32)
        XCTAssertEqual(result.cgImage.height, 16)
        XCTAssertEqual(result.orientation, .right)
        var sample = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try sample.withUnsafeMutableBytes { bytes in
            let address = try XCTUnwrap(bytes.baseAddress)
            CIContext().render(CIImage(cgImage: result.cgImage), toBitmap: address, rowBytes: 4,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        }
        for (actual, expected) in zip(sample, [19, 71, 203, 255]) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - expected), 2)
        }
    }

    func testUnreadableUIImageCompletesWithPhotoError() async {
        let requests = PreviewRequestScript(stages: [[.init(image: UIImage())]])
        do { _ = try await load(requests); XCTFail("Expected unreadable preview error.") }
        catch AppFailure.photo { XCTAssertEqual(requests.plans.count, 1) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnreadableLocalUIImageCanUseOnlyTheExplicitNetworkFallback() async throws {
        let requests = PreviewRequestScript(stages: [
            [.init(image: UIImage())], [.init(image: try syntheticImage())]
        ])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertEqual(result.source, .networkPreview)
        XCTAssertEqual(requests.plans.count, 2)
    }

    private func load(_ requests: PreviewRequestScript, networkAllowed: Bool = false) async throws -> IndexingImage {
        try await PreviewImageLoader.load(targetSize: target, networkAllowed: networkAllowed,
            request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) })
    }

    private func previewTask(_ requests: PreviewRequestScript) -> Task<IndexingImage, Error> {
        Task {
            try await PreviewImageLoader.load(targetSize: CGSize(width: 224, height: 224), networkAllowed: true,
                request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) })
        }
    }

    private func syntheticImage(width: Int = 32, height: Int = 16,
                                orientation: UIImage.Orientation = .up) throws -> UIImage {
        UIImage(cgImage: try TestFixtures.image(width: width, height: height) { _, _ in (19, 71, 203) },
                scale: 1, orientation: orientation)
    }

    private func photosError(_ code: Int) -> NSError { NSError(domain: PHPhotosErrorDomain, code: code) }

    private func assertPlan(_ plan: PreviewRequestScript.Plan, network: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.targetSize, target, file: file, line: line)
        XCTAssertEqual(plan.contentMode, .aspectFit, file: file, line: line)
        XCTAssertEqual(plan.options.isNetworkAccessAllowed, network, file: file, line: line)
        XCTAssertEqual(plan.options.deliveryMode, network ? .highQualityFormat : .fastFormat, file: file, line: line)
        XCTAssertEqual(plan.options.version, .current, file: file, line: line)
        XCTAssertEqual(plan.options.resizeMode, .fast, file: file, line: line)
        XCTAssertFalse(plan.options.isSynchronous, file: file, line: line)
    }
}

/// Synchronous callbacks exercise the real continuation-before-request-ID race.
/// Immutable replies contain only synthetic images; mutable recordings are locked.
private final class PreviewRequestScript: @unchecked Sendable {
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
    private let cancelBeforeID: Bool
    private var storedPlans: [Plan] = []
    private var storedCancelledIDs: [PHImageRequestID] = []

    init(stages: [[Reply]], cancelBeforeID: Bool = false) {
        self.stages = stages
        self.cancelBeforeID = cancelBeforeID
    }

    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return storedPlans }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return storedCancelledIDs }

    func request(_ targetSize: CGSize, _ contentMode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping PreviewImageLoader.Callback) -> PHImageRequestID {
        lock.lock()
        let index = storedPlans.count
        storedPlans.append(Plan(targetSize: targetSize, contentMode: contentMode, options: options))
        let replies = index < stages.count ? stages[index]
            : [Reply(info: [PHImageErrorKey: AppFailure.photo("Unexpected extra preview request.")])]
        lock.unlock()
        for reply in replies { callback(reply.image, reply.info) }
        if cancelBeforeID { withUnsafeCurrentTask { $0?.cancel() } }
        return PHImageRequestID(index + 1)
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        storedCancelledIDs.append(id)
    }
}

private final class PendingPreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private var callback: PreviewImageLoader.Callback?
    private var storedCancelledIDs: [PHImageRequestID] = []

    init(started: XCTestExpectation) { self.started = started }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return storedCancelledIDs }

    func start(_ callback: @escaping PreviewImageLoader.Callback) -> PHImageRequestID {
        lock.lock()
        self.callback = callback
        lock.unlock()
        started.fulfill()
        return 71
    }

    func complete(_ image: UIImage) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(image, nil)
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        storedCancelledIDs.append(id)
    }
}