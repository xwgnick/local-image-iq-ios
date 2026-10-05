import Foundation
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct PhotoAlbum: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let canAdd: Bool
}

enum PhotoBatchAction: Sendable {
    case favorite(Bool)
    case addToAlbum(String)
    case createAlbum(String)
}

protocol PhotoLibraryActions: Sendable {
    func albums() async throws -> [PhotoAlbum]
    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws
    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare
    func validateAccess(ids: [String]) throws
}

enum PhotoLibraryActionError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection, invalidIdentifier, permissionDenied, accessChanged, unavailableAssets
    case favoriteUnavailable, albumUnavailable, albumNotEditable, emptyAlbumTitle
    case mutationFailed, sharePreparationFailed, cloudOnly

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "请先选择照片。"
        case .invalidIdentifier: return "所选照片或相册无效，请重新选择。"
        case .permissionDenied: return "请先允许访问照片。"
        case .accessChanged: return "照片访问权限已更改，请重新选择。"
        case .unavailableAssets: return "部分照片已删除或不再允许访问，请重新选择。"
        case .favoriteUnavailable: return "部分照片不允许修改收藏状态。"
        case .albumUnavailable: return "此相册已不存在或无法访问。"
        case .albumNotEditable: return "此相册不允许添加照片。"
        case .emptyAlbumTitle: return "请输入相册名称。"
        case .mutationFailed: return "未能完成照片操作，请检查后重试。"
        case .sharePreparationFailed: return "未能准备分享照片，请重试。"
        case .cloudOnly: return "没有可用的本地预览；如需访问 iCloud，请明确开启后重试。"
        }
    }
}

/// Pure validation used by both preflights and model-free tests. No Photos writes.
enum PhotoActionValidation {
    static func orderedUniqueIDs(_ ids: [String]) throws -> [String] {
        guard !ids.isEmpty else { throw PhotoLibraryActionError.emptySelection }
        var seen = Set<String>()
        var ordered: [String] = []
        for id in ids {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhotoLibraryActionError.invalidIdentifier
            }
            if seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered
    }

    static func requireAccess(_ authorization: PHAuthorizationStatus) throws {
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryActionError.permissionDenied
        }
    }

    static func normalized(_ action: PhotoBatchAction) throws -> PhotoBatchAction {
        switch action {
        case .favorite: return action
        case .addToAlbum(let id):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PhotoLibraryActionError.invalidIdentifier
            }
            return action // Local identifiers are opaque; never trim/rewrite them.
        case .createAlbum(let name):
            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw PhotoLibraryActionError.emptyAlbumTitle }
            return .createAlbum(title)
        }
    }

    static func sortedAlbums(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        var seen = Set<String>()
        return albums.filter { seen.insert($0.id).inserted }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

struct PhotoBatchAssetState: Sendable {
    let id: String
    let isImage: Bool
    let canFavorite: Bool
}

/// A plan exists only after the ENTIRE selection and action have been validated.
/// No partial selection, implicit retry, batch splitting, or empty-album fallback.
struct PhotoBatchMutationPlan: Sendable {
    let action: PhotoBatchAction
    let assetIDs: [String]

    init(action: PhotoBatchAction, ids: [String], assets: [PhotoBatchAssetState],
         album: PhotoAlbum? = nil, authorization: PHAuthorizationStatus) throws {
        try PhotoActionValidation.requireAccess(authorization)
        let ordered = try PhotoActionValidation.orderedUniqueIDs(ids)
        let normalized = try PhotoActionValidation.normalized(action)
        var available: [String: PhotoBatchAssetState] = [:]
        for asset in assets { available[asset.id] = asset }
        for id in ordered {
            guard let asset = available[id], asset.isImage else {
                throw PhotoLibraryActionError.unavailableAssets
            }
            if case .favorite = normalized, !asset.canFavorite {
                throw PhotoLibraryActionError.favoriteUnavailable
            }
        }
        if case .addToAlbum(let id) = normalized {
            guard let album, album.id == id else { throw PhotoLibraryActionError.albumUnavailable }
            guard album.canAdd else { throw PhotoLibraryActionError.albumNotEditable }
        }
        self.action = normalized
        assetIDs = ordered
    }
}

/// Cancellation can prevent submission or make the queued Photos block a no-op.
/// beginMutation() is the last cancellable boundary, NOT proof of a Photos commit.
/// Afterwards cancellation NEVER claims
/// rollback, resumes early, or converts an actually successful write into cancellation.
/// PhotoKit callback blocks do not inherit the originating Task's cancellation.
final class PhotoMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var began = false
    private var failure: Error?

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        if !began { cancelled = true }
    }

    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func beginMutation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        began = true
    }

    func recordFailure(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        failure = error
    }

    func result(success: Bool) -> Result<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        if let failure { return .failure(failure) }
        if !began, cancelled { return .failure(CancellationError()) }
        return success && began ? .success(()) : .failure(PhotoLibraryActionError.mutationFailed)
    }
}

