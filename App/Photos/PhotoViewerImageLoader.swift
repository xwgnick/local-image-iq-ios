import Foundation
import CoreImage
import Photos
import UIKit

/// Display-only authority. Creation time and byte-exact identity are part of the
/// revision; neither a surviving ID nor an unchanged modification time suffices.
struct PhotoViewerSnapshot: Sendable, Equatable {
    let revision: PhotoRevision
    let authorization: PHAuthorizationStatus
    let generation: UInt64?

    func validate(id: String, authorization readAuthorization: () -> PHAuthorizationStatus,
                  generation readGeneration: () -> UInt64?,
                  currentRevision: (String) -> PhotoRevision?) throws {
        try Task.checkCancellation()
        func checkAccess() throws {
            let access = readAuthorization()
            guard access == .authorized || access == .limited else { throw AppFailure.permission }
            guard access == authorization, readGeneration() == generation else { throw CancellationError() }
        }
        try checkAccess()
        guard revision.id.utf8.elementsEqual(id.utf8) else { throw CancellationError() }
        let current = currentRevision(id)
        // A metadata read can itself race authorization or a Photos notification.
        try checkAccess()
            guard let current, current == revision,
              current.id.utf8.elementsEqual(id.utf8) else { throw CancellationError() }
        try Task.checkCancellation()
    }
}

struct PhotoViewerImage: @unchecked Sendable {
    let snapshot: PhotoViewerSnapshot
    let result: DisplayThumbnailResult
}

/// Closure factory permits synthetic request/presentation tests without PHAsset,
/// private Photos access or replacing PhotoLibraryClient's indexing behavior.
struct PhotoViewerImageSource: Sendable {
    let load: @Sendable (String, Bool) async throws -> PhotoViewerImage
    let validate: @Sendable (PhotoViewerSnapshot) throws -> Void
    let asset: (@Sendable (String) throws -> PhotoViewerAsset)?
    let upgrade: (@Sendable (PhotoViewerAsset, CGSize, Bool) async throws -> PhotoViewerImage)?

    init(library: PhotoLibraryClient) {
        load = { try await library.viewerImage(id: $0, networkAllowed: $1) }
        validate = { try library.validateViewerSnapshot($0, id: $0.revision.id) }
        asset = { try library.viewerAsset(id: $0) }
        upgrade = { try await library.viewerUpgrade(asset: $0, targetSize: $1, cloudConsent: $2) }
    }

    init(load: @escaping @Sendable (String, Bool) async throws -> PhotoViewerImage,
         validate: @escaping @Sendable (PhotoViewerSnapshot) throws -> Void,
         asset: (@Sendable (String) throws -> PhotoViewerAsset)? = nil,
         upgrade: (@Sendable (PhotoViewerAsset, CGSize, Bool) async throws -> PhotoViewerImage)? = nil) {
        self.load = load
        self.validate = validate
        self.asset = asset
        self.upgrade = upgrade
    }
}

/// The existing HQ224 first-image contract remains independent of upgrades.
/// A readable result completes immediately; the viewer publishes it BEFORE
/// asking for any additional pixels. No embedding/index policy changes.
enum PhotoViewerImageLoader {
    private static let ciContext = CIContext()

