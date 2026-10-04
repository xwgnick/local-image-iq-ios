import Combine
import Foundation
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// State contracts with synthetic summaries and independently held model branches.
/// No sleeps, polling, real models, history defaults, network or Photos requests.
/// Positive XCTest timeouts detect deadlocks; they do not drive startup policy.
@MainActor
final class StartupProgressStateTests: XCTestCase {
    func testMissingHistoryIsVisibleSynchronouslyAtExactlyOneOfNine() async {
        let plan = ProgressStatePlan()
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        XCTAssertNil(state.startupProgressFraction)
        XCTAssertEqual(state.startupProgress.completed, [])

        fixture.perform { $0.start() }
        // No suspension: entry completion and the risk decision belong to start().
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        XCTAssertTrue(state.startupProgressVisible)
        assertProgress(state, [.entry], visible: true)
        await fulfillment(of: [plan.entered], timeout: 3)
        let delays = await fixture.delay.arguments
        let calls = await fixture.worker.calls
        XCTAssertEqual(delays, [])
        XCTAssertEqual(calls.timedLaunches, 1)
        XCTAssertEqual(calls.legacyLaunches, 0, "The timing overload must be a protocol witness, not an extension-only overload.")
        XCTAssertEqual(fixture.history.lookups, [context()])
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testRealStepsIncludingParallelBranchesAdvanceOnceAndOnlyFullReadyWritesHistory() async {
        let pulses = fullPulses()
        let duplicate = ProgressStatePulse([.tokenizer, .imageModel])
        let plan = ProgressStatePlan(groups: [
            [pulses[0]], [pulses[1]], Array(pulses[2...4]), [duplicate], [pulses[5]], [pulses[6]]
        ])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        state.query = "TEST query"
        let trace = ProgressStateTrace(state)
        fixture.perform { $0.start() }
        await fulfillment(of: [plan.entered], timeout: 3)
        await plan.prepare.open()
        await fulfillment(of: [plan.preparing], timeout: 3)

        var completed: Set<StartupStep> = [.entry]
        for index in [0, 1, 3, 2, 4] {
            // Three independent children are admitted together, then deliberately
            // released image -> tokenizer -> text, not enum/callback order.
            if index == 3 {
                await fulfillment(of: Array(pulses[2...4]).map(\.started), timeout: 3)
            }
            await release(pulses[index])
            completed.formUnion(pulses[index].steps)
            assertProgress(state, completed, visible: true)
            XCTAssertEqual(state.summary.indexedCount, 0)
            XCTAssertFalse(state.canSearch)
            XCTAssertFalse(state.canIndex)
            XCTAssertTrue(fixture.history.writes.isEmpty)
        }
        let beforeDuplicate = trace.progress
        await release(duplicate)
        XCTAssertEqual(trace.progress, beforeDuplicate, "Duplicate worker completions must not advance the displayed snapshot.")
        for index in [5, 6] {
            await release(pulses[index])
            completed.formUnion(pulses[index].steps)
            assertProgress(state, completed, visible: true)
        }
        XCTAssertEqual(completed.count, 8)
        XCTAssertFalse(completed.contains(.ready))
        XCTAssertFalse(state.canSearch)
        XCTAssertTrue(fixture.history.writes.isEmpty, "Models and counts are not launch-owner readiness.")

        await finish(plan, state: state)
        XCTAssertEqual(state.launchPhase, .ready)
        assertProgress(state, Set(StartupStep.allCases), visible: false)
        XCTAssertEqual(state.startupProgress.fraction, 1)
        XCTAssertEqual(fixture.history.writes, [context()])
        XCTAssertEqual(state.summary.indexedCount, 7)
        XCTAssertTrue(state.canSearch)
        XCTAssertTrue(state.canIndex)
        let progressing = trace.progress.filter { !$0.completed.isEmpty }
        XCTAssertEqual(progressing.map { $0.completed.count }, Array(1...9))
        for pair in zip(progressing, progressing.dropFirst()) {
            XCTAssertTrue(pair.0.completed.isSubset(of: pair.1.completed))
        }
        state.start()
        state.retryLaunch()
        XCTAssertEqual(fixture.history.writes, [context()])
    }

    func testKnownContextFastReadyCancelsStartedNoncooperativeDelayAndNeverShowsLateBar() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let timer = ProgressStateDelayCall()
        let fixture = makeFixture(plans: [plan], known: true, timers: [timer])
        let state = fixture.requiredState
        let trace = ProgressStateTrace(state)
        fixture.perform { $0.start() }
        assertProgress(state, [.entry], visible: false)
        await fulfillment(of: [plan.entered, timer.started], timeout: 3)
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        await fulfillment(of: [timer.cancelled], timeout: 3)
        let args = await fixture.delay.arguments
        XCTAssertEqual(args, [8])
        XCTAssertEqual(fixture.history.writes, [context()])
        XCTAssertFalse(trace.visibility.contains(true))

        // Intentionally leave this delay suspended until teardown. Release it
        // noncooperatively while STILL foreground/ready, then join the actual
        // inherited tasks, not just the delay closure's return notification.
        fixture.cancelBeforeCleanup = false
        fixture.afterCleanup = {
            XCTAssertEqual(state.launchPhase, .ready)
            XCTAssertFalse(trace.visibility.contains(true))
            XCTAssertFalse(state.startupProgressVisible)
            XCTAssertNil(state.startupProgressFraction)
        }
        fixture.expectedDelayCancellationOnReturn = [true]
    }

