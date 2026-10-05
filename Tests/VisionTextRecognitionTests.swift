import XCTest
import CoreImage
import ImageIO
import Photos
import UIKit
import Vision
@testable import LocalImageIQ

/// Synthetic pixels only: no PHAsset fetch, permissions, private photos, downloads,
/// screenshots or model fixture dependency. The four native tests are mandatory
/// XCTest cases (no simulator/model-availability skip or mocked OCR output).
final class VisionTextRecognitionTests: XCTestCase {
    private typealias Recognizer = VisionPhotoTextRecognizer
    private typealias Reply = OCRImageRequests.Reply
    private let nativeSize = CGSize(width: 640, height: 320)
    private let quality224 = CGSize(width: 448, height: 224)

    func testSharedPolicyVersion() {
        XCTAssertEqual(PhotoTextPolicy.version, "vision-ocr-r3-accurate-zh-en-fit-v1")
    }

    func testInitializationDoesNotLoadPixelsConstructRequestsOrQueryCapabilities() {
        let probe = OCRProbe()
        var work = Recognizer.ImageRecognition()
        work.makeRequest = { probe.hit("request"); return VNRecognizeTextRequest() }
        work.supportedRevisions = { probe.hit("revisions"); return IndexSet(integer: 3) }
        work.supportedLanguages = { _ in probe.hit("languages"); return Recognizer.ImageRecognition.languages }
        work.perform = { _, _ in probe.hit("perform") }
        let service = Recognizer(loadImage: { _, _ in
            probe.hit("pixels")
            throw Recognizer.Failure.imageUnavailable
        }, imageRecognition: work)
        withExtendedLifetime(service) {
            for key in ["pixels", "request", "revisions", "languages", "perform"] {
                XCTAssertEqual(probe.count(key), 0, key)
            }
        }
    }

    func testNativeRequestUsesSupportedRevisionThreeAccurateChineseAndEnglish() throws {
        let request = try Recognizer.ImageRecognition().configuredRequest()
        XCTAssertEqual(request.revision, VNRecognizeTextRequestRevision3)
        XCTAssertEqual(request.recognitionLevel, .accurate)
        XCTAssertEqual(request.recognitionLanguages, ["zh-Hans", "zh-Hant", "en-US"])
        XCTAssertFalse(request.automaticallyDetectsLanguage)
        XCTAssertTrue(request.usesLanguageCorrection)
        XCTAssertEqual(request.minimumTextHeight, 0)
        let supported = try request.supportedRecognitionLanguages()
        for language in request.recognitionLanguages { XCTAssertTrue(supported.contains(language), language) }
    }

    @MainActor
    func testNativeVisionServiceRecognizesSyntheticEnglish() async throws {
        let pixels = try Self.textPixels()
        let image = UIImage(cgImage: pixels, scale: 3, orientation: .up)
        let loaded = result(image, target: CGSize(width: 1600, height: 420))
        let service: any PhotoTextRecognizing = Recognizer(loadImage: { id, network in
            XCTAssertEqual(id, "synthetic-coffee")
            XCTAssertFalse(network)
            return loaded
        })
        let recognized = try await service.recognize(id: "synthetic-coffee", networkAllowed: false)
        XCTAssertTrue(recognized.text.uppercased().contains("COFFEE"))
        XCTAssertTrue(recognized.text.contains("3817"))
        XCTAssertEqual(recognized.pixelWidth, 1600)
        XCTAssertEqual(recognized.pixelHeight, 420)
        XCTAssertFalse(recognized.isReduced)
    }

