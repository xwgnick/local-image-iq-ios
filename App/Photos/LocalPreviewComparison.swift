import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Photos
import UIKit

enum LocalPreviewMode: String, CaseIterable, Sendable, Identifiable {
    // Declaration order is the diagnostic request order, not a quality ranking.
    case fast224, quality224, quality480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast224: return "Fast 224"
        case .quality224: return "High quality 224"
        case .quality480: return "High quality 480"
        }
    }

    var shortEdge: Int {
        switch self {
        case .fast224, .quality224: return 224
        case .quality480: return 480
        }
    }
}

struct LocalPreviewEntry: Sendable {
    let mode: LocalPreviewMode
    let requestedSize: CGSize
    /// Actual returned pixels and orientation, not resized/rotated for presentation.
    let preview: IndexingImage?
    let issue: String?
}

/// In-memory diagnostic only; neither index inputs nor display policy are changed.
/// The parent UI must disclose that these requests do NOT bypass PhotoKit/OS caches:
/// fast224 runs first and may warm those caches for the two high-quality requests.
/// Requested size/delivery mode does not guarantee that many pixels or more detail.
struct LocalPreviewComparison: Sendable {
    let photoID: String
    let revision: PhotoRevision
    let authorizationRawValue: Int
    let entries: [LocalPreviewEntry]
}

protocol LocalPreviewComparing: Sendable {
    func compareLocalPreviews(id: String) async throws -> LocalPreviewComparison
    /// Recheck before presenting an awaited result; no model or storage access.
    func isCurrent(_ comparison: LocalPreviewComparison) -> Bool
}

/// Injectable requestImage-only diagnostic, separate from PreviewImageLoader.load.
/// No original-data request, network fallback, retry, application image cache or I/O.
enum LocalPreviewComparisonLoader {
    // Fixed messages deliberately exclude PhotoKit error descriptions/userInfo,
    // which can contain asset identifiers or filesystem paths.
    static let issueNeedsNetwork = "No local preview is available. Network access is required; no download was requested."
    static let issueUnavailable = "PhotoKit returned no usable local preview."
    static let issueFailed = "PhotoKit could not provide this local preview."

    private static let ciContext = CIContext()

    /// Preserve valid asset aspect ratios. Invalid metadata uses a square;
    /// an invalid short edge uses the baseline 224 pixels, never maximum size.
    static func targetSize(width: Int, height: Int, shortEdge: Int) -> CGSize {
        let edge = CGFloat(shortEdge > 0 ? shortEdge : 224)
        let square = CGSize(width: edge, height: edge)
        guard width > 0, height > 0 else { return square }
        let longEdge = edge * CGFloat(max(width, height)) / CGFloat(min(width, height))
        guard longEdge.isFinite, longEdge >= edge else { return square }
        return width <= height ? CGSize(width: edge, height: longEdge)
            : CGSize(width: longEdge, height: edge)
    }

    static func compare(id: String, revision: PhotoRevision, authorizationRawValue: Int,
                        pixelWidth: Int, pixelHeight: Int,
                        request: @escaping PreviewImageLoader.Request,
                        cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                        validate: @escaping @Sendable () -> Bool) async throws -> LocalPreviewComparison {
        var entries: [LocalPreviewEntry] = []
        for mode in LocalPreviewMode.allCases {
            try checkCurrent(validate)
            let target = targetSize(width: pixelWidth, height: pixelHeight, shortEdge: mode.shortEdge)
            let entry: LocalPreviewEntry
            do {
                entry = try await load(mode: mode, target: target, request: request, cancel: cancel)
            } catch {
                // Task or callback cancellation remains cancellation even if the
                // snapshot also became invalid while the request was finishing.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                try checkCurrent(validate)
                throw error
            }
            try checkCurrent(validate)
            entries.append(entry)
        }
        try checkCurrent(validate)
        return LocalPreviewComparison(photoID: id, revision: revision,
                                      authorizationRawValue: authorizationRawValue, entries: entries)
    }

