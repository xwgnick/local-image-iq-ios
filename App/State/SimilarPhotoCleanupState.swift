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

/// Page-scoped reads and user-confirmed deletion. Only the first ready foreground
/// entry may compute automatically, after checking the backend's completed cache.
/// No startup work, indexing, OCR, keeper selection or direct Photos calls.
@MainActor
final class SimilarPhotoCleanupState: ObservableObject {
    @Published var threshold: Float = SimilarPhotoGroupingPolicy.defaultThreshold {
        didSet {
            guard threshold != oldValue else { return }
            SimilarCleanupPreferences.save(threshold: threshold, in: preferences)
            let seen = hasEnteredPage || autoAttemptConsumed || hasCompletedResult
            invalidateRead()
            if seen {
                needsRegroup = true
                autoAttemptConsumed = true
                restoreNeeded = false
            }
        }
    }
    @Published private(set) var groups: [SimilarPhotoGroup] = []
    @Published private(set) var progress = SimilarPhotoGroupingProgress()
    @Published private(set) var isGrouping = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isPageVisible = false
    @Published private(set) var needsRegroup = false
    @Published private(set) var persistenceIssue: String?
    @Published private(set) var isValidating = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isSelecting = false
    @Published private(set) var isValidatingSelection = false
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var message: String?
    @Published private(set) var failureDiagnostic: SimilarCleanupDiagnostic?
    @Published private(set) var failureOperation: SimilarCleanupOperation?
    @Published private(set) var hasScanned = false
    @Published private(set) var candidateCount = 0
    @Published private(set) var staleCount = 0
    @Published private(set) var unindexedCount = 0
    @Published private(set) var pendingDeletion: SimilarPhotoDeletionIntent?

    var selectedCount: Int { selectedIDs.count }
    var canChangeThreshold: Bool { !isDeleting }
    var selectionSessionID: UUID? { sessionID }
    var orderedSelectedPhotos: [IndexedPhoto] {
        groups.flatMap(\.photos).filter { selectedIDs.contains($0.id) }
    }

    private let grouping: any SimilarPhotoGrouping
    private let deletion: any PhotoDeleting
    private let preferences: UserDefaults?
    // Validators belong to this exact published result, never a later query.
    private var result: SimilarPhotoGroupingResult?
    private var sessionID: UUID?
    private var generation = UUID()
    private var groupingTaskID: UUID?
    private var groupingTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var rangeSelection: RangeSelectionCapture?
    private var selectionTaskID: UUID?
    private var selectionTask: Task<Void, Never>?
    private var deletionNotice: String?
    private var isForeground = true
    private var hasEnteredPage = false
    private var pageReady = false
    // History is independent of visible counts: a successful zero is completed.
    private var hasCompletedResult = false
    private var autoAttemptConsumed = false
    private var restoreNeeded = true
    private var requiresVisiblePage = false

    private struct RangeSelectionCapture {
        let token: UUID
        let sessionID: UUID
        let generation: UUID
        let groupID: String
        let photoIDs: [String]
        let members: Set<String>
        let baseSelectedIDs: Set<String>
        let result: SimilarPhotoGroupingResult
    }

    init(grouping: any SimilarPhotoGrouping, deletion: any PhotoDeleting, preferences: UserDefaults? = nil) {
        self.grouping = grouping
        self.deletion = deletion
        self.preferences = preferences
        self.threshold = SimilarCleanupPreferences.threshold(in: preferences)
    }

    deinit {
        groupingTask?.cancel()
        selectionTask?.cancel()
        // Never cancel mutationTask: it retains its service independently and
        // awaits the real outcome, including after this controller is released.
    }

    func scan() {
        guard isForeground, !isDeleting else { return }
        autoAttemptConsumed = true
        restoreNeeded = false
        invalidateRead()
        message = nil
        deletionNotice = nil
        do {
            try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        } catch {
            recordFailure(SimilarCleanupDiagnostic(phase: .compute, code: .invalidIndex), operation: .group)
            return
        }
        startRead(restoring: false, mayCompute: true)
    }

    /// Visibility does not imply foreground. The root owns pause()/resume().
    func enterPage(ready: Bool) {
        hasEnteredPage = true
        isPageVisible = true
        availabilityChanged(ready: ready)
    }

