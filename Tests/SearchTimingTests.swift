import Dispatch
import Foundation
import XCTest
@testable import LocalImageIQ

/// Pure deterministic tests: no AppState, Photos, models, UI, sleeps, or I/O.
final class SearchTimingTests: XCTestCase {
    func testEveryStagePartitionsOneClockFromQueueThroughPublication() {
        let clock = SearchTimingTestClock(100)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        let stages = SearchTimingStage.allCases
        let seconds = stages.indices.map { Double($0 + 1) / 4 }
        for index in stages.indices.dropFirst() {
            clock.advance(by: seconds[index - 1])
            recorder.mark(stages[index])
        }
        clock.advance(by: seconds[seconds.count - 1])

        let report = recorder.finish(.ready)
        XCTAssertEqual(report.id, recorder.id)
        XCTAssertEqual(report.mode, "加速")
        XCTAssertEqual(report.stages.map(\.stage), stages)
        XCTAssertEqual(report.stages.map(\.seconds), seconds)
        XCTAssertEqual(report.totalSeconds, 22.75)
        XCTAssertEqual(report.slowest?.stage, .publication)
        XCTAssertEqual(report.slowest?.seconds, 3.25)
        XCTAssertEqual(clock.readCount, 14)
        XCTAssertNil(report.firstImageSeconds)
        assertPartition(report)
    }

    func testRepeatedMarksDoNotReadClockAndRevisitedStagesKeepDistinctIntervals() {
        let clock = SearchTimingTestClock(20)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        clock.advance(by: 1)
        recorder.mark(.queue)
        XCTAssertEqual(clock.readCount, 1)
        clock.advance(by: 1)
        recorder.mark(.translation)
        clock.advance(by: 3)
        recorder.mark(.translation)
        XCTAssertEqual(clock.readCount, 2)
        recorder.mark(.scoring)
        clock.advance(by: 4)
        recorder.mark(.translation)
        clock.advance(by: 1)

        let report = recorder.finish(.ready)
        XCTAssertEqual(report.stages.map(\.stage), [.queue, .translation, .scoring, .translation])
        XCTAssertEqual(report.stages.map(\.seconds), [2, 3, 4, 1])
        XCTAssertEqual(report.seconds(for: .translation), 4)
        XCTAssertEqual(report.seconds(for: .models), 0)
        XCTAssertEqual(report.totalSeconds, 10)
        assertPartition(report)
    }

    func testSameInstantRetainsAllActualZeroDurationTransitions() {
        let clock = SearchTimingTestClock(42)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        for stage in SearchTimingStage.allCases { recorder.mark(stage) }
        let report = recorder.finish(.ready)
        XCTAssertEqual(report.stages.map(\.stage), SearchTimingStage.allCases)
        XCTAssertTrue(report.stages.allSatisfy { $0.seconds == 0 })
        XCTAssertEqual(report.totalSeconds, 0)
        assertPartition(report)
    }

    func testFinishIsIdempotentAndFirstOutcomeWinsWithoutAnyMarks() {
        let outcomes: [SearchTimingOutcome] = [.ready, .cancelled, .failed]
        var identifiers = Set<UUID>()
        for outcome in outcomes {
            let clock = SearchTimingTestClock(100)
            let recorder = SearchTimingRecorder(clock: { clock.now() })
            clock.advance(by: 2)
            let frozen = recorder.finish(outcome)
            XCTAssertTrue(identifiers.insert(frozen.id).inserted)
            XCTAssertEqual(frozen.outcome, outcome)
            XCTAssertEqual(frozen.stages.map(\.stage), [.queue])
            XCTAssertEqual(frozen.totalSeconds, 2)
            XCTAssertEqual(frozen.cacheSource, "未知")
            XCTAssertEqual(frozen.candidateCount, 0)
            XCTAssertFalse(frozen.matrixReused)
            XCTAssertFalse(frozen.snapshotReused)
            clock.advance(by: 100)
            for stage in SearchTimingStage.allCases { recorder.mark(stage) }
            for later in outcomes { assertSameRanking(recorder.finish(later), frozen) }
            XCTAssertEqual(clock.readCount, 2)
            assertPartition(frozen)
        }
    }

