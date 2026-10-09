import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Exercises the production controller AND service with real temporary SQLite.
/// Successful fake Photos callbacks are the only deletion grant in these tests.
@MainActor
final class SimilarCleanupDeletionRefreshTests: XCTestCase {
    func testSuccessRegistersBeforeRefreshEvenWhenPhotosInvalidatesAndSyncPrunesFirst() async throws {
        let f = try fixture()
        let callback = gate()
        let note = gate()
        let access = IndexAccessCoordinator()
        let grouping = DeletionRefreshGrouping(service: f.service, noteGate: note)
        let deletion = DeletionRefreshDeleting { revisions in
            f.library.remove(Set(revisions.map(\.id)))
            await callback.wait() // Photos observer may arrive before completion.
        }
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion, indexAccess: access)
        await enter(state)
        let session = state.selectionSessionID
        let intent = try select("b", state: state)
        state.confirmDeletion(intent)
        try await reached(callback.entered)
        state.setAutomaticRefreshDeferred(true)
        state.invalidateAccess()
        XCTAssertTrue(state.groups.isEmpty, "No private content retained in the invalidated UI")
        XCTAssertTrue(state.isDeleting)
        let writer = try await access.acquireWrite()
        try await f.prune(["b"])
        writer.release()
        state.indexSourceChanged()
        callback.open()
        try await reached(note.entered)
        XCTAssertTrue(state.isDeleting, "Mutation admission remains closed until evidence is recorded")
        XCTAssertEqual(grouping.events, ["restore", "group", "note"])
        state.setAutomaticRefreshDeferred(false)
        state.enterPage(ready: true)
        XCTAssertEqual(grouping.events, ["restore", "group", "note"])
        note.open()
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events, ["restore", "group", "note", "noted", "restore"])
        XCTAssertEqual(grouping.captures.first?.revisions, intent.revisions)
        XCTAssertNotNil(grouping.captures.first?.baselineID)
        XCTAssertEqual(state.groups.first?.photos.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(state.candidateCount, 4)
        XCTAssertTrue(state.canSelect)
        XCTAssertNotEqual(state.selectionSessionID, session)
        XCTAssertTrue(state.selectedIDs.isEmpty)
        XCTAssertNil(state.pendingDeletion)
        XCTAssertEqual(state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        assertNoGlobalRerun(f)
        // An old queued confirmation cannot write against the new session.
        state.confirmDeletion(intent)
        await state.waitUntilIdle()
        XCTAssertEqual(deletion.calls.count, 1)
        XCTAssertEqual(grouping.captures.count, 1)
        // Later irrelevant sync writes also restore without rediscovery.
        let nextWriter = try await access.acquireWrite()
        try deletionSQL(f.directory, "UPDATE photos SET geography_version = 'later-sync'")
        nextWriter.release()
        state.indexSourceChanged()
        await state.waitUntilIdle()
        XCTAssertTrue(state.canSelect)
        assertNoGlobalRerun(f)
    }

    func testCancelledOrFailedPhotosDeletionDoesNotRegisterAndStillReadsFresh() async throws {
        for cancelled in [false, true] {
            let f = try fixture()
            let grouping = DeletionRefreshGrouping(service: f.service)
            let deletion = DeletionRefreshDeleting { _ in
                // A failure is not proof of rollback; fresh restore must classify
                // the actual remaining scope, not assume the selected IDs survived.
                f.library.remove(["b"])
                try await f.prune(["b"])
                if cancelled { throw CancellationError() }
                throw PhotoDeletionError.mutationFailed
            }
            let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
            await enter(state)
            state.confirmDeletion(try select("b", state: state))
            await state.waitUntilIdle()
            XCTAssertTrue(grouping.captures.isEmpty)
            XCTAssertEqual(grouping.events, ["restore", "group", "restore", "group"])
            XCTAssertEqual(state.candidateCount, 4)
            XCTAssertFalse(state.isDeleting)
            XCTAssertTrue(state.canSelect)
            XCTAssertEqual(state.message, (cancelled ? PhotoDeletionError.cancelled : .mutationFailed).localizedDescription)
            XCTAssertEqual(f.metrics.values.count, 2)
            XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
        }
    }

    func testNoVisibleRemovalWaitsWithoutLifecycleLoopThenRealNotificationMaintains() async throws {
        let f = try fixture()
        let grouping = DeletionRefreshGrouping(service: f.service)
        let deletion = DeletionRefreshDeleting { _ in } // Successful callback; fetch has not caught up.
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        await enter(state)
        state.confirmDeletion(try select("b", state: state))
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events, ["restore", "group", "note", "noted", "restore"])
        XCTAssertEqual(f.metrics.values.count, 1)
        XCTAssertTrue(state.needsRegroup)
        XCTAssertTrue(state.canRetryAutomaticRefresh)
        XCTAssertFalse(state.canSelect)
        XCTAssertTrue(state.groups.isEmpty)
        for _ in 0..<3 {
            state.enterPage(ready: true)
            state.availabilityChanged(ready: true)
            state.leavePage()
            state.enterPage(ready: true)
            state.pause()
            state.resume()
            state.setAutomaticRefreshDeferred(true)
            state.setAutomaticRefreshDeferred(false)
            state.dismissMessage()
        }
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events.count, 5)
        f.library.remove(["b"])
        try await f.prune(["b"])
        state.invalidateAccess()
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events.last, "restore")
        XCTAssertEqual(grouping.events.count, 6)
        XCTAssertTrue(state.canSelect)
        XCTAssertFalse(state.needsRegroup)
        assertNoGlobalRerun(f)
    }

    func testSuccessfulCallbackAfterPauseStillRecordsWithoutCancellingMutation() async throws {
        let f = try fixture()
        let callback = gate()
        let grouping = DeletionRefreshGrouping(service: f.service)
        let deletion = DeletionRefreshDeleting { revisions in
            await callback.wait()
            XCTAssertFalse(Task.isCancelled)
            f.library.remove(Set(revisions.map(\.id)))
            try await f.prune(revisions.map(\.id))
        }
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        await enter(state)
        state.confirmDeletion(try select("b", state: state))
        try await reached(callback.entered)
        state.pause()
        state.leavePage()
        state.invalidateAccess()
        XCTAssertTrue(state.groups.isEmpty)
        callback.open()
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events, ["restore", "group", "note", "noted"])
        XCTAssertFalse(state.isDeleting)
        XCTAssertFalse(state.canSelect)
        state.enterPage(ready: true)
        state.resume()
        await state.waitUntilIdle()
        XCTAssertTrue(state.canSelect)
        XCTAssertEqual(state.candidateCount, 4)
        assertNoGlobalRerun(f)
    }

    func testControllerReleaseDoesNotLoseSubmittedSuccessRegistration() async throws {
        let f = try fixture()
        let callback = gate()
        let registered = XCTestExpectation(description: "Deletion registered without controller")
        let grouping = DeletionRefreshGrouping(service: f.service, afterNote: { registered.fulfill() })
        let deletion = DeletionRefreshDeleting { revisions in
            await callback.wait()
            XCTAssertFalse(Task.isCancelled)
            f.library.remove(Set(revisions.map(\.id)))
            try await f.prune(revisions.map(\.id))
        }
        var state: SimilarPhotoCleanupState? = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        await enter(try XCTUnwrap(state))
        let intent = try select("b", state: XCTUnwrap(state))
        state?.confirmDeletion(intent)
        try await reached(callback.entered)
        weak var released = state
        state = nil
        XCTAssertNil(released)
        callback.open()
        try await reached(registered)
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(result.candidateCount, 4)
        assertNoGlobalRerun(f)
    }

    func testStaleOrQueuedIntentCannotRegisterAfterAccessOrIndexRevisionChanges() async throws {
        for indexChange in [false, true] {
            let f = try fixture()
            let access = IndexAccessCoordinator()
            let grouping = DeletionRefreshGrouping(service: f.service)
            let deletion = DeletionRefreshDeleting { _ in }
            let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion, indexAccess: access)
            await enter(state)
            let intent = try select("b", state: state)
            if indexChange {
                let writer = try await access.acquireWrite()
                state.confirmDeletion(intent) // Blocked while queued writer owns revision.
                writer.release()
                state.confirmDeletion(intent) // Also blocked before notification arrives.
                state.indexSourceChanged()
            } else {
                state.invalidateAccess()
                state.confirmDeletion(intent)
            }
            await state.waitUntilIdle()
            state.confirmDeletion(intent)
            await state.waitUntilIdle()
            XCTAssertTrue(deletion.calls.isEmpty)
            XCTAssertTrue(grouping.captures.isEmpty)
            XCTAssertEqual(f.metrics.values.count, 1)
        }
    }

    func testAuthorizationReductionDuringSuccessfulDeletionFallsBackInsteadOfGrantingMissingIDs() async throws {
        let f = try fixture()
        let grouping = DeletionRefreshGrouping(service: f.service)
        let deletion = DeletionRefreshDeleting { _ in
            f.library.remove(["b", "single"])
            f.library.setAuthorization(4)
            try await f.prune(["b", "single"])
        }
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        await enter(state)
        state.confirmDeletion(try select("b", state: state))
        await state.waitUntilIdle()
        XCTAssertEqual(grouping.events, ["restore", "group", "note", "noted", "restore", "group"])
        XCTAssertEqual(state.candidateCount, 3)
        XCTAssertTrue(state.canSelect)
        XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
    }

    func testExplicitScanStillPerformsFullRediscoveryAfterMaintainedZero() async throws {
        let f = try fixture([deletionPhoto("a", angle: 0), deletionPhoto("b", angle: 0.25), deletionPhoto("c", angle: -0.26)])
        let grouping = DeletionRefreshGrouping(service: f.service)
        let deletion = DeletionRefreshDeleting { revisions in
            f.library.remove(Set(revisions.map(\.id)))
            try await f.prune(revisions.map(\.id))
        }
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        await enter(state)
        state.confirmDeletion(try select("b", state: state))
        await state.waitUntilIdle()
        XCTAssertTrue(state.hasScanned, "Successful zero is completed history, not missing work")
        XCTAssertTrue(state.groups.isEmpty)
        XCTAssertEqual(state.candidateCount, 2)
        assertNoGlobalRerun(f)
        state.leavePage()
        state.enterPage(ready: true)
        await state.waitUntilIdle()
        XCTAssertEqual(f.metrics.values.count, 2)
        state.scan()
        await state.waitUntilIdle()
        XCTAssertEqual(state.groups.first?.photos.map(\.id), ["a", "c"])
        XCTAssertEqual(f.metrics.values.count, 3)
        XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
    }

    func testLegacySingleArgumentNotificationRemainsCompatibleAndDoesNotRunOnFailure() async throws {
        for fails in [false, true] {
            let grouping = DeletionRefreshLegacyGrouping()
            let deletion = DeletionRefreshDeleting { _ in if fails { throw PhotoDeletionError.mutationFailed } }
            let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
            await enter(state)
            state.confirmDeletion(try select("b", state: state))
            await state.waitUntilIdle()
            let events = await grouping.events
            XCTAssertEqual(events, fails ? ["group", "group"] : ["group", "note", "group"])
        }
    }

    func testDefaultIs95WithoutOverridingAnyValidSavedPreference() throws {
        XCTAssertEqual(SimilarPhotoGroupingPolicy.defaultThreshold, 0.95)
        XCTAssertEqual(SimilarCleanupPreferences.threshold(in: nil), 0.95)
        let name = "SimilarCleanupDeletionRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = DeletionRefreshLegacyGrouping()
        let deletion = DeletionRefreshDeleting { _ in }
        let missing = SimilarPhotoCleanupState(grouping: service, deletion: deletion, preferences: defaults)
        XCTAssertEqual(missing.threshold, 0.95)
        XCTAssertNil(defaults.object(forKey: SimilarCleanupPreferences.thresholdKey))
        for tick in 50...99 {
            defaults.set(tick, forKey: SimilarCleanupPreferences.thresholdKey)
            let state = SimilarPhotoCleanupState(grouping: service, deletion: deletion, preferences: defaults)
            XCTAssertEqual(state.threshold, Float(tick) / 100)
            XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), tick)
        }
        defaults.set("90", forKey: SimilarCleanupPreferences.thresholdKey)
        XCTAssertEqual(SimilarCleanupPreferences.threshold(in: defaults), 0.95)
        XCTAssertEqual(defaults.string(forKey: SimilarCleanupPreferences.thresholdKey), "90")
    }

    private func fixture(_ photos: [IndexedPhoto]? = nil) throws -> DeletionMaintenanceFixture {
        let f = try DeletionMaintenanceFixture(photos: photos)
        addTeardownBlock { try FileManager.default.removeItem(at: f.directory) }
        return f
    }
    private func gate() -> DeletionMaintenanceGate {
        let value = DeletionMaintenanceGate()
        addTeardownBlock { value.open() }
        return value
    }
    private func reached(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Missing deterministic milestone")
            throw DeletionMaintenanceFailure.fixture
        }
    }
    private func enter(_ state: SimilarPhotoCleanupState) async {
        state.enterPage(ready: true)
        await state.waitUntilIdle()
        XCTAssertTrue(state.canSelect)
    }
    private func select(_ id: String, state: SimilarPhotoCleanupState) throws -> SimilarPhotoDeletionIntent {
        state.toggleSelection(id)
        state.prepareDeletion()
        return try XCTUnwrap(state.pendingDeletion)
    }
    private func assertNoGlobalRerun(_ f: DeletionMaintenanceFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.metrics.values.count, 2, file: file, line: line)
        guard f.metrics.values.count == 2 else { return }
        let maintained = f.metrics.values[1]
        XCTAssertEqual(maintained.decodedRowCount, 0, file: file, line: line)
        XCTAssertEqual(maintained.computation.matrixMultiplyCount, 0, file: file, line: line)
        XCTAssertEqual(maintained.computation.seedScoreCount, 0, file: file, line: line)
        XCTAssertEqual(maintained.sourceSnapshotCount, 3, file: file, line: line)
    }
}

