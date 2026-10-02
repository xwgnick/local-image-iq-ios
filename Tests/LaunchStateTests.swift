import Combine
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// State-machine tests only: synthetic summaries, injected authorization and
/// explicitly released worker continuations. No models, Photos authorization
/// requests, image reads, translation sessions, network calls or timed sleeps.
@MainActor
final class LaunchStateTests: XCTestCase {
    func testHeldLaunchPublishesActualStagesAndCannotBecomeReadyBeforeCompletion() async {
        let hold = heldLaunch("cold launch")
        let worker = FakeLaunchWorker(plans: [.init(hold: hold)])
        let state = makeState(worker)
        var phases: [AppState.LaunchPhase] = []
        let observation = state.$launchPhase.removeDuplicates().sink { phases.append($0) }
        defer { observation.cancel() }
        state.query = "TEST query"

        state.start()
        await fulfillment(of: [hold.checking], timeout: 3)
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        XCTAssertEqual(state.activity, .starting)
        XCTAssertTrue(state.isBusy)
        XCTAssertFalse(state.modelsReady)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.canSearch)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertFalse(state.summary.authorizedCountKnown)

        await hold.prepare.open()
        await fulfillment(of: [hold.preparing], timeout: 3)
        XCTAssertEqual(state.launchPhase, .preparingSearch)
        XCTAssertEqual(state.activity, .starting)
        XCTAssertEqual(state.summary.indexedCount, 0, "A stage is not a completed summary.")
        XCTAssertFalse(state.canSearch)

