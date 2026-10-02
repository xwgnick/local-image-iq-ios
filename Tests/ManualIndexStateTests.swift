import Combine
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// State-only tests with injected permissions and synthetic worker responses.
/// No Photos authorization requests, asset reads, models, storage, screens or
/// network. Holds deliberately ignore cancellation until explicitly released.
@MainActor
final class ManualIndexStateTests: XCTestCase {
    func testIndexDoesNotClearAndCapturesTheExplicitCloudChoice() async {
        for networkAllowed in [false, true] {
            let indexing = hold("manual index")
            let worker = ManualIndexStateWorker(holds: [.index: indexing])
            let state = makeState(worker)
            await start(state)
            state.allowICloudDownload = networkAllowed
            state.query = "TEST manual search"
            state.search()
            await state.waitUntilIdle()
            assertVisibleSearch(state)
            state.selection = AppState.Selection(id: ManualIndexFixture.hit.id)

            state.index()
            assertInvalidatedSearch(state)
            XCTAssertEqual(state.activity, .indexing)
            XCTAssertFalse(state.canIndex)
            // The option belongs to this explicit request, not a later UI edit.
            state.allowICloudDownload = !networkAllowed
            await fulfillment(of: [indexing.started], timeout: 3)
            let running = await worker.snapshot
            XCTAssertEqual(running.events, completed([.launch, .search]) + [.began(.index)])
            XCTAssertEqual(running.networkFlags, [networkAllowed])
            XCTAssertEqual(state.progress.completed, 1)
            XCTAssertEqual(state.progress.encoded, 1)
            state.index()
            state.rebuildIndex()

            await indexing.finish.open()
            await state.waitUntilIdle()
            assertIndexed(state)
            await assertHistory(worker, [.launch, .search, .index])
        }
    }

    func testExplicitRebuildClearsThenIndexesInOneSerializedOperation() async {
        let clearing = hold("rebuild clear")
        let indexing = hold("rebuild index")
        let worker = ManualIndexStateWorker(holds: [.clear: clearing, .index: indexing])
        let state = makeState(worker)
        await start(state)
        state.allowICloudDownload = true
        state.query = "TEST manual search"
        state.search()
        await state.waitUntilIdle()
        assertVisibleSearch(state)
        state.selection = AppState.Selection(id: ManualIndexFixture.hit.id)
        var activities: [AppState.Activity?] = []
        let observation = state.$activity.sink { activities.append($0) }
        defer { observation.cancel() }

        state.rebuildIndex()
        assertInvalidatedSearch(state)
        XCTAssertEqual(state.activity, .indexing)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.summary.indexStatisticsKnown, "Rebuild invalidates saved counts before clear starts.")
        await fulfillment(of: [clearing.started], timeout: 3)
        let duringClear = await worker.snapshot
        XCTAssertEqual(duringClear.events, completed([.launch, .search]) + [.began(.clear)])
        XCTAssertTrue(duringClear.networkFlags.isEmpty, "Indexing cannot start before clear returns.")
        XCTAssertEqual(duringClear.active, 1)
        state.index()
        state.rebuildIndex()
        state.allowICloudDownload = false

        await clearing.finish.open()
        await fulfillment(of: [indexing.started], timeout: 3)
        let duringIndex = await worker.snapshot
        XCTAssertEqual(duringIndex.events, completed([.launch, .search, .clear]) + [.began(.index)])
        XCTAssertEqual(duringIndex.networkFlags, [true])
        XCTAssertEqual(duringIndex.active, 1)
        XCTAssertEqual(duringIndex.peakActive, 1)
        XCTAssertEqual(state.activity, .indexing, "Clear and index share one busy operation.")
        XCTAssertFalse(state.canIndex)
        assertInvalidatedSearch(state)
        XCTAssertTrue(state.summary.indexStatisticsKnown, "The successfully accepted clear summary restores known statistics.")
        // Clear may already publish fresh empty metadata. Do not require the
        // pre-clear counts to survive a successfully deleted local index.
        state.index()
        state.rebuildIndex()