private final class DeletionRefreshGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    struct Capture { let revisions: [PhotoRevision]; let baselineID: UUID? }
    private let lock = NSLock()
    private var trace: [String] = []
    private var recorded: [Capture] = []
    private let service: SimilarPhotoGroupingService
    private let noteGate: DeletionMaintenanceGate?
    private let afterNote: @Sendable () -> Void
    init(service: SimilarPhotoGroupingService, noteGate: DeletionMaintenanceGate? = nil,
         afterNote: @escaping @Sendable () -> Void = {}) {
        self.service = service; self.noteGate = noteGate; self.afterNote = afterNote
    }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var events: [String] { locked { trace } }
    var captures: [Capture] { locked { recorded } }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        locked { trace.append("restore") }
        return try await service.restore(threshold: threshold)
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        locked { trace.append("group") }
        return try await service.group(threshold: threshold, progress: progress)
    }
    func confirmedDeletion(revisions: [PhotoRevision], baselineID: UUID?) async {
        locked { trace.append("note"); recorded.append(Capture(revisions: revisions, baselineID: baselineID)) }
        await noteGate?.wait()
        await service.confirmedDeletion(revisions: revisions, baselineID: baselineID)
        locked { trace.append("noted") }
        afterNote()
    }
}

private final class DeletionRefreshDeleting: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PhotoRevision]] = []
    private let operation: @Sendable ([PhotoRevision]) async throws -> Void
    init(_ operation: @escaping @Sendable ([PhotoRevision]) async throws -> Void) { self.operation = operation }
    var calls: [[PhotoRevision]] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ revisions: [PhotoRevision]) { lock.lock(); defer { lock.unlock() }; recorded.append(revisions) }
    func delete(revisions: [PhotoRevision]) async throws { record(revisions); try await operation(revisions) }
}

private actor DeletionRefreshLegacyGrouping: SimilarPhotoGrouping {
    private(set) var events: [String] = []
    func confirmedDeletion(revisions: [PhotoRevision]) async { events.append("note") }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        events.append("group")
        return SimilarPhotoGroupingResult(groups: [SimilarPhotoGroup(id: "a", photos: [deletionPhoto("a"), deletionPhoto("b")], minimumSimilarity: 1)],
            candidateCount: 2, staleCount: 0, unindexedCount: 0, threshold: threshold)
    }
}