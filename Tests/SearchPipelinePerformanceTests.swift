import CryptoKit
import Foundation
import ImageIO
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

/// ONE model-free, synthetic comparison, deliberately not XCTest.measure's
/// repeated-query loop. No elapsed-time gate, timeout, resource cap or opt-in skip.
/// Native XCTest execution supplies the evidence; this source claims no speedup.
///
/// Attachment schema v1 (JSON objects/arrays with primitive leaves only):
/// boundary, fixture, memory, checks, summary, runs. Each run contains actual
/// recorder stages/flags and fake-boundary call deltas, never queries, photo IDs,
/// paths, vectors, model identifiers, hashes, raw errors or recorder UUIDs.
/// Times span recorder creation -> awaited worker.search -> recorder.finish.
/// .publication means worker return HERE, not AppState/UI publication. Fixture
/// seeding, parity assertions, independent hash checks and cleanup are excluded.
final class SearchPipelinePerformanceTests: XCTestCase {
    func testSyntheticSQLiteSearchPipelineComparison8000By768() async throws {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SearchPipelinePerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Could not remove the exclusively owned synthetic fixture.") }
        }

        let resolver = OfflinePlaceResolver.unavailable("Synthetic stored places only; no boundary lookup.")
        let seed = try PipelinePerformanceFixture.seed(directory: directory, geography: resolver.version)
        let database = directory.appendingPathComponent("index.sqlite3")
        let binary = directory.appendingPathComponent("search-vectors-v1.bin")
        let databaseBytes = try byteCount(database)
        let sourceSHA = try PipelinePerformanceFixture.sha256(database)
        XCTAssertGreaterThan(databaseBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: binary.path))
        var expectedIDs = Set<String>()
        for revision in seed.revisions { expectedIDs.insert(revision.id) }
        XCTAssertEqual(expectedIDs.count, 8_000)

        // Three distinct, dense normalized Float queries, generated independently
        // of the image/place streams. Text encoding is a lookup, NOT inference.
        let queries = ["synthetic alpha", "synthetic beta", "synthetic gamma"]
        var generator = PipelinePerformanceGenerator(state: 0xBEAD_0011)
        var vectors: [[Float]] = []
        var lookup: [String: [Float]] = [:]
        for query in queries {
            let vector = try generator.unitVector()
            vectors.append(vector)
            lookup[query] = vector
        }
        XCTAssertNotEqual(vectors[0], vectors[1])
        XCTAssertNotEqual(vectors[1], vectors[2])
        XCTAssertNotEqual(vectors[0], vectors[2])

        let library = PipelinePerformanceLibrary(seed.revisions)
        let encoders = PipelinePerformanceEncoders(lookup)
        var worker: PhotoIndexWorker? = PhotoIndexWorker(
            library: library, encoders: encoders, directory: directory, resolver: resolver)
        // Worker/cache monitors must be released BEFORE directory cleanup, also
        // on cancellation/error. SQLite readers close internally on every read.
        defer { worker = nil }
        weak var initialWorker = worker
        var old: [PipelinePerformanceRun] = []
        for query in queries {
            try Task.checkCancellation()
            let run = try await timedSearch(worker: XCTUnwrap(worker), library: library,
                                            encoders: encoders, text: query, reference: true,
                                            phase: "reference", expectedIDs: expectedIDs)
            assertPhase(run, source: "参考基线", matrix: false, snapshot: false,
                        enumerations: 3, captures: 0, loads: 0, builds: 0, validations: 0)
            old.append(run)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: binary.path),
                       "The old path must not create or prewarm the derived cache.")

        try Task.checkCancellation()
        let cold = try await timedSearch(worker: XCTUnwrap(worker), library: library,
                                         encoders: encoders, text: queries[0], reference: false,
                                         phase: "accelerated_cold", expectedIDs: expectedIDs)
        assertPhase(cold, source: "数据库读取", matrix: false, snapshot: false,
                    enumerations: 1, captures: 1, loads: 1, builds: 1, validations: 3)
        assertSame(cold, old[0])
        // Disk durability is no longer part of awaited search. Separately drain
        // its optional tail before disk/restart assertions, outside cold timing.
        let tailDrainStart = ProcessInfo.processInfo.systemUptime
        await worker?.waitForSearchCacheWriteback()
        let tailDrainSeconds = ProcessInfo.processInfo.systemUptime - tailDrainStart
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))

        // No adjacent repeat after cold; each of the three warm requests has a
        // different query. All reuse the matrix, but MUST still invoke text().
        let warmOrder: [Int] = [1, 2, 0]
        var warm: [PipelinePerformanceRun] = []
        for index in warmOrder {
            try Task.checkCancellation()
            let run = try await timedSearch(worker: XCTUnwrap(worker), library: library,
                                            encoders: encoders, text: queries[index], reference: false,
                                            phase: "accelerated_warm", expectedIDs: expectedIDs)
            assertPhase(run, source: "内存驻留", matrix: true, snapshot: true,
                        enumerations: 1, captures: 1, loads: 0, builds: 0, validations: 3)
            assertSame(run, old[index])
            warm.append(run)
        }
        let calls = await encoders.textHistory()
        XCTAssertTrue(calls == [queries[0], queries[1], queries[2], queries[0],
                                queries[1], queries[2], queries[0]], "No query-result/embedding cache.")
        worker = nil
        XCTAssertNil(initialWorker, "Release the first resident matrix and its SQLite monitor.")

        // These checks are OUTSIDE all timed intervals. Decode only the binary
        // header, not a second copy of its vectors; digests stay out of reports.
        let binaryBytes = try byteCount(binary)
        XCTAssertGreaterThan(binaryBytes, 0)
        let binarySHA = try PipelinePerformanceFixture.sha256(binary)
        do {
            let headerData = try Data(contentsOf: binary, options: .mappedIfSafe)
            let header = try PropertyListDecoder().decode(PipelinePerformanceCacheHeader.self, from: headerData)
            XCTAssertEqual(header.schema, 1)
            XCTAssertTrue(header.key.databaseSHA256 == sourceSHA, "Cache key must cover the whole source DB.")
            XCTAssertTrue(header.key.scope.modelUTF8 == Data(PipelinePerformanceFixture.cacheVersion.utf8))
            XCTAssertTrue(try header.key.scope.idsSHA256 == PipelinePerformanceFixture.scopeSHA(expectedIDs),
                          "The binary must be bound to exactly this authorized synthetic ID scope.")
        }

        // New worker, new encoders AND new metadata cache: no retained matrix or
        // snapshot crosses this boundary. This is NOT a new process / OS reboot.
        try Task.checkCancellation()
        let restartedLibrary = PipelinePerformanceLibrary(seed.revisions)
        let restartedEncoders = PipelinePerformanceEncoders(lookup)
        worker = PhotoIndexWorker(library: restartedLibrary, encoders: restartedEncoders,
                                  directory: directory, resolver: resolver)
        weak var restartedWorker = worker
        let restart = try await timedSearch(worker: XCTUnwrap(worker), library: restartedLibrary,
                                            encoders: restartedEncoders, text: queries[0], reference: false,
                                            phase: "restart_binary", expectedIDs: expectedIDs)
        assertPhase(restart, source: "二进制缓存", matrix: false, snapshot: false,
                    enumerations: 1, captures: 1, loads: 1, builds: 1, validations: 3)
        assertSame(restart, old[0])
        let restartedCalls = await restartedEncoders.textHistory()
        XCTAssertTrue(restartedCalls == [queries[0]])
        worker = nil
        XCTAssertNil(restartedWorker)
        XCTAssertTrue(try PipelinePerformanceFixture.sha256(database) == sourceSHA,
                      "Search must not mutate the synthetic SQLite source.")
        XCTAssertTrue(try PipelinePerformanceFixture.sha256(binary) == binarySHA,
                      "Resident/restart reads must not silently rebuild the binary.")
        XCTAssertEqual(try byteCount(database), databaseBytes)
        XCTAssertEqual(try byteCount(binary), binaryBytes)
        for suffix in ["-journal", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + suffix))
        }
        try Task.checkCancellation()
        try attachReport(old: old, cold: cold, warm: warm, warmOrder: warmOrder, restart: restart,
                         databaseBytes: databaseBytes, binaryBytes: binaryBytes, seed: seed,
                         tailDrainSeconds: tailDrainSeconds)
    }

    private func timedSearch(worker: PhotoIndexWorker, library: PipelinePerformanceLibrary,
                             encoders: PipelinePerformanceEncoders, text: String, reference: Bool,
                             phase: String, expectedIDs: Set<String>) async throws -> PipelinePerformanceRun {
        try Task.checkCancellation()
        let before = library.counters()
        let encoderBefore = await encoders.counters()
        let started = ProcessInfo.processInfo.systemUptime
        let timing = SearchTimingRecorder(mode: reference ? "reference" : "accelerated")
        let response = try await worker.search(text: text, originalText: text, limit: Int.max,
            locationWeight: 0.6, filters: .init(), textSearchEnabled: false,
            timing: timing, referenceSearch: reference)
        let report = timing.finish(.ready)
        let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        let after = library.counters()
        let encoderAfter = await encoders.counters()
        try Task.checkCancellation()
        XCTAssertEqual(encoderAfter.prepares - encoderBefore.prepares, 1)
        XCTAssertEqual(encoderAfter.texts - encoderBefore.texts, 1)
        XCTAssertEqual(encoderAfter.forbidden, 0)
        XCTAssertEqual(after.forbidden, 0)
        XCTAssertEqual(response.hits.count, 8_000)
        XCTAssertEqual(response.summary.authorizedCount, 8_000)
        XCTAssertTrue(response.summary.authorizedCountKnown)
        XCTAssertEqual(response.summary.indexedCount, 8_000)
        XCTAssertEqual(response.summary.locatedCount, 8_000)
        XCTAssertFalse(response.textSearchUsed)
        XCTAssertTrue(response.textMatchedIDs.isEmpty)
        var ids: [String] = []
        var bits: [UInt32] = []
        ids.reserveCapacity(response.hits.count)
        bits.reserveCapacity(response.hits.count)
        for hit in response.hits {
            try Task.checkCancellation()
            XCTAssertEqual(hit.photo.imageEmbedding.count, 768)
            ids.append(hit.id)
            bits.append(hit.score.bitPattern)
        }
        XCTAssertTrue(Set(ids) == expectedIDs, "ALL N authorized candidates, not a top-K/paging shortcut.")
        return PipelinePerformanceRun(phase: phase, report: report, wallMilliseconds: wallMilliseconds,
            counts: after.subtracting(before),
            encoderCounts: PipelinePerformanceEncoders.Counters(
                prepares: encoderAfter.prepares - encoderBefore.prepares,
                texts: encoderAfter.texts - encoderBefore.texts,
                forbidden: encoderAfter.forbidden - encoderBefore.forbidden),
            ids: ids, bits: bits)
    }

    private func assertPhase(_ run: PipelinePerformanceRun, source: String, matrix: Bool, snapshot: Bool,
                             enumerations: Int, captures: Int, loads: Int, builds: Int, validations: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        let report = run.report
        XCTAssertEqual(report.cacheSource, source, file: file, line: line)
        XCTAssertEqual(report.matrixReused, matrix, file: file, line: line)
        XCTAssertEqual(report.snapshotReused, snapshot, file: file, line: line)
        XCTAssertEqual(report.candidateCount, 8_000, file: file, line: line)
        XCTAssertEqual(report.outcome, .ready, file: file, line: line)
        XCTAssertEqual(report.mode, source == "参考基线" ? "参考基线" : "加速", file: file, line: line)
        XCTAssertNil(report.firstImageSeconds, file: file, line: line)
        let expected: [SearchTimingStage] = [.queue, .snapshot, .models, .indexRead, .queryEncoding,
            .counts, .accessCheck, .scoring, .filtering, .finalAccess, .publication]
        var actual: [SearchTimingStage] = []
        var sum: Double = 0
        for row in report.stages {
            actual.append(row.stage)
            XCTAssertTrue(row.seconds.isFinite && row.seconds >= 0, file: file, line: line)
            sum += row.seconds
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(sum, report.totalSeconds, file: file, line: line)
        XCTAssertTrue(report.totalSeconds.isFinite && report.totalSeconds > 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(run.wallMilliseconds, report.totalSeconds * 1_000, file: file, line: line)
        XCTAssertEqual(run.counts.enumerations, enumerations, file: file, line: line)
        XCTAssertEqual(run.counts.captures, captures, file: file, line: line)
        XCTAssertEqual(run.counts.loads, loads, file: file, line: line)
        XCTAssertEqual(run.counts.builds, builds, file: file, line: line)
        XCTAssertEqual(run.counts.validations, validations, file: file, line: line)
    }

    private func assertSame(_ run: PipelinePerformanceRun, _ baseline: PipelinePerformanceRun,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(run.ids == baseline.ids, "Every ordered hit ID must match the SAME-query baseline.",
                      file: file, line: line)
        XCTAssertTrue(run.bits == baseline.bits, "Every Float score.bitPattern must match, no tolerance.",
                      file: file, line: line)
    }

    private func byteCount(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).int64Value
    }

    private func attachReport(old: [PipelinePerformanceRun], cold: PipelinePerformanceRun,
                              warm: [PipelinePerformanceRun], warmOrder: [Int], restart: PipelinePerformanceRun,
                              databaseBytes: Int64, binaryBytes: Int64, seed: PipelinePerformanceSeed,
                              tailDrainSeconds: Double) throws {
        var oldMS: [Double] = []
        var warmMS: [Double] = []
        var pairedSpeedups: [Double] = []
        var paired: [[String: Any]] = []
        for run in old { oldMS.append(run.report.totalSeconds * 1_000) }
        for index in warm.indices {
            let milliseconds = warm[index].report.totalSeconds * 1_000
            warmMS.append(milliseconds)
            let baseline = oldMS[warmOrder[index]]
            let speedup = baseline / milliseconds
            pairedSpeedups.append(speedup)
            paired.append(["old_ms": baseline, "warm_ms": milliseconds, "speedup": speedup])
        }
        let oldMedian = oldMS.sorted()[1]
        let warmMedian = warmMS.sorted()[1]
        let ratioOfMedians = oldMedian / warmMedian
        let medianPaired = pairedSpeedups.sorted()[1]
        let coldMS = cold.report.totalSeconds * 1_000
        let binaryMS = restart.report.totalSeconds * 1_000
        var records: [[String: Any]] = []
        var oldSum: Double = 0
        var warmSum: Double = 0
        for run in old { records.append(run.json); oldSum += run.report.totalSeconds * 1_000 }
        records.append(cold.json)
        for run in warm { records.append(run.json); warmSum += run.report.totalSeconds * 1_000 }
        records.append(restart.json)
        #if targetEnvironment(simulator)
        let runtime = "simulator_synthetic_not_phone_evidence"
        #else
        let runtime = "native_synthetic_not_user_photo_or_end_to_end_evidence"
        #endif
        #if DEBUG
        let debugConfiguration = true
        #else
        let debugConfiguration = false
        #endif
        let boundary: [String: Any] = [
            "runtime": runtime, "debug_configuration": debugConfiguration,
            "timed_scope": "recorder creation through awaited PhotoIndexWorker.search and finish; worker return only",
            "model_boundary": "synthetic normalized vectors; mock prepare and text lookup; no ML or tokenizer",
            "photo_boundary": "fake full-access metadata walks and actual versioned snapshot cache; no PhotoKit or pixels",
            "cold_scope": "first derived-cache request; includes full source SHA, SQLite JSON decode/validation and matrix construction; binary encode/write is non-awaited tail work after result construction",
            "cache_tail_remaining_drain_seconds": tailDrainSeconds,
            "cache_tail_drain_boundary": "wait after cold parity assertion; tail can already be running/completed; not total encoding duration",
            "binary_scope": "first request of new worker and metadata cache; includes full source SHA, binary validation/decode, matrix construction",
            "os_cache_state": "uncontrolled; seed/hash/reference reads precede cold; binary hash/header reads precede restart; no OS cache eviction",
            "cold_worker_previously_ran_reference_only": true,
            "hash_serialization_matrix_costs_included_in_index_read": false,
            "hash_and_matrix_costs_included_in_index_read": true,
            "hash_serialization_matrix_subtimings_separately_measured": false,
            "restart_is_same_process": true, "process_restart_measured": false,
            "ui_publication_measured": false, "page_access_validation_measured": false,
            "first_image_measured": false, "translation_measured": false,
            "ml_inference_measured": false, "photo_pixels_measured": false,
            "ocr_enabled": false, "query_cache_used": false,
            "excluded": "fixture creation, parity checks, independent hashes/header checks, cleanup; no user end-to-end claim"
        ]
        let fixture: [String: Any] = [
            "rows": 8_000, "dimensions": 768, "distinct_queries": 3,
            "distinct_places": 8, "located_rows": 8_000, "location_weight": Double(Float(0.6)),
            "sqlite_schema_version": 1, "sqlite_seed_transactions": 1,
            "sqlite_seed_prepared_insert_statements": 2,
            "serialized_database_bytes": databaseBytes, "serialized_binary_bytes": binaryBytes,
            "image_json_bytes": seed.imageJSONBytes, "distinct_place_json_bytes": seed.placeJSONBytes
        ]
        let memory: [String: Any] = [
            "resident_matrix_peak_bytes_calculated": 8_000 * 768 * MemoryLayout<Double>.stride,
            "resident_matrix_element_bytes": MemoryLayout<Double>.stride,
            "retained_image_float_bytes_calculated": 8_000 * 768 * MemoryLayout<Float>.stride,
            "matrix_instances_at_once": 1, "rss_measured": false,
            "scope": "one Double image matrix; excludes Float arrays, places, JSON, binary buffers, scratch and allocator overhead"
        ]
        let summary: [String: Any] = [
            "old_ms": oldMS, "warm_ms": warmMS, "cold_ms": coldMS, "binary_first_ms": binaryMS,
            "old_sum_ms": oldSum, "warm_sum_ms": warmSum, "cold_plus_warm_sum_ms": coldMS + warmSum,
            "all_measured_sum_ms": oldSum + coldMS + warmSum + binaryMS,
            "old_median_ms": oldMedian, "warm_median_ms": warmMedian,
            "ratio_of_medians_speedup": ratioOfMedians, "median_same_query_speedup": medianPaired,
            "same_query_comparisons": paired,
            "cold_same_query_speedup": oldMS[0] / coldMS,
            "binary_same_query_speedup": oldMS[0] / binaryMS,
            "target_speedup": 10, "warm_ratio_of_medians_meets_target": ratioOfMedians >= 10,
            "warm_median_same_query_meets_target": medianPaired >= 10,
            "target_is_test_gate": false, "reference_samples": 3, "warm_samples": 3,
            "cold_samples": 1, "binary_samples": 1,
            "sampling_limit": "one fixed-order run, not a confidence interval or general device guarantee"
        ]
        let checks: [String: Any] = [
            "ordered_ids_and_score_bits_required_per_comparison": 8_000,
            "same_query_parity_comparisons": 5, "parity_failures_fail_test": true,
            "source_sha_and_authorized_scope_asserted": true,
            "source_and_binary_unchanged_asserted": true,
            "phase_source_matrix_snapshot_flags_asserted": true,
            "xctest_result_is_authoritative": true
        ]
        let object: [String: Any] = ["schema_version": 1, "boundary": boundary, "fixture": fixture,
            "memory": memory, "checks": checks, "summary": summary, "runs": records]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "TIMINGS-search-pipeline"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The entire primitive report, including every phase/stage, is also
        // numeric console evidence. Never print the in-memory parity fixtures.
        print("TIMINGS-search-pipeline " + String(decoding: data, as: UTF8.self))
    }
}

