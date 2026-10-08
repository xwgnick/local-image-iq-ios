import Foundation
import Combine

/// One automatic image-index job, independent of AppState's foreground queue.
/// Cancellation requests stop dispatch; only the service's return proves that
/// its structured children (including noninterruptible predictions) have drained.
@MainActor
final class PhotoSyncState: ObservableObject {
    enum Phase: Sendable, Equatable {
        case idle, checking, updating, cancelling, cancelled, completed, needsAttention, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = PhotoSyncProgress()
    @Published private(set) var failureMessage: String?

    var visible: Bool { phase != .idle }
    var canCancel: Bool { task != nil && (phase == .checking || phase == .updating) }
    var canRestart: Bool {
        isEnabled && ready && task == nil && phase != .checking && phase != .updating && phase != .cancelling
    }
    var isEnabled: Bool { service != nil }

    /// Callbacks are synchronous on MainActor. No search-session invalidation is
    /// implied by a commit. Retained late service callbacks are generation-fenced.
    /// The owner schedules currentSummary separately: do not await metadata here
    /// or bind that read to the cancelled sync task. A won commit may arrive while
    /// cancelling and must still make the durable prefix available for search.
    var onCommitted: @MainActor () -> Void = {}
    var onCompleted: @MainActor (LibrarySummary) -> Void = { _ in }
    /// Runs once after the current job drains, even for failure or cancellation.
    /// A settled write attempt is not a committed record or successful summary.
    var onSettled: @MainActor () -> Void = {}

    private let service: (any PhotoSyncServicing)?
    private let completionDelay: @Sendable () async throws -> Void
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private var stopping = false
    // The floating card observes this object, not its AppState parent. Readiness
    // must publish even when a persistent cancelled/failed phase is unchanged.
    @Published private var ready = false
    private var networkAllowed = false
    private var pending = true
    private var userSuppressed = false
    private var failureRequiresRestart = false
    private var completionTask: Task<Void, Never>?
    private var completionToken: UUID?