        await indexing.finish.open()
        await state.waitUntilIdle()
        assertIndexed(state)
        XCTAssertEqual(activities, [nil, .indexing, nil], "Rebuild has no idle gap or separate clear operation.")
        await assertHistory(worker, [.launch, .search, .clear, .index])
    }

    func testClearFailureStopsRebuildBeforeIndexAndExposesTheFailure() async {
        let failure = AppFailure.storage("TEST-clear-failed")
        let worker = ManualIndexStateWorker(clearFailure: failure)
        let state = makeState(worker)
        await start(state)

        state.rebuildIndex()
        await state.waitUntilIdle()

        XCTAssertEqual(state.errorMessage, failure.localizedDescription)
        XCTAssertNotNil(state.actionHint)
        XCTAssertNil(state.activity)
        XCTAssertTrue(state.canIndex)
        let snapshot = await worker.snapshot
        XCTAssertTrue(snapshot.networkFlags.isEmpty)
        XCTAssertFalse(state.summary.indexStatisticsKnown)
        await assertHistory(worker, [.launch, .clear])
    }

    func testCancelWhileClearIsHeldNeverStartsIndexAfterLateClearSuccess() async {
        let clearing = hold("cancelled rebuild clear")
        let worker = ManualIndexStateWorker(holds: [.clear: clearing])
        let state = makeState(worker)
        await start(state)
        state.query = "TEST manual search"
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertTrue(state.canSearch)
        state.rebuildIndex()
        XCTAssertFalse(state.summary.indexStatisticsKnown)
        await fulfillment(of: [clearing.started], timeout: 3)

        state.cancel()
        XCTAssertTrue(state.isBusy, "Noninterruptible clear still has to drain.")
        XCTAssertFalse(state.canIndex)
        state.index()
        state.rebuildIndex()
        let held = await worker.snapshot
        XCTAssertEqual(held.events, completed([.launch]) + [.began(.clear)])
        await clearing.finish.open()
        await state.waitUntilIdle()

        XCTAssertNil(state.activity)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.actionHint)
        XCTAssertEqual(state.progress, IndexProgress(), "No indexing progress is allowed after cancelled clear.")
        XCTAssertFalse(state.summary.indexStatisticsKnown, "Late clear success cannot certify the discarded summary.")
        XCTAssertFalse(state.canSearch)
        XCTAssertTrue(state.canIndex)
        let snapshot = await worker.snapshot
        XCTAssertTrue(snapshot.networkFlags.isEmpty)
        await assertHistory(worker, [.launch, .clear], cancelled: [.clear])

        state.search()
        await state.waitUntilIdle()
        await assertHistory(worker, [.launch, .clear], cancelled: [.clear])

        // Cancellation intentionally leaves counts unknown, not necessarily zero.
        // Only the user's explicit metadata refresh restores their known state.
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertEqual(state.summary.indexedCount, ManualIndexFixture.metadata.indexedCount)
        XCTAssertTrue(state.canSearch)
        XCTAssertNil(state.errorMessage)
        await assertHistory(worker, [.launch, .clear, .refresh], cancelled: [.clear])
    }

    func testCancelledClearIndexKeepsStatisticsUnknownUntilManualRefresh() async {
        let clearing = hold("cancelled standalone clear")
        let worker = ManualIndexStateWorker(holds: [.clear: clearing])
        let state = makeState(worker)
        await start(state)
        state.query = "TEST manual search"
        state.search()
        await state.waitUntilIdle()
        assertVisibleSearch(state)
        state.selection = AppState.Selection(id: ManualIndexFixture.hit.id)
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertTrue(state.canSearch)

        state.clearIndex()
        assertInvalidatedSearch(state)
        XCTAssertEqual(state.activity, .clearing)
        XCTAssertFalse(state.summary.indexStatisticsKnown, "Clear invalidates counts synchronously, before the worker runs.")
        await fulfillment(of: [clearing.started], timeout: 3)
        state.cancel()
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.canIndex)
        await clearing.finish.open()
        await state.waitUntilIdle()

        XCTAssertNil(state.activity)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.actionHint)
        XCTAssertTrue(state.canRead)
        XCTAssertTrue(state.modelsReady)
        XCTAssertTrue(state.canIndex)
        XCTAssertFalse(state.summary.indexStatisticsKnown)
        XCTAssertFalse(state.canSearch, "A nonempty query cannot search unknown index statistics while otherwise ready.")
        assertInvalidatedSearch(state)
        state.search()
        await state.waitUntilIdle()
        await assertHistory(worker, [.launch, .search, .clear], cancelled: [.clear])

        // This fake returns its original stored metadata. The contract here is
        // known versus unknown, not a synthetic database row-count simulation.
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertEqual(state.summary.indexedCount, ManualIndexFixture.metadata.indexedCount)
        XCTAssertTrue(state.canSearch)
        XCTAssertNil(state.errorMessage)
        assertInvalidatedSearch(state)
        let refreshed = await worker.snapshot
        XCTAssertTrue(refreshed.networkFlags.isEmpty)
        await assertHistory(worker, [.launch, .search, .clear, .refresh], cancelled: [.clear])
    }

    func testForegroundRefreshDrainsCancelledRebuildClearAndNeverStartsItsIndex() async {
        let clearing = hold("backgrounded rebuild clear")
        let refreshing = hold("foreground read-only refresh")
        let worker = ManualIndexStateWorker(holds: [.clear: clearing, .refresh: refreshing])
        let state = makeState(worker)
        await start(state)
        state.rebuildIndex()
        await fulfillment(of: [clearing.started], timeout: 3)

        state.enterBackground()
        state.libraryChanged()
        state.enterForeground()
        state.enterForeground()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.activity, .refreshing)
        let held = await worker.snapshot
        XCTAssertEqual(held.events, completed([.launch]) + [.began(.clear)])

        await clearing.finish.open()
        await fulfillment(of: [refreshing.started], timeout: 3)
        let refreshingSnapshot = await worker.snapshot
        XCTAssertEqual(refreshingSnapshot.events, completed([.launch, .clear]) + [.began(.refresh)])
        XCTAssertEqual(refreshingSnapshot.peakActive, 1, "Actor reentrancy must not bypass predecessor draining.")
        XCTAssertTrue(refreshingSnapshot.networkFlags.isEmpty)
        await refreshing.finish.open()
        await state.waitUntilIdle()

        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.activity)
        await assertHistory(worker, [.launch, .clear, .refresh], cancelled: [.clear])
    }

    func testBackgroundIdleRejectsBothManualActionsWithoutWorkerCalls() async {
        for permission in [PHAuthorizationStatus.authorized, .limited] {
            let worker = ManualIndexStateWorker()
            let state = makeState(worker, authorization: permission)
            await start(state)
            state.query = "TEST manual search"
            XCTAssertTrue(state.canIndex)
            XCTAssertTrue(state.canSearch)

            state.enterBackground()
            await state.waitUntilIdle()
            XCTAssertFalse(state.isBusy)
            XCTAssertTrue(state.canRead)
            XCTAssertTrue(state.modelsReady)
            XCTAssertTrue(state.summary.indexStatisticsKnown)
            XCTAssertFalse(state.canIndex, "Background alone blocks indexing even when idle and ready.")
            XCTAssertFalse(state.canSearch)
            state.index()
            state.rebuildIndex()
            await state.waitUntilIdle()

            XCTAssertNil(state.activity)
            XCTAssertNil(state.errorMessage)
            XCTAssertTrue(state.summary.indexStatisticsKnown, "A rejected rebuild must not invalidate metadata.")
            let snapshot = await worker.snapshot
            XCTAssertTrue(snapshot.networkFlags.isEmpty)
            await assertHistory(worker, [.launch])
        }
    }

    func testBothManualActionsRequireReadablePermissionEvenWithReadyModels() async {
        for permission in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
            let worker = ManualIndexStateWorker()
            let state = makeState(worker, authorization: permission)
            await start(state)
            XCTAssertEqual(state.authorization, permission)
            XCTAssertTrue(state.modelsReady)
            XCTAssertFalse(state.canRead)
            XCTAssertFalse(state.canIndex)

            state.index()
            state.rebuildIndex()
            await state.waitUntilIdle()

            XCTAssertNil(state.activity)
            XCTAssertNil(state.errorMessage)
            await assertHistory(worker, [.launch])
        }
    }

    func testBothManualActionsRequireModelIdentityWithoutAModelIssue() async {
        let unavailable = [
            LibrarySummary(),
            LibrarySummary(modelIssue: "TEST-model-missing"),
            LibrarySummary(modelVersion: "TEST-invalid-model", modelIssue: "TEST-model-invalid")
        ]
        for metadata in unavailable {
            let worker = ManualIndexStateWorker(metadata: metadata)
            let state = makeState(worker)
            XCTAssertTrue(state.canRead)
            XCTAssertFalse(state.modelsReady)
            XCTAssertFalse(state.canIndex)
            state.index()
            state.rebuildIndex()
            await state.waitUntilIdle()
            await assertHistory(worker, [])

            await start(state)
            XCTAssertFalse(state.modelsReady)
            XCTAssertFalse(state.canIndex)
            state.index()
            state.rebuildIndex()
            await state.waitUntilIdle()
            await assertHistory(worker, [.launch])
        }
    }

    func testAuthorizedAndLimitedEmptyMetadataAllowOnlyExplicitManualIndexing() async {
        for permission in [PHAuthorizationStatus.authorized, .limited] {
            for rebuild in [false, true] {
                let metadata = LibrarySummary(modelVersion: ManualIndexFixture.model)
                let worker = ManualIndexStateWorker(metadata: metadata)
                let state = makeState(worker, authorization: permission)
                await start(state)
                XCTAssertFalse(state.summary.authorizedCountKnown)
                XCTAssertEqual(state.summary.authorizedCount, 0)
                XCTAssertEqual(state.summary.indexedCount, 0)
                XCTAssertTrue(state.modelsReady)
                XCTAssertTrue(state.canIndex, "An unknown Photos count is not an empty/unauthorized library.")
                await assertHistory(worker, [.launch])

                if rebuild { state.rebuildIndex() } else { state.index() }
                await state.waitUntilIdle()

                assertIndexed(state)
                await assertHistory(worker, rebuild ? [.launch, .clear, .index] : [.launch, .index])
            }
        }
    }

    func testBothManualActionsAreGuardedWhileLaunchIsBusy() async {
        let launching = hold("busy launch")
        let worker = ManualIndexStateWorker(holds: [.launch: launching])
        let state = makeState(worker)
        state.start()
        await fulfillment(of: [launching.started], timeout: 3)
        XCTAssertEqual(state.activity, .starting)
        XCTAssertFalse(state.canIndex)
        state.index()
        state.rebuildIndex()
        let held = await worker.snapshot
        XCTAssertEqual(held.events, [.began(.launch)])

        await launching.finish.open()
        await state.waitUntilIdle()

        XCTAssertTrue(state.canIndex)
        await assertHistory(worker, [.launch])
    }

    func testBothManualActionsAreGuardedWhileReadyModelsHaveOtherBusyWork() async {
        let operations: [(ManualIndexCall, AppState.Activity)] = [
            (.refresh, .refreshing), (.search, .searching), (.index, .indexing), (.clear, .clearing)
        ]
        for (operation, activity) in operations {
            let pending = hold("busy \(operation)")
            let worker = ManualIndexStateWorker(holds: [operation: pending])
            let state = makeState(worker)
            await start(state)
            state.query = "TEST manual search"
            switch operation {
            case .refresh: state.refresh()
            case .search: state.search()
            case .index: state.index()
            case .clear: state.clearIndex()
            case .launch: XCTFail("Launch has a separate guard test.")
            }
            await fulfillment(of: [pending.started], timeout: 3)
            XCTAssertEqual(state.activity, activity)
            XCTAssertTrue(state.modelsReady)
            XCTAssertTrue(state.canRead)
            XCTAssertFalse(state.canIndex)
            state.index()
            state.rebuildIndex()
            let held = await worker.snapshot
            XCTAssertEqual(held.events, completed([.launch]) + [.began(operation)])

            await pending.finish.open()
            await state.waitUntilIdle()

            XCTAssertNil(state.activity)
            XCTAssertTrue(state.summary.indexStatisticsKnown, "Successful worker summaries restore known statistics.")
            await assertHistory(worker, [.launch, operation])
        }
    }

    func testAutomaticStartRefreshLibraryChangeAndForegroundNeverIndexOrClear() async {
        for permission in [PHAuthorizationStatus.authorized, .limited, .notDetermined, .denied, .restricted] {
            let worker = ManualIndexStateWorker()
            let state = makeState(worker, authorization: permission)
            XCTAssertFalse(LibrarySummary().authorizedCountKnown)
            XCTAssertTrue(LibrarySummary().indexStatisticsKnown)
            XCTAssertFalse(state.summary.authorizedCountKnown)
            state.start()
            state.start()
            await state.waitUntilIdle()
            XCTAssertEqual(state.launchPhase, .ready)
            XCTAssertFalse(state.summary.authorizedCountKnown)
            await assertHistory(worker, [.launch])

            state.refresh()
            await state.waitUntilIdle()
            await assertHistory(worker, [.launch, .refresh])
            state.libraryChanged()
            await state.waitUntilIdle()
            await assertHistory(worker, [.launch, .refresh, .refresh])

            state.enterForeground() // Already foreground: no work.
            state.start()
            state.enterBackground()
            state.refresh()
            state.libraryChanged()
            await state.waitUntilIdle()
            await assertHistory(worker, [.launch, .refresh, .refresh])

            state.enterForeground()
            state.enterForeground()
            state.start()
            await state.waitUntilIdle()
            XCTAssertEqual(state.launchPhase, .ready)
            XCTAssertFalse(state.summary.authorizedCountKnown)
            XCTAssertEqual(state.authorization, permission)
            XCTAssertEqual(state.canIndex, permission == .authorized || permission == .limited)
            await assertHistory(worker, [.launch, .refresh, .refresh, .refresh])
        }
    }

    private func hold(_ name: String) -> ManualIndexHold {
        ManualIndexHold(started: expectation(description: name))
    }

    private func makeState(_ worker: ManualIndexStateWorker,
                           authorization: PHAuthorizationStatus = .authorized) -> AppState {
        // Same concrete observation wrapper as the existing state tests; fake
        // authorization never requests/grants the simulator Photos permission.
        let state = AppState(library: PhotoLibraryClient(), worker: worker,
                             authorizationStatus: { authorization })
        addTeardownBlock {
            await state.enterBackground()
            await worker.releaseAll()
            await state.waitUntilIdle()
        }
        return state
    }

    private func start(_ state: AppState) async {
        state.start()
        await state.waitUntilIdle()
    }

    private func assertVisibleSearch(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.results.map(\.id), [ManualIndexFixture.hit.id], file: file, line: line)
        XCTAssertEqual(state.completedQuery, "TEST manual search", file: file, line: line)
        XCTAssertNotNil(state.completedSearchQuery, file: file, line: line)
    }

    private func assertInvalidatedSearch(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
    }

    private func assertIndexed(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.summary.authorizedCountKnown, file: file, line: line)
        XCTAssertTrue(state.summary.indexStatisticsKnown, file: file, line: line)
        XCTAssertEqual(state.summary.authorizedCount, 4, file: file, line: line)
        XCTAssertEqual(state.summary.indexedCount, 3, file: file, line: line)
        XCTAssertEqual(state.summary.locatedCount, 1, file: file, line: line)
        XCTAssertEqual(state.summary.modelVersion, ManualIndexFixture.model, file: file, line: line)
        XCTAssertNil(state.activity, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertTrue(state.canIndex, file: file, line: line)
    }

    private func completed(_ calls: [ManualIndexCall]) -> [ManualIndexEvent] {
        calls.flatMap { [ManualIndexEvent.began($0), .finished($0)] }
    }

    private func assertHistory(_ worker: ManualIndexStateWorker, _ calls: [ManualIndexCall],
                               cancelled: [ManualIndexCall] = [],
                               file: StaticString = #filePath, line: UInt = #line) async {
        let snapshot = await worker.snapshot
        XCTAssertEqual(snapshot.events, completed(calls), file: file, line: line)
        XCTAssertEqual(snapshot.cancelled, cancelled, file: file, line: line)
        XCTAssertEqual(snapshot.active, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(snapshot.peakActive, 1, "Whole worker calls must remain serialized.", file: file, line: line)
    }
}

