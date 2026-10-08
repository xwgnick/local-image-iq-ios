import Foundation

/// Whole foreground operations hold read leases; automatic sync holds a write
/// lease only for a commit. Consecutive readers share access, but cannot pass a
/// queued writer. No suspension or continuation resumption occurs under a lock.
final class IndexAccessCoordinator: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: IndexAccessCoordinator?
        private let writing: Bool

        fileprivate init(owner: IndexAccessCoordinator, writing: Bool) {
            self.owner = owner
            self.writing = writing
        }

        func release() {
            lock.lock()
            let owner = self.owner
            self.owner = nil
            lock.unlock()
            owner?.release(writing: writing)
        }

        deinit { release() }
    }

    private final class Waiter: @unchecked Sendable {
        enum State: Equatable { case new, waiting, granted, cancelled }
        let writing: Bool
        // All fields below are protected by the coordinator's lock.
        var state = State.new
        var continuation: CheckedContinuation<Lease, Error>?
        init(writing: Bool) { self.writing = writing }
    }

    private let lock = NSLock()
    private var readers = 0
    private var writing = false
    private var version: UInt64 = 0
    private var queue: [Waiter] = []
    // Observation only, outside the lock; enables deterministic queue-order tests.
    private let didEnqueue: (@Sendable () -> Void)?

    init(didEnqueue: (@Sendable () -> Void)? = nil) { self.didEnqueue = didEnqueue }

    var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writing
    }

    /// Availability only, not a reservation; callers still acquire a read lease.
    var canReadImmediately: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !writing && queue.isEmpty
    }

    func acquireRead() async throws -> Lease { try await acquire(writing: false) }
    func acquireWrite() async throws -> Lease { try await acquire(writing: true) }

    func tryRead() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard !writing, queue.isEmpty else { return nil }
        readers += 1
        return Lease(owner: self, writing: false)
    }

    private func acquire(writing: Bool) async throws -> Lease {
        let waiter = Waiter(writing: writing)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let lease = try await withCheckedThrowingContinuation { continuation in
                install(waiter, continuation: continuation)
            }
            // Cancellation after grant must return that grant, not leak it, and
            // must never revoke a lease already returned to a running operation.
            do { try Task.checkCancellation() }
            catch { lease.release(); throw error }
            return lease
        } onCancel: {
            self.cancel(waiter)
        }
    }

    private typealias Grant = (CheckedContinuation<Lease, Error>, Lease)

    /// Caller holds lock. Returning values, rather than resuming here, also
    /// prevents a resumed operation from recursively taking this lock.
    private func grants() -> [Grant] {
        var result: [Grant] = []
        while !writing, let first = queue.first {
            if first.writing && readers != 0 { break }
            queue.removeFirst()
            first.state = .granted
            if first.writing {
                writing = true
                version &+= 1 // Invalidate authority BEFORE even a failing write.
            } else { readers += 1 }
            if let continuation = first.continuation {
                first.continuation = nil
                result.append((continuation, Lease(owner: self, writing: first.writing)))
            }
        }
        return result
    }

    private func resume(_ grants: [Grant]) {
        for (continuation, lease) in grants { continuation.resume(returning: lease) }
    }

    private func install(_ waiter: Waiter, continuation: CheckedContinuation<Lease, Error>) {
        lock.lock()
        if waiter.state == .cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        waiter.state = .waiting
        waiter.continuation = continuation
        queue.append(waiter)
        let ready = grants()
        lock.unlock()
        didEnqueue?()
        resume(ready)
    }

    private func cancel(_ waiter: Waiter) {
        lock.lock()
        switch waiter.state {
        case .granted, .cancelled:
            lock.unlock()
        case .new, .waiting:
            waiter.state = .cancelled
            let continuation = waiter.continuation
            waiter.continuation = nil
            queue.removeAll { $0 === waiter }
            let ready = grants()
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
            resume(ready)
        }
    }

    private func release(writing: Bool) {
        lock.lock()
        if writing { self.writing = false } else { readers -= 1 }
        let ready = grants()
        lock.unlock()
        resume(ready)
    }
}