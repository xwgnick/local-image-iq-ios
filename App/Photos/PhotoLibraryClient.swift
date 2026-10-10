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

/// The callback uses callbackLock; the independent search-cache lock owns its
/// generation, authorization, registration and retained immutable fetch result.
/// PhotoKit's thread-safe manager is shared; individual assets remain call-local.
final class PhotoLibraryClient: NSObject, PHPhotoLibraryChangeObserver, PhotoLibraryIndexing, PhotoThumbnailProviding, @unchecked Sendable {
    /// Additive notification: compatibility viewers also observe invalidation,
    /// without taking over the app's existing single change handler.
    static let viewerDidChangeNotification = Notification.Name("PhotoLibraryClient.viewerDidChange")
    private let manager = PHImageManager.default()
    private let callbackLock = NSLock()
    private var changeHandler: (@Sendable () -> Void)?
    private let searchCache = PhotoSearchSnapshotCache<SearchFetch>()

    /// PHFetchResult is an immutable PhotoKit snapshot, shared for enumeration
    /// and changeDetails only. Its replacement is serialized by searchCache.
    private struct SearchFetch: @unchecked Sendable {
        let result: PHFetchResult<PHAsset>
    }

    var changeGeneration: UInt64? { searchCache.changeGeneration }

    override init() {
        super.init()
    }