/// Owns only its unique temporary directory. Retain through UIActivityViewController
/// dismissal; the presenter must validateAccess(assetIDs) immediately before showing
/// it and call cleanup() on dismissal/access loss. Already-shared external copies
/// cannot be revoked. URLs/asset IDs are private in-memory state, never logged.
final class PreparedPhotoShare: Identifiable, @unchecked Sendable {
    let id: UUID
    let urls: [URL]
    let assetIDs: [String]
    private let directory: URL
    private let lock = NSLock()
    private var cleanedUp = false

    fileprivate init(id: UUID, urls: [URL], assetIDs: [String], directory: URL) {
        self.id = id
        self.urls = urls
        self.assetIDs = assetIDs
        self.directory = directory
    }

    /// Idempotent, including concurrent calls. Filesystem failures are best effort;
    /// a later call/deinit retries rather than marking failed removal as complete.
    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        guard !cleanedUp else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            cleanedUp = true
        } catch {
            cleanedUp = !FileManager.default.fileExists(atPath: directory.path)
        }
    }

    deinit { cleanup() }
}

/// Injectable file writer/access checker: tests use tiny synthetic files and never
/// call PhotoKit. Production writes one JPEG at a time, retaining URLs, not images.
enum PhotoSharePreparer {
    static func prepare(ids: [String], temporaryRoot: URL = FileManager.default.temporaryDirectory,
                        validate: @Sendable ([String]) throws -> Void,
                        write: @Sendable (String, URL) async throws -> Void) async throws -> PreparedPhotoShare {
        let ordered = try PhotoActionValidation.orderedUniqueIDs(ids)
        try Task.checkCancellation()
        try validate(ordered) // No directory or pixel request before ALL IDs pass.
        try Task.checkCancellation()
        let id = UUID()
        var directory = temporaryRoot.appendingPathComponent("PhotoShare-\(id.uuidString)", isDirectory: true)
        let urls = ordered.indices.map {
            directory.appendingPathComponent(String(format: "photo-%03ld.jpg", $0 + 1))
        }
        do {
            // A fresh UUID scopes this preparation; no shared staging directory.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch { throw PhotoLibraryActionError.sharePreparationFailed }
        let prepared = PreparedPhotoShare(id: id, urls: urls, assetIDs: ordered, directory: directory)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            for (index, assetID) in ordered.enumerated() {
                try Task.checkCancellation()
                try validate([assetID])
                try await write(assetID, urls[index])
                try Task.checkCancellation()
                try validate([assetID])
            }
            try validate(ordered)
            try Task.checkCancellation()
            return prepared
        } catch {
            prepared.cleanup() // Remove every completed/partial file before returning an error.
            throw sanitizedError(error)
        }
    }

