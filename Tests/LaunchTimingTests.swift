import Dispatch
import Foundation
import XCTest
@testable import LocalImageIQ

/// Deterministic recorder tests: no wall-clock delays, models or Photos calls.
final class LaunchTimingTests: XCTestCase {
    func testMarksPartitionElapsedTimeWithoutOverlappingModelParentAndChildRows() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        let stages: [LaunchTimingStage] = [
            .entry, .queue, .worker, .places, .models, .resources,
            .tokenizer, .imageModel, .textModel, .counts, .publish
        ]
        let seconds: [Double] = [1, 2, 0.5, 0.25, 0.25, 1, 2, 4, 3, 0.5, 0.5]
        for index in stages.indices.dropFirst() {
            clock.advance(by: seconds[index - 1])
            recorder.mark(stages[index])
        }
        clock.advance(by: 0.5)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.id, recorder.id)
        XCTAssertEqual(report.kind, .cold)
        XCTAssertEqual(report.outcome, .ready)
        XCTAssertEqual(report.rows.map(\.stage), stages)
        XCTAssertEqual(report.rows.map(\.seconds), seconds)
        XCTAssertEqual(report.totalSeconds, 15)
        XCTAssertEqual(report.slowest?.stage, .imageModel)
        XCTAssertEqual(report.slowest?.seconds, 4)
        assertPartition(report)
    }

    func testRepeatedMarkOfCurrentStageDoesNotFragmentRowsOrReadClock() throws {
        let clock = LaunchTimingTestClock(20)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        clock.advance(by: 1)
        recorder.mark(.entry)
        XCTAssertEqual(clock.readCount, 1)
        clock.advance(by: 1)
        recorder.mark(.models)
        clock.advance(by: 2)
        recorder.mark(.models)
        recorder.mark(.models)
        XCTAssertEqual(clock.readCount, 2)
        clock.advance(by: 3)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .models])
        XCTAssertEqual(report.rows.map(\.seconds), [2, 5])
        XCTAssertEqual(report.totalSeconds, 7)
        XCTAssertEqual(clock.readCount, 3)
        assertPartition(report)
    }

    func testDistinctStagesAtSameInstantRetainZeroDurationRows() throws {
        let clock = LaunchTimingTestClock(42)
        let recorder = LaunchTimingRecorder(kind: .retry, now: { clock.now() })
        for stage in LaunchTimingStage.allCases { recorder.mark(stage) }

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.stage), LaunchTimingStage.allCases)
        XCTAssertEqual(report.rows.map(\.seconds), Array(repeating: 0, count: LaunchTimingStage.allCases.count))
        XCTAssertEqual(report.totalSeconds, 0)
        XCTAssertNotNil(report.slowest)
        XCTAssertEqual(report.slowest?.seconds, 0)
        assertPartition(report)
    }

    func testFinishWithoutMarksReturnsExactlyOnceForEveryKindAndOutcome() throws {
        let kinds: [LaunchTimingKind] = [.cold, .retry, .foreground]
        let outcomes: [LaunchTimingOutcome] = [.ready, .failed, .interrupted]
        var identifiers = Set<UUID>()
        for kind in kinds {
            for outcome in outcomes {
                let clock = LaunchTimingTestClock(100)
                let recorder = LaunchTimingRecorder(kind: kind, now: { clock.now() })
                clock.advance(by: 2)
                let report = try XCTUnwrap(recorder.finish(outcome))
                XCTAssertTrue(identifiers.insert(report.id).inserted)
                XCTAssertEqual(report.id, recorder.id)
                XCTAssertEqual(report.kind, kind)
                XCTAssertEqual(report.outcome, outcome)
                XCTAssertEqual(report.rows.map(\.stage), [.entry])
                XCTAssertEqual(report.rows.map(\.seconds), [2])
                XCTAssertEqual(report.totalSeconds, 2)
                for laterOutcome in outcomes { XCTAssertNil(recorder.finish(laterOutcome)) }
                XCTAssertEqual(clock.readCount, 2, "Repeated finish must not consult a later clock value.")
                assertPartition(report)
            }
        }
    }

    func testInterruptedReportFreezesBeforeLateModelMarksAndCompletions() throws {
        let clock = LaunchTimingTestClock(50)
        let recorder = LaunchTimingRecorder(kind: .foreground, now: { clock.now() })
        clock.advance(by: 1)
        recorder.mark(.sharedModels)
        clock.advance(by: 3)
        let report = try XCTUnwrap(recorder.finish(.interrupted))
        let readsAtFinish = clock.readCount

        clock.advance(by: 100)
        for stage in LaunchTimingStage.allCases { recorder.mark(stage) }
        XCTAssertNil(recorder.finish(.ready))
        XCTAssertNil(recorder.finish(.failed))
        XCTAssertNil(recorder.finish(.interrupted))
        XCTAssertEqual(clock.readCount, readsAtFinish)
        XCTAssertEqual(report.kind, .foreground)
        XCTAssertEqual(report.outcome, .interrupted)
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .sharedModels])
        XCTAssertEqual(report.rows.map(\.seconds), [1, 3])
        XCTAssertEqual(report.totalSeconds, 4)
        assertPartition(report)
    }

    func testRegressingInjectedClockNeverProducesNegativeOrOverlappingRows() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        clock.set(101)
        recorder.mark(.queue)
        clock.set(99)
        recorder.mark(.worker)
        clock.set(104)
        recorder.mark(.models)
        clock.set(102)
        recorder.mark(.publish)
        clock.set(105)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .queue, .worker, .models, .publish])
        XCTAssertEqual(report.rows.map(\.seconds), [1, 0, 3, 0, 1])
        XCTAssertEqual(report.totalSeconds, 5)
        assertPartition(report)
    }

    func testFixedChineseLabelsAndDurationFormatting() {
        XCTAssertEqual(LaunchTimingStage.allCases.map(\.rawValue), [
            "入口与权限状态", "调度／等待前任务", "进入准备任务", "地点元数据（非地图）",
            "模型准备入口", "模型资源检查", "加载分词器", "加载图像模型", "加载文本模型",
            "等待已有模型任务", "复用已加载模型", "读取已存索引统计", "返回／发布就绪"
        ])
        XCTAssertEqual([LaunchTimingKind.cold, .retry, .foreground].map(\.rawValue),
                       ["本进程首次启动", "手动重试", "中断后恢复"])
        XCTAssertEqual([LaunchTimingOutcome.ready, .failed, .interrupted].map(\.rawValue),
                       ["准备完成", "准备失败", "准备中断"])
        XCTAssertEqual(LaunchTimingReport.duration(0), "0.000 秒")
        XCTAssertEqual(LaunchTimingReport.duration(1.25), "1.250 秒")
    }

    func testConcurrentMarksAndFinishProduceOneFrozenPartition() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        let reports = LaunchTimingTestReports()
        let stages = LaunchTimingStage.allCases
        // Both mutable test fixtures are independently locked. No assertions or
        // unsynchronized captured-array writes occur on concurrent worker queues.
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            clock.advance(by: 1)
            recorder.mark(stages[index % stages.count])
            if let report = recorder.finish(index.isMultiple(of: 2) ? .ready : .interrupted) {
                reports.append(report)
            }
        }

        let completed = reports.values
        XCTAssertEqual(completed.count, 1)
        let report = try XCTUnwrap(completed.first)
        XCTAssertEqual(report.id, recorder.id)
        XCTAssertEqual(report.kind, .cold)
        XCTAssertTrue([LaunchTimingOutcome.ready, .interrupted].contains(report.outcome))
        XCTAssertGreaterThanOrEqual(report.totalSeconds, 1)
        XCTAssertLessThanOrEqual(report.totalSeconds, 128)
        assertPartition(report)
        let readsAtFinish = clock.readCount
        recorder.mark(.publish)
        XCTAssertNil(recorder.finish(.failed))
        XCTAssertEqual(clock.readCount, readsAtFinish)
    }

    private func assertPartition(_ report: LaunchTimingReport,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.rows.isEmpty, file: file, line: line)
        XCTAssertEqual(report.rows.map(\.id), Array(report.rows.indices), file: file, line: line)
        XCTAssertTrue(report.rows.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }, file: file, line: line)
        XCTAssertEqual(report.rows.reduce(0) { $0 + $1.seconds }, report.totalSeconds, file: file, line: line)
    }
}

/// Shared only by these scoped tests. The @Sendable clock closure captures this
/// lock-protected reference, never a mutable local Double.
final class LaunchTimingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Double
    private var reads = 0

    init(_ instant: Double) { self.instant = instant }

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        return instant
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func advance(by seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        instant += seconds
    }

    func set(_ instant: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.instant = instant
    }
}

private final class LaunchTimingTestReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [LaunchTimingReport] = []

    var values: [LaunchTimingReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    func append(_ report: LaunchTimingReport) {
        lock.lock()
        defer { lock.unlock() }
        reports.append(report)
    }
}