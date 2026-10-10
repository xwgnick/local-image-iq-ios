import Foundation
import Combine

/// Intent/presentation only. AppState owns the existing serialized worker task,
/// its read lease and its drain tail. This object never opens Photos or storage.
@MainActor
final class OCRSyncState: ObservableObject {
    enum Phase: Equatable { case idle, waiting, checking, updating, cancelling, cancelled, completed, failed }
    enum Completion { case completed, cancelled, failed }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = TextIndexProgress()
    @Published private(set) var totalKnown = false
    @Published private(set) var pending = false
    /// True from admission until the *old task returns*, including cancellation
    /// and supersession by another foreground operation. Not a visibility flag.
    @Published private(set) var currentRunning = false
    @Published private(set) var enabled: Bool
    @Published private(set) var ready = false
    private var generation: UUID?

    var canShow: Bool { phase != .idle }
    var canCancel: Bool { (pending || currentRunning) && phase != .cancelling }
    var canRetry: Bool {
        enabled && ready && !pending && !currentRunning
            && (phase == .cancelled || phase == .failed || phase == .completed)
    }
    var fraction: Double? {
        phase == .updating && totalKnown && progress.total > 0 ? progress.fraction : nil
    }

    /// Restoring a preference is deliberately not a toggle event.
    init(enabled: Bool = false) { self.enabled = enabled }

    func userChangedEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { requestUpdate() }
        else { cancel() }
    }

    /// Explicit manual maintenance/retry shares the one pending intent. A
    /// running, non-cancelled update already satisfies a duplicate request.
    func requestUpdate() {
        guard enabled, !currentRunning || phase == .cancelling else { return }
        pending = true
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
        currentRunning = true
        progress = TextIndexProgress()
        totalKnown = false
        phase = .checking
        return token
    }

    func cancel() {
        guard pending || currentRunning else { return }
        pending = false
        if currentRunning { phase = .cancelling }
        else { phase = .cancelled }
    }

    /// A never-admitted toggle intent can wait through background/readiness
    /// changes. An admitted job is cancelled, never auto-retried on foreground.
    func pause() {
        updateAvailability(ready: false)
        if currentRunning { cancel() }
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

    func finish(token: UUID, completion: Completion) {
        guard generation == token else { return }
        let stopping = phase == .cancelling
        generation = nil
        currentRunning = false
        if pending {
            progress = TextIndexProgress()
            totalKnown = false
            phase = .waiting
            return
        }
        if stopping { phase = .cancelled; return }
        switch completion {
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        case .completed:
            // A returned scan with skipped/failed photos is not full success.
            phase = progress.failed > 0 || progress.cloudSkipped > 0 || progress.staleSkipped > 0
                ? .failed : .completed
        }
    }

    func dismiss() {
        guard !currentRunning, !pending else { return }
        phase = .idle
    }
}