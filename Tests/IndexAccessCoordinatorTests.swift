import Foundation
import XCTest
@testable import LocalImageIQ

final class IndexAccessCoordinatorTests: XCTestCase {
    func testReadAvailabilityObservesQueueAndWriterWithoutTakingALease() async throws {
        let queued = AccessSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        XCTAssertTrue(access.canReadImmediately)
        let reader = try await access.acquireRead()
        defer { reader.release() }
        XCTAssertTrue(access.canReadImmediately, "Existing readers can share access")
        let writer = Task { try await access.acquireWrite() }
        defer { writer.cancel() }
        await queued.wait(2)
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 0)
        XCTAssertFalse(access.canReadImmediately, "A queued writer forbids a new immediate reader")
        XCTAssertNil(access.tryRead())
        writer.cancel()
        await cancelled(writer)
        XCTAssertTrue(access.canReadImmediately, "Cancelling the waiter restores availability before readers finish")
        XCTAssertEqual(access.revision, 0)
        reader.release()
        let next = Task { try await access.acquireWrite() }
        defer { next.cancel() }
        await queued.wait(3)
        // Reading the property must not acquire/leak a lease that blocks this grant.
        XCTAssertTrue(access.isWriting)
        XCTAssertEqual(access.revision, 1)
        XCTAssertFalse(access.canReadImmediately)
        let lease = try await next.value
        lease.release() // Also represents a failed/rolled-back writer with no commit callback.
        XCTAssertFalse(access.isWriting)
        XCTAssertTrue(access.canReadImmediately)
        XCTAssertEqual(access.revision, 1)
        let immediate = try XCTUnwrap(access.tryRead())
        immediate.release()
    }

    func testReadersOverlapAndWriterWaitsForEveryReader() async throws {
        let queued = AccessSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let a = try await access.acquireRead()
        let b = try await access.acquireRead()
        let writer = Task { try await access.acquireWrite() }
        await queued.wait(3)
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 0)
        XCTAssertNil(access.tryRead(), "A later reader cannot pass a queued writer")
        a.release()
        XCTAssertFalse(access.isWriting)
        b.release()
        let lease = try await writer.value
        XCTAssertTrue(access.isWriting)
        XCTAssertEqual(access.revision, 1)
        XCTAssertNil(access.tryRead())
        lease.release()
        XCTAssertFalse(access.isWriting)
    }

    func testFIFOWithConsecutiveReadersAndMultipleWriters() async throws {
        let queued = AccessSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let first = try await access.acquireWrite()
        let r1 = Task { try await access.acquireRead() }
        await queued.wait(2)
        let r2 = Task { try await access.acquireRead() }
        await queued.wait(3)
        let w2 = Task { try await access.acquireWrite() }
        await queued.wait(4)
        let r3 = Task { try await access.acquireRead() }
        await queued.wait(5)
        let w3 = Task { try await access.acquireWrite() }
        await queued.wait(6)
        first.release()
        let a = try await r1.value
        let b = try await r2.value
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 1)
        XCTAssertNil(access.tryRead())
        a.release()
        XCTAssertEqual(access.revision, 1)
        b.release()
        let second = try await w2.value
        XCTAssertEqual(access.revision, 2)
        second.release()
        let c = try await r3.value
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 2)
        c.release()
        let third = try await w3.value
        XCTAssertEqual(access.revision, 3)
        third.release()
    }

    func testCancelledQueuedWriterUnblocksFollowingReaderWithoutLeaking() async throws {
        let queued = AccessSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let first = try await access.acquireRead()
        let writer = Task { try await access.acquireWrite() }
        await queued.wait(2)
        let reader = Task { try await access.acquireRead() }
        await queued.wait(3)
        writer.cancel()
        await cancelled(writer)
        let second = try await reader.value // First reader deliberately still held.
        XCTAssertEqual(access.revision, 0)
        first.release()
        second.release()
        let next = try await access.acquireWrite()
        XCTAssertEqual(access.revision, 1)
        next.release()
    }

    func testCancelledQueuedReaderDoesNotBlockNextWriter() async throws {
        let queued = AccessSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let first = try await access.acquireWrite()
        let reader = Task { try await access.acquireRead() }
        await queued.wait(2)
        let writer = Task { try await access.acquireWrite() }
        await queued.wait(3)
        reader.cancel()
        await cancelled(reader)
        first.release()
        let last = try await writer.value
        XCTAssertEqual(access.revision, 2)
        last.release()
    }

    func testConcurrentAndRepeatedReleaseIsIdempotent() async throws {
        let access = IndexAccessCoordinator()
        let lease = try await access.acquireRead()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { lease.release() }
            group.addTask { lease.release() }
        }
        let writer = try await access.acquireWrite()
        lease.release()
        XCTAssertTrue(access.isWriting)
        XCTAssertNil(access.tryRead())
        writer.release()
        writer.release()
        let read = try XCTUnwrap(access.tryRead())
        read.release()
    }

    func testDeinitReleasesAndFailedWriteStillChangesRevision() async throws {
        let access = IndexAccessCoordinator()
        var writer: IndexAccessCoordinator.Lease? = try await access.acquireWrite()
        XCTAssertNotNil(writer)
        XCTAssertEqual(access.revision, 1)
        writer = nil
        XCTAssertFalse(access.isWriting)
        var reader = access.tryRead()
        XCTAssertNotNil(reader)
        reader = nil
        let next = try await access.acquireWrite()
        XCTAssertEqual(access.revision, 2)
        next.release()
    }

    func testAlreadyCancelledAcquireDoesNotQueueOrGrant() async {
        let access = IndexAccessCoordinator()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await access.acquireWrite()
        }
        await cancelled(task)
        XCTAssertEqual(access.revision, 0)
        XCTAssertFalse(access.isWriting)
        let reader = access.tryRead()
        XCTAssertNotNil(reader)
        reader?.release()
    }

    func testCancellationBetweenGrantAndResumeReturnsGrantExactlyOnce() async throws {
        // This observer executes after the grant lock is released, but before
        // the continuation resumes. No timing-dependent cancellation loop.
        let access = IndexAccessCoordinator(didEnqueue: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let task = Task { try await access.acquireWrite() }
        await cancelled(task)
        XCTAssertEqual(access.revision, 1, "Grant invalidates even if its caller is cancelled")
        XCTAssertFalse(access.isWriting)
        let reader = try XCTUnwrap(access.tryRead())
        reader.release()
    }

    func testCancellingLeaseOwnerDoesNotRevokeLiveLease() async throws {
        let access = IndexAccessCoordinator()
        let acquired = AccessSignal()
        let release = AccessSignal()
        let owner = Task {
            let lease = try await access.acquireWrite()
            acquired.send()
            await release.wait(1)
            XCTAssertTrue(access.isWriting)
            lease.release()
        }
        await acquired.wait(1)
        owner.cancel()
        XCTAssertTrue(access.isWriting)
        XCTAssertNil(access.tryRead())
        release.send()
        try await owner.value
        XCTAssertFalse(access.isWriting)
    }

    private func cancelled(_ task: Task<IndexAccessCoordinator.Lease, Error>) async {
        do {
            let lease = try await task.value
            lease.release()
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}

/// Counting one-shot milestones. Async waits never hold NSLock, and signals can
/// precede waits. Tests need no sleeps, polling, or guessed scheduling delays.
private final class AccessSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func send() {
        lock.lock()
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }
    func wait(_ target: Int) async {
        await withCheckedContinuation { install($0, target: target) }
    }
    private func install(_ continuation: CheckedContinuation<Void, Never>, target: Int) {
        lock.lock()
        if count >= target { lock.unlock(); continuation.resume() }
        else { waiters.append((target, continuation)); lock.unlock() }
    }
}