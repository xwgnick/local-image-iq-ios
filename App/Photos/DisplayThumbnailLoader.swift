import Foundation
import CoreGraphics
import CoreImage
import Photos
import UIKit

/// Request policy for result tiles only. Asset access, caching and presentation
/// belong to the caller; this loader performs no PhotoKit reads of its own.
enum DisplayThumbnailLoader {
    typealias Callback = (UIImage?, [AnyHashable: Any]?) -> Void
    typealias Request = @Sendable (CGSize, PHImageContentMode, PHImageRequestOptions, @escaping Callback) -> PHImageRequestID

    private enum MissingResource: Error { case requiresNetwork, noResource }
    private static let ciContext = CIContext()

    /// PhotoKit sizes are pixels, not points. Reject invalid geometry instead of
    /// inventing a square/default size; valid subpixel sizes request one pixel.
    static func targetSize(points: CGSize, displayScale: CGFloat) -> CGSize? {
        guard points.width.isFinite, points.height.isFinite, displayScale.isFinite,
              points.width > 0, points.height > 0, displayScale > 0 else { return nil }
        let width = points.width * displayScale
        let height = points.height * displayScale
        guard width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(1, width.rounded(.up)), height: max(1, height.rounded(.up)))
    }

    /// Always start with local HQ. On missing resources only:
    /// - offline: local HQ -> local Fast;
    /// - explicit opt-in: local HQ -> network HQ -> local Fast.
    /// Fast must not mask an opted-in HQ upgrade. Ordinary errors (including real
    /// network failures), permission failures and cancellation never fall back.
    static func load(targetSize: CGSize, networkAllowed: Bool,
                     request: @escaping Request,
                     cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> UIImage {
        var stages: [(delivery: PHImageRequestOptionsDeliveryMode, network: Bool)] = [(.highQualityFormat, false)]
        if networkAllowed { stages.append((.highQualityFormat, true)) }
        stages.append((.fastFormat, false))
        var needsNetwork = false
        for stage in stages {
            try Task.checkCancellation()
            do {
                let image = try await loadStage(targetSize: targetSize, delivery: stage.delivery,
                                                network: stage.network, request: request, cancel: cancel)
                try Task.checkCancellation()
                return image
            } catch {
                try Task.checkCancellation()
                guard let missing = error as? MissingResource else { throw error }
                if case .requiresNetwork = missing { needsNetwork = true }
            }
        }
        try Task.checkCancellation()
        if needsNetwork { throw AppFailure.cloudOnly }
        throw AppFailure.photo("No preview is available.")
    }

    private static func loadStage(targetSize: CGSize, delivery: PHImageRequestOptionsDeliveryMode,
                                  network: Bool, request: @escaping Request,
                                  cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> UIImage {
        try Task.checkCancellation()
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = delivery
        options.resizeMode = delivery == .highQualityFormat ? .exact : .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = network
        let gate = PhotoRequestGate<UIImage>(cancelRequest: cancel)
        let firstCallback = CallbackClaim()
        let result: UIImage = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let id = request(targetSize, .aspectFill, options) { image, info in
                    let cancelled = PhotoImageRequestInfo.isCancellation(info)
                    let error = info?[PHImageErrorKey] as? Error
                    let resourceError = error.map { PhotoImageRequestInfo.requiresNetwork($0) } ?? false
                    // Match the existing network display contract: provisional
                    // degraded callbacks do not finish an opted-in HQ request.
                    // PhotoKit highQualityFormat normally supplies one final
                    // result; a provider sending only provisional results must
                    // eventually finish or be cancelled. No deadline is invented.
                    // Cancellation/errors still take precedence over degradation.
                    if network, PhotoImageRequestInfo.flag(PHImageResultIsDegradedKey, info),
                       !cancelled, error == nil || (resourceError && image != nil) { return }
                    // Claim before CI rendering, so concurrent duplicates cannot
                    // replace a chosen callback while its pixels are being read.
                    guard firstCallback.claim() else { return }
                    if cancelled {
                        gate.finish(.failure(CancellationError()))
                        return
                    }
                    if let error, !resourceError {
                        gate.finish(.failure(isPermissionFailure(error) ? AppFailure.permission : error))
                        return
                    }
                    if let image, let readable = readableImage(image) {
                        // Local HQ/Fast accept one-shot reduced pixels, just like
                        // indexing. Request HQ first, but do not discard the best
                        // local result or wait indefinitely for another callback.
                        // A cloud flag/3164 alone cannot invalidate usable pixels.
                        gate.finish(.success(readable))
                    } else {
                        // Same missing-resource classification as the preview
                        // helper: nil/unreadable pixels, cloud flag, Photos 3164.
                        // A cloud flag never reclassifies an ordinary error.
                        let missing: MissingResource = resourceError
                            || PhotoImageRequestInfo.flag(PHImageResultIsInCloudKey, info)
                            ? .requiresNetwork : .noResource
                        gate.finish(.failure(missing))
                    }
                }
                gate.setRequestID(id)
            }
        }, onCancel: { gate.cancel() })
        try Task.checkCancellation()
        return result
    }

    private static func isPermissionFailure(_ error: Error) -> Bool {
        if let failure = error as? AppFailure, case .permission = failure { return true }
        let error = error as NSError
        return error.domain == PHPhotosErrorDomain
            && (error.code == PHPhotosError.Code.accessUserDenied.rawValue
                || error.code == PHPhotosError.Code.accessRestricted.rawValue)
    }

    /// Match the index helper's readable-pixel test, preserving scale/orientation
    /// and avoiding resize, crop, upsampling or an encode/decode round trip.
    private static func readableImage(_ image: UIImage) -> UIImage? {
        if image.cgImage != nil { return image }
        guard let ciImage = image.ciImage else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty, !extent.isNull, !extent.isInfinite,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.width.isFinite, extent.height.isFinite,
              let pixels = ciContext.createCGImage(ciImage, from: extent) else { return nil }
        return UIImage(cgImage: pixels, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Only this flag is mutable, under the lock; the shared gate owns completion.
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