import Foundation
import Photos

/// The caller captures these exact revisions from the user's checkbox selection
/// and obtains explicit confirmation BEFORE calling delete. Never pass a fresh
/// album/library query in place of that selection, or silently refresh revisions.
protocol PhotoDeleting: Sendable {
    func delete(revisions: [PhotoRevision]) async throws
}

/// No associated IDs, paths, underlying errors or system descriptions escape.
/// Controllers catch CancellationError separately (normal cancellation, not a
/// rollback claim), display PhotoDeletionError.localizedDescription for failures,
/// and use mutationFailed for any unexpected error. They must not retry deletion
/// automatically or replace a real success with Task.isCancelled afterwards.
enum PhotoDeletionError: Error, Equatable, Sendable, LocalizedError {
    case emptySelection, invalidSelection, permissionDenied, accessChanged
    case unavailableAssets, revisionChanged, notDeletable, cancelled, mutationFailed

    var errorDescription: String? {
        switch self {
        case .emptySelection: return "请先选择要删除的照片。"
        case .invalidSelection: return "所选照片信息无效，请重新选择。"
        case .permissionDenied: return "请先允许访问照片。"
        case .accessChanged: return "照片访问权限或图库状态已更改，请重新选择。"
        case .unavailableAssets: return "部分照片已不存在或无法访问，请重新选择。"
        case .revisionChanged: return "部分照片已更改，请重新选择并确认。"
        case .notDeletable: return "部分照片不允许删除。"
        case .cancelled: return "已取消删除照片。"
        case .mutationFailed: return "未能完成照片删除，请检查照片状态。"
        }
    }

    static func sanitized(_ error: Error) -> Error {
        if PhotoImageRequestInfo.isCancellation(error) { return CancellationError() }
        if let error = error as? PhotoDeletionError {
            if error == .cancelled { return CancellationError() }
            return error
        }
        if let error = error as? PhotoLibraryActionError {
            switch error {
            case .emptySelection: return PhotoDeletionError.emptySelection
            case .invalidIdentifier: return PhotoDeletionError.invalidSelection
            case .permissionDenied: return PhotoDeletionError.permissionDenied
            case .accessChanged: return PhotoDeletionError.accessChanged
            case .unavailableAssets: return PhotoDeletionError.unavailableAssets
            default: return PhotoDeletionError.mutationFailed
            }
        }
        let systemError = error as NSError
        if systemError.domain == PHPhotosErrorDomain,
           systemError.code == PHPhotosError.Code.accessUserDenied.rawValue
            || systemError.code == PHPhotosError.Code.accessRestricted.rawValue {
            return PhotoDeletionError.permissionDenied
        }
        return PhotoDeletionError.mutationFailed
    }
}

/// Pure metadata only; constructing/validating a state never calls PhotoKit.
struct PhotoDeletionAssetState: Sendable {
    let id: String
    let isImage: Bool
    let canDelete: Bool
    let revision: PhotoRevision
}

/// All-or-nothing validation. An entire selected group (including a one-photo
/// group) is allowed: confirmation belongs to the UI, not a keep-one restriction.
struct PhotoDeletionPlan: Sendable {
    let revisions: [PhotoRevision]
    var assetIDs: [String] { revisions.map(\.id) }

    init(revisions: [PhotoRevision], assets: [PhotoDeletionAssetState],
         authorization: PHAuthorizationStatus) throws {
        do {
            try PhotoActionValidation.requireAccess(authorization)
            let expected = try Self.orderedUniqueRevisions(revisions)
            let selectedIDs = Set(expected.map(\.id))
            var available: [String: PhotoDeletionAssetState] = [:]
            for asset in assets {
                // No silently overwritten duplicate states or expanded selection.
                guard selectedIDs.contains(asset.id), asset.revision.id == asset.id,
                      Self.isWellFormed(asset.revision), available[asset.id] == nil else {
                    throw PhotoDeletionError.invalidSelection
                }
                available[asset.id] = asset
            }
            for revision in expected {
                guard let asset = available[revision.id], asset.isImage else {
                    throw PhotoDeletionError.unavailableAssets
                }
                guard asset.revision == revision else { throw PhotoDeletionError.revisionChanged }
                guard asset.canDelete else { throw PhotoDeletionError.notDeletable }
            }
            self.revisions = expected
        } catch { throw PhotoDeletionError.sanitized(error) }
    }

    static func orderedUniqueRevisions(_ revisions: [PhotoRevision]) throws -> [PhotoRevision] {
        do {
            // Reuse the existing ID rules, including opaque IDs: validate blanks,
            // but NEVER trim, sort, canonicalize or otherwise rewrite identifiers.
            let ids = try PhotoActionValidation.orderedUniqueIDs(revisions.map(\.id))
            var byID: [String: PhotoRevision] = [:]
            for revision in revisions {
                guard isWellFormed(revision) else { throw PhotoDeletionError.invalidSelection }
                if let previous = byID[revision.id], previous != revision {
                    // Do not pick the newest revision out of conflicting captures.
                    throw PhotoDeletionError.invalidSelection
                }
                byID[revision.id] = revision
            }
            return try ids.map { id in
                guard let revision = byID[id] else { throw PhotoDeletionError.invalidSelection }
                return revision
            }
        } catch { throw PhotoDeletionError.sanitized(error) }
    }

    private static func isWellFormed(_ revision: PhotoRevision) -> Bool {
        revision.modificationTime.isFinite && (revision.creationTime?.isFinite ?? true)
    }
}