    func testKnownContextHeldDelayReceivesEightSecondsAndChangesOnlyVisibility() async {
        let pulse = ProgressStatePulse([.places])
        let plan = ProgressStatePlan(groups: [[pulse]])
        let timer = ProgressStateDelayCall()
        let fixture = makeFixture(plans: [plan], known: true, timers: [timer])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await fulfillment(of: [plan.entered, timer.started], timeout: 3)
        let before = state.startupProgress
        let becameVisible = expectation(description: "Held policy delay made the bar visible")
        let observation = state.$startupProgressVisible.filter { $0 }.prefix(1).sink { _ in becameVisible.fulfill() }
        defer { observation.cancel() }
        await timer.gate.open()
        await fulfillment(of: [timer.returned, becameVisible], timeout: 3)

        let args = await fixture.delay.arguments
        let cancellation = await fixture.delay.returnedCancelled
        XCTAssertEqual(args, [StartupDisplayPolicy.fallbackDelaySeconds])
        XCTAssertEqual(args, [8], "This is an injected argument assertion, not an eight-second wait.")
        XCTAssertEqual(cancellation, [false])
        XCTAssertEqual(state.startupProgress, before)
        assertProgress(state, [.entry], visible: true)
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        XCTAssertEqual(state.activity, .starting)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        await plan.prepare.open()
        await release(pulse)
        assertProgress(state, [.entry, .places], visible: true)
    }