private struct PipelinePerformanceRun {
    let phase: String
    let report: SearchTimingReport
    let wallMilliseconds: Double
    let counts: PipelinePerformanceLibrary.Counters
    let encoderCounts: PipelinePerformanceEncoders.Counters
    let ids: [String]
    let bits: [UInt32]

    var json: [String: Any] {
        var stages: [[String: Any]] = []
        var sumMS: Double = 0
        for row in report.stages {
            let milliseconds = row.seconds * 1_000
            stages.append(["stage": row.stage.rawValue, "ms": milliseconds])
            sumMS += milliseconds
        }
        return ["phase": phase, "mode": report.mode, "source": report.cacheSource,
            "recorder_outcome": report.outcome.rawValue,
            "matrix_reused": report.matrixReused, "snapshot_reused": report.snapshotReused,
            "candidate_count": report.candidateCount, "returned_count": ids.count,
            "recorder_total_ms": report.totalSeconds * 1_000, "outer_wall_ms": wallMilliseconds,
            "stage_sum_ms": sumMS, "stages": stages,
            "first_image_ms": NSNull(), "full_fake_enumerations": counts.enumerations,
            "snapshot_captures": counts.captures, "snapshot_source_loads": counts.loads,
            "snapshot_full_metadata_builds": counts.builds, "snapshot_epoch_validations": counts.validations,
            "full_metadata_walks": counts.enumerations + counts.builds,
            "mock_prepare_calls": encoderCounts.prepares, "mock_text_lookup_calls": encoderCounts.texts,
            "forbidden_encoder_calls": encoderCounts.forbidden, "forbidden_library_calls": counts.forbidden]
    }
}

