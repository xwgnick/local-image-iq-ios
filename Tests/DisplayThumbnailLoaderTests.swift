import XCTest
import Photos
import UIKit
import CoreImage
@testable import LocalImageIQ

final class DisplayThumbnailLoaderTests: XCTestCase {
    private let target = CGSize(width: 521, height: 651)

    func testPointSizeUsesTwoAndThreeTimesDisplayScale() {
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 120, height: 150), displayScale: 2),
                       CGSize(width: 240, height: 300))
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 120, height: 150), displayScale: 3),
                       CGSize(width: 360, height: 450))
    }

    func testFractionalTileRoundsEachPixelDimensionUp() {
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 173.5, height: 216.875), displayScale: 3),
                       target)
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 173.5, height: 216.875), displayScale: 2),
                       CGSize(width: 347, height: 434))
    }

    func testLandscapeTargetRemainsNonSquare() {
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 216.875, height: 173.5), displayScale: 3),
                       CGSize(width: 651, height: 521))
    }

    func testPositiveSubpixelGeometryRequestsAtLeastOnePixel() {
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 0.01, height: 0.4), displayScale: 2),
                       CGSize(width: 1, height: 1))
    }

    func testInvalidPointDimensionsReturnNil() {
        let invalidValues: [CGFloat] = [0, -1, .nan, .infinity, -.infinity]
        for invalid in invalidValues {
            XCTAssertNil(DisplayThumbnailLoader.targetSize(points: CGSize(width: invalid, height: 100), displayScale: 3))
            XCTAssertNil(DisplayThumbnailLoader.targetSize(points: CGSize(width: 100, height: invalid), displayScale: 3))
        }
    }

    func testInvalidScaleAndMultiplicationOverflowReturnNil() {
        let invalidValues: [CGFloat] = [0, -1, .nan, .infinity, -.infinity]
        for invalid in invalidValues {
            XCTAssertNil(DisplayThumbnailLoader.targetSize(points: CGSize(width: 100, height: 80), displayScale: invalid))
        }
        XCTAssertNil(DisplayThumbnailLoader.targetSize(points: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1),
                                                       displayScale: 2))
        XCTAssertNil(DisplayThumbnailLoader.targetSize(points: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude),
                                                       displayScale: 2))
    }

    func testValidGeometryHasNoArbitraryPixelCeiling() {
        XCTAssertEqual(DisplayThumbnailLoader.targetSize(points: CGSize(width: 9000, height: 6000), displayScale: 3),
                       CGSize(width: 27000, height: 18000))
    }

    func testLocalHQSuccessSkipsFastAndNetworkEvenWhenOptedIn() async throws {
        let image = try syntheticImage(width: 521, height: 651, scale: 3, orientation: .right)
        for allowed in [false, true] {
            let script = ThumbnailRequestScript(stages: [[.init(image: image)]])
            let result = try await load(script, networkAllowed: allowed)
            XCTAssertTrue(result === image)
            XCTAssertTrue(result.cgImage === image.cgImage)
            XCTAssertEqual(result.scale, 3)
            XCTAssertEqual(result.imageOrientation, .right)
            assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
            XCTAssertTrue(script.cancelledIDs.isEmpty)
        }
    }

    func testSingleDegradedLocalHQCallbackCompletesWithoutWaiting() async throws {
        let image = try syntheticImage()
        for allowed in [false, true] {
            let script = ThumbnailRequestScript(stages: [[.init(image: image, info: [PHImageResultIsDegradedKey: true])]])
            let result = try await load(script, networkAllowed: allowed)
            XCTAssertTrue(result === image)
            assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
        }
    }

    func testUndersizedLocalHQWithoutDegradedFlagIsStillLocalSuccess() async throws {
        let image = try syntheticImage(width: 32, height: 16)
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: false]]
        for info in infos {
            let script = ThumbnailRequestScript(stages: [[.init(image: image, info: info)]])
            let result = try await load(script, networkAllowed: true)
            XCTAssertTrue(result === image)
            XCTAssertEqual(result.cgImage?.width, 32)
            XCTAssertEqual(result.cgImage?.height, 16)
            assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
        }
    }

    func testReadablePixelsWinOverCloudFlagAndResourceErrorAtEveryStage() async throws {
        let image = try syntheticImage()
        let infos: [[AnyHashable: Any]] = [
            [PHImageResultIsInCloudKey: true],
            [PHImageErrorKey: photosError(3164)],
            [PHImageErrorKey: photosError(3164), PHImageResultIsInCloudKey: true]
        ]
        for path in stagePaths {
            for info in infos {
                let script = makeScript(path, reply: .init(image: image, info: info))
                let result = try await load(script, networkAllowed: path.networkAllowed)
                XCTAssertTrue(result === image)
                assertPlans(script, path: path)
            }
        }
    }

    func testOnlyMissingOrUnreadableLocalHQFallsBackToOfflineFast() async throws {
        let image = try syntheticImage()
        for missing in missingReplies() {
            let script = ThumbnailRequestScript(stages: [[missing], [.init(image: image)]])
            let result = try await load(script)
            XCTAssertTrue(result === image)
            assertPlans(script, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        }
    }

    func testOfflineFastAcceptsSingleDegradedCallbackAfterHQMiss() async throws {
        let image = try syntheticImage()
        let script = ThumbnailRequestScript(stages: [[.init()], [
            .init(image: image, info: [PHImageResultIsDegradedKey: true, PHImageErrorKey: photosError(3164)])
        ]])
        let result = try await load(script)
        XCTAssertTrue(result === image)
        assertPlans(script, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
    }

    func testOptInTriesNetworkHQBeforeFastCanMaskQualityUpgrade() async throws {
        let image = try syntheticImage(width: 521, height: 651)
        for missing in missingReplies() {
            let script = ThumbnailRequestScript(stages: [[missing], [.init(image: image)]])
            let result = try await load(script, networkAllowed: true)
            XCTAssertTrue(result === image)
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        }
    }

    func testNetworkHQIgnoresProvisionalCallbacksUntilFinalImage() async throws {
        let reduced = try syntheticImage()
        let final = try syntheticImage(width: 521, height: 651)
        let script = ThumbnailRequestScript(stages: [[.init()], [
            .init(info: [PHImageResultIsDegradedKey: true]),
            .init(image: reduced, info: [PHImageResultIsDegradedKey: true]),
            .init(image: reduced, info: [PHImageResultIsDegradedKey: true, PHImageErrorKey: photosError(3164)]),
            .init(image: final, info: [PHImageResultIsDegradedKey: false])
        ]])
        let result = try await load(script, networkAllowed: true)
        XCTAssertTrue(result === final)
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
    }

    func testNetworkHQMissingResourceFallsBackToOfflineFast() async throws {
        let image = try syntheticImage()
        // A network nil+degraded callback is provisional, not a final miss.
        for missing in missingReplies().filter({ !PhotoImageRequestInfo.flag(PHImageResultIsDegradedKey, $0.info) }) {
            let script = ThumbnailRequestScript(stages: [[.init()], [missing], [.init(image: image)]])
            let result = try await load(script, networkAllowed: true)
            XCTAssertTrue(result === image)
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, true, false])
        }
    }

    func testMissingNetworkImageWith3164IsTerminalEvenWhenMarkedDegraded() async throws {
        let image = try syntheticImage()
        let script = ThumbnailRequestScript(stages: [[.init()], [
            .init(info: [PHImageErrorKey: photosError(3164), PHImageResultIsDegradedKey: true])
        ], [.init(image: image)]])
        let result = try await load(script, networkAllowed: true)
        XCTAssertTrue(result === image)
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, true, false])
    }

    func testExhaustedPlainMissesArePhotoErrorsNotInventedCloudErrors() async {
        for allowed in [false, true] {
            let stages: [[ThumbnailRequestScript.Reply]] = allowed ? [[.init()], [.init()], [.init()]] : [[.init()], [.init()]]
            let script = ThumbnailRequestScript(stages: stages)
            do { _ = try await load(script, networkAllowed: allowed); XCTFail("Expected missing preview.") }
            catch AppFailure.photo { }
            catch { XCTFail("Unexpected error: \(error)") }
            assertPlans(script, path: allowed ? stagePaths[3] : stagePaths[2])
        }
    }

    func testAnyMissingStageRequiringNetworkPreservesCloudOnlyClassification() async {
        let infos: [[AnyHashable: Any]] = [[PHImageErrorKey: photosError(3164)], [PHImageResultIsInCloudKey: true]]
        for allowed in [false, true] {
            let count = allowed ? 3 : 2
            for index in 0..<count {
                for info in infos {
                    var stages = Array(repeating: [ThumbnailRequestScript.Reply()], count: count)
                    stages[index] = [.init(info: info)]
                    let script = ThumbnailRequestScript(stages: stages)
                    do { _ = try await load(script, networkAllowed: allowed); XCTFail("Expected cloud-only after all misses.") }
                    catch AppFailure.cloudOnly { }
                    catch { XCTFail("Unexpected error: \(error)") }
                    assertPlans(script, path: allowed ? stagePaths[3] : stagePaths[2])
                }
            }
        }
    }

    func testGenericErrorsBeatPixelsCloudAndDegradedMetadataWithoutFallback() async throws {
        let images: [UIImage?] = [nil, UIImage(), try syntheticImage()]
        let errors = [NSError(domain: "SyntheticThumbnailError", code: 8),
                      NSError(domain: "NotThePhotosDomain", code: 3164),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)]
        for path in stagePaths {
            for image in images {
                for expected in errors {
                    let script = makeScript(path, reply: .init(image: image, info: [
                        PHImageErrorKey: expected, PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true
                    ]))
                    do { _ = try await load(script, networkAllowed: path.networkAllowed); XCTFail("Ordinary errors must propagate.") }
                    catch {
                        XCTAssertEqual((error as NSError).domain, expected.domain)
                        XCTAssertEqual((error as NSError).code, expected.code)
                    }
                    assertPlans(script, path: path)
                }
            }
        }
    }

    func testPermissionFailuresBeatPixelsAndNeverFallBackAtAnyStage() async throws {
        let images: [UIImage?] = [nil, try syntheticImage()]
        let errors: [Error] = [AppFailure.permission,
            photosError(PHPhotosError.Code.accessUserDenied.rawValue),
            photosError(PHPhotosError.Code.accessRestricted.rawValue)]
        for path in stagePaths {
            for image in images {
                for expected in errors {
                    let script = makeScript(path, reply: .init(image: image, info: [
                        PHImageErrorKey: expected, PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true
                    ]))
                    do { _ = try await load(script, networkAllowed: path.networkAllowed); XCTFail("Expected permission failure.") }
                    catch AppFailure.permission { }
                    catch { XCTFail("Unexpected error: \(error)") }
                    assertPlans(script, path: path)
                }
            }
        }
    }

    func testCancellationMetadataBeatsPixelsErrorsAndDegradationAtEveryStage() async throws {
        let images: [UIImage?] = [nil, try syntheticImage()]
        let infos: [[AnyHashable: Any]] = [
            [PHImageCancelledKey: true, PHImageErrorKey: photosError(3164)],
            [PHImageCancelledKey: true, PHImageErrorKey: AppFailure.permission],
            [PHImageErrorKey: CancellationError()],
            [PHImageErrorKey: photosError(PHPhotosError.Code.userCancelled.rawValue)],
            [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)],
            [PHImageErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        ]
        for path in stagePaths {
            for image in images {
                for var info in infos {
                    info[PHImageResultIsInCloudKey] = true
                    info[PHImageResultIsDegradedKey] = true
                    let script = makeScript(path, reply: .init(image: image, info: info))
                    do { _ = try await load(script, networkAllowed: path.networkAllowed); XCTFail("Expected cancellation.") }
                    catch { XCTAssertTrue(error is CancellationError) }
                    assertPlans(script, path: path)
                }
            }
        }
    }

    func testFiniteCIBackedImageRendersPixelsAndPreservesScaleAndOrientation() async throws {
        let original = try syntheticImage()
        let pixels = try XCTUnwrap(original.cgImage)
        let ciImage = CIImage(cgImage: pixels).transformed(by: CGAffineTransform(translationX: 9, y: 13))
        let image = UIImage(ciImage: ciImage, scale: 2, orientation: .leftMirrored)
        XCTAssertNil(image.cgImage)
        let script = ThumbnailRequestScript(stages: [[.init(image: image)]])
        let result = try await load(script)
        XCTAssertEqual(result.cgImage?.width, 32)
        XCTAssertEqual(result.cgImage?.height, 16)
        XCTAssertEqual(result.scale, 2)
        XCTAssertEqual(result.imageOrientation, .leftMirrored)
        assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
    }

    func testFirstTerminalCallbackWinsOverSynchronousDuplicatesAtEveryStage() async throws {
        let first = try syntheticImage()
        let later = try syntheticImage(width: 521, height: 651)
        for path in stagePaths {
            let replies: [ThumbnailRequestScript.Reply] = [ThumbnailRequestScript.Reply(image: first)]
                + lateReplies(image: later)
            let stages: [[ThumbnailRequestScript.Reply]] = path.prefix + [replies]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await load(script, networkAllowed: path.networkAllowed)
            XCTAssertTrue(result === first)
            assertPlans(script, path: path)
            XCTAssertTrue(script.cancelledIDs.isEmpty)
        }
    }

    func testAlreadyCancelledTaskStartsNoRequests() async {
        let script = ThumbnailRequestScript(stages: [])
        let task = start(script, cancelledAtStart: true)
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(script.plans.isEmpty)
        XCTAssertTrue(script.cancelledIDs.isEmpty)
    }

    func testCancellationBeforeIDWithNoCallbackCancelsOnlyEventualActiveID() async {
        for path in stagePaths {
            let id = path.deliveries.count
            let script = ThumbnailRequestScript(stages: path.prefix + [[]], cancelBeforeIDAt: id)
            let task = start(script, networkAllowed: path.networkAllowed)
            do { _ = try await task.value; XCTFail("Expected cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.cancelledIDs, [PHImageRequestID(id)])
            assertPlans(script, path: path)
        }
    }

    func testTaskCancellationRacingSynchronousImageBeforeIDWinsAtEveryStage() async throws {
        let image = try syntheticImage()
        for path in stagePaths {
            let id = path.deliveries.count
            let script = ThumbnailRequestScript(stages: path.prefix + [[.init(image: image)]], cancelBeforeIDAt: id)
            let task = start(script, networkAllowed: path.networkAllowed)
            do { _ = try await task.value; XCTFail("Task cancellation must beat synchronous success.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.cancelledIDs, [PHImageRequestID(id)])
            assertPlans(script, path: path)
        }
    }

    func testTaskCancellationRacingMissingOrFatalErrorStartsNoFallback() async {
        let replies: [ThumbnailRequestScript.Reply] = [
            .init(), .init(info: [PHImageErrorKey: photosError(3164)]),
            .init(info: [PHImageErrorKey: NSError(domain: "SyntheticThumbnailError", code: 8)])
        ]
        for path in stagePaths {
            for reply in replies {
                let id = path.deliveries.count
                let script = ThumbnailRequestScript(stages: path.prefix + [[reply]], cancelBeforeIDAt: id)
                let task = start(script, networkAllowed: path.networkAllowed)
                do { _ = try await task.value; XCTFail("Expected cancellation, not fallback.") }
                catch { XCTAssertTrue(error is CancellationError) }
                XCTAssertEqual(script.cancelledIDs, [PHImageRequestID(id)])
                assertPlans(script, path: path)
            }
        }
    }

    func testPendingRequestCancellationIgnoresLateCallbacksAtEveryStage() async throws {
        let image = try syntheticImage()
        for path in stagePaths {
            let id = path.deliveries.count
            let script = ThumbnailRequestScript(stages: path.prefix + [[]])
            let task = start(script, networkAllowed: path.networkAllowed)
            defer { task.cancel() }
            await script.waitForRequest(id)
            task.cancel()
            for number in 1...id {
                XCTAssertTrue(script.complete(PHImageRequestID(number), with: lateReplies(image: image)))
            }
            do { _ = try await task.value; XCTFail("Late callbacks cannot undo cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.cancelledIDs, [PHImageRequestID(id)])
            assertPlans(script, path: path)
        }
    }

    func testNetworkOnlyProvisionalResultCanBeCancelledWithoutFinalCallback() async throws {
        let reduced = try syntheticImage()
        let script = ThumbnailRequestScript(stages: [[.init()], []])
        let task = start(script, networkAllowed: true)
        defer { task.cancel() }
        await script.waitForRequest(2)
        XCTAssertTrue(script.complete(2, with: [.init(image: reduced, info: [PHImageResultIsDegradedKey: true])]))
        task.cancel()
        do { _ = try await task.value; XCTFail("A provisional image must not complete network HQ.") }
        catch { XCTAssertTrue(error is CancellationError) }
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        XCTAssertEqual(script.cancelledIDs, [2])
    }

    func testLateLocalHQCallbacksCannotReplaceOrAbortPendingFastFallback() async throws {
        let stale = try syntheticImage()
        let fast = try syntheticImage(width: 64, height: 48)
        for late in lateReplies(image: stale) {
            let script = ThumbnailRequestScript(stages: [[.init()], []])
            let task = start(script)
            defer { task.cancel() }
            await script.waitForRequest(2)
            XCTAssertTrue(script.complete(1, with: [late]))
            XCTAssertTrue(script.complete(2, with: [.init(image: fast, info: [PHImageResultIsDegradedKey: true])]))
            let result = try await task.value
            XCTAssertTrue(result === fast)
            assertPlans(script, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            XCTAssertTrue(script.cancelledIDs.isEmpty)
        }
    }

    func testLateLocalHQCallbacksCannotReplaceOrAbortPendingNetworkHQ() async throws {
        let stale = try syntheticImage()
        let online = try syntheticImage(width: 521, height: 651)
        for late in lateReplies(image: stale) {
            let script = ThumbnailRequestScript(stages: [[.init()], []])
            let task = start(script, networkAllowed: true)
            defer { task.cancel() }
            await script.waitForRequest(2)
            XCTAssertTrue(script.complete(1, with: [late]))
            XCTAssertTrue(script.complete(2, with: [.init(image: online)]))
            let result = try await task.value
            XCTAssertTrue(result === online)
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        }
    }

    func testRequestsRemainSequentialAndLateHQCallbacksCannotReplaceThirdStage() async throws {
        let stale = try syntheticImage(width: 521, height: 651)
        let fast = try syntheticImage()
        let script = ThumbnailRequestScript(stages: [[], [], []])
        let task = start(script, networkAllowed: true)
        defer { task.cancel() }
        await script.waitForRequest(1)
        assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertTrue(script.complete(1, with: [.init(info: [PHImageErrorKey: photosError(3164)])]))
        await script.waitForRequest(2)
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        XCTAssertTrue(script.complete(2, with: [.init(image: stale, info: [PHImageResultIsDegradedKey: true])]))
        // complete is synchronous: ignoring a provisional callback cannot start Fast.
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true])
        XCTAssertTrue(script.complete(2, with: [.init(info: [PHImageResultIsInCloudKey: true])]))
        await script.waitForRequest(3)
        XCTAssertTrue(script.complete(1, with: lateReplies(image: stale)))
        XCTAssertTrue(script.complete(2, with: lateReplies(image: stale)))
        XCTAssertTrue(script.complete(3, with: [.init(image: fast)]))
        let result = try await task.value
        XCTAssertTrue(result === fast)
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, true, false])
        XCTAssertTrue(script.cancelledIDs.isEmpty)
    }

    private struct StagePath {
        let networkAllowed: Bool
        let deliveries: [PHImageRequestOptionsDeliveryMode]
        let networks: [Bool]
        var prefix: [[ThumbnailRequestScript.Reply]] {
            Array(repeating: [.init()], count: deliveries.count - 1)
        }
    }

    private var stagePaths: [StagePath] {
        [StagePath(networkAllowed: true, deliveries: [.highQualityFormat], networks: [false]),
         StagePath(networkAllowed: true, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, true]),
         StagePath(networkAllowed: false, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false]),
         StagePath(networkAllowed: true, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, true, false])]
    }

    private func makeScript(_ path: StagePath, reply: ThumbnailRequestScript.Reply) -> ThumbnailRequestScript {
        ThumbnailRequestScript(stages: path.prefix + [[reply]])
    }

    private func load(_ script: ThumbnailRequestScript, networkAllowed: Bool = false) async throws -> UIImage {
        addTeardownBlock { script.releaseCallbacks() }
        return try await DisplayThumbnailLoader.load(targetSize: target, networkAllowed: networkAllowed,
            request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
    }

    private func start(_ script: ThumbnailRequestScript, networkAllowed: Bool = false,
                       cancelledAtStart: Bool = false) -> Task<UIImage, Error> {
        addTeardownBlock { script.releaseCallbacks() }
        let target = self.target
        return Task {
            if cancelledAtStart { withUnsafeCurrentTask { $0?.cancel() } }
            return try await DisplayThumbnailLoader.load(targetSize: target, networkAllowed: networkAllowed,
                request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
        }
    }

    private func syntheticImage(width: Int = 32, height: Int = 16, scale: CGFloat = 1,
                                orientation: UIImage.Orientation = .up) throws -> UIImage {
        UIImage(cgImage: try TestFixtures.image(width: width, height: height) { _, _ in (19, 71, 203) },
                scale: scale, orientation: orientation)
    }

    private func photosError(_ code: Int) -> NSError { NSError(domain: PHPhotosErrorDomain, code: code) }

    private func missingReplies() -> [ThumbnailRequestScript.Reply] {
        [.init(), .init(info: [PHImageResultIsDegradedKey: true]),
         .init(info: [PHImageErrorKey: photosError(3164)]),
         .init(info: [PHImageResultIsInCloudKey: true]),
         .init(image: UIImage()), .init(image: UIImage(ciImage: CIImage.empty())),
         .init(image: UIImage(ciImage: CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))))]
    }

    private func lateReplies(image: UIImage) -> [ThumbnailRequestScript.Reply] {
        [.init(image: image), .init(info: [PHImageResultIsDegradedKey: true]),
         .init(info: [PHImageErrorKey: photosError(3164)]),
         .init(info: [PHImageErrorKey: AppFailure.permission]),
         .init(info: [PHImageErrorKey: NSError(domain: "SyntheticThumbnailError", code: 8)]),
         .init(image: image, info: [PHImageCancelledKey: true])]
    }

    private func assertPlans(_ script: ThumbnailRequestScript, path: StagePath,
                             file: StaticString = #filePath, line: UInt = #line) {
        assertPlans(script, deliveries: path.deliveries, networks: path.networks, file: file, line: line)
    }

    private func assertPlans(_ script: ThumbnailRequestScript, deliveries: [PHImageRequestOptionsDeliveryMode],
                             networks: [Bool], file: StaticString = #filePath, line: UInt = #line) {
        let plans = script.plans
        XCTAssertEqual(plans.count, deliveries.count, file: file, line: line)
        XCTAssertEqual(networks.count, deliveries.count, file: file, line: line)
        guard plans.count == deliveries.count, networks.count == deliveries.count else { return }
        for index in plans.indices {
            let plan = plans[index]
            XCTAssertEqual(plan.targetSize, target, file: file, line: line)
            XCTAssertEqual(plan.contentMode, .aspectFill, file: file, line: line)
            XCTAssertEqual(plan.options.version, .current, file: file, line: line)
            XCTAssertEqual(plan.options.deliveryMode, deliveries[index], file: file, line: line)
            XCTAssertEqual(plan.options.resizeMode, deliveries[index] == .highQualityFormat ? .exact : .fast, file: file, line: line)
            XCTAssertEqual(plan.options.isNetworkAccessAllowed, networks[index], file: file, line: line)
            XCTAssertFalse(plan.options.isSynchronous, file: file, line: line)
            for earlier in 0..<index {
                XCTAssertFalse(plan.options === plans[earlier].options, "Options must be fresh per request.", file: file, line: line)
            }
        }
    }
}

