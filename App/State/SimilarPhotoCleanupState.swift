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

/// Page-scoped, restore-first automatic refresh and user-confirmed deletion.
/// Real source events and released thresholds request the latest target; lifecycle
/// notifications only admit pending work, never retry a failed/cancelled target.
/// No startup work, indexing, OCR, keeper selection or direct Photos calls.
@MainActor
final class SimilarPhotoCleanupState: ObservableObject {
    @Published var threshold: Float = SimilarPhotoGroupingPolicy.defaultThreshold {
        didSet {
            // Programmatic/legacy callers still commit immediately. The slider
            // uses setDraftThreshold + commitDraftThreshold instead. Internal
            // application must not overwrite a newer, unreleased draft.
            guard !applyingAutomaticThreshold else { return }
            draftThreshold = threshold
            draftNeedsCommit = false
            pendingThreshold = nil
            guard threshold != oldValue else { return }
            SimilarCleanupPreferences.save(threshold: threshold, in: preferences)
            let seen = hasEnteredPage || hasCompletedResult || groupingTask != nil
            invalidateRead()
            if seen { needsRegroup = true }
            refreshPending = true
            needsAutomaticRefreshRetry = false
            tryAutomaticEntry()
        }
    }
    @Published private(set) var draftThreshold: Float = SimilarPhotoGroupingPolicy.defaultThreshold
    @Published private(set) var resultThreshold: Float?
    @Published private(set) var groups: [SimilarPhotoGroup] = []
    @Published private(set) var displayGroups: [SimilarPhotoGroup] = []
    @Published private(set) var progress = SimilarPhotoGroupingProgress()
    @Published private(set) var isGrouping = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isReadDraining = false
    @Published private(set) var isPageVisible = false
    @Published private(set) var isAutomaticRefreshDeferred = false
    @Published private(set) var needsAutomaticRefreshRetry = false
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
    var hasPendingThresholdChange: Bool { draftThreshold != threshold }
    var canUpdateResults: Bool {
        isForeground && (!hasEnteredPage || (isPageVisible && pageReady))
            && !isAutomaticRefreshDeferred && !isReadDraining && !isGrouping && !isRestoring && !isDeleting && !isValidatingSelection
            && (!hasScanned || needsRegroup || hasPendingThresholdChange || hasStaleIndexRevision)
    }
    var canRetryAutomaticRefresh: Bool {
        automaticReadEligible && needsAutomaticRefreshRetry && groupingTask == nil
    }
    var selectionSessionID: UUID? { sessionID }
    var orderedSelectedPhotos: [IndexedPhoto] {
        groups.flatMap(\.photos).filter { selectedIDs.contains($0.id) }
    }

    private let grouping: any SimilarPhotoGrouping
    private let deletion: any PhotoDeleting
    private let preferences: UserDefaults?
    private let indexAccess: IndexAccessCoordinator?
    // Validators belong to this exact published result, never a later query.
    private var result: SimilarPhotoGroupingResult?
    private var resultIndexRevision: UInt64?
    private var displayNumbers: [String: Int] = [:]
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
    private var refreshPending = true
    private var pendingThreshold: Float?
    private var draftNeedsCommit = false
    private var applyingAutomaticThreshold = false
    private var observedIndexRevision: UInt64?
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

    init(grouping: any SimilarPhotoGrouping, deletion: any PhotoDeleting, preferences: UserDefaults? = nil,
         indexAccess: IndexAccessCoordinator? = nil) {
        self.grouping = grouping
        self.deletion = deletion
        self.preferences = preferences
        self.indexAccess = indexAccess
        self.observedIndexRevision = indexAccess?.revision
        let saved = SimilarCleanupPreferences.threshold(in: preferences)
        self.threshold = saved
        self.draftThreshold = saved
    }

    deinit {
        groupingTask?.cancel()
        selectionTask?.cancel()
        // Never cancel mutationTask: it retains its service independently and
        // awaits the real outcome, including after this controller is released.
    }

    func displayNumber(for groupID: String) -> Int? { displayNumbers[groupID] }