    static func load(pixelWidth: Int, pixelHeight: Int, networkAllowed: Bool,
                     request: @escaping DisplayThumbnailLoader.Request,
                     cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                     validate: @escaping @Sendable () throws -> Void) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        try validate()
        let target = LocalPreviewComparisonLoader.targetSize(width: pixelWidth, height: pixelHeight, shortEdge: 224)
        // Preserve local HQ -> opted-in cloud HQ -> Fast only if no HQ supplied
        // usable pixels. With the switch off, both requests stay strictly local.
        let stages: [DisplayThumbnailStage] = networkAllowed
            ? [.localHQ224, .networkHQ, .localFast224] : [.localHQ224, .localFast224]
        var attempts: [DisplayThumbnailAttempt] = []
        var needsNetwork = false
        for stage in stages {
            try Task.checkCancellation()
            try validate()
            let delivery = try await read(stage: stage, target: target, request: request, cancel: cancel)
            try Task.checkCancellation()
            try validate()
            try Task.checkCancellation()
            attempts.append(delivery.attempt)
            needsNetwork = needsNetwork || delivery.needsNetwork
            if let image = delivery.image, let size = delivery.attempt.returnedSize {
                // Any readable local HQ result is displayed immediately, including
                // undersized/degraded pixels. Metadata stays honest; no forced Fast
                // or network upgrade and no promise of 224 actual pixels.
                return DisplayThumbnailResult(image: image, stage: stage, requestedSize: target,
                    returnedSize: size, degraded: delivery.attempt.degraded, attempts: attempts, targetSize: target)
            }
        }
        if needsNetwork { throw AppFailure.cloudOnly }
        throw AppFailure.photo("No preview is available.")
    }

    /// One rendition request only. Automatic callers pass false; true belongs
    /// exclusively to a consumed single-photo confirmation, not a global option.
    /// Missing/error/undersized results never discard the viewer's prior image.
    static func upgrade(targetSize: CGSize, cloudConsent: Bool,
                        request: @escaping DisplayThumbnailLoader.Request,
                        cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                        validate: @escaping @Sendable () throws -> Void) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        try validate()
        guard let target = DisplayThumbnailLoader.targetSize(points: targetSize, displayScale: 1) else {
            throw AppFailure.photo("Invalid viewer image size.")
        }
        let stage: DisplayThumbnailStage = cloudConsent ? .networkHQ : .localHQ
        let delivery = try await read(stage: stage, target: target, resizeMode: .exact,
                                      request: request, cancel: cancel)
        try Task.checkCancellation()
        try validate()
        try Task.checkCancellation()
        guard let image = delivery.image, let size = delivery.attempt.returnedSize else {
            if delivery.needsNetwork { throw AppFailure.cloudOnly }
            throw AppFailure.photo("No higher resolution preview is available.")
        }
        return DisplayThumbnailResult(image: image, stage: stage, requestedSize: target,
            returnedSize: size, degraded: delivery.attempt.degraded,
            attempts: [delivery.attempt], targetSize: target)
    }

    private struct Delivery: @unchecked Sendable {
        let image: UIImage?
        let attempt: DisplayThumbnailAttempt
        let needsNetwork: Bool
    }

    private static func read(stage: DisplayThumbnailStage, target: CGSize,
                             resizeMode: PHImageRequestOptionsResizeMode = .fast,
                             request: @escaping DisplayThumbnailLoader.Request,
                             cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> Delivery {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = stage == .localFast224 ? .fastFormat : .highQualityFormat
        options.resizeMode = resizeMode
        options.isSynchronous = false
        options.isNetworkAccessAllowed = stage == .networkHQ
        let gate = PhotoRequestGate<Delivery>(cancelRequest: cancel)
        let claim = CallbackClaim()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let id = request(target, .aspectFit, options) { image, info in
                    let cancelled = PhotoImageRequestInfo.isCancellation(info)
                    let error = info?[PHImageErrorKey] as? Error
                    let resourceError = error.map { PhotoImageRequestInfo.requiresNetwork($0) } ?? false
                    // Keep the established network HQ contract: a provisional
                    // callback is not completion. Errors/cancellation still win.
                    if stage == .networkHQ, PhotoImageRequestInfo.flag(PHImageResultIsDegradedKey, info),
                       !cancelled, error == nil || (resourceError && image != nil) { return }
                    guard claim.take() else { return }
                    if cancelled { gate.finish(.failure(CancellationError())); return }
                    if let error, !resourceError {
                        let nsError = error as NSError
                        let permission = nsError.domain == PHPhotosErrorDomain
                            && (nsError.code == PHPhotosError.Code.accessUserDenied.rawValue
                                || nsError.code == PHPhotosError.Code.accessRestricted.rawValue)
                        gate.finish(.failure(permission ? AppFailure.permission : error))
                        return
                    }
                    let readable = image.flatMap(readableImage)
                    let size = readable?.cgImage.map { CGSize(width: $0.width, height: $0.height) }
                    let needsNetwork = readable == nil && (resourceError || PhotoImageRequestInfo.flag(PHImageResultIsInCloudKey, info))
                    let attempt = DisplayThumbnailAttempt(stage: stage, requestedSize: target,
                        returnedSize: size, degraded: (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue,
                        outcome: readable != nil ? "native return" : (needsNetwork ? "需网络" : "无可用像素"))
                    gate.finish(.success(Delivery(image: readable, attempt: attempt, needsNetwork: needsNetwork)))
                }
                // The shared gate cancels this ID even if cancellation happened
                // synchronously inside request(), before it returned the ID.
                gate.setRequestID(id)
            }
        }, onCancel: { gate.cancel() })
    }

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

    private final class CallbackClaim: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}