    @MainActor
    func testNativeVisionServiceRecognizesSyntheticChinese() async throws {
        let pixels = try Self.textPixels("星巴克咖啡 3817")
        let image = UIImage(cgImage: pixels, scale: 3, orientation: .up)
        let loaded = result(image, target: CGSize(width: 1600, height: 420))
        // Inject only synthetic pixels; use the production configured request and real Vision OCR.
        let service: any PhotoTextRecognizing = Recognizer(loadImage: { id, network in
            XCTAssertEqual(id, "synthetic-chinese-coffee")
            XCTAssertFalse(network)
            return loaded
        })
        let recognized = try await service.recognize(id: "synthetic-chinese-coffee", networkAllowed: false)
        XCTAssertTrue(recognized.text.contains("星巴克"))
        XCTAssertTrue(recognized.text.contains("3817"))
        XCTAssertEqual(recognized.pixelWidth, 1600)
        XCTAssertEqual(recognized.pixelHeight, 420)
        XCTAssertFalse(recognized.isReduced)
    }

    @MainActor
    func testNativeVisionServiceRecognizesEXIFRotatedSyntheticEnglish() async throws {
        let upright = try Self.textPixels()
        // Physically rotate the raster left; EXIF right restores the original.
        // Supplying .up instead would leave vertical text and reversed dimensions.
        let rotated = CIImage(cgImage: upright).oriented(.left)
        let pixels = try XCTUnwrap(CIContext().createCGImage(rotated, from: rotated.extent))
        XCTAssertEqual(pixels.width, 420)
        XCTAssertEqual(pixels.height, 1600)
        let image = UIImage(cgImage: pixels, scale: 2, orientation: .right)
        let loaded = result(image, target: CGSize(width: 1600, height: 420))
        let service = Recognizer(loadImage: { _, _ in loaded })
        let recognized = try await service.recognize(id: "synthetic-rotated", networkAllowed: false)
        XCTAssertTrue(recognized.text.uppercased().contains("COFFEE"))
        XCTAssertTrue(recognized.text.contains("3817"))
        XCTAssertEqual(recognized.pixelWidth, 1600)
        XCTAssertEqual(recognized.pixelHeight, 420)
        XCTAssertFalse(recognized.isReduced)
    }

    func testNativeVisionBlankImageIsSuccessfulEmptyText() async throws {
        let image = try syntheticImage(width: 640, height: 320)
        let loaded = result(image)
        let service = Recognizer(loadImage: { _, _ in loaded })
        let recognized = try await service.recognize(id: "synthetic-blank", networkAllowed: false)
        XCTAssertEqual(recognized.text, "")
        XCTAssertEqual(recognized.pixelWidth, 640)
        XCTAssertEqual(recognized.pixelHeight, 320)
        XCTAssertFalse(recognized.isReduced)
    }

    func testAllEightUIImageOrientationsPreservePixelsAndReportOrientedDimensions() throws {
        let orientations: [(UIImage.Orientation, CGImagePropertyOrientation, Bool)] = [
            (.up, .up, false), (.upMirrored, .upMirrored, false),
            (.down, .down, false), (.downMirrored, .downMirrored, false),
            (.left, .left, true), (.leftMirrored, .leftMirrored, true),
            (.right, .right, true), (.rightMirrored, .rightMirrored, true)
        ]
        for (ui, exif, swapped) in orientations {
            let image = try syntheticImage(width: 64, height: 32, scale: 3, orientation: ui)
            let target = swapped ? CGSize(width: 32, height: 64) : CGSize(width: 64, height: 32)
            let input = try Recognizer.imageInput(result(image, target: target))
            XCTAssertTrue(input.image.cgImage === image.cgImage)
            XCTAssertEqual(input.image.orientation, exif)
            XCTAssertEqual(input.pixelWidth, swapped ? 32 : 64)
            XCTAssertEqual(input.pixelHeight, swapped ? 64 : 32)
            XCTAssertFalse(input.isReduced)
        }
    }