    init(service: (any PhotoSyncServicing)? = nil,
         completionDelay: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .seconds(3))
         }) {
        self.service = service
        self.completionDelay = completionDelay
    }

    deinit {
        task?.cancel()
        completionTask?.cancel()
    }

    /// Repeated ready publications (e.g. search finishing) are not new events.
    /// An actual foreground/readiness edge or network choice requests a fresh
    /// diff, but never overrides user cancellation or an unknown failure.
    func updateAvailability(ready: Bool, networkAllowed: Bool) {
        let becameReady = ready && !self.ready
        let networkChanged = networkAllowed != self.networkAllowed
        self.networkAllowed = networkAllowed
        guard isEnabled else { self.ready = ready; return }
        guard ready else { pause(); return }
        self.ready = true
        guard becameReady || networkChanged else { return }
        pending = true
        if networkChanged, task != nil { stopCurrent() }
        startIfNeeded()
    }

    /// Multiple notifications during a drain collapse into exactly one new diff.
    func libraryChanged() {
        guard isEnabled, !userSuppressed, !failureRequiresRestart else { return }
        pending = true
        invalidateCompletionDisplay()
        if task != nil { stopCurrent() }
        startIfNeeded()
    }

    /// Process-local suppression survives tabs, foreground toggles and refresh.
    /// Keep partial committed counters, and do not show restart before draining.
    func cancel() {
        guard task != nil else { return }
        userSuppressed = true
        pending = false
        stopCurrent()
    }

    func restart() {
        guard canRestart else { return }
        userSuppressed = false
        failureRequiresRestart = false
        pending = true
        startIfNeeded()
    }

    /// Lifecycle/manual suspension is NOT a user cancel. AppState must explicitly
    /// republish readiness; the old worker cannot resume itself after this call.
    func pause() {
        ready = false
        pending = true
        invalidateCompletionDisplay()
        if task != nil { stopCurrent() }
        else if phase == .completed { phase = .idle }
    }

    func suspendAndWait() async {
        pause()
        await waitUntilIdle()
    }

    /// A failed/cancelled manual mutation must not become an implicit automatic
    /// retry. Keep explicit restart available once AppState is ready; do not
    /// impose an extra refresh/recovery prerequisite or fake a user cancel.
    func requireExplicitRestart() {
        guard isEnabled else { return }
        pending = false
        failureRequiresRestart = true
        invalidateCompletionDisplay()
        if task != nil { stopCurrent() }
        else if !userSuppressed { phase = .needsAttention }
    }

    /// Includes a queued fresh diff, but never the completion-card dwell timer.
    func waitUntilIdle() async {
        while let current = task { await current.value }
    }

    private func stopCurrent() {
        guard let task else { return }
        stopping = true
        invalidateCompletionDisplay()
        phase = .cancelling
        task.cancel()
    }

    private func startIfNeeded() {
        guard let service, ready, pending, task == nil,
              !userSuppressed, !failureRequiresRestart else { return }
        invalidateCompletionDisplay()
        pending = false
        stopping = false
        failureMessage = nil
        progress = PhotoSyncProgress()
        let token = UUID()
        generation = token
        let networkAllowed = networkAllowed
        // Never retain self over the service await: deinit must cancel the job,
        // not depend on that job finishing to break a self/task ownership cycle.
        task = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await service.synchronize(networkAllowed: networkAllowed, progress: { [weak self] value in
                    await self?.accept(value, token: token)
                }, committed: { [weak self] in
                    await self?.acceptCommit(token: token)
                })
                self?.finish(result: result, error: nil, token: token, cancelled: Task.isCancelled)
            } catch {
                self?.finish(result: nil, error: error, token: token, cancelled: Task.isCancelled)
            }
        }
        phase = .checking
    }

    private func accept(_ value: PhotoSyncProgress, token: UUID) {
        guard generation == token else { return }
        // The commit may have won the cancellation race. Its counters survive,
        // but its callback cannot turn a draining job back into a running one.
        progress = value
        if !stopping { phase = value.phase == .checking ? .checking : .updating }
    }

    private func acceptCommit(token: UUID) {
        guard generation == token else { return }
        onCommitted()
    }

    private func finish(result: PhotoSyncResult?, error: Error?, token: UUID, cancelled: Bool) {
        guard generation == token else { return }
        let requestedStop = stopping
        generation = nil
        task = nil
        stopping = false
        defer {
            onSettled()
            // Publish settlement with no live job before an already-queued
            // lifecycle/library restart. Settlement itself queues nothing.
            if requestedStop { startIfNeeded() }
        }
        if requestedStop || cancelled || error is CancellationError {
            if userSuppressed {
                pending = false
                phase = .cancelled
            } else if failureRequiresRestart {
                pending = false
                phase = .needsAttention
            } else {
                phase = .idle
                // A backend-only cancellation waits for the next real event.
                // Only an explicitly queued lifecycle/library restart runs now.
                if !requestedStop { pending = true }
            }
            return
        }
        guard let result, error == nil else {
            pending = false
            failureRequiresRestart = true
            failureMessage = "照片同步未完成，请手动重新同步。已完成的索引会保留。"
            phase = .failed
            return
        }
        progress = result.progress
        pending = false
        phase = result.progress.failed > 0 || result.progress.needsNetwork > 0 ? .needsAttention : .completed
        onCompleted(result.summary)
        if phase == .completed, task == nil { scheduleCompletionDisplay() }
    }

    private func invalidateCompletionDisplay() {
        completionToken = nil
        completionTask?.cancel()
        completionTask = nil
    }

    private func scheduleCompletionDisplay() {
        invalidateCompletionDisplay()
        let token = UUID()
        completionToken = token
        let delay = completionDelay
        completionTask = Task { @MainActor [weak self] in
            do { try await delay() }
            catch { return }
            guard !Task.isCancelled, let self, self.completionToken == token,
                  self.phase == .completed, self.task == nil else { return }
            self.completionToken = nil
            self.completionTask = nil
            self.phase = .idle
        }
    }
}