        await hold.finish.open()
        await state.waitUntilIdle()
        XCTAssertEqual(phases, [.pending, .checkingLibrary, .preparingSearch, .ready])
        XCTAssertEqual(state.summary.indexedCount, 2)
        XCTAssertFalse(state.summary.authorizedCountKnown, "Launch reads metadata, not the current Photos count.")
        XCTAssertTrue(state.modelsReady)
        XCTAssertTrue(state.canSearch)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.launchIssue)
        await assertCalls(worker, launches: 1)
    }

    func testRepeatedStartIsIdempotentWhileCheckingPreparingAndReady() async {
        let hold = heldLaunch("idempotent launch")
        let worker = FakeLaunchWorker(plans: [.init(hold: hold)])
        let state = makeState(worker)
        state.start()
        state.start()
        await fulfillment(of: [hold.checking], timeout: 3)
        state.start()
        state.retryLaunch()
        await assertCalls(worker, launches: 1)

        await hold.prepare.open()
        await fulfillment(of: [hold.preparing], timeout: 3)
        state.start()
        state.retryLaunch()
        await hold.finish.open()
        await state.waitUntilIdle()
        state.start()
        state.retryLaunch()
        state.enterForeground()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        await assertCalls(worker, launches: 1)
    }

    func testEmptyAndUnauthorizedLibrariesCanFinishLaunchWithInjectedAuthorization() async {
        let statuses: [PHAuthorizationStatus] = [.authorized, .limited, .notDetermined, .denied, .restricted]
        for authorization in statuses {
            let empty = LibrarySummary(modelVersion: "TEST-empty-model")
            let worker = FakeLaunchWorker(plans: [.init(summary: empty)])
            let state = makeState(worker, authorization: authorization)
            state.query = "TEST query"
            state.start()
            await state.waitUntilIdle()

            let readable = authorization == .authorized || authorization == .limited
            XCTAssertEqual(state.authorization, authorization)
            XCTAssertEqual(state.launchPhase, .ready)
            XCTAssertTrue(state.modelsReady)
            XCTAssertEqual(state.canRead, readable)
            XCTAssertEqual(state.canIndex, readable, "An empty authorized library may still be indexed.")
            XCTAssertFalse(state.canSearch)
            XCTAssertEqual(state.summary.authorizedCount, 0)
            XCTAssertEqual(state.summary.indexedCount, 0)
            XCTAssertNil(state.launchIssue)
            XCTAssertNil(state.errorMessage)
            await assertCalls(worker, launches: 1)
        }
    }

    func testModelIssueFailsWithGenericLaunchMessageAndExplicitRetryRecovers() async throws {
        let rawIssue = "TEST-model-contract-detail"
        let failed = LibrarySummary(authorizedCount: 5, modelIssue: rawIssue)
        let retry = heldLaunch("explicit retry")
        let worker = FakeLaunchWorker(plans: [.init(summary: failed), .init(hold: retry)])
        let state = makeState(worker)
        state.query = "TEST query"
        state.start()
        await state.waitUntilIdle()

        XCTAssertEqual(state.launchPhase, .failed)
        XCTAssertEqual(state.summary.modelIssue, rawIssue)
        XCTAssertEqual(state.errorMessage, rawIssue)
        let message = try XCTUnwrap(state.launchIssue)
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains(rawIssue), "The launch page uses a generic message, not model internals.")
        XCTAssertFalse(state.modelsReady)
        XCTAssertFalse(state.canSearch)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.isBusy)

        state.retryLaunch()
        state.retryLaunch()
        await fulfillment(of: [retry.checking], timeout: 3)
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        XCTAssertEqual(state.activity, .starting)
        XCTAssertNil(state.launchIssue)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.canSearch)
        await retry.prepare.open()
        await fulfillment(of: [retry.preparing], timeout: 3)
        await retry.finish.open()
        await state.waitUntilIdle()

        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertNil(state.launchIssue)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.summary.modelIssue)
        XCTAssertTrue(state.canSearch)
        await assertCalls(worker, launches: 2)
    }

    func testThrownFailureRequiresExplicitContinueAndPreservesErrorWithoutDoingWork() async throws {
        let failure = AppFailure.storage("TEST-launch-storage-failure")
        let worker = FakeLaunchWorker(plans: [.init(failure: failure)])
        let state = makeState(worker)
        state.query = "TEST query"
        state.start()
        await state.waitUntilIdle()

        XCTAssertEqual(state.launchPhase, .failed)
        XCTAssertEqual(state.errorMessage, failure.localizedDescription)
        let issue = try XCTUnwrap(state.launchIssue)
        let hint = try XCTUnwrap(state.actionHint)
        XCTAssertFalse(issue.isEmpty)
        XCTAssertFalse(issue.contains("TEST-launch-storage-failure"))
        XCTAssertFalse(state.isBusy)
        state.openHomeAfterLaunchFailure()
        await state.waitUntilIdle()

        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.launchIssue, issue)
        XCTAssertEqual(state.errorMessage, failure.localizedDescription)
        XCTAssertEqual(state.actionHint, hint)
        XCTAssertFalse(state.modelsReady)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.canSearch)
        state.index()
        state.search()
        state.start()
        state.retryLaunch()
        state.openHomeAfterLaunchFailure()
        await state.waitUntilIdle()
        await assertCalls(worker, launches: 1)
    }

    func testContinueCannotBypassPendingOrEitherLoadingStage() async {
        let hold = heldLaunch("cannot bypass")
        let worker = FakeLaunchWorker(plans: [.init(hold: hold)])
        let state = makeState(worker)
        state.openHomeAfterLaunchFailure()
        XCTAssertEqual(state.launchPhase, .pending)
        await assertCalls(worker, launches: 0)

        state.start()
        await fulfillment(of: [hold.checking], timeout: 3)
        state.openHomeAfterLaunchFailure()
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        XCTAssertEqual(state.activity, .starting)
        await hold.prepare.open()
        await fulfillment(of: [hold.preparing], timeout: 3)
        state.openHomeAfterLaunchFailure()
        XCTAssertEqual(state.launchPhase, .preparingSearch)
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.summary.indexedCount, 0)
        await hold.finish.open()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        await assertCalls(worker, launches: 1)
    }

    func testBackgroundRejectsLateSuccessModelIssueAndThrowAndRemainsPending() async {
        let outcomes: [FakeLaunchWorker.Outcome] = [
            .success(LibrarySummary(authorizedCount: 99, indexedCount: 99, modelVersion: "TEST-stale-model")),
            .success(LibrarySummary(authorizedCount: 99, modelIssue: "TEST-late-model-issue")),
            .failure(.storage("TEST-late-storage-error"))
        ]
        for outcome in outcomes {
            let hold = heldLaunch("background late completion")
            let worker = FakeLaunchWorker(plans: [.init(outcome: outcome, hold: hold)])
            let state = makeState(worker)
            state.start()
            await fulfillment(of: [hold.checking], timeout: 3)
            state.enterBackground()
            XCTAssertEqual(state.launchPhase, .pending)
            await hold.prepare.open()
            await fulfillment(of: [hold.preparing], timeout: 3)
            XCTAssertEqual(state.launchPhase, .pending, "A late callback cannot leave the background gate.")
            await hold.finish.open()
            await state.waitUntilIdle()

            XCTAssertEqual(state.launchPhase, .pending)
            XCTAssertEqual(state.summary.authorizedCount, 0)
            XCTAssertEqual(state.summary.indexedCount, 0)
            XCTAssertNil(state.summary.modelVersion)
            XCTAssertNil(state.summary.modelIssue)
            XCTAssertNil(state.launchIssue)
            XCTAssertNil(state.errorMessage)
            XCTAssertNil(state.activity)
            XCTAssertFalse(state.canSearch)
            await assertCalls(worker, launches: 1)
        }
    }

    func testForegroundRestartDrainsCancelledLaunchBeforeStartingItsReplacement() async {
        let first = heldLaunch("cancelled launch")
        let second = heldLaunch("foreground replacement")
        let stale = LibrarySummary(authorizedCount: 99, indexedCount: 99, modelVersion: "TEST-stale-model")
        let worker = FakeLaunchWorker(plans: [.init(summary: stale, hold: first), .init(hold: second)])
        let state = makeState(worker)
        state.start()
        await fulfillment(of: [first.checking], timeout: 3)
        state.enterBackground()
        state.enterForeground()
        state.enterForeground()
        state.start()
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        await assertCalls(worker, launches: 1)

        await first.prepare.open()
        await fulfillment(of: [first.preparing], timeout: 3)
        XCTAssertEqual(state.launchPhase, .checkingLibrary, "The predecessor's stage token is stale.")
        await first.finish.open()
        await fulfillment(of: [second.checking], timeout: 3)
        let running = await worker.calls
        XCTAssertEqual(running.active, 1)
        XCTAssertEqual(running.peakActive, 1, "Actor reentrancy alone must not allow overlapping launches.")
        XCTAssertEqual(running.launches, 2)
        XCTAssertEqual(state.summary.indexedCount, 0, "The cancelled predecessor must never publish its summary.")
        await second.prepare.open()
        await fulfillment(of: [second.preparing], timeout: 3)
        await second.finish.open()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.summary.indexedCount, 2)
        let finished = await worker.calls
        XCTAssertEqual(finished.active, 0)
        await assertCalls(worker, launches: 2)
    }

    func testCompletedLaunchUsesOneLightRefreshOnForegroundWithoutRewarming() async {
        let refreshed = LibrarySummary(authorizedCount: 9, indexedCount: 7, modelVersion: "TEST-refreshed-model")
        let worker = FakeLaunchWorker(refreshSummary: refreshed)
        let state = makeState(worker)
        state.start()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        state.enterForeground()
        await assertCalls(worker, launches: 1)

        state.enterBackground()
        state.enterForeground()
        state.enterForeground()
        state.start()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.activity, .refreshing)
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.summary.indexedCount, 7)
        XCTAssertEqual(state.summary.modelVersion, refreshed.modelVersion)
        XCTAssertFalse(state.isBusy)
        await assertCalls(worker, launches: 1, refreshes: 1)
    }

    func testFailedLaunchDoesNotAutomaticallyRetryOnForegroundRefreshOrLibraryChange() async throws {
        let worker = FakeLaunchWorker(plans: [.init(failure: .storage("TEST-explicit-retry-only"))])
        let state = makeState(worker)
        state.start()
        await state.waitUntilIdle()
        let issue = try XCTUnwrap(state.launchIssue)
        let error = try XCTUnwrap(state.errorMessage)
        let hint = state.actionHint

        state.enterBackground()
        state.openHomeAfterLaunchFailure()
        state.retryLaunch()
        state.start()
        XCTAssertEqual(state.launchPhase, .failed, "Recovery actions require the foreground.")
        state.enterForeground()
        state.enterForeground()
        state.start()
        state.refresh()
        state.libraryChanged()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .failed)
        XCTAssertEqual(state.launchIssue, issue)
        XCTAssertEqual(state.errorMessage, error)
        XCTAssertEqual(state.actionHint, hint)
        XCTAssertFalse(state.isBusy)
        await assertCalls(worker, launches: 1)
    }

    func testLibraryChangeAndRefreshDuringPreparationUpdatePermissionWithoutRestartingLaunch() async {
        for useLibraryChange in [true, false] {
            for changedAuthorization in [PHAuthorizationStatus.denied, .limited] {
                let hold = heldLaunch("photo-independent preparation")
                let permission = LaunchStateAuthorization(.authorized)
                let worker = FakeLaunchWorker(plans: [.init(hold: hold)])
                let state = makeState(worker, authorizationStatus: { permission.value })
                var phases: [AppState.LaunchPhase] = []
                let observation = state.$launchPhase.removeDuplicates().sink { phases.append($0) }
                defer { observation.cancel() }
                state.query = "TEST query"
                state.start()
                await fulfillment(of: [hold.checking], timeout: 3)
                await hold.prepare.open()
                await fulfillment(of: [hold.preparing], timeout: 3)
                state.selection = AppState.Selection(id: "TEST-selection")
                permission.value = changedAuthorization

                if useLibraryChange { state.libraryChanged() } else { state.refresh() }
                XCTAssertEqual(state.authorization, changedAuthorization, "Permission updates before model preparation returns.")
                XCTAssertEqual(state.canRead, changedAuthorization == .limited)
                XCTAssertNil(state.selection)
                XCTAssertTrue(state.results.isEmpty)
                XCTAssertNil(state.completedQuery)
                XCTAssertNil(state.completedSearchQuery)
                XCTAssertEqual(state.launchPhase, .preparingSearch)
                XCTAssertEqual(state.activity, .starting)
                XCTAssertTrue(state.isBusy)
                XCTAssertFalse(state.modelsReady)
                XCTAssertFalse(state.canIndex)
                XCTAssertFalse(state.canSearch)
                XCTAssertEqual(state.summary.indexedCount, 0, "Only completion may publish the prepared metadata.")

                // Repeated notifications neither cancel this attempt nor schedule
                // a replacement model load/read-only refresh behind it.
                state.libraryChanged()
                state.refresh()
                state.start()
                state.retryLaunch()
                await worker.emit(.preparingSearch, attempt: 1)
                XCTAssertEqual(phases, [.pending, .checkingLibrary, .preparingSearch])
                await assertCalls(worker, launches: 1)

                await hold.finish.open()
                await state.waitUntilIdle()
                await worker.emit(.checkingLibrary, attempt: 1)
                XCTAssertEqual(phases, [.pending, .checkingLibrary, .preparingSearch, .ready])
                XCTAssertEqual(state.authorization, changedAuthorization)
                XCTAssertEqual(state.summary.indexedCount, 2)
                XCTAssertFalse(state.summary.authorizedCountKnown)
                XCTAssertEqual(state.summary.modelVersion, "TEST-launch-model")
                XCTAssertTrue(state.modelsReady)
                XCTAssertEqual(state.canIndex, changedAuthorization == .limited)
                XCTAssertEqual(state.canSearch, changedAuthorization == .limited)
                XCTAssertNil(state.activity)
                XCTAssertNil(state.launchIssue)
                XCTAssertNil(state.errorMessage)
                let calls = await worker.calls
                XCTAssertEqual(calls.cancelledLaunches, 0, "Photos changes must not cancel model preparation.")
                await assertCalls(worker, launches: 1)
            }
        }
    }

    func testLibraryChangeAfterLaunchClearsRealSearchResultsAndUpdatesPermissionBeforeReadOnlyRefresh() async {
        let permission = LaunchStateAuthorization(.authorized)
        let refresh = HeldStateRefresh(started: expectation(description: "Read-only refresh started"))
        let hit = SearchHit(photo: TestFixtures.photo(id: "TEST-visible-photo").photo, score: 0.75)
        let worker = FakeLaunchWorker(refreshHold: refresh, searchHits: [hit])
        let state = makeState(worker, authorizationStatus: { permission.value })
        state.start()
        await state.waitUntilIdle()
        state.query = "TEST query"
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.results.map(\.id), [hit.id])
        XCTAssertEqual(state.completedQuery, "TEST query")
        XCTAssertNotNil(state.completedSearchQuery)
        state.selection = AppState.Selection(id: hit.id)

        permission.value = .denied
        state.libraryChanged()
        XCTAssertEqual(state.authorization, .denied)
        XCTAssertFalse(state.canRead)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.completedQuery)
        XCTAssertNil(state.completedSearchQuery)
        XCTAssertEqual(state.launchPhase, .ready, "A Photos change must not replay the startup gate.")
        XCTAssertEqual(state.activity, .refreshing)
        await fulfillment(of: [refresh.started], timeout: 3)
        await assertCalls(worker, launches: 1, refreshes: 1, searches: 1)
        await refresh.finish.open()
        await state.waitUntilIdle()

        XCTAssertEqual(state.authorization, .denied)
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.activity)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.canSearch)
        await assertCalls(worker, launches: 1, refreshes: 1, searches: 1)
    }

    func testStartRequestedBeforeFirstForegroundIsRememberedAndLaunchesInsteadOfRefreshing() async {
        let worker = FakeLaunchWorker()
        let state = makeState(worker)
        state.enterBackground()
        state.start()
        state.start()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .pending)
        XCTAssertFalse(state.isBusy)
        await assertCalls(worker, launches: 0)

        // Regression: start() must remember the request before its foreground
        // guard; otherwise enterForeground() incorrectly performs only refresh().
        state.enterForeground()
        await state.waitUntilIdle()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertTrue(state.modelsReady)
        await assertCalls(worker, launches: 1)
    }

    func testLaunchPreservesOriginalQueryModelIdentityAndUserSearchSettings() async {
        let summary = LibrarySummary(authorizedCount: 4, indexedCount: 3, locatedCount: 1,
                                     modelVersion: "TEST-existing-model|TEST-existing-input-policy")
        let worker = FakeLaunchWorker(plans: [.init(summary: summary)], refreshSummary: summary)
        let state = makeState(worker, authorization: .limited)
        let original = "  TEST Original MiXeD Query  "
        state.query = original
        state.locationWeight = 0.85
        state.resultLimit = 12
        state.allowICloudDownload = true
        state.chineseSearchEnabled = false
        state.translationLanguage = .traditional
        state.start()
        await state.waitUntilIdle()

        XCTAssertEqual(state.query, original)
        XCTAssertEqual(state.summary.modelVersion, summary.modelVersion)
        XCTAssertEqual(state.summary.locatedCount, 1)
        XCTAssertEqual(state.locationWeight, 0.85)
        XCTAssertEqual(state.resultLimit, 12)
        XCTAssertTrue(state.allowICloudDownload)
        XCTAssertFalse(state.chineseSearchEnabled)
        XCTAssertEqual(state.translationLanguage, .traditional)
        XCTAssertTrue(state.canSearch)
        state.search()
        await state.waitUntilIdle()
        let request = await worker.searchRequests.last
        XCTAssertEqual(request?.text, original)
        XCTAssertEqual(request?.limit, 12)
        XCTAssertEqual(request?.locationWeight, Float(0.85))
        XCTAssertEqual(state.completedQuery, original)
        XCTAssertEqual(state.completedSearchQuery?.effective, original)
        await assertCalls(worker, launches: 1, searches: 1)
    }

    func testDefaultsAndReadinessGuardsRemainEffectiveBeforeAndAfterLaunch() async {
        let worker = FakeLaunchWorker()
        let state = makeState(worker)
        XCTAssertEqual(state.launchPhase, .pending)
        XCTAssertEqual(state.locationWeight, 0.6)
        XCTAssertEqual(state.resultLimit, 3)
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertFalse(state.debugToolsEnabled)
        XCTAssertTrue(state.query.isEmpty)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertFalse(state.modelsReady)
        XCTAssertFalse(state.canIndex)
        state.query = "TEST query"
        XCTAssertFalse(state.canSearch)
        state.search()
        state.index()
        state.retryLaunch()
        await state.waitUntilIdle()
        await assertCalls(worker, launches: 0)

        state.query = ""
        state.start()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertTrue(state.canIndex)
        XCTAssertFalse(state.canSearch)
        state.query = " \n\t "
        XCTAssertFalse(state.canSearch)
        state.query = "TEST query"
        XCTAssertTrue(state.canSearch)
        state.index()
        await state.waitUntilIdle()
        XCTAssertTrue(state.summary.authorizedCountKnown, "An explicit mock scan supplies a current Photos count.")
        state.search()
        await state.waitUntilIdle()
        let network = await worker.networkRequests
        let request = await worker.searchRequests.last
        XCTAssertEqual(network, [false])
        XCTAssertEqual(request?.text, "TEST query")
        XCTAssertEqual(request?.limit, 3)
        XCTAssertEqual(request?.locationWeight, Float(0.6))
        XCTAssertEqual(state.locationWeight, 0.6)
        XCTAssertEqual(state.resultLimit, 3)
        XCTAssertFalse(state.allowICloudDownload)
        await assertCalls(worker, launches: 1, indexes: 1, searches: 1)
    }

    private func heldLaunch(_ name: String) -> HeldStateLaunch {
        HeldStateLaunch(checking: expectation(description: "\(name): checking callback accepted"),
                        preparing: expectation(description: "\(name): preparing callback returned"))
    }

    private func makeState(_ worker: FakeLaunchWorker,
                           authorization: PHAuthorizationStatus = .authorized,
                           authorizationStatus: (() -> PHAuthorizationStatus)? = nil) -> AppState {
        // AppState still needs its concrete client to register the change handler.
        // Injected authorization does not grant real Photos access. On the
        // unauthorized simulator synchronizeObservation() never registers with
        // PHPhotoLibrary; all actual work below is handled by the actor fake.
        let state = AppState(library: PhotoLibraryClient(), worker: worker,
                             authorizationStatus: authorizationStatus ?? { authorization })
        addTeardownBlock {
            await state.enterBackground()
            await worker.releaseAll()
            await state.waitUntilIdle()
        }
        return state
    }

    private func assertCalls(_ worker: FakeLaunchWorker, launches: Int,
                             refreshes: Int = 0, indexes: Int = 0, searches: Int = 0,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await worker.calls
        XCTAssertEqual(calls.launches, launches, file: file, line: line)
        XCTAssertEqual(calls.refreshes, refreshes, file: file, line: line)
        XCTAssertEqual(calls.indexes, indexes, file: file, line: line)
        XCTAssertEqual(calls.searches, searches, file: file, line: line)
        XCTAssertEqual(calls.clears, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(calls.peakActive, 1, "Cancelled predecessors must drain.", file: file, line: line)
    }
}

