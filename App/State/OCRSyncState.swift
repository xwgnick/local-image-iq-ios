import Foundation
import Combine

/// Intent/presentation only. AppState owns the existing serialized worker task,
/// its read lease and its drain tail. This object never opens Photos or storage.
@MainActor
final class OCRSyncState: ObservableObject {
    enum Phase: Equatable { case idle, waiting, checking, updating, cancelling, cancelled, completed, failed }
    enum Completion: Equatable { case completed, cancelled, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = TextIndexProgress()
    @Published private(set) var totalKnown = false
    @Published private(set) var pending = false
    /// True from admission until the *old task returns*, including cancellation
    /// and supersession by another foreground operation. Not a visibility flag.
    @Published private(set) var currentRunning = false
    @Published private(set) var enabled: Bool
    @Published private(set) var ready = false
    @Published private(set) var terminalHidden = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var lifecyclePaused = false
    @Published private(set) var isResuming = false
    private var generation: UUID?
    private var pendingRetryReducedPreviews = false
    private(set) var retryReducedPreviews = false
    var pendingQualityRetry: Bool { pendingRetryReducedPreviews }
    private let completionDelay: @Sendable () async throws -> Void
    private var completionTask: Task<Void, Never>?
    private var completionToken: UUID?

    var canShow: Bool { phase != .idle && !terminalHidden }
    var completionTitle: String {
        progress.incompleteCount > 0 ? progress.completionTitle : "文字索引未完成"
    }
    var completionDetail: String {
        if progress.incompleteCount > 0 { return progress.completionDetail }
        return failureMessage ?? "本次文字检查未完成，已完成记录保留；可在图库查看详情并手动重试。"
    }
    var canCancel: Bool { (pending || currentRunning) && phase != .cancelling }
    var canRetry: Bool {
        enabled && ready && !pending && !currentRunning
            && (phase == .cancelled || phase == .failed || phase == .completed)
    }
    var fraction: Double? {
        phase == .updating && totalKnown && progress.total > 0 ? progress.fraction : nil
    }

    /// Restoring a preference is deliberately not a toggle event.
    init(enabled: Bool = false, completionDelay: @escaping @Sendable () async throws -> Void = {
        try await Task.sleep(for: .seconds(6))
    }) {
        self.enabled = enabled
        self.completionDelay = completionDelay
    }

    deinit { completionTask?.cancel() }

    private func resetTerminalDisplay() {
        completionTask?.cancel()
        completionTask = nil
        completionToken = nil
        terminalHidden = false
        failureMessage = nil
    }

    private func scheduleTerminalHide() {
        let token = UUID()
        completionToken = token
        let delay = completionDelay
        completionTask = Task { @MainActor [weak self] in
            do { try await delay() }
            catch { return }
            guard !Task.isCancelled, let self, self.completionToken == token,
                  !self.currentRunning, !self.pending else { return }
            self.terminalHidden = true
            self.completionTask = nil
            self.completionToken = nil
        }
    }

    func userChangedEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { requestUpdate() }
        else { cancel() }
    }

    /// Explicit manual maintenance/retry shares the one pending intent. A
    /// running, non-cancelled update already satisfies a duplicate request.
    func requestUpdate(retryReducedPreviews: Bool = false) {
        guard enabled, !currentRunning || phase == .cancelling else { return }
        resetTerminalDisplay()
        pending = true
        lifecyclePaused = false
        pendingRetryReducedPreviews = pendingRetryReducedPreviews || retryReducedPreviews
        if !currentRunning {
            progress = TextIndexProgress()
            totalKnown = false
            phase = .waiting
        }
    }

    func updateAvailability(ready: Bool) {
        if self.ready != ready { self.ready = ready }
    }

    func takeReadyRequest() -> UUID? {
        guard enabled, ready, pending, !currentRunning else { return nil }
        let token = UUID()
        generation = token
        pending = false
        retryReducedPreviews = pendingRetryReducedPreviews
        pendingRetryReducedPreviews = false
        currentRunning = true
        isResuming = lifecyclePaused
        lifecyclePaused = false
        progress = TextIndexProgress()
        totalKnown = false
        phase = .checking
        return token
    }

    func cancel() {
        guard pending || currentRunning else { return }
        pending = false
        lifecyclePaused = false
        isResuming = false
        pendingRetryReducedPreviews = false
        if currentRunning { phase = .cancelling }
        else { phase = .cancelled; scheduleTerminalHide() }
    }

    /// Lifecycle interruption retains intent; user cancellation and failures do not.
    func pause() {
        updateAvailability(ready: false)
        if currentRunning, phase != .cancelling {
            pending = true
            pendingRetryReducedPreviews = pendingRetryReducedPreviews || retryReducedPreviews
            lifecyclePaused = true
            phase = .cancelling
        } else if pending {
            lifecyclePaused = true
        }
    }

    func restoreInterruptedRequest(retryReducedPreviews: Bool) {
        guard enabled, !currentRunning, !pending else { return }
        requestUpdate(retryReducedPreviews: retryReducedPreviews)
        lifecyclePaused = true
    }

    /// Superseding foreground work cancels the old job but must not erase a
    /// newer OFF->ON request that is waiting for that old job to drain.
    func stopRunning() {
        if currentRunning { phase = .cancelling }
    }

    func accept(_ value: TextIndexProgress, token: UUID) {
        guard generation == token else { return }
        progress = value
        totalKnown = true
        // A last committed row may win cancellation; retain factual counters
        // without pretending a draining recognizer is running again.
        if phase != .cancelling { phase = .updating }
    }

    func finish(token: UUID, completion: Completion, issue: String? = nil) {
        guard generation == token else { return }
        let stopping = phase == .cancelling
        generation = nil
        currentRunning = false
        failureMessage = issue
        if pending {
            if !lifecyclePaused {
                progress = TextIndexProgress()
                totalKnown = false
            }
            phase = .waiting
            return
        }
        if stopping { phase = .cancelled; scheduleTerminalHide(); return }
        switch completion {
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        case .completed:
            // A returned scan with skipped/failed photos is not full success.
            phase = progress.incompleteCount > 0
                ? .failed : .completed
        }
        if completion == .completed, phase == .failed, progress.deferredFailures > 0,
           progress.failed == 0, progress.cloudSkipped == 0, progress.staleSkipped == 0 {
            terminalHidden = true
            return
        }
        scheduleTerminalHide()
    }

    func dismiss() {
        guard !currentRunning, !pending else { return }
        resetTerminalDisplay()
        phase = .idle
    }
}