    func testMetadataReportsActualCandidateCountAndFreezesAtFinish() {
        let clock = SearchTimingTestClock(10)
        let recorder = SearchTimingRecorder(mode: "baseline", clock: { clock.now() })
        recorder.setIndex(source: "sqlite", count: 12, matrixReused: false)
        recorder.setSnapshotReused(false)
        recorder.setIndex(source: "resident", count: 8_017, matrixReused: true)
        recorder.setSnapshotReused(true)
        XCTAssertEqual(clock.readCount, 1, "Metadata updates do not add timing boundaries.")
        clock.advance(by: 1)
        let frozen = recorder.finish(.ready)
        XCTAssertEqual(frozen.mode, "参考基线")
        XCTAssertEqual(frozen.cacheSource, "内存驻留")
        XCTAssertEqual(frozen.candidateCount, 8_017)
        XCTAssertEqual(frozen.stages.count, 1)
        XCTAssertTrue(frozen.matrixReused)
        XCTAssertTrue(frozen.snapshotReused)

        recorder.setIndex(source: "binary", count: 0, matrixReused: false)
        recorder.setSnapshotReused(false)
        assertSameRanking(recorder.finish(.cancelled), frozen)
        XCTAssertEqual(clock.readCount, 2)
    }

    func testAllowlistedSourcesAndModesBecomeFixedChineseLabels() {
        let clock = SearchTimingTestClock(0)
        let sources: [(String, String)] = [
            ("sqlite", "数据库读取"), ("binary", "二进制缓存"),
            ("resident", "内存驻留"), ("reference", "参考基线"), ("unknown", "未知"),
            (" SQLite \n", "数据库读取"), ("二进制缓存", "二进制缓存")
        ]
        for (source, expected) in sources {
            let recorder = SearchTimingRecorder(clock: { clock.now() })
            recorder.setIndex(source: source, count: 37, matrixReused: false)
            XCTAssertEqual(recorder.finish(.ready).cacheSource, expected)
        }
        let modes: [(String, String)] = [
            ("accelerated", "加速"), ("加速", "加速"), ("reference", "参考基线"),
            ("baseline", "参考基线"), ("基线", "参考基线"),
            ("参考基线", "参考基线"), (" BASELINE ", "参考基线"), ("unknown", "未知")
        ]
        for (mode, expected) in modes {
            let recorder = SearchTimingRecorder(mode: mode, clock: { clock.now() })
            XCTAssertEqual(recorder.finish(.ready).mode, expected)
        }
    }

    func testUnknownStringsCannotPassThroughAndCountsHaveNoArbitraryCeiling() {
        let clock = SearchTimingTestClock(0)
        // Synthetic privacy sentinels only; no user queries, identifiers or paths.
        let sentinels = ["synthetic query words", "sqlite:/synthetic/private.db",
                         "resident synthetic-photo-id", "C:\\synthetic\\private", "baseline:private"]
        for sentinel in sentinels {
            let recorder = SearchTimingRecorder(mode: sentinel, clock: { clock.now() })
            recorder.setIndex(source: sentinel, count: -1, matrixReused: false)
            let report = recorder.finish(.failed)
            XCTAssertEqual(report.mode, "未知")
            XCTAssertEqual(report.cacheSource, "未知")
            XCTAssertEqual(report.candidateCount, 0)
            XCTAssertFalse(String(reflecting: report).contains(sentinel))
            let fixture = SearchTimingReport(
                id: UUID(), stages: [], totalSeconds: 0, outcome: .ready,
                mode: sentinel, cacheSource: sentinel, candidateCount: Int.max,
                matrixReused: false, snapshotReused: false)
            XCTAssertEqual(fixture.mode, "未知")
            XCTAssertEqual(fixture.cacheSource, "未知")
            XCTAssertEqual(fixture.candidateCount, Int.max)
        }
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        recorder.setIndex(source: "reference", count: Int.max, matrixReused: false)
        XCTAssertEqual(recorder.finish(.ready).candidateCount, Int.max)
    }

    func testInvalidAndRegressingClocksCannotCreateNegativeOrNonfiniteRows() {
        let clock = SearchTimingTestClock(100)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        let samples: [Double] = [101, 99, .nan, .infinity, -.infinity, -1, 104, 102]
        let stages: [SearchTimingStage] = [
            .translation, .snapshot, .models, .indexRead, .queryEncoding, .counts, .scoring, .publication
        ]
        for (sample, stage) in zip(samples, stages) {
            clock.set(sample)
            recorder.mark(stage)
        }
        clock.set(105)
        let report = recorder.finish(.ready)
        XCTAssertEqual(report.stages.map(\.seconds), [1, 0, 0, 0, 0, 0, 3, 0, 1])
        XCTAssertEqual(report.totalSeconds, 5)
        assertPartition(report)

        for initial in [Double.nan, .infinity, -.infinity, -10] {
            let invalidClock = SearchTimingTestClock(initial)
            let attempt = SearchTimingRecorder(clock: { invalidClock.now() })
            invalidClock.set(2)
            let recovered = attempt.finish(.failed)
            XCTAssertEqual(recovered.totalSeconds, 2)
            assertPartition(recovered)
        }
    }