    /// Search gets priority over pending reads. Completed live groups and their
    /// committed selection remain intact unless access/inputs are invalidated.
    func leavePage() {
        isPageVisible = false
        cancelRangeSelection()
        pendingDeletion = nil
        if isGrouping || isRestoring {
            restoreNeeded = true
            invalidateRead()
        }
    }

    /// Ready includes permission, model/index statistics and absence of app work.
    /// A notification is not an instruction to retry a failed/cancelled grouping.
    func availabilityChanged(ready: Bool) {
        pageReady = ready
        if !ready {
            cancelRangeSelection()
            pendingDeletion = nil
            if isGrouping || isRestoring {
                restoreNeeded = true
                invalidateRead()
            }
        }
        tryAutomaticEntry()
    }

    private func tryAutomaticEntry() {
        guard isPageVisible, isForeground, pageReady, !isDeleting,
              !isGrouping, !isRestoring, restoreNeeded else { return }
        let mayCompute = !autoAttemptConsumed && !hasCompletedResult && !needsRegroup
        autoAttemptConsumed = true
        restoreNeeded = false
        invalidateRead()
        // A delayed Photos notification may arrive after mutation completion.
        // Cache classification must not erase that real outcome notice.
        if message != deletionNotice { message = nil }
        do {
            try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        } catch {
            recordFailure(SimilarCleanupDiagnostic(phase: .photos, code: .invalidIndex), operation: .restore)
            return
        }
        startRead(restoring: true, mayCompute: mayCompute)
    }

    /// Both restore and grouping share a retained drain chain. The missing-cache
    /// branch groups inline, never calls scan() from a task that scan must join.
    private func startRead(restoring: Bool, mayCompute: Bool) {
        failureDiagnostic = nil
        failureOperation = nil
        let predecessor = groupingTask
        let token = UUID()
        let requestedThreshold = threshold
        generation = token
        groupingTaskID = token
        requiresVisiblePage = restoring
        isRestoring = restoring
        isGrouping = !restoring
        groupingTask = Task { @MainActor [weak self, grouping = self.grouping] in
            defer { self?.finishGrouping(token) }
            // Keep the entire cancelled tail, including queued replacements.
            // An uncooperative read must finish before another one can begin.
            await predecessor?.value
            guard !Task.isCancelled, self?.isCurrent(token) == true else { return }
            // Local to this task, not a shared actor property: missing-cache
            // computation and publication must not be mislabeled as restore.
            var operation: SimilarCleanupOperation = restoring ? .restore : .group
            do {
                if restoring {
                    let restored = try await grouping.restore(threshold: requestedThreshold)
                    try Task.checkCancellation()
                    guard self?.isCurrent(token) == true else { return }
                    switch restored {
                    case .restored(let snapshot):
                        operation = .publication
                        try await self?.publish(snapshot, threshold: requestedThreshold, token: token)
                        return
                    case .stale:
                        self?.needsRegroup = true
                        return
                    case .missing:
                        guard mayCompute else {
                            self?.needsRegroup = true
                            return
                        }
                        self?.isRestoring = false
                        self?.isGrouping = true
                    }
                }
                operation = .group
                let snapshot = try await grouping.group(threshold: requestedThreshold) { [weak self] value in
                    await self?.publishProgress(value, token: token)
                }
                try Task.checkCancellation()
                operation = .publication
                try await self?.publish(snapshot, threshold: requestedThreshold, token: token)
            } catch {
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                self.progress = SimilarPhotoGroupingProgress()
                guard !(error is CancellationError) else { return }
                // Production service errors already carry their exact phase.
                // Untyped injected/legacy failures get only the known boundary.
                let phase: SimilarCleanupPhase = operation == .publication ? .publication
                    : operation == .group ? .compute : .photos
                self.recordFailure(Self.readDiagnostic(error, phase: phase), operation: operation)
            }
        }
    }

