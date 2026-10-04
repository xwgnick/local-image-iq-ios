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

    private enum Outcome: String {
        case nativeReturn = "native return", requiresNetwork = "需网络", noResource = "无可用像素"
    }

    private struct StageResult: Sendable {
        let candidate: DisplayThumbnailResult?
        let attempt: DisplayThumbnailAttempt
        let needsNetwork: Bool
    }
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

    /// Compatibility only: the old interface knows tile aspect, not asset aspect.
    /// Production callers should use loadResult with the asset's HQ224 target.
    static func load(targetSize: CGSize, networkAllowed: Bool,
                     request: @escaping Request,
                     cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> UIImage {
        let quality224Target: CGSize
        if targetSize.width <= targetSize.height {
            quality224Target = CGSize(width: 224, height: 224 * targetSize.height / targetSize.width)
        } else {
            quality224Target = CGSize(width: 224 * targetSize.width / targetSize.height, height: 224)
        }
        return try await loadResult(targetSize: targetSize, quality224Target: quality224Target,
                                    networkAllowed: networkAllowed, request: request, cancel: cancel).image
    }

    /// Local display HQ -> exact HQ224 contract -> optional network display HQ.
    /// Fast224 is used only if no HQ request supplied readable pixels. Reduced
    /// local callbacks finish that request, not the entire selection strategy.
    /// Ordinary errors, permission failures and cancellation always propagate,
    /// even if an earlier request supplied a usable candidate.
    static func loadResult(targetSize: CGSize, quality224Target: CGSize, networkAllowed: Bool,
                           request: @escaping Request,
                           cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> DisplayThumbnailResult {
        var stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224]
        if networkAllowed { stages.append(.networkHQ) }
        stages.append(.localFast224)
        var best: DisplayThumbnailResult?
        var attempts: [DisplayThumbnailAttempt] = []
        var needsNetwork = false
        for stage in stages {
            try Task.checkCancellation()
            if stage == .localFast224, best != nil { break }
            let size = stage == .localHQ224 || stage == .localFast224 ? quality224Target : targetSize
            let result: StageResult
            do {
                result = try await loadStage(stage: stage, requestedSize: size, targetSize: targetSize,
                                             request: request, cancel: cancel)
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            attempts.append(result.attempt)
            needsNetwork = needsNetwork || result.needsNetwork
            if let candidate = result.candidate {
                if let current = best {
                    if prefers(candidate, over: current, targetSize: targetSize) { best = candidate }
                } else {
                    best = candidate
                }
            }
            if let best, best.isSufficientForDisplay, best.degraded != true { break }
        }
        try Task.checkCancellation()
        if let best {
            return DisplayThumbnailResult(image: best.image, stage: best.stage,
                requestedSize: best.requestedSize, returnedSize: best.returnedSize,
                degraded: best.degraded, attempts: attempts, targetSize: targetSize)
        }
        if needsNetwork { throw AppFailure.cloudOnly }
        throw AppFailure.photo("No preview is available.")
    }

    private static func prefers(_ candidate: DisplayThumbnailResult, over current: DisplayThumbnailResult,
                                targetSize: CGSize) -> Bool {
        if (candidate.degraded == true) != (current.degraded == true) { return candidate.degraded != true }
        let candidateCoverage = DisplayThumbnailResult.displayCoverage(returnedSize: candidate.returnedSize,
            orientation: candidate.image.imageOrientation, targetSize: targetSize)
        let currentCoverage = DisplayThumbnailResult.displayCoverage(returnedSize: current.returnedSize,
            orientation: current.image.imageOrientation, targetSize: targetSize)
        return candidateCoverage > currentCoverage // Ties retain the first callback's candidate.
    }

    private static func loadStage(stage: DisplayThumbnailStage, requestedSize: CGSize, targetSize: CGSize,
                                  request: @escaping Request,
                                  cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> StageResult {
        try Task.checkCancellation()
        let network = stage == .networkHQ
        let shortEdge224 = stage == .localHQ224 || stage == .localFast224
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = stage == .localFast224 ? .fastFormat : .highQualityFormat
        options.resizeMode = shortEdge224 ? .fast : .exact
        options.isSynchronous = false
        options.isNetworkAccessAllowed = network
        let gate = PhotoRequestGate<StageResult>(cancelRequest: cancel)
        let firstCallback = CallbackClaim()
        let result: StageResult = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let id = request(requestedSize, shortEdge224 ? .aspectFit : .aspectFill, options) { image, info in
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
                    let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue
                    if let image, let readable = readableImage(image), let pixels = readable.cgImage {
                        // Retain raw raster metadata before orientation. Local
                        // reduced pixels are candidates, not reasons to skip HQ224.
                        // A cloud flag/3164 alone cannot invalidate usable pixels.
                        let returnedSize = CGSize(width: pixels.width, height: pixels.height)
                        let attempt = DisplayThumbnailAttempt(stage: stage, requestedSize: requestedSize,
                            returnedSize: returnedSize, degraded: degraded, outcome: Outcome.nativeReturn.rawValue)
                        let candidate = DisplayThumbnailResult(image: readable, stage: stage,
                            requestedSize: requestedSize, returnedSize: returnedSize, degraded: degraded,
                            targetSize: targetSize)
                        gate.finish(.success(StageResult(candidate: candidate, attempt: attempt, needsNetwork: false)))
                    } else {
                        // Same missing-resource classification as the preview
                        // helper: nil/unreadable pixels, cloud flag, Photos 3164.
                        // A cloud flag never reclassifies an ordinary error.
                        let needsNetwork = resourceError
                            || PhotoImageRequestInfo.flag(PHImageResultIsInCloudKey, info)
                        let outcome: Outcome = needsNetwork ? .requiresNetwork : .noResource
                        let attempt = DisplayThumbnailAttempt(stage: stage, requestedSize: requestedSize,
                            returnedSize: nil, degraded: degraded, outcome: outcome.rawValue)
                        gate.finish(.success(StageResult(candidate: nil, attempt: attempt, needsNetwork: needsNetwork)))
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