import Dispatch
import Foundation
import XCTest
@testable import LocalImageIQ

/// No clocks, sleeps, polling, models or Photos. Potentially reentrant operations
/// run off the XCTest thread and use only XCTest's bounded completion timeout.
final class StartupProgressTests: XCTestCase {
    func testExactlyNineDistinctRequirementsAndFixedChineseLabels() {
        XCTAssertEqual(StartupStep.allCases, [
            .entry, .places, .resources, .tokenizer, .imageModel, .textModel, .assembly, .counts, .ready
        ])
        XCTAssertEqual(StartupStep.allCases.map(\.rawValue), [
            "入口与权限状态", "地点元数据", "模型资源检查", "分词器就绪", "图像模型就绪",
            "文本模型就绪", "模型组装完成", "索引统计完成", "启动就绪"
        ])
        XCTAssertEqual(Set(StartupStep.allCases.map(\.rawValue)).count, 9)
        XCTAssertEqual(StartupStep.modelSteps, [.resources, .tokenizer, .imageModel, .textModel, .assembly])
    }

    func testFractionIsOnlyCompletedCountOverNine() {
        let recorder = StartupProgressRecorder()
        var expected: Set<StartupStep> = []
        XCTAssertEqual(recorder.snapshot, StartupProgressSnapshot(completed: []))
        XCTAssertEqual(recorder.snapshot.fraction, 0)
        for step in StartupStep.allCases {
            recorder.complete(step)
            expected.insert(step)
            XCTAssertEqual(recorder.snapshot.completed, expected)
            XCTAssertEqual(recorder.snapshot.fraction, Double(expected.count) / 9.0)
            recorder.complete(step)
            XCTAssertEqual(recorder.snapshot.completed, expected)
        }
        XCTAssertEqual(recorder.snapshot.fraction, 1)
    }

    func testReadyAndModelCompletionNeverInventOtherCompletedRequirements() {
        let readyOnly = StartupProgressRecorder()
        readyOnly.complete(.ready)
        XCTAssertEqual(readyOnly.snapshot.completed, [.ready])
        XCTAssertEqual(readyOnly.snapshot.fraction, 1.0 / 9.0)

        let modelsOnly = StartupProgressRecorder()
        modelsOnly.complete(StartupStep.modelSteps)
        XCTAssertEqual(modelsOnly.snapshot.completed, StartupStep.modelSteps)
        XCTAssertEqual(modelsOnly.snapshot.fraction, 5.0 / 9.0)
        XCTAssertFalse(modelsOnly.snapshot.completed.contains(.ready))
    }

    func testBatchNotifiesOnceAndDuplicatesAndEmptyBatchesAreSilent() {
        let recorder = StartupProgressRecorder()
        let log = StartupProgressTestValues<StartupProgressSnapshot>()
        let id = recorder.observe { log.append($0) }
        recorder.complete([])
        recorder.complete([.resources, .tokenizer])
        recorder.complete(.resources)
        recorder.complete([.resources, .tokenizer])
        recorder.complete([.tokenizer, .imageModel])
        recorder.complete([])
        recorder.removeObserver(id)

        XCTAssertEqual(log.values.map(\.completed), [[], [.resources, .tokenizer], [.resources, .tokenizer, .imageModel]])
    }

    func testRegistrationSynchronouslyReplaysEmptyAndExistingProgress() {
        let recorder = StartupProgressRecorder()
        let first = StartupProgressTestValues<StartupProgressSnapshot>()
        let second = StartupProgressTestValues<StartupProgressSnapshot>()
        let firstID = recorder.observe { first.append($0) }
        XCTAssertEqual(first.values, [StartupProgressSnapshot(completed: [])])
        recorder.complete([.entry, .places])
        let secondID = recorder.observe { second.append($0) }
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(second.values, [StartupProgressSnapshot(completed: [.entry, .places])])
        recorder.removeObserver(firstID)
        recorder.removeObserver(secondID)
    }

    func testObserverRemovalIsIdempotentAndDoesNotCancelOtherWaiters() {
        let recorder = StartupProgressRecorder()
        let cancelled = StartupProgressTestValues<StartupProgressSnapshot>()
        let active = StartupProgressTestValues<StartupProgressSnapshot>()
        let cancelledID = recorder.observe { cancelled.append($0) }
        let activeID = recorder.observe { active.append($0) }
        recorder.complete(.resources)
        recorder.removeObserver(cancelledID)
        recorder.removeObserver(cancelledID)
        recorder.removeObserver(UUID())
        recorder.complete(StartupStep.modelSteps)
        recorder.removeObserver(activeID)

        XCTAssertEqual(cancelled.values.map(\.completed), [[], [.resources]])
        XCTAssertEqual(active.values.map(\.completed), [[], [.resources], StartupStep.modelSteps])
        XCTAssertEqual(recorder.snapshot.completed, StartupStep.modelSteps)
    }