    func testThrownFailureFreezesOnlyRealCompletedStepsAndDoesNotWriteHistory() async {
        let pulse = ProgressStatePulse([.places, .resources])
        let plan = ProgressStatePlan(groups: [[pulse]], outcome: .failure(.storage("TEST throw")))
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(state.launchPhase, .failed)
        assertProgress(state, [.entry, .places, .resources], visible: false)
        XCTAssertEqual(state.launchTimings.last?.outcome, .failed)
        XCTAssertFalse(state.canSearch)
        XCTAssertFalse(state.canIndex)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        let frozen = state.startupProgress
        await emitLate(workerSteps, worker: fixture.worker, attempt: 1)
        XCTAssertEqual(state.startupProgress, frozen)
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testModelIssueAfterAllWorkerStepsStillCannotCompleteReadyOrWriteHistory() async {
        let failed = LibrarySummary(indexedCount: 7, modelVersion: "TEST model", modelIssue: "TEST contract issue")
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]], outcome: .success(failed))
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        state.query = "TEST query"
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(state.launchPhase, .failed)
        assertProgress(state, workerSteps.union([.entry]), visible: false)
        XCTAssertEqual(state.startupProgress.fraction, 8.0 / 9.0)
        XCTAssertEqual(state.summary.modelIssue, "TEST contract issue")
        XCTAssertEqual(state.launchTimings.last?.outcome, .failed)
        XCTAssertFalse(state.canSearch)
        XCTAssertFalse(state.canIndex)
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testExplicitCancellationRejectsNoncooperativeSuccessAndDoesNotWriteHistory() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        state.cancel()
        await finish(plan, state: state)
        XCTAssertEqual(state.launchPhase, .failed)
        XCTAssertEqual(state.launchTimings.last?.outcome, .interrupted)
        assertProgress(state, workerSteps.union([.entry]), visible: false)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        let calls = await fixture.worker.calls
        XCTAssertEqual(calls.cancelledLaunches, 1)
    }

    func testExplicitOpenHomeAfterFailureDoesNotForgeReadyStepOrSuccessfulHistory() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse([.resources])]], outcome: .failure(.storage("TEST recovery")))
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        let frozen = state.startupProgress
        let issue = state.launchIssue
        let error = state.errorMessage
        let ids = state.launchTimings.map(\.id)
        state.openHomeAfterLaunchFailure()
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.startupProgress, frozen)
        XCTAssertFalse(state.startupProgress.completed.contains(.ready))
        XCTAssertNil(state.startupProgressFraction)
        XCTAssertEqual(state.launchIssue, issue)
        XCTAssertEqual(state.errorMessage, error)
        XCTAssertEqual(state.launchTimings.map(\.id), ids)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.canSearch)
        await emitLate(Set(StartupStep.allCases), worker: fixture.worker, attempt: 1)
        XCTAssertEqual(state.startupProgress, frozen)
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testSuccessfulSummaryWithMissingWorkerStepsDoesNotInventStepsOrWriteHistory() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse([.resources])]])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(state.launchPhase, .ready, "The fake summary is successful, but is not evidence for unreported steps.")
        assertProgress(state, [.entry, .resources, .ready], visible: false)
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testBuildContextChangeIsNewRiskDespiteSuccessfulPreviousBuild() async {
        let previous = context(build: "20")
        let current = context(build: "21")
        XCTAssertNotEqual(previous, current)
        let history = ProgressStateHistory(successes: [previous])
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan], history: history, contextProvider: { current })
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        assertProgress(state, [.entry], visible: true)
        XCTAssertEqual(history.lookups, [current])
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(history.writes, [current])
        let args = await fixture.delay.arguments
        XCTAssertTrue(args.isEmpty)
    }

    func testSuccessWritesCapturedAttemptContextNotAChangedProviderValue() async {
        let original = context(build: "20")
        let replacement = context(build: "21")
        let provider = ProgressStateContext(original)
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan], contextProvider: { provider.read() })
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        provider.value = replacement
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(provider.reads, 1)
        XCTAssertEqual(fixture.history.lookups, [original])
        XCTAssertEqual(fixture.history.writes, [original])
    }

    func testMissingContextRemainsRiskyAndCannotPersistEvenACompleteSuccess() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan], contextProvider: { nil })
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        assertProgress(state, [.entry], visible: true)
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        XCTAssertEqual(state.startupProgress.completed, Set(StartupStep.allCases))
        XCTAssertTrue(fixture.history.lookups.isEmpty)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        let args = await fixture.delay.arguments
        XCTAssertTrue(args.isEmpty)
    }

    func testBackgroundFreezesProgressBeforeHeldParallelChildrenComplete() async {
        let children = [ProgressStatePulse([.tokenizer]), ProgressStatePulse([.imageModel]), ProgressStatePulse([.textModel])]
        let plan = ProgressStatePlan(groups: [children])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await plan.prepare.open()
        await fulfillment(of: children.map(\.started), timeout: 3)
        await release(children[0])
        assertProgress(state, [.entry, .tokenizer], visible: true)
        state.enterBackground()
        let frozen = state.startupProgress
        XCTAssertEqual(state.launchPhase, .pending)
        XCTAssertEqual(state.launchTimings.last?.outcome, .interrupted)
        assertProgress(state, [.entry, .tokenizer], visible: false)
        let callsWhileHeld = await fixture.worker.calls
        XCTAssertEqual(callsWhileHeld.active, 1, "Freezing does not wait for noninterruptible children.")
        await release(children[1])
        await release(children[2])
        await fixture.worker.emitStage(.checkingLibrary, attempt: 1)
        XCTAssertEqual(state.startupProgress, frozen)
        XCTAssertEqual(state.launchPhase, .pending)
        await finish(plan, state: state)
        XCTAssertEqual(state.startupProgress, frozen)
        XCTAssertEqual(state.launchPhase, .pending)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertFalse(state.startupProgressVisible)
        XCTAssertTrue(fixture.history.writes.isEmpty)
    }

    func testForegroundReplacementRejectsAdmittedOldSnapshotStageAndNoncooperativeTimer() async throws {
        let oldPulse = ProgressStatePulse([.places])
        let first = ProgressStatePlan(groups: [[oldPulse]])
        let secondPulse = ProgressStatePulse([.imageModel])
        let second = ProgressStatePlan(groups: [[secondPulse]])
        let firstTimer = ProgressStateDelayCall()
        let secondTimer = ProgressStateDelayCall()
        let fixture = makeFixture(plans: [first, second], known: true, timers: [firstTimer, secondTimer])
        let state = fixture.requiredState
        let firstFinished = fixture.perform { $0.start() }
        await fulfillment(of: [first.entered, firstTimer.started], timeout: 3)
        await first.prepare.open()
        await release(oldPulse)
        let recorded = await fixture.worker.recorder(attempt: 1)
        let oldRecorder = try XCTUnwrap(recorded)
        let staleDelivery = ProgressStateSignal.make("Already-admitted old snapshot returned")
        // Synchronous MainActor turn: the old observer queues its Task before
        // freeze, but cannot run it until AFTER the replacement has been installed.
        ProgressStateTaskScope.$lifetime.withValue(ProgressStateTaskLifetime(staleDelivery)) {
            oldRecorder.complete(.textModel)
        }
        state.enterBackground()
        let oldFrozen = state.startupProgress
        XCTAssertEqual(oldFrozen.completed, [.entry, .places, .textModel])
        fixture.perform { $0.enterForeground() }
        assertProgress(state, [.entry], visible: false)
        await fulfillment(of: [staleDelivery, firstTimer.cancelled, secondTimer.started], timeout: 3)
        assertProgress(state, [.entry], visible: false)
        let queuedCalls = await fixture.worker.calls
        XCTAssertEqual(queuedCalls.timedLaunches, 1, "Replacement waits for the predecessor, not merely its cancellation.")

        await firstTimer.gate.open()
        await first.finish.open()
        await fulfillment(of: [firstFinished.expectation(), second.entered], timeout: 3)
        await fixture.worker.emitStage(.preparingSearch, attempt: 1)
        await emitLate(workerSteps, worker: fixture.worker, attempt: 1)
        XCTAssertEqual(oldRecorder.snapshot, oldFrozen)
        XCTAssertEqual(state.launchPhase, .checkingLibrary)
        assertProgress(state, [.entry], visible: false)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        let calls = await fixture.worker.calls
        let cancellation = await fixture.delay.returnedCancelled
        XCTAssertEqual(calls.timedLaunches, 2)
        XCTAssertEqual(calls.peakActive, 1)
        XCTAssertEqual(cancellation, [true])
        await second.prepare.open()
        await release(secondPulse)
        assertProgress(state, [.entry, .imageModel], visible: false)
        XCTAssertEqual(state.launchTimings.count, 1)
        XCTAssertEqual(state.launchTimings.first?.outcome, .interrupted)
    }

    func testExplicitRetryResetsFailedStepsAndHasItsOwnVisibilityDelay() async {
        let failedPulse = ProgressStatePulse([.resources, .tokenizer])
        let first = ProgressStatePlan(groups: [[failedPulse]], outcome: .failure(.storage("TEST retry")))
        let newPulse = ProgressStatePulse([.imageModel])
        let second = ProgressStatePlan(groups: [[newPulse]])
        let firstTimer = ProgressStateDelayCall()
        let secondTimer = ProgressStateDelayCall()
        let fixture = makeFixture(plans: [first, second], known: true, timers: [firstTimer, secondTimer])
        let state = fixture.requiredState
        let firstFinished = fixture.perform { $0.start() }
        await fulfillment(of: [firstTimer.started], timeout: 3)
        await releaseAllProgress(first)
        await finish(first, state: state)
        assertProgress(state, [.entry, .resources, .tokenizer], visible: false)
        await fulfillment(of: [firstTimer.cancelled], timeout: 3)
        state.start()
        state.refresh()
        let beforeRetry = await fixture.worker.calls
        XCTAssertEqual(beforeRetry.timedLaunches, 1)
        XCTAssertEqual(beforeRetry.refreshes, 0)

        fixture.perform { $0.retryLaunch() }
        assertProgress(state, [.entry], visible: false)
        await fulfillment(of: [second.entered, secondTimer.started], timeout: 3)
        await firstTimer.gate.open()
        await fulfillment(of: [firstFinished.expectation()], timeout: 3)
        await emitLate(workerSteps, worker: fixture.worker, attempt: 1)
        assertProgress(state, [.entry], visible: false)
        XCTAssertEqual(fixture.history.lookups, [context(), context()])
        XCTAssertTrue(fixture.history.writes.isEmpty)

        let visible = expectation(description: "Only retry's own timer can reveal its bar")
        let observation = state.$startupProgressVisible.filter { $0 }.prefix(1).sink { _ in visible.fulfill() }
        defer { observation.cancel() }
        await secondTimer.gate.open()
        await fulfillment(of: [visible], timeout: 3)
        assertProgress(state, [.entry], visible: true)
        await second.prepare.open()
        await release(newPulse)
        assertProgress(state, [.entry, .imageModel], visible: true)
        XCTAssertFalse(state.startupProgress.completed.contains(.resources))
        XCTAssertFalse(state.startupProgress.completed.contains(.tokenizer))
        let args = await fixture.delay.arguments
        XCTAssertEqual(args, [8, 8])
    }

    func testSearchAndIndexGuardsAndExistingMetadataDoNotChangeBeforeTrueReady() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        state.query = "TEST preserved query"
        state.locationWeight = 0.85
        state.resultLimit = 12
        state.allowICloudDownload = true
        let refreshed = fixture.perform { $0.refresh() }
        await fulfillment(of: [refreshed.expectation()], timeout: 3)
        XCTAssertTrue(state.canSearch)
        XCTAssertTrue(state.canIndex)
        let count = state.summary.indexedCount
        let model = state.summary.modelVersion
        let indexProgress = state.progress

        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        XCTAssertEqual(state.launchPhase, .preparingSearch)
        assertProgress(state, workerSteps.union([.entry]), visible: true)
        XCTAssertFalse(state.canSearch)
        XCTAssertFalse(state.canIndex)
        XCTAssertEqual(state.summary.indexedCount, count)
        XCTAssertEqual(state.summary.modelVersion, model)
        XCTAssertEqual(state.progress, indexProgress)
        state.search()
        state.index()
        state.openHomeAfterLaunchFailure()
        XCTAssertEqual(state.launchPhase, .preparingSearch)
        let calls = await fixture.worker.calls
        XCTAssertEqual(calls.searches, 0)
        XCTAssertEqual(calls.indexes, 0)
        XCTAssertEqual(calls.clears, 0)
        XCTAssertTrue(fixture.history.writes.isEmpty)

        await finish(plan, state: state)
        XCTAssertTrue(state.canSearch)
        XCTAssertTrue(state.canIndex)
        XCTAssertEqual(state.query, "TEST preserved query")
        XCTAssertEqual(state.locationWeight, 0.85)
        XCTAssertEqual(state.resultLimit, 12)
        XCTAssertTrue(state.allowICloudDownload)
        XCTAssertEqual(state.progress, indexProgress)
        XCTAssertEqual(fixture.history.writes, [context()])
    }

    func testNormalAndForegroundRefreshEmitNoNewStartupProgressOrHistory() async {
        let plan = ProgressStatePlan(groups: [[ProgressStatePulse(workerSteps)]])
        let fixture = makeFixture(plans: [plan])
        let state = fixture.requiredState
        fixture.perform { $0.start() }
        await releaseAllProgress(plan)
        await finish(plan, state: state)
        let trace = ProgressStateTrace(state)
        let snapshot = state.startupProgress
        let ids = state.launchTimings.map(\.id)
        let refreshFinished = fixture.perform { $0.refresh() }
        await fulfillment(of: [refreshFinished.expectation()], timeout: 3)
        state.enterBackground()
        let foregroundFinished = fixture.perform { $0.enterForeground() }
        await fulfillment(of: [foregroundFinished.expectation()], timeout: 3)
        XCTAssertEqual(state.launchPhase, .ready)
        XCTAssertEqual(state.startupProgress, snapshot)
        XCTAssertEqual(trace.progress, [snapshot])
        XCTAssertEqual(trace.visibility, [false])
        XCTAssertNil(state.startupProgressFraction)
        XCTAssertEqual(state.launchTimings.map(\.id), ids)
        XCTAssertEqual(fixture.history.writes, [context()])
        XCTAssertEqual(fixture.history.lookups, [context()])
        let calls = await fixture.worker.calls
        let args = await fixture.delay.arguments
        XCTAssertEqual(calls.timedLaunches, 1)
        XCTAssertEqual(calls.legacyLaunches, 0)
        XCTAssertEqual(calls.refreshes, 2)
        XCTAssertEqual(calls.indexes, 0)
        XCTAssertEqual(calls.searches, 0)
        XCTAssertEqual(calls.clears, 0)
        XCTAssertTrue(args.isEmpty)
    }

    func testDeinitReleasesStateWhileStartedWorkerAndVisibilityDelayAreBothHeld() async {
        let plan = ProgressStatePlan()
        let timer = ProgressStateDelayCall()
        let fixture = makeFixture(plans: [plan], known: true, timers: [timer])
        weak var weakState = fixture.state
        fixture.perform { $0.start() }
        await fulfillment(of: [plan.entered, timer.started], timeout: 3)
        XCTAssertNotNil(weakState)
        // The fixture/teardown deliberately does not capture a second strong
        // AppState reference; neither the delay nor a held worker may own it.
        fixture.state = nil
        XCTAssertNil(weakState, "Do not promote weak self before awaiting the visibility delay or worker.")
        await fulfillment(of: [timer.cancelled], timeout: 3)
        XCTAssertTrue(fixture.history.writes.isEmpty)
        fixture.expectedDelayCancellationOnReturn = [true]
        // Teardown opens ALL gates before joining the inherited tasks, even if
        // a failed weak assertion reveals a production retain cycle.
    }

    // MARK: - Bounded event helpers

    private var workerSteps: Set<StartupStep> {
        [.places, .resources, .tokenizer, .imageModel, .textModel, .assembly, .counts]
    }

    private func fullPulses() -> [ProgressStatePulse] {
        [StartupStep.places, .resources, .tokenizer, .imageModel, .textModel, .assembly, .counts]
            .map { ProgressStatePulse([$0]) }
    }

    private func context(build: String = "20") -> StartupContext {
        StartupContext(fingerprint: StartupContext.makeFingerprint(
            manifestData: Data("TEST synthetic manifest".utf8),
            bundleURL: URL(fileURLWithPath: "/TEST/StartupProgress.app"),
            bundleIdentifier: "test.startup.progress", bundleVersion: build,
            shortVersion: "0.5.7", operatingSystemVersion: "TEST OS", resourceURLs: []))
    }

    private func makeFixture(plans: [ProgressStatePlan], known: Bool = false,
                             timers: [ProgressStateDelayCall] = [],
                             history: ProgressStateHistory? = nil,
                             contextProvider: (() -> StartupContext?)? = nil) -> ProgressStateFixture {
        let identity = context()
        let store = history ?? ProgressStateHistory(successes: known ? [identity] : [])
        let fixture = ProgressStateFixture(plans: plans, history: store, timers: timers,
                                           contextProvider: contextProvider ?? { identity })
        addTeardownBlock { [fixture] in
            await fixture.releaseForCleanup()
            let completions = await fixture.taskCompletions
            let joins = completions.map { $0.expectation() }
            if !joins.isEmpty { await self.fulfillment(of: joins, timeout: 3) }
            await fixture.verifyCleanup()
        }
        return fixture
    }

    private func assertProgress(_ state: AppState, _ completed: Set<StartupStep>, visible: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.startupProgress.completed, completed, file: file, line: line)
        XCTAssertEqual(state.startupProgress.fraction, Double(completed.count) / 9.0, file: file, line: line)
        XCTAssertEqual(state.startupProgressVisible, visible, file: file, line: line)
        let fraction = state.startupProgressFraction
        if visible { XCTAssertEqual(fraction, Double(completed.count) / 9.0, file: file, line: line) }
        else { XCTAssertNil(fraction, file: file, line: line) }
    }

    private func release(_ pulse: ProgressStatePulse) async {
        await pulse.gate.open()
        await fulfillment(of: [pulse.delivered], timeout: 3)
    }

    private func releaseAllProgress(_ plan: ProgressStatePlan) async {
        await plan.prepare.open()
        await fulfillment(of: [plan.preparing], timeout: 3)
        for group in plan.groups {
            for pulse in group { await release(pulse) }
        }
    }

    private func finish(_ plan: ProgressStatePlan, state: AppState) async {
        let idle = expectation(description: "Launch owner finished publication")
        let observation = state.$activity.filter { $0 == nil }.prefix(1).sink { _ in idle.fulfill() }
        defer { observation.cancel() }
        await plan.finish.open()
        await fulfillment(of: [idle], timeout: 3)
        // Publication has no further suspension after activity becomes nil;
        // resuming on MainActor therefore sees the completed state transition.
        // Teardown joins the task family with a separate bounded event fence.
    }

    private func emitLate(_ steps: Set<StartupStep>, worker: ProgressStateWorker, attempt: Int) async {
        let delivered = ProgressStateSignal.make("Late recorder delivery finished")
        await worker.emit(steps, attempt: attempt, delivered: delivered)
        await fulfillment(of: [delivered], timeout: 3)
    }
}

