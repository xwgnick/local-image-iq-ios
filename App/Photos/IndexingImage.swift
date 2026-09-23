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
    static let version = "photokit-preview-v1"

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
    func enumerateAuthorizedImages() throws -> [PhotoRevision]
    func currentRevision(id: String) -> PhotoRevision?
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String?
    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage
}

extension PhotoLibraryIndexing {
    var authorizationStatusRawValue: Int? { nil }

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
        do {
            return try await loadStage(targetSize: targetSize, network: false, request: request, cancel: cancel)
        } catch {
            try Task.checkCancellation()
            guard let missing = error as? LocalMissing else { throw error }
            guard networkAllowed else {
                switch missing {
                case .requiresNetwork: throw AppFailure.cloudOnly
                case .noResource: throw AppFailure.photo("PhotoKit returned no local preview.")
                }
            }
        }
        // Exactly one optional retry, for a missing local resource only. No auth/error retry.
        do {
            return try await loadStage(targetSize: targetSize, network: true, request: request, cancel: cancel)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private static func loadStage(targetSize: CGSize, network: Bool,
                                  request: @escaping Request,
                                  cancel: @escaping @Sendable (PHImageRequestID) -> Void) async throws -> IndexingImage {
        try Task.checkCancellation()
        // Fresh options for each stage; never mutate options belonging to an active request.
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = network ? .highQualityFormat : .fastFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = network
        let gate = PhotoRequestGate<IndexingImage>(cancelRequest: cancel)
        let result: IndexingImage = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let id = request(targetSize, .aspectFit, options) { image, info in
                    // Cancellation beats even usable pixels and cloud/error metadata.
                    if PhotoImageRequestInfo.isCancellation(info) {
                        gate.finish(.failure(CancellationError()))
                        return
                    }
                    do {
                        if let image, let pixels = cgImage(from: image) {
                            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue
                            let reduced = (degraded ?? false)
                                || CGFloat(min(pixels.width, pixels.height)) < min(targetSize.width, targetSize.height)
                            let source: IndexingImage.Source = network ? .networkPreview
                                : (reduced ? .localReducedPreview : .localPreview)
                            // fastFormat has ONE callback, which may be degraded. Never wait
                            // for a nonexistent better image, and never JPEG/PNG re-encode.
                            gate.finish(.success(IndexingImage(cgImage: pixels,
                                                              orientation: orientation(image.imageOrientation),
                                                              source: source, requestedSize: targetSize,
                                                              photokitDegraded: degraded)))
                        } else if let error = info?[PHImageErrorKey] as? Error {
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