import Combine
import Foundation

/// Result-toolbar work only. No AppState, search/history/index invalidation, or
/// implicit Photos writes. The parent owns selection and refreshes after Photos
/// notifications; loading an album filter/picker never performs a mutation.
@MainActor
final class ResultPhotoActionsState: ObservableObject {
    @Published private(set) var albums: [PhotoAlbum] = []
    @Published private(set) var albumsLoading = false
    @Published private(set) var albumIssue: String?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var share: PreparedPhotoShare?
    @Published private(set) var sharingPresented = false

    private let service: any PhotoLibraryActions
    private var albumGeneration = UUID()
    private var preparationGeneration = UUID()
    private var albumTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    // SwiftUI can set the sheet binding to nil BEFORE onDismiss. Keep ownership
    // separately so that this transition cannot prematurely delete in-use files.
    private var ownedShare: PreparedPhotoShare?

    init(service: any PhotoLibraryActions) { self.service = service }

    deinit {
        albumTask?.cancel()
        preparationTask?.cancel()
        ownedShare?.cleanup()
        // Do NOT cancel mutationTask: once submitted it may commit. The task
        // retains the service, not this controller, and awaits its real outcome.
    }

    func loadAlbums() {
        albumTask?.cancel()
        let token = UUID()
        albumGeneration = token
        albumIssue = nil
        albumsLoading = true
        albumTask = Task { @MainActor [weak self, service = self.service] in
            defer { self?.finishAlbums(token) }
            guard !Task.isCancelled, self?.albumGeneration == token else { return }
            do {
                // Independent reads need not drain an uncooperative predecessor.
                let values = try await service.albums()
                guard !Task.isCancelled, let self, self.albumGeneration == token else { return }
                self.albums = values
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      let self, self.albumGeneration == token else { return }
                self.albums = []
                self.albumIssue = Self.safeMessage(error, fallback: "未能读取相册，请重试。")
            }
        }
    }

    func perform(_ action: PhotoBatchAction, ids: [String]) {
        guard !isBusy, !ids.isEmpty else { return }
        let snapshot: [String]
        let normalized: PhotoBatchAction
        do {
            snapshot = try PhotoActionValidation.orderedUniqueIDs(ids)
            normalized = try PhotoActionValidation.normalized(action)
            try service.validateAccess(ids: snapshot)
        } catch {
            message = Self.safeMessage(error, fallback: PhotoLibraryActionError.mutationFailed.localizedDescription)
            return
        }
        message = nil
        isBusy = true
        mutationTask = Task { @MainActor [weak self, service = self.service] in
            guard self != nil else { return }
            // The nonisolated async service does its work off MainActor. Never
            // retain self across this await, retry, or cancel on UI/read changes.
            do {
                try await service.apply(normalized, to: snapshot)
                self?.finishMutation(message: Self.successMessage(normalized))
            } catch {
                // Even CancellationError is not evidence of rollback. The
                // service alone knows whether the submitted mutation committed.
                self?.finishMutation(message: Self.safeMessage(error,
                    fallback: PhotoLibraryActionError.mutationFailed.localizedDescription))
            }
        }
    }

    func prepareShare(ids: [String], networkAllowed: Bool) {
        guard !isBusy, !ids.isEmpty, ownedShare == nil, share == nil else { return }
        let snapshot: [String]
        do {
            snapshot = try PhotoActionValidation.orderedUniqueIDs(ids)
        } catch {
            message = Self.safeMessage(error, fallback: PhotoLibraryActionError.sharePreparationFailed.localizedDescription)
            return
        }
        let token = UUID()
        preparationGeneration = token
        message = nil
        isBusy = true
        preparationTask = Task { @MainActor [weak self, service = self.service] in
            defer { self?.finishPreparation(token) }
            guard !Task.isCancelled, self?.preparationGeneration == token else { return }
            do {
                try service.validateAccess(ids: snapshot)
                let prepared = try await service.prepareShare(ids: snapshot, networkAllowed: networkAllowed)
                guard !Task.isCancelled, let self, self.preparationGeneration == token else {
                    prepared.cleanup() // Includes late success after owner deinit.
                    return
                }
                do {
                    guard prepared.assetIDs == snapshot else { throw PhotoLibraryActionError.accessChanged }
                    // Synchronous last check immediately before publication, not
                    // a library/search generation comparison. No intervening await.
                    try service.validateAccess(ids: prepared.assetIDs)
                } catch {
                    prepared.cleanup()
                    throw error
                }
                self.ownedShare = prepared
                self.share = prepared // Drives the parent's sheet(item:) binding.
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                      let self, self.preparationGeneration == token else { return }
                self.message = Self.safeMessage(error,
                    fallback: PhotoLibraryActionError.sharePreparationFailed.localizedDescription)
            }
        }
    }

