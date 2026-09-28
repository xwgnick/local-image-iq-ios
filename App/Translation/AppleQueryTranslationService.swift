import Combine
import Foundation
import Translation

/// The caller owns serialization. This bridge owns exactly one request until its
/// SwiftUI translation closure has drained; it never owns a TranslationSession.
@MainActor
final class AppleQueryTranslationService: ObservableObject, QueryTranslating {
    enum Purpose: Hashable, Sendable {
        case search, preparation
    }

    struct Job: Identifiable, Sendable {
        enum Kind: Sendable {
            case translation(String)
            case preparation

            var purpose: Purpose {
                switch self {
                case .translation: return .search
                case .preparation: return .preparation
                }
            }
        }

        enum Output: Sendable {
            case translated(String)
            case prepared
        }

        let id: UUID
        let hostID: UUID
        let language: QueryTranslationLanguage
        let kind: Kind
        var purpose: Purpose { kind.purpose }
    }

    @Published private(set) var job: Job?

    private enum Phase { case pending, active, finishing }

    private struct Bridge {
        let job: Job
        let token: AppleQueryTranslationCancellationToken
        let continuation: CheckedContinuation<Job.Output, Error>
        var phase: Phase = .pending
        var hostLost = false
    }

    private var hosts: [Purpose: UUID] = [:]
    private var bridge: Bridge?

