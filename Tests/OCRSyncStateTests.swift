import XCTest
import Combine
@testable import LocalImageIQ

/// Pure event state, no clocks, worker, Photos, storage, models or network.
@MainActor
final class OCRSyncStateTests: XCTestCase {
    func testRecordedFailureDoesNotRepeatNoticeButRetainsManualRecovery() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.accept(.init(total: 7907, completed: 7907, reused: 7906, deferredFailures: 1), token: run)
        state.finish(token: run, completion: .completed)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.progress.deferredFailures, 1)
        XCTAssertTrue(state.terminalHidden)
        XCTAssertFalse(state.canShow)
        XCTAssertTrue(state.canRetry)
        XCTAssertTrue(state.completionDetail.contains("手动更新"))
        state.requestUpdate()
        XCTAssertFalse(state.terminalHidden)
        XCTAssertNotNil(state.takeReadyRequest())
    }

    func testOperationalFailureIsNotSilencedByPreviouslyRecordedPhotoFailure() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.accept(.init(total: 2, completed: 1, deferredFailures: 1), token: run)
        state.finish(token: run, completion: .failed, issue: "文字索引无法读写，请稍后重试。")
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.canShow)
        XCTAssertFalse(state.terminalHidden)
    }

    func testPartial7907ResultAutomaticallyHidesButRetainsFailureAndRetry() async throws {
        let gate = OCRTerminalDelayGate()
        let entered = expectation(description: "terminal delay started")
        let hidden = expectation(description: "terminal display hidden")
        let state = OCRSyncState(completionDelay: {
            entered.fulfill()
            await gate.wait()
        })
        let observer = state.$terminalHidden.filter { $0 }.sink { _ in hidden.fulfill() }
        defer { observer.cancel() }
        state.userChangedEnabled(true)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.accept(.init(total: 7907, completed: 7907, reused: 7906, failed: 1,
                           lastIssue: "暂时无法读取照片以识别文字，请重试更新照片文字。"), token: run)
        state.finish(token: run, completion: .completed)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.canShow)
        XCTAssertEqual(state.completionTitle, "文字索引：1 张未完成")
        XCTAssertTrue(state.completionDetail.contains("7906/7907"))
        XCTAssertTrue(state.completionDetail.contains("暂时无法读取照片"))
        await fulfillment(of: [entered], timeout: 3)
        await gate.open()
        await fulfillment(of: [hidden], timeout: 3)
        XCTAssertFalse(state.canShow)
        XCTAssertEqual(state.phase, .failed, "Hiding a notice must not erase the actual outcome.")
        XCTAssertTrue(state.canRetry)
        XCTAssertTrue(state.enabled)
        XCTAssertNil(state.takeReadyRequest())
        state.requestUpdate()
        XCTAssertTrue(state.canShow)
        XCTAssertFalse(state.terminalHidden)
        XCTAssertNotNil(state.takeReadyRequest())
    }

    func testCloudAndStaleFailuresExplainTheirOwnRecoveryWithoutFalseSuccess() throws {
        for progress in [TextIndexProgress(total: 2, completed: 2, reused: 1, cloudSkipped: 1),
                         TextIndexProgress(total: 2, completed: 2, reused: 1, staleSkipped: 1)] {
            let state = OCRSyncState()
            state.userChangedEnabled(true)
            state.updateAvailability(ready: true)
            let run = try XCTUnwrap(state.takeReadyRequest())
            state.accept(progress, token: run)
            state.finish(token: run, completion: .completed)
            XCTAssertEqual(state.phase, .failed)
            XCTAssertEqual(state.completionTitle, "文字索引：1 张未完成")
            XCTAssertTrue(state.completionDetail.contains(progress.cloudSkipped > 0 ? "iCloud" : "先更新图片索引"))
            XCTAssertTrue(state.completionDetail.contains("已保存的文字仍可搜索"))
        }
    }

    func testManualQualityRetryDoesNotLeakIntoNextToggleAfterDrain() throws {
        let state = OCRSyncState()
        state.userChangedEnabled(true)
        state.requestUpdate(retryReducedPreviews: true)
        state.updateAvailability(ready: true)
        let manual = try XCTUnwrap(state.takeReadyRequest())
        XCTAssertTrue(state.retryReducedPreviews)
        state.userChangedEnabled(false)
        state.userChangedEnabled(true)
        state.finish(token: manual, completion: .cancelled)
        XCTAssertNotNil(state.takeReadyRequest())
        XCTAssertFalse(state.retryReducedPreviews)
    }

    private actor OCRTerminalDelayGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

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

    func testLifecyclePauseResumesOnlyAfterOldRunDrains() throws {
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
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.lifecyclePaused)
        XCTAssertNotNil(state.takeReadyRequest())
        XCTAssertTrue(state.isResuming)
        XCTAssertNil(state.takeReadyRequest())
    }

    func testLifecyclePauseKeepsCommittedCountersAndManualQualityIntent() throws {
        let state = OCRSyncState(enabled: true)
        state.requestUpdate(retryReducedPreviews: true)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        let saved = TextIndexProgress(total: 7907, completed: 7906, recognized: 5, reused: 7901)
        state.accept(saved, token: run)
        state.pause()
        XCTAssertTrue(state.pendingQualityRetry)
        state.finish(token: run, completion: .cancelled)
        XCTAssertEqual(state.progress, saved)
        state.updateAvailability(ready: true)
        XCTAssertNotNil(state.takeReadyRequest())
        XCTAssertTrue(state.retryReducedPreviews)
        XCTAssertTrue(state.isResuming)
    }

    func testUserCancelOrOffWithdrawsLifecycleResumeEvenDuringDrain() throws {
        for off in [false, true] {
            let state = OCRSyncState(enabled: true)
            state.requestUpdate()
            state.updateAvailability(ready: true)
            let run = try XCTUnwrap(state.takeReadyRequest())
            state.pause()
            if off { state.userChangedEnabled(false) } else { state.cancel() }
            state.finish(token: run, completion: .cancelled)
            state.updateAvailability(ready: true)
            XCTAssertFalse(state.lifecyclePaused)
            XCTAssertFalse(state.pending)
            XCTAssertNil(state.takeReadyRequest())
        }
    }

    func testRestoredInterruptedRequestDoesNotTurnSavedOnPreferenceIntoNewWork() throws {
        let state = OCRSyncState(enabled: true)
        state.updateAvailability(ready: true)
        XCTAssertNil(state.takeReadyRequest())
        state.restoreInterruptedRequest(retryReducedPreviews: true)
        XCTAssertNotNil(state.takeReadyRequest())
        XCTAssertTrue(state.isResuming)
        XCTAssertTrue(state.retryReducedPreviews)
        let disabled = OCRSyncState()
        disabled.restoreInterruptedRequest(retryReducedPreviews: true)
        disabled.updateAvailability(ready: true)
        XCTAssertNil(disabled.takeReadyRequest())
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