    static func sanitizedError(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let failure = error as? PhotoLibraryActionError { return failure }
        if let failure = error as? AppFailure {
            switch failure {
            case .permission: return PhotoLibraryActionError.permissionDenied
            case .cloudOnly: return PhotoLibraryActionError.cloudOnly
            default: break
            }
        }
        if PhotoImageRequestInfo.requiresNetwork(error) { return PhotoLibraryActionError.cloudOnly }
        return PhotoLibraryActionError.sharePreparationFailed
    }
}

/// Pixel-only encoder, independently testable without accessing the photo library.
enum PhotoShareJPEGWriter {
    static func write(image: UIImage, to url: URL) async throws {
        try Task.checkCancellation()
        let rendered = await MainActor.run {
            autoreleasepool { PhotoShareSheet.renderedCopy(of: image) }
        }
        try Task.checkCancellation()
        try autoreleasepool {
            guard let pixels = rendered.cgImage,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL,
                    UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PhotoLibraryActionError.sharePreparationFailed
            }
            // Encode ONLY the newly rendered bitmap, never copy source properties.
            // Orientation is already normalized; no EXIF/GPS/source filenames.
            CGImageDestinationAddImage(destination, pixels,
                [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw PhotoLibraryActionError.sharePreparationFailed
            }
        }
    }
}

/// All mutable per-operation state is local or locked; the injected read-only
/// library client is thread-safe. Non-actor async methods enumerate/encode off the
/// main actor. Only the existing UIKit rendered-copy helper hops to MainActor.
/// Initialization/enumeration/sharing NEVER submit Photos mutations or request
/// authorization. The only Photos write entry point is explicit apply(_:to:).
/// Never deletes/moves assets or edits original pixels, dates, or index records.
/// Photos itself owns any resulting modification-date changes.
final class SystemPhotoLibraryActions: PhotoLibraryActions, @unchecked Sendable {
    private let library: PhotoLibraryClient

    init(library: PhotoLibraryClient) { self.library = library }

