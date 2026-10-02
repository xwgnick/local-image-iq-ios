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
        XCTAssertTrue(report.components.isEmpty, "Legacy sequential marks remain wall rows only.")
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
            "模型准备入口", "模型资源检查", "并行准备模型（总等待）",
            "加载分词器", "加载图像模型", "加载文本模型", "汇总模型并发布",
            "等待已有模型任务", "复用已加载模型", "读取已存索引统计", "返回／发布就绪"
        ])
        XCTAssertEqual(LaunchTimingStage.allCases.count, 15)
        XCTAssertEqual([LaunchTimingKind.cold, .retry, .foreground].map(\.rawValue),
                       ["本进程首次启动", "手动重试", "中断后恢复"])
        XCTAssertEqual([LaunchTimingOutcome.ready, .failed, .interrupted].map(\.rawValue),
                       ["准备完成", "准备失败", "准备中断"])
        XCTAssertEqual([LaunchTimingComponentOutcome.completed, .failed, .interrupted].map(\.rawValue),
                       ["完成", "失败", "中断"])
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

    func testParallelComponentsOverlapWithoutAdvancingWallPartition() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        recorder.mark(.parallelModels)
        let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        let text = try XCTUnwrap(recorder.beginComponent(.textModel))
        clock.advance(by: 4)
        recorder.endComponent(text, outcome: .completed)
        clock.advance(by: 2)
        recorder.endComponent(image, outcome: .completed)
        clock.advance(by: 2)
        recorder.endComponent(tokenizer, outcome: .completed)
        let reads = clock.readCount
        recorder.mark(.parallelModels)
        XCTAssertEqual(clock.readCount, reads, "Children must not change the current parent stage.")
        clock.advance(by: 2)
        recorder.mark(.modelAssembly)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .parallelModels, .modelAssembly])
        XCTAssertEqual(report.rows.map(\.seconds), [0, 10, 0])
        XCTAssertEqual(report.totalSeconds, 10)
        XCTAssertEqual(report.components.map(\.id), [tokenizer, image, text])
        XCTAssertEqual(report.components.map(\.stage), [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [0, 0, 0])
        XCTAssertEqual(report.components.map(\.seconds), [8, 6, 4])
        XCTAssertEqual(report.components.map(\.outcome), [.completed, .completed, .completed])
        XCTAssertEqual(report.components.reduce(0) { $0 + $1.seconds }, 18)
        XCTAssertEqual(report.slowest?.stage, .parallelModels)
        XCTAssertEqual(report.slowest?.seconds, 10)
        assertPartition(report)
    }

    func testComponentStartOffsetsAllowQueuesAndDrainingBeyondLongestBranch() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        clock.set(101)
        recorder.mark(.parallelModels)
        clock.set(103)
        let text = try XCTUnwrap(recorder.beginComponent(.textModel))
        clock.set(104)
        let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        clock.set(105)
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        clock.set(107)
        recorder.endComponent(text, outcome: .completed)
        clock.set(110)
        recorder.endComponent(tokenizer, outcome: .completed)
        clock.set(113)
        recorder.endComponent(image, outcome: .completed)
        clock.set(115)
        recorder.mark(.modelAssembly)
        clock.set(116)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.seconds), [1, 14, 1])
        XCTAssertEqual(report.totalSeconds, 16)
        XCTAssertEqual(report.components.map(\.id), [tokenizer, image, text])
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [4, 5, 3])
        XCTAssertEqual(report.components.map(\.seconds), [6, 8, 4])
        XCTAssertEqual(report.slowest?.stage, .parallelModels)
        XCTAssertEqual(report.slowest?.seconds, 14)
        XCTAssertEqual(report.components.map(\.seconds).max(), 8)
        assertPartition(report)
    }

    func testFailedFinishFreezesActiveComponentsAndIgnoresLateCallbacks() throws {
        let clock = LaunchTimingTestClock(50)
        let recorder = LaunchTimingRecorder(kind: .retry, now: { clock.now() })
        recorder.mark(.parallelModels)
        let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        let text = try XCTUnwrap(recorder.beginComponent(.textModel))
        clock.advance(by: 2)
        recorder.endComponent(tokenizer, outcome: .completed)
        clock.advance(by: 1)
        recorder.endComponent(image, outcome: .failed)
        clock.advance(by: 1)
        let report = try XCTUnwrap(recorder.finish(.failed))
        let readsAtFinish = clock.readCount

        clock.advance(by: 100)
        for id in [tokenizer, image, text] {
            recorder.endComponent(id, outcome: .completed)
            recorder.endComponent(id, outcome: .failed)
            recorder.endComponent(id, outcome: .interrupted)
        }
        recorder.endComponent(nil, outcome: .completed)
        recorder.endComponent(UUID(), outcome: .failed)
        for stage in LaunchTimingStage.allCases {
            XCTAssertNil(recorder.beginComponent(stage))
            recorder.mark(stage)
        }
        for outcome in [LaunchTimingOutcome.ready, .failed, .interrupted] {
            XCTAssertNil(recorder.finish(outcome))
        }
        XCTAssertEqual(clock.readCount, readsAtFinish)
        XCTAssertEqual(report.kind, .retry)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.totalSeconds, 4)
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .parallelModels])
        XCTAssertEqual(report.rows.map(\.seconds), [0, 4])
        XCTAssertEqual(report.components.map(\.id), [tokenizer, image, text])
        XCTAssertEqual(report.components.map(\.seconds), [2, 3, 4])
        XCTAssertEqual(report.components.map(\.outcome), [.completed, .failed, .interrupted])
        assertPartition(report)
    }

    func testEveryFinishOutcomeInterruptsOnlyUnfinishedComponents() throws {
        for outcome in [LaunchTimingOutcome.ready, .failed, .interrupted] {
            let clock = LaunchTimingTestClock(0)
            let recorder = LaunchTimingRecorder(kind: .foreground, now: { clock.now() })
            recorder.mark(.parallelModels)
            let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
            let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
            let text = try XCTUnwrap(recorder.beginComponent(.textModel))
            clock.advance(by: 1)
            recorder.endComponent(tokenizer, outcome: .completed)
            clock.advance(by: 1)
            recorder.endComponent(text, outcome: .interrupted)
            clock.advance(by: 1)

            let report = try XCTUnwrap(recorder.finish(outcome))
            XCTAssertEqual(report.outcome, outcome)
            XCTAssertEqual(report.components.map(\.id), [tokenizer, image, text])
            XCTAssertEqual(report.components.map(\.seconds), [1, 3, 2])
            XCTAssertEqual(report.components.map(\.outcome), [.completed, .interrupted, .interrupted])
            XCTAssertEqual(report.totalSeconds, 3)
            let readsAtFinish = clock.readCount
            recorder.endComponent(image, outcome: .completed)
            XCTAssertNil(recorder.finish(outcome))
            XCTAssertEqual(clock.readCount, readsAtFinish)
            assertPartition(report)
        }
    }

    func testOnlyModelBranchStagesCanBeginComponents() throws {
        let clock = LaunchTimingTestClock(20)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        let allowed: [LaunchTimingStage] = [.tokenizer, .imageModel, .textModel]
        for stage in LaunchTimingStage.allCases {
            let reads = clock.readCount
            if allowed.contains(stage) {
                XCTAssertNotNil(recorder.beginComponent(stage))
                XCTAssertEqual(clock.readCount, reads + 1)
            } else {
                XCTAssertNil(recorder.beginComponent(stage))
                XCTAssertEqual(clock.readCount, reads)
            }
        }
        let report = try XCTUnwrap(recorder.finish(.interrupted))
        XCTAssertEqual(report.rows.map(\.stage), [.entry])
        XCTAssertEqual(report.totalSeconds, 0)
        XCTAssertEqual(report.components.map(\.stage), allowed)
        XCTAssertEqual(report.components.map(\.outcome), [.interrupted, .interrupted, .interrupted])
        assertPartition(report)
    }

    func testNilUnknownAndRepeatedEndsAreNoOps() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        recorder.endComponent(nil, outcome: .failed)
        recorder.endComponent(UUID(), outcome: .completed)
        XCTAssertEqual(clock.readCount, 1)
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        clock.advance(by: 2)
        recorder.endComponent(image, outcome: .failed)
        let readsAtEnd = clock.readCount
        clock.advance(by: 5)
        recorder.endComponent(image, outcome: .completed)
        recorder.endComponent(image, outcome: .interrupted)
        recorder.endComponent(nil, outcome: .completed)
        recorder.endComponent(UUID(), outcome: .failed)
        XCTAssertEqual(clock.readCount, readsAtEnd)
        clock.advance(by: 1)

        let report = try XCTUnwrap(recorder.finish(.failed))
        XCTAssertEqual(report.rows.map(\.stage), [.entry])
        XCTAssertEqual(report.totalSeconds, 8)
        XCTAssertEqual(report.components.count, 1)
        let component = try XCTUnwrap(report.components.first)
        XCTAssertEqual(component.id, image)
        XCTAssertEqual(component.stage, .imageModel)
        XCTAssertEqual(component.startOffsetSeconds, 0)
        XCTAssertEqual(component.seconds, 2)
        XCTAssertEqual(component.outcome, .failed)
        assertPartition(report)
    }

    func testReportComponentOrderFollowsBranchesNotStartOrCompletionOrder() throws {
        let orders: [[LaunchTimingStage]] = [
            [.tokenizer, .imageModel, .textModel], [.tokenizer, .textModel, .imageModel],
            [.imageModel, .tokenizer, .textModel], [.imageModel, .textModel, .tokenizer],
            [.textModel, .tokenizer, .imageModel], [.textModel, .imageModel, .tokenizer]
        ]
        let expected: [LaunchTimingStage] = [.tokenizer, .imageModel, .textModel]
        for order in orders {
            let clock = LaunchTimingTestClock(100)
            let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
            var identifiers: [LaunchTimingStage: UUID] = [:]
            for stage in order { identifiers[stage] = try XCTUnwrap(recorder.beginComponent(stage)) }
            for stage in order.reversed() {
                clock.advance(by: 1)
                recorder.endComponent(identifiers[stage], outcome: .completed)
            }
            let report = try XCTUnwrap(recorder.finish(.ready))
            XCTAssertEqual(report.components.map(\.stage), expected)
            XCTAssertEqual(report.components.map(\.id), expected.compactMap { identifiers[$0] })
            XCTAssertEqual(report.components.map(\.outcome), [.completed, .completed, .completed])
            for (index, stage) in order.reversed().enumerated() {
                XCTAssertEqual(report.components.first(where: { $0.stage == stage })?.seconds, Double(index + 1))
            }
            assertPartition(report)
        }
    }

    func testRepeatedBranchComponentsKeepBeginOrderWithinTheirBranch() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        let first = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        clock.advance(by: 1)
        let second = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        clock.advance(by: 1)
        recorder.endComponent(second, outcome: .completed)
        clock.advance(by: 1)
        recorder.endComponent(first, outcome: .failed)
        recorder.endComponent(image, outcome: .completed)
        clock.advance(by: 1)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.components.map(\.id), [first, second, image])
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [0, 1, 1])
        XCTAssertEqual(report.components.map(\.seconds), [3, 1, 2])
        XCTAssertEqual(report.components.map(\.outcome), [.failed, .completed, .completed])
        XCTAssertEqual(report.totalSeconds, 4)
        assertPartition(report)
    }

    func testComponentsDoNotExtendAttemptWhenInjectedClockRegressesAtFinish() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        clock.set(101)
        recorder.mark(.parallelModels)
        clock.set(105)
        let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        clock.set(115)
        recorder.endComponent(tokenizer, outcome: .completed)
        clock.set(120)
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        clock.set(121)
        let text = try XCTUnwrap(recorder.beginComponent(.textModel))
        clock.set(125)
        recorder.endComponent(text, outcome: .completed)
        clock.set(110)

        let report = try XCTUnwrap(recorder.finish(.failed))
        XCTAssertEqual(report.totalSeconds, 10, "Child clock reads must not advance the parent's last boundary.")
        XCTAssertEqual(report.rows.map(\.seconds), [1, 9])
        XCTAssertEqual(report.components.map(\.id), [tokenizer, image, text])
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [5, 10, 10])
        XCTAssertEqual(report.components.map(\.seconds), [5, 0, 0])
        XCTAssertEqual(report.components.map(\.outcome), [.completed, .interrupted, .completed])
        assertPartition(report)
    }

    func testRegressingComponentClockClampsStartsAndDurationsWithoutMovingWallClock() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        clock.set(101)
        recorder.mark(.queue)
        clock.set(99)
        let tokenizer = try XCTUnwrap(recorder.beginComponent(.tokenizer))
        clock.set(98)
        recorder.endComponent(tokenizer, outcome: .completed)
        clock.set(103)
        let image = try XCTUnwrap(recorder.beginComponent(.imageModel))
        clock.set(102)
        recorder.endComponent(image, outcome: .completed)
        clock.set(104)
        let text = try XCTUnwrap(recorder.beginComponent(.textModel))
        clock.set(105)
        recorder.endComponent(text, outcome: .completed)
        clock.set(106)
        recorder.mark(.publish)
        clock.set(107)

        let report = try XCTUnwrap(recorder.finish(.ready))
        XCTAssertEqual(report.rows.map(\.stage), [.entry, .queue, .publish])
        XCTAssertEqual(report.rows.map(\.seconds), [1, 5, 1])
        XCTAssertEqual(report.totalSeconds, 7)
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [1, 3, 4])
        XCTAssertEqual(report.components.map(\.seconds), [0, 0, 1])
        assertPartition(report)
    }

    func testReportsDefaultToNoComponentsAndKeepSlowestInWallRows() {
        let rows = [LaunchTimingRow(id: 0, stage: .parallelModels, seconds: 2),
                    LaunchTimingRow(id: 1, stage: .modelAssembly, seconds: 1)]
        let legacy = LaunchTimingReport(id: UUID(), kind: .cold, outcome: .ready,
                                        totalSeconds: 3, rows: rows)
        XCTAssertTrue(legacy.components.isEmpty)
        let component = LaunchTimingComponent(id: UUID(), stage: .textModel,
                                              startOffsetSeconds: 0, seconds: 99, outcome: .completed)
        // Deliberately inconsistent fixture: slowest must never inspect children.
        let supplied = LaunchTimingReport(id: UUID(), kind: .retry, outcome: .ready,
                                          totalSeconds: 3, rows: rows, components: [component])
        XCTAssertEqual(supplied.totalSeconds, 3)
        XCTAssertEqual(supplied.components.first?.id, component.id)
        XCTAssertEqual(supplied.slowest?.stage, .parallelModels)
        XCTAssertEqual(supplied.slowest?.seconds, 2)
        let noRows = LaunchTimingReport(id: UUID(), kind: .retry, outcome: .failed,
                                        totalSeconds: 3, rows: [], components: [component])
        XCTAssertNil(noRows.slowest)
    }

    func testConcurrentComponentEndsAndFinishFreezeOneConsistentReport() throws {
        let clock = LaunchTimingTestClock(100)
        let recorder = LaunchTimingRecorder(kind: .cold, now: { clock.now() })
        recorder.mark(.parallelModels)
        let stages: [LaunchTimingStage] = [.tokenizer, .imageModel, .textModel]
        let identifiers = try stages.map { try XCTUnwrap(recorder.beginComponent($0)) }
        let reports = LaunchTimingTestReports()
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            clock.advance(by: 1)
            recorder.endComponent(identifiers[index % identifiers.count],
                                  outcome: index.isMultiple(of: 2) ? .completed : .failed)
            recorder.mark(.modelAssembly)
            if let report = recorder.finish(index.isMultiple(of: 2) ? .ready : .interrupted) {
                reports.append(report)
            }
        }

        XCTAssertEqual(reports.values.count, 1)
        let report = try XCTUnwrap(reports.values.first)
        XCTAssertEqual(report.components.map(\.id), identifiers)
        XCTAssertEqual(report.components.map(\.stage), stages)
        XCTAssertEqual(report.components.map(\.startOffsetSeconds), [0, 0, 0])
        XCTAssertGreaterThanOrEqual(report.totalSeconds, 1)
        XCTAssertLessThanOrEqual(report.totalSeconds, 128)
        assertPartition(report)
        let readsAtFinish = clock.readCount
        for id in identifiers { recorder.endComponent(id, outcome: .completed) }
        XCTAssertNil(recorder.beginComponent(.tokenizer))
        XCTAssertNil(recorder.finish(.failed))
        XCTAssertEqual(clock.readCount, readsAtFinish)
    }

    private func assertPartition(_ report: LaunchTimingReport,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.rows.isEmpty, file: file, line: line)
        XCTAssertEqual(report.rows.map(\.id), Array(report.rows.indices), file: file, line: line)
        XCTAssertTrue(report.rows.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }, file: file, line: line)
        XCTAssertEqual(report.rows.reduce(0) { $0 + $1.seconds }, report.totalSeconds, file: file, line: line)
        XCTAssertEqual(Set(report.components.map(\.id)).count, report.components.count, file: file, line: line)
        for component in report.components {
            XCTAssertTrue([LaunchTimingStage.tokenizer, .imageModel, .textModel].contains(component.stage),
                          file: file, line: line)
            XCTAssertTrue(component.startOffsetSeconds.isFinite && component.startOffsetSeconds >= 0,
                          file: file, line: line)
            XCTAssertTrue(component.seconds.isFinite && component.seconds >= 0, file: file, line: line)
            XCTAssertLessThanOrEqual(component.startOffsetSeconds + component.seconds,
                                     report.totalSeconds, file: file, line: line)
        }
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