    /// Editing is not a commit, persistence write or request to recompute. An
    /// existing result (even one finishing now) keeps its requested threshold.
    func setDraftThreshold(_ value: Float) {
        guard canChangeThreshold, draftThreshold != value else { return }
        cancelRangeSelection()
        pendingDeletion = nil
        draftThreshold = value
        draftNeedsCommit = value != threshold
        // An older released value waiting behind a drain is superseded by this
        // edit, but the new value is NOT eligible until its own release.
        pendingThreshold = nil
    }

    /// Slider release (also call after an accessibility/programmatic draft edit).
    /// Repeated release callbacks for the same target are not retry requests.
    func commitDraftThreshold() {
        guard canChangeThreshold else { return }
        draftNeedsCommit = false
        guard draftThreshold != (pendingThreshold ?? threshold) else {
            tryAutomaticEntry()
            return
        }
        pendingThreshold = draftThreshold
        requestAutomaticRefresh()
    }

    /// The UI supplies true throughout sync checking/updating/cancelling, and
    /// false only once it has drained. This is an admission gate, not a timer.
    /// Repeated values neither invalidate results nor retry suppressed targets.
    func setAutomaticRefreshDeferred(_ value: Bool) {
        guard isAutomaticRefreshDeferred != value else { return }
        isAutomaticRefreshDeferred = value
        if value {
            cancelRangeSelection()
            pendingDeletion = nil
            suspendActiveRead()
        } else {
            if hasStaleIndexRevision { indexSourceChanged() }
            tryAutomaticEntry()
        }
    }

    /// Explicit user stop, unlike a lifecycle suspension. Suppression survives
    /// tab/readiness/foreground/defer round trips and message dismissal. A real
    /// source event, changed released threshold or explicit retry rearms it.
    /// This never cancels or detaches an already submitted deletion.
    func cancelAutomaticRefresh() {
        guard refreshPending || groupingTask != nil else { return }
        refreshPending = false
        needsAutomaticRefreshRetry = true
        invalidateRead(preservingBrowsing: hasEnteredPage)
        if hasScanned { needsRegroup = true }
    }

    func retryAutomaticRefresh() {
        guard canRetryAutomaticRefresh else { return }
        requestAutomaticRefresh()
    }

    /// UI-only explicit commit. Unlike legacy scan(), repeated taps cannot
    /// replace/cancel the currently running read or queue another computation.
    func updateResults() {
        guard canUpdateResults else { return }
        // A failed/rolled-back writer advances revision without a commit event.
        // Clear old selection and choose cache restore before starting this read.
        if hasStaleIndexRevision, !hasEnteredPage { indexSourceChanged() }
        do {
            try SimilarPhotoGroupingPolicy.validate(threshold: draftThreshold)
        } catch {
            recordFailure(SimilarCleanupDiagnostic(phase: .compute, code: .invalidIndex), operation: .group)
            return
        }
        cancelRangeSelection()
        if hasEnteredPage {
            draftNeedsCommit = false
            pendingThreshold = draftThreshold
            requestAutomaticRefresh()
            return
        }
        let restoreUnchangedThreshold = needsRegroup && !hasPendingThresholdChange && resultThreshold == threshold
        threshold = draftThreshold
        if restoreUnchangedThreshold {
            // An index revision can change for irrelevant metadata. On this
            // explicit request only, let the backend compare its full cache key
            // before paying for pairwise grouping again. No commit-triggered work.
            refreshPending = false
            needsAutomaticRefreshRetry = false
            invalidateRead()
            message = nil
            deletionNotice = nil
            startRead(restoring: true, mayCompute: true, recomputeStale: true)
        } else {
            scan()
        }
    }

    func scan() {
        guard isForeground, !isDeleting, !isAutomaticRefreshDeferred else { return }
        refreshPending = false
        pendingThreshold = nil
        needsAutomaticRefreshRetry = false
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
        suspendActiveRead()
    }

    /// Ready includes permission, model/index statistics and absence of app work.
    /// A notification is not an instruction to retry a failed/cancelled grouping.
    func availabilityChanged(ready: Bool) {
        pageReady = ready
        if !ready {
            cancelRangeSelection()
            pendingDeletion = nil
            suspendActiveRead()
        }
        tryAutomaticEntry()
    }