    func testFreezeIsSilentIdempotentAndCannotFakeReady() {
        let recorder = StartupProgressRecorder()
        let log = StartupProgressTestValues<StartupProgressSnapshot>()
        _ = recorder.observe { log.append($0) }
        recorder.complete([.entry, .resources])
        let frozen = recorder.freeze()
        let before = log.values
        for step in StartupStep.allCases { recorder.complete(step) }
        recorder.complete(Set(StartupStep.allCases))

        XCTAssertEqual(recorder.freeze(), frozen)
        XCTAssertEqual(recorder.snapshot, frozen)
        XCTAssertEqual(frozen.completed, [.entry, .resources])
        XCTAssertEqual(log.values, before)
        XCTAssertFalse(frozen.completed.contains(.ready))
    }

    func testObservationAfterFreezeReplaysFrozenSnapshotOnce() {
        let recorder = StartupProgressRecorder()
        recorder.complete(.tokenizer)
        let frozen = recorder.freeze()
        let log = StartupProgressTestValues<StartupProgressSnapshot>()
        let id = recorder.observe { log.append($0) }
        XCTAssertEqual(log.values, [frozen])
        recorder.complete(Set(StartupStep.allCases))
        recorder.freeze()
        recorder.removeObserver(id)
        XCTAssertEqual(log.values, [frozen])
    }

    func testConcurrentDuplicateCompletionsEmitEachDistinctCountExactlyOnce() async {
        let recorder = StartupProgressRecorder()
        let log = StartupProgressTestValues<StartupProgressSnapshot>()
        let id = recorder.observe { log.append($0) }
        guard await runConcurrently({
            DispatchQueue.concurrentPerform(iterations: 288) { index in
                recorder.complete(StartupStep.allCases[index % 9])
            }
        }) else { return }
        recorder.removeObserver(id)

        let values = log.values
        XCTAssertEqual(recorder.snapshot.completed, Set(StartupStep.allCases))
        XCTAssertEqual(values.count, 10, "One replay plus nine actual changes; duplicate completion is silent.")
        XCTAssertEqual(values.map { $0.completed.count }.sorted(), Array(0...9))
        XCTAssertEqual(values.reduce(into: Set<StartupStep>()) { $0.formUnion($1.completed) }, Set(StartupStep.allCases))
        for value in values { XCTAssertEqual(value.fraction, Double(value.completed.count) / 9.0) }
        // Deliberately do not assert delivery order across completion threads.
    }

    func testConcurrentRegistrationAndCompletionDoNotLoseCompletedRequirements() async {
        let recorder = StartupProgressRecorder()
        let logs = (0..<36).map { _ in StartupProgressTestValues<StartupProgressSnapshot>() }
        let ids = StartupProgressTestValues<UUID>()
        guard await runConcurrently({
            DispatchQueue.concurrentPerform(iterations: logs.count) { index in
                let log = logs[index]
                ids.append(recorder.observe { log.append($0) })
                recorder.complete(StartupStep.allCases[index % 9])
            }
        }) else { return }
        for id in ids.values { recorder.removeObserver(id) }

        XCTAssertEqual(Set(ids.values).count, logs.count)
        for log in logs {
            let union = log.values.reduce(into: Set<StartupStep>()) { $0.formUnion($1.completed) }
            XCTAssertEqual(union, Set(StartupStep.allCases), "Registration plus replay must close the subscription gap.")
        }
    }

    func testConcurrentCompletionAndFreezeShareOneImmutableFinalSet() async {
        let recorder = StartupProgressRecorder()
        let frozen = StartupProgressTestValues<StartupProgressSnapshot>()
        let delivered = StartupProgressTestValues<StartupProgressSnapshot>()
        _ = recorder.observe { delivered.append($0) }
        recorder.complete(.entry)
        guard await runConcurrently({
            DispatchQueue.concurrentPerform(iterations: 144) { index in
                if index.isMultiple(of: 3) { frozen.append(recorder.freeze()) }
                else { recorder.complete(StartupStep.allCases[index % 9]) }
            }
        }) else { return }

        let final = recorder.snapshot
        XCTAssertEqual(frozen.values.count, 48)
        XCTAssertTrue(frozen.values.allSatisfy { $0 == final })
        XCTAssertTrue(delivered.values.allSatisfy { $0.completed.isSubset(of: final.completed) })
        let countAfterJoiningWorkers = delivered.values.count
        recorder.complete(Set(StartupStep.allCases))
        XCTAssertEqual(recorder.snapshot, final)
        XCTAssertEqual(delivered.values.count, countAfterJoiningWorkers)
    }

