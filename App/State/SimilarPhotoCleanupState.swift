import Combine
import Foundation
import ImageIQCore

/// A confirmation is tied to one published grouping and an exact ordered capture.
/// Dismissing it does not delete anything; only confirmDeletion submits a write.
struct SimilarPhotoDeletionIntent: Identifiable, Sendable {
    let id: UUID
    let sessionID: UUID
    let revisions: [PhotoRevision]
    let emptiedGroupCount: Int
    var count: Int { revisions.count }
}

/// Sheet-local, explicit reads and user-confirmed deletion only. No AppState,
/// persistence, automatic indexing, regrouping, keeper selection, or Photos calls.
@MainActor
final class SimilarPhotoCleanupState: ObservableObject {
    @Published var threshold: Float = SimilarPhotoGroupingPolicy.defaultThreshold {
        didSet {
            guard threshold != oldValue else { return }
            invalidateRead()
        }
    }
    @Published private(set) var groups: [SimilarPhotoGroup] = []
    @Published private(set) var progress = SimilarPhotoGroupingProgress()
    @Published private(set) var isGrouping = false
    @Published private(set) var isDeleting = false
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var message: String?
    @Published private(set) var hasScanned = false
    @Published private(set) var candidateCount = 0
    @Published private(set) var staleCount = 0
    @Published private(set) var unindexedCount = 0
    @Published private(set) var pendingDeletion: SimilarPhotoDeletionIntent?

    var selectedCount: Int { selectedIDs.count }
    var orderedSelectedPhotos: [IndexedPhoto] {
        groups.flatMap(\.photos).filter { selectedIDs.contains($0.id) }
    }

    private let grouping: any SimilarPhotoGrouping
    private let deletion: any PhotoDeleting
    // Validators belong to this exact published result, never a later query.
    private var result: SimilarPhotoGroupingResult?
    private var sessionID: UUID?
    private var generation = UUID()
    private var groupingTaskID: UUID?
    private var groupingTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var isForeground = true

    init(grouping: any SimilarPhotoGrouping, deletion: any PhotoDeleting) {
        self.grouping = grouping
        self.deletion = deletion
    }

    deinit {
        groupingTask?.cancel()
        // Never cancel mutationTask: it retains its service independently and
        // awaits the real outcome, including after this controller is released.
    }

    func scan() {
        guard isForeground, !isDeleting else { return }
        invalidateRead()
        message = nil
        do {
            try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        } catch {
            message = "请选择有效的相似度阈值后重新分组。"
            return
        }

        let predecessor = groupingTask
        let token = UUID()
        let requestedThreshold = threshold
        generation = token
        groupingTaskID = token
        isGrouping = true
        groupingTask = Task { @MainActor [weak self, grouping = self.grouping] in
            defer { self?.finishGrouping(token) }
            // Keep the entire cancelled tail, including queued replacements.
            // An uncooperative read must finish before another one can begin.
            await predecessor?.value
            guard !Task.isCancelled, self?.isCurrent(token) == true else { return }
            do {
                let snapshot = try await grouping.group(threshold: requestedThreshold) { [weak self] value in
                    await self?.publishProgress(value, token: token)
                }
                try Task.checkCancellation()
                guard let self, self.isCurrent(token) else { return }
                guard snapshot.threshold == requestedThreshold else {
                    self.progress = SimilarPhotoGroupingProgress()
                    self.message = Self.groupingFailureMessage
                    return
                }
                // Synchronous final access/revision check directly before
                // publication; no await between validation and the stored result.
                try snapshot.validateAccess()
                self.result = snapshot
                self.sessionID = token
                self.groups = snapshot.groups
                self.candidateCount = snapshot.candidateCount
                self.staleCount = snapshot.staleCount
                self.unindexedCount = snapshot.unindexedCount
                self.hasScanned = true
            } catch {
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                self.progress = SimilarPhotoGroupingProgress()
                if !(error is CancellationError) { self.message = Self.groupingFailureMessage }
            }
        }
    }

    func toggleSelection(_ id: String) {
        guard canSelect, let result,
              groups.contains(where: { $0.photos.contains(where: { $0.id == id }) }) else { return }
        do {
            try result.validatePhotos([id])
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
            pendingDeletion = nil
        } catch { selectionAccessFailed() }
    }

    /// Adds ALL members, including the last remaining photo. The confirmation
    /// carries a warning count rather than silently enforcing a keep-one rule.
    func selectGroup(_ groupID: String) {
        guard canSelect, let result, let group = groups.first(where: { $0.id == groupID }) else { return }
        let ids = group.photos.map(\.id)
        do {
            try result.validatePhotos(ids)
            let selected = selectedIDs.union(ids)
            if selected != selectedIDs {
                selectedIDs = selected
                pendingDeletion = nil
            }
        } catch { selectionAccessFailed() }
    }

