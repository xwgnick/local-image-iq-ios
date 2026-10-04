import Foundation
import CoreLocation
import Photos
import UIKit
import ImageIO

struct PhotoRevision: Sendable, Equatable {
    let id: String
    let modificationTime: Double
    let creationTime: Double?

    init(asset: PHAsset) {
        id = asset.localIdentifier
        modificationTime = (asset.modificationDate ?? asset.creationDate ?? .distantPast).timeIntervalSince1970
        creationTime = asset.creationDate?.timeIntervalSince1970
    }

    init(id: String, modificationTime: Double, creationTime: Double? = nil) {
        self.id = id
        self.modificationTime = modificationTime
        self.creationTime = creationTime
    }
}

struct PhotoImageData: Sendable {
    let data: Data
    let orientation: CGImagePropertyOrientation
}

/// PhotoKit may call back synchronously or on arbitrary queues. All completion and
/// cancellation state is protected by one lock; cancelling before ID assignment
/// still cancels the eventual request. Continuations are resumed outside the lock.
final class PhotoRequestGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private let cancelRequest: @Sendable (PHImageRequestID) -> Void

    init(cancelRequest: @escaping @Sendable (PHImageRequestID) -> Void) {
        self.cancelRequest = cancelRequest
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let result = outcome
        if result == nil { self.continuation = continuation }
        lock.unlock()
        if let result { continuation.resume(with: result) }
    }

    func setRequestID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let mustCancel = cancelled
        lock.unlock()
        if mustCancel { cancelRequest(id) }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = requestID
        let waiting: CheckedContinuation<Value, Error>?
        if outcome == nil {
            outcome = .failure(CancellationError())
            waiting = continuation
            continuation = nil
        } else { waiting = nil }
        lock.unlock()
        waiting?.resume(throwing: CancellationError())
        if let id { cancelRequest(id) }
    }
}

/// Only the change callback is mutable, protected by callbackLock. PhotoKit's
/// thread-safe manager is shared, while PHAsset instances stay within each call.
final class PhotoLibraryClient: NSObject, PHPhotoLibraryChangeObserver, PhotoLibraryIndexing, PhotoThumbnailProviding, @unchecked Sendable {
    private let manager = PHImageManager.default()
    private let callbackLock = NSLock()
    private var changeHandler: (@Sendable () -> Void)?
    private var observing = false
    private var generation: UInt64 = 0