    func testReplayAndCompletionObserversMayReenterEveryRecorderOperation() async {
        let recorder = StartupProgressRecorder()
        let log = StartupProgressTestValues<StartupProgressSnapshot>()
        let nested = StartupProgressTestValues<StartupProgressSnapshot>()
        guard await runConcurrently({
            _ = recorder.observe { value in
                log.append(value)
                _ = recorder.snapshot
                if value.completed.isEmpty {
                    let nestedID = recorder.observe { nested.append($0) }
                    recorder.removeObserver(nestedID)
                    recorder.complete(.entry)
                } else {
                    recorder.freeze()
                }
            }
            recorder.complete(.ready)
        }) else { return }

        XCTAssertEqual(log.values.map(\.completed), [[], [.entry]])
        XCTAssertEqual(nested.values.map(\.completed), [[]])
        XCTAssertEqual(recorder.snapshot.completed, [.entry])
    }

    func testReentrantFreezeSuppressesNotYetAdmittedListenersInSameBroadcast() async {
        let recorder = StartupProgressRecorder()
        let changes = StartupProgressTestValues<StartupProgressSnapshot>()
        guard await runConcurrently({
            for _ in 0..<4 {
                _ = recorder.observe { value in
                    guard !value.completed.isEmpty else { return }
                    changes.append(value)
                    recorder.freeze()
                }
            }
            recorder.complete(.entry)
            recorder.complete(.ready)
        }) else { return }

        XCTAssertEqual(changes.values.map(\.completed), [[.entry]])
        XCTAssertEqual(recorder.snapshot.completed, [.entry])
    }

    func testReentrantRemovalSuppressesNotYetAdmittedListenersWithoutFreezingProducer() async {
        let recorder = StartupProgressRecorder()
        let ids = StartupProgressTestValues<UUID>()
        let changes = StartupProgressTestValues<StartupProgressSnapshot>()
        guard await runConcurrently({
            for _ in 0..<4 {
                ids.append(recorder.observe { value in
                    guard !value.completed.isEmpty else { return }
                    changes.append(value)
                    for id in ids.values { recorder.removeObserver(id) }
                })
            }
            recorder.complete(.resources)
            recorder.complete(StartupStep.modelSteps)
        }) else { return }

        XCTAssertEqual(changes.values.map(\.completed), [[.resources]])
        XCTAssertEqual(recorder.snapshot.completed, StartupStep.modelSteps)
    }

    func testFrozenOldAttemptDoesNotCancelSharedModelProgressAndNewWaiterReplays() {
        let shared = StartupProgressRecorder()
        let oldAttempt = StartupProgressRecorder()
        let oldID = shared.observe { oldAttempt.complete($0.completed) }
        oldAttempt.complete(.entry)
        shared.complete([.resources, .tokenizer])
        let oldFrozen = oldAttempt.freeze()
        // Even a late shared notification cannot mutate the frozen old attempt.
        shared.complete(.imageModel)
        shared.removeObserver(oldID)

        let newAttempt = StartupProgressRecorder()
        newAttempt.complete(.entry)
        let newID = shared.observe { newAttempt.complete($0.completed) }
        XCTAssertEqual(newAttempt.snapshot.completed, [.entry, .resources, .tokenizer, .imageModel])
        shared.complete([.textModel, .assembly])
        shared.removeObserver(newID)

        XCTAssertEqual(oldAttempt.snapshot, oldFrozen)
        XCTAssertEqual(oldFrozen.completed, [.entry, .resources, .tokenizer])
        XCTAssertEqual(shared.snapshot.completed, StartupStep.modelSteps)
        XCTAssertEqual(newAttempt.snapshot.completed, StartupStep.modelSteps.union([.entry]))
        XCTAssertFalse(newAttempt.snapshot.completed.contains(.ready))
    }

    private func runConcurrently(_ operation: @escaping @Sendable () -> Void) async -> Bool {
        let finished = expectation(description: "Concurrent/reentrant recorder operations returned")
        DispatchQueue(label: "StartupProgressTests.work", attributes: .concurrent).async {
            operation()
            finished.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(result, .completed, "A recorder lock must never be held while invoking a listener.")
        // Never touch the possibly deadlocked recorder on a timeout path.
        return result == .completed
    }
}

private final class StartupProgressTestValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}