private struct PipelinePerformanceSeed {
    let revisions: [PhotoRevision]
    let imageJSONBytes: Int64
    let placeJSONBytes: Int64
}

private struct PipelinePerformanceGenerator {
    var state: UInt64

    mutating func unitVector() throws -> [Float] {
        try Task.checkCancellation()
        var values = [Float](repeating: 0, count: 768)
        var squares: Double = 0
        for index in values.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let integer = Int((state >> 32) & 0xFFFF) - 32_768
            let value = Float(integer) / 32_768
            values[index] = value
            squares += Double(value) * Double(value)
        }
        let norm = squares.squareRoot()
        for index in values.indices { values[index] = Float(Double(values[index]) / norm) }
        try EmbeddingValidation.validateUnit(values)
        try Task.checkCancellation()
        return values
    }
}

private enum PipelinePerformanceFixture {
    static let modelVersion = "synthetic-search-pipeline-v1"
    static var cacheVersion: String { IndexImagePolicy.cacheVersion(modelVersion: modelVersion) }

    /// Exact SQLite schema 1 from SQLitePhotoStore/TestFixtures.seedRawCache.
    /// Synchronous and exclusively owned: one transaction, two prepared INSERTs
    /// reused with bound parameters. FULL sync once at commit, NOT 8,000 save()s.
    /// No vector bank of 8,000 rows is retained just to construct the fixture.
    static func seed(directory: URL, geography: String) throws -> PipelinePerformanceSeed {
        try Task.checkCancellation()
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
            &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        defer { if let handle { XCTAssertEqual(sqlite3_close_v2(handle), SQLITE_OK) } }
        guard status == SQLITE_OK, let database = handle else { throw Failure.sqlite(status) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func check(_ status: Int32, _ expected: Int32 = SQLITE_OK) throws {
            guard status == expected else { throw Failure.sqlite(status) }
        }
        func exec(_ sql: String) throws { try check(sqlite3_exec(database, sql, nil, nil, nil)) }
        func text(_ value: String, _ index: Int32, _ statement: OpaquePointer) throws {
            try check(value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) })
        }
        func blob(_ data: Data, _ index: Int32, _ statement: OpaquePointer) throws {
            try check(data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) })
        }
        func finishRow(_ statement: OpaquePointer) throws {
            try check(sqlite3_step(statement), SQLITE_DONE)
            try check(sqlite3_reset(statement))
            try check(sqlite3_clear_bindings(statement))
        }
        try exec("PRAGMA journal_mode = DELETE; PRAGMA synchronous = FULL; PRAGMA secure_delete = ON;")
        try exec("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) } }
        try exec("""
            CREATE TABLE photos (
                id TEXT PRIMARY KEY NOT NULL, revision REAL NOT NULL, model_version TEXT NOT NULL,
                image_embedding BLOB NOT NULL, creation_time REAL, place_text TEXT,
                geography_version TEXT NOT NULL);
            CREATE TABLE places (
                text TEXT NOT NULL, model_version TEXT NOT NULL, embedding BLOB NOT NULL,
                PRIMARY KEY (text, model_version));
            PRAGMA user_version = 1;
            """)
        var placePointer: OpaquePointer?
        defer { if let placePointer { sqlite3_finalize(placePointer) } }
        try check(sqlite3_prepare_v2(database,
            "INSERT INTO places (text, model_version, embedding) VALUES (?, ?, ?)", -1, &placePointer, nil))
        let placeStatement = try XCTUnwrap(placePointer)
        var photoPointer: OpaquePointer?
        defer { if let photoPointer { sqlite3_finalize(photoPointer) } }
        try check(sqlite3_prepare_v2(database, """
            INSERT INTO photos (id, revision, model_version, image_embedding, creation_time, place_text, geography_version)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, -1, &photoPointer, nil))
        let photoStatement = try XCTUnwrap(photoPointer)
        let encoder = JSONEncoder()
        var placeGenerator = PipelinePerformanceGenerator(state: 0xFACE_8822)
        var imageGenerator = PipelinePerformanceGenerator(state: 0xCAFE_7733)
        var labels: [String] = []
        var placeBytes: Int64 = 0
        for index in 0..<8 {
            try Task.checkCancellation()
            let label = "Synthetic place \(index)"
            labels.append(label)
            let data = try encoder.encode(placeGenerator.unitVector())
            placeBytes += Int64(data.count)
            try text(label, 1, placeStatement)
            try text(cacheVersion, 2, placeStatement)
            try blob(data, 3, placeStatement)
            try finishRow(placeStatement)
        }
        var revisions: [PhotoRevision] = []
        revisions.reserveCapacity(8_000)
        var imageBytes: Int64 = 0
        for index in 0..<8_000 {
            try Task.checkCancellation()
            let id = String(format: "synthetic-%05d", index)
            let revision = 1_000.0 + Double(index)
            let creation = 500.0 + Double(index)
            let data = try encoder.encode(imageGenerator.unitVector())
            imageBytes += Int64(data.count)
            // Deliberately nonuniform repetition: one place has 4,500 photos,
            // the other seven have 500 each. Core must center DISTINCT places.
            let slot = index % 16
            let placeIndex = slot < 8 ? 0 : slot - 8
            try text(id, 1, photoStatement)
            try check(sqlite3_bind_double(photoStatement, 2, revision))
            try text(cacheVersion, 3, photoStatement)
            try blob(data, 4, photoStatement)
            try check(sqlite3_bind_double(photoStatement, 5, creation))
            try text(labels[placeIndex], 6, photoStatement)
            try text(geography, 7, photoStatement)
            try finishRow(photoStatement)
            revisions.append(PhotoRevision(id: id, modificationTime: revision, creationTime: creation))
        }
        try Task.checkCancellation()
        try exec("COMMIT")
        committed = true
        return PipelinePerformanceSeed(revisions: revisions, imageJSONBytes: imageBytes, placeJSONBytes: placeBytes)
    }

    static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }

    static func scopeSHA(_ ids: Set<String>) throws -> Data {
        // Same length-framed UTF-8 scope contract as SearchIndexCache. Synthetic
        // IDs are ASCII; no normalization/localized-order assumptions are needed.
        func append(_ data: Data, to hash: inout SHA256) {
            var length = UInt64(data.count).littleEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: data)
        }
        var hash = SHA256()
        hash.update(data: Data("search-scope-v1".utf8))
        append(Data(String(ids.count).utf8), to: &hash)
        try Task.checkCancellation()
        for id in ids.sorted() {
            try Task.checkCancellation()
            append(Data(id.utf8), to: &hash)
        }
        return Data(hash.finalize())
    }

    enum Failure: Error { case sqlite(Int32), unexpectedOperation }
}

private struct PipelinePerformanceCacheHeader: Decodable {
    struct Scope: Decodable { let modelUTF8: Data; let idsSHA256: Data }
    struct Key: Decodable { let scope: Scope; let databaseSHA256: Data }
    let schema: Int
    let key: Key
}

/// No Photos framework calls. Every full enumeration/build actually walks N
/// small metadata rows; returning a cached Array alone would undercount that work.
private final class PipelinePerformanceLibrary: PhotoLibraryIndexing, PhotoSearchSnapshotting, @unchecked Sendable {
    struct Counters {
        var enumerations = 0
        var captures = 0
        var loads = 0
        var builds = 0
        var validations = 0
        var forbidden = 0

        func subtracting(_ old: Counters) -> Counters {
            Counters(enumerations: enumerations - old.enumerations, captures: captures - old.captures,
                     loads: loads - old.loads, builds: builds - old.builds,
                     validations: validations - old.validations, forbidden: forbidden - old.forbidden)
        }
    }

    private let revisions: [PhotoRevision]
    private let byID: [String: PhotoRevision]
    private let cache = PhotoSearchSnapshotCache<[PhotoRevision]>()
    private let lock = NSLock()
    private var calls = Counters()

    init(_ revisions: [PhotoRevision]) {
        self.revisions = revisions
        var byID: [String: PhotoRevision] = [:]
        for row in revisions { byID[row.id] = row }
        self.byID = byID
        cache.synchronizeObservation(isRegistered: true, access: .init(authorization: 3, canRead: true))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    func counters() -> Counters { locked { calls } }
    var canReadImages: Bool { true }
    var authorizationStatusRawValue: Int? { 3 }
    var changeGeneration: UInt64? { cache.changeGeneration }

    private func walk(_ source: [PhotoRevision]) throws -> [PhotoRevision] {
        var result: [PhotoRevision] = []
        result.reserveCapacity(source.count)
        for row in source {
            try Task.checkCancellation()
            result.append(PhotoRevision(id: row.id, modificationTime: row.modificationTime, creationTime: row.creationTime))
        }
        return result
    }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        locked { calls.enumerations += 1 }
        return try walk(revisions)
    }
    func currentRevision(id: String) -> PhotoRevision? { byID[id] }
    func invalidateSearchSnapshot() { cache.invalidate() }

    func searchSnapshot() throws -> PhotoSearchSnapshot {
        locked { calls.captures += 1 }
        let captured = try cache.capture(readAccess: { [self] in
            .init(authorization: authorizationStatusRawValue ?? -1, canRead: canReadImages)
        }, loadSource: { [self] in
            locked { calls.loads += 1 }
            return revisions
        }, loadRevisions: { [self] source in
            locked { calls.builds += 1 }
            return try walk(source)
        }, loadPhotos: { [self] ids in
            var rows: [PhotoRevision] = []
            for id in ids {
                try Task.checkCancellation()
                if let row = byID[id] { rows.append(row) }
            }
            return rows
        })
        return PhotoSearchSnapshot(revisions: captured.revisions, reused: captured.reused, validate: { [self] in
            locked { calls.validations += 1 }
            try captured.validate()
        }, validatePhotos: captured.validatePhotos)
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { calls.forbidden += 1 }
        XCTFail("Search must use stored synthetic labels, not resolve geography.")
        return nil
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { calls.forbidden += 1 }
        XCTFail("Synthetic performance search must not request photo pixels.")
        throw PipelinePerformanceFixture.Failure.unexpectedOperation
    }
}

private actor PipelinePerformanceEncoders: PhotoEncoding {
    struct Counters { var prepares = 0; var texts = 0; var forbidden = 0 }
    private let vectors: [String: [Float]]
    private var calls = Counters()
    private var history: [String] = []
    private let manifest: ModelManifest

    init(_ vectors: [String: [Float]]) {
        self.vectors = vectors
        let source = ModelManifest.Source(id: "synthetic-no-model", revision: "fixture-only")
        manifest = ModelManifest(schemaVersion: 2, modelVersion: PipelinePerformanceFixture.modelVersion,
            dimension: 768, sequenceLength: 64, imageSize: 224, imageModel: source, textModel: source,
            imageInput: "pixel_values", textInputs: ["input_ids"], output: "output_embedding")
    }
    func counters() -> Counters { calls }
    func textHistory() -> [String] { history }
    func inspectResources() -> ModelManifest { manifest }
    func prepare() throws -> ModelManifest {
        try Task.checkCancellation()
        calls.prepares += 1
        return manifest
    }
    func text(_ text: String) throws -> [Float] {
        try Task.checkCancellation()
        calls.texts += 1
        history.append(text)
        guard let vector = vectors[text] else { throw PipelinePerformanceFixture.Failure.unexpectedOperation }
        return vector
    }
    func makeIndexingImageEncoders() throws -> [any PhotoImageEncoding] {
        calls.forbidden += 1
        XCTFail("No indexing encoder factory in a search benchmark.")
        throw PipelinePerformanceFixture.Failure.unexpectedOperation
    }
    func image(preview: IndexingImage) throws -> [Float] {
        calls.forbidden += 1
        XCTFail("No image inference in a synthetic search benchmark.")
        throw PipelinePerformanceFixture.Failure.unexpectedOperation
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        calls.forbidden += 1
        XCTFail("No original image decoding/inference in a synthetic search benchmark.")
        throw PipelinePerformanceFixture.Failure.unexpectedOperation
    }
}