    var changeGeneration: UInt64? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return generation
    }

    override init() {
        super.init()
    }

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// Registering before authorization can trigger an implicit system prompt.
    /// Refresh runs after the user's explicit choice and on foreground/access changes.
    @MainActor
    func synchronizeObservation() {
        let shouldObserve = Self.canRead
        callbackLock.lock()
        let changed = observing != shouldObserve
        observing = shouldObserve
        callbackLock.unlock()
        guard changed else { return }
        if shouldObserve { PHPhotoLibrary.shared().register(self) }
        else { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        callbackLock.lock()
        changeHandler = handler
        callbackLock.unlock()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        callbackLock.lock()
        generation &+= 1
        let callback = changeHandler
        callbackLock.unlock()
        callback?()
    }

    static var authorization: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    static var canRead: Bool { authorization == .authorized || authorization == .limited }

    var canReadImages: Bool { Self.canRead }

    /// No date/place predicates. A successful return is a COMPLETE authorized image
    /// enumeration; cancellation/authorization transitions throw before pruning.
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try Task.checkCancellation()
        let initialAuthorization = Self.authorization
        guard initialAuthorization == .authorized || initialAuthorization == .limited else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var result: [PhotoRevision] = []
        var interrupted = false
        fetched.enumerateObjects { asset, _, stop in
            if Task.isCancelled { interrupted = true; stop.pointee = true; return }
            result.append(PhotoRevision(asset: asset))
        }
        guard !interrupted else { throw CancellationError() }
        try Task.checkCancellation()
        guard Self.authorization == initialAuthorization else { throw CancellationError() }
        return result.sorted { $0.id < $1.id }
    }

    func currentRevision(id: String) -> PhotoRevision? { asset(id: id).map(PhotoRevision.init(asset:)) }

    /// Coordinates exist only during this call; neither snapshots nor SQLite store GPS.
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        guard case let .resolved(label) = placeResult(id: id, resolver: resolver) else { return nil }
        return label
    }

    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult {
        // One fetch; an inaccessible/deleted asset is not evidence of missing GPS.
        guard let asset = asset(id: id) else { return .unavailable }
        return Self.classify(location: asset.location, resolver: resolver)
    }

    /// Pure metadata classification, also usable with synthetic locations and no PhotoKit access.
    static func classify(location: CLLocation?, resolver: OfflinePlaceResolver?,
                         isAvailable: Bool = true) -> PhotoPlaceResult {
        guard isAvailable else { return .unavailable }
        guard let location else { return .noGPS }
        let coordinate = location.coordinate
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else {
            return .unavailable
        }
          // A historical photo may have coordinates but no accuracy estimate.
          // Preserve the existing coordinate-only lookup, not a new accuracy filter.
        guard let resolver, resolver.featureCount > 0 else { return .noPack }
        guard let label = resolver.label(longitude: coordinate.longitude, latitude: coordinate.latitude) else {
            return .outsideCoverage
        }
        return .resolved(label)
    }

    private func asset(id: String) -> PHAsset? {
        guard Self.canRead else { return nil }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        return asset?.mediaType == .image ? asset : nil
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        try Task.checkCancellation()
        guard let asset = asset(id: id) else { throw AppFailure.photo("Access was removed or the photo was deleted.") }
        let target = PreviewImageLoader.targetSize(pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        return try await PreviewImageLoader.load(targetSize: target, networkAllowed: networkAllowed,
                                                request: { [manager] targetSize, contentMode, options, callback in
            manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode,
                                 options: options, resultHandler: callback)
        }, cancel: { [manager] in manager.cancelImageRequest($0) })
    }

    func imageData(id: String, networkAllowed: Bool = false) async throws -> PhotoImageData {
        try Task.checkCancellation()
        guard let asset = asset(id: id) else { throw AppFailure.photo("Access was removed or the photo was deleted.") }
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = networkAllowed
        let gate = PhotoRequestGate<PhotoImageData> { [manager] in manager.cancelImageRequest($0) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let request = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, orientation, info in
                    if PhotoImageRequestInfo.isCancellation(info) { gate.finish(.failure(CancellationError())); return }
                    if let error = info?[PHImageErrorKey] as? Error {
                        if !networkAllowed, data == nil, PhotoImageRequestInfo.requiresNetwork(error) {
                            gate.finish(.failure(AppFailure.cloudOnly)); return
                        }
                        if data == nil || !PhotoImageRequestInfo.requiresNetwork(error) {
                            gate.finish(.failure(error)); return
                        }
                    }
                    if Self.flag(PHImageResultIsDegradedKey, info) { return }
                    if let data {
                        gate.finish(.success(PhotoImageData(data: data, orientation: orientation)))
                    } else if Self.flag(PHImageResultIsInCloudKey, info), !networkAllowed {
                        gate.finish(.failure(AppFailure.cloudOnly))
                    } else {
                        gate.finish(.failure(AppFailure.photo("PhotoKit returned no image data.")))
                    }
                }
                gate.setRequestID(request)
            }
        }, onCancel: { gate.cancel() })
    }

    /// Result tiles use current asset pixels independently of the stored embedding
    /// revision. This display-only path never updates or rebuilds the index.
    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool = false) async throws -> UIImage {
        try await thumbnailResult(id: id, targetSize: targetSize, networkAllowed: networkAllowed).image
    }

    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool = false) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        guard Self.canRead else { throw AppFailure.permission }
        let authorization = Self.authorization
        let generation = changeGeneration
        guard let selectedAsset = asset(id: id) else {
            throw AppFailure.photo("This photo is no longer accessible.")
        }
        guard let pixels = DisplayThumbnailLoader.targetSize(points: targetSize, displayScale: 1) else {
            throw AppFailure.photo("Invalid thumbnail size.")
        }
        let revision = PhotoRevision(asset: selectedAsset)
        try validateThumbnail(id: id, revision: revision, authorization: authorization, generation: generation)
        // Use the exact target calculation and options of the existing HQ224
        // comparison, not the grid's cropped aspect ratio or exact resize mode.
        let quality224 = LocalPreviewComparisonLoader.targetSize(
            width: selectedAsset.pixelWidth, height: selectedAsset.pixelHeight, shortEdge: 224)
        let result = try await DisplayThumbnailLoader.loadResult(
            targetSize: pixels, quality224Target: quality224, networkAllowed: networkAllowed,
            request: { [self, manager] targetSize, contentMode, options, callback in
                // Recheck between fallback stages as well as across the await.
                do {
                    try validateThumbnail(id: id, revision: revision,
                                          authorization: authorization, generation: generation)
                } catch {
                    callback(nil, [PHImageErrorKey: error])
                    return PHInvalidImageRequestID
                }
                return manager.requestImage(for: selectedAsset, targetSize: targetSize, contentMode: contentMode,
                                            options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) })
        try validateThumbnail(id: id, revision: revision, authorization: authorization, generation: generation)
        return result
    }

    private func validateThumbnail(id: String, revision: PhotoRevision, authorization: PHAuthorizationStatus,
                                   generation: UInt64?) throws {
        try Task.checkCancellation()
        guard Self.canRead else { throw AppFailure.permission }
        guard Self.authorization == authorization, changeGeneration == generation,
              revision.id == id, currentRevision(id: id) == revision else { throw CancellationError() }
        // Metadata reads can race a permission change or PhotoKit notification.
        guard Self.canRead else { throw AppFailure.permission }
        guard Self.authorization == authorization, changeGeneration == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func displayImage(id: String, targetSize: CGSize, networkAllowed: Bool = false) async throws -> UIImage {
        try Task.checkCancellation()
        guard let asset = asset(id: id) else { throw AppFailure.photo("This photo is no longer accessible.") }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = networkAllowed
        options.isSynchronous = false
        // Offline results should show a cached reduced preview rather than wait
        // for unavailable high-quality pixels. fastFormat completes once.
        options.deliveryMode = networkAllowed ? .highQualityFormat : .fastFormat
        options.resizeMode = .fast
        let gate = PhotoRequestGate<UIImage> { [manager] in manager.cancelImageRequest($0) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                if Task.isCancelled { gate.cancel(); return }
                let request = manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit, options: options) { image, info in
                    if PhotoImageRequestInfo.isCancellation(info) { gate.finish(.failure(CancellationError())); return }
                    if let error = info?[PHImageErrorKey] as? Error {
                        if !networkAllowed, image == nil, PhotoImageRequestInfo.requiresNetwork(error) {
                            gate.finish(.failure(AppFailure.cloudOnly)); return
                        }
                        if image == nil || !PhotoImageRequestInfo.requiresNetwork(error) {
                            gate.finish(.failure(error)); return
                        }
                    }
                    if networkAllowed, Self.flag(PHImageResultIsDegradedKey, info) { return }
                    if let image { gate.finish(.success(image)) }
                    else if Self.flag(PHImageResultIsInCloudKey, info), !networkAllowed {
                        gate.finish(.failure(AppFailure.cloudOnly))
                    } else { gate.finish(.failure(AppFailure.photo("No preview is available."))) }
                }
                gate.setRequestID(request)
            }
        }, onCancel: { gate.cancel() })
    }

    private static func flag(_ key: String, _ info: [AnyHashable: Any]?) -> Bool {
        (info?[key] as? NSNumber)?.boolValue ?? false
    }
}

