import Foundation
import Combine
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic services and explicit async gates only: no authorization requests,
/// Photos assets, model loads, storage writes, polling or timing-based ordering.
@MainActor
final class PhotoSyncStateTests: XCTestCase {
    func testDisabledStateCannotStartEvenWithFakeReadiness() async {
        let state = PhotoSyncState()
        state.updateAvailability(ready: true, networkAllowed: true)
        state.libraryChanged()
        state.restart()
        await state.waitUntilIdle()
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.visible)
        XCTAssertFalse(state.canCancel)
        XCTAssertFalse(state.canRestart)
    }

    func testCancelBeforeServiceStartsStillSettlesOnceWithoutSuccessCallbacks() async {
        let service = SyncStateService([])
        let state = makeState(service)
        var settlements = 0
        var commits = 0
        var summaries = 0
        state.onSettled = { [weak state] in
            settlements += 1
            XCTAssertEqual(state?.phase, .cancelled)
            XCTAssertTrue(state?.canRestart ?? false)
        }
        state.onCommitted = { commits += 1 }
        state.onCompleted = { _ in summaries += 1 }
        // No suspension between scheduling and cancellation: the initial
        // cancellation check exits before the service is ever entered.
        state.updateAvailability(ready: true, networkAllowed: false)
        state.cancel()
        XCTAssertEqual(settlements, 0)
        await state.waitUntilIdle()
        state.updateAvailability(ready: true, networkAllowed: false)
        await state.waitUntilIdle()
        let calls = await service.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(settlements, 1)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(summaries, 0)
        XCTAssertNil(state.failureMessage)
    }

    func testFirstReadinessEdgeStartsOnceAndCapturesNetworkChoice() async {
        let run = SyncStateRun()
        let service = SyncStateService([run])
        let state = makeState(service)
        state.updateAvailability(ready: false, networkAllowed: true)
        state.libraryChanged()
        let before = await service.calls
        XCTAssertEqual(before, 0)
        state.updateAvailability(ready: true, networkAllowed: true)
        await run.entered.wait()
        state.updateAvailability(ready: true, networkAllowed: true)
        state.updateAvailability(ready: true, networkAllowed: true)
        XCTAssertTrue(state.canCancel)
        let flags = await service.networkFlags
        XCTAssertEqual(flags, [true])
        state.cancel()
        run.release.send()
        await state.waitUntilIdle()
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    func testUserCancelStopsDispatchDrainsKeepsPartialCountsAndRequiresExplicitFreshRestart() async {
        let partial = PhotoSyncProgress(phase: .updating, total: 8, completed: 2, encoded: 2, removed: 3)
        let first = SyncStateRun(initial: partial, commitBeforeWait: true)
        let second = SyncStateRun(initial: PhotoSyncProgress(phase: .updating, total: 5),
                                  result: syncResult(count: 7, encoded: 5))
        let service = SyncStateService([first, second])
        let state = makeState(service)
        var commits = 0
        var summaries = 0
        var settledPhases: [PhotoSyncState.Phase] = []
        state.onCommitted = { commits += 1 }
        state.onCompleted = { _ in summaries += 1 }
        state.onSettled = { [weak state] in
            guard let state else { XCTFail("State must still be owned by the test."); return }
            settledPhases.append(state.phase)
            XCTAssertFalse(state.canCancel)
            XCTAssertTrue(state.canRestart, "The old task and stopping flags are already cleared.")
        }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        state.cancel()
        await first.cancelled.wait()
        XCTAssertTrue(settledPhases.isEmpty, "Cancellation is not settlement until the service drains.")
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertTrue(state.visible)
        XCTAssertFalse(state.canCancel)
        XCTAssertFalse(state.canRestart)
        XCTAssertEqual(state.progress, partial)
        state.libraryChanged()
        state.updateAvailability(ready: false, networkAllowed: false)
        state.updateAvailability(ready: true, networkAllowed: true)
        state.restart() // Cannot jump past the still-live backend.
        let heldCalls = await service.calls
        XCTAssertEqual(heldCalls, 1)
        first.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(first.ended.count, 1)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(state.progress, partial)
        XCTAssertTrue(state.visible)
        XCTAssertTrue(state.canRestart)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(summaries, 0)
        XCTAssertEqual(settledPhases, [.cancelled])
        let dispatches = await service.dispatches
        XCTAssertEqual(dispatches, 1, "The held prediction drains, but another item is never dispatched.")

        state.updateAvailability(ready: false, networkAllowed: true)
        state.updateAvailability(ready: true, networkAllowed: true)
        state.libraryChanged()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .cancelled)
        let stillOne = await service.calls
        XCTAssertEqual(stillOne, 1)

        state.restart()
        await second.entered.wait()
        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.progress.total, 5, "Explicit restart uses a fresh diff, not the old total of eight.")
        XCTAssertEqual(state.progress.encoded, 0)
        second.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(summaries, 1)
        XCTAssertEqual(settledPhases, [.cancelled, .completed])
        let flags = await service.networkFlags
        let peak = await service.peakActive
        XCTAssertEqual(flags, [false, true])
        XCTAssertEqual(peak, 1)
    }

    func testPauseNeedsExplicitReadinessAndDoesNotSetUserSuppression() async {
        let first = SyncStateRun()
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        let state = makeState(service)
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        state.pause()
        first.release.send()
        await state.suspendAndWait()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.canRestart)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        state.updateAvailability(ready: true, networkAllowed: false)
        await second.entered.wait()
        state.cancel()
        second.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .cancelled)
    }

    func testLibraryChangesCoalesceDuringDrainAndUseLatestNetworkChoice() async {
        let first = SyncStateRun(ignoreCancellation: true)
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        let state = makeState(service)
        var accepted = 0
        var settledPhases: [PhotoSyncState.Phase] = []
        state.onCompleted = { _ in accepted += 1 }
        state.onSettled = { [weak state] in
            guard let state else { XCTFail("State must still be owned by the test."); return }
            settledPhases.append(state.phase)
            XCTAssertFalse(state.canCancel)
            XCTAssertTrue(state.canRestart, "Notify before starting the already-queued replacement.")
        }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        state.libraryChanged()
        state.libraryChanged()
        state.updateAvailability(ready: true, networkAllowed: true)
        state.libraryChanged()
        XCTAssertEqual(state.phase, .cancelling)
        first.release.send()
        await second.entered.wait()
        XCTAssertEqual(first.ended.count, 1)
        XCTAssertEqual(accepted, 0, "A cancelled backend's late successful summary is not accepted.")
        XCTAssertEqual(settledPhases, [.idle])
        second.release.send()
        await state.waitUntilIdle()
        let calls = await service.calls
        let peak = await service.peakActive
        let flags = await service.networkFlags
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(flags, [false, true])
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(settledPhases, [.idle, .completed])
    }

    func testLateProgressAndCommitFromOldGenerationCannotChangeRestartedState() async {
        let first = SyncStateRun()
        let second = SyncStateRun(initial: PhotoSyncProgress(phase: .updating, total: 4))
        let service = SyncStateService([first, second])
        let state = makeState(service)
        var commits = 0
        var settlements = 0
        state.onCommitted = { commits += 1 }
        state.onSettled = { settlements += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        state.cancel()
        first.release.send()
        await state.waitUntilIdle()
        await service.lateCallback(run: 0)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(settlements, 1)
        state.restart()
        await second.entered.wait()
        let current = state.progress
        await service.lateCallback(run: 0)
        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.progress, current)
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(settlements, 1)
        state.cancel()
        second.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(settlements, 2)
    }

    func testCommittedCallbackDuringCancellationInvalidatesSourceWithoutResumingUI() async {
        let run = SyncStateRun()
        let service = SyncStateService([run])
        let state = makeState(service)
        var commits = 0
        state.onCommitted = { commits += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await run.entered.wait()
        state.cancel()
        // Simulate a durable commit that won the race just before cancellation.
        await service.lateCallback(run: 0)
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(state.progress.encoded, 9)
        run.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(state.progress.encoded, 9)
        await service.lateCallback(run: 0)
        XCTAssertEqual(commits, 1)
    }

    func testBackendCancellationWaitsForAnotherReadinessEventInsteadOfSpinning() async {
        let first = SyncStateRun(backendCancels: true)
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        let state = makeState(service)
        var settlements = 0
        var summaries = 0
        state.onSettled = { settlements += 1 }
        state.onCompleted = { _ in summaries += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        first.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(settlements, 1)
        XCTAssertEqual(summaries, 0)
        state.updateAvailability(ready: true, networkAllowed: false)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        state.updateAvailability(ready: false, networkAllowed: false)
        state.updateAvailability(ready: true, networkAllowed: false)
        await second.entered.wait()
        state.cancel()
        second.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(settlements, 2)
        XCTAssertEqual(summaries, 0)
    }

    func testUnknownFailureIsSanitizedAndLatchedUntilManualRestart() async {
        let first = SyncStateRun(initial: PhotoSyncProgress(phase: .updating, total: 3, completed: 1, encoded: 1),
                                 failure: .sensitive)
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        let state = makeState(service)
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        first.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.progress.encoded, 1)
        XCTAssertTrue(state.visible)
        XCTAssertTrue(state.canRestart)
        XCTAssertEqual(state.failureMessage, "照片同步未完成，请手动重新同步。已完成的索引会保留。")
        state.libraryChanged()
        state.updateAvailability(ready: false, networkAllowed: false)
        state.updateAvailability(ready: true, networkAllowed: true)
        await state.waitUntilIdle()
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.phase, .failed)
        state.restart()
        await second.entered.wait()
        XCTAssertNil(state.failureMessage)
        state.cancel()
        second.release.send()
        await state.waitUntilIdle()
    }

    func testPartialResultNeedsAttentionDoesNotImmediatelyRetryOrHide() async {
        let run = SyncStateRun(result: PhotoSyncResult(summary: syncSummary(3), progress:
            PhotoSyncProgress(phase: .updating, total: 5, completed: 5, encoded: 3, failed: 1, needsNetwork: 1)))
        let service = SyncStateService([run])
        let clock = SyncStateSignal()
        let state = PhotoSyncState(service: service, completionDelay: { clock.send() })
        var settlements = 0
        var summaries = 0
        state.onSettled = { settlements += 1 }
        state.onCompleted = { _ in summaries += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await run.entered.wait()
        run.release.send()
        await state.waitUntilIdle()
        state.updateAvailability(ready: true, networkAllowed: false)
        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertTrue(state.visible)
        XCTAssertTrue(state.canRestart)
        XCTAssertNil(state.failureMessage)
        XCTAssertEqual(clock.count, 0)
        XCTAssertEqual(settlements, 1)
        XCTAssertEqual(summaries, 1, "The real partial summary is still delivered, without claiming full success.")
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    func testCompletionDwellIsIndependentOfJobAndNoChangesDoNotLoop() async {
        let run = SyncStateRun(result: syncResult(count: 0, encoded: 0))
        let service = SyncStateService([run])
        let delayEntered = SyncStateSignal()
        let releaseDelay = SyncStateSignal()
        let hidden = SyncStateSignal()
        let state = PhotoSyncState(service: service, completionDelay: {
            delayEntered.send()
            await releaseDelay.wait()
        })
        var settlements = 0
        state.onSettled = { settlements += 1 }
        let observation = state.$phase.dropFirst().sink { if $0 == .idle { hidden.send() } }
        defer { observation.cancel() }
        state.updateAvailability(ready: true, networkAllowed: false)
        await run.entered.wait()
        XCTAssertNil(state.progress.fraction, "Checking has no invented percentage.")
        run.release.send()
        await state.waitUntilIdle() // Deliberately does NOT release the display gate.
        await delayEntered.wait()
        XCTAssertEqual(state.phase, .completed)
        XCTAssertEqual(settlements, 1, "Settlement does not wait for the completion-card dwell.")
        XCTAssertEqual(state.progress.fraction, 1)
        XCTAssertTrue(state.visible)
        XCTAssertFalse(state.canCancel)
        state.updateAvailability(ready: true, networkAllowed: false)
        releaseDelay.send()
        await hidden.wait()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.visible)
        XCTAssertEqual(settlements, 1, "Hiding a completed card is not another job settlement.")
        state.updateAvailability(ready: true, networkAllowed: false)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    func testObsoleteCompletionDelayCannotHideCancelledOrNewRun() async {
        let first = SyncStateRun()
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        let entered = SyncStateSignal()
        let release = SyncStateSignal()
        let returned = SyncStateSignal()
        let state = PhotoSyncState(service: service, completionDelay: {
            entered.send()
            await release.wait() // Intentionally ignores cancellation.
            returned.send()
        })
        var idlePublications = 0
        let observation = state.$phase.dropFirst().sink { if $0 == .idle { idlePublications += 1 } }
        defer { observation.cancel() }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        first.release.send()
        await state.waitUntilIdle()
        await entered.wait()
        state.restart()
        await second.entered.wait()
        release.send()
        await returned.wait()
        state.cancel()
        second.release.send()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(state.visible)
        XCTAssertEqual(idlePublications, 0)
    }

    func testDeinitCancelsBackendAndCannotLaunchQueuedRestart() async {
        let first = SyncStateRun()
        let second = SyncStateRun()
        let service = SyncStateService([first, second])
        var state: PhotoSyncState? = makeState(service)
        weak var weakState = state
        state?.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        state?.libraryChanged()
        state = nil
        XCTAssertNil(weakState, "The task must not retain its state over an await.")
        await first.cancelled.wait()
        first.release.send()
        await first.ended.wait()
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(second.entered.count, 0)
    }

    func testInjectedForegroundWorkerNeverEnablesRealAutomaticPhotoKitByDefault() async {
        for access in [nil, IndexAccessCoordinator()] as [IndexAccessCoordinator?] {
            let front = SyncForegroundService()
            let state = AppState(worker: front, authorizationStatus: { .authorized }, indexAccess: access)
            state.start()
            await state.waitUntilIdle()
            XCTAssertFalse(state.photoSync.isEnabled)
            XCTAssertTrue(state.indexAccess === access)
            state.libraryChanged()
            await state.waitUntilIdle()
            state.enterBackground()
            state.enterForeground()
            await state.waitUntilIdle()
            await state.waitForSync()
            XCTAssertFalse(state.photoSync.visible)
            let indexes = await front.count(.index)
            let texts = await front.count(.text)
            XCTAssertEqual(indexes, 0)
            XCTAssertEqual(texts, 0)
        }
    }

    func testInitialAuthorizationGuardThenApprovedEmptyLibraryStartsAutomatically() async {
        for initial in [PHAuthorizationStatus.notDetermined, .denied, .restricted] {
            let authorization = SyncStateAuthorization(initial)
            let front = SyncForegroundService(summary: syncSummary(0))
            let run = SyncStateRun()
            let sync = SyncStateService([run])
            let state = AppState(worker: front, authorizationStatus: { authorization.value }, syncService: sync)
            state.start()
            await state.waitUntilIdle()
            XCTAssertTrue(state.modelsReady)
            XCTAssertEqual(state.summary.indexedCount, 0)
            let before = await sync.calls
            XCTAssertEqual(before, 0)
            authorization.value = .limited
            state.libraryChanged()
            await state.waitUntilIdle()
            await run.entered.wait()
            XCTAssertNotNil(state.indexAccess, "Explicit fake sync receives a coordinator without real writes.")
            state.photoSync.cancel()
            run.release.send()
            await state.waitForSync()
        }
    }

    func testModelsOrFailedLaunchCannotBeBypassedToStartSync() async {
        for throwsOnLaunch in [false, true] {
            var summary = syncSummary(0)
            if !throwsOnLaunch { summary.modelIssue = "TEST model unavailable" }
            let front = SyncForegroundService(summary: summary, failures: throwsOnLaunch ? [.launch] : [])
            let sync = SyncStateService([SyncStateRun()])
            let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
            state.start()
            await state.waitUntilIdle()
            XCTAssertEqual(state.launchPhase, .failed)
            state.openHomeAfterLaunchFailure()
            state.refresh()
            await state.waitUntilIdle()
            await state.waitForSync()
            let calls = await sync.calls
            XCTAssertEqual(calls, 0)
            XCTAssertFalse(state.photoSync.visible)
        }
    }

    func testCancellingSyncDoesNotCancelConcurrentForegroundSearch() async {
        let searchGate = SyncStateSignal()
        let front = SyncForegroundService(holds: [.search: searchGate])
        let run = SyncStateRun()
        let sync = SyncStateService([run])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        state.query = "synthetic query"
        state.search()
        await front.arrival(.search).wait()
        XCTAssertEqual(state.activity, .searching)
        XCTAssertTrue(state.photoSync.canCancel)
        state.photoSync.cancel()
        await run.cancelled.wait()
        XCTAssertEqual(state.activity, .searching)
        searchGate.send()
        await state.waitUntilIdle() // Returns while the sync backend is still held.
        XCTAssertFalse(state.results.isEmpty)
        XCTAssertEqual(state.completedQuery, "synthetic query")
        XCTAssertEqual(state.photoSync.phase, .cancelling)
        let session = state.resultSessionID
        run.release.send()
        await state.waitForSync()
        XCTAssertEqual(state.resultSessionID, session)
        XCTAssertEqual(state.photoSync.phase, .cancelled)
    }

    func testCancellingForegroundSearchDoesNotCancelSync() async {
        let gate = SyncStateSignal()
        let front = SyncForegroundService(holds: [.search: gate])
        let run = SyncStateRun()
        let sync = SyncStateService([run])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        state.query = "synthetic query"
        state.search()
        await front.arrival(.search).wait()
        state.cancel()
        gate.send()
        await state.waitUntilIdle()
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertEqual(run.cancelled.count, 0)
        XCTAssertTrue(state.photoSync.canCancel)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testSyncCommitWaitsForSearchPublicationThenMergesCountsWithoutClearingResultsOrOCR() async {
        let queued = SyncStateSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let searchGate = SyncStateSignal()
        var original = syncSummary(2)
        original.textIndexCounts = TextIndexCounts(records: 8, withText: 6, reduced: 1)
        original.textIndexStatisticsKnown = true
        original.textIndexIssue = "TEST preserved OCR notice"
        let front = SyncForegroundService(summary: original, holds: [.search: searchGate])
        let run = SyncStateRun(result: syncResult(count: 9, encoded: 7), commitAfterWait: true)
        let sync = SyncStateService([run], access: access)
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        let epoch = state.indexSourceEpoch
        let photosEpoch = state.photoLibraryEpoch
        var sourcePublications = 0
        let sourceObservation = state.$indexSourceEpoch.dropFirst().sink { _ in sourcePublications += 1 }
        defer { sourceObservation.cancel() }
        var publications = 0
        let observation = state.$results.sink { hits in
            if !hits.isEmpty {
                publications += 1
                XCTAssertFalse(access.isWriting, "The read lease includes @Published result delivery.")
                XCTAssertEqual(access.revision, 0, "The queued sync commit cannot preempt publication.")
            }
        }
        defer { observation.cancel() }
        state.query = "synthetic query"
        state.search()
        await front.arrival(.search).wait()
        run.release.send()
        await queued.wait(3) // Launch read, search read, sync write.
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(state.indexSourceEpoch, epoch)
        searchGate.send()
        await state.waitUntilIdle()
        let session = state.resultSessionID
        state.setSelectingResults(true)
        state.selectVisibleResults()
        let selection = state.selectedResultIDs
        await state.waitForSync()
        XCTAssertEqual(publications, 1)
        XCTAssertNotNil(session)
        XCTAssertEqual(state.resultSessionID, session)
        XCTAssertEqual(state.selectedResultIDs, selection)
        XCTAssertEqual(state.completedQuery, "synthetic query")
        XCTAssertNotEqual(state.indexSourceEpoch, epoch)
        XCTAssertEqual(sourcePublications, 1, "Settlement must not republish the already-notified committed revision.")
        XCTAssertEqual(state.photoLibraryEpoch, photosEpoch)
        XCTAssertEqual(state.summary.indexedCount, 9)
        XCTAssertEqual(state.summary.locatedCount, 4)
        XCTAssertEqual(state.summary.textIndexCounts, original.textIndexCounts)
        XCTAssertEqual(state.summary.textIndexStatisticsKnown, original.textIndexStatisticsKnown)
        XCTAssertEqual(state.summary.textIndexIssue, original.textIndexIssue)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(access.isWriting)
    }

    func testOnlyNewRevisionsChangeSourceEpochAndLateCancelledGenerationDoesNot() async throws {
        let access = IndexAccessCoordinator()
        let existingWrite = try await access.acquireWrite()
        existingWrite.release() // Seed a nonzero revision before constructing AppState.
        let front = SyncForegroundService()
        let run = SyncStateRun()
        let sync = SyncStateService([run], access: access)
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        var epochs: [UUID] = []
        let observation = state.$indexSourceEpoch.dropFirst().sink { epochs.append($0) }
        defer { observation.cancel() }
        let first = state.indexSourceEpoch
        await sync.lateCallback(run: 0)
        XCTAssertEqual(state.indexSourceEpoch, first, "A callback alone is not a revision change.")
        XCTAssertTrue(epochs.isEmpty)
        try await sync.commitAgain(run: 0)
        let second = state.indexSourceEpoch
        await sync.lateCallback(run: 0)
        XCTAssertEqual(state.indexSourceEpoch, second, "Duplicate notifications publish no extra epoch.")
        try await sync.commitAgain(run: 0)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(second, state.indexSourceEpoch)
        XCTAssertEqual(epochs.count, 2)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
        XCTAssertEqual(epochs.count, 2, "Settlement sees the same already-notified revision.")
        let stopped = state.indexSourceEpoch
        await sync.lateCallback(run: 0)
        XCTAssertEqual(state.indexSourceEpoch, stopped)
        XCTAssertEqual(epochs.count, 2)
    }

    func testRolledBackSyncWriterSettlesRevisionOnceWithoutSuccessOrSearchInvalidation() async {
        for cancelWriter in [false, true] {
            let access = IndexAccessCoordinator()
            let privateDescriptionReads = SyncStateSignal()
            var original = syncSummary(2)
            original.textIndexCounts = TextIndexCounts(records: 8, withText: 6, reduced: 1)
            original.textIndexStatisticsKnown = true
            let front = SyncForegroundService(summary: original)
            let run = SyncStateRun(initial: PhotoSyncProgress(phase: .updating, total: 3),
                                   failure: .observedSensitive(privateDescriptionReads), rollbackWriteAfterWait: true)
            let sync = SyncStateService([run], access: access)
            let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
            var commits = 0
            var summaries = 0
            var settlements = 0
            let committed = state.photoSync.onCommitted
            let completed = state.photoSync.onCompleted
            let settled = state.photoSync.onSettled
            state.photoSync.onCommitted = { commits += 1; committed() }
            state.photoSync.onCompleted = { summaries += 1; completed($0) }
            state.photoSync.onSettled = { [weak syncState = state.photoSync] in
                settlements += 1
                XCTAssertEqual(run.ended.count, 1, "The failed/cancelled worker has drained.")
                XCTAssertFalse(access.isWriting)
                XCTAssertFalse(syncState?.canCancel ?? true)
                XCTAssertTrue(syncState?.canRestart ?? false, "Task and stopping flags are cleared before notification.")
                settled() // Exercise the actual AppState callback, not a test replacement.
            }
            state.start()
            await state.waitUntilIdle()
            await run.entered.wait()
            state.query = "synthetic query"
            state.search()
            await state.waitUntilIdle()
            state.setSelectingResults(true)
            state.selectVisibleResults()
            let resultIDs = state.results.map(\.id)
            let session = state.resultSessionID
            let selection = state.selectedResultIDs
            let epoch = state.indexSourceEpoch
            let photosEpoch = state.photoLibraryEpoch
            XCTAssertFalse(resultIDs.isEmpty)
            XCTAssertNotNil(session)
            XCTAssertFalse(selection.isEmpty)
            var epochs: [UUID] = []
            let observation = state.$indexSourceEpoch.dropFirst().sink {
                epochs.append($0)
                XCTAssertFalse(access.isWriting, "Notify only after this rolled-back writer releases its lease.")
            }
            defer { observation.cancel() }
            run.release.send()
            await run.writerEntered.wait()
            XCTAssertTrue(access.isWriting)
            XCTAssertEqual(access.revision, 1, "A granted write invalidates authority even without a commit.")
            XCTAssertEqual(state.indexSourceEpoch, epoch)
            XCTAssertEqual(settlements, 0)
            XCTAssertEqual(commits, 0)
            XCTAssertEqual(summaries, 0)
            if cancelWriter {
                state.photoSync.cancel()
                XCTAssertEqual(state.photoSync.phase, .cancelling)
                XCTAssertFalse(state.photoSync.canRestart)
                XCTAssertEqual(settlements, 0, "Cancel must still wait for writer rollback.")
            }
            run.releaseWriter.send()
            await state.waitForSync()
            XCTAssertEqual(state.photoSync.phase, cancelWriter ? .cancelled : .failed)
            if cancelWriter { XCTAssertNil(state.photoSync.failureMessage) }
            else {
                XCTAssertEqual(state.photoSync.failureMessage, "照片同步未完成，请手动重新同步。已完成的索引会保留。")
            }
            XCTAssertEqual(privateDescriptionReads.count, 0, "Never inspect private error descriptions.")
            XCTAssertEqual(commits, 0, "Rollback must not manufacture a durable commit.")
            XCTAssertEqual(summaries, 0, "Failure/cancellation must not manufacture a successful summary.")
            XCTAssertEqual(settlements, 1)
            XCTAssertEqual(epochs.count, 1)
            XCTAssertNotEqual(state.indexSourceEpoch, epoch)
            XCTAssertEqual(epochs.last, state.indexSourceEpoch)
            XCTAssertEqual(state.photoLibraryEpoch, photosEpoch)
            XCTAssertEqual(state.resultSessionID, session)
            XCTAssertEqual(state.results.map(\.id), resultIDs)
            XCTAssertTrue(state.isSelectingResults)
            XCTAssertEqual(state.selectedResultIDs, selection)
            XCTAssertEqual(state.completedQuery, "synthetic query")
            XCTAssertEqual(state.summary.indexedCount, original.indexedCount)
            XCTAssertEqual(state.summary.indexStatisticsKnown, original.indexStatisticsKnown)
            XCTAssertEqual(state.summary.locatedCount, original.locatedCount)
            XCTAssertEqual(state.summary.textIndexCounts, original.textIndexCounts)
            XCTAssertEqual(state.summary.textIndexStatisticsKnown, original.textIndexStatisticsKnown)
            XCTAssertTrue(state.canSearch)
            XCTAssertNil(state.errorMessage)
            XCTAssertNil(state.actionHint)
            XCTAssertFalse(access.isWriting)

            await sync.lateCallback(run: 0)
            state.photoSync.updateAvailability(ready: true, networkAllowed: false)
            state.photoSync.libraryChanged()
            await state.waitForSync()
            XCTAssertEqual(commits, 0)
            XCTAssertEqual(summaries, 0)
            XCTAssertEqual(settlements, 1)
            XCTAssertEqual(epochs.count, 1)
            let calls = await sync.calls
            let events = await front.events
            XCTAssertEqual(calls, 1, "Settlement and repeated readiness never retry a failed/cancelled job.")
            XCTAssertEqual(events, [.launch, .search], "Settlement starts no foreground count refresh or search.")
        }
    }

    func testCancellingSyncQueuedCommitDoesNotWaitForOrCancelForegroundReader() async {
        let queued = SyncStateSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let searchGate = SyncStateSignal()
        let front = SyncForegroundService(holds: [.search: searchGate])
        let partial = PhotoSyncProgress(phase: .updating, total: 3, completed: 1, encoded: 1)
        let run = SyncStateRun(initial: partial, commitBeforeWait: true, commitAfterWait: true)
        let sync = SyncStateService([run], access: access)
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        let committedEpoch = state.indexSourceEpoch
        state.query = "synthetic query"
        state.search()
        await front.arrival(.search).wait()
        run.release.send()
        await queued.wait(4) // Launch, first commit, search, blocked second commit.
        state.photoSync.cancel()
        await state.waitForSync() // Must return without releasing the search gate.
        XCTAssertEqual(state.photoSync.phase, .cancelled)
        XCTAssertEqual(state.photoSync.progress, partial)
        XCTAssertEqual(state.indexSourceEpoch, committedEpoch)
        XCTAssertEqual(access.revision, 1)
        XCTAssertEqual(state.activity, .searching)
        XCTAssertEqual(run.ended.count, 1)
        searchGate.send()
        await state.waitUntilIdle()
        XCTAssertFalse(state.results.isEmpty)
    }

    func testManualIndexRebuildAndClearDrainSyncBeforeWriterAndResumeFreshDiffAfterSuccess() async {
        for operation in [SyncManualAction.index, .rebuild, .clear] {
            let access = IndexAccessCoordinator()
            let manualGate = SyncStateSignal()
            let held: SyncForegroundKind = operation == .index ? .index : .clear
            let front = SyncForegroundService(holds: [held: manualGate])
            let first = SyncStateRun(ignoreCancellation: true)
            let second = SyncStateRun()
            let sync = SyncStateService([first, second], access: access)
            let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
            state.start()
            await state.waitUntilIdle()
            await first.entered.wait()
            operation.begin(state)
            await first.cancelled.wait()
            XCTAssertEqual(front.arrival(held).count, 0)
            XCTAssertFalse(access.isWriting, "Do not acquire the manual writer before draining sync.")
            XCTAssertEqual(state.photoSync.phase, .cancelling)
            first.release.send()
            await front.arrival(held).wait()
            XCTAssertEqual(first.ended.count, 1)
            XCTAssertTrue(access.isWriting)
            XCTAssertNil(access.tryRead())
            XCTAssertFalse(state.photoSync.canRestart)
            XCTAssertEqual(second.entered.count, 0)
            manualGate.send()
            await state.waitUntilIdle()
            await second.entered.wait()
            XCTAssertFalse(access.isWriting)
            let events = await front.events
            let expected: [SyncForegroundKind] = operation == .rebuild ? [.launch, .clear, .index] : [.launch, held]
            XCTAssertEqual(events, expected)
            let peak = await sync.peakActive
            XCTAssertEqual(peak, 1)
            state.photoSync.cancel()
            second.release.send()
            await state.waitForSync()
        }
    }

    func testManualFailureDoesNotAutomaticallyRetryThroughSync() async {
        let front = SyncForegroundService(failures: [.index])
        let first = SyncStateRun()
        let second = SyncStateRun()
        let sync = SyncStateService([first, second])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await first.entered.wait()
        state.index()
        first.release.send()
        await state.waitUntilIdle()
        await state.waitForSync()
        let calls = await sync.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(state.photoSync.phase, .needsAttention)
        XCTAssertTrue(state.photoSync.canRestart, "No additional manual refresh/recovery barrier.")
        state.photoSync.restart()
        await second.entered.wait()
        state.photoSync.cancel()
        second.release.send()
        await state.waitForSync()
    }

    func testUserCancelPersistsAcrossAppForegroundRefreshAndManualIndex() async {
        let front = SyncForegroundService()
        let first = SyncStateRun()
        let second = SyncStateRun()
        let sync = SyncStateService([first, second])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await first.entered.wait()
        state.photoSync.cancel()
        state.enterBackground()
        state.enterForeground()
        await state.waitUntilIdle()
        XCTAssertEqual(state.photoSync.phase, .cancelling)
        XCTAssertFalse(state.photoSync.canRestart)
        first.release.send()
        await state.waitForSync()
        XCTAssertEqual(state.photoSync.phase, .cancelled)
        state.index()
        await state.waitUntilIdle()
        await state.waitForSync()
        XCTAssertEqual(state.photoSync.phase, .cancelled)
        let calls = await sync.calls
        XCTAssertEqual(calls, 1)
        state.photoSync.restart()
        await second.entered.wait()
        state.photoSync.cancel()
        second.release.send()
        await state.waitForSync()
    }

    func testBackgroundPauseRefreshReadinessQueuesOnlyOneRestartAfterDrain() async {
        let refreshGate = SyncStateSignal()
        let front = SyncForegroundService(holds: [.refresh: refreshGate])
        let first = SyncStateRun()
        let second = SyncStateRun()
        let sync = SyncStateService([first, second])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await first.entered.wait()
        state.enterBackground()
        state.enterForeground()
        state.enterForeground()
        await front.arrival(.refresh).wait()
        first.release.send()
        await state.waitForSync()
        XCTAssertEqual(second.entered.count, 0, "Not ready until the foreground refresh succeeds.")
        refreshGate.send()
        await state.waitUntilIdle()
        await second.entered.wait()
        let peak = await sync.peakActive
        XCTAssertEqual(peak, 1)
        state.photoSync.cancel()
        second.release.send()
        await state.waitForSync()
    }

    func testForegroundReadOperationsWaitForWriterAndHoldLeaseThroughPublication() async throws {
        for kind in [SyncForegroundKind.launch, .refresh, .search, .text, .check] {
            let queued = SyncStateSignal()
            let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
            let gate = SyncStateSignal()
            let front = SyncForegroundService(holds: [kind: gate])
            let state = AppState(worker: front, authorizationStatus: { .authorized }, indexAccess: access)
            if kind != .launch {
                state.start()
                await state.waitUntilIdle()
            }
            let before = queued.count
            let initialWriter = try await access.acquireWrite()
            switch kind {
            case .launch: state.start()
            case .refresh: state.refresh()
            case .search: state.query = "synthetic query"; state.search()
            case .text: state.textSearchEnabled = true; state.indexPhotoText()
            case .check: state.debugToolsEnabled = true; state.checkPhoto(id: "synthetic", query: "synthetic query")
            default: XCTFail("Unexpected read fixture")
            }
            await queued.wait(before + 2)
            XCTAssertEqual(front.arrival(kind).count, 0)
            initialWriter.release()
            await front.arrival(kind).wait()
            let nextWriter = Task { try await access.acquireWrite() }
            await queued.wait(before + 3)
            var idlePublications = 0
            let observation = state.$activity.dropFirst().sink { activity in
                if activity == nil {
                    idlePublications += 1
                    XCTAssertFalse(access.isWriting, "Lease remains held through success/catch publication.")
                    XCTAssertEqual(access.revision, 1)
                }
            }
            gate.send()
            await state.waitUntilIdle()
            let writer = try await nextWriter.value
            XCTAssertEqual(idlePublications, 1)
            XCTAssertTrue(access.isWriting)
            writer.release()
            observation.cancel()
            XCTAssertFalse(access.isWriting)
        }
    }

    func testOCRCanComputeAlongsideSyncButSyncCommitWaitsForOCRReadLease() async {
        let queued = SyncStateSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let textGate = SyncStateSignal()
        let front = SyncForegroundService(holds: [.text: textGate])
        let run = SyncStateRun(result: syncResult(count: 9), commitAfterWait: true)
        let sync = SyncStateService([run], access: access)
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        state.textSearchEnabled = true
        state.indexPhotoText()
        await front.arrival(.text).wait()
        XCTAssertTrue(state.photoSync.canCancel)
        run.release.send()
        await queued.wait(3)
        XCTAssertEqual(run.cancelled.count, 0)
        XCTAssertFalse(access.isWriting)
        textGate.send()
        await state.waitUntilIdle()
        await state.waitForSync()
        XCTAssertEqual(state.summary.indexedCount, 9)
        XCTAssertEqual(state.summary.textIndexCounts.records, 12)
        XCTAssertTrue(state.summary.textIndexStatisticsKnown)
    }

    func testCancellingQueuedManualWriterDoesNotRunWorkerOrLeakLease() async throws {
        let queued = SyncStateSignal()
        let access = IndexAccessCoordinator(didEnqueue: { queued.send() })
        let front = SyncForegroundService()
        let state = AppState(worker: front, authorizationStatus: { .authorized }, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        let reader = try await access.acquireRead()
        state.index()
        await queued.wait(3)
        XCTAssertEqual(front.arrival(.index).count, 0)
        state.cancel()
        await state.waitUntilIdle()
        XCTAssertEqual(front.arrival(.index).count, 0)
        XCTAssertEqual(access.revision, 0)
        reader.release()
        let writer = try await access.acquireWrite()
        XCTAssertEqual(access.revision, 1)
        writer.release()
    }

    private func makeState(_ service: SyncStateService) -> PhotoSyncState {
        // Leave completion visible without introducing a test timer or live task.
        PhotoSyncState(service: service, completionDelay: { throw CancellationError() })
    }

    func testFirstCommittedStoredCountEnablesSearchBeforeInitialSyncFinishes() async throws {
        var initial = syncSummary(0)
        initial.textIndexCounts = TextIndexCounts(records: 8, withText: 6, reduced: 1)
        initial.textIndexStatisticsKnown = true
        initial.textIndexIssue = "TEST preserved OCR notice"
        let front = SyncForegroundService(summary: initial)
        let run = SyncStateRun()
        var stored = syncSummary(1)
        stored.authorizedCountKnown = false
        let read = SyncSummaryRead(summary: stored)
        let access = IndexAccessCoordinator()
        let sync = SyncStateService([run], access: access, summaryReads: [read])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.query = "synthetic query"
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        XCTAssertFalse(state.canSearch)
        XCTAssertEqual(state.summary.indexedCount, 0)
        let status = state.status
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 1)
        XCTAssertTrue(state.summary.indexStatisticsKnown)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertEqual(state.photoSync.progress.encoded, 0, "Stored counts are not derived from progress.")
        XCTAssertTrue(state.canSearch)
        XCTAssertTrue(state.photoSync.canCancel, "The whole sync is still held.")
        XCTAssertEqual(run.ended.count, 0)
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.status, status)
        XCTAssertEqual(state.summary.textIndexCounts, initial.textIndexCounts)
        XCTAssertEqual(state.summary.textIndexStatisticsKnown, initial.textIndexStatisticsKnown)
        XCTAssertEqual(state.summary.textIndexIssue, initial.textIndexIssue)
        let events = await front.events
        let calls = await sync.calls
        XCTAssertEqual(events, [.launch], "No foreground refresh, OCR or manual index.")
        XCTAssertEqual(calls, 1, "Metadata publication does not schedule a full sync.")
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testCancellationWinningAfterCommitStillPublishesIndependentPartialSummary() async throws {
        let front = SyncForegroundService(summary: syncSummary(0))
        let run = SyncStateRun()
        let read = SyncSummaryRead(summary: syncSummary(1))
        let sync = SyncStateService([run], summaryReads: [read])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        var completed = 0
        let callback = state.photoSync.onCompleted
        state.photoSync.onCompleted = { completed += 1; callback($0) }
        state.query = "synthetic query"
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        state.photoSync.cancel()
        // A commit that won cancellation can still arrive while the job drains.
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        run.release.send()
        await state.waitForSync()
        XCTAssertEqual(state.photoSync.phase, .cancelled)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertEqual(read.cancelled.count, 0, "User sync cancellation must not cancel this read.")
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 1)
        XCTAssertTrue(state.canSearch)
        XCTAssertEqual(state.photoSync.phase, .cancelled)
        XCTAssertEqual(completed, 0, "Partial metadata is not whole-sync completion.")
        let calls = await sync.calls
        XCTAssertEqual(calls, 1)
    }

    func testCommitMetadataPreservesCompletedSearchSessionSelectionAndOCR() async throws {
        var original = syncSummary(2)
        original.textIndexCounts = TextIndexCounts(records: 12, withText: 9, reduced: 1)
        original.textIndexStatisticsKnown = true
        let front = SyncForegroundService(summary: original)
        let run = SyncStateRun()
        let read = SyncSummaryRead(summary: syncSummary(7))
        let access = IndexAccessCoordinator()
        let sync = SyncStateService([run], access: access, summaryReads: [read])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        state.query = "synthetic query"
        state.search()
        await state.waitUntilIdle()
        state.setSelectingResults(true)
        state.selectVisibleResults()
        let session = state.resultSessionID
        let selected = state.selectedResultIDs
        let ids = state.results.map(\.id)
        let photosEpoch = state.photoLibraryEpoch
        let status = state.status
        var publications = 0
        let observation = state.$summary.dropFirst().sink { value in
            if value.indexedCount == 7 {
                publications += 1
                XCTAssertFalse(access.isWriting)
                XCTAssertEqual(access.revision, 1)
            }
        }
        defer { observation.cancel() }
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(state.summary.indexedCount, 7)
        XCTAssertNotNil(session)
        XCTAssertEqual(state.resultSessionID, session)
        XCTAssertEqual(state.selectedResultIDs, selected)
        XCTAssertEqual(state.results.map(\.id), ids)
        XCTAssertEqual(state.completedQuery, "synthetic query")
        XCTAssertEqual(state.photoLibraryEpoch, photosEpoch)
        XCTAssertEqual(state.status, status)
        XCTAssertEqual(state.summary.textIndexCounts, original.textIndexCounts)
        XCTAssertTrue(state.summary.textIndexStatisticsKnown)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testMetadataReadDoesNotCancelAnActiveForegroundSearch() async throws {
        let search = SyncStateSignal()
        let front = SyncForegroundService(holds: [.search: search])
        let run = SyncStateRun()
        let read = SyncSummaryRead(summary: syncSummary(7))
        let sync = SyncStateService([run], summaryReads: [read])
        let state = AppState(worker: front, authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        state.query = "synthetic query"
        state.search()
        await front.arrival(.search).wait()
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 7)
        XCTAssertEqual(state.activity, .searching)
        XCTAssertEqual(run.cancelled.count, 0)
        search.send()
        await state.waitUntilIdle()
        XCTAssertNotNil(state.resultSessionID)
        XCTAssertFalse(state.results.isEmpty)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testCommitBurstCoalescesToOneTailReadAndNeverPublishesObsoleteSnapshot() async throws {
        let run = SyncStateRun()
        let first = SyncSummaryRead(summary: syncSummary(1))
        let last = SyncSummaryRead(summary: syncSummary(5))
        let sync = SyncStateService([run], summaryReads: [first, last])
        let state = AppState(worker: SyncForegroundService(summary: syncSummary(0)),
                             authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await first.entered.wait()
        for _ in 0..<10 { await sync.lateCallback(run: 0) }
        let held = await sync.summaryCalls
        XCTAssertEqual(held, 1)
        first.release.send()
        await last.entered.wait()
        XCTAssertEqual(state.summary.indexedCount, 0, "A superseded snapshot never flashes on screen.")
        last.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 5)
        XCTAssertEqual(state.photoSync.progress.encoded, 9, "Do not infer nine from callback progress.")
        let calls = await sync.summaryCalls
        let peak = await sync.peakSummaryReads
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(peak, 1)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testRevisionChangeAfterMetadataReadRejectsSnapshotAndReadsFreshTail() async throws {
        let access = IndexAccessCoordinator()
        let run = SyncStateRun()
        let first = SyncSummaryRead(summary: syncSummary(1), releaseReadBeforeWait: true)
        let last = SyncSummaryRead(summary: syncSummary(3))
        let sync = SyncStateService([run], access: access, summaryReads: [first, last])
        let state = AppState(worker: SyncForegroundService(summary: syncSummary(0)),
                             authorizationStatus: { .authorized }, syncService: sync, indexAccess: access)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await first.entered.wait()
        // A different writer changed the source, without a sync commit callback.
        let writer = try await access.acquireWrite()
        writer.release()
        first.release.send()
        await last.entered.wait()
        XCTAssertEqual(state.summary.indexedCount, 0)
        let observation = state.$summary.dropFirst().sink { value in
            if value.indexedCount == 3 {
                XCTAssertFalse(access.isWriting)
                XCTAssertEqual(access.revision, 2)
            }
        }
        last.release.send()
        await state.waitForSyncSummary()
        observation.cancel()
        XCTAssertEqual(state.summary.indexedCount, 3)
        state.photoSync.cancel()
        run.release.send()
        await state.waitForSync()
    }

    func testBackgroundCancelsMetadataAndLateReturnCannotPublishAfterForegroundRefresh() async throws {
        let run = SyncStateRun()
        let read = SyncSummaryRead(summary: syncSummary(9), ignoreCancellation: true)
        let sync = SyncStateService([run], summaryReads: [read])
        let state = AppState(worker: SyncForegroundService(summary: syncSummary(2)),
                             authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        state.photoSync.cancel() // Do not restart the synthetic full sync on foreground.
        state.enterBackground()
        await read.cancelled.wait()
        run.release.send()
        await state.waitForSync()
        XCTAssertEqual(state.summary.indexedCount, 2)
        state.enterForeground()
        await state.waitUntilIdle()
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 2)
        let calls = await sync.calls
        XCTAssertEqual(calls, 1)
    }

    func testChangedPermissionAtMetadataPublicationDoesNotPublishCounts() async throws {
        for changed in [PHAuthorizationStatus.denied, .limited] {
            let authorization = SyncStateAuthorization(.authorized)
            let run = SyncStateRun()
            let read = SyncSummaryRead(summary: syncSummary(9))
            let sync = SyncStateService([run], summaryReads: [read])
            let state = AppState(worker: SyncForegroundService(), authorizationStatus: { authorization.value }, syncService: sync)
            state.start()
            await state.waitUntilIdle()
            await run.entered.wait()
            try await sync.commitAgain(run: 0)
            await read.entered.wait()
            authorization.value = changed
            read.release.send()
            await state.waitForSyncSummary()
            XCTAssertEqual(state.summary.indexedCount, 2)
            XCTAssertEqual(state.authorization, changed)
            XCTAssertEqual(state.canRead, changed == .limited)
            state.photoSync.cancel()
            run.release.send()
            await state.waitForSync()
        }
    }

    func testNewSyncCommitWaitsForCancelledMetadataTailAndRejectsOldGeneration() async throws {
        let firstRun = SyncStateRun()
        let secondRun = SyncStateRun()
        let firstRead = SyncSummaryRead(summary: syncSummary(9), ignoreCancellation: true)
        let secondRead = SyncSummaryRead(summary: syncSummary(3))
        let sync = SyncStateService([firstRun, secondRun], summaryReads: [firstRead, secondRead])
        let state = AppState(worker: SyncForegroundService(summary: syncSummary(0)),
                             authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await firstRun.entered.wait()
        try await sync.commitAgain(run: 0)
        await firstRead.entered.wait()
        state.enterBackground()
        await firstRead.cancelled.wait()
        firstRun.release.send()
        await state.waitForSync()
        state.enterForeground()
        await state.waitUntilIdle()
        await secondRun.entered.wait()
        try await sync.commitAgain(run: 1)
        XCTAssertEqual(secondRead.entered.count, 0, "A cancelled but undrained metadata call still owns the tail.")
        firstRead.release.send()
        await secondRead.entered.wait()
        XCTAssertEqual(state.summary.indexedCount, 0, "Old scope's nine must not publish in the new foreground generation.")
        secondRead.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 3)
        let peak = await sync.peakSummaryReads
        XCTAssertEqual(peak, 1)
        state.photoSync.cancel()
        secondRun.release.send()
        await state.waitForSync()
    }

    func testMetadataFailureNilUnknownCountsAndWrongModelNeverInventKnownZero() async throws {
        let descriptions = SyncStateSignal()
        var unknown = syncSummary(0)
        unknown.indexStatisticsKnown = false
        var wrongModel = syncSummary(0)
        wrongModel.modelVersion = "other-model"
        var failedModel = syncSummary(0)
        failedModel.modelIssue = "TEST not ready"
        for read in [SyncSummaryRead(summary: nil),
                     SyncSummaryRead(summary: syncSummary(0), failure: .observedSensitive(descriptions)),
                     SyncSummaryRead(summary: unknown), SyncSummaryRead(summary: wrongModel),
                     SyncSummaryRead(summary: failedModel)] {
            let run = SyncStateRun()
            let sync = SyncStateService([run], summaryReads: [read])
            let state = AppState(worker: SyncForegroundService(), authorizationStatus: { .authorized }, syncService: sync)
            state.query = "synthetic query"
            state.start()
            await state.waitUntilIdle()
            await run.entered.wait()
            try await sync.commitAgain(run: 0)
            await read.entered.wait()
            read.release.send()
            await state.waitForSyncSummary()
            XCTAssertEqual(state.summary.indexedCount, 2)
            XCTAssertTrue(state.summary.indexStatisticsKnown)
            XCTAssertTrue(state.canSearch)
            XCTAssertNil(state.errorMessage)
            XCTAssertNil(state.actionHint)
            let calls = await sync.summaryCalls
            XCTAssertEqual(calls, 1, "No automatic failure retry.")
            state.photoSync.cancel()
            run.release.send()
            await state.waitForSync()
        }
        XCTAssertEqual(descriptions.count, 0)
    }

    func testFinalSyncSummarySupersedesPendingMetadataWithoutDuplicateFinalRead() async throws {
        let run = SyncStateRun(result: syncResult(count: 6))
        let read = SyncSummaryRead(summary: syncSummary(1), ignoreCancellation: true)
        let sync = SyncStateService([run], summaryReads: [read])
        let state = AppState(worker: SyncForegroundService(summary: syncSummary(0)),
                             authorizationStatus: { .authorized }, syncService: sync)
        state.start()
        await state.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        run.release.send()
        await state.waitForSync()
        await read.cancelled.wait()
        XCTAssertEqual(state.summary.indexedCount, 6)
        read.release.send()
        await state.waitForSyncSummary()
        XCTAssertEqual(state.summary.indexedCount, 6)
        let calls = await sync.summaryCalls
        XCTAssertEqual(calls, 1)
    }

    func testDeinitCancelsIndependentMetadataWithoutRetainingAppState() async throws {
        let run = SyncStateRun()
        let read = SyncSummaryRead(summary: syncSummary(1), ignoreCancellation: true)
        let sync = SyncStateService([run], summaryReads: [read])
        var state: AppState? = AppState(worker: SyncForegroundService(), authorizationStatus: { .authorized }, syncService: sync)
        weak var weakState = state
        state?.start()
        await state?.waitUntilIdle()
        await run.entered.wait()
        try await sync.commitAgain(run: 0)
        await read.entered.wait()
        state = nil
        XCTAssertNil(weakState)
        await read.cancelled.wait()
        await run.cancelled.wait()
        read.release.send()
        run.release.send()
        await read.ended.wait()
        await run.ended.wait()
    }
}

@MainActor
private final class SyncStateAuthorization {
    var value: PHAuthorizationStatus
    init(_ value: PHAuthorizationStatus) { self.value = value }
}

@MainActor
private enum SyncManualAction: Equatable {
    case index, rebuild, clear
    func begin(_ state: AppState) {
        switch self {
        case .index: state.index()
        case .rebuild: state.rebuildIndex()
        case .clear: state.clearIndex()
        }
    }
}

private func syncSummary(_ count: Int) -> LibrarySummary {
    LibrarySummary(authorizedCount: count, authorizedCountKnown: true, indexedCount: count,
                   locatedCount: count / 2, modelVersion: "test-model", placesDescription: "TEST places")
}

private func syncResult(count: Int = 4, encoded: Int = 1) -> PhotoSyncResult {
    PhotoSyncResult(summary: syncSummary(count), progress:
        PhotoSyncProgress(phase: .updating, total: encoded, completed: encoded, encoded: encoded))
}

private enum SyncStateFault: Error, LocalizedError {
    case sensitive
    case observedSensitive(SyncStateSignal)
    var errorDescription: String? {
        if case .observedSensitive(let reads) = self { reads.send() }
        return "PRIVATE photo-id /private/database/path raw OCR text"
    }
}

private struct SyncStateRun: Sendable {
    let entered = SyncStateSignal()
    let release = SyncStateSignal()
    let cancelled = SyncStateSignal()
    let ended = SyncStateSignal()
    let writerEntered = SyncStateSignal()
    let releaseWriter = SyncStateSignal()
    var initial = PhotoSyncProgress()
    var result = syncResult()
    var failure: SyncStateFault? = nil
    var backendCancels = false
    var ignoreCancellation = false
    var commitBeforeWait = false
    var commitAfterWait = false
    var rollbackWriteAfterWait = false
}

private struct SyncSummaryRead: Sendable {
    let entered = SyncStateSignal()
    let release = SyncStateSignal()
    let cancelled = SyncStateSignal()
    let ended = SyncStateSignal()
    var summary: LibrarySummary?
    var failure: SyncStateFault? = nil
    var ignoreCancellation = false
    /// Model the worker-to-MainActor hop after the SQL read lease has ended.
    var releaseReadBeforeWait = false
}

private actor SyncStateService: PhotoSyncServicing {
    private struct Callbacks: Sendable {
        let progress: @Sendable (PhotoSyncProgress) async -> Void
        let committed: @Sendable () async -> Void
    }
    private let runs: [SyncStateRun]
    private let access: IndexAccessCoordinator?
    private let summaryReads: [SyncSummaryRead]
    private var activeSummaryReads = 0
    private(set) var summaryCalls = 0
    private(set) var peakSummaryReads = 0
    private var callbacks: [Callbacks] = []
    private var active = 0
    private(set) var calls = 0
    private(set) var peakActive = 0
    private(set) var dispatches = 0
    private(set) var networkFlags: [Bool] = []

    init(_ runs: [SyncStateRun], access: IndexAccessCoordinator? = nil, summaryReads: [SyncSummaryRead] = []) {
        self.runs = runs
        self.access = access
        self.summaryReads = summaryReads
    }

    func currentSummary() async throws -> LibrarySummary? {
        let index = summaryCalls
        summaryCalls += 1
        guard index < summaryReads.count else { return nil }
        let read = summaryReads[index]
        activeSummaryReads += 1
        peakSummaryReads = max(peakSummaryReads, activeSummaryReads)
        var lease: IndexAccessCoordinator.Lease?
        defer { lease?.release(); activeSummaryReads -= 1; read.ended.send() }
        lease = try await access?.acquireRead()
        if read.releaseReadBeforeWait { lease?.release(); lease = nil }
        await withTaskCancellationHandler {
            read.entered.send()
            await read.release.wait()
        } onCancel: { read.cancelled.send() }
        if !read.ignoreCancellation { try Task.checkCancellation() }
        if let failure = read.failure { throw failure }
        return read.summary
    }

    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        let index = calls
        calls += 1
        guard index < runs.count else { throw SyncStateFault.sensitive }
        let run = runs[index]
        callbacks.append(Callbacks(progress: progress, committed: committed))
        active += 1
        peakActive = max(peakActive, active)
        defer { active -= 1; run.ended.send() }
        networkFlags.append(networkAllowed)
        dispatches += 1
        if run.commitBeforeWait { try await commit(committed) }
        await progress(run.initial)
        await withTaskCancellationHandler {
            run.entered.send()
            await run.release.wait()
        } onCancel: {
            run.cancelled.send()
        }
        if !run.ignoreCancellation { try Task.checkCancellation() }
        if run.rollbackWriteAfterWait {
            guard let access else { throw SyncStateFault.sensitive }
            let lease = try await access.acquireWrite()
            defer { lease.release() }
            // Model a granted writer whose transaction rolls back. Only the
            // coordinator revision changes; no database or Photos write occurs.
            run.writerEntered.send()
            await run.releaseWriter.wait()
            try Task.checkCancellation()
            throw run.failure ?? SyncStateFault.sensitive
        }
        if run.backendCancels { throw CancellationError() }
        if let failure = run.failure { throw failure }
        dispatches += 1
        if run.commitAfterWait { try await commit(committed) }
        await progress(run.result.progress)
        return run.result
    }

    private func commit(_ callback: @Sendable () async -> Void) async throws {
        let lease = try await access?.acquireWrite()
        // No actual database/Photos mutation; exercise the real coordinator.
        lease?.release()
        await callback()
    }

    func commitAgain(run: Int) async throws {
        try await commit(callbacks[run].committed)
    }

    func lateCallback(run: Int) async {
        let callback = callbacks[run]
        await callback.committed()
        await callback.progress(PhotoSyncProgress(phase: .updating, total: 99, completed: 9, encoded: 9))
    }
}

private enum SyncForegroundKind: CaseIterable, Hashable, Sendable {
    case launch, refresh, search, index, clear, text, check
}

private actor SyncForegroundService: PhotoWorkServicing {
    private let storedSummary: LibrarySummary
    private let holds: [SyncForegroundKind: SyncStateSignal]
    private let failures: Set<SyncForegroundKind>
    private nonisolated let arrivals: [SyncForegroundKind: SyncStateSignal]
    private(set) var events: [SyncForegroundKind] = []

    init(summary: LibrarySummary = syncSummary(2), holds: [SyncForegroundKind: SyncStateSignal] = [:],
         failures: Set<SyncForegroundKind> = []) {
        storedSummary = summary
        self.holds = holds
        self.failures = failures
        arrivals = Dictionary(uniqueKeysWithValues: SyncForegroundKind.allCases.map { ($0, SyncStateSignal()) })
    }

    nonisolated func arrival(_ kind: SyncForegroundKind) -> SyncStateSignal { arrivals[kind]! }
    func count(_ kind: SyncForegroundKind) -> Int { events.filter { $0 == kind }.count }

    private func perform(_ kind: SyncForegroundKind) async throws {
        events.append(kind)
        arrivals[kind]!.send()
        if let gate = holds[kind] { await gate.wait() }
        try Task.checkCancellation()
        if failures.contains(kind) { throw SyncStateFault.sensitive }
    }

    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        try await perform(.launch)
        return storedSummary
    }

    func refresh() async throws -> LibrarySummary {
        try await perform(.refresh)
        return storedSummary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        try await perform(.search)
        let hits = try VectorSearch.search(query: TestFixtures.vector(), photos: [TestFixtures.photo().photo],
                                           limit: limit, locationWeight: locationWeight)
        return SearchResponse(summary: storedSummary, hits: hits)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        try await perform(.index)
        await progress(IndexProgress(total: 7, completed: 7, encoded: 7))
        return syncSummary(7)
    }

    func clear() async throws -> LibrarySummary {
        try await perform(.clear)
        return syncSummary(0)
    }

    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        try await perform(.text)
        var summary = storedSummary
        summary.textIndexCounts = TextIndexCounts(records: 12, withText: 9, reduced: 1)
        summary.textIndexStatisticsKnown = true
        return summary
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        try await perform(.check)
        throw SyncStateFault.sensitive // Exercise read-lease release through catch.
    }
}

/// Signals can precede waits. Continuations resume outside the lock, and tests
/// observe exact enqueue/entry/return milestones rather than scheduler delays.
private final class SyncStateSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func send() {
        lock.lock()
        value += 1
        let ready = waiters.filter { $0.0 <= value }
        waiters.removeAll { $0.0 <= value }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }
    func wait(_ target: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if value >= target { lock.unlock(); continuation.resume() }
            else { waiters.append((target, continuation)); lock.unlock() }
        }
    }
}