    var isSupported: Bool {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) { return true }
        #endif
        return false
    }

    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        guard isSupported else { return .unsupported }
        do {
            return try await checkedAvailability(for: language)
        } catch {
            return .unavailable
        }
    }

    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        try Task.checkCancellation()
        guard isSupported else { throw QueryTranslationFailure.unsupported }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QueryTranslationFailure.emptyResult
        }
        try await preflight(language, purpose: .search)
        let output = try await submit(.translation(text), from: language)
        try Task.checkCancellation()
        guard case .translated(let target) = output else {
            throw QueryTranslationFailure.unavailable
        }
        return target
    }

    func prepare(_ language: QueryTranslationLanguage) async throws {
        try await preflight(language, purpose: .preparation)
        let output = try await submit(.preparation, from: language)
        try Task.checkCancellation()
        guard case .prepared = output else { throw QueryTranslationFailure.unavailable }
    }

    private func preflight(_ language: QueryTranslationLanguage, purpose: Purpose) async throws {
        try Task.checkCancellation()
        guard isSupported else { throw QueryTranslationFailure.unsupported }
        guard hosts[purpose] != nil else { throw QueryTranslationFailure.unavailable }
        let status = try await checkedAvailability(for: language)
        try Task.checkCancellation()
        try Self.requireAvailability(status, for: purpose)
    }

    /// Uncached: installed packs can be removed outside this app.
    private func checkedAvailability(
        for language: QueryTranslationLanguage, jobID: UUID? = nil
    ) async throws -> QueryTranslationAvailability {
        try Task.checkCancellation()
        guard isSupported else { return .unsupported }
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            if let jobID { try checkActiveJob(jobID) }
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: language.rawValue),
                to: Locale.Language(identifier: "en")
            )
            try Task.checkCancellation()
            if let jobID { try checkActiveJob(jobID) }
            switch status {
            case .installed: return .installed
            case .supported: return .downloadRequired
            case .unsupported: return .unsupported
            @unknown default: return .unavailable
            }
        }
        #endif
        return .unsupported
    }

    /// Called immediately inside translationTask, and again after preparation.
    func availability(for job: Job) async throws -> QueryTranslationAvailability {
        try checkActiveJob(job.id)
        return try await checkedAvailability(for: job.language, jobID: job.id)
    }

    static func requireAvailability(_ status: QueryTranslationAvailability, for purpose: Purpose) throws {
        switch status {
        case .installed: return
        case .downloadRequired:
            if purpose == .preparation { return }
            throw QueryTranslationFailure.notInstalled
        case .unsupported: throw QueryTranslationFailure.unsupported
        case .unchecked, .unavailable: throw QueryTranslationFailure.unavailable
        }
    }

    /// Never expose Apple's error descriptions/userInfo (which may contain text).
    static func typedFailure(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let failure = error as? QueryTranslationFailure { return failure }
        return QueryTranslationFailure.unavailable
    }

    // MARK: - Presenter registration and session-free bridge (also testable on Simulator)

    func registerHost(id: UUID, purpose: Purpose) {
        let previous = hosts.updateValue(id, forKey: purpose)
        if let previous, previous != id {
            loseHost(id: previous, purpose: purpose)
        }
    }

    func unregisterHost(id: UUID, purpose: Purpose) {
        // An old view's onDisappear must not unregister its replacement.
        if hosts[purpose] == id { hosts.removeValue(forKey: purpose) }
        loseHost(id: id, purpose: purpose)
    }

    private func loseHost(id: UUID, purpose: Purpose) {
        guard let current = bridge, current.job.hostID == id, current.job.purpose == purpose else { return }
        jobHostDisappeared(id: current.job.id, hostID: id)
    }

    func jobHostDisappeared(id: UUID, hostID: UUID) {
        guard let current = bridge, current.job.id == id, current.job.hostID == hostID else { return }
        bridge?.hostLost = true
        if current.phase == .pending {
            complete(id: id, result: .failure(QueryTranslationFailure.unavailable))
        }
        // An active closure still owns the drain, even if its view was removed.
        // Never resume early or try to reuse that view's invalidated session.
    }

    /// Pure continuation handoff, separated from the public device/pack checks.
    /// AppState serializes callers; a busy or absent presenter fails, not queues.
    func submit(_ kind: Job.Kind, from language: QueryTranslationLanguage) async throws -> Job.Output {
        let token = AppleQueryTranslationCancellationToken()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output: Job.Output = try await withCheckedThrowingContinuation { continuation in
                // onCancel can run BEFORE this continuation is installed. Its
                // synchronous token write, not the later actor hop, closes that race.
                guard !token.isCancelled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard bridge == nil, let hostID = hosts[kind.purpose] else {
                    continuation.resume(throwing: QueryTranslationFailure.unavailable)
                    return
                }
                let request = Job(id: token.id, hostID: hostID, language: language, kind: kind)
                bridge = Bridge(job: request, token: token, continuation: continuation)
                job = request
            }
            try Task.checkCancellation()
            guard !token.isCancelled else { throw CancellationError() }
            return output
        } onCancel: {
            token.markCancelled()
            // No session is captured by this bookkeeping-only task.
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(id: token.id)
            }
        }
    }

    private func cancelPendingRequest(id: UUID) {
        guard let current = bridge, current.job.id == id, current.phase == .pending else { return }
        complete(id: id, result: .failure(CancellationError()))
        // Active/finishing requests retain their job, child identity and
        // configuration. The cancelled token suppresses their eventual result.
    }

    /// Exactly one invocation of translationTask may claim this immutable job.
    func beginJob(id: UUID, hostID: UUID) -> Bool {
        guard let current = bridge, current.job.id == id,
              current.job.hostID == hostID, current.phase == .pending else { return false }
        if current.token.isCancelled || Task.isCancelled {
            complete(id: id, result: .failure(CancellationError()))
            return false
        }
        guard !current.hostLost, hosts[current.job.purpose] == hostID else {
            complete(id: id, result: .failure(QueryTranslationFailure.unavailable))
            return false
        }
        bridge?.phase = .active
        return true
    }

    /// Must precede every session call and follow every suspension in its closure.
    func checkActiveJob(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let current = bridge, current.job.id == id else { throw CancellationError() }
        guard !current.token.isCancelled else { throw CancellationError() }
        guard current.phase == .active, !current.hostLost,
              hosts[current.job.purpose] == current.job.hostID else {
            throw QueryTranslationFailure.unavailable
        }
    }

    /// Invoke only as the closure's final, non-suspending action on MainActor.
    /// Defer publication/unmounting until that closure has actually returned.
    func finishAfterClosure(id: UUID, result: Result<Job.Output, Error>) {
        guard let current = bridge, current.job.id == id, current.phase == .active else { return }
        bridge?.phase = .finishing
        let outcome: Result<Job.Output, Error> = Task.isCancelled ? .failure(CancellationError()) : result
        DispatchQueue.main.async { [self] in
            complete(id: id, result: outcome)
        }
    }

    private func complete(id: UUID, result: Result<Job.Output, Error>) {
        guard let current = bridge, current.job.id == id, current.phase != .active else { return }
        let outcome: Result<Job.Output, Error>
        if current.token.isCancelled {
            outcome = .failure(CancellationError())
        } else if case .failure(let error) = result, error is CancellationError {
            outcome = .failure(CancellationError())
        } else if current.hostLost {
            outcome = .failure(QueryTranslationFailure.unavailable)
        } else {
            outcome = result.mapError { Self.typedFailure($0) }
        }
        bridge = nil
        job = nil
        current.continuation.resume(with: outcome)
    }
}

/// Only this cancellation bit crosses executors; all bridge state is MainActor.
private final class AppleQueryTranslationCancellationToken: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func markCancelled() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}