import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Photos
import UIKit

struct IndexingImage: @unchecked Sendable {
    enum Source: String, Sendable {
        case localPreview, localReducedPreview, networkPreview
    }

    let cgImage: CGImage
    let orientation: CGImagePropertyOrientation
    let source: Source
    let requestedSize: CGSize?
    let photokitDegraded: Bool?

    /// Defaults keep synthetic/legacy callers compatible; unknown is not false.
    init(cgImage: CGImage, orientation: CGImagePropertyOrientation, source: Source,
         requestedSize: CGSize? = nil, photokitDegraded: Bool? = nil) {
        self.cgImage = cgImage
        self.orientation = orientation
        self.source = source
        self.requestedSize = requestedSize
        self.photokitDegraded = photokitDegraded
    }
}

enum IndexImagePolicy {
    static let version = "photokit-hq224-fast-fallback-v1"

    static func cacheVersion(modelVersion: String) -> String {
        modelVersion + "|" + version
    }
}

/// Only a resolved administrative label leaves the lookup; never raw GPS.
enum PhotoPlaceResult: Sendable, Equatable {
    case resolved(String), noGPS, noPack, outsideCoverage, unavailable
}

protocol PhotoLibraryIndexing: Sendable {
    var canReadImages: Bool { get }
    /// Optional for existing test libraries; production also detects full/limited
    /// permission transitions that happen to leave the same authorized image IDs.
    var authorizationStatusRawValue: Int? { get }
    /// Changes synchronously when a PhotoKit notification arrives, before its
    /// MainActor callback is scheduled. Nil for legacy injected test libraries.
    var changeGeneration: UInt64? { get }
    func enumerateAuthorizedImages() throws -> [PhotoRevision]
    func currentRevision(id: String) -> PhotoRevision?
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String?
    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage
}

extension PhotoLibraryIndexing {
    var authorizationStatusRawValue: Int? { nil }
    var changeGeneration: UInt64? { nil }

    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult {
        // Legacy/test libraries cannot distinguish missing GPS from other causes.
        guard let label = placeLabel(id: id, resolver: resolver) else { return .unavailable }
        return .resolved(label)
    }
}

extension PhotoLibraryClient {
    var authorizationStatusRawValue: Int? { Self.authorization.rawValue }
}

/// Shared classification for previews and the retained original-data/parity API.
enum PhotoImageRequestInfo {
    static func flag(_ key: String, _ info: [AnyHashable: Any]?) -> Bool {
        (info?[key] as? NSNumber)?.boolValue ?? false
    }

    static func requiresNetwork(_ error: Error) -> Bool {
        let error = error as NSError
        // PHPhotosErrorDomain 3164 = networkAccessRequired; the cloud flag may be absent.
        return error.domain == PHPhotosErrorDomain && error.code == 3164
    }

    static func isCancellation(_ info: [AnyHashable: Any]?) -> Bool {
        if flag(PHImageCancelledKey, info) { return true }
        guard let error = info?[PHImageErrorKey] as? Error else { return false }
        return isCancellation(error)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return (nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue)
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError)
    }
}

/// This is the production callback policy, also injectable without PHAsset or photo access.
/// There is deliberately no original-data request in this interface or fallback path.
enum PreviewImageLoader {
    typealias Callback = @Sendable (UIImage?, [AnyHashable: Any]?) -> Void
    typealias Request = @Sendable (CGSize, PHImageContentMode, PHImageRequestOptions, @escaping Callback) -> PHImageRequestID

    private enum LocalMissing: Error { case requiresNetwork, noResource }
    private static let ciContext = CIContext()

    static func targetSize(pixelWidth: Int, pixelHeight: Int) -> CGSize {
        // Invalid/missing metadata still gets a model-sized request, never maximum/original size.
        guard pixelWidth > 0, pixelHeight > 0 else { return CGSize(width: 224, height: 224) }
        let longEdge = CGFloat(224) * CGFloat(max(pixelWidth, pixelHeight)) / CGFloat(min(pixelWidth, pixelHeight))
        return pixelWidth <= pixelHeight ? CGSize(width: 224, height: longEdge)
            : CGSize(width: longEdge, height: 224)
    }

