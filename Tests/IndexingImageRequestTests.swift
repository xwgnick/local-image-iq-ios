import XCTest
import Photos
import UIKit
import CoreImage
import ImageIO
@testable import LocalImageIQ

final class IndexingImageRequestTests: XCTestCase {
    private let target = CGSize(width: 448, height: 224)

    func testCacheVersionAndSourceContract() {
        XCTAssertEqual(IndexImagePolicy.version, "photokit-hq224-fast-fallback-v1")
        XCTAssertEqual(IndexImagePolicy.cacheVersion(modelVersion: "model-v2"),
                       "model-v2|photokit-hq224-fast-fallback-v1")
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

    func testAllowedNetworkStillRequestsLocalHQFirstAndAcceptsDegradedOnce() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        let requests = PreviewRequestScript(stages: [[
            .init(image: image, info: [PHImageResultIsDegradedKey: true]),
            .init(image: nil, info: [PHImageErrorKey: photosError(3164)]),
            .init(image: image)
        ]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertEqual(result.source, .localReducedPreview)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(result.requestedSize, target)
        XCTAssertEqual(result.photokitDegraded, true)
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertTrue(requests.cancelledIDs.isEmpty)
    }

    func testSingleDegradedCallbackCompletesWithoutWaitingForBetterPixels() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        for useFastFallback in [false, true] {
            let success = [PreviewRequestScript.Reply(image: image, info: [PHImageResultIsDegradedKey: true])]
            let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], success] : [success])
            let result = try await load(requests, networkAllowed: true)
            XCTAssertEqual(result.source, .localReducedPreview)
            XCTAssertTrue(result.cgImage === image.cgImage)
            XCTAssertEqual(result.photokitDegraded, true)
            XCTAssertEqual(result.requestedSize, target)
            assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                        networks: useFastFallback ? [false, false] : [false])
        }
    }

    func testFullSizeLocalPixelsNeedNoNetworkOrDataAPI() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        let requests = PreviewRequestScript(stages: [[.init(image: image)]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertEqual(result.source, .localPreview)
        XCTAssertTrue(result.cgImage === image.cgImage)
        // The injected surface supplies ONLY requestImage-style previews; there is
        // no original-data provider, and retaining the exact CGImage proves no encode/decode.
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertEqual(result.requestedSize, target)
        XCTAssertNil(result.photokitDegraded)
    }

    func testSmallPixelsAreReducedEvenWithoutDegradedFlag() async throws {
        let image = try syntheticImage()
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: false]]
        for useFastFallback in [false, true] {
            for info in infos {
                let success = [PreviewRequestScript.Reply(image: image, info: info)]
                let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], success] : [success])
                let result = try await load(requests, networkAllowed: true)
                XCTAssertEqual(result.source, .localReducedPreview)
                XCTAssertTrue(result.cgImage === image.cgImage)
                XCTAssertEqual(result.cgImage.width, 32)
                XCTAssertEqual(result.cgImage.height, 16)
                XCTAssertEqual(result.photokitDegraded, info == nil ? nil : false)
                assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                            networks: useFastFallback ? [false, false] : [false])
            }
        }
    }

    func testUsableLocalPixelsWinOverCloudFlagAnd3164() async throws {
        let image = try syntheticImage()
        for networkAllowed in [false, true] {
            for useFastFallback in [false, true] {
                let success = [PreviewRequestScript.Reply(image: image, info: [
                    PHImageResultIsInCloudKey: true, PHImageErrorKey: photosError(3164)
                ])]
                let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], success] : [success])
                let result = try await load(requests, networkAllowed: networkAllowed)
                XCTAssertTrue(result.cgImage === image.cgImage)
                XCTAssertEqual(result.source, .localReducedPreview)
                assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                            networks: useFastFallback ? [false, false] : [false])
            }
        }
    }

    func testUsablePixelsWinOverGenericErrorAndCloudMetadataAtEitherLocalStage() async throws {
        let image = try syntheticImage()
        for useFastFallback in [false, true] {
            let success = [PreviewRequestScript.Reply(image: image, info: [
                PHImageErrorKey: NSError(domain: "SyntheticPhotoError", code: 8), PHImageResultIsInCloudKey: true
            ])]
            let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], success] : [success])
            let result = try await load(requests, networkAllowed: true)
            XCTAssertTrue(result.cgImage === image.cgImage)
            XCTAssertEqual(result.source, .localReducedPreview)
            assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                        networks: useFastFallback ? [false, false] : [false])
        }
    }

    func testMissing3164WithoutCloudFlagIsCloudOnlyWhenOffline() async {
        let missing = PreviewRequestScript.Reply(info: [PHImageErrorKey: photosError(3164)])
        let scenarios: [[[PreviewRequestScript.Reply]]] = [[[missing], [.init()]], [[.init()], [missing]], [[missing], [missing]]]
        for stages in scenarios {
            let requests = PreviewRequestScript(stages: stages)
            do {
                _ = try await load(requests)
                XCTFail("Either local stage requiring network must yield cloud-only, but only after both miss.")
            } catch AppFailure.cloudOnly { }
            catch { XCTFail("Unexpected error: \(error)") }
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        }
    }

    func testNilImageWithCloudFlagWithoutErrorIsCloudOnlyWhenOffline() async {
        let missing = PreviewRequestScript.Reply(info: [PHImageResultIsInCloudKey: true])
        let scenarios: [[[PreviewRequestScript.Reply]]] = [[[missing], [.init()]], [[.init()], [missing]], [[missing], [missing]]]
        for stages in scenarios {
            let requests = PreviewRequestScript(stages: stages)
            do { _ = try await load(requests); XCTFail("Expected cloud-only after two local misses.") }
            catch AppFailure.cloudOnly { }
            catch { XCTFail("Unexpected error: \(error)") }
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        }
    }

    func testPlainNilAndDegradedNilCompleteAsPhotoErrorsNotCloudOnly() async {
        let infos: [[AnyHashable: Any]?] = [nil, [PHImageResultIsDegradedKey: true]]
        for first in infos {
            for second in infos {
                let requests = PreviewRequestScript(stages: [[.init(info: first)], [.init(info: second)]])
                do {
                    _ = try await load(requests)
                    XCTFail("Each nil callback must complete its stage, not wait for another callback.")
                } catch AppFailure.photo { }
                catch { XCTFail("Unknown availability must not be called cloud-only: \(error)") }
                assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            }
        }
    }

    func testHQMissingFallsBackToFastOfflineAndFastSuccessSuppressesAllowedNetwork() async throws {
        let image = try syntheticImage(width: 448, height: 224, orientation: .left)
        for missing in missingReplies() {
            for networkAllowed in [false, true] {
                let requests = PreviewRequestScript(stages: [[missing], [.init(image: image)]])
                let result = try await load(requests, networkAllowed: networkAllowed)
                XCTAssertEqual(result.source, .localPreview)
                XCTAssertTrue(result.cgImage === image.cgImage)
                XCTAssertEqual(result.orientation, .left)
                XCTAssertEqual(result.requestedSize, target)
                XCTAssertNil(result.photokitDegraded)
                assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
                XCTAssertTrue(requests.cancelledIDs.isEmpty)
            }
        }
    }

    func testTwoLocalMissesAllowThirdNetworkHQOnlyWithExplicitOptIn() async throws {
        let image = try syntheticImage(orientation: .right)
        for first in missingReplies() {
            for second in missingReplies() {
                let requests = PreviewRequestScript(stages: [
                    [first], [second], [.init(image: image, info: [PHImageResultIsDegradedKey: true])]
                ])
                let result = try await load(requests, networkAllowed: true)
                XCTAssertEqual(result.source, .networkPreview)
                XCTAssertTrue(result.cgImage === image.cgImage)
                XCTAssertEqual(result.orientation, .right)
                XCTAssertEqual(result.requestedSize, target)
                XCTAssertEqual(result.photokitDegraded, true)
                assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                            networks: [false, false, true])
                XCTAssertTrue(requests.cancelledIDs.isEmpty)
            }
        }
    }

    func testGenericErrorsWithoutPixelsRemainFailuresEvenWithCloudFlagAtEitherLocalStage() async {
        let errors: [Error] = [
            NSError(domain: "SyntheticPhotoError", code: 8),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            NSError(domain: "NotThePhotosDomain", code: 3164)
        ]
        for useFastFallback in [false, true] {
            for expected in errors {
                let failure = [PreviewRequestScript.Reply(info: [
                    PHImageErrorKey: expected, PHImageResultIsInCloudKey: true
                ])]
                let requests = PreviewRequestScript(stages: useFastFallback
                    ? [[.init(info: [PHImageErrorKey: photosError(3164)])], failure] : [failure])
                do {
                    _ = try await load(requests, networkAllowed: true)
                    XCTFail("A real error must not trigger another local or network request.")
                } catch {
                    XCTAssertEqual((error as NSError).domain, (expected as NSError).domain)
                    XCTAssertEqual((error as NSError).code, (expected as NSError).code)
                }
                assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                            networks: useFastFallback ? [false, false] : [false])
            }
        }
    }

    func testPermissionErrorsBeatPixelsAndCloudMetadataWithoutFallbackAtEitherLocalStage() async throws {
        let images: [UIImage?] = [nil, try syntheticImage()]
        let errors: [Error] = [AppFailure.permission,
            photosError(PHPhotosError.Code.accessUserDenied.rawValue),
            photosError(PHPhotosError.Code.accessRestricted.rawValue)]
        for useFastFallback in [false, true] {
            for image in images {
                for error in errors {
                    let failure = [PreviewRequestScript.Reply(image: image, info: [
                        PHImageErrorKey: error, PHImageResultIsInCloudKey: true
                    ])]
                    let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], failure] : [failure])
                    do { _ = try await load(requests, networkAllowed: true); XCTFail("Permission must beat pixels.") }
                    catch AppFailure.permission { }
                    catch { XCTFail("Expected normalized permission failure, not \(error).") }
                    assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                                networks: useFastFallback ? [false, false] : [false])
                }
            }
        }
    }

    func testAuthenticationErrorBeatsPixelsWithoutFallbackAtEitherLocalStage() async throws {
        let expected = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
        let images: [UIImage?] = [nil, try syntheticImage()]
        for useFastFallback in [false, true] {
            for image in images {
                let failure = [PreviewRequestScript.Reply(image: image, info: [
                    PHImageErrorKey: expected, PHImageResultIsInCloudKey: true
                ])]
                let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], failure] : [failure])
                do { _ = try await load(requests, networkAllowed: true); XCTFail("Authentication must beat pixels.") }
                catch {
                    XCTAssertEqual((error as NSError).domain, NSURLErrorDomain)
                    XCTAssertEqual((error as NSError).code, NSURLErrorUserAuthenticationRequired)
                }
                assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                            networks: useFastFallback ? [false, false] : [false])
            }
        }
    }

    func testNetworkErrorsIncluding3164AreNotMisclassifiedAsCloudOnlyOrRetried() async {
        for expected in [photosError(3164), NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)] {
            let requests = PreviewRequestScript(stages: [
                [.init(info: [PHImageErrorKey: photosError(3164)])],
                [.init()],
                [.init(info: [PHImageErrorKey: expected, PHImageResultIsInCloudKey: true])]
            ])
            do {
                _ = try await load(requests, networkAllowed: true)
                XCTFail("Expected the real network error.")
            } catch {
                XCTAssertEqual((error as NSError).domain, expected.domain)
                XCTAssertEqual((error as NSError).code, expected.code)
            }
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                        networks: [false, false, true])
        }
    }

    func testNetworkNilCompletesWithoutFurtherRetry() async {
        let requests = PreviewRequestScript(stages: [
            [.init()], [.init()], [.init(info: [PHImageResultIsInCloudKey: true, PHImageResultIsDegradedKey: true])]
        ])
        do {
            _ = try await load(requests, networkAllowed: true)
            XCTFail("Expected no network preview.")
        } catch AppFailure.photo { }
        catch { XCTFail("Network nil must not be reported as offline cloud-only: \(error)") }
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                    networks: [false, false, true])
    }

    func testCancellationMetadataWinsOverUsablePixelsAndNeverFallsBack() async throws {
        let images: [UIImage?] = [nil, try syntheticImage()]
        let infos: [[AnyHashable: Any]] = [
            [PHImageCancelledKey: true, PHImageResultIsInCloudKey: true, PHImageErrorKey: photosError(3164)],
            [PHImageCancelledKey: true, PHImageErrorKey: AppFailure.permission],
            [PHImageCancelledKey: true,
             PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)],
            [PHImageErrorKey: CancellationError()],
            [PHImageErrorKey: photosError(PHPhotosError.Code.userCancelled.rawValue)],
            [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)],
            [PHImageErrorKey: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)]
        ]
        for useFastFallback in [false, true] {
            for image in images {
                for info in infos {
                    let cancelled = [PreviewRequestScript.Reply(image: image, info: info)]
                    let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], cancelled] : [cancelled])
                    do {
                        _ = try await load(requests, networkAllowed: true)
                        XCTFail("Cancellation must win over pixels, permission, authentication and cloud metadata.")
                    } catch { XCTAssertTrue(error is CancellationError) }
                    assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                                networks: useFastFallback ? [false, false] : [false])
                }
            }
        }
    }

    func testAlreadyCancelledTaskDoesNotStartARequest() async {
        let requests = PreviewRequestScript(stages: [[.init()]])
        let run = startPreview(requests, cancelledAtStart: true)
        do { _ = try await finish(run); XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(requests.plans.isEmpty)
        XCTAssertTrue(requests.cancelledIDs.isEmpty)
    }

    func testCancellationBeforeRequestIDWithNoCallbackCancelsEventualID() async {
        let requests = PreviewRequestScript(stages: [[]], cancelBeforeIDAt: 1)
        let run = startPreview(requests)
        do { _ = try await finish(run); XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertEqual(requests.pendingCount, 0)
    }

    func testTaskCancellationRacingSynchronousSuccessWinsBeforeReturn() async throws {
        let requests = PreviewRequestScript(stages: [[.init(image: try syntheticImage())]], cancelBeforeIDAt: 1)
        let run = startPreview(requests)
        do { _ = try await finish(run); XCTFail("A cancelled task must not return pixels.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
    }

    func testTaskCancellationRacingErrorWinsAndDoesNotStartFallback() async {
        for expected in [photosError(3164), NSError(domain: "SyntheticPhotoError", code: 8)] {
            let requests = PreviewRequestScript(stages: [[.init(info: [PHImageErrorKey: expected])]], cancelBeforeIDAt: 1)
            let run = startPreview(requests)
            do { _ = try await finish(run); XCTFail("Cancellation must win over a concurrent error.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.cancelledIDs, [1])
            assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        }
    }

    func testTaskCancellationAfterRequestStartsIgnoresLateCallback() async throws {
        let started = expectation(description: "Preview requested")
        let image = try syntheticImage()
        let requests = PreviewRequestScript(stages: [[]], onRequest: { if $0 == 1 { started.fulfill() } })
        let run = startPreview(requests)
        defer { run.stop() }
        await fulfillment(of: [started], timeout: 2)
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        run.task.cancel()
        XCTAssertTrue(requests.complete(1, with: [.init(image: image), .init()]))
        do { _ = try await finish(run); XCTFail("Late pixels must not override task cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [1])
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertEqual(requests.pendingCount, 0)
    }

    func testSecondStageTaskCancellationIgnoresLateCallbacksAndStartsNoNetworkRequest() async throws {
        let image = try syntheticImage()
        let started = expectation(description: "Fast fallback is pending")
        let requests = PreviewRequestScript(stages: [[.init()], []],
                                           onRequest: { if $0 == 2 { started.fulfill() } })
        let run = startPreview(requests)
        defer { run.stop() }
        await fulfillment(of: [started], timeout: 3)
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        XCTAssertEqual(requests.pendingCount, 1)
        XCTAssertNil(run.result.value)
        run.task.cancel()
        XCTAssertTrue(requests.complete(1, with: [.init(image: image)]))
        XCTAssertTrue(requests.complete(2, with: [.init(image: image), .init(info: [PHImageErrorKey: photosError(3164)])]))
        do { _ = try await finish(run); XCTFail("Second-stage cancellation must beat late pixels.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [2], "Only the active fast request is cancelled, not the completed HQ request.")
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        XCTAssertEqual(requests.pendingCount, 0)
    }

    func testSecondStageCancellationBeforeIDWithNoCallbackCancelsOnlyEventualFastID() async {
        let requests = PreviewRequestScript(stages: [[.init()], []], cancelBeforeIDAt: 2)
        let run = startPreview(requests)
        do { _ = try await finish(run); XCTFail("Expected second-stage pre-ID cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [2])
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        XCTAssertEqual(requests.pendingCount, 0)
    }

    func testSecondStageCancellationRacingSynchronousPixelsWinsBeforeReturn() async throws {
        let requests = PreviewRequestScript(stages: [[.init()], [.init(image: try syntheticImage())]], cancelBeforeIDAt: 2)
        let run = startPreview(requests)
        do { _ = try await finish(run); XCTFail("Fast pixels must not win over task cancellation before ID assignment.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests.cancelledIDs, [2])
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
    }

    func testSecondStageCancellationRacingMissingOrFatalErrorNeverStartsNetwork() async {
        let replies: [PreviewRequestScript.Reply] = [
            .init(), .init(info: [PHImageResultIsDegradedKey: true]),
            .init(info: [PHImageErrorKey: photosError(3164)]),
            .init(info: [PHImageErrorKey: NSError(domain: "SyntheticPhotoError", code: 8)]),
            .init(info: [PHImageErrorKey: AppFailure.permission]),
            .init(info: [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)])
        ]
        for reply in replies {
            let requests = PreviewRequestScript(stages: [[.init()], [reply]], cancelBeforeIDAt: 2)
            let run = startPreview(requests)
            do { _ = try await finish(run); XCTFail("Task cancellation must win over the second-stage error.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.cancelledIDs, [2])
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        }
    }

    func testRequestsAreSequentialAndNetworkCannotStartUntilBothOfflineCallbacksMiss() async throws {
        let image = try syntheticImage()
        let started = (1...3).map { XCTestExpectation(description: "Production request \($0) started") }
        let requests = PreviewRequestScript(stages: [[], [], []], onRequest: { number in
            if (1...3).contains(number) { started[number - 1].fulfill() }
        })
        let run = startPreview(requests)
        defer { run.stop() }
        await fulfillment(of: [started[0]], timeout: 3)
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
        XCTAssertNil(run.result.value)
        XCTAssertTrue(requests.complete(1, with: [.init(info: [PHImageErrorKey: photosError(3164)])]))
        await fulfillment(of: [started[1]], timeout: 3)
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
        XCTAssertNil(run.result.value)
        XCTAssertTrue(requests.complete(2, with: [.init(info: [PHImageResultIsDegradedKey: true])]))
        await fulfillment(of: [started[2]], timeout: 3)
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat], networks: [false, false, true])
        XCTAssertNil(run.result.value)
        XCTAssertTrue(requests.complete(3, with: [.init(image: image)]))
        let result = try await finish(run)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(result.source, .networkPreview)
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat], networks: [false, false, true])
        XCTAssertTrue(requests.cancelledIDs.isEmpty)
    }

    func testLateHQCallbacksAfterFastStartsCannotReplaceOrAbortFastResult() async throws {
        let stale = try syntheticImage(width: 11, height: 5, orientation: .down)
        let fast = try syntheticImage(width: 448, height: 224, orientation: .leftMirrored)
        for late in lateReplies(image: stale) {
            let started = XCTestExpectation(description: "Fast started after HQ miss")
            let requests = PreviewRequestScript(stages: [[.init()], []],
                                               onRequest: { if $0 == 2 { started.fulfill() } })
            let run = startPreview(requests)
            defer { run.stop() }
            await fulfillment(of: [started], timeout: 3)
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            XCTAssertEqual(requests.pendingCount, 1)
            // Retained stage-1 callback is really invoked AFTER stage 2 starts,
            // not merely duplicated synchronously before the fallback exists.
            XCTAssertTrue(requests.complete(1, with: [late]))
            XCTAssertTrue(requests.complete(2, with: [.init(image: fast, info: [PHImageResultIsDegradedKey: false])]))
            let result = try await finish(run)
            XCTAssertTrue(result.cgImage === fast.cgImage)
            XCTAssertFalse(result.cgImage === stale.cgImage)
            XCTAssertEqual(result.orientation, .leftMirrored)
            XCTAssertEqual(result.source, .localPreview)
            XCTAssertEqual(result.photokitDegraded, false)
            XCTAssertEqual(result.requestedSize, target)
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            XCTAssertTrue(requests.cancelledIDs.isEmpty)
        }
    }

    func testLateLocalCallbacksAfterNetworkStartsCannotReplaceOrAbortNetworkResult() async throws {
        let stale = try syntheticImage(width: 448, height: 224, orientation: .down)
        let online = try syntheticImage(width: 17, height: 9, orientation: .rightMirrored)
        for late in lateReplies(image: stale) {
            let started = XCTestExpectation(description: "Network started after two local misses")
            let requests = PreviewRequestScript(stages: [[.init()], [.init()], []],
                                               onRequest: { if $0 == 3 { started.fulfill() } })
            let run = startPreview(requests)
            defer { run.stop() }
            await fulfillment(of: [started], timeout: 3)
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                        networks: [false, false, true])
            XCTAssertEqual(requests.pendingCount, 1)
            XCTAssertTrue(requests.complete(1, with: [late]))
            XCTAssertTrue(requests.complete(2, with: [late]))
            XCTAssertTrue(requests.complete(3, with: [.init(image: online, info: [PHImageResultIsDegradedKey: true])]))
            let result = try await finish(run)
            XCTAssertTrue(result.cgImage === online.cgImage)
            XCTAssertFalse(result.cgImage === stale.cgImage)
            XCTAssertEqual(result.orientation, .rightMirrored)
            XCTAssertEqual(result.source, .networkPreview)
            XCTAssertEqual(result.photokitDegraded, true)
            XCTAssertEqual(result.requestedSize, target)
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                        networks: [false, false, true])
            XCTAssertTrue(requests.cancelledIDs.isEmpty)
        }
    }

    func testFastFirstCallbackKeepsItsPixelsDespiteSynchronousSuccessErrorAndCancellationDuplicates() async throws {
        let first = try syntheticImage(width: 32, height: 16, orientation: .left)
        let later = try syntheticImage(width: 448, height: 224, orientation: .down)
        let requests = PreviewRequestScript(stages: [[.init()], [
            .init(image: first, info: [PHImageResultIsDegradedKey: true]),
            .init(image: later), .init(info: [PHImageErrorKey: AppFailure.permission]),
            .init(info: [PHImageCancelledKey: true]), .init(info: [PHImageErrorKey: photosError(3164)])
        ]])
        let result = try await load(requests, networkAllowed: true)
        XCTAssertTrue(result.cgImage === first.cgImage)
        XCTAssertEqual(result.orientation, .left)
        XCTAssertEqual(result.source, .localReducedPreview)
        XCTAssertEqual(result.photokitDegraded, true)
        assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
    }

    func testUIImageRightOrientationIsPreservedWithoutRotatingOrReencoding() async throws {
        let image = try syntheticImage(orientation: .right)
        let requests = PreviewRequestScript(stages: [[.init(image: image)]])
        let result = try await load(requests)
        XCTAssertEqual(result.orientation, .right)
        XCTAssertTrue(result.cgImage === image.cgImage)
        XCTAssertEqual(result.cgImage.width, 32)
        XCTAssertEqual(result.cgImage.height, 16)
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
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
            assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
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
        assertPlans(requests, deliveries: [.highQualityFormat], networks: [false])
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

    func testUnreadableUIImageAndEmptyOrInfiniteCIImagesRequireTwoOfflineMissesBeforePhotoError() async {
        for first in unreadableImages() {
            for second in unreadableImages() {
                XCTAssertNil(first.cgImage)
                XCTAssertNil(second.cgImage)
                let requests = PreviewRequestScript(stages: [[.init(image: first)], [.init(image: second)]])
                do { _ = try await load(requests); XCTFail("Expected photo failure after both unreadable local previews.") }
                catch AppFailure.photo { }
                catch { XCTFail("Unexpected error: \(error)") }
                assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat], networks: [false, false])
            }
        }
    }

    func testUnreadableLocalImagesUseNetworkOnlyAfterBothLocalStagesMiss() async throws {
        let image = try syntheticImage()
        for unreadable in unreadableImages() {
            let requests = PreviewRequestScript(stages: [
                [.init(image: unreadable)], [.init(image: unreadable)], [.init(image: image)]
            ])
            let result = try await load(requests, networkAllowed: true)
            XCTAssertEqual(result.source, .networkPreview)
            XCTAssertTrue(result.cgImage === image.cgImage)
            assertPlans(requests, deliveries: [.highQualityFormat, .fastFormat, .highQualityFormat],
                        networks: [false, false, true])
        }
    }

    func testUnreadablePixelsWithGenericErrorAndCloudFlagDoNotTriggerFallback() async {
        let expected = NSError(domain: "SyntheticPhotoError", code: 8)
        for useFastFallback in [false, true] {
            for image in unreadableImages() {
                let failure = [PreviewRequestScript.Reply(image: image, info: [
                    PHImageErrorKey: expected, PHImageResultIsInCloudKey: true
                ])]
                let requests = PreviewRequestScript(stages: useFastFallback ? [[.init()], failure] : [failure])
                do { _ = try await load(requests, networkAllowed: true); XCTFail("Unreadable pixels do not erase a real error.") }
                catch {
                    XCTAssertEqual((error as NSError).domain, "SyntheticPhotoError")
                    XCTAssertEqual((error as NSError).code, 8)
                }
                assertPlans(requests, deliveries: useFastFallback ? [.highQualityFormat, .fastFormat] : [.highQualityFormat],
                            networks: useFastFallback ? [false, false] : [false])
            }
        }
    }

    private func load(_ requests: PreviewRequestScript, networkAllowed: Bool = false) async throws -> IndexingImage {
        try await finish(startPreview(requests, networkAllowed: networkAllowed))
    }

    private func startPreview(_ requests: PreviewRequestScript, networkAllowed: Bool = true,
                              cancelledAtStart: Bool = false) -> PreviewRun {
        let target = self.target
        let finished = XCTestExpectation(description: "Production preview operation completed")
        let result = PreviewResult()
        let task = Task {
            if cancelledAtStart { withUnsafeCurrentTask { $0?.cancel() } }
            do {
                let image = try await PreviewImageLoader.load(targetSize: target, networkAllowed: networkAllowed,
                    request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) })
                result.store(.success(image))
            } catch { result.store(.failure(error)) }
            finished.fulfill()
        }
        let run = PreviewRun(task: task, finished: finished, result: result, script: requests)
        addTeardownBlock { run.stop() }
        return run
    }

    private func finish(_ run: PreviewRun) async throws -> IndexingImage {
        defer { run.stop() }
        // Test deadline only: a broken one-shot policy must fail, not hang on task.value.
        // No timeout, sleep, or timing-based fallback is installed in production.
        await fulfillment(of: [run.finished], timeout: 3)
        return try XCTUnwrap(run.result.value, "Preview callback policy did not complete within the XCTest deadline.").get()
    }

    private func unreadableImages() -> [UIImage] {
        [UIImage(), UIImage(ciImage: CIImage.empty()),
         UIImage(ciImage: CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1)))]
    }

    private func missingReplies() -> [PreviewRequestScript.Reply] {
        [.init(), .init(info: [PHImageResultIsDegradedKey: true]),
         .init(info: [PHImageErrorKey: photosError(3164)]),
         .init(info: [PHImageResultIsInCloudKey: true])]
            + unreadableImages().map { .init(image: $0) }
    }

    private func lateReplies(image: UIImage) -> [PreviewRequestScript.Reply] {
        [.init(image: image, info: [PHImageResultIsDegradedKey: false]),
         .init(info: [PHImageResultIsDegradedKey: true]),
         .init(info: [PHImageErrorKey: photosError(3164), PHImageResultIsInCloudKey: true]),
         .init(info: [PHImageErrorKey: NSError(domain: "SyntheticPhotoError", code: 8)]),
         .init(info: [PHImageErrorKey: AppFailure.permission]),
         .init(info: [PHImageErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)]),
         .init(image: image, info: [PHImageCancelledKey: true])]
    }

    private func syntheticImage(width: Int = 32, height: Int = 16,
                                orientation: UIImage.Orientation = .up) throws -> UIImage {
        UIImage(cgImage: try TestFixtures.image(width: width, height: height) { _, _ in (19, 71, 203) },
                scale: 1, orientation: orientation)
    }

    private func photosError(_ code: Int) -> NSError { NSError(domain: PHPhotosErrorDomain, code: code) }

    private func assertPlans(_ requests: PreviewRequestScript, deliveries: [PHImageRequestOptionsDeliveryMode],
                             networks: [Bool], file: StaticString = #filePath, line: UInt = #line) {
        let plans = requests.plans
        XCTAssertEqual(plans.count, deliveries.count, "Unexpected request count.", file: file, line: line)
        XCTAssertEqual(networks.count, deliveries.count, "Invalid test expectation.", file: file, line: line)
        guard plans.count == deliveries.count, networks.count == deliveries.count else { return }
        for index in plans.indices {
            assertPlan(plans[index], delivery: deliveries[index], network: networks[index], file: file, line: line)
            for earlier in 0..<index {
                XCTAssertFalse(plans[index].options === plans[earlier].options,
                               "Each stage needs independent options; do not mutate an earlier request.", file: file, line: line)
            }
        }
    }

    private func assertPlan(_ plan: PreviewRequestScript.Plan, delivery: PHImageRequestOptionsDeliveryMode, network: Bool,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(plan.targetSize, target, file: file, line: line)
        XCTAssertEqual(plan.contentMode, .aspectFit, file: file, line: line)
        XCTAssertEqual(plan.options.isNetworkAccessAllowed, network, file: file, line: line)
        XCTAssertEqual(plan.options.deliveryMode, delivery, file: file, line: line)
        XCTAssertEqual(plan.options.version, .current, file: file, line: line)
        XCTAssertEqual(plan.options.resizeMode, .fast, file: file, line: line)
        XCTAssertFalse(plan.options.isSynchronous, file: file, line: line)
    }
}

/// Synchronous callbacks exercise the continuation-before-request-ID race. Empty
/// stages are explicitly released. Retain all callbacks to deliver earlier-stage
/// duplicates AFTER a fallback starts, not only within the original request call.
/// All mutable state is locked; callbacks and expectations run outside the lock.
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
    private let cancelBeforeIDAt: Int?
    private let onRequest: @Sendable (Int) -> Void
    private var storedPlans: [Plan] = []
    private var storedCancelledIDs: [PHImageRequestID] = []
    private var callbacks: [PHImageRequestID: PreviewImageLoader.Callback] = [:]
    private var pending: Set<PHImageRequestID> = []
    private var closed = false

    init(stages: [[Reply]], cancelBeforeIDAt: Int? = nil, onRequest: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.stages = stages
        self.cancelBeforeIDAt = cancelBeforeIDAt
        self.onRequest = onRequest
    }

    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return storedPlans }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return storedCancelledIDs }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    func request(_ targetSize: CGSize, _ contentMode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping PreviewImageLoader.Callback) -> PHImageRequestID {
        lock.lock()
        let index = storedPlans.count
        let id = PHImageRequestID(index + 1)
        storedPlans.append(Plan(targetSize: targetSize, contentMode: contentMode, options: options))
        let unexpected = !closed && !stages.indices.contains(index)
        let replies: [Reply]
        if closed {
            replies = [.init(info: [PHImageCancelledKey: true])]
        } else if stages.indices.contains(index) {
            replies = stages[index]
            callbacks[id] = callback
            if replies.isEmpty { pending.insert(id) }
        } else {
            replies = [.init(info: [PHImageErrorKey: AppFailure.photo("Unexpected extra preview request.")])]
        }
        lock.unlock()
        if unexpected { XCTFail("Unexpected preview request \(index + 1); the script has only \(stages.count) stages.") }
        onRequest(index + 1)
        for reply in replies { callback(reply.image, reply.info) }
        if cancelBeforeIDAt == index + 1 { withUnsafeCurrentTask { $0?.cancel() } }
        return id
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        storedCancelledIDs.append(id)
        // Keep callbacks: PhotoKit may still deliver after cancellation.
    }

    /// True means the requested callback existed and was actually invoked.
    func complete(_ id: PHImageRequestID, with replies: [Reply]) -> Bool {
        lock.lock()
        let callback = callbacks[id]
        if !replies.isEmpty { pending.remove(id) }
        lock.unlock()
        guard let callback, !replies.isEmpty else { return false }
        for reply in replies { callback(reply.image, reply.info) }
        return true
    }

    func releaseHeldCallbacks() {
        lock.lock()
        closed = true
        let held = pending.compactMap { callbacks[$0] }
        pending.removeAll()
        callbacks.removeAll()
        lock.unlock()
        for callback in held { callback(nil, [PHImageCancelledKey: true]) }
    }
}

private final class PreviewResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<IndexingImage, Error>?
    var value: Result<IndexingImage, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
    func store(_ result: Result<IndexingImage, Error>) { lock.lock(); defer { lock.unlock() }; stored = result }
}

private struct PreviewRun: @unchecked Sendable {
    let task: Task<Void, Never>
    let finished: XCTestExpectation
    let result: PreviewResult
    let script: PreviewRequestScript

    func stop() {
        task.cancel()
        script.releaseHeldCallbacks()
    }
}