    func testReducedStatusCoversBothAxesDegradedAndFastOrUnknownSources() throws {
        let image = try syntheticImage(width: 64, height: 32)
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ, .localFast224, .unknown]
        let flags: [Bool?] = [nil, false, true]
        let targets = [CGSize(width: 64, height: 32), CGSize(width: 65, height: 32), CGSize(width: 64, height: 33)]
        for stage in stages {
            for flag in flags {
                for (index, target) in targets.enumerated() {
                    let input = try Recognizer.imageInput(result(image, target: target, stage: stage, degraded: flag))
                    XCTAssertEqual(input.isReduced, index != 0 || flag == true || stage == .localFast224 || stage == .unknown)
                    XCTAssertEqual(input.pixelWidth, 64)
                    XCTAssertEqual(input.pixelHeight, 32)
                }
            }
        }
    }

    func testTinyDegradedPixelsStillReachRecognitionWithoutQualityCutoff() async throws {
        let image = try syntheticImage(width: 1, height: 1)
        let loaded = result(image, stage: .localFast224, degraded: true)
        let probe = OCRProbe()
        var work = noInferenceWork()
        work.perform = { _, input in
            probe.hit("perform")
            XCTAssertEqual(input.cgImage.width, 1)
            XCTAssertEqual(input.cgImage.height, 1)
        }
        let service = Recognizer(loadImage: { _, _ in loaded }, imageRecognition: work)
        let recognized = try await service.recognize(id: "synthetic-tiny", networkAllowed: false)
        XCTAssertEqual(probe.count("perform"), 1)
        XCTAssertEqual(recognized.text, "")
        XCTAssertEqual(recognized.pixelWidth, 1)
        XCTAssertTrue(recognized.isReduced)
    }

    func testUnreadableImageFailsBeforeConstructingVisionRequest() async {
        let probe = OCRProbe()
        var work = noInferenceWork()
        work.makeRequest = { probe.hit("request"); return VNRecognizeTextRequest() }
        let loaded = DisplayThumbnailResult.unverified(image: UIImage(), targetSize: nativeSize)
        let service = Recognizer(loadImage: { _, _ in loaded }, imageRecognition: work)
        do { _ = try await service.recognize(id: "synthetic-empty", networkAllowed: false); XCTFail("Expected failure.") }
        catch { assertFailure(error, .imageUnavailable) }
        XCTAssertEqual(probe.count("request"), 0)
    }

    func testUnsupportedRevisionIsActionableAndDoesNotConstructRequest() {
        let probe = OCRProbe()
        var work = noInferenceWork()
        work.supportedRevisions = { IndexSet(integer: 2) }
        work.makeRequest = { probe.hit("request"); return VNRecognizeTextRequest() }
        do { _ = try work.configuredRequest(); XCTFail("Must not silently use a different revision.") }
        catch { assertFailure(error, .revisionUnavailable) }
        XCTAssertEqual(probe.count("request"), 0)
        XCTAssertTrue(Recognizer.Failure.revisionUnavailable.localizedDescription.contains("更新 iOS"))
    }

    func testEachRequiredLanguageIsCheckedOnConfiguredAccurateRequest() {
        for missing in Recognizer.ImageRecognition.languages {
            var work = noInferenceWork()
            work.supportedLanguages = { request in
                XCTAssertEqual(request.revision, VNRecognizeTextRequestRevision3)
                XCTAssertEqual(request.recognitionLevel, .accurate)
                return Recognizer.ImageRecognition.languages.filter { $0 != missing }
            }
            do { _ = try work.configuredRequest(); XCTFail("Must not silently fall back to a language subset.") }
            catch { assertFailure(error, .languagesUnavailable) }
        }
    }

    func testCapabilityErrorsAreSanitized() {
        var work = noInferenceWork()
        work.supportedLanguages = { _ in throw Self.privateError }
        do { _ = try work.configuredRequest(); XCTFail("Expected failure.") }
        catch { assertFailure(error, .languagesUnavailable) }
        XCTAssertTrue(Recognizer.Failure.languagesUnavailable.localizedDescription.contains("更新 iOS"))
    }

    func testImageAndVisionErrorsNeverExposeDescriptionsOrPaths() async throws {
        let loaded = result(try syntheticImage())
        var work = noInferenceWork()
        work.perform = { _, _ in throw Self.privateError }
        let vision = Recognizer(loadImage: { _, _ in loaded }, imageRecognition: work)
        do { _ = try await vision.recognize(id: "synthetic", networkAllowed: false); XCTFail("Expected failure.") }
        catch { assertFailure(error, .recognitionFailed) }
        let errors: [Error] = [Self.privateError, AppFailure.photo("synthetic-private-content")]
        for expected in errors {
            let pixels = Recognizer(loadImage: { _, _ in throw expected }, imageRecognition: noInferenceWork())
            do { _ = try await pixels.recognize(id: "synthetic", networkAllowed: false); XCTFail("Expected failure.") }
            catch { assertFailure(error, .imageUnavailable) }
        }
    }

    func testPhotoAccessCloudOnlyAndCancellationKeepTheirClassifications() async {
        let failures: [Error] = [AppFailure.permission, AppFailure.cloudOnly, CancellationError()]
        for (index, failure) in failures.enumerated() {
            let service = Recognizer(loadImage: { _, _ in throw failure }, imageRecognition: noInferenceWork())
            do { _ = try await service.recognize(id: "synthetic", networkAllowed: false); XCTFail("Expected failure.") }
            catch {
                switch index {
                case 0: guard case AppFailure.permission = error else { XCTFail("Lost permission failure."); continue }
                case 1: guard case AppFailure.cloudOnly = error else { XCTFail("Lost cloud-only failure."); continue }
                default: XCTAssertTrue(error is CancellationError)
                }
            }
        }
    }

    func testAlreadyCancelledCallerDoesNoPixelOrVisionWork() async {
        let probe = OCRProbe()
        let service = Recognizer(loadImage: { _, _ in
            probe.hit("pixels")
            throw Self.privateError
        }, imageRecognition: noInferenceWork())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.recognize(id: "synthetic", networkAllowed: false)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.count("pixels"), 0)
    }

    func testCancellationRacingPixelSuccessPreventsVisionConstruction() async throws {
        let loaded = result(try syntheticImage())
        let probe = OCRProbe()
        var work = noInferenceWork()
        work.makeRequest = { probe.hit("request"); return VNRecognizeTextRequest() }
        let service = Recognizer(loadImage: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return loaded
        }, imageRecognition: work)
        let task = Task { try await service.recognize(id: "synthetic", networkAllowed: false) }
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.count("request"), 0)
    }

    func testCancellationDuringCapabilityQueryNeverPerformsRecognition() async throws {
        let loaded = result(try syntheticImage())
        let probe = OCRProbe()
        var work = noInferenceWork()
        work.supportedLanguages = { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Recognizer.ImageRecognition.languages
        }
        work.perform = { _, _ in probe.hit("perform") }
        let service = Recognizer(loadImage: { _, _ in loaded }, imageRecognition: work)
        let task = Task { try await service.recognize(id: "synthetic", networkAllowed: false) }
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probe.count("perform"), 0)
    }

    @MainActor
    func testCancellationCallsRequestCancelButWaitsForSynchronousWorkToDrain() async throws {
        let loaded = result(try syntheticImage())
        // Exercise both a late successful perform and a late framework error.
        for failsAfterRelease in [false, true] {
            let started = expectation(description: "Synchronous recognition entered")
            let cancelled = expectation(description: "Request cancellation forwarded")
            let release = DispatchSemaphore(value: 0)
            let probe = OCRProbe()
            var work = noInferenceWork()
            work.perform = { _, _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                release.wait()
                probe.hit("drained")
                if failsAfterRelease { throw Self.privateError }
            }
            work.cancel = { request in
                request.cancel()
                probe.hit("cancel")
                cancelled.fulfill()
            }
            let service = Recognizer(loadImage: { _, _ in loaded }, imageRecognition: work)
            let task = Task.detached {
                defer { probe.hit("returned") }
                return try await service.recognize(id: "synthetic", networkAllowed: false)
            }
            defer { release.signal(); task.cancel() }
            await fulfillment(of: [started], timeout: 5)
            task.cancel()
            await fulfillment(of: [cancelled], timeout: 5)
            XCTAssertEqual(probe.count("cancel"), 1)
            XCTAssertEqual(probe.count("drained"), 0)
            XCTAssertEqual(probe.count("returned"), 0, "Cancellation must not pretend synchronous Vision work drained.")
            release.signal()
            do { _ = try await task.value; XCTFail("Late success/error must not undo cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(probe.count("drained"), 1)
            XCTAssertEqual(probe.count("returned"), 1)
        }
    }

    func testRecognizerPassesCapturedNetworkFlagAndDoesNotAutoRetryReducedPixels() async throws {
        let loaded = result(try syntheticImage(width: 16, height: 8), stage: .localFast224, degraded: true)
        let probe = OCRProbe()
        let service = Recognizer(loadImage: { id, allowed in
            XCTAssertEqual(id, "synthetic")
            probe.hit(allowed ? "online" : "offline")
            return loaded
        }, imageRecognition: noInferenceWork())
        for allowed in [false, true] {
            let value = try await service.recognize(id: "synthetic", networkAllowed: allowed)
            XCTAssertTrue(value.isReduced)
        }
        XCTAssertEqual(probe.count("offline"), 1)
        XCTAssertEqual(probe.count("online"), 1)
    }

    func testOCRLoaderRequestsNativeFullImageOfflineFirstEvenWhenOptedIn() async throws {
        let image = try syntheticImage(width: 640, height: 320)
        for allowed in [false, true] {
            let script = OCRImageRequests(stages: [[Reply(image: image)]])
            let loaded = try await load(script, networkAllowed: allowed)
            XCTAssertTrue(loaded.image === image)
            XCTAssertEqual(loaded.stage, .localHQ)
            XCTAssertTrue(loaded.isReusable)
            assertPlans(script, networks: [false], fastLast: false)
        }
    }

    func testOfflineAllStagesUseAspectFitAndAcceptDegradedFastWithoutRejectingPixels() async throws {
        let image = try syntheticImage(width: 64, height: 32)
        let script = OCRImageRequests(stages: [[Reply()], [Reply()], [Reply(image: image, info: [PHImageResultIsDegradedKey: true])]])
        let validations = OCRProbe()
        let loaded = try await load(script, validate: { validations.hit("validate") })
        XCTAssertTrue(loaded.image === image)
        XCTAssertEqual(loaded.stage, .localFast224)
        XCTAssertTrue(try Recognizer.imageInput(loaded).isReduced)
        XCTAssertEqual(validations.count("validate"), 5, "Before load, each of three stages, and after load.")
        assertPlans(script, networks: [false, false, false], fastLast: true)
    }

    func testOptInNetworkHQPrecedesFastAndAllFourStagesUseAspectFit() async throws {
        let image = try syntheticImage(width: 64, height: 32)
        let script = OCRImageRequests(stages: [[Reply()], [Reply()], [Reply()], [Reply(image: image)]])
        let loaded = try await load(script, networkAllowed: true)
        XCTAssertEqual(loaded.stage, .localFast224)
        assertPlans(script, networks: [false, false, true, false], fastLast: true)
    }

    func testNetworkHQStillWaitsForFinalCallbackAndRetainsNativeTarget() async throws {
        let small = try syntheticImage(width: 64, height: 32)
        let full = try syntheticImage(width: 640, height: 320)
        let script = OCRImageRequests(stages: [[Reply()], [Reply()], [
            Reply(image: small, info: [PHImageResultIsDegradedKey: true]),
            Reply(image: full, info: [PHImageResultIsDegradedKey: false])
        ]])
        let loaded = try await load(script, networkAllowed: true)
        XCTAssertTrue(loaded.image === full)
        XCTAssertEqual(loaded.stage, .networkHQ)
        XCTAssertFalse(try Recognizer.imageInput(loaded).isReduced)
        assertPlans(script, networks: [false, false, true], fastLast: false)
    }

    func testHQPreferenceKeepsNonDegradedCandidateAndNeverUsesFastToMaskHQ() async throws {
        let larger = try syntheticImage(width: 128, height: 64)
        let smaller = try syntheticImage(width: 64, height: 32)
        let script = OCRImageRequests(stages: [
            [Reply(image: larger, info: [PHImageResultIsDegradedKey: true])],
            [Reply(image: smaller, info: [PHImageResultIsDegradedKey: false])]
        ])
        let loaded = try await load(script)
        XCTAssertTrue(loaded.image === smaller)
        XCTAssertEqual(loaded.stage, .localHQ224)
        XCTAssertTrue(try Recognizer.imageInput(loaded).isReduced)
        assertPlans(script, networks: [false, false], fastLast: false)
    }

    func testHQ224CoverageIsStillComparedWithFullNativeTarget() async throws {
        let image = try syntheticImage(width: 448, height: 224)
        let script = OCRImageRequests(stages: [[Reply()], [Reply(image: image)]])
        let loaded = try await load(script)
        XCTAssertEqual(loaded.requestedSize, quality224)
        XCTAssertEqual(loaded.returnedSize, quality224)
        XCTAssertFalse(loaded.isSufficientForDisplay)
        let input = try Recognizer.imageInput(loaded)
        XCTAssertEqual(input.pixelWidth, 448)
        XCTAssertEqual(input.pixelHeight, 224)
        XCTAssertTrue(input.isReduced)
    }

    func testNativePixelRequestHasNoArbitrarySizeCeiling() async throws {
        // Large request metadata only; allocate no large raster in this test.
        let image = try syntheticImage(width: 64, height: 32)
        let script = OCRImageRequests(stages: [[Reply(image: image)], [Reply()]])
        let loaded = try await PhotoLibraryClient.textRecognitionImage(
            pixelWidth: 27000, pixelHeight: 18000, networkAllowed: false,
            request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
        XCTAssertEqual(script.plans.first?.target, CGSize(width: 27000, height: 18000))
        XCTAssertEqual(script.plans.last?.target, CGSize(width: 336, height: 224))
        XCTAssertTrue(try Recognizer.imageInput(loaded).isReduced)
    }

    func testValidationFailureBetweenStagesStopsBeforeNextPixelRequest() async {
        let script = OCRImageRequests(stages: [[Reply()]])
        let probe = OCRProbe()
        do {
            _ = try await load(script, validate: {
                if probe.hit("validate") == 3 { throw CancellationError() }
            })
            XCTFail("Expected invalidation.")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(script.plans.count, 1)
    }

    func testAccessIsRevalidatedAfterSuccessfulPixels() async throws {
        let script = OCRImageRequests(stages: [[Reply(image: try syntheticImage(width: 640, height: 320))]])
        let probe = OCRProbe()
        do {
            _ = try await load(script, validate: {
                if probe.hit("validate") == 3 { throw AppFailure.permission }
            })
            XCTFail("Expected access failure after pixels.")
        } catch AppFailure.permission { }
        catch { XCTFail("Lost permission classification.") }
        XCTAssertEqual(probe.count("validate"), 3)
        XCTAssertEqual(script.plans.count, 1)
    }

    func testOrdinaryErrorAfterHQPixelsStillStopsWithoutFallback() async throws {
        let image = try syntheticImage(width: 64, height: 32)
        let script = OCRImageRequests(stages: [[Reply(image: image)], [Reply(info: [PHImageErrorKey: Self.privateError])]])
        do { _ = try await load(script, networkAllowed: true); XCTFail("Earlier pixels must not mask errors.") }
        catch { XCTAssertEqual((error as NSError).domain, Self.privateError.domain) }
        XCTAssertEqual(script.plans.count, 2)
    }

    func testExhaustedOfflineRequestsPreserveCloudOnlyWithoutEnablingNetwork() async {
        let cloud = Reply(info: [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164)])
        let script = OCRImageRequests(stages: [[cloud], [cloud], [cloud]])
        do { _ = try await load(script); XCTFail("Expected cloud-only.") }
        catch AppFailure.cloudOnly { }
        catch { XCTFail("Lost cloud-only classification.") }
        assertPlans(script, networks: [false, false, false], fastLast: true)
    }

    func testPhotoRequestCancellationBeforeIDAssignmentCancelsEventualID() async {
        let script = OCRImageRequests(stages: [[]], cancelBeforeID: true)
        addTeardownBlock { script.releaseCallbacks() }
        let task = Task { try await self.load(script) }
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(script.cancelledIDs, [1])
        XCTAssertEqual(script.plans.count, 1)
    }

    func testPendingPhotoRequestCancellationIgnoresLatePixelsAndStartsNoNextStage() async throws {
        let started = expectation(description: "Photo request registered")
        let script = OCRImageRequests(stages: [[]], started: started)
        addTeardownBlock { script.releaseCallbacks() }
        let task = Task { try await self.load(script, networkAllowed: true) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        script.completeFirst(Reply(image: try syntheticImage(width: 640, height: 320)))
        do { _ = try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(script.cancelledIDs, [1])
        XCTAssertEqual(script.plans.count, 1)
    }

    func testInvalidNativeDimensionsDoNotInventACroppedOrMaximumSizeRequest() async {
        let script = OCRImageRequests(stages: [])
        do {
            _ = try await PhotoLibraryClient.textRecognitionImage(pixelWidth: 0, pixelHeight: 320,
                networkAllowed: false, request: { script.request($0, $1, $2, $3) }, cancel: { script.cancel($0) })
            XCTFail("Expected invalid metadata.")
        } catch AppFailure.photo { }
        catch { XCTFail("Unexpected failure classification.") }
        XCTAssertTrue(script.plans.isEmpty)
    }

    // MARK: - Synthetic fixtures and assertions

    @MainActor
    private static func textPixels(_ text: String = "COFFEE 3817") throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 420), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 420))
            (text as NSString).draw(at: CGPoint(x: 120, y: 120), withAttributes: [
                // UIKit's system font fallback supplies Chinese glyphs as well as Latin text.
                .font: UIFont.systemFont(ofSize: 124, weight: .bold),
                .foregroundColor: UIColor.black
            ])
        }
        return try XCTUnwrap(image.cgImage)
    }

    private func syntheticImage(width: Int = 64, height: Int = 32, scale: CGFloat = 1,
                                orientation: UIImage.Orientation = .up) throws -> UIImage {
        UIImage(cgImage: try TestFixtures.image(width: width, height: height) { _, _ in (255, 255, 255) },
                scale: scale, orientation: orientation)
    }

    private func result(_ image: UIImage, target: CGSize? = nil, stage: DisplayThumbnailStage = .localHQ,
                        degraded: Bool? = false) -> DisplayThumbnailResult {
        DisplayThumbnailResult(image: image, stage: stage, requestedSize: target ?? nativeSize,
            returnedSize: image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            degraded: degraded, targetSize: target ?? nativeSize)
    }

    private func noInferenceWork() -> Recognizer.ImageRecognition {
        var work = Recognizer.ImageRecognition()
        work.supportedRevisions = { IndexSet(integer: VNRecognizeTextRequestRevision3) }
        work.supportedLanguages = { _ in Recognizer.ImageRecognition.languages }
        work.perform = { _, _ in }
        return work
    }

    private static var privateError: NSError {
        NSError(domain: "SyntheticOCRError", code: 17,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-content /synthetic/private-photo-path"])
    }

    private func assertFailure(_ error: Error, _ expected: Recognizer.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error is Recognizer.Failure, file: file, line: line)
        XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        XCTAssertFalse(error.localizedDescription.contains("synthetic-private"), file: file, line: line)
    }

    private func load(_ script: OCRImageRequests, networkAllowed: Bool = false,
                      validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        try await PhotoLibraryClient.textRecognitionImage(pixelWidth: 640, pixelHeight: 320,
            networkAllowed: networkAllowed, request: { script.request($0, $1, $2, $3) },
            cancel: { script.cancel($0) }, validate: validate)
    }

    private func assertPlans(_ script: OCRImageRequests, networks: [Bool], fastLast: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        let plans = script.plans
        XCTAssertEqual(plans.count, networks.count, file: file, line: line)
        guard plans.count == networks.count else { return }
        for (index, plan) in plans.enumerated() {
            let fast = fastLast && index == plans.count - 1
            let shortEdge = index == 1 || fast
            XCTAssertEqual(plan.target, shortEdge ? quality224 : nativeSize, file: file, line: line)
            XCTAssertEqual(plan.mode, .aspectFit, file: file, line: line)
            XCTAssertEqual(plan.options.version, .current, file: file, line: line)
            XCTAssertEqual(plan.options.deliveryMode, fast ? .fastFormat : .highQualityFormat, file: file, line: line)
            XCTAssertEqual(plan.options.resizeMode, shortEdge ? .fast : .exact, file: file, line: line)
            XCTAssertEqual(plan.options.isNetworkAccessAllowed, networks[index], file: file, line: line)
            XCTAssertFalse(plan.options.isSynchronous, file: file, line: line)
            for previous in 0..<index {
                XCTAssertFalse(plan.options === plans[previous].options, file: file, line: line)
            }
        }
    }
}