    private static func checkCurrent(_ validate: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        let current = validate()
        try Task.checkCancellation()
        guard current else {
            throw AppFailure.photo("Photo access or the photo changed during comparison. Run the comparison again.")
        }
    }

    private static func load(mode: LocalPreviewMode, target: CGSize,
                             request: @escaping PreviewImageLoader.Request,
                             cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> LocalPreviewEntry {
        try Task.checkCancellation()
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = mode == .fast224 ? .fastFormat : .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = false

        let gate = PhotoRequestGate<LocalPreviewEntry>(cancelRequest: cancel)
        let firstCallback = CallbackClaim()
        let result: LocalPreviewEntry
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    if Task.isCancelled { gate.cancel(); return }
                    let id = request(target, .aspectFit, options) { image, info in
                        // Claim before CI conversion so even concurrent duplicate
                        // callbacks cannot replace the first accepted callback.
                        guard firstCallback.claim() else { return }
                        if PhotoImageRequestInfo.isCancellation(info) {
                            gate.finish(.failure(CancellationError()))
                            return
                        }
                        let error = info?[PHImageErrorKey] as? Error
                        if let error, isPermissionFailure(error) {
                            gate.finish(.failure(AppFailure.permission))
                            return
                        }
                        if let image, let pixels = cgImage(from: image) {
                            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue
                            let reduced = (degraded ?? false)
                                || CGFloat(min(pixels.width, pixels.height)) < min(target.width, target.height)
                            let preview = IndexingImage(cgImage: pixels,
                                                        orientation: orientation(image.imageOrientation),
                                                        source: reduced ? .localReducedPreview : .localPreview,
                                                        requestedSize: target, photokitDegraded: degraded)
                            // BOTH delivery modes complete on the first callback,
                            // including degraded=true. Missing flags remain unknown.
                            gate.finish(.success(LocalPreviewEntry(mode: mode, requestedSize: target,
                                                                   preview: preview, issue: nil)))
                            return
                        }
                        let issue: String
                        if let error {
                            issue = PhotoImageRequestInfo.requiresNetwork(error) ? issueNeedsNetwork : issueFailed
                        } else if PhotoImageRequestInfo.flag(PHImageResultIsInCloudKey, info) {
                            issue = issueNeedsNetwork
                        } else {
                            // Includes nil+nil and an unreadable UIImage. Do not
                            // wait indefinitely for a nonexistent second callback.
                            issue = issueUnavailable
                        }
                        gate.finish(.success(LocalPreviewEntry(mode: mode, requestedSize: target,
                                                               preview: nil, issue: issue)))
                    }
                    gate.setRequestID(id)
                }
            }, onCancel: { gate.cancel() })
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return result
    }

    private static func isPermissionFailure(_ error: Error) -> Bool {
        if let failure = error as? AppFailure, case .permission = failure { return true }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain
            && (nsError.code == PHPhotosError.Code.accessUserDenied.rawValue
                || nsError.code == PHPhotosError.Code.accessRestricted.rawValue)
    }

    // Match the existing loader's conversion without changing its private helpers.
    // No application resize, upsample, crop, orientation bake-in or re-encoding.
    private static func cgImage(from image: UIImage) -> CGImage? {
        if let pixels = image.cgImage { return pixels }
        if let ciImage = image.ciImage {
            let extent = ciImage.extent
            guard !extent.isEmpty, !extent.isNull, !extent.isInfinite,
                  extent.origin.x.isFinite, extent.origin.y.isFinite,
                  extent.width.isFinite, extent.height.isFinite else { return nil }
            return ciContext.createCGImage(ciImage, from: extent)
        }
        return nil
    }

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

    /// Only this flag is mutable; PhotoRequestGate owns completion/cancellation.
    private final class CallbackClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}