private enum ManualIndexCall: Hashable, Sendable {
    case launch, refresh, search, index, clear
}

private enum ManualIndexEvent: Equatable, Sendable {
    case began(ManualIndexCall), finished(ManualIndexCall)
}

private enum ManualIndexFixture {
    static let model = "TEST-manual-index-model"
    static var metadata: LibrarySummary { LibrarySummary(indexedCount: 2, modelVersion: model) }
    static var indexed: LibrarySummary {
        LibrarySummary(authorizedCount: 4, authorizedCountKnown: true, indexedCount: 3,
                       locatedCount: 1, modelVersion: model)
    }
    static var cleared: LibrarySummary { LibrarySummary(modelVersion: model) }
    static var hit: SearchHit {
        SearchHit(photo: TestFixtures.photo(id: "TEST-manual-photo", model: model).photo, score: 0.75)
    }
}

private actor ManualIndexLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct ManualIndexHold: Sendable {
    let started: XCTestExpectation
    let finish = ManualIndexLatch()
}

/// Reentrant by design: if AppState forgets to await a predecessor, the event
/// ordering and peakActive expose it. Ignoring cancellation here also ensures a
/// successful but cancelled clear cannot rely on the fake to prevent indexing.
private actor ManualIndexStateWorker: PhotoWorkServicing {
    struct Snapshot: Sendable {
        var events: [ManualIndexEvent] = []
        var networkFlags: [Bool] = []
        var cancelled: [ManualIndexCall] = []
        var active = 0
        var peakActive = 0
    }

    private let metadata: LibrarySummary
    private let clearFailure: AppFailure?
    private let allHolds: [ManualIndexCall: ManualIndexHold]
    private var pendingHolds: [ManualIndexCall: ManualIndexHold]
    private(set) var snapshot = Snapshot()

    init(metadata: LibrarySummary = ManualIndexFixture.metadata,
         clearFailure: AppFailure? = nil, holds: [ManualIndexCall: ManualIndexHold] = [:]) {
        self.metadata = metadata
        self.clearFailure = clearFailure
        allHolds = holds
        pendingHolds = holds
    }

    private func begin(_ call: ManualIndexCall) {
        snapshot.events.append(.began(call))
        snapshot.active += 1
        snapshot.peakActive = max(snapshot.peakActive, snapshot.active)
    }

    private func finish(_ call: ManualIndexCall) {
        snapshot.events.append(.finished(call))
        snapshot.active -= 1
        if Task.isCancelled { snapshot.cancelled.append(call) }
    }

    private func waitIfHeld(_ call: ManualIndexCall) async {
        guard let hold = pendingHolds.removeValue(forKey: call) else { return }
        hold.started.fulfill()
        await hold.finish.wait()
    }

    func releaseAll() async {
        for hold in allHolds.values { await hold.finish.open() }
    }

    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        begin(.launch)
        defer { finish(.launch) }
        await progress(.checkingLibrary)
        await progress(.preparingSearch)
        await waitIfHeld(.launch)
        return metadata
    }

    func refresh() async throws -> LibrarySummary {
        begin(.refresh)
        defer { finish(.refresh) }
        await waitIfHeld(.refresh)
        return metadata
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        begin(.index)
        defer { finish(.index) }
        snapshot.networkFlags.append(networkAllowed)
        await progress(IndexProgress(total: 4, completed: 1, encoded: 1))
        await waitIfHeld(.index)
        return ManualIndexFixture.indexed
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        begin(.search)
        defer { finish(.search) }
        await waitIfHeld(.search)
        return SearchResponse(summary: metadata, hits: [ManualIndexFixture.hit])
    }

    func clear() async throws -> LibrarySummary {
        begin(.clear)
        defer { finish(.clear) }
        await waitIfHeld(.clear)
        if let clearFailure { throw clearFailure }
        return ManualIndexFixture.cleared
    }
}