    private func publish(_ snapshot: SimilarPhotoGroupingResult, threshold requestedThreshold: Float,
                         token: UUID) async throws {
        do {
            guard isCurrent(token) else { return }
            guard snapshot.threshold == requestedThreshold else {
                throw SimilarCleanupDiagnostic(phase: .publication, code: .invalidIndex)
            }
            // Full-member validation stays on the generic executor for both paths.
            isValidating = true
            try await snapshot.prepareForPublication()
            try Task.checkCancellation()
            guard isCurrent(token), threshold == requestedThreshold else { return }
            // No suspension between the cheap authority fence and publication.
            try snapshot.validatePublicationEpoch()
            result = snapshot
            sessionID = token
            groups = snapshot.groups
            candidateCount = snapshot.candidateCount
            staleCount = snapshot.staleCount
            unindexedCount = snapshot.unindexedCount
            persistenceIssue = snapshot.persistenceIssue
            hasScanned = true
            hasCompletedResult = true
            needsRegroup = false
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.readDiagnostic(error, phase: .publication)
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
        } catch { selectionAccessFailed(error: error) }
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
        } catch { selectionAccessFailed(error: error) }
    }

    /// Captures committed state only. Hover/drag updates stay in the pure UI
    /// model; this entry performs only an epoch check, never a PhotoKit batch.
    func beginRangeSelection(groupID: String) -> UUID? {
        guard canSelect, let result, let sessionID,
              let group = groups.first(where: { $0.id == groupID }) else { return nil }
        do {
            try result.validatePublicationEpoch()
        } catch {
            selectionAccessFailed(error: error)
            return nil
        }
        let token = UUID()
        let ids = group.photos.map(\.id)
        rangeSelection = RangeSelectionCapture(token: token, sessionID: sessionID,
            generation: generation, groupID: groupID, photoIDs: ids, members: Set(ids),
            baseSelectedIDs: selectedIDs, result: result)
        pendingDeletion = nil
        isSelecting = true
        return token
    }

    /// EXACT desired membership inside the captured group, not a toggle list.
    /// Reject foreign IDs rather than silently selecting them or filtering them.
    /// All additions AND removals are validated together off MainActor, then
    /// published once behind the result's cheap synchronous epoch fence.
    func finishRangeSelection(token: UUID, selectedInGroup: Set<String>) {
        guard let capture = rangeSelection, capture.token == token,
              selectionTaskID != token, isCurrentSelection(capture) else { return }
        guard selectedInGroup.isSubset(of: capture.members) else {
            cancelRangeSelection()
            return
        }
        let desired = capture.baseSelectedIDs.subtracting(capture.members).union(selectedInGroup)
        let changed = capture.baseSelectedIDs.symmetricDifference(desired)
        let changedIDs = capture.photoIDs.filter { changed.contains($0) }
        let predecessor = selectionTask
        isValidatingSelection = true
        selectionTaskID = token
        selectionTask = Task { @MainActor [weak self] in
            defer { self?.finishSelectionTask(token) }
            // Retain cancelled predecessors, even queued ones. New actions may
            // invalidate them immediately, but cannot lose their drain handles.
            await predecessor?.value
            guard !Task.isCancelled, self?.isCurrentSelection(capture) == true else { return }
            do {
                try await Self.validateSelectionPhotos(changedIDs, result: capture.result)
                try Task.checkCancellation()
                guard let self, self.isCurrentSelection(capture) else { return }
                try capture.result.validatePublicationEpoch()
                // No suspension between the last fence and the single publish.
                self.selectedIDs = desired
                self.pendingDeletion = nil
            } catch {
                guard let self, !Task.isCancelled, self.isCurrentSelection(capture) else { return }
                self.selectionAccessFailed(error: error)
            }
        }
    }

    /// Cancellation never changes committed selection or writes to Photos.
    /// The handle remains joinable until even an uncooperative validator drains.
    func cancelRangeSelection() {
        rangeSelection = nil
        selectionTask?.cancel()
        isValidatingSelection = false
        isSelecting = false
    }

    func clearSelection() {
        cancelRangeSelection()
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
        } catch { selectionAccessFailed(error: error) }
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
            selectionAccessFailed(error: error)
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
                self?.finishDeletion(message: PhotoDeletionRecoveryNotice.success(count: revisions.count))
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
    func invalidateAccess() {
        invalidateRead()
        restoreNeeded = true
        // Do not infer stale from a notification or from counts alone. The
        // backend distinguishes irrelevant changes using fresh full validators.
        if hasEnteredPage { tryAutomaticEntry() }
    }

    func pause() {
        isForeground = false
        if result != nil || isGrouping || isRestoring { restoreNeeded = true }
        invalidateRead()
    }

    func resume() {
        isForeground = true
        tryAutomaticEntry()
    }
    func dismissMessage() {
        message = nil
        deletionNotice = nil
        failureDiagnostic = nil
        failureOperation = nil
    }

    /// Joins cancelled read/selection tails, replacements and independent mutation.
    func waitUntilIdle() async {
        while groupingTask != nil || selectionTask != nil || mutationTask != nil {
            let read = groupingTask
            let selection = selectionTask
            let write = mutationTask
            await read?.value
            await selection?.value
            await write?.value
        }
    }

    var canSelect: Bool {
        isForeground && (!hasEnteredPage || (isPageVisible && pageReady))
            && !isGrouping && !isRestoring && !needsRegroup && !isDeleting && !isSelecting && result != nil
    }

    private func isCurrentSelection(_ capture: RangeSelectionCapture) -> Bool {
        isForeground && (!hasEnteredPage || (isPageVisible && pageReady))
            && !isGrouping && !isRestoring && !needsRegroup && !isDeleting && isSelecting
            && rangeSelection?.token == capture.token
            && sessionID == capture.sessionID && generation == capture.generation
            && selectedIDs == capture.baseSelectedIDs
    }

    private func finishSelectionTask(_ token: UUID) {
        if rangeSelection?.token == token {
            rangeSelection = nil
            isValidatingSelection = false
            isSelecting = false
        }
        if selectionTaskID == token {
            selectionTask = nil
            selectionTaskID = nil
        }
    }

    /// Like prepareForPublication, non-actor async runs on the Swift 5 generic
    /// executor. Never call the synchronous metadata closure from a hover event.
    private nonisolated static func validateSelectionPhotos(
        _ ids: [String], result: SimilarPhotoGroupingResult
    ) async throws {
        try Task.checkCancellation()
        if !ids.isEmpty { try result.validatePhotos(ids) }
        try Task.checkCancellation()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        isForeground && generation == token && (!requiresVisiblePage || (isPageVisible && pageReady))
    }

    private func publishProgress(_ value: SimilarPhotoGroupingProgress, token: UUID) {
        guard isCurrent(token), isGrouping else { return }
        progress = value
    }

    private func invalidateRead() {
        cancelRangeSelection()
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
        isRestoring = false
        isValidating = false
        persistenceIssue = nil
    }

    private func finishGrouping(_ token: UUID) {
        if generation == token {
            isGrouping = false
            isRestoring = false
            isValidating = false
        }
        if groupingTaskID == token {
            groupingTask = nil
            groupingTaskID = nil
        }
    }

    private func selectionAccessFailed(error: Error) {
        // Capture cancellation/cause BEFORE invalidateRead cancels selectionTask
        // (which can be this very task). Self-cancellation during invalidation
        // must not suppress a genuine range-validation failure.
        let cancelled = error is CancellationError || Task.isCancelled
            || (error as? PhotoDeletionError) == .cancelled
        let diagnostic = cancelled ? nil : Self.readDiagnostic(error, phase: .selection)
        invalidateRead()
        restoreNeeded = true
        // A cancelled read still invalidates unsafe selection, but is not a
        // permission/storage failure and must never surface a new diagnostic.
        guard let diagnostic else { return }
        recordFailure(diagnostic, operation: .selection)
    }

    private nonisolated static func readDiagnostic(_ error: Error, phase: SimilarCleanupPhase) -> SimilarCleanupDiagnostic {
        // These are existing typed READ/selection checks, not mutation errors.
        // Never use PhotoDeletionError.sanitized here: it discards unknown causes.
        if let deletionError = error as? PhotoDeletionError {
            return SimilarCleanupDiagnostic(phase: phase,
                code: deletionError == .permissionDenied ? .permissionDenied : .photoAccessChanged)
        }
        return SimilarCleanupDiagnostic.classify(error, phase: phase)
    }

    private func recordFailure(_ diagnostic: SimilarCleanupDiagnostic, operation: SimilarCleanupOperation) {
        failureDiagnostic = diagnostic
        failureOperation = operation
        // One shared safe formatter, with the code/phase first in the ordinary
        // alert (no duplicate marker and no debug UI required).
        message = diagnostic.message(operation: operation)
    }

    private func finishDeletion(message: String) {
        // Failure is not proof of rollback, so discard stale suggestions on both
        // outcomes. This does not touch the saved image index or start a rescan.
        invalidateRead()
        autoAttemptConsumed = true
        needsRegroup = true
        restoreNeeded = false
        mutationTask = nil
        isDeleting = false
        failureDiagnostic = nil
        failureOperation = nil
        deletionNotice = message
        self.message = message
    }

    private nonisolated static func expectedPhotoRevision(_ photo: IndexedPhoto) -> PhotoRevision {
        PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
    }
}