    static func load(targetSize: CGSize, networkAllowed: Bool,
                     request: @escaping Request,
                     cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> IndexingImage {
        var needsNetwork = false
        // Both local stages use the same short-edge-224 target. Only an actual
        // missing resource advances the sequence, never a generic/auth error.
        let localModes: [PHImageRequestOptionsDeliveryMode] = [.highQualityFormat, .fastFormat]
        for delivery in localModes {
            try Task.checkCancellation()
            do {
                let image = try await loadStage(targetSize: targetSize, delivery: delivery, network: false,
                                                request: request, cancel: cancel)
                try Task.checkCancellation()
                return image
            } catch {
                try Task.checkCancellation()
                guard let missing = error as? LocalMissing else { throw error }
                if case .requiresNetwork = missing { needsNetwork = true }
            }
        }
        try Task.checkCancellation()
        guard networkAllowed else {
            if needsNetwork { throw AppFailure.cloudOnly }
            throw AppFailure.photo("PhotoKit returned no local preview.")
        }
        // Only the existing explicit opt-in permits a network request, after
        // BOTH local representations were missing. Real network errors stay raw.
        do {
            let image = try await loadStage(targetSize: targetSize, delivery: .highQualityFormat, network: true,
                                            request: request, cancel: cancel)
            try Task.checkCancellation()
            return image
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func loadStage(targetSize: CGSize, delivery: PHImageRequestOptionsDeliveryMode, network: Bool,
                                  request: @escaping Request,
                                  cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> IndexingImage {
        try Task.checkCancellation()
        // Fresh options for each stage; never mutate options belonging to an active request.
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = delivery
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = network
        let gate = PhotoRequestGate<IndexingImage>(cancelRequest: cancel)
        let firstCallback = CallbackClaim()
        let result: IndexingImage = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let id = request(targetSize, .aspectFit, options) { image, info in
                    // Claim before pixel conversion; even concurrent duplicates
                    // must not replace the first callback while CI renders it.
                    guard firstCallback.claim() else { return }
                    // Cancellation beats even usable pixels and cloud/error metadata.
                    if PhotoImageRequestInfo.isCancellation(info) {
                        gate.finish(.failure(CancellationError()))
                        return
                    }
                    let error = info?[PHImageErrorKey] as? Error
                    if let error, isPermissionFailure(error) {
                        gate.finish(.failure(AppFailure.permission))
                        return
                    }
                    if let error, isAuthenticationFailure(error) {
                        gate.finish(.failure(error))
                        return
                    }
                    do {
                        if let image, let pixels = cgImage(from: image) {
                            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue
                            let reduced = (degraded ?? false)
                                || CGFloat(min(pixels.width, pixels.height)) < min(targetSize.width, targetSize.height)
                            let source: IndexingImage.Source = network ? .networkPreview
                                : (reduced ? .localReducedPreview : .localPreview)
                            // BOTH delivery modes accept one-shot low-resolution/degraded
                            // pixels. Never wait for a better callback or JPEG/PNG re-encode.
                            gate.finish(.success(IndexingImage(cgImage: pixels,
                                                              orientation: orientation(image.imageOrientation),
                                                              source: source, requestedSize: targetSize,
                                                              photokitDegraded: degraded)))
                        } else if let error {
                            if !network, PhotoImageRequestInfo.requiresNetwork(error) {
                                throw LocalMissing.requiresNetwork
                            }
                            // Includes permission/authentication and real network failures,
                            // even when PhotoKit also sets the cloud flag.
                            throw error
                        } else if !network {
                            throw PhotoImageRequestInfo.flag(PHImageResultIsInCloudKey, info)
                                ? LocalMissing.requiresNetwork : LocalMissing.noResource
                        } else {
                            throw AppFailure.photo("PhotoKit returned no network preview.")
                        }
                    } catch { gate.finish(.failure(error)) }
                }
                gate.setRequestID(id)
            }
        }, onCancel: { gate.cancel() })
        // A task cancellation racing a successful callback must not deliver an image.
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

    private static func isAuthenticationFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorUserAuthenticationRequired
    }

    /// PhotoRequestGate owns completion/cancellation; this only claims a callback.
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
}