/// Captured before the first fetch and retained for the entire operation.
struct PhotoDeletionEpoch: Sendable, Equatable {
    let authorization: PHAuthorizationStatus
    let generation: UInt64?

    func validate(_ current: PhotoDeletionEpoch) throws {
        try PhotoActionValidation.requireAccess(current.authorization)
        guard self == current else { throw PhotoDeletionError.accessChanged }
    }
}

/// Internal dependency seam, not a public prepare/commit API. A preflight must
/// validate the WHOLE expected selection using PhotoDeletionPlan before returning
/// its payload. The initial payload is discarded; only the newly fetched queued
/// payload reaches request, synchronously inside the submitted changes block.
/// No payload crosses an await or needs unchecked Sendable PHAsset wrappers.
enum PhotoDeletionExecutor {
    typealias Changes = @Sendable () -> Void
    typealias Completion = @Sendable (Bool, Error?) -> Void
    typealias Submit = @Sendable (@escaping Changes, @escaping Completion) -> Void

    static func run<Selection>(
        expected: [PhotoRevision],
        currentEpoch: @escaping @Sendable () -> PhotoDeletionEpoch,
        preflight: @escaping @Sendable ([PhotoRevision], PHAuthorizationStatus) throws -> Selection,
        request: @escaping @Sendable (Selection) -> Void,
        submit: @escaping Submit
    ) async throws {
        do {
            try Task.checkCancellation()
            let expected = try PhotoDeletionPlan.orderedUniqueRevisions(expected)
            let initial = currentEpoch()
            try PhotoActionValidation.requireAccess(initial.authorization)
            _ = try preflight(expected, initial.authorization)
            try initial.validate(currentEpoch())
            try Task.checkCancellation()

            let gate = PhotoMutationGate()
            try await withTaskCancellationHandler(operation: {
                try gate.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    submit({
                        do {
                            // Queued PhotoKit blocks do not inherit Task cancellation.
                            try gate.checkCancellation()
                            try initial.validate(currentEpoch())
                            let selected = try preflight(expected, initial.authorization)
                            // Last precommit epoch check, after ALL asset checks and
                            // immediately before the gate/request. Photos cannot be
                            // locked by this app: a later OS change is still possible.
                            try initial.validate(currentEpoch())
                            try gate.beginMutation()
                            request(selected)
                        } catch { gate.recordFailure(PhotoDeletionError.sanitized(error)) }
                    }, { success, systemError in
                        let result = gate.result(success: success).mapError { error -> Error in
                            // Preserve queued preflight failures/cancellation. Only
                            // the gate's unclassified Photos failure uses the OS code.
                            if !success, error as? PhotoLibraryActionError == .mutationFailed,
                               let systemError {
                                return PhotoDeletionError.sanitized(systemError)
                            }
                            return PhotoDeletionError.sanitized(error)
                        }
                        // After beginMutation, wait for the real callback even if
                        // cancelled. No post-success cancellation check or retry.
                        continuation.resume(with: result)
                    })
                }
            }, onCancel: { gate.cancel() })
        } catch { throw PhotoDeletionError.sanitized(error) }
    }
}

/// Initialization only retains the client: no authorization, observer registration,
/// asset fetching or mutation. Only explicit delete(revisions:) can delete photos.
/// Per-operation state is local or protected by the existing PhotoMutationGate;
/// the injected client's generation accessor is thread-safe.
final class SystemPhotoDeletionService: PhotoDeleting, @unchecked Sendable {
    private let library: PhotoLibraryClient

    init(library: PhotoLibraryClient) { self.library = library }

    func delete(revisions: [PhotoRevision]) async throws {
        try await PhotoDeletionExecutor.run(expected: revisions, currentEpoch: { [library] in
            PhotoDeletionEpoch(authorization: PhotoLibraryClient.authorization,
                               generation: library.changeGeneration)
        }, preflight: { expected, authorization in
            try Self.selectedAssets(expected: expected, authorization: authorization)
        }, request: { selected in
            // Exactly one request in one Photos transaction for this selected
            // snapshot. No per-asset transactions, originals copied, or UI bypass.
            // Photos may display its own confirmation. Deletions normally move to
            // Recently Deleted and may sync through iCloud Photos; availability and
            // retention depend on the system, NOT an unconditional 30-day guarantee.
            PHAssetChangeRequest.deleteAssets(selected as NSArray)
        }, submit: { changes, completion in
            PHPhotoLibrary.shared().performChanges(changes, completionHandler: completion)
        })
    }

    private static func selectedAssets(expected: [PhotoRevision],
                                       authorization: PHAuthorizationStatus) throws -> [PHAsset] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        // This is the ONLY fetch: explicit captured IDs, never all/library/album.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: expected.map(\.id), options: options)
        let assets = (0..<fetched.count).map { fetched.object(at: $0) }
        let plan = try PhotoDeletionPlan(revisions: expected, assets: assets.map {
            PhotoDeletionAssetState(id: $0.localIdentifier, isImage: $0.mediaType == .image,
                                   canDelete: $0.canPerform(.delete), revision: PhotoRevision(asset: $0))
        }, authorization: authorization)
        // PhotoKit fetch order is unspecified. The validated plan has exactly the
        // captured unique IDs and revisions; reconstruct that order without drops.
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        return try plan.assetIDs.map { id in
            guard let asset = byID[id] else { throw PhotoDeletionError.unavailableAssets }
            return asset
        }
    }
}