    func albums() async throws -> [PhotoAlbum] {
        try Task.checkCancellation()
        let authorization = PhotoLibraryClient.authorization
        try PhotoActionValidation.requireAccess(authorization)
        var albums: [PhotoAlbum] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let fetched = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            for index in 0..<fetched.count {
                try Task.checkCancellation()
                let collection = fetched.object(at: index)
                let regular = collection.assetCollectionType == .album
                    && collection.assetCollectionSubtype == .albumRegular
                // Public, useful image filters only. Excludes Hidden and Recently
                // Deleted without using private subtype numbers or private APIs.
                let readableSmart: Bool
                switch collection.assetCollectionSubtype {
                case .smartAlbumUserLibrary, .smartAlbumFavorites, .smartAlbumRecentlyAdded,
                     .smartAlbumScreenshots, .smartAlbumLivePhotos:
                    readableSmart = collection.assetCollectionType == .smartAlbum
                default: readableSmart = false
                }
                guard regular || readableSmart else { continue }
                albums.append(PhotoAlbum(id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "未命名相册",
                    canAdd: regular && collection.canPerform(.addContent)))
            }
        }
        try Self.validateAuthorization(authorization)
        try Task.checkCancellation()
        return PhotoActionValidation.sortedAlbums(albums)
    }

    func validateAccess(ids: [String]) throws {
        _ = try Self.images(ids: PhotoActionValidation.orderedUniqueIDs(ids))
    }

    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws {
        try Task.checkCancellation()
        let prepared = try Self.prepareMutation(action: action, ids: ids)
        try Task.checkCancellation()
        let gate = PhotoMutationGate()
        try await withTaskCancellationHandler(operation: {
            try gate.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    do {
                        try gate.checkCancellation()
                        // Re-fetch inside the queued block BEFORE any change request:
                        // deletions/access loss must never create an empty album.
                        let current = try Self.prepareMutation(action: prepared.plan.action,
                                                               ids: prepared.plan.assetIDs)
                        try gate.beginMutation()
                        switch current.plan.action {
                        case .favorite(let favorite):
                            for asset in current.assets {
                                PHAssetChangeRequest(for: asset).isFavorite = favorite
                            }
                        case .addToAlbum:
                            guard let album = current.album,
                                  let request = PHAssetCollectionChangeRequest(for: album) else {
                                throw PhotoLibraryActionError.albumNotEditable
                            }
                            request.addAssets(current.assets as NSArray)
                        case .createAlbum(let title):
                            let request = PHAssetCollectionChangeRequest
                                .creationRequestForAssetCollection(withTitle: title)
                            request.addAssets(current.assets as NSArray)
                        }
                    } catch { gate.recordFailure(error) }
                }, completionHandler: { success, _ in
                    // Await the real result even if the originating task was cancelled.
                    // No cancellation check after success, no automatic retry.
                    continuation.resume(with: gate.result(success: success))
                })
            }
        }, onCancel: { gate.cancel() })
    }

    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare {
        try await PhotoSharePreparer.prepare(ids: ids, validate: { [self] in
            try validateAccess(ids: $0)
        }, write: { [self] id, url in
            try await writeShareImage(id: id, to: url, networkAllowed: networkAllowed)
        })
    }

    private struct PreparedMutation {
        let plan: PhotoBatchMutationPlan
        let assets: [PHAsset]
        let album: PHAssetCollection?
    }

    private static func prepareMutation(action: PhotoBatchAction, ids: [String]) throws -> PreparedMutation {
        let action = try PhotoActionValidation.normalized(action)
        let ids = try PhotoActionValidation.orderedUniqueIDs(ids)
        let authorization = PhotoLibraryClient.authorization
        let assets = try images(ids: ids)
        let album: PHAssetCollection?
        if case .addToAlbum(let id) = action {
            album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        } else { album = nil }
        let descriptor = album.map {
            PhotoAlbum(id: $0.localIdentifier, title: $0.localizedTitle ?? "未命名相册",
                canAdd: $0.assetCollectionType == .album && $0.assetCollectionSubtype == .albumRegular
                    && $0.canPerform(.addContent))
        }
        let plan = try PhotoBatchMutationPlan(action: action, ids: ids, assets: assets.map {
            PhotoBatchAssetState(id: $0.localIdentifier, isImage: $0.mediaType == .image,
                                canFavorite: $0.canPerform(.properties))
        }, album: descriptor, authorization: authorization)
        try validateAuthorization(authorization)
        return PreparedMutation(plan: plan, assets: assets, album: album)
    }

    private static func images(ids: [String]) throws -> [PHAsset] {
        let authorization = PhotoLibraryClient.authorization
        try PhotoActionValidation.requireAccess(authorization)
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options)
        var byID: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        let ordered = try ids.map { id -> PHAsset in
            guard let asset = byID[id], asset.mediaType == .image else {
                throw PhotoLibraryActionError.unavailableAssets
            }
            return asset
        }
        try validateAuthorization(authorization)
        return ordered
    }

    private static func validateAuthorization(_ original: PHAuthorizationStatus) throws {
        let current = PhotoLibraryClient.authorization
        try PhotoActionValidation.requireAccess(current)
        guard current == original else { throw PhotoLibraryActionError.accessChanged }
    }

    private func writeShareImage(id: String, to url: URL, networkAllowed: Bool) async throws {
        try Task.checkCancellation()
        guard let asset = try Self.images(ids: [id]).first else {
            throw PhotoLibraryActionError.unavailableAssets
        }
        // Explicit share requests the asset's dimensions without a screen-size cap.
        // The existing HQ/local fallback policy may return a smaller preview. This
        // is a rendered JPEG, NOT an original-quality/RAW/Live Photo video export.
        let result = try await library.thumbnailResult(id: id,
            targetSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            networkAllowed: networkAllowed)
        try await PhotoShareJPEGWriter.write(image: result.image, to: url)
    }
}