import Foundation
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
final class PhotoLibraryClient: NSObject, PHPhotoLibraryChangeObserver, PhotoLibraryIndexing, @unchecked Sendable {
    private let manager = PHImageManager.default()
    private let callbackLock = NSLock()
    private var changeHandler: (@Sendable () -> Void)?
    private var observing = false

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
        guard let location = asset(id: id)?.location else { return nil }
        return resolver.label(longitude: location.coordinate.longitude, latitude: location.coordinate.latitude)
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