import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

@MainActor
final class AppStateTests: XCTestCase {
    func testDefaultsAreExplicitCloudOptOutAndSixtyPercentLocation() {
        let state = AppState(worker: StateTestWorker(), authorizationStatus: { .notDetermined })
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertFalse(state.debugToolsEnabled)
        XCTAssertEqual(state.locationWeight, 0.6)
        XCTAssertEqual(state.resultLimit, 3)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertEqual(state.authorization, .notDetermined)
    }

    func testMissingModelsDoNotHidePhotoAuthorizationState() async {
        let worker = StateTestWorker(modelIssue: "Install a model-enabled build.")
        let state = AppState(worker: worker, authorizationStatus: { .limited })
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.canRead)
        XCTAssertEqual(state.authorization, .limited)
        XCTAssertFalse(state.modelsReady)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.canSearch)
        XCTAssertNotNil(state.summary.modelIssue)
    }

    func testReplacementWaitsForPredecessorAndRejectsItsStaleSummary() async {
        let started = expectation(description: "First refresh reached suspended work")
        let worker = StateTestWorker(holding: .refresh, started: started)
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await fulfillment(of: [started], timeout: 3)
        state.refresh()
        await worker.release()
        await state.waitUntilIdle()
        let peak = await worker.peakConcurrency
        let count = await worker.refreshCount
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(state.summary.indexedCount, 2)
        XCTAssertFalse(state.isBusy)
    }

    func testLibraryChangeClearsResultsAndDiscardsCancelledSearch() async {
        let started = expectation(description: "Search reached suspended work")
        let worker = StateTestWorker(holding: .search, started: started)
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        state.query = "Synthetic query"
        state.search()
        await fulfillment(of: [started], timeout: 3)
        state.selection = AppState.Selection(id: "synthetic-asset")
        state.libraryChanged()
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.selection)
        await worker.release()
        await state.waitUntilIdle()
        XCTAssertTrue(state.results.isEmpty)
        let peak = await worker.peakConcurrency
        XCTAssertEqual(peak, 1)
    }

    func testEditingWeightInvalidatesInFlightSearch() async {
        let started = expectation(description: "Search started")
        let worker = StateTestWorker(holding: .search, started: started)
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        state.query = "Synthetic query"
        state.search()
        await fulfillment(of: [started], timeout: 3)
        state.locationWeight = 1
        await worker.release()
        await state.waitUntilIdle()
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertFalse(state.isBusy)
    }

    func testIndexCancellationRetainsProgressAndPassesCloudOptOut() async {
        let started = expectation(description: "Index saved first record")
        let worker = StateTestWorker(holding: .index, started: started)
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        state.index()
        await fulfillment(of: [started], timeout: 3)
        state.cancel()
        await worker.release()
        await state.waitUntilIdle()
        XCTAssertEqual(state.progress.completed, 1)
        XCTAssertEqual(state.progress.encoded, 1)
        let received = await worker.networkAllowed
        XCTAssertEqual(received, false)
        XCTAssertTrue(state.status.contains("Completed records"))
    }

    func testBackgroundLibraryChangeDoesNotStartForegroundWork() async {
        let worker = StateTestWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        state.enterBackground()
        state.libraryChanged()
        await state.waitUntilIdle()
        let before = await worker.refreshCount
        XCTAssertEqual(before, 1)
        state.enterForeground()
        await state.waitUntilIdle()
        let after = await worker.refreshCount
        XCTAssertEqual(after, 2)
    }

    func testErrorsExposeActionableUIState() async {
        let state = AppState(worker: StateTestWorker(failRefresh: true), authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertNotNil(state.errorMessage)
        XCTAssertNotNil(state.actionHint)
        XCTAssertFalse(state.isBusy)
        state.dismissError()
        XCTAssertNil(state.errorMessage)
    }
}

private actor TestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// Deliberately finishes after cancellation, modelling a noninterruptible Core ML
/// prediction. AppState must still discard it AND wait before starting another job.
private actor StateTestWorker: PhotoWorkServicing {
    enum HeldOperation: Equatable { case refresh, search, index }
    private let holding: HeldOperation?
    private let started: XCTestExpectation?
    private let latch = TestLatch()
    private let modelIssue: String?
    private let failRefresh: Bool
    private var active = 0
    private(set) var peakConcurrency = 0
    private(set) var refreshCount = 0
    private(set) var networkAllowed: Bool?

    init(holding: HeldOperation? = nil, started: XCTestExpectation? = nil, modelIssue: String? = nil, failRefresh: Bool = false) {
        self.holding = holding
        self.started = started
        self.modelIssue = modelIssue
        self.failRefresh = failRefresh
    }

    func release() async { await latch.open() }

    private func begin() { active += 1; peakConcurrency = max(peakConcurrency, active) }

    func refresh() async throws -> LibrarySummary {
        begin()
        defer { active -= 1 }
        refreshCount += 1
        let count = refreshCount
        if holding == .refresh, count == 1 { started?.fulfill(); await latch.wait() }
        if failRefresh { throw AppFailure.storage("Synthetic storage error") }
        return LibrarySummary(authorizedCount: count, indexedCount: count,
                              modelVersion: modelIssue == nil ? "test-model" : nil, modelIssue: modelIssue)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        begin()
        defer { active -= 1 }
        self.networkAllowed = networkAllowed
        await progress(IndexProgress(total: 2, completed: 1, encoded: 1))
        if holding == .index { started?.fulfill(); await latch.wait() }
        return LibrarySummary(authorizedCount: 2, indexedCount: 2, modelVersion: "test-model")
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        begin()
        defer { active -= 1 }
        if holding == .search { started?.fulfill(); await latch.wait() }
        let photo = TestFixtures.photo().photo
        let hits = try VectorSearch.search(query: TestFixtures.vector(), photos: [photo], limit: limit, locationWeight: locationWeight)
        return SearchResponse(summary: LibrarySummary(authorizedCount: 1, indexedCount: 1, modelVersion: "test-model"), hits: hits)
    }

    func clear() async throws -> LibrarySummary { LibrarySummary(modelVersion: "test-model") }
}