    func clearSelection() {
        guard !isDeleting else { return }
        selectedIDs = []
        pendingDeletion = nil
    }

    func prepareDeletion() {
        guard canSelect, let result, let sessionID else { return }
        guard !selectedIDs.isEmpty else {
            pendingDeletion = nil
            message = PhotoDeletionError.emptySelection.localizedDescription
            return
        }
        let photos = orderedSelectedPhotos
        do {
            try result.validatePhotos(photos.map(\.id))
            let revisions = photos.map(Self.expectedPhotoRevision)
            guard revisions.count == selectedCount else { throw PhotoDeletionError.accessChanged }
            pendingDeletion = SimilarPhotoDeletionIntent(
                id: UUID(), sessionID: sessionID, revisions: revisions,
                emptiedGroupCount: groups.filter {
                    !$0.photos.isEmpty && $0.photos.allSatisfy { selectedIDs.contains($0.id) }
                }.count)
            message = nil
        } catch { selectionAccessFailed() }
    }

    func cancelDeletionConfirmation() { pendingDeletion = nil }

    func confirmDeletion(_ intent: SimilarPhotoDeletionIntent) {
        guard canSelect, let result, let pending = pendingDeletion,
              pending.id == intent.id else { return }
        // Reject stale/altered confirmation values, even if their UUID was copied.
        guard pending.sessionID == intent.sessionID, sessionID == intent.sessionID,
              pending.revisions == intent.revisions,
              pending.emptiedGroupCount == intent.emptiedGroupCount,
              !intent.revisions.isEmpty,
              intent.revisions == orderedSelectedPhotos.map(Self.expectedPhotoRevision),
              intent.count == selectedCount else {
            pendingDeletion = nil
            message = PhotoDeletionError.invalidSelection.localizedDescription
            return
        }
        do {
            try result.validatePhotos(intent.revisions.map(\.id))
        } catch {
            selectionAccessFailed()
            return
        }

        pendingDeletion = nil
        message = nil
        isDeleting = true
        mutationTask = Task { @MainActor [weak self, deletion = self.deletion, revisions = intent.revisions] in
            // Do not guard on self, cancel on UI changes, or check cancellation
            // after success. Only the service knows the actual mutation outcome.
            do {
                try await deletion.delete(revisions: revisions)
                self?.finishDeletion(message: "已删除\(revisions.count)张照片，照片可能位于系统“最近删除”中。请手动重新分组。")
            } catch {
                let text: String
                if error is CancellationError {
                    text = PhotoDeletionError.cancelled.localizedDescription
                } else {
                    text = (error as? PhotoDeletionError ?? .mutationFailed).localizedDescription
                }
                self?.finishDeletion(message: text)
            }
        }
    }

    /// Photos observations invalidate only READ state, including during deletion.
    /// Do not discard the mutation handle or its eventual real completion message.
    func invalidateAccess() { invalidateRead() }

    func pause() {
        isForeground = false
        invalidateRead()
    }

    func resume() { isForeground = true }
    func dismissMessage() { message = nil }

    /// Joins cancelled predecessors, replacements, and the independent mutation.
    func waitUntilIdle() async {
        while groupingTask != nil || mutationTask != nil {
            let read = groupingTask
            let write = mutationTask
            await read?.value
            await write?.value
        }
    }

    private var canSelect: Bool { isForeground && !isGrouping && !isDeleting && result != nil }

    private func isCurrent(_ token: UUID) -> Bool { isForeground && generation == token }

    private func publishProgress(_ value: SimilarPhotoGroupingProgress, token: UUID) {
        guard isCurrent(token), isGrouping else { return }
        progress = value
    }

    private func invalidateRead() {
        generation = UUID()
        groupingTask?.cancel()
        // Retain the tail until finishGrouping; later explicit scans must drain it.
        result = nil
        sessionID = nil
        groups = []
        selectedIDs = []
        pendingDeletion = nil
        progress = SimilarPhotoGroupingProgress()
        hasScanned = false
        candidateCount = 0
        staleCount = 0
        unindexedCount = 0
        isGrouping = false
    }

    private func finishGrouping(_ token: UUID) {
        if generation == token { isGrouping = false }
        if groupingTaskID == token {
            groupingTask = nil
            groupingTaskID = nil
        }
    }

    private func selectionAccessFailed() {
        invalidateRead()
        message = PhotoDeletionError.accessChanged.localizedDescription
    }

    private func finishDeletion(message: String) {
        // Failure is not proof of rollback, so discard stale suggestions on both
        // outcomes. This does not touch the saved image index or start a rescan.
        invalidateRead()
        mutationTask = nil
        isDeleting = false
        self.message = message
    }

    private nonisolated static func expectedPhotoRevision(_ photo: IndexedPhoto) -> PhotoRevision {
        PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
    }

    private static let groupingFailureMessage = "未能完成相似照片分组，请确认照片访问权限后手动重新分组。"
}