// MARK: - Test-only gates and task completion fences

private enum ProgressStateSignal {
    static func make(_ description: String) -> XCTestExpectation {
        let value = XCTestExpectation(description: description)
        value.assertForOverFulfill = true
        return value
    }
}

/// Tasks created by AppState inherit this value. Its final release is a positive
/// completion fence for the entire spawned task family, including the private
/// visibility Task and observer Tasks. No scheduler-order/yield assumption is
/// needed. Pulse-local scopes similarly join admitted observer callbacks, even
/// when freeze/replacement causes those callbacks to be ignored.
private enum ProgressStateTaskScope {
    @TaskLocal static var lifetime: ProgressStateTaskLifetime?
}

private final class ProgressStateTaskLifetime: @unchecked Sendable {
    private let finish: @Sendable () -> Void
    init(_ finished: XCTestExpectation) { finish = { finished.fulfill() } }
    init(_ finished: ProgressStateCompletion) { finish = { finished.complete() } }
    deinit { finish() }
}

/// Separate subscriptions let a test AND teardown join the same task family
/// without reusing an XCTestExpectation (XCTest allows only one wait per object).
/// Teardown still has its own fence if an earlier assertion/wait failed.
private final class ProgressStateCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var subscribers: [XCTestExpectation] = []

    func expectation() -> XCTestExpectation {
        let value = ProgressStateSignal.make("AppState spawned task family finished")
        lock.lock()
        let alreadyCompleted = completed
        if !alreadyCompleted { subscribers.append(value) }
        lock.unlock()
        if alreadyCompleted { value.fulfill() }
        return value
    }

    func complete() {
        lock.lock()
        completed = true
        let pending = subscribers
        subscribers.removeAll()
        lock.unlock()
        for subscriber in pending { subscriber.fulfill() }
    }
}