@MainActor
private final class LaunchStateAuthorization {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

private actor LaunchStateLatch {
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

private struct HeldStateLaunch: Sendable {
    let checking: XCTestExpectation
    let preparing: XCTestExpectation
    let prepare = LaunchStateLatch()
    let finish = LaunchStateLatch()
}

private struct HeldStateRefresh: Sendable {
    let started: XCTestExpectation
    let finish = LaunchStateLatch()
}

/// Deliberately ignores cancellation and keeps old progress callbacks so tests
/// can deliver stages/results after replacement. A real noninterruptible model
/// load must be drained even though its result has already been invalidated.
private actor FakeLaunchWorker: PhotoWorkServicing {
    enum Outcome: Sendable {
        case success(LibrarySummary)
        case failure(AppFailure)
    }

    struct Plan: Sendable {
        let outcome: Outcome
        let hold: HeldStateLaunch?

        init(summary: LibrarySummary = LibrarySummary(indexedCount: 2,
                                                       modelVersion: "TEST-launch-model"),
             hold: HeldStateLaunch? = nil) {
            self.init(outcome: .success(summary), hold: hold)
        }

        init(failure: AppFailure, hold: HeldStateLaunch? = nil) {
            self.init(outcome: .failure(failure), hold: hold)
        }

        init(outcome: Outcome, hold: HeldStateLaunch? = nil) {
            self.outcome = outcome
            self.hold = hold
        }
    }

    struct Calls: Sendable {
        var launches = 0
        var cancelledLaunches = 0
        var refreshes = 0
        var indexes = 0
        var searches = 0
        var clears = 0
        var active = 0
        var peakActive = 0
    }

    struct SearchRequest: Sendable {
        let text: String
        let limit: Int
        let locationWeight: Float
    }

    private let plans: [Plan]
    private let refreshSummary: LibrarySummary
    private let refreshHold: HeldStateRefresh?
    private let searchHits: [SearchHit]
    private var callbacks: [Int: @Sendable (LaunchStage) async -> Void] = [:]
    private(set) var calls = Calls()
    private(set) var networkRequests: [Bool] = []
    private(set) var searchRequests: [SearchRequest] = []

    init(plans: [Plan] = [Plan()],
         refreshSummary: LibrarySummary = LibrarySummary(indexedCount: 2,
                                                          modelVersion: "TEST-launch-model"),
         refreshHold: HeldStateRefresh? = nil, searchHits: [SearchHit] = []) {
        self.plans = plans
        self.refreshSummary = refreshSummary
        self.refreshHold = refreshHold
        self.searchHits = searchHits
    }

    private func begin() {
        calls.active += 1
        calls.peakActive = max(calls.peakActive, calls.active)
    }

    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        begin()
        defer {
            calls.active -= 1
            if Task.isCancelled { calls.cancelledLaunches += 1 }
        }
        calls.launches += 1
        let attempt = calls.launches
        guard plans.indices.contains(attempt - 1) else {
            throw AppFailure.storage("TEST-unexpected-extra-launch")
        }
        let plan = plans[attempt - 1]
        callbacks[attempt] = progress
        await progress(.checkingLibrary)
        if let hold = plan.hold {
            hold.checking.fulfill()
            await hold.prepare.wait()
        }
        await progress(.preparingSearch)
        if let hold = plan.hold {
            hold.preparing.fulfill()
            await hold.finish.wait()
        }
        switch plan.outcome {
        case .success(let summary): return summary
        case .failure(let error): throw error
        }
    }

    func emit(_ stage: LaunchStage, attempt: Int) async {
        guard let callback = callbacks[attempt] else {
            XCTFail("Test attempted to publish progress before that launch started.")
            return
        }
        await callback(stage)
    }

    func releaseAll() async {
        for plan in plans {
            if let hold = plan.hold {
                await hold.prepare.open()
                await hold.finish.open()
            }
        }
        if let refreshHold { await refreshHold.finish.open() }
    }

    func refresh() async throws -> LibrarySummary {
        begin()
        defer { calls.active -= 1 }
        calls.refreshes += 1
        if let refreshHold, calls.refreshes == 1 {
            refreshHold.started.fulfill()
            await refreshHold.finish.wait()
        }
        return refreshSummary
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        begin()
        defer { calls.active -= 1 }
        calls.indexes += 1
        networkRequests.append(networkAllowed)
        var summary = refreshSummary
        summary.authorizedCount = max(summary.authorizedCount, summary.indexedCount)
        summary.authorizedCountKnown = true
        return summary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        begin()
        defer { calls.active -= 1 }
        calls.searches += 1
        searchRequests.append(SearchRequest(text: text, limit: limit, locationWeight: locationWeight))
        return SearchResponse(summary: refreshSummary, hits: searchHits)
    }

    func clear() async throws -> LibrarySummary {
        begin()
        defer { calls.active -= 1 }
        calls.clears += 1
        return refreshSummary
    }
}