import Foundation
import XCTest
@testable import LocalImageIQ

/// Scheduling/readiness/drain contracts only: no models, downloads, Photos,
/// sleeps, polling or physical-backend overlap claims. Times are injected.
final class ParallelModelPreparationTests: XCTestCase {
    func testAllThreeBranchesStartBeforeAnyReleaseAndRecordParallelWallAndComponents() async throws {
        let clock = PMPreparationClock()
        let timing = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        let progress = StartupProgressRecorder()
        clock.set(101)
        let run = start(timing: timing, startupProgress: progress)
        guard await expect([run.probe.signals.allStarted]) else { return }
        assertAllStartedAndHeld(await run.probe.snapshot())
        XCTAssertEqual(progress.snapshot.completed, [])

        clock.set(109)
        await run.probe.releaseAll()
        guard await expect([run.probe.signals.returned]) else { return }
        assertSuccess(await run.task.value)
        assertDrained(await run.probe.snapshot(), cancelled: [])
        XCTAssertEqual(progress.snapshot.completed, [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(progress.snapshot.fraction, 3.0 / 9.0,
                       "This helper cannot invent resources, assembly, counts or owner readiness.")

        clock.set(111)
        let report = try XCTUnwrap(timing.finish(.ready))
        assertReport(report, outcome: .ready, wall: [1, 8, 2],
                     components: [8, 8, 8], statuses: [.completed, .completed, .completed])
        XCTAssertEqual(report.kind, .cold)
        XCTAssertEqual(report.id, timing.id)
        XCTAssertEqual(report.components.reduce(0) { $0 + $1.seconds }, 24,
                       "Overlapping components must not be added to the 11-unit wall total.")
        XCTAssertEqual(report.slowest?.stage, .parallelModels)
        XCTAssertEqual(report.slowest?.seconds, 8)
        XCTAssertNil(timing.finish(.ready))
        progress.complete([.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(progress.snapshot.completed, [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(progress.snapshot.fraction, 3.0 / 9.0, "Duplicate completions must not add steps.")
    }

    func testSuccessRequiresEveryPossibleLastBranchBeforeReturningHeterogeneousValues() async throws {
        for last in PMPreparationBranch.allCases {
            let timing = LaunchTimingRecorder(kind: .retry, now: { 0 })
            let progress = StartupProgressRecorder()
            let run = start(timing: timing, startupProgress: progress)
            guard await expect([run.probe.signals.allStarted]) else { return }
            assertAllStartedAndHeld(await run.probe.snapshot())
            XCTAssertEqual(progress.snapshot.completed, [])

            let firstTwo = PMPreparationBranch.allCases.filter { $0 != last }
            for (index, branch) in firstTwo.enumerated() {
                let completed = Set(firstTwo.prefix(index + 1).map(\.startupStep))
                let advanced = expectation(description: "Released branch reported successful completion")
                advanced.assertForOverFulfill = true
                let observer = progress.observe { snapshot in
                    if snapshot.completed == completed { advanced.fulfill() }
                }
                defer { progress.removeObserver(observer) }
                await run.probe.release(branch)
                // exit() runs inside the injected operation, BEFORE measured()
                // publishes success. Wait for the actual progress event as well.
                guard await expect([run.probe.signals.exited(branch), advanced]) else { return }
                XCTAssertEqual(progress.snapshot.completed, completed)
                XCTAssertEqual(progress.snapshot.fraction, Double(index + 1) / 9.0)
            }
            let held = await run.probe.snapshot()
            XCTAssertEqual(held.exited, Set(firstTwo))
            XCTAssertFalse(held.released.contains(last))
            XCTAssertNil(held.exitedAtReturn, "Two successful branches are not all-required readiness.")
            XCTAssertFalse(progress.snapshot.completed.contains(last.startupStep))

            await run.probe.release(last)
            guard await expect([run.probe.signals.returned]) else { return }
            assertSuccess(await run.task.value)
            assertDrained(await run.probe.snapshot(), cancelled: [])
            XCTAssertEqual(progress.snapshot.completed, [.tokenizer, .imageModel, .textModel])
            let report = try XCTUnwrap(timing.finish(.ready))
            assertReport(report, outcome: .ready, wall: [0, 0, 0], offsets: [0, 0, 0],
                         components: [0, 0, 0], statuses: [.completed, .completed, .completed])
        }
    }

    func testFailureCancelsAndDrainsBothSiblingKindsAndPreservesOriginalError() async throws {
        // Each sibling is held last once. Cancellation observation does not
        // release either its cooperative cleanup gate or the noncooperative gate.
        for last in [PMPreparationBranch.image, .text] {
            let clock = PMPreparationClock()
            let timing = LaunchTimingRecorder(kind: .retry, now: { clock.now() })
            let progress = StartupProgressRecorder()
            let original = PMPreparationFailure()
            clock.set(101)
            let run = start(timing: timing, startupProgress: progress,
                            tokenizerFailure: original, cooperativeImage: true)
            guard await expect([run.probe.signals.allStarted]) else { return }
            assertAllStartedAndHeld(await run.probe.snapshot())
            XCTAssertEqual(progress.snapshot.completed, [])

            clock.set(104)
            await run.probe.release(.tokenizer)
            guard await expect([run.probe.signals.exited(.tokenizer),
                                run.probe.signals.imageCancelled]) else { return }
            let cancelling = await run.probe.snapshot()
            XCTAssertEqual(cancelling.exited, [.tokenizer])
            XCTAssertEqual(cancelling.released, [.tokenizer])
            XCTAssertNil(cancelling.exitedAtReturn)
            XCTAssertEqual(progress.snapshot.completed, [], "A thrown branch is not a completed requirement.")

            clock.set(110)
            let first: PMPreparationBranch = last == .image ? .text : .image
            await run.probe.release(first)
            guard await expect([run.probe.signals.exited(first)]) else { return }
            let draining = await run.probe.snapshot()
            XCTAssertEqual(draining.exited, Set([.tokenizer, first]))
            XCTAssertFalse(draining.released.contains(last))
            XCTAssertNil(draining.exitedAtReturn, "A cancellation request is not a completed drain.")

            await run.probe.release(last)
            guard await expect([run.probe.signals.returned]) else { return }
            assertFailure(await run.task.value, identicalTo: original)
            let finished = await run.probe.snapshot()
            assertDrained(finished, cancelled: [.image, .text])
            XCTAssertEqual(progress.snapshot.completed, [],
                           "Neither a failed branch nor cancelled siblings may advance progress.")
            assertBefore(.exited(.tokenizer, false), .imageCancelled, in: finished)
            assertBefore(.imageCancelled, .exited(.image, true), in: finished)

            clock.set(112)
            let report = try XCTUnwrap(timing.finish(.failed))
            assertReport(report, outcome: .failed, wall: [1, 9, 2],
                         components: [3, 9, 9], statuses: [.failed, .interrupted, .interrupted])
            XCTAssertNil(timing.finish(.ready))
        }
    }

    func testExternalCancellationDrainsNoncooperativeBranchesAndCooperativeCleanup() async throws {
        let clock = PMPreparationClock()
        let timing = LaunchTimingRecorder(kind: .foreground, now: { clock.now() })
        let progress = StartupProgressRecorder()
        clock.set(101)
        let run = start(timing: timing, startupProgress: progress, cooperativeImage: true)
        guard await expect([run.probe.signals.allStarted]) else { return }
        assertAllStartedAndHeld(await run.probe.snapshot())
        XCTAssertEqual(progress.snapshot.completed, [])

        clock.set(104)
        run.task.cancel()
        guard await expect([run.probe.signals.imageCancelled]) else { return }
        let cancelling = await run.probe.snapshot()
        XCTAssertTrue(cancelling.exited.isEmpty)
        XCTAssertTrue(cancelling.released.isEmpty)
        XCTAssertNil(cancelling.exitedAtReturn)

        clock.set(110)
        for branch in [PMPreparationBranch.tokenizer, .text] {
            await run.probe.release(branch)
            guard await expect([run.probe.signals.exited(branch)]) else { return }
            let draining = await run.probe.snapshot()
            XCTAssertFalse(draining.exited.contains(.image))
            XCTAssertNil(draining.exitedAtReturn)
        }
        await run.probe.release(.image)
        guard await expect([run.probe.signals.returned]) else { return }
        assertCancellation(await run.task.value)
        assertDrained(await run.probe.snapshot(), cancelled: Set(PMPreparationBranch.allCases))
        XCTAssertEqual(progress.snapshot.completed, [],
                       "Even a noncooperative late normal return must fail the post-work cancellation check.")

        clock.set(112)
        let report = try XCTUnwrap(timing.finish(.interrupted))
        assertReport(report, outcome: .interrupted, wall: [1, 9, 2],
                     components: [9, 9, 9], statuses: [.interrupted, .interrupted, .interrupted])
        XCTAssertNil(timing.finish(.ready))
    }

    func testCancellationBeforeEntryInvokesNoBranchesWithOrWithoutTiming() async throws {
        for recordsTiming in [true, false] {
            let clock = PMPreparationClock()
            let timing: LaunchTimingRecorder? = recordsTiming
                ? LaunchTimingRecorder(kind: .cold, now: { clock.now() }) : nil
            let progress = StartupProgressRecorder()
            clock.set(101)
            // Self-cancel inside the owned task, before load(), avoiding a race
            // between scheduling the task and cancelling it from the test.
            let run = start(timing: timing, startupProgress: progress, cancelledBeforeEntry: true)
            guard await expect([run.probe.signals.returned]) else { return }
            assertCancellation(await run.task.value)
            XCTAssertEqual(progress.snapshot.completed, [])
            let state = await run.probe.snapshot()
            XCTAssertTrue(state.started.isEmpty)
            XCTAssertTrue(state.released.isEmpty)
            XCTAssertTrue(state.exited.isEmpty)
            XCTAssertEqual(state.events, [.returned])
            XCTAssertEqual(state.exitedAtReturn, Set<PMPreparationBranch>())
            if let timing {
                XCTAssertEqual(clock.readCount, 1, "Pre-cancelled entry must not mark or begin a span.")
                let report = try XCTUnwrap(timing.finish(.interrupted))
                XCTAssertEqual(report.outcome, .interrupted)
                XCTAssertEqual(report.rows.map(\.stage), [.entry])
                XCTAssertEqual(report.rows.map(\.seconds), [1])
                XCTAssertEqual(report.totalSeconds, 1)
                XCTAssertTrue(report.components.isEmpty)
            }
        }
    }

    func testFreezingCancelledOldAttemptLeavesSharedLikeTaskRunningAndIgnoresLateCallbacks() async throws {
        let clock = PMPreparationClock()
        let oldProgress = StartupProgressRecorder()
        let sharedProgress = StartupProgressRecorder()
        let timing = LaunchTimingRecorder(kind: .cold, now: { clock.now() }, startupProgress: oldProgress)
        let oldObserver = sharedProgress.observe { oldProgress.complete($0.completed) }
        defer { sharedProgress.removeObserver(oldObserver) }
        clock.set(101)
        let run = start(timing: timing, startupProgress: sharedProgress)
        // Synthetic owned backing task + old waiter, not CoreMLEncoders.loadingTask
        // or a proof of the production multi-waiter cancellation policy.
        let oldWaiter = Task { () -> Result<PMPreparationValues, Error> in
            let result = await run.task.value
            do {
                try Task.checkCancellation()
                return result
            } catch { return .failure(error) }
        }
        addTeardownBlock {
            // Teardown blocks run LIFO: open backing gates BEFORE joining this
            // waiter, including when an expectation or XCTUnwrap fails early.
            oldWaiter.cancel()
            await run.cleanup()
            _ = await oldWaiter.value
        }
        guard await expect([run.probe.signals.allStarted]) else { return }
        assertAllStartedAndHeld(await run.probe.snapshot())
        XCTAssertEqual(sharedProgress.snapshot.completed, [])

        oldWaiter.cancel()
        clock.set(105)
        let frozen = try XCTUnwrap(timing.finish(.interrupted))
        let frozenProgress = oldProgress.freeze()
        let readsAtFreeze = clock.readCount
        XCTAssertFalse(run.task.isCancelled)
        clock.set(200)
        let advanced = expectation(description: "Shared branches publish after old timing and display freeze")
        advanced.assertForOverFulfill = true
        let progressObserver = sharedProgress.observe { snapshot in
            if snapshot.completed == [.imageModel, .textModel] { advanced.fulfill() }
        }
        defer { sharedProgress.removeObserver(progressObserver) }
        for branch in [PMPreparationBranch.image, .text] { await run.probe.release(branch) }
        guard await expect([run.probe.signals.exited(.image), run.probe.signals.exited(.text), advanced]) else { return }
        let stillRunning = await run.probe.snapshot()
        XCTAssertEqual(stillRunning.exited, [.image, .text])
        XCTAssertNil(stillRunning.exitedAtReturn)
        XCTAssertFalse(run.task.isCancelled)
        XCTAssertEqual(sharedProgress.snapshot.completed, [.imageModel, .textModel])
        XCTAssertEqual(oldProgress.snapshot, frozenProgress)
        XCTAssertEqual(frozenProgress.completed, [])

        let laterProgress = StartupProgressRecorder()
        let laterObserver = sharedProgress.observe { laterProgress.complete($0.completed) }
        defer { sharedProgress.removeObserver(laterObserver) }
        XCTAssertEqual(laterProgress.snapshot.completed, [.imageModel, .textModel],
                       "A later waiter replays actual completed work before the last branch returns.")
        sharedProgress.complete(.imageModel)
        XCTAssertEqual(laterProgress.snapshot.fraction, 2.0 / 9.0)

        await run.probe.release(.tokenizer)
        guard await expect([run.probe.signals.returned]) else { return }
        assertSuccess(await run.task.value)
        assertCancellation(await oldWaiter.value)
        assertDrained(await run.probe.snapshot(), cancelled: [])
        XCTAssertEqual(sharedProgress.snapshot.completed, [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(laterProgress.snapshot, sharedProgress.snapshot)
        XCTAssertEqual(oldProgress.snapshot, frozenProgress)
        // The backing producer ends its own channel only after actual work.
        // Ending it must not freeze a launch owner's independent requirements.
        let sharedFrozen = sharedProgress.freeze()
        laterProgress.complete(.entry)
        XCTAssertEqual(laterProgress.snapshot.completed, [.entry, .tokenizer, .imageModel, .textModel])
        XCTAssertEqual(sharedProgress.snapshot, sharedFrozen)
        // Real measured() end callbacks and the helper's deferred assembly mark
        // have now happened, but must not even consult the old recorder's clock.
        XCTAssertEqual(clock.readCount, readsAtFreeze)
        XCTAssertNil(timing.finish(.ready))
        XCTAssertNil(timing.beginComponent(.imageModel))
        timing.mark(.publish)
        XCTAssertEqual(clock.readCount, readsAtFreeze)
        XCTAssertEqual(frozen.id, timing.id)
        XCTAssertEqual(frozen.outcome, .interrupted)
        XCTAssertEqual(frozen.rows.map(\.stage), [.entry, .parallelModels])
        XCTAssertEqual(frozen.rows.map(\.seconds), [1, 4])
        XCTAssertEqual(frozen.totalSeconds, 5)
        XCTAssertEqual(frozen.components.map(\.stage), [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(frozen.components.map(\.startOffsetSeconds), [1, 1, 1])
        XCTAssertEqual(frozen.components.map(\.seconds), [4, 4, 4])
        XCTAssertEqual(frozen.components.map(\.outcome), [.interrupted, .interrupted, .interrupted])
    }

    func testNilTimingStillStartsAllBranchesAndWaitsForTheLastResult() async {
        let progress = StartupProgressRecorder()
        let run = start(timing: nil, startupProgress: progress)
        guard await expect([run.probe.signals.allStarted]) else { return }
        assertAllStartedAndHeld(await run.probe.snapshot())
        XCTAssertEqual(progress.snapshot.completed, [])
        await run.probe.release(.text)
        await run.probe.release(.image)
        guard await expect([run.probe.signals.exited(.text), run.probe.signals.exited(.image)]) else { return }
        let held = await run.probe.snapshot()
        XCTAssertEqual(held.exited, [.image, .text])
        XCTAssertNil(held.exitedAtReturn)
        await run.probe.release(.tokenizer)
        guard await expect([run.probe.signals.returned]) else { return }
        assertSuccess(await run.task.value)
        assertDrained(await run.probe.snapshot(), cancelled: [])
        XCTAssertEqual(progress.snapshot.completed, [.tokenizer, .imageModel, .textModel],
                       "Step completion must not depend on a timing recorder or component token.")
    }

    private func start(timing: LaunchTimingRecorder?, startupProgress: StartupProgressRecorder? = nil,
                       tokenizerFailure: PMPreparationFailure? = nil,
                       cooperativeImage: Bool = false, cancelledBeforeEntry: Bool = false) -> PMPreparationRun {
        let probe = PMPreparationProbe()
        let cancellation = PMPreparationCancellation()
        let task = Task { () -> Result<PMPreparationValues, Error> in
            if cancelledBeforeEntry { withUnsafeCurrentTask { $0?.cancel() } }
            let result: Result<PMPreparationValues, Error>
            do {
                let values: PMPreparationValues = try await ParallelModelPreparation.load(
                    timing: timing,
                    startupProgress: startupProgress,
                    tokenizer: {
                        defer {
                            XCTAssertFalse(startupProgress?.snapshot.completed.contains(.tokenizer) ?? false,
                                           "Tokenizer must not be complete before its work returns successfully.")
                        }
                        await probe.arriveAndWait(.tokenizer)
                        await probe.exit(.tokenizer, cancelled: Task.isCancelled)
                        if let tokenizerFailure { throw tokenizerFailure }
                        return "TEST-tokenizer"
                    },
                    image: {
                        defer {
                            XCTAssertFalse(startupProgress?.snapshot.completed.contains(.imageModel) ?? false,
                                           "Image must not be complete before its work returns successfully.")
                        }
                        if cooperativeImage {
                            await probe.arrive(.image)
                            let wasCancelled = await cancellation.wait()
                            if wasCancelled { await probe.imageCancellationObserved() }
                            await probe.waitForRelease(.image)
                            await probe.exit(.image, cancelled: Task.isCancelled)
                            if wasCancelled { throw CancellationError() }
                        } else {
                            await probe.arriveAndWait(.image)
                            await probe.exit(.image, cancelled: Task.isCancelled)
                        }
                        return 42
                    },
                    text: {
                        defer {
                            XCTAssertFalse(startupProgress?.snapshot.completed.contains(.textModel) ?? false,
                                           "Text must not be complete before its work returns successfully.")
                        }
                        // Intentionally ignores cancellation while the gate is
                        // closed, then returns normally. measured() must reject
                        // this late value and mark the component interrupted.
                        await probe.arriveAndWait(.text)
                        await probe.exit(.text, cancelled: Task.isCancelled)
                        return true
                    })
                result = .success(values)
            } catch { result = .failure(error) }
            await probe.helperReturned()
            return result
        }
        let run = PMPreparationRun(probe: probe, cancellation: cancellation, task: task)
        addTeardownBlock { await run.cleanup() }
        return run
    }

    private func expect(_ expectations: [XCTestExpectation],
                        file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        // Positive event timeout is only a test-failure escape, not a latency
        // assertion. No inverted expectations or elapsed-time comparisons.
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: 5)
        XCTAssertEqual(result, .completed, "Expected deterministic event was not reached.", file: file, line: line)
        return result == .completed
    }

    private func assertAllStartedAndHeld(_ state: PMPreparationSnapshot,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.started, Set(PMPreparationBranch.allCases), file: file, line: line)
        XCTAssertEqual(state.events.count, 3, file: file, line: line)
        XCTAssertTrue(state.released.isEmpty, file: file, line: line)
        XCTAssertTrue(state.exited.isEmpty, file: file, line: line)
        XCTAssertNil(state.exitedAtReturn, file: file, line: line)
    }

    private func assertDrained(_ state: PMPreparationSnapshot, cancelled: Set<PMPreparationBranch>,
                               file: StaticString = #filePath, line: UInt = #line) {
        let all = Set(PMPreparationBranch.allCases)
        XCTAssertEqual(state.started, all, file: file, line: line)
        XCTAssertEqual(state.released, all, file: file, line: line)
        XCTAssertEqual(state.exited, all, file: file, line: line)
        XCTAssertEqual(state.exitedAtReturn, all, "Every branch must exit before helper return.", file: file, line: line)
        XCTAssertEqual(state.events.last, .returned, file: file, line: line)
        for branch in PMPreparationBranch.allCases {
            let exit = PMPreparationEvent.exited(branch, cancelled.contains(branch))
            XCTAssertEqual(state.events.filter { $0 == .started(branch) }.count, 1, file: file, line: line)
            XCTAssertEqual(state.events.filter { $0 == exit }.count, 1, file: file, line: line)
            assertBefore(.released(branch), exit, in: state, file: file, line: line)
            assertBefore(exit, .returned, in: state, file: file, line: line)
            for released in PMPreparationBranch.allCases {
                assertBefore(.started(branch), .released(released), in: state, file: file, line: line)
            }
        }
    }

    private func assertBefore(_ first: PMPreparationEvent, _ second: PMPreparationEvent,
                              in state: PMPreparationSnapshot,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let a = state.events.firstIndex(of: first), let b = state.events.firstIndex(of: second) else {
            XCTFail("Required lifecycle event is missing.", file: file, line: line)
            return
        }
        XCTAssertLessThan(a, b, file: file, line: line)
    }

    private func assertSuccess(_ result: Result<PMPreparationValues, Error>,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let values) = result else {
            XCTFail("Expected successful preparation.", file: file, line: line)
            return
        }
        XCTAssertEqual(values.tokenizer, "TEST-tokenizer", file: file, line: line)
        XCTAssertEqual(values.image, 42, file: file, line: line)
        XCTAssertTrue(values.text, file: file, line: line)
    }

    private func assertFailure(_ result: Result<PMPreparationValues, Error>, identicalTo expected: PMPreparationFailure,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            XCTFail("Expected the original branch failure.", file: file, line: line)
            return
        }
        XCTAssertTrue((error as? PMPreparationFailure) === expected,
                      "Sibling cancellation must not replace or wrap the original error.", file: file, line: line)
    }

    private func assertCancellation(_ result: Result<PMPreparationValues, Error>,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else {
            XCTFail("Cancelled preparation must not return readiness.", file: file, line: line)
            return
        }
        XCTAssertTrue(error is CancellationError, file: file, line: line)
    }

    private func assertReport(_ report: LaunchTimingReport, outcome: LaunchTimingOutcome,
                              wall: [Double], offsets: [Double] = [1, 1, 1], components: [Double],
                              statuses: [LaunchTimingComponentOutcome],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(report.outcome, outcome, file: file, line: line)
        XCTAssertEqual(report.rows.map(\.id), [0, 1, 2], file: file, line: line)
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .parallelModels, .modelAssembly], file: file, line: line)
        XCTAssertEqual(report.rows.map(\.seconds), wall, file: file, line: line)
        XCTAssertEqual(report.totalSeconds, wall.reduce(0, +), file: file, line: line)
        XCTAssertEqual(report.rows.reduce(0) { $0 + $1.seconds }, report.totalSeconds, file: file, line: line)
        XCTAssertEqual(report.components.map(\.stage), [.tokenizer, .imageModel, .textModel], file: file, line: line)
        XCTAssertEqual(Set(report.components.map(\.id)).count, 3, file: file, line: line)
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), offsets, file: file, line: line)
        XCTAssertEqual(report.components.map(\.seconds), components, file: file, line: line)
        XCTAssertEqual(report.components.map(\.outcome), statuses, file: file, line: line)
    }
}

private typealias PMPreparationValues = (tokenizer: String, image: Int, text: Bool)

private enum PMPreparationBranch: CaseIterable, Hashable, Sendable {
    case tokenizer, image, text

    var startupStep: StartupStep {
        switch self {
        case .tokenizer: return .tokenizer
        case .image: return .imageModel
        case .text: return .textModel
        }
    }
}

private enum PMPreparationEvent: Equatable, Sendable {
    case started(PMPreparationBranch)
    case released(PMPreparationBranch)
    case exited(PMPreparationBranch, Bool)
    case imageCancelled
    case returned
}

private struct PMPreparationSnapshot: Sendable {
    let events: [PMPreparationEvent]
    let started: Set<PMPreparationBranch>
    let released: Set<PMPreparationBranch>
    let exited: Set<PMPreparationBranch>
    let exitedAtReturn: Set<PMPreparationBranch>?
}

/// XCTest expectations support cross-thread fulfillment. The actor fulfills
/// each once; test code only waits for positive events, once per expectation.
private final class PMPreparationSignals: @unchecked Sendable {
    let allStarted = XCTestExpectation(description: "All three branch bodies entered")
    let imageCancelled = XCTestExpectation(description: "Image observed cooperative cancellation")
    let returned = XCTestExpectation(description: "Preparation helper returned after draining")
    private let tokenizerExited = XCTestExpectation(description: "Tokenizer body exited")
    private let imageExited = XCTestExpectation(description: "Image body exited")
    private let textExited = XCTestExpectation(description: "Text body exited")

    func exited(_ branch: PMPreparationBranch) -> XCTestExpectation {
        switch branch {
        case .tokenizer: return tokenizerExited
        case .image: return imageExited
        case .text: return textExited
        }
    }
}

/// Actor-owned, level-triggered gates: opening before a waiter arrives is safe.
/// Noncooperative waits deliberately do not install cancellation handlers.
private actor PMPreparationProbe {
    nonisolated let signals = PMPreparationSignals()
    private var events: [PMPreparationEvent] = []
    private var started: Set<PMPreparationBranch> = []
    private var released: Set<PMPreparationBranch> = []
    private var exited: Set<PMPreparationBranch> = []
    private var exitedAtReturn: Set<PMPreparationBranch>?
    private var waiters: [PMPreparationBranch: [CheckedContinuation<Void, Never>]] = [:]
    private var didObserveCancellation = false

    func arrive(_ branch: PMPreparationBranch) {
        events.append(.started(branch))
        if started.insert(branch).inserted, started.count == PMPreparationBranch.allCases.count {
            signals.allStarted.fulfill()
        }
    }

    func arriveAndWait(_ branch: PMPreparationBranch) async {
        arrive(branch)
        await waitForRelease(branch)
    }

    func waitForRelease(_ branch: PMPreparationBranch) async {
        guard !released.contains(branch) else { return }
        await withCheckedContinuation { continuation in
            waiters[branch, default: []].append(continuation)
        }
    }

    func release(_ branch: PMPreparationBranch) {
        guard released.insert(branch).inserted else { return }
        events.append(.released(branch))
        let pending = waiters.removeValue(forKey: branch) ?? []
        for continuation in pending { continuation.resume() }
    }

    func releaseAll() {
        for branch in PMPreparationBranch.allCases { release(branch) }
    }

    func imageCancellationObserved() {
        events.append(.imageCancelled)
        if !didObserveCancellation {
            didObserveCancellation = true
            signals.imageCancelled.fulfill()
        }
    }

    func exit(_ branch: PMPreparationBranch, cancelled: Bool) {
        events.append(.exited(branch, cancelled))
        if exited.insert(branch).inserted { signals.exited(branch).fulfill() }
    }

    func helperReturned() {
        exitedAtReturn = exited
        events.append(.returned)
        signals.returned.fulfill()
    }

    func snapshot() -> PMPreparationSnapshot {
        PMPreparationSnapshot(events: events, started: started, released: released,
                              exited: exited, exitedAtReturn: exitedAtReturn)
    }
}

/// The synchronous cancellation handler cannot await the actor. A small locked
/// continuation signal bridges that boundary without spawning a signaling Task.
/// Cancellation before registration is remembered; cleanup can also unblock it.
private final class PMPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func wait() async -> Bool {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let outcome {
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }, onCancel: { self.resolve(cancelled: true) })
    }

    func releaseForCleanup() { resolve(cancelled: false) }

    private func resolve(cancelled: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = cancelled
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: cancelled) }
    }
}

private struct PMPreparationRun: Sendable {
    let probe: PMPreparationProbe
    let cancellation: PMPreparationCancellation
    let task: Task<Result<PMPreparationValues, Error>, Never>

    func cleanup() async {
        task.cancel()
        cancellation.releaseForCleanup()
        await probe.releaseAll()
        _ = await task.value
    }
}

private final class PMPreparationFailure: Error, Sendable {}

private final class PMPreparationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Double = 100
    private var reads = 0

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return instant
    }

    func set(_ value: Double) {
        lock.lock()
        defer { lock.unlock() }
        instant = value
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }
}