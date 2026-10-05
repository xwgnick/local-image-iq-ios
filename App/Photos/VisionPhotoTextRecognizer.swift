import Foundation
import ImageIO
import UIKit
import Vision

/// No request, language capability query, pixels or model work at initialization.
/// Vision's built-in OCR is on-device; networkAllowed controls only PhotoKit pixels.
/// Synchronous Vision work stays on this actor, never MainActor or a detached job
/// whose lifetime could outlive the caller's cancellation/drain boundary.
actor VisionPhotoTextRecognizer: PhotoTextRecognizing {
    typealias ImageLoader = @Sendable (String, Bool) async throws -> DisplayThumbnailResult

    enum Failure: LocalizedError, Sendable {
        case imageUnavailable, revisionUnavailable, languagesUnavailable, recognitionFailed

        var errorDescription: String? {
            switch self {
            case .imageUnavailable:
                return "暂时无法读取照片以识别文字，请重试更新照片文字。"
            case .revisionUnavailable:
                return "当前 iOS 版本不支持所需的文字识别功能，请更新 iOS 后重试。"
            case .languagesUnavailable:
                return "当前 iOS 版本无法识别中文和英文，请更新 iOS 后重试。"
            case .recognitionFailed:
                return "暂时无法完成本机文字识别，请重试更新照片文字。"
            }
        }
    }

    /// Internal injection seam for synthetic-image native tests and deterministic
    /// lifecycle tests. Production defaults ALWAYS perform the actual Vision request.
    /// All closures run synchronously on the actor except cancel, which may race
    /// perform using VNRequest's cancellation API. Never mutate configuration there.
    struct ImageRecognition: Sendable {
        static let languages = ["zh-Hans", "zh-Hant", "en-US"]

        var makeRequest: @Sendable () -> VNRecognizeTextRequest = { VNRecognizeTextRequest() }
        var supportedRevisions: @Sendable () -> IndexSet = { VNRecognizeTextRequest.supportedRevisions }
        var supportedLanguages: @Sendable (VNRecognizeTextRequest) throws -> [String] = {
            try $0.supportedRecognitionLanguages()
        }
        var perform: @Sendable (VNRecognizeTextRequest, IndexingImage) throws -> Void = { request, image in
            try VNImageRequestHandler(cgImage: image.cgImage, orientation: image.orientation,
                                      options: [:]).perform([request])
        }
        var cancel: @Sendable (VNRecognizeTextRequest) -> Void = { $0.cancel() }

        func configuredRequest() throws -> VNRecognizeTextRequest {
            try Task.checkCancellation()
            guard supportedRevisions().contains(VNRecognizeTextRequestRevision3) else {
                throw Failure.revisionUnavailable
            }
            let request = makeRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.recognitionLanguages = Self.languages
            request.automaticallyDetectsLanguage = false
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0
            let supported: [String]
            do {
                // Query the actual revision-3 accurate request, not a launch-time
                // global/default-revision capability list or a language download API.
                supported = try supportedLanguages(request)
            } catch {
                try Task.checkCancellation()
                if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
                throw Failure.languagesUnavailable
            }
            try Task.checkCancellation()
            guard Self.languages.allSatisfy(supported.contains) else { throw Failure.languagesUnavailable }
            return request
        }
    }

    struct ImageInput: Sendable {
        let image: IndexingImage
        let isReduced: Bool

        /// Actual oriented raster dimensions, never UIImage points or requested size.
        var pixelWidth: Int { swapsAxes ? image.cgImage.height : image.cgImage.width }
        var pixelHeight: Int { swapsAxes ? image.cgImage.width : image.cgImage.height }

        private var swapsAxes: Bool {
            switch image.orientation {
            case .left, .leftMirrored, .right, .rightMirrored: return true
            default: return false
            }
        }
    }

    private let loadImage: ImageLoader
    private let imageRecognition: ImageRecognition

    init(library: PhotoLibraryClient) {
        loadImage = { id, networkAllowed in
            try await library.textRecognitionImage(id: id, networkAllowed: networkAllowed)
        }
        imageRecognition = ImageRecognition()
    }

    /// Inject only pixels for a real Vision test; optional work hooks are for
    /// deterministic error/cancellation tests, not a substitute for native OCR tests.
    init(loadImage: @escaping ImageLoader, imageRecognition: ImageRecognition = ImageRecognition()) {
        self.loadImage = loadImage
        self.imageRecognition = imageRecognition
    }

    func recognize(id: String, networkAllowed: Bool) async throws -> RecognizedPhotoText {
        try Task.checkCancellation()
        let loaded: DisplayThumbnailResult
        do {
            loaded = try await loadImage(id, networkAllowed)
        } catch {
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
            if let failure = error as? AppFailure {
                switch failure {
                case .permission: throw AppFailure.permission
                case .cloudOnly: throw AppFailure.cloudOnly
                default: break
                }
            }
            // Do not propagate PhotoKit descriptions, asset identifiers or paths.
            throw Failure.imageUnavailable
        }
        try Task.checkCancellation()
        let input = try Self.imageInput(loaded)
        let cancellation = RequestCancellation(cancelRequest: imageRecognition.cancel)
        return try await withTaskCancellationHandler(operation: {
            try recognizeImage(input, cancellation: cancellation)
        }, onCancel: { cancellation.cancel() })
    }

    private func recognizeImage(_ input: ImageInput, cancellation: RequestCancellation) throws -> RecognizedPhotoText {
        defer { cancellation.finish() }
        try Task.checkCancellation()
        let request = try imageRecognition.configuredRequest()
        cancellation.install(request)
        try Task.checkCancellation()
        do {
            // Intentionally synchronous: cancellation requests cancel(), but cannot
            // resume a continuation early or declare the Vision work drained.
            try imageRecognition.perform(request, input.image)
        } catch {
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
            throw Failure.recognitionFailed
        }
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        try Task.checkCancellation()
        return RecognizedPhotoText(text: text, pixelWidth: input.pixelWidth,
                                   pixelHeight: input.pixelHeight, isReduced: input.isReduced)
    }

    static func imageInput(_ result: DisplayThumbnailResult) throws -> ImageInput {
        // DisplayThumbnailLoader already renders finite CI images without resizing.
        guard let pixels = result.image.cgImage, pixels.width > 0, pixels.height > 0 else {
            throw Failure.imageUnavailable
        }
        // The loader computes coverage against the FULL native target, including
        // when HQ224 wins. Fast/unknown/degraded and either undersized axis remain
        // reduced; there is no pixel-quality cutoff and even tiny images get OCR.
        let reduced = !result.isReusable
        return ImageInput(image: IndexingImage(cgImage: pixels,
            orientation: orientation(result.image.imageOrientation),
            source: reduced ? .localReducedPreview : (result.stage == .networkHQ ? .networkPreview : .localPreview),
            requestedSize: result.requestedSize, photokitDegraded: result.degraded), isReduced: reduced)
    }

    /// Same eight-case mapping as PreviewImageLoader's private conversion. Keep
    /// UIKit enum raw values out of EXIF: left/right/mirrored values differ.
    private static func orientation(_ value: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch value {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    /// Only request.cancel() may cross the actor boundary. Configuration/results
    /// stay actor-owned; lock-protected lifecycle handles cancellation before install
    /// and after finish, without a lock around the long synchronous perform call.
    private final class RequestCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private let cancelRequest: @Sendable (VNRecognizeTextRequest) -> Void
        private var request: VNRecognizeTextRequest?
        private var cancelled = false
        private var finished = false

        init(cancelRequest: @escaping @Sendable (VNRecognizeTextRequest) -> Void) {
            self.cancelRequest = cancelRequest
        }

        func install(_ request: VNRecognizeTextRequest) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            self.request = request
            let mustCancel = cancelled
            lock.unlock()
            if mustCancel { cancelRequest(request) }
        }

        func cancel() {
            lock.lock()
            guard !cancelled, !finished else { lock.unlock(); return }
            cancelled = true
            let active = request
            lock.unlock()
            if let active { cancelRequest(active) }
        }

        func finish() {
            lock.lock()
            finished = true
            request = nil
            lock.unlock()
        }
    }
}