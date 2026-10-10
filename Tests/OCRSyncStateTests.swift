import XCTest
@testable import LocalImageIQ

/// Pure event state, no clocks, worker, Photos, storage, models or network.
@MainActor
final class OCRSyncStateTests: XCTestCase {
    func testSavedOnAndRepeatedReadyNeverCreateIntent() {
        let state = OCRSyncState(enabled: true)
        for _ in 0..<3 {
            state.updateAvailability(ready: true)
            state.userChangedEnabled(true)
            XCTAssertNil(state.takeReadyRequest())
        }
        XCTAssertFalse(state.canShow)
        XCTAssertFalse(state.currentRunning)
    }

    func testOnAdmitsOnceAndDuplicateTrueCoalesces() throws {
        let state = OCRSyncState()
        state.updateAvailability(ready: true)
        state.userChangedEnabled(true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        XCTAssertEqual(state.phase, .checking)
        XCTAssertTrue(state.currentRunning)
        XCTAssertNil(state.fraction)
        state.userChangedEnabled(true)
        state.requestUpdate()
        XCTAssertNil(state.takeReadyRequest())
        state.finish(token: run, completion: .completed)
        XCTAssertEqual(state.phase, .completed)
        XCTAssertNil(state.takeReadyRequest())
    }

    func testBusyDefersOneThenSettlementAdmitsOnce() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        for _ in 0..<3 {
            state.updateAvailability(ready: false)
            state.userChangedEnabled(true)
            XCTAssertNil(state.takeReadyRequest())
        }
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.canCancel)
        XCTAssertFalse(state.currentRunning)
        state.updateAvailability(ready: true)
        XCTAssertNotNil(state.takeReadyRequest())
        XCTAssertNil(state.takeReadyRequest())
    }

    func testOffCancelsPendingWithoutStartingLater() {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.userChangedEnabled(false)
        XCTAssertEqual(state.phase, .cancelled)
        state.updateAvailability(ready: true)
        XCTAssertNil(state.takeReadyRequest())
        XCTAssertFalse(state.canRetry)
    }

    func testOffDuringRunWaitsForDrainAndRetainsWonCommitCounters() throws {
        let state = OCRSyncState()
        state.updateAvailability(ready: true)
        state.userChangedEnabled(true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.userChangedEnabled(false)
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertTrue(state.currentRunning)
        XCTAssertFalse(state.canCancel)
        XCTAssertFalse(state.canRetry)
        let committed = TextIndexProgress(total: 9, completed: 3, recognized: 2, reused: 1)
        state.accept(committed, token: run)
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertEqual(state.progress, committed)
        XCTAssertNil(state.fraction)
        state.finish(token: run, completion: .completed)
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertFalse(state.currentRunning)
        XCTAssertEqual(state.progress, committed)
    }

    func testOffOnDuringDrainQueuesExactlyOneNewRun() throws {
        let state = OCRSyncState()
        state.updateAvailability(ready: true)
        state.userChangedEnabled(true)
        let old = try XCTUnwrap(state.takeReadyRequest())
        state.userChangedEnabled(false)
        state.userChangedEnabled(true)
        state.userChangedEnabled(true)
        XCTAssertTrue(state.pending)
        XCTAssertNil(state.takeReadyRequest())
        state.finish(token: old, completion: .cancelled)
        XCTAssertEqual(state.phase, .waiting)
        let new = try XCTUnwrap(state.takeReadyRequest())
        XCTAssertNotEqual(new, old)
        state.finish(token: old, completion: .failed)
        state.accept(.init(total: 100, completed: 99), token: old)
        XCTAssertEqual(state.phase, .checking)
        XCTAssertFalse(state.totalKnown)
        XCTAssertEqual(state.progress, TextIndexProgress())
        XCTAssertNil(state.takeReadyRequest())
    }

    func testPendingIntentSurvivesBackgroundButRunningJobNeverResumes() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.pause()
        XCTAssertTrue(state.pending)
        XCTAssertNil(state.takeReadyRequest())
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.pause()
        state.updateAvailability(ready: true)
        XCTAssertNil(state.takeReadyRequest())
        state.finish(token: run, completion: .cancelled)
        XCTAssertNil(state.takeReadyRequest())
        XCTAssertEqual(state.phase, .cancelled)
    }

    func testFailedCancelledAndCompletedNeverRetryOnReadinessOrDuplicateTrue() throws {
        for completion in [OCRSyncState.Completion.failed, .cancelled, .completed] {
            let state = OCRSyncState()
            state.updateAvailability(ready: true)
            state.userChangedEnabled(true)
            let run = try XCTUnwrap(state.takeReadyRequest())
            state.finish(token: run, completion: completion)
            for ready in [false, true, true] {
                state.updateAvailability(ready: ready)
                state.userChangedEnabled(true)
                XCTAssertNil(state.takeReadyRequest())
            }
            XCTAssertTrue(state.canRetry)
            state.requestUpdate() // Explicit retry only.
            XCTAssertNotNil(state.takeReadyRequest())
            XCTAssertNil(state.takeReadyRequest())
        }
    }

    func testProgressOnlyHasRatioAfterActualNonzeroTotal() throws {
        let state = OCRSyncState()
        state.updateAvailability(ready: true)
        state.userChangedEnabled(true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        XCTAssertNil(state.fraction)
        state.accept(.init(), token: run)
        XCTAssertTrue(state.totalKnown)
        XCTAssertNil(state.fraction)
        state.accept(.init(total: 8, completed: 3, recognized: 1, reused: 2), token: run)
        XCTAssertEqual(state.fraction, 0.375)
        state.finish(token: run, completion: .completed)
        XCTAssertNil(state.fraction)
    }

    func testSkippedOrFailedPhotosAreNotDisplayedAsCompleteSuccess() throws {
        for progress in [TextIndexProgress(total: 2, completed: 2, cloudSkipped: 1),
                         TextIndexProgress(total: 2, completed: 2, failed: 1),
                         TextIndexProgress(total: 2, completed: 2, staleSkipped: 1)] {
            let state = OCRSyncState()
            state.updateAvailability(ready: true)
            state.userChangedEnabled(true)
            let run = try XCTUnwrap(state.takeReadyRequest())
            state.accept(progress, token: run)
            state.finish(token: run, completion: .completed)
            XCTAssertEqual(state.phase, .failed)
            XCTAssertEqual(state.progress, progress)
            XCTAssertNil(state.takeReadyRequest())
        }
    }

    func testDismissIsPresentationOnlyAndCannotHideLiveJob() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.dismiss()
        XCTAssertEqual(state.phase, .waiting)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.dismiss()
        XCTAssertTrue(state.currentRunning)
        state.finish(token: run, completion: .completed)
        state.dismiss()
        XCTAssertFalse(state.canShow)
        XCTAssertTrue(state.enabled)
        XCTAssertNil(state.takeReadyRequest())
    }

    func testSupersessionDoesNotLoseNewIntentButStaleCallbacksCannotPublish() throws {
        let state = OCRSyncState()
        state.updateAvailability(ready: true)
        state.userChangedEnabled(true)
        let old = try XCTUnwrap(state.takeReadyRequest())
        state.userChangedEnabled(false)
        state.userChangedEnabled(true)
        state.stopRunning()
        state.finish(token: old, completion: .failed)
        let new = try XCTUnwrap(state.takeReadyRequest())
        state.accept(.init(total: 4, completed: 1), token: new)
        state.finish(token: old, completion: .completed)
        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.progress.completed, 1)
    }
}