    func testFractionalClockPartitionAndFixedLabelsAndFormatting() {
        let clock = SearchTimingTestClock(0.1)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        for (index, stage) in SearchTimingStage.allCases.dropFirst().enumerated() {
            clock.set(0.1 + Double(index + 1) * 0.07)
            recorder.mark(stage)
        }
        clock.set(1.31)
        let report = recorder.finish(.ready)
        XCTAssertEqual(report.totalSeconds, 1.21, accuracy: 1e-12)
        assertPartition(report)
        XCTAssertEqual(SearchTimingStage.allCases.map(\.rawValue), [
            "调度／等待前任务", "查询翻译", "获取图库快照", "准备搜索模型", "读取索引／准备缓存",
            "查询编码", "读取索引统计", "搜索前访问检查", "向量评分与排序", "照片文字匹配",
            "筛选搜索结果", "发布前访问检查", "返回／发布排名"
        ])
        XCTAssertEqual([SearchTimingOutcome.ready, .cancelled, .failed].map(\.rawValue),
                       ["排名已发布", "搜索已取消", "搜索失败"])
        XCTAssertEqual(SearchTimingReport.duration(0), "0.000 秒")
        XCTAssertEqual(SearchTimingReport.duration(1.25), "1.250 秒")
    }

    func testFirstImageIsPostPublicationOnceAndDoesNotChangeRankingOrOriginalValue() throws {
        let clock = SearchTimingTestClock(100)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        XCTAssertNil(recorder.firstImage())
        XCTAssertEqual(clock.readCount, 1)
        clock.advance(by: 2)
        recorder.mark(.translation)
        clock.advance(by: 3)
        recorder.mark(.publication)
        clock.advance(by: 1)
        let published = recorder.finish(.ready)
        XCTAssertEqual(published.totalSeconds, 6)
        clock.advance(by: 4)
        let image = try XCTUnwrap(recorder.firstImage())
        XCTAssertEqual(image.firstImageSeconds, 10, "Use the initial request, not publication, as origin.")
        assertSameRanking(image, published)
        XCTAssertNil(published.firstImageSeconds, "Earlier report values remain immutable.")
        let reads = clock.readCount
        clock.advance(by: 100)
        XCTAssertNil(recorder.firstImage())
        recorder.mark(.scoring)
        let replay = recorder.finish(.failed)
        assertSameRanking(replay, published)
        XCTAssertEqual(replay.firstImageSeconds, 10)
        XCTAssertEqual(clock.readCount, reads)
        assertPartition(image)
    }

    func testFailedAndCancelledAttemptsIgnoreLateImagesAndCannotBeRevived() {
        for outcome in [SearchTimingOutcome.cancelled, .failed] {
            let clock = SearchTimingTestClock(10)
            let recorder = SearchTimingRecorder(clock: { clock.now() })
            clock.advance(by: 1)
            recorder.mark(.translation)
            clock.advance(by: 2)
            let frozen = recorder.finish(outcome)
            let reads = clock.readCount
            clock.advance(by: 100)
            for _ in 0..<3 {
                XCTAssertNil(recorder.firstImage())
                assertSameRanking(recorder.finish(.ready), frozen)
            }
            XCTAssertNil(recorder.finish(outcome).firstImageSeconds)
            XCTAssertEqual(clock.readCount, reads)
            assertPartition(frozen)
        }
    }

    func testFirstImageWithInvalidOrRegressingClockCannotPrecedePublication() throws {
        for late in [Double(99), .nan, .infinity, -.infinity, -1] {
            let clock = SearchTimingTestClock(100)
            let recorder = SearchTimingRecorder(clock: { clock.now() })
            clock.set(105)
            let published = recorder.finish(.ready)
            clock.set(late)
            let image = try XCTUnwrap(recorder.firstImage())
            XCTAssertEqual(image.firstImageSeconds, 5)
            assertSameRanking(image, published)
            XCTAssertNil(recorder.firstImage())
        }
    }