/// Deliberately separate from the normal indexing and display APIs above.
extension PhotoLibraryClient: LocalPreviewComparing {
    func compareLocalPreviews(id: String) async throws -> LocalPreviewComparison {
        try Task.checkCancellation()
        let authorization = Self.authorization
        guard authorization == .authorized || authorization == .limited else {
            throw AppFailure.permission
        }
        // Capture one request asset and its snapshot before the first await. All
        // three requests use this same PHAsset; validation only rechecks metadata.
        guard let selectedAsset = asset(id: id) else {
            throw AppFailure.photo("This photo is no longer accessible.")
        }
        let revision = PhotoRevision(asset: selectedAsset)
        return try await LocalPreviewComparisonLoader.compare(
            id: id, revision: revision, authorizationRawValue: authorization.rawValue,
            pixelWidth: selectedAsset.pixelWidth, pixelHeight: selectedAsset.pixelHeight,
            request: { [manager] targetSize, contentMode, options, callback in
                manager.requestImage(for: selectedAsset, targetSize: targetSize, contentMode: contentMode,
                                     options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) }, validate: { [self] in
                isLocalPreviewCurrent(id: id, revision: revision, authorizationRawValue: authorization.rawValue)
            })
    }

    func isCurrent(_ comparison: LocalPreviewComparison) -> Bool {
        isLocalPreviewCurrent(id: comparison.photoID, revision: comparison.revision,
                              authorizationRawValue: comparison.authorizationRawValue)
    }

    private func isLocalPreviewCurrent(id: String, revision: PhotoRevision, authorizationRawValue: Int) -> Bool {
        let authorization = Self.authorization
        guard authorization.rawValue == authorizationRawValue,
              authorization == .authorized || authorization == .limited,
              revision.id == id, currentRevision(id: id) == revision else { return false }
        // Also reject a permission transition while fetching the current revision.
        return Self.authorization == authorization
    }
}