    /// Safe in a SwiftUI body: access check only, no publication or cleanup.
    /// This is an upfront check, not a guarantee after URLs reach another app.
    func canPresent(_ prepared: PreparedPhotoShare) -> Bool {
        guard ownedShare?.id == prepared.id else { return false }
        do {
            try service.validateAccess(ids: prepared.assetIDs)
            return true
        } catch { return false }
    }

    /// Event/presentation preflight only; NEVER call this mutating method in body.
    /// Call immediately before constructing UIActivityViewController. On failure
    /// the parent must not construct it. Existing external copies are not revoked.
    @discardableResult
    func validateShare(_ prepared: PreparedPhotoShare) -> Bool {
        guard ownedShare?.id == prepared.id else { return false }
        do {
            try service.validateAccess(ids: prepared.assetIDs)
            return true
        } catch {
            message = Self.safeMessage(error, fallback: PhotoLibraryActionError.sharePreparationFailed.localizedDescription)
            dismissShare()
            return false
        }
    }

    /// Optional event hook for the parent presenter, before handing URLs to UIKit.
    @discardableResult
    func markSharingPresented() -> Bool {
        guard let prepared = ownedShare, validateShare(prepared) else { return false }
        sharingPresented = true
        return true
    }

    /// Wire to sheet onDismiss / activity completion, not background transitions.
    func dismissShare() {
        let prepared = ownedShare
        let boundShare = share
        share = nil
        ownedShare = nil
        sharingPresented = false
        prepared?.cleanup()
        boundShare?.cleanup()
    }

    func dismissShare(id: UUID) {
        guard ownedShare?.id == id else { return }
        dismissShare()
    }

    func beginPresentation(_ prepared: PreparedPhotoShare) -> Bool {
        guard validateShare(prepared) else { return false }
        sharingPresented = true
        return true
    }

    /// Cancels only the share READ. Does not dismiss a ready share, cancel album
    /// metadata, or affect a submitted mutation / its eventual success message.
    func cancelPreparation() {
        preparationGeneration = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        isBusy = mutationTask != nil
    }

    /// Explicit foreground selection/query change. Once UIKit owns the share,
    /// retain files until completion (or an explicit access-loss dismissal).
    /// For background-driven resultSessionID clearing, the parent MUST call only
    /// cancelPreparation()/pause(), NOT this method when a ready share exists.
    func invalidateSelection() {
        cancelPreparation()
        if !sharingPresented { dismissShare() }
    }

    /// The app may enter background while a share extension consumes these URLs.
    func pause() { cancelPreparation() }

    func dismissMessage() { message = nil }

    /// Photos notification: cancel unfinished sharing, but do not invalidate a
    /// ready share merely because our own write changed a library generation.
    /// Recheck actual presence/access; only access loss dismisses it.
    func libraryChanged() {
        cancelPreparation()
        if let prepared = ownedShare { validateShare(prepared) }
    }

    private func finishAlbums(_ token: UUID) {
        guard albumGeneration == token else { return }
        albumTask = nil
        albumsLoading = false
    }

    private func finishPreparation(_ token: UUID) {
        guard preparationGeneration == token else { return }
        preparationTask = nil
        isBusy = mutationTask != nil
    }

    private func finishMutation(message: String) {
        mutationTask = nil
        self.message = message
        isBusy = preparationTask != nil
    }

    private static func safeMessage(_ error: Error, fallback: String) -> String {
        // Never trust an arbitrary service/PhotoKit NSError's localized text:
        // it can contain paths, asset identifiers, album titles, or metadata.
        (error as? PhotoLibraryActionError)?.localizedDescription ?? fallback
    }

    private static func successMessage(_ action: PhotoBatchAction) -> String {
        switch action {
        case .favorite(true): return "已加入收藏"
        case .favorite(false): return "已取消收藏"
        case .addToAlbum: return "已加入相册"
        case .createAlbum: return "已创建相册并加入照片"
        }
    }
}