    deinit {
        if searchCache.isObserving { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /// Registering before authorization can trigger an implicit system prompt.
    /// Refresh runs after the user's explicit choice and on foreground/access changes.
    @MainActor
    func synchronizeObservation() {
        let access = Self.searchAccess
        let wasObserving = searchCache.isObserving
        // Invalidate full/limited transitions even when registration stays true.
        // Do not invalidate an ordinary refresh with unchanged authorization.
        searchCache.synchronizeObservation(isRegistered: wasObserving && access.canRead, access: access)
        guard wasObserving != access.canRead else { return }
        if access.canRead {
            // Warm reuse is allowed only AFTER actual registration completes.
            PHPhotoLibrary.shared().register(self)
            let current = Self.searchAccess
            if !current.canRead { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
            searchCache.synchronizeObservation(isRegistered: current.canRead, access: current)
        } else {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    func observe(_ handler: @escaping @Sendable () -> Void) {
        callbackLock.lock()
        changeHandler = handler
        callbackLock.unlock()
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Synchronous invalidation precedes notification, even for unrelated
        // changes. Rebuild sorted revisions lazily from the updated fetch result,
        // not a new whole-library fetch. No claim of per-row incremental work.
        searchCache.libraryDidChange { source in
            guard let details = changeInstance.changeDetails(for: source.result) else { return source }
            return SearchFetch(result: details.fetchResultAfterChanges)
        }
        NotificationCenter.default.post(name: Self.viewerDidChangeNotification, object: self)
        callbackLock.lock()
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
        let options = Self.searchFetchOptions()
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
        // A photo admitted by the complete snapshot must use the same fetch
        // scope when checked or loaded by ID. Authorization still gates access.
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: Self.searchFetchOptions()).firstObject
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

    /// On-demand OCR pixels, independent of indexing, tiles and original-data export.
    /// The native asset dimensions are a request, not a guarantee of returned detail.
    func textRecognitionImage(id: String, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        guard Self.canRead else { throw AppFailure.permission }
        let authorization = Self.authorization
        let generation = changeGeneration
        guard let selectedAsset = asset(id: id) else {
            throw AppFailure.photo("This photo is no longer accessible.")
        }
        let revision = PhotoRevision(asset: selectedAsset)
        return try await Self.textRecognitionImage(
            pixelWidth: selectedAsset.pixelWidth, pixelHeight: selectedAsset.pixelHeight,
            networkAllowed: networkAllowed,
            request: { [manager] size, mode, options, callback in
                manager.requestImage(for: selectedAsset, targetSize: size, contentMode: mode,
                                     options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) }, validate: { [self] in
                try validateThumbnail(id: id, revision: revision,
                                      authorization: authorization, generation: generation)
            })
    }

    /// Injectable OCR adapter to the existing candidate/fallback policy. Tests need
    /// neither PHAsset nor library access. Only content mode differs at every stage;
    /// native HQ / HQ224 / opt-in network HQ / last-resort Fast semantics stay shared.
    static func textRecognitionImage(pixelWidth: Int, pixelHeight: Int, networkAllowed: Bool,
                                     request: @escaping DisplayThumbnailLoader.Request,
                                     cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                                     validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        try validate()
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw AppFailure.photo("Photo dimensions are unavailable. Try updating photo text again.")
        }
        let nativeTarget = CGSize(width: pixelWidth, height: pixelHeight)
        let quality224 = LocalPreviewComparisonLoader.targetSize(
            width: pixelWidth, height: pixelHeight, shortEdge: 224)
        let result = try await DisplayThumbnailLoader.loadResult(
            targetSize: nativeTarget, quality224Target: quality224, networkAllowed: networkAllowed,
            request: { size, _, options, callback in
                do {
                    try Task.checkCancellation()
                    try validate()
                    try Task.checkCancellation()
                } catch {
                    callback(nil, [PHImageErrorKey: error])
                    return PHInvalidImageRequestID
                }
                // Preserve the captured opt-in even if the shared loader changes.
                options.isNetworkAccessAllowed = networkAllowed && options.isNetworkAccessAllowed
                return request(size, .aspectFit, options, callback)
            }, cancel: cancel)
        try Task.checkCancellation()
        try validate()
        try Task.checkCancellation()
        return result
    }

    /// Dedicated cleanup comparison pixels. targetSize is the pane's pixel bounds,
    /// not an original-size request. Every stage preserves the whole photograph.
    func comparisonResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        guard Self.canRead else { throw AppFailure.permission }
        let authorization = Self.authorization
        let generation = changeGeneration
        guard let selectedAsset = asset(id: id) else {
            throw AppFailure.photo("This photo is no longer accessible.")
        }
        let revision = PhotoRevision(asset: selectedAsset)
        return try await Self.comparisonResult(
            pixelWidth: selectedAsset.pixelWidth, pixelHeight: selectedAsset.pixelHeight,
            targetSize: targetSize, networkAllowed: networkAllowed,
            request: { [manager] size, mode, options, callback in
                manager.requestImage(for: selectedAsset, targetSize: size, contentMode: mode,
                                     options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) }, validate: { [self] in
                try validateThumbnail(id: id, revision: revision,
                                      authorization: authorization, generation: generation)
            })
    }

    /// Injectable adapter: no OCR, original-data request, index write or pixel cap.
    /// Fit the asset aspect into the pane before the loader measures coverage, so
    /// letterboxing does not incorrectly trigger a larger/network fallback.
    static func comparisonResult(pixelWidth: Int, pixelHeight: Int, targetSize: CGSize,
                                 networkAllowed: Bool, request: @escaping DisplayThumbnailLoader.Request,
                                 cancel: @escaping @Sendable (PHImageRequestID) -> Void,
                                 validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        try Task.checkCancellation()
        try validate()
        guard pixelWidth > 0, pixelHeight > 0,
              let bounds = DisplayThumbnailLoader.targetSize(points: targetSize, displayScale: 1) else {
            throw AppFailure.photo("Invalid comparison image size.")
        }
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let scale = min(bounds.width / width, bounds.height / height)
        guard let fitted = DisplayThumbnailLoader.targetSize(
            points: CGSize(width: width * scale, height: height * scale), displayScale: 1) else {
            throw AppFailure.photo("Invalid comparison image size.")
        }
        let quality224 = LocalPreviewComparisonLoader.targetSize(
            width: pixelWidth, height: pixelHeight, shortEdge: 224)
        let result = try await DisplayThumbnailLoader.loadResult(
            targetSize: fitted, quality224Target: quality224, networkAllowed: networkAllowed,
            request: { size, _, options, callback in
                do {
                    try Task.checkCancellation()
                    try validate()
                    try Task.checkCancellation()
                } catch {
                    callback(nil, [PHImageErrorKey: error])
                    return PHInvalidImageRequestID
                }
                options.isNetworkAccessAllowed = networkAllowed && options.isNetworkAccessAllowed
                return request(size, .aspectFit, options, callback)
            }, cancel: cancel)
        try Task.checkCancellation()
        try validate()
        try Task.checkCancellation()
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

    /// Compatibility signature: targetSize no longer starts a maximum-size or
    /// viewport request. Viewer defaults to local HQ224 regardless of opt-in.
    func displayImage(id: String, targetSize: CGSize, networkAllowed: Bool = false) async throws -> UIImage {
        try await viewerImage(id: id, networkAllowed: networkAllowed).result.image
    }

    func viewerImage(id: String, networkAllowed: Bool = false) async throws -> PhotoViewerImage {
        try Task.checkCancellation()
        let authorization = Self.authorization
        guard authorization == .authorized || authorization == .limited else { throw AppFailure.permission }
        let generation = changeGeneration
        guard let selectedAsset = asset(id: id) else { throw AppFailure.photo("This photo is no longer accessible.") }
        let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(asset: selectedAsset),
                                           authorization: authorization, generation: generation)
        let result = try await PhotoViewerImageLoader.load(
            pixelWidth: selectedAsset.pixelWidth, pixelHeight: selectedAsset.pixelHeight,
            networkAllowed: networkAllowed,
            request: { [manager] size, mode, options, callback in
                manager.requestImage(for: selectedAsset, targetSize: size, contentMode: mode,
                                     options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) }, validate: { [self] in
                try validateViewerSnapshot(snapshot, id: id)
            })
        try validateViewerSnapshot(snapshot, id: id)
        return PhotoViewerImage(snapshot: snapshot, result: result)
    }

    func validateViewerSnapshot(_ snapshot: PhotoViewerSnapshot, id: String) throws {
        try snapshot.validate(id: id, authorization: { Self.authorization },
                              generation: { self.changeGeneration }, currentRevision: currentRevision(id:))
    }

    /// Captured before the first request, including when no local preview exists.
    /// A cloud confirmation can therefore bind metadata without downloading first.
    func viewerAsset(id: String) throws -> PhotoViewerAsset {
        try Task.checkCancellation()
        let authorization = Self.authorization
        guard authorization == .authorized || authorization == .limited else { throw AppFailure.permission }
        let generation = changeGeneration
        guard let selectedAsset = asset(id: id) else { throw AppFailure.photo("This photo is no longer accessible.") }
        let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(asset: selectedAsset),
                                           authorization: authorization, generation: generation)
        try validateViewerSnapshot(snapshot, id: id)
        return PhotoViewerAsset(snapshot: snapshot,
            pixelSize: CGSize(width: selectedAsset.pixelWidth, height: selectedAsset.pixelHeight))
    }

    func viewerUpgrade(asset captured: PhotoViewerAsset, targetSize: CGSize,
                       cloudConsent: Bool) async throws -> PhotoViewerImage {
        let snapshot = captured.snapshot
        let id = snapshot.revision.id
        try validateViewerSnapshot(snapshot, id: id)
        guard let selectedAsset = asset(id: id), PhotoRevision(asset: selectedAsset) == snapshot.revision,
              selectedAsset.localIdentifier.utf8.elementsEqual(id.utf8),
              CGSize(width: selectedAsset.pixelWidth, height: selectedAsset.pixelHeight) == captured.pixelSize else {
            throw CancellationError()
        }
        try validateViewerSnapshot(snapshot, id: id)
        let result = try await PhotoViewerImageLoader.upgrade(targetSize: targetSize, cloudConsent: cloudConsent,
            request: { [self, manager] size, mode, options, callback in
                do { try validateViewerSnapshot(snapshot, id: id) }
                catch { callback(nil, [PHImageErrorKey: error]); return PHInvalidImageRequestID }
                return manager.requestImage(for: selectedAsset, targetSize: size, contentMode: mode,
                                            options: options, resultHandler: callback)
            }, cancel: { [manager] in manager.cancelImageRequest($0) }, validate: { [self] in
                try validateViewerSnapshot(snapshot, id: id)
            })
        try validateViewerSnapshot(snapshot, id: id)
        return PhotoViewerImage(snapshot: snapshot, result: result)
    }

    private static func flag(_ key: String, _ info: [AnyHashable: Any]?) -> Bool {
        (info?[key] as? NSNumber)?.boolValue ?? false
    }
}

/// Fresh selected-ID metadata only: no retained full snapshot, pixels, or prompt.
extension PhotoLibraryClient: PhotoRevisionBatchReading {
    func currentRevisions(ids: [String]) throws -> [PhotoRevision] {
        try Task.checkCancellation()
        let authorization = Self.authorization
        let generation = changeGeneration
        func validateEpoch() throws {
            try Task.checkCancellation()
            guard Self.canRead else { throw AppFailure.permission }
            guard Self.authorization == authorization, changeGeneration == generation else {
                throw AppFailure.photo("Photo access changed. Try again.")
            }
        }
        try validateEpoch()
        let requested = Set(ids)
        let uniqueIDs = requested.sorted()
        guard !uniqueIDs.isEmpty else {
            try validateEpoch()
            return []
        }
        try validateEpoch()
        // Match full enumeration's hidden/burst scope, but fetch only these IDs.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIDs, options: Self.searchFetchOptions())
        let revisions = try Self.searchRevisions(in: fetched).filter { requested.contains($0.id) }
        try validateEpoch()
        return revisions
    }
}

/// Production metadata reuse. Worker still performs a fresh full final check,
/// and AppState invalidates the retained source on background/foreground. Fresh
/// batch page checks remain independent of observer notification delivery.
extension PhotoLibraryClient: PhotoSearchSnapshotting {
    func searchSnapshot() throws -> PhotoSearchSnapshot {
        try searchCache.capture(readAccess: { Self.searchAccess }, loadSource: {
            SearchFetch(result: PHAsset.fetchAssets(with: .image, options: Self.searchFetchOptions()))
        }, loadRevisions: { source in
            try Self.searchRevisions(in: source.result)
        }, loadPhotos: { ids in
            // One fresh selected-ID query, including hidden and burst images just
            // like the full capture. Exact IDs and all revision fields are checked
            // by the core, between actual authorization/generation checks.
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: Self.searchFetchOptions())
            return try Self.searchRevisions(in: fetched)
        })
    }

    func invalidateSearchSnapshot() { searchCache.invalidate() }

    private static var searchAccess: PhotoSearchSnapshotCache<SearchFetch>.Access {
        let status = authorization
        return .init(authorization: status.rawValue, canRead: status == .authorized || status == .limited)
    }

    /// Shared by full enumeration, single-ID reads and batch/search reads.
    /// Return a fresh instance so one caller cannot mutate another's scope.
    static func searchFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    private static func searchRevisions(in fetched: PHFetchResult<PHAsset>) throws -> [PhotoRevision] {
        try Task.checkCancellation()
        var revisions: [PhotoRevision] = []
        var interrupted = false
        fetched.enumerateObjects { asset, _, stop in
            if Task.isCancelled { interrupted = true; stop.pointee = true; return }
            if asset.mediaType == .image { revisions.append(PhotoRevision(asset: asset)) }
        }
        guard !interrupted else { throw CancellationError() }
        try Task.checkCancellation()
        return revisions
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