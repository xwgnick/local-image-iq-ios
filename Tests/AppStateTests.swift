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

    func testFinalSearchValidationFailurePublishesNeitherSummaryNorResults() async {
        let failure = AppFailure.photo("TEST-final-search-access-changed")
        let worker = StateTestWorker(finalValidation: { throw failure })
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertEqual(state.summary.indexedCount, 2, "The prepared search response has different counts.")
        state.query = "Synthetic query"
        XCTAssertTrue(state.canSearch)

        state.search()
        await state.waitUntilIdle()

        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(state.summary.authorizedCount, 2)
        XCTAssertEqual(state.summary.indexedCount, 2, "Validation must precede summary publication, not just results.")
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.completedQuery)
        XCTAssertNil(state.completedSearchQuery)
        XCTAssertEqual(state.errorMessage, failure.localizedDescription)
        XCTAssertNotNil(state.actionHint)
        XCTAssertFalse(state.isBusy)
    }

    func testSuccessfulFinalSearchValidationPublishesThePreparedResponse() async {
        let validated = expectation(description: "Final publication access check ran")
        let worker = StateTestWorker(finalValidation: { validated.fulfill() })
        let state = AppState(worker: worker, authorizationStatus: { .limited })
        state.refresh()
        await state.waitUntilIdle()
        state.query = "Synthetic query"

        state.search()
        await state.waitUntilIdle()
        await fulfillment(of: [validated], timeout: 3)

        XCTAssertEqual(state.authorization, .limited)
        XCTAssertEqual(state.summary.indexedCount, 1)
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertEqual(state.results.map(\.id), [TestFixtures.photo().photo.id])
        XCTAssertEqual(state.completedQuery, "Synthetic query")
        XCTAssertEqual(state.completedSearchQuery?.effective, "Synthetic query")
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.actionHint)
        XCTAssertFalse(state.isBusy)
    }

    func testPermissionRevokedAfterSearchPreparationRejectsPublicationWithoutLibraryChange() async {
        for initialPermission in [PHAuthorizationStatus.authorized, .limited] {
            let prepared = expectation(description: "Response prepared before publication for \(initialPermission)")
            let worker = StateTestWorker(holding: .search, started: prepared, finalValidation: {
                throw AppFailure.photo("TEST-response-validator-must-not-precede-permission-guard")
            })
            let authorization = StateTestAuthorization(initialPermission)
            let state = AppState(worker: worker, authorizationStatus: { authorization.status })
            addTeardownBlock {
                await worker.release()
                await state.waitUntilIdle()
            }
            state.refresh()
            await state.waitUntilIdle()
            state.refresh()
            await state.waitUntilIdle()
            state.query = "Synthetic query"
            XCTAssertTrue(state.canSearch)
            state.search()
            await fulfillment(of: [prepared], timeout: 3)

            // Mutate only the MainActor provider. No libraryChanged(), refresh(),
            // cancellation or setting edit may invalidate this search for us.
            authorization.status = .denied
            XCTAssertEqual(state.authorization, initialPermission)
            XCTAssertEqual(state.activity, .searching)
            await worker.release()
            await state.waitUntilIdle()

            XCTAssertEqual(state.authorization, .denied)
            XCTAssertFalse(state.canRead)
            XCTAssertFalse(state.canSearch)
            XCTAssertEqual(state.errorMessage, AppFailure.permission.localizedDescription)
            XCTAssertNotNil(state.actionHint)
            XCTAssertEqual(state.summary.authorizedCount, 2)
            XCTAssertEqual(state.summary.indexedCount, 2)
            XCTAssertTrue(state.results.isEmpty)
            XCTAssertNil(state.completedQuery)
            XCTAssertNil(state.completedSearchQuery)
            XCTAssertFalse(state.isBusy)
            let refreshCount = await worker.refreshCount
            XCTAssertEqual(refreshCount, 2, "No Photos observer or refresh is needed to reject publication.")
        }
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

@MainActor
private final class StateTestAuthorization {
    var status: PHAuthorizationStatus

    init(_ status: PHAuthorizationStatus) { self.status = status }
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
    private let finalValidation: @Sendable () throws -> Void
    private var active = 0
    private(set) var peakConcurrency = 0
    private(set) var refreshCount = 0
    private(set) var networkAllowed: Bool?

    init(holding: HeldOperation? = nil, started: XCTestExpectation? = nil, modelIssue: String? = nil,
         failRefresh: Bool = false, finalValidation: @escaping @Sendable () throws -> Void = {}) {
        self.holding = holding
        self.started = started
        self.modelIssue = modelIssue
        self.failRefresh = failRefresh
        self.finalValidation = finalValidation
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
        let photo = TestFixtures.photo().photo
        let hits = try VectorSearch.search(query: TestFixtures.vector(), photos: [photo], limit: limit, locationWeight: locationWeight)
        let response = SearchResponse(summary: LibrarySummary(authorizedCount: 1, indexedCount: 1, modelVersion: "test-model"),
                                      hits: hits, validateAccess: finalValidation)
        // Hold only after preparing the response; its synchronous validator must
        // run in AppState at publication, never inside this suspended worker.
        if holding == .search { started?.fulfill(); await latch.wait() }
        return response
    }

    func clear() async throws -> LibrarySummary { LibrarySummary(modelVersion: "test-model") }
}