/// Deliberately noncooperative: cancellation does not release the continuation.
/// Every gate belongs to a fixture and is opened unconditionally in teardown.
private actor ProgressStateGate {
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

private struct ProgressStatePulse: Sendable {
    let steps: Set<StartupStep>
    let gate = ProgressStateGate()
    let started = ProgressStateSignal.make("Progress child reached its gate")
    let delivered = ProgressStateSignal.make("Progress child and admitted observer callbacks returned")

    init(_ steps: Set<StartupStep>) { self.steps = steps }

    func run(recorder: StartupProgressRecorder?) async {
        started.fulfill()
        await gate.wait()
        ProgressStateTaskScope.$lifetime.withValue(ProgressStateTaskLifetime(delivered)) {
            recorder?.complete(steps)
        }
    }
}

private struct ProgressStatePlan: Sendable {
    enum Outcome: Sendable {
        case success(LibrarySummary)
        case failure(AppFailure)
    }

    let entered = ProgressStateSignal.make("Launch checking callback returned")
    let preparing = ProgressStateSignal.make("Launch preparing callback returned")
    let prepare = ProgressStateGate()
    let finish = ProgressStateGate()
    let groups: [[ProgressStatePulse]]
    let outcome: Outcome

    init(groups: [[ProgressStatePulse]] = [],
         outcome: Outcome = .success(LibrarySummary(indexedCount: 7, locatedCount: 3, modelVersion: "TEST model"))) {
        self.groups = groups
        self.outcome = outcome
    }

    func releaseAll() async {
        await prepare.open()
        for group in groups {
            for pulse in group { await pulse.gate.open() }
        }
        await finish.open()
    }
}

private struct ProgressStateDelayCall: Sendable {
    let gate = ProgressStateGate()
    let started = ProgressStateSignal.make("Injected visibility delay started")
    let cancelled = ProgressStateSignal.make("Started visibility delay was cancelled")
    let returned = ProgressStateSignal.make("Injected visibility delay returned noncooperatively")
}

private actor ProgressStateDelay {
    let plans: [ProgressStateDelayCall]
    private(set) var arguments: [Double] = []
    private(set) var returnedCancelled: [Bool] = []

    init(_ plans: [ProgressStateDelayCall]) { self.plans = plans }

    func wait(_ seconds: Double) async throws {
        let index = arguments.count
        arguments.append(seconds)
        guard plans.indices.contains(index) else {
            XCTFail("Unexpected visibility delay invocation; this attempt has no delay plan.")
            return
        }
        let plan = plans[index]
        await withTaskCancellationHandler {
            plan.started.fulfill()
            await plan.gate.wait()
            returnedCancelled.append(Task.isCancelled)
            plan.returned.fulfill()
            // Intentionally do not throw on cancellation: AppState must guard
            // the resumed continuation itself before making the bar visible.
        } onCancel: {
            plan.cancelled.fulfill()
        }
    }

    func releaseAll() async {
        for plan in plans { await plan.gate.open() }
    }
}

@MainActor
private final class ProgressStateHistory: StartupHistoryStoring {
    private var successes: [StartupContext]
    private(set) var lookups: [StartupContext] = []
    private(set) var writes: [StartupContext] = []

    init(successes: [StartupContext] = []) { self.successes = successes }

    func hasSuccessfulPreparation(for context: StartupContext) -> Bool {
        lookups.append(context)
        return successes.contains(context)
    }

    func recordSuccessfulPreparation(for context: StartupContext) {
        writes.append(context)
        successes.append(context)
    }
}

@MainActor
private final class ProgressStateContext {
    var value: StartupContext?
    private(set) var reads = 0
    init(_ value: StartupContext?) { self.value = value }
    func read() -> StartupContext? { reads += 1; return value }
}

@MainActor
private final class ProgressStateTrace {
    private(set) var progress: [StartupProgressSnapshot] = []
    private(set) var visibility: [Bool] = []
    private var observations: Set<AnyCancellable> = []

    init(_ state: AppState) {
        // Initial replay and the synchronous entry snapshot can reassign the
        // same value. Count actual completed-set changes, not @Published writes.
        state.$startupProgress.removeDuplicates().sink { [weak self] in self?.progress.append($0) }.store(in: &observations)
        state.$startupProgressVisible.sink { [weak self] in self?.visibility.append($0) }.store(in: &observations)
    }
}

@MainActor
private final class ProgressStateFixture {
    var state: AppState?
    var requiredState: AppState { state! }
    let worker: ProgressStateWorker
    let history: ProgressStateHistory
    let delay: ProgressStateDelay
    private(set) var taskCompletions: [ProgressStateCompletion] = []
    var cancelBeforeCleanup = true
    var afterCleanup: (() -> Void)?
    var expectedDelayCancellationOnReturn: [Bool]?

    init(plans: [ProgressStatePlan], history: ProgressStateHistory,
         timers: [ProgressStateDelayCall], contextProvider: @escaping () -> StartupContext?) {
        let worker = ProgressStateWorker(plans)
        let delay = ProgressStateDelay(timers)
        self.worker = worker
        self.history = history
        self.delay = delay
        // No real authorization request. The concrete client is required only
        // for AppState's change-handler API; all work uses the actor fake.
        state = AppState(library: PhotoLibraryClient(), worker: worker,
                         authorizationStatus: { .authorized }, startupHistory: history,
                         startupContext: contextProvider,
                         startupVisibilityDelay: { seconds in try await delay.wait(seconds) })
    }

    @discardableResult
    func perform(_ action: (AppState) -> Void) -> ProgressStateCompletion {
        let finished = ProgressStateCompletion()
        taskCompletions.append(finished)
        ProgressStateTaskScope.$lifetime.withValue(ProgressStateTaskLifetime(finished)) {
            action(requiredState)
        }
        return finished
    }

    func releaseForCleanup() async {
        if cancelBeforeCleanup { state?.enterBackground() }
        await worker.releaseAll()
        await delay.releaseAll()
    }

    func verifyCleanup() async {
        if let expectedDelayCancellationOnReturn {
            let actual = await delay.returnedCancelled
            XCTAssertEqual(actual, expectedDelayCancellationOnReturn)
        }
        afterCleanup?()
        afterCleanup = nil
        state?.enterBackground()
        let calls = await worker.calls
        XCTAssertEqual(calls.active, 0, "All worker gates must be released before joining/ending the test.")
        XCTAssertEqual(calls.legacyLaunches, 0, "AppState must dispatch through the explicit timing-aware requirement witness.")
        XCTAssertEqual(calls.diagnostics, 0)
    }
}

/// Implements BOTH protocol requirements explicitly. The timing-aware witness
/// alone emits startup completion events; legacy/refresh/other stubs cannot
/// silently inherit a default implementation that makes these tests vacuous.
private actor ProgressStateWorker: PhotoWorkServicing {
    struct Calls: Sendable {
        var legacyLaunches = 0
        var timedLaunches = 0
        var cancelledLaunches = 0
        var refreshes = 0
        var indexes = 0
        var searches = 0
        var clears = 0
        var diagnostics = 0
        var active = 0
        var peakActive = 0
    }

    private let plans: [ProgressStatePlan]
    private let summary = LibrarySummary(indexedCount: 7, locatedCount: 3, modelVersion: "TEST model")
    private var recorders: [Int: StartupProgressRecorder] = [:]
    private var callbacks: [Int: @Sendable (LaunchStage) async -> Void] = [:]
    private(set) var calls = Calls()

    init(_ plans: [ProgressStatePlan]) { self.plans = plans }

    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        calls.legacyLaunches += 1
        await progress(.checkingLibrary)
        await progress(.preparingSearch)
        return summary
    }

    func prepareForLaunch(timing: LaunchTimingRecorder?,
                          progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        let index = calls.timedLaunches
        calls.timedLaunches += 1
        calls.active += 1
        calls.peakActive = max(calls.peakActive, calls.active)
        defer {
            calls.active -= 1
            if Task.isCancelled { calls.cancelledLaunches += 1 }
        }
        guard plans.indices.contains(index) else {
            XCTFail("Unexpected launch without an explicit per-attempt plan.")
            throw AppFailure.storage("TEST unexpected launch")
        }
        XCTAssertNotNil(timing?.startupProgress, "AppState must pass its attempt recorder to the protocol witness.")
        recorders[index + 1] = timing?.startupProgress
        callbacks[index + 1] = progress
        let plan = plans[index]
        await progress(.checkingLibrary)
        plan.entered.fulfill()
        await plan.prepare.wait()
        await progress(.preparingSearch)
        plan.preparing.fulfill()
        for group in plan.groups {
            await withTaskGroup(of: Void.self) { children in
                for pulse in group {
                    children.addTask { await pulse.run(recorder: timing?.startupProgress) }
                }
                await children.waitForAll()
            }
        }
        await plan.finish.wait()
        switch plan.outcome {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func recorder(attempt: Int) -> StartupProgressRecorder? { recorders[attempt] }

    func emit(_ steps: Set<StartupStep>, attempt: Int, delivered: XCTestExpectation) {
        ProgressStateTaskScope.$lifetime.withValue(ProgressStateTaskLifetime(delivered)) {
            guard let recorder = recorders[attempt] else {
                XCTFail("Late event requires an already-started attempt.")
                return
            }
            recorder.complete(steps)
        }
    }

    func emitStage(_ stage: LaunchStage, attempt: Int) async {
        guard let callback = callbacks[attempt] else {
            XCTFail("Late stage requires an already-started attempt.")
            return
        }
        await callback(stage)
    }

    func releaseAll() async {
        for plan in plans { await plan.releaseAll() }
    }

    func refresh() async throws -> LibrarySummary {
        calls.refreshes += 1
        return summary
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        calls.indexes += 1
        return summary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        calls.searches += 1
        return SearchResponse(summary: summary, hits: [])
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        calls.diagnostics += 1
        throw AppFailure.photo("TEST diagnostics stub")
    }

    func clear() async throws -> LibrarySummary {
        calls.clears += 1
        return LibrarySummary()
    }
}