    func testConcurrentMarksMetadataAndFinishesReplayOneOrderedFrozenPartition() throws {
        let clock = SearchTimingTestClock(100)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        let reports = SearchTimingTestReports()
        let stages = SearchTimingStage.allCases
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            clock.advance(by: 1)
            recorder.mark(stages[index % stages.count])
            recorder.setIndex(source: "resident", count: index, matrixReused: true)
            recorder.setSnapshotReused(true)
            reports.append(recorder.finish(index.isMultiple(of: 2) ? .ready : .cancelled))
        }
        // Assertions stay outside worker closures, which capture only locked
        // fixtures and immutable values. No assumed scheduling order of threads.
        let values = reports.values
        XCTAssertEqual(values.count, 128)
        let frozen = try XCTUnwrap(values.first)
        XCTAssertEqual(frozen.stages.first?.stage, .queue)
        XCTAssertEqual(frozen.cacheSource, "内存驻留")
        XCTAssertGreaterThanOrEqual(frozen.candidateCount, 0)
        XCTAssertLessThan(frozen.candidateCount, 128)
        XCTAssertTrue(frozen.matrixReused)
        XCTAssertTrue(frozen.snapshotReused)
        XCTAssertGreaterThanOrEqual(frozen.totalSeconds, 1)
        XCTAssertLessThanOrEqual(frozen.totalSeconds, 128)
        for value in values { assertSameRanking(value, frozen) }
        assertPartition(frozen)
        let reads = clock.readCount
        recorder.mark(.publication)
        assertSameRanking(recorder.finish(.failed), frozen)
        XCTAssertEqual(clock.readCount, reads)
    }

    func testConcurrentImageNotificationsAcceptExactlyOneAfterPublication() throws {
        let clock = SearchTimingTestClock(100)
        let recorder = SearchTimingRecorder(clock: { clock.now() })
        let reports = SearchTimingTestReports()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let report = recorder.firstImage() { reports.append(report) }
        }
        XCTAssertTrue(reports.values.isEmpty)
        XCTAssertEqual(clock.readCount, 1)
        clock.advance(by: 2)
        let published = recorder.finish(.ready)
        clock.advance(by: 3)
        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            if let report = recorder.firstImage() { reports.append(report) }
        }
        XCTAssertEqual(reports.values.count, 1)
        let image = try XCTUnwrap(reports.values.first)
        assertSameRanking(image, published)
        XCTAssertEqual(image.firstImageSeconds, 5)
        XCTAssertEqual(clock.readCount, 3)
        XCTAssertNil(recorder.firstImage())
        assertPartition(image)
    }

    private func assertPartition(_ report: SearchTimingReport,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(report.stages.isEmpty, file: file, line: line)
        XCTAssertEqual(report.stages.first?.stage, .queue, file: file, line: line)
        XCTAssertEqual(report.stages.map(\.id), Array(report.stages.indices), file: file, line: line)
        XCTAssertTrue(report.totalSeconds.isFinite && report.totalSeconds >= 0, file: file, line: line)
        XCTAssertTrue(report.stages.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }, file: file, line: line)
        XCTAssertEqual(report.stages.reduce(0) { $0 + $1.seconds }, report.totalSeconds, file: file, line: line)
        if let firstImage = report.firstImageSeconds {
            XCTAssertTrue(firstImage.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(firstImage, report.totalSeconds, file: file, line: line)
        }
    }

    private func assertSameRanking(_ actual: SearchTimingReport, _ expected: SearchTimingReport,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.id), expected.stages.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.stage), expected.stages.map(\.stage), file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.seconds), expected.stages.map(\.seconds), file: file, line: line)
        XCTAssertEqual(actual.totalSeconds, expected.totalSeconds, file: file, line: line)
        XCTAssertEqual(actual.outcome, expected.outcome, file: file, line: line)
        XCTAssertEqual(actual.mode, expected.mode, file: file, line: line)
        XCTAssertEqual(actual.cacheSource, expected.cacheSource, file: file, line: line)
        XCTAssertEqual(actual.candidateCount, expected.candidateCount, file: file, line: line)
        XCTAssertEqual(actual.matrixReused, expected.matrixReused, file: file, line: line)
        XCTAssertEqual(actual.snapshotReused, expected.snapshotReused, file: file, line: line)
    }
}

private final class SearchTimingTestClock: @unchecked Sendable {
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

    func set(_ instant: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.instant = instant
    }

    func advance(by seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        instant += seconds
    }
}

private final class SearchTimingTestReports: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [SearchTimingReport] = []

    var values: [SearchTimingReport] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    func append(_ report: SearchTimingReport) {
        lock.lock()
        defer { lock.unlock() }
        reports.append(report)
    }
}