/// Test-only locked counters; no actor hop is needed from synchronous Vision hooks.
private final class OCRProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    @discardableResult
    func hit(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        counts[key, default: 0] += 1
        return counts[key, default: 0]
    }

    func count(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[key, default: 0]
    }
}

/// Small callback script around the EXISTING production loader, not a second
/// loader implementation. Images/options are immutable; only pending callbacks,
/// recorded plans and cancellation IDs are mutable, under the lock.
private final class OCRImageRequests: @unchecked Sendable {
    struct Reply {
        var image: UIImage? = nil
        var info: [AnyHashable: Any]? = nil
    }
    struct Plan {
        let target: CGSize
        let mode: PHImageContentMode
        let options: PHImageRequestOptions
    }

    private let lock = NSLock()
    private let stages: [[Reply]]
    private let cancelBeforeID: Bool
    private let started: XCTestExpectation?
    private var recordedPlans: [Plan] = []
    private var recordedCancelledIDs: [PHImageRequestID] = []
    private var pending: DisplayThumbnailLoader.Callback?

    init(stages: [[Reply]], cancelBeforeID: Bool = false, started: XCTestExpectation? = nil) {
        self.stages = stages
        self.cancelBeforeID = cancelBeforeID
        self.started = started
    }

    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return recordedPlans }
    var cancelledIDs: [PHImageRequestID] { lock.lock(); defer { lock.unlock() }; return recordedCancelledIDs }

    func request(_ target: CGSize, _ mode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping DisplayThumbnailLoader.Callback) -> PHImageRequestID {
        lock.lock()
        let index = recordedPlans.count
        recordedPlans.append(Plan(target: target, mode: mode, options: options))
        let expected = stages.indices.contains(index)
        let replies = expected ? stages[index] : [Reply(info: [PHImageErrorKey: AppFailure.photo("Unexpected OCR image request.")])]
        if replies.isEmpty { pending = callback }
        lock.unlock()
        if !expected { XCTFail("Unexpected extra OCR pixel request.") }
        started?.fulfill()
        for reply in replies { callback(reply.image, reply.info) }
        if cancelBeforeID { withUnsafeCurrentTask { $0?.cancel() } }
        return PHImageRequestID(index + 1)
    }

    func cancel(_ id: PHImageRequestID) {
        lock.lock(); defer { lock.unlock() }
        recordedCancelledIDs.append(id)
    }

    func completeFirst(_ reply: Reply) {
        lock.lock()
        let callback = pending
        pending = nil
        lock.unlock()
        callback?(reply.image, reply.info)
    }

    func releaseCallbacks() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}