    private var automaticReadEligible: Bool {
        hasEnteredPage && isPageVisible && isForeground && pageReady
            && !isAutomaticRefreshDeferred && !isDeleting && !draftNeedsCommit
    }

    private func requestAutomaticRefresh() {
        refreshPending = true
        needsAutomaticRefreshRetry = false
        invalidateRead(preservingBrowsing: true)
        if hasScanned { needsRegroup = true }
        tryAutomaticEntry()
    }

    private func suspendActiveRead() {
        guard isGrouping || isRestoring else { return }
        refreshPending = true
        invalidateRead(preservingBrowsing: hasEnteredPage)
    }

    private func tryAutomaticEntry() {
        // A single pending target coalesces all events while deferred, hidden,
        // mutating or draining. Do not lose the cancelled predecessor's handle.
        guard automaticReadEligible, groupingTask == nil, refreshPending,
              !needsAutomaticRefreshRetry else { return }
        refreshPending = false
        let target = pendingThreshold ?? threshold
        // A delayed Photos notification may arrive after mutation completion.
        // Cache classification must not erase that real outcome notice.
        if message != deletionNotice { message = nil }
        do {
            try SimilarPhotoGroupingPolicy.validate(threshold: target)
        } catch {
            recordFailure(SimilarCleanupDiagnostic(phase: .photos, code: .invalidIndex), operation: .restore)
            return
        }
        // Only an admitted latest request applies/persists a slider release.
        // A queued/cancelled intermediate target must never replace preferences.
        if pendingThreshold != nil {
            applyingAutomaticThreshold = true
            threshold = target
            applyingAutomaticThreshold = false
            SimilarCleanupPreferences.save(threshold: target, in: preferences)
            pendingThreshold = nil
        }
        invalidateRead(preservingBrowsing: true)
        startRead(restoring: true, mayCompute: true, recomputeStale: true)
    }