/// Lock-protected callback script, not a PhotoKit client. Immutable synthetic
/// images/options are never mutated across threads. Every mutable collection is
/// locked; callbacks and continuations are invoked outside the lock.
/// Empty stages are released explicitly; no timers, polling or Photos access.
private final class ThumbnailRequestScript: @unchecked Sendable {
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
    private var storedPlans: [Plan] = []
    private var storedCancelledIDs: [PHImageRequestID] = []
    private var callbacks: [PHImageRequestID: DisplayThumbnailLoader.Callback] = [:]
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(stages: [[Reply]], cancelBeforeIDAt: Int? = nil) {
        self.stages = stages
        self.cancelBeforeIDAt = cancelBeforeIDAt
    }

    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return storedPlans }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return storedCancelledIDs }

    func request(_ targetSize: CGSize, _ contentMode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping DisplayThumbnailLoader.Callback) -> PHImageRequestID {
        lock.lock()
        let index = storedPlans.count
        let id = PHImageRequestID(index + 1)
        storedPlans.append(Plan(targetSize: targetSize, contentMode: contentMode, options: options))
        callbacks[id] = callback
        let expected = stages.indices.contains(index)
        let replies: [Reply] = expected ? stages[index]
            : [.init(info: [PHImageErrorKey: AppFailure.photo("Unexpected thumbnail request.")])]
        let waiting = waiters.removeValue(forKey: index + 1) ?? []
        lock.unlock()
        if !expected { XCTFail("Unexpected request \(index + 1); the script has only \(stages.count) stages.") }
        for waiter in waiting { waiter.resume() }
        for reply in replies { callback(reply.image, reply.info) }
        if cancelBeforeIDAt == index + 1 { withUnsafeCurrentTask { $0?.cancel() } }
        return id
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        storedCancelledIDs.append(id)
        // Retain callbacks to exercise PhotoKit delivery AFTER cancellation.
    }

    func complete(_ id: PHImageRequestID, with replies: [Reply]) -> Bool {
        lock.lock()
        let callback = callbacks[id]
        lock.unlock()
        guard let callback else { return false }
        for reply in replies { callback(reply.image, reply.info) }
        return true
    }

    func releaseCallbacks() {
        // Break script -> callback -> gate -> injected cancellation -> script.
        // Keep them until teardown so late delivery remains testable after finish.
        lock.lock(); defer { lock.unlock() }
        callbacks.removeAll()
    }

    func waitForRequest(_ number: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if storedPlans.count >= number {
                lock.unlock()
                continuation.resume()
            } else {
                waiters[number, default: []].append(continuation)
                lock.unlock()
            }
        }
    }
}