import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Observations, not elapsed-time pass/fail gates or physical-phone claims.
/// Both workloads execute when selected, without an opt-in skip or timing gate.
/// No XCTest.measure repetition, no 50 x 8000 threshold sweep, no CI modification.
final class SimilarGroupingPerformanceTests: XCTestCase {
    func testSmallClusteredColdAndWarmDifferentThresholdObservations() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let photos = GroupingOptimizationFixtures.denseClustered(count: 96)
        let generationSeconds = seconds(start.duration(to: clock.now))
        try await observeCore(photos: photos, generationSeconds: generationSeconds, allSingletons: false)

        // Separate real service observation: includes three durable SQLite reads,
        // fake full Photos metadata snapshots, fresh authority checks and binary
        // result persistence. It is NOT real PhotoKit, inference or UI latency.
        let fixtureStart = clock.now
        let f = try GroupingOptimizationServiceFixture(photos: photos)
        let directory = f.directory
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let fixtureSeconds = seconds(fixtureStart.duration(to: clock.now))
        let coldStart = clock.now
        let cold = try await f.service.group(threshold: 0.90) { _ in }
        let coldSeconds = seconds(coldStart.duration(to: clock.now))
        let warmStart = clock.now
        let warm = try await f.service.group(threshold: 0.75) { _ in }
        let warmSeconds = seconds(warmStart.duration(to: clock.now))
        let expectedCold = try await GroupingLegacyReference.run(photos: photos, threshold: 0.90)
        let expectedWarm = try await GroupingLegacyReference.run(photos: photos, threshold: 0.75)
        assertGroupingBits(cold.groups, expectedCold.groups)
        assertGroupingBits(warm.groups, expectedWarm.groups)
        let metrics = f.metrics.values
        XCTAssertEqual(metrics.count, 2)
        XCTAssertEqual(metrics.map(\.preparationCount), [1, 0])
        XCTAssertEqual(metrics.map(\.decodedRowCount), [96, 0])
        XCTAssertEqual(metrics.map(\.preparedInputReuseCount), [0, 1])
        XCTAssertEqual(metrics.map(\.sourceSnapshotCount), [3, 3])
        XCTAssertEqual(f.library.snapshot.enumerations, 6)
        try attach(name: "similar-grouping-small-service-phases", report: [
            "workload": "96 dense synthetic vectors; SQLite + fake Photos metadata; no inference/pixels/UI",
            "fixtureCreationSeconds": fixtureSeconds,
            "coldServiceSecondsThreshold090": coldSeconds,
            "warmServiceSecondsThreshold075": warmSeconds,
            "preparations": metrics.map(\.preparationCount),
            "decodedRows": metrics.map(\.decodedRowCount),
            "durableSourcePasses": metrics.map(\.sourceSnapshotCount),
            "exactAgreement": "Group/member order, metadata, vector bits and minimumSimilarity bits asserted against legacy separately at each threshold"
        ])
    }

    func test8000SparseColdAndWarmDifferentThresholdObservations() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let photos = sparse8000()
        let generationSeconds = seconds(start.duration(to: clock.now))
        XCTAssertEqual(photos.count, 8000)
        try await observeCore(photos: photos, generationSeconds: generationSeconds, allSingletons: true)
    }

    private func observeCore(photos: [IndexedPhoto], generationSeconds: Double, allSingletons: Bool) async throws {
        let clock = ContinuousClock()
        var rows: [[String: Any]] = []
        var prepared: SimilarGroupingPreparedInput?
        // Exactly one legacy and one optimized computation at each threshold.
        // Warm really changes the threshold; no reuse of completed results.
        for (iteration, threshold) in [Float(0.90), Float(0.75)].enumerated() {
            let legacyPreparationStart = clock.now
            let referenceInput = try GroupingLegacyReference.Input(photos)
            let legacyPreparationSeconds = seconds(legacyPreparationStart.duration(to: clock.now))
            let legacyStart = clock.now
            let expected = try await GroupingLegacyReference.run(input: referenceInput, threshold: threshold)
            let legacyComputeSeconds = seconds(legacyStart.duration(to: clock.now))

            var preparationSeconds = 0.0
            if prepared == nil {
                let preparationStart = clock.now
                prepared = try SimilarGroupingPreparedInput(photos: photos)
                preparationSeconds = seconds(preparationStart.duration(to: clock.now))
            }
            let input = try XCTUnwrap(prepared)
            let computeStart = clock.now
            let actual = try await SimilarPhotoGrouper.compute(prepared: input, threshold: threshold)
            let computeSeconds = seconds(computeStart.duration(to: clock.now))
            assertGroupingBits(actual.groups, expected.groups)
            XCTAssertEqual(actual.metrics.matrixMultiplyCount, expected.metrics.matrixMultiplyCount)
            XCTAssertEqual(actual.metrics.seedScoreCount, expected.metrics.seedScoreCount)
            XCTAssertEqual(actual.metrics.memberScoreCount, expected.metrics.memberScoreCount)
            if allSingletons {
                XCTAssertTrue(actual.groups.isEmpty)
                XCTAssertEqual(actual.metrics.matrixMultiplyCount, 8000)
                XCTAssertEqual(actual.metrics.seedScoreCount, 8000 * 7999 / 2)
                XCTAssertEqual(actual.metrics.sortCandidateCount, 0)
                XCTAssertEqual(expected.metrics.sortCandidateCount, 8000 * 7999 / 2)
            }
            rows.append([
                "mode": iteration == 0 ? "cold" : "warm-different-threshold",
                "thresholdBits": threshold.bitPattern,
                "threshold": Double(threshold),
                "legacyPreparationSeconds": legacyPreparationSeconds,
                "legacyComputeSeconds": legacyComputeSeconds,
                "optimizedPreparationSeconds": preparationSeconds,
                "optimizedComputeSeconds": computeSeconds,
                "legacyTotalSeconds": legacyPreparationSeconds + legacyComputeSeconds,
                "optimizedTotalSeconds": preparationSeconds + computeSeconds,
                "groupCount": actual.groups.count,
                "legacyWork": counters(expected.metrics),
                "optimizedWork": counters(actual.metrics)
            ])
        }
        try attach(name: "similar-grouping-core-\(photos.count)-phases", report: [
            "rowCount": photos.count, "dimension": 768,
            "generationSeconds": generationSeconds, "observations": rows,
            "workload": allSingletons ? "8000 unique two-coordinate synthetic unit vectors; all singletons at both thresholds" : "96 deterministic dense clustered unit vectors",
            "exactAgreement": "Asserted against original greedy algorithm, separately for both thresholds; no score tolerance",
            "scope": "Core preparation and grouping only; no SQLite decoding/hashing, Photos snapshots, publication, persistence, model inference or UI",
            "remainingCost": "Still one full N x 768 mmul per unassigned seed and exact seed/member dots. Warm caches preparation, not scores. Worst-case O(N^2 D), not delta-only regrouping.",
            "timingPolicy": "Single observations; no elapsed-time limit, repetition, speedup requirement or physical-phone claim"
        ])
    }

    private func counters(_ value: SimilarGroupingComputationMetrics) -> [String: Int] {
        ["matrixMultiplies": value.matrixMultiplyCount, "seedDots": value.seedScoreCount,
         "remainingMemberDots": value.memberScoreCount, "sortedCandidates": value.sortCandidateCount,
         "candidateSortComparisons": value.sortComparisonCount]
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func attach(name: String, report: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func sparse8000() -> [IndexedPhoto] {
        var photos: [IndexedPhoto] = []
        photos.reserveCapacity(8000)
        let component = Float(0.5).squareRoot()
        // Each unordered coordinate pair is unique. Distinct vectors share at
        // most one coordinate, so |cosine| <= 0.5 (apart from Float rounding),
        // well below BOTH benchmark thresholds. Deterministic signs add ties and
        // negative ranking scores. This is intentionally the no-groups worst case.
        rows: for first in 0..<768 {
            for second in (first + 1)..<768 {
                var vector = [Float](repeating: 0, count: 768)
                vector[first] = component
                vector[second] = photos.count.isMultiple(of: 2) ? component : -component
                photos.append(GroupingOptimizationFixtures.photo(String(format: "sparse-%05d", photos.count), vector: vector))
                if photos.count == 8000 { break rows }
            }
        }
        return Array(photos.reversed())
    }
}