    /// Both restore and grouping share a retained drain chain. The missing-cache
    /// branch groups inline, never calls scan() from a task that scan must join.
    private func startRead(restoring: Bool, mayCompute: Bool, recomputeStale: Bool = false) {
        failureDiagnostic = nil
        failureOperation = nil
        let predecessor = groupingTask
        let token = UUID()
        let requestedThreshold = threshold
        generation = token
        groupingTaskID = token
        requiresVisiblePage = restoring && hasEnteredPage
        isRestoring = restoring
        isGrouping = !restoring
        groupingTask = Task { @MainActor [weak self, grouping = self.grouping, indexAccess = self.indexAccess] in
            defer { self?.finishGrouping(token) }
            // Keep the entire cancelled tail, including queued replacements.
            // An uncooperative read must finish before another one can begin.
            await predecessor?.value
            guard !Task.isCancelled, self?.isCurrent(token) == true else { return }
            // Local to this task, not a shared actor property: missing-cache
            // computation and publication must not be mislabeled as restore.
            var operation: SimilarCleanupOperation = restoring ? .restore : .group
            do {
                // Hold one front-read lease across restore, an optional missing
                // cache computation, off-main validation and MainActor publish.
                let lease = try await indexAccess?.acquireRead()
                defer { lease?.release() }
                try Task.checkCancellation()
                guard self?.isCurrent(token) == true else { return }
                let revision = indexAccess?.revision
                self?.observedIndexRevision = revision
                if restoring {
                    let restored = try await grouping.restore(threshold: requestedThreshold)
                    try Task.checkCancellation()
                    guard self?.isCurrent(token) == true else { return }
                    switch restored {
                    case .awaitingDeletion:
                        // Do not compute against an enumeration which still
                        // contains confirmed deletions, and do not self-retry.
                        // A real Photos/index event or explicit retry rearms it.
                        self?.needsRegroup = true
                        self?.needsAutomaticRefreshRetry = true
                        return
                    case .restored(let snapshot):
                        operation = .publication
                        try await self?.publish(snapshot, threshold: requestedThreshold, token: token, indexRevision: revision)
                        return
                    case .stale:
                        guard recomputeStale else {
                            self?.needsRegroup = true
                            return
                        }
                        self?.isRestoring = false
                        self?.isGrouping = true
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
                try await self?.publish(snapshot, threshold: requestedThreshold, token: token, indexRevision: revision)
            } catch {
                guard let self, self.isCurrent(token), !Task.isCancelled else { return }
                self.progress = SimilarPhotoGroupingProgress()
                self.refreshPending = false
                self.needsAutomaticRefreshRetry = true
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
                         token: UUID, indexRevision: UInt64?) async throws {
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
            guard indexRevisionIsCurrent(indexRevision) else { return }
            result = snapshot
            resultIndexRevision = indexRevision
            resultThreshold = requestedThreshold
            sessionID = token
            groups = snapshot.groups
            displayGroups = SimilarGroupPresentation.sortedGroups(snapshot.groups)
            displayNumbers = Dictionary(uniqueKeysWithValues: displayGroups.enumerated().map { ($0.element.id, $0.offset + 1) })
            candidateCount = snapshot.candidateCount
            staleCount = snapshot.staleCount
            unindexedCount = snapshot.unindexedCount
            persistenceIssue = snapshot.persistenceIssue
            hasScanned = true
            hasCompletedResult = true
            needsRegroup = false
            needsAutomaticRefreshRetry = false
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.readDiagnostic(error, phase: .publication)
        }
    }

    func toggleSelection(_ id: String) {
        let lease = indexAccess?.tryRead()
        guard indexAccess == nil || lease != nil else { return }
        defer { lease?.release() }
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
        let lease = indexAccess?.tryRead()
        guard indexAccess == nil || lease != nil else { return }
        defer { lease?.release() }
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
        let lease = indexAccess?.tryRead()
        guard indexAccess == nil || lease != nil else { return nil }
        defer { lease?.release() }
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
        selectionTask = Task { @MainActor [weak self, indexAccess = self.indexAccess] in
            defer { self?.finishSelectionTask(token) }
            // Retain cancelled predecessors, even queued ones. New actions may
            // invalidate them immediately, but cannot lose their drain handles.
            await predecessor?.value
            guard !Task.isCancelled, self?.isCurrentSelection(capture) == true else { return }
            var lease: IndexAccessCoordinator.Lease?
            // Keep the lease through error handling too: releasing to a queued
            // writer first would change revision and mask a genuine failure.
            defer { lease?.release() }
            do {
                lease = try await indexAccess?.acquireRead()
                try Task.checkCancellation()
                // Same canSelect authority gate, excluding only this capture's
                // own isSelecting flag; queued writes may have changed revision.
                guard self?.isCurrentSelection(capture) == true else { return }
                try await Self.validateSelectionPhotos(changedIDs, result: capture.result)
                try Task.checkCancellation()
                guard let self, self.isCurrentSelection(capture) else { return }
                try capture.result.validatePublicationEpoch()
                guard self.indexRevisionIsCurrent(self.resultIndexRevision) else { return }
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
        let lease = indexAccess?.tryRead()
        guard indexAccess == nil || lease != nil else { return }
        defer { lease?.release() }
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
        // Only synchronous preflight is a source-index read. Do not retain the
        // lease in the Photos task; its existing service owns all Photos checks.
        let lease = indexAccess?.tryRead()
        guard indexAccess == nil || lease != nil else { return }
        defer { lease?.release() }
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
        mutationTask = Task { @MainActor [weak self, deletion = self.deletion, grouping = self.grouping,
                          revisions = intent.revisions, baselineID = result.deletionBaselineID] in
            // Do not guard on self, cancel on UI changes, or check cancellation
            // after success. Only the service knows the actual mutation outcome.
            do {
                try await deletion.delete(revisions: revisions)
                // Capture was validated against this exact published session
                // BEFORE submission. Keep mutation admission closed until the
                // successful outcome is registered, even if a Photos callback
                // has already cleared UI access or this controller was released.
                await grouping.confirmedDeletion(revisions: revisions, baselineID: baselineID)
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

    /// Index commits are not Photos permission events. Keep the completed view
    /// and its navigation identity, but never keep its selection authority.
    /// The parent calls this separately from the Photos/library epoch callback.
    func indexSourceChanged() {
        // With a coordinator, repeated notifications for an observed revision
        // are not new events (including after failure/cancellation). A queued
        // writer has not advanced that revision yet. Without one, each callback
        // is an actual source event supplied by the parent.
        if let indexAccess {
            guard observedIndexRevision != indexAccess.revision else { return }
            observedIndexRevision = indexAccess.revision
        }
        // Preserve the standalone legacy read's lease/capture contract.
        if !hasEnteredPage, isGrouping || isRestoring { return }
        guard hasEnteredPage || hasCompletedResult || hasScanned else { return }
        requestAutomaticRefresh()
    }

    /// Photos observations invalidate only READ state, including during deletion.
    /// Do not discard the mutation handle or its eventual real completion message.
    func invalidateAccess() {
        if hasEnteredPage {
            // Access can be revoked or reduced: unlike an index-only commit,
            // it must immediately remove old Photos content from browsing too.
            invalidateRead()
            requestAutomaticRefresh()
        }
        else {
            invalidateRead()
            refreshPending = true
            needsAutomaticRefreshRetry = false
        }
    }

    func pause() {
        isForeground = false
        if !needsAutomaticRefreshRetry, result != nil || isGrouping || isRestoring {
            refreshPending = true
        }
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
        canSelectResult && !isSelecting && (indexAccess?.canReadImmediately ?? true)
    }

    private var canSelectResult: Bool {
        isForeground && (!hasEnteredPage || (isPageVisible && pageReady))
            && !isAutomaticRefreshDeferred && !isGrouping && !isRestoring && !needsRegroup && !isDeleting && result != nil
            && !hasPendingThresholdChange && indexRevisionIsCurrent(resultIndexRevision)
    }

    private var hasStaleIndexRevision: Bool {
        guard let indexAccess, let resultIndexRevision else { return false }
        return resultIndexRevision != indexAccess.revision
    }

    private func indexRevisionIsCurrent(_ revision: UInt64?) -> Bool {
        guard let indexAccess else { return true }
        return revision == indexAccess.revision && !indexAccess.isWriting
    }

    private func isCurrentSelection(_ capture: RangeSelectionCapture) -> Bool {
        canSelectResult && isSelecting
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

    private func invalidateRead(preservingBrowsing: Bool = false) {
        cancelRangeSelection()
        generation = UUID()
        groupingTask?.cancel()
        isReadDraining = groupingTask != nil
        // Retain the tail until finishGrouping; later explicit scans must drain it.
        result = nil
        resultIndexRevision = nil
        // Retain only the presentation identity for safe index-only browsing.
        // result=nil plus generation/revision fences revoke ALL selection and
        // immutable confirmations; fresh publication assigns a new session.
        if !preservingBrowsing { sessionID = nil }
        selectedIDs = []
        pendingDeletion = nil
        progress = SimilarPhotoGroupingProgress()
        if !preservingBrowsing {
            resultThreshold = nil
            groups = []
            displayGroups = []
            displayNumbers = [:]
            hasScanned = false
            candidateCount = 0
            staleCount = 0
            unindexedCount = 0
        }
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
            // Publish completion even when generation was already revoked, so
            // retry controls can become available after an uncooperative tail.
            isReadDraining = false
            tryAutomaticEntry()
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
        refreshPending = false
        needsAutomaticRefreshRetry = true
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
        refreshPending = false
        needsAutomaticRefreshRetry = true
        failureDiagnostic = diagnostic
        failureOperation = operation
        // One shared safe formatter, with the code/phase first in the ordinary
        // alert (no duplicate marker and no debug UI required).
        message = diagnostic.message(operation: operation)
    }

    private func finishDeletion(message: String) {
        // Failure is not proof of rollback, so discard stale suggestions on both
        // outcomes. Only after the mutation completes may the pending automatic
        // read start; its notice survives restoration and delayed source events.
        invalidateRead()
        needsRegroup = true
        refreshPending = true
        needsAutomaticRefreshRetry = false
        mutationTask = nil
        isDeleting = false
        failureDiagnostic = nil
        failureOperation = nil
        deletionNotice = message
        self.message = message
        tryAutomaticEntry()
    }

    private nonisolated static func expectedPhotoRevision(_ photo: IndexedPhoto) -> PhotoRevision {
        PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
    }
}