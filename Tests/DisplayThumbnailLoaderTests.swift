import XCTest
import Photos
import UIKit
import CoreImage
@testable import LocalImageIQ

final class DisplayThumbnailLoaderTests: XCTestCase {
    private typealias Reply = ThumbnailRequestScript.Reply
    private let target = CGSize(width: 521, height: 651)
    private var quality224Target: CGSize { CGSize(width: 224, height: CGFloat(224) * 651 / 521) }

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
        let image = try syntheticImage(width: 651, height: 521, scale: 3, orientation: .right)
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

    func testSingleDegradedLocalHQCallbackCompletesRequestButStillTriesHQ224() async throws {
        let image = try syntheticImage()
        for allowed in [false, true] {
            var stages: [[Reply]] = [[.init(image: image, info: [PHImageResultIsDegradedKey: true])], [.init()]]
            if allowed { stages.append([.init()]) }
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script, networkAllowed: allowed)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.stage, .localHQ)
            XCTAssertEqual(result.degraded, true)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
            assertPlans(script, path: stagePaths[allowed ? 2 : 1])
        }
    }

    func testUndersizedLocalHQWithoutDegradedFlagIsRetainedAfterUpgradeMisses() async throws {
        let image = try syntheticImage(width: 32, height: 16)
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: false]]
        for info in infos {
            let stages: [[Reply]] = [[.init(image: image, info: info)], [.init()], [.init()]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script, networkAllowed: true)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.returnedSize, CGSize(width: 32, height: 16))
            XCTAssertEqual(result.degraded, (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
            assertPlans(script, path: stagePaths[2])
        }
    }

    func testReadablePixelsWinOverCloudFlagAndResourceErrorAtEveryStage() async throws {
        let image = try syntheticImage(width: 521, height: 651)
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

    func testOnlyMissingOrUnreadableBothLocalHQRequestsFallBackToOfflineFast() async throws {
        let image = try syntheticImage()
        for missing in missingReplies() {
            let stages: [[Reply]] = [[missing], [missing], [.init(image: image)]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await load(script)
            XCTAssertTrue(result === image)
            assertPlans(script, path: stagePaths[3])
        }
    }

    func testOfflineFastAcceptsSingleDegradedCallbackAfterHQMiss() async throws {
        let image = try syntheticImage()
        let stages: [[Reply]] = [[.init()], [.init()], [
            .init(image: image, info: [PHImageResultIsDegradedKey: true, PHImageErrorKey: photosError(3164)])
        ]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await load(script)
        XCTAssertTrue(result === image)
        assertPlans(script, path: stagePaths[3])
    }

    func testOptInTriesNetworkHQBeforeFastCanMaskQualityUpgrade() async throws {
        let image = try syntheticImage(width: 521, height: 651)
        for missing in missingReplies() {
            let stages: [[Reply]] = [[missing], [missing], [.init(image: image)]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await load(script, networkAllowed: true)
            XCTAssertTrue(result === image)
            assertPlans(script, path: stagePaths[2])
        }
    }

    func testNetworkHQIgnoresProvisionalCallbacksUntilFinalImage() async throws {
        let reduced = try syntheticImage()
        let final = try syntheticImage(width: 521, height: 651)
        let stages: [[Reply]] = [[.init()], [.init()], [
            .init(info: [PHImageResultIsDegradedKey: true]),
            .init(image: reduced, info: [PHImageResultIsDegradedKey: true]),
            .init(image: reduced, info: [PHImageResultIsDegradedKey: true, PHImageErrorKey: photosError(3164)]),
            .init(image: final, info: [PHImageResultIsDegradedKey: false])
        ]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true)
        XCTAssertTrue(result.image === final)
        XCTAssertEqual(result.attempts.count, 3, "Provisional callbacks are not terminal attempts.")
        XCTAssertEqual(result.attempts.last?.returnedSize, CGSize(width: 521, height: 651))
        XCTAssertEqual(result.degraded, false)
        assertPlans(script, path: stagePaths[2])
    }

    func testNetworkHQMissingResourceFallsBackToOfflineFast() async throws {
        let image = try syntheticImage()
        // A network nil+degraded callback is provisional, not a final miss.
        for missing in missingReplies().filter({ !PhotoImageRequestInfo.flag(PHImageResultIsDegradedKey, $0.info) }) {
            let stages: [[Reply]] = [[.init()], [.init()], [missing], [.init(image: image)]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await load(script, networkAllowed: true)
            XCTAssertTrue(result === image)
            assertPlans(script, path: stagePaths[4])
        }
    }

    func testMissingNetworkImageWith3164IsTerminalEvenWhenMarkedDegraded() async throws {
        let image = try syntheticImage()
        let stages: [[Reply]] = [[.init()], [.init()], [
            .init(info: [PHImageErrorKey: photosError(3164), PHImageResultIsDegradedKey: true])
        ], [.init(image: image)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await load(script, networkAllowed: true)
        XCTAssertTrue(result === image)
        assertPlans(script, path: stagePaths[4])
    }

    func testExhaustedPlainMissesArePhotoErrorsNotInventedCloudErrors() async {
        for allowed in [false, true] {
            let stages: [[Reply]] = Array(repeating: [.init()], count: allowed ? 4 : 3)
            let script = ThumbnailRequestScript(stages: stages)
            do { _ = try await load(script, networkAllowed: allowed); XCTFail("Expected missing preview.") }
            catch AppFailure.photo { }
            catch { XCTFail("Unexpected error: \(error)") }
            assertPlans(script, path: allowed ? stagePaths[4] : stagePaths[3])
        }
    }

    func testAnyMissingStageRequiringNetworkPreservesCloudOnlyClassification() async {
        let infos: [[AnyHashable: Any]] = [[PHImageErrorKey: photosError(3164)], [PHImageResultIsInCloudKey: true]]
        for allowed in [false, true] {
            let count = allowed ? 4 : 3
            for index in 0..<count {
                for info in infos {
                    var stages: [[Reply]] = Array(repeating: [.init()], count: count)
                    stages[index] = [.init(info: info)]
                    let script = ThumbnailRequestScript(stages: stages)
                    do { _ = try await load(script, networkAllowed: allowed); XCTFail("Expected cloud-only after all misses.") }
                    catch AppFailure.cloudOnly { }
                    catch { XCTFail("Unexpected error: \(error)") }
                    assertPlans(script, path: allowed ? stagePaths[4] : stagePaths[3])
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
        let stages: [[Reply]] = [[.init(image: image)], [.init()]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script)
        XCTAssertEqual(result.image.cgImage?.width, 32)
        XCTAssertEqual(result.image.cgImage?.height, 16)
        XCTAssertEqual(result.image.scale, 2)
        XCTAssertEqual(result.image.imageOrientation, .leftMirrored)
        XCTAssertEqual(result.returnedSize, CGSize(width: 32, height: 16))
        XCTAssertEqual(result.attempts.first?.returnedSize, result.returnedSize)
        XCTAssertFalse(result.isSufficientForDisplay)
        assertPlans(script, path: stagePaths[1])
    }

    func testFirstTerminalCallbackWinsOverSynchronousDuplicatesAtEveryStage() async throws {
        let first = try syntheticImage(width: 521, height: 651)
        let later = try syntheticImage(width: 1042, height: 1302)
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
        let stages: [[Reply]] = [[.init()], [.init()], []]
        let script = ThumbnailRequestScript(stages: stages)
        let task = start(script, networkAllowed: true)
        defer { task.cancel() }
        await script.waitForRequest(3)
        XCTAssertTrue(script.complete(3, with: [.init(image: reduced, info: [PHImageResultIsDegradedKey: true])]))
        task.cancel()
        do { _ = try await task.value; XCTFail("A provisional image must not complete network HQ.") }
        catch { XCTAssertTrue(error is CancellationError) }
        assertPlans(script, path: stagePaths[2])
        XCTAssertEqual(script.cancelledIDs, [3])
    }

    func testLateLocalHQCallbacksCannotReplaceOrAbortPendingFastFallback() async throws {
        let stale = try syntheticImage()
        let fast = try syntheticImage(width: 64, height: 48)
        for late in lateReplies(image: stale) {
            let stages: [[Reply]] = [[.init()], [.init()], []]
            let script = ThumbnailRequestScript(stages: stages)
            let task = start(script)
            defer { task.cancel() }
            await script.waitForRequest(3)
            XCTAssertTrue(script.complete(1, with: [late]))
            XCTAssertTrue(script.complete(2, with: [late]))
            XCTAssertTrue(script.complete(3, with: [.init(image: fast, info: [PHImageResultIsDegradedKey: true])]))
            let result = try await task.value
            XCTAssertTrue(result === fast)
            assertPlans(script, path: stagePaths[3])
            XCTAssertTrue(script.cancelledIDs.isEmpty)
        }
    }

    func testLateLocalHQCallbacksCannotReplaceOrAbortPendingNetworkHQ() async throws {
        let stale = try syntheticImage()
        let online = try syntheticImage(width: 521, height: 651)
        for late in lateReplies(image: stale) {
            let stages: [[Reply]] = [[.init()], [.init()], []]
            let script = ThumbnailRequestScript(stages: stages)
            let task = start(script, networkAllowed: true)
            defer { task.cancel() }
            await script.waitForRequest(3)
            XCTAssertTrue(script.complete(1, with: [late]))
            XCTAssertTrue(script.complete(2, with: [late]))
            XCTAssertTrue(script.complete(3, with: [.init(image: online)]))
            let result = try await task.value
            XCTAssertTrue(result === online)
            assertPlans(script, path: stagePaths[2])
        }
    }

    func testRequestsRemainSequentialAndLateHQCallbacksCannotReplaceFourthStage() async throws {
        let stale = try syntheticImage(width: 521, height: 651)
        let fast = try syntheticImage()
        let stages: [[Reply]] = [[], [], [], []]
        let script = ThumbnailRequestScript(stages: stages)
        let task = start(script, networkAllowed: true)
        defer { task.cancel() }
        await script.waitForRequest(1)
        assertPlans(script, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertTrue(script.complete(1, with: [.init(info: [PHImageErrorKey: photosError(3164)])]))
        await script.waitForRequest(2)
        assertPlans(script, path: stagePaths[1])
        XCTAssertTrue(script.complete(2, with: [.init()]))
        await script.waitForRequest(3)
        assertPlans(script, path: stagePaths[2])
        XCTAssertTrue(script.complete(3, with: [.init(image: stale, info: [PHImageResultIsDegradedKey: true])]))
        // complete is synchronous: ignoring a provisional callback cannot start Fast.
        assertPlans(script, path: stagePaths[2])
        XCTAssertTrue(script.complete(3, with: [.init(info: [PHImageResultIsInCloudKey: true])]))
        await script.waitForRequest(4)
        XCTAssertTrue(script.complete(1, with: lateReplies(image: stale)))
        XCTAssertTrue(script.complete(2, with: lateReplies(image: stale)))
        XCTAssertTrue(script.complete(3, with: lateReplies(image: stale)))
        XCTAssertTrue(script.complete(4, with: [.init(image: fast)]))
        let result = try await task.value
        XCTAssertTrue(result === fast)
        assertPlans(script, path: stagePaths[4])
        XCTAssertTrue(script.cancelledIDs.isEmpty)
    }

    func testExactCallerHQ224AndFast224ContractPreservesBothAssetAspects() async throws {
        let assetSizes: [CGSize] = [CGSize(width: 4000, height: 3000), CGSize(width: 3000, height: 4000)]
        let fast = try syntheticImage(width: 64, height: 48, scale: 3, orientation: .right)
        for asset in assetSizes {
            let supplied = LocalPreviewComparisonLoader.targetSize(
                width: Int(asset.width), height: Int(asset.height), shortEdge: 224)
            let expected = asset.width > asset.height
                ? CGSize(width: CGFloat(224) * 4000 / 3000, height: 224)
                : CGSize(width: 224, height: CGFloat(224) * 4000 / 3000)
            XCTAssertEqual(supplied, expected)
            let error = NSError(domain: PHPhotosErrorDomain, code: 3164,
                                userInfo: [NSLocalizedDescriptionKey: "DO_NOT_COPY_ERROR_DETAILS"])
            let stages: [[Reply]] = [
                [.init(info: [PHImageErrorKey: error, PHImageResultIsDegradedKey: false])],
                [.init(image: UIImage(), info: [PHImageResultIsDegradedKey: true])],
                [.init(image: fast)]
            ]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script, quality224Size: supplied)
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat],
                        networks: [false, false, false], quality224Size: supplied)
            XCTAssertTrue(result.image === fast)
            XCTAssertEqual(result.stage, .localFast224)
            XCTAssertEqual(result.requestedSize, supplied)
            XCTAssertEqual(result.returnedSize, CGSize(width: 64, height: 48))
            XCTAssertNil(result.degraded)
            XCTAssertFalse(result.isReusable)
            XCTAssertEqual(result.attempts.map(\.stage), [.localHQ, .localHQ224, .localFast224])
            XCTAssertEqual(result.attempts.map(\.requestedSize), [target, supplied, supplied])
            XCTAssertEqual(result.attempts.map(\.returnedSize), [nil, nil, CGSize(width: 64, height: 48)])
            XCTAssertEqual(result.attempts.map(\.degraded), [false, true, nil])
            XCTAssertEqual(result.attempts.map(\.outcome), ["需网络", "无可用像素", "native return"])
        }
    }

    func testMissingDisplayHQUsesUndersizedHQ224OfflineWithoutFast() async throws {
        let hq224 = try syntheticImage(width: 224, height: 299)
        let supplied = CGSize(width: 224, height: CGFloat(224) * 4000 / 3000)
        for missing in missingReplies() {
            let stages: [[Reply]] = [[missing], [.init(image: hq224)]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script, quality224Size: supplied)
            XCTAssertTrue(result.image === hq224)
            XCTAssertEqual(result.stage, .localHQ224)
            XCTAssertEqual(result.requestedSize, supplied)
            XCTAssertEqual(result.returnedSize, CGSize(width: 224, height: 299))
            XCTAssertNil(result.degraded)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
            XCTAssertEqual(result.attempts.map(\.stage), [.localHQ, .localHQ224])
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat],
                        networks: [false, false], quality224Size: supplied)
        }
    }

    func testDegraded32PixelDisplayHQIsUpgradedByCallerHQ224() async throws {
        let reduced = try syntheticImage(width: 32, height: 16)
        let hq = try syntheticImage(width: 299, height: 224)
        let supplied = CGSize(width: CGFloat(224) * 4000 / 3000, height: 224)
        let stages: [[Reply]] = [
            [.init(image: reduced, info: [PHImageResultIsDegradedKey: true])],
            [.init(image: hq, info: [PHImageResultIsDegradedKey: false])],
            [.init(info: [PHImageResultIsInCloudKey: true])]
        ]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true, quality224Size: supplied)
        XCTAssertTrue(result.image === hq)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertEqual(result.requestedSize, supplied)
        XCTAssertEqual(result.returnedSize, CGSize(width: 299, height: 224))
        XCTAssertEqual(result.degraded, false)
        XCTAssertFalse(result.isSufficientForDisplay)
        XCTAssertFalse(result.isReusable)
        XCTAssertEqual(result.attempts.map(\.stage), [.localHQ, .localHQ224, .networkHQ])
        XCTAssertEqual(result.attempts.map(\.returnedSize), [CGSize(width: 32, height: 16), CGSize(width: 299, height: 224), nil])
        XCTAssertEqual(result.attempts.map(\.outcome), ["native return", "native return", "需网络"])
        assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .highQualityFormat],
                    networks: [false, false, true], quality224Size: supplied)
    }

    func testLargerLocalHQIsRetainedWhenHQ224HasLessPixelCoverage() async throws {
        let large = try syntheticImage(width: 500, height: 600)
        let small = try syntheticImage(width: 224, height: 280)
        let stages: [[Reply]] = [[.init(image: large)], [.init(image: small)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script)
        XCTAssertTrue(result.image === large)
        XCTAssertEqual(result.stage, .localHQ)
        XCTAssertEqual(result.requestedSize, target)
        XCTAssertEqual(result.returnedSize, CGSize(width: 500, height: 600))
        XCTAssertEqual(result.attempts.last?.returnedSize, CGSize(width: 224, height: 280))
        XCTAssertFalse(result.isSufficientForDisplay)
        XCTAssertFalse(result.isReusable)
        assertPlans(script, path: stagePaths[1])
    }

    func testOptInUpgradesUsableButUndersizedLocalCandidates() async throws {
        let small = try syntheticImage()
        let hq224 = try syntheticImage(width: 224, height: 280)
        let online = try syntheticImage(width: 521, height: 651)
        let stages: [[Reply]] = [[.init(image: small)], [.init(image: hq224)], [.init(image: online)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true)
        XCTAssertTrue(result.image === online)
        XCTAssertEqual(result.stage, .networkHQ)
        XCTAssertEqual(result.requestedSize, target)
        XCTAssertNil(result.degraded)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertTrue(result.isReusable)
        XCTAssertEqual(result.attempts.map(\.outcome), Array(repeating: "native return", count: 3))
        assertPlans(script, path: stagePaths[2])
    }

    func testSmallerNetworkHQNeverReplacesBetterLocalHQ224() async throws {
        let local = try syntheticImage(width: 224, height: 280)
        let online = try syntheticImage()
        let stages: [[Reply]] = [[.init()], [.init(image: local)], [.init(image: online)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true)
        XCTAssertTrue(result.image === local)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertEqual(result.attempts.last?.stage, .networkHQ)
        XCTAssertEqual(result.attempts.last?.returnedSize, CGSize(width: 32, height: 16))
        assertPlans(script, path: stagePaths[2])
    }

    func testSufficientHQ224SkipsNetworkEvenWhenOptedIn() async throws {
        let image = try syntheticImage(width: 521, height: 651)
        let stages: [[Reply]] = [[.init()], [.init(image: image)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertTrue(result.image === image)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertTrue(result.isReusable)
        assertPlans(script, path: stagePaths[1])
    }

    func testNonDegradedCandidatesTakePriorityOverGreaterPixelCoverage() async throws {
        let large = try syntheticImage(width: 800, height: 800)
        let small = try syntheticImage()
        let unflagged: [Bool?] = [nil, false]
        for flag in unflagged {
            for degradedFirst in [true, false] {
                let clean = Reply(image: small, info: flag.map { [PHImageResultIsDegradedKey: $0] })
                let reduced = Reply(image: large, info: [PHImageResultIsDegradedKey: true])
                let stages: [[Reply]] = degradedFirst ? [[reduced], [clean]] : [[clean], [reduced]]
                let script = ThumbnailRequestScript(stages: stages)
                let result = try await loadResult(script)
                XCTAssertTrue(result.image === small)
                XCTAssertEqual(result.stage, degradedFirst ? .localHQ224 : .localHQ)
                XCTAssertEqual(result.degraded, flag)
                XCTAssertFalse(result.isSufficientForDisplay)
                assertPlans(script, path: stagePaths[1])
            }
        }
    }

    func testAllDegradedHQCandidatesStillReturnBestWithoutFast() async throws {
        let small = try syntheticImage()
        let large = try syntheticImage(width: 521, height: 651)
        let stages: [[Reply]] = [
            [.init(image: small, info: [PHImageResultIsDegradedKey: true])],
            [.init(image: large, info: [PHImageResultIsDegradedKey: true])]
        ]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script)
        XCTAssertTrue(result.image === large)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertEqual(result.degraded, true)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertFalse(result.isReusable)
        assertPlans(script, path: stagePaths[1])
    }

    func testOptInStillTriesNetworkWhenLargeLocalPixelsAreFlaggedDegraded() async throws {
        let local = try syntheticImage(width: 521, height: 651)
        let online = try syntheticImage(width: 521, height: 651)
        let stages: [[Reply]] = [
            [.init(image: local, info: [PHImageResultIsDegradedKey: true])], [.init()], [.init(image: online)]
        ]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script, networkAllowed: true)
        XCTAssertTrue(result.image === online)
        XCTAssertEqual(result.stage, .networkHQ)
        XCTAssertTrue(result.isReusable)
        assertPlans(script, path: stagePaths[2])
    }

    func testEqualCoverageKeepsFirstAndNilAndFalseFlagsHaveEqualPriority() async throws {
        let first = try syntheticImage(width: 224, height: 280)
        let second = try syntheticImage(width: 224, height: 280)
        let flags: [Bool?] = [nil, false, true]
        for firstFlag in flags {
            let secondFlag: Bool? = firstFlag == true ? true : (firstFlag == nil ? false : nil)
            let stages: [[Reply]] = [
                [.init(image: first, info: firstFlag.map { [PHImageResultIsDegradedKey: $0] })],
                [.init(image: second, info: secondFlag.map { [PHImageResultIsDegradedKey: $0] })]
            ]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script)
            XCTAssertTrue(result.image === first)
            XCTAssertEqual(result.stage, .localHQ)
            XCTAssertEqual(result.degraded, firstFlag)
            assertPlans(script, path: stagePaths[1])
        }
    }

    func testSelectionUsesMinimumOrientedAxisRatioNotRasterAreaOrLongestEdge() async throws {
        let first = try syntheticImage(width: 300, height: 600, scale: 3, orientation: .right)
        let second = try syntheticImage(width: 400, height: 320)
        let stages: [[Reply]] = [[.init(image: first)], [.init(image: second)]]
        let script = ThumbnailRequestScript(stages: stages)
        let result = try await loadResult(script)
        XCTAssertTrue(result.image === second)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertEqual(result.attempts.first?.returnedSize, CGSize(width: 300, height: 600))
        XCTAssertFalse(result.isSufficientForDisplay)
        assertPlans(script, path: stagePaths[1])
    }

    func testOneInsufficientDisplayAxisAlwaysTriggersHQ224() async throws {
        let sizes: [CGSize] = [CGSize(width: 520, height: 651), CGSize(width: 521, height: 650)]
        for size in sizes {
            let image = try syntheticImage(width: Int(size.width), height: Int(size.height))
            let stages: [[Reply]] = [[.init(image: image)], [.init()]]
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script)
            XCTAssertTrue(result.image === image)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
            assertPlans(script, path: stagePaths[1])
        }
    }

    func testRawPixelMetadataAndSufficiencyRespectEveryUIImageOrientationNotScale() throws {
        let orientations: [UIImage.Orientation] = [.up, .upMirrored, .down, .downMirrored,
                                                   .left, .leftMirrored, .right, .rightMirrored]
        for (index, orientation) in orientations.enumerated() {
            let image = try syntheticImage(width: 640, height: 320, scale: 3, orientation: orientation)
            let size = CGSize(width: 320, height: 640)
            let result = DisplayThumbnailResult(image: image, stage: .localHQ, requestedSize: size,
                returnedSize: CGSize(width: 640, height: 320), degraded: nil, targetSize: size)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.returnedSize, CGSize(width: 640, height: 320))
            XCTAssertEqual(result.isSufficientForDisplay, index >= 4)
            XCTAssertEqual(result.isReusable, index >= 4)
        }
    }

    func testCacheEligibilityDependsOnStageRawFlagAndBothDisplayDimensions() throws {
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ, .localFast224, .unknown]
        let flags: [Bool?] = [nil, false, true]
        let size = CGSize(width: 300, height: 400)
        for width in [299, 300] {
            let image = try syntheticImage(width: width, height: 400)
            for stage in stages {
                for flag in flags {
                    let result = DisplayThumbnailResult(image: image, stage: stage, requestedSize: size,
                        returnedSize: CGSize(width: width, height: 400), degraded: flag, targetSize: size)
                    XCTAssertEqual(result.isSufficientForDisplay, width == 300)
                    let reusable = width == 300 && stage != .localFast224 && stage != .unknown && flag != true
                    XCTAssertEqual(result.isReusable, reusable)
                    XCTAssertEqual(result.degraded, flag)
                }
            }
        }
    }

    func testUnverifiedLegacyAdapterKeepsKnownRawPixelsButNeverReuses() throws {
        let image = try syntheticImage(width: 640, height: 320, scale: 2, orientation: .rightMirrored)
        let size = CGSize(width: 320, height: 640)
        let result = DisplayThumbnailResult.unverified(image: image, targetSize: size)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.stage, .unknown)
        XCTAssertEqual(result.requestedSize, size)
        XCTAssertEqual(result.returnedSize, CGSize(width: 640, height: 320))
        XCTAssertNil(result.degraded)
        XCTAssertTrue(result.attempts.isEmpty)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertFalse(result.isReusable)
    }

    func testUnverifiedLegacyAdapterDoesNotInventPixelsFromImagePointsOrCIExtent() throws {
        let raster = try syntheticImage()
        let ci = UIImage(ciImage: CIImage(cgImage: try XCTUnwrap(raster.cgImage)), scale: 2, orientation: .left)
        for image in [UIImage(), ci] {
            let result = DisplayThumbnailResult.unverified(image: image, targetSize: target)
            XCTAssertTrue(result.image === image)
            XCTAssertEqual(result.stage, .unknown)
            XCTAssertEqual(result.returnedSize, .zero)
            XCTAssertNil(result.degraded)
            XCTAssertTrue(result.attempts.isEmpty)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
        }
    }

    func testStableDisplaySourceTags() {
        XCTAssertEqual(DisplayThumbnailStage.localHQ.rawValue, "本地 HQ（显示尺寸）")
        XCTAssertEqual(DisplayThumbnailStage.localHQ224.rawValue, "本地 HQ224")
        XCTAssertEqual(DisplayThumbnailStage.networkHQ.rawValue, "联网 HQ（显示尺寸）")
        XCTAssertEqual(DisplayThumbnailStage.localFast224.rawValue, "本地 Fast224")
        XCTAssertEqual(DisplayThumbnailStage.unknown.rawValue, "来源未知")
    }

    func testGenericErrorsAfterUsableHQStillPropagate() async throws {
        let image = try syntheticImage()
        let expected = NSError(domain: "SyntheticThumbnailError", code: 8)
        for number in [2, 3] {
            var stages: [[Reply]] = Array(repeating: [.init(image: image)], count: number - 1)
            stages.append([.init(image: image, info: [PHImageErrorKey: expected,
                PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true])])
            let script = ThumbnailRequestScript(stages: stages)
            do { _ = try await loadResult(script, networkAllowed: number == 3); XCTFail("Must propagate ordinary errors.") }
            catch {
                XCTAssertEqual((error as NSError).domain, expected.domain)
                XCTAssertEqual((error as NSError).code, expected.code)
            }
            assertPlans(script, path: stagePaths[number - 1])
        }
    }

    func testPermissionErrorsAfterUsableHQStillPropagate() async throws {
        let image = try syntheticImage()
        let errors: [Error] = [AppFailure.permission, photosError(PHPhotosError.Code.accessUserDenied.rawValue),
                               photosError(PHPhotosError.Code.accessRestricted.rawValue)]
        for number in [2, 3] {
            for error in errors {
                var stages: [[Reply]] = Array(repeating: [.init(image: image)], count: number - 1)
                stages.append([.init(image: image, info: [PHImageErrorKey: error, PHImageResultIsDegradedKey: true])])
                let script = ThumbnailRequestScript(stages: stages)
                do { _ = try await loadResult(script, networkAllowed: number == 3); XCTFail("Must propagate permission errors.") }
                catch AppFailure.permission { }
                catch { XCTFail("Unexpected error: \(error)") }
                assertPlans(script, path: stagePaths[number - 1])
            }
        }
    }

    func testCallbackCancellationAfterUsableHQStillPropagates() async throws {
        let image = try syntheticImage()
        for number in [2, 3] {
            var stages: [[Reply]] = Array(repeating: [.init(image: image)], count: number - 1)
            stages.append([.init(image: image, info: [PHImageCancelledKey: true,
                PHImageErrorKey: AppFailure.permission, PHImageResultIsDegradedKey: true])])
            let script = ThumbnailRequestScript(stages: stages)
            do { _ = try await loadResult(script, networkAllowed: number == 3); XCTFail("Must propagate cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            assertPlans(script, path: stagePaths[number - 1])
        }
    }

    func testTaskCancellationAfterUsableHQCancelsOnlyPendingUpgrade() async throws {
        let image = try syntheticImage()
        for number in [2, 3] {
            var stages: [[Reply]] = Array(repeating: [.init(image: image)], count: number - 1)
            stages.append([])
            let script = ThumbnailRequestScript(stages: stages)
            let task = start(script, networkAllowed: number == 3)
            defer { task.cancel() }
            await script.waitForRequest(number)
            task.cancel()
            for id in 1...number {
                XCTAssertTrue(script.complete(PHImageRequestID(id), with: lateReplies(image: image)))
            }
            do { _ = try await task.value; XCTFail("Earlier pixels cannot undo cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(script.cancelledIDs, [PHImageRequestID(number)])
            assertPlans(script, path: stagePaths[number - 1])
        }
    }

    func testFirstSmallTerminalCallbackRemainsCandidateDespiteLargerDuplicatesAtEveryStage() async throws {
        let first = try syntheticImage()
        let later = try syntheticImage(width: 521, height: 651)
        for path in stagePaths {
            let replies: [Reply] = [.init(image: first)] + lateReplies(image: later)
            var stages: [[Reply]] = path.prefix + [replies]
            // An undersized HQ candidate continues through the remaining HQ
            // requests, but never starts Fast. Duplicates cannot upgrade it.
            let remainingHQ = max(0, 3 - path.deliveries.count)
            if path.networkAllowed { stages += Array(repeating: [.init()], count: remainingHQ) }
            let script = ThumbnailRequestScript(stages: stages)
            let result = try await loadResult(script, networkAllowed: path.networkAllowed)
            XCTAssertTrue(result.image === first)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertFalse(result.isReusable)
            XCTAssertEqual(result.attempts[path.deliveries.count - 1].returnedSize, CGSize(width: 32, height: 16))
            assertPlans(script, path: path.networkAllowed && path.deliveries.count < 3 ? stagePaths[2] : path)
        }
    }

    func testLegacyLoadComputesShort224FromTileAspectOnly() async throws {
        let image = try syntheticImage()
        let sizes: [CGSize] = [target, CGSize(width: 651, height: 521)]
        for size in sizes {
            let stages: [[Reply]] = [[.init()], [.init()], [.init(image: image)]]
            let script = ThumbnailRequestScript(stages: stages)
            addTeardownBlock { script.releaseCallbacks() }
            let result = try await DisplayThumbnailLoader.load(targetSize: size, networkAllowed: false,
                request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
            let expected = size.width < size.height ? quality224Target
                : CGSize(width: quality224Target.height, height: 224)
            XCTAssertTrue(result === image)
            assertPlans(script, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat],
                        networks: [false, false, false], displaySize: size, quality224Size: expected)
        }
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
         StagePath(networkAllowed: true, deliveries: [.highQualityFormat, .highQualityFormat], networks: [false, false]),
         StagePath(networkAllowed: true, deliveries: [.highQualityFormat, .highQualityFormat, .highQualityFormat], networks: [false, false, true]),
         StagePath(networkAllowed: false, deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, false, false]),
         StagePath(networkAllowed: true, deliveries: [.highQualityFormat, .highQualityFormat, .highQualityFormat, .fastFormat], networks: [false, false, true, false])]
    }

    private func makeScript(_ path: StagePath, reply: ThumbnailRequestScript.Reply) -> ThumbnailRequestScript {
        ThumbnailRequestScript(stages: path.prefix + [[reply]])
    }

    private func load(_ script: ThumbnailRequestScript, networkAllowed: Bool = false) async throws -> UIImage {
        addTeardownBlock { script.releaseCallbacks() }
        return try await DisplayThumbnailLoader.load(targetSize: target, networkAllowed: networkAllowed,
            request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
    }

    private func loadResult(_ script: ThumbnailRequestScript, networkAllowed: Bool = false,
                            targetSize: CGSize? = nil, quality224Size: CGSize? = nil) async throws -> DisplayThumbnailResult {
        addTeardownBlock { script.releaseCallbacks() }
        return try await DisplayThumbnailLoader.loadResult(targetSize: targetSize ?? target,
            quality224Target: quality224Size ?? quality224Target, networkAllowed: networkAllowed,
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
                             networks: [Bool], displaySize: CGSize? = nil, quality224Size: CGSize? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        let plans = script.plans
        XCTAssertEqual(plans.count, deliveries.count, file: file, line: line)
        XCTAssertEqual(networks.count, deliveries.count, file: file, line: line)
        guard plans.count == deliveries.count, networks.count == deliveries.count else { return }
        for index in plans.indices {
            let plan = plans[index]
            let shortEdge224 = index == 1 || deliveries[index] == .fastFormat
            let expectedSize = shortEdge224 ? (quality224Size ?? quality224Target) : (displaySize ?? target)
            XCTAssertEqual(plan.targetSize, expectedSize, file: file, line: line)
            XCTAssertEqual(plan.contentMode, shortEdge224 ? .aspectFit : .aspectFill, file: file, line: line)
            XCTAssertEqual(plan.options.version, .current, file: file, line: line)
            XCTAssertEqual(plan.options.deliveryMode, deliveries[index], file: file, line: line)
            XCTAssertEqual(plan.options.resizeMode, shortEdge224 ? .fast : .exact, file: file, line: line)
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