import CryptoKit
import Foundation
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Real SQLite and v1 serialization, synthetic vectors only. Work-count gates
/// are deterministic; elapsed times are evidence attachments, NEVER pass gates.
final class SearchColdPreparationTests: XCTestCase {
    private func context(rows: [CachedPhoto]? = nil,
                         checkpoint: (@Sendable (SearchCacheDeferredCheckpoint) async -> Void)? = nil)
        throws -> ColdCacheContext {
        let directory = try TestFixtures.temporaryDirectory()
        try TestFixtures.seedRawCache(rows ?? fixtureRows(count: 4), directory: directory)
        let probe = SearchColdWorkProbe()
        let reader = SQLitePhotoStore(directory: directory, readOnly: true)
        let cache = SearchIndexCache(directory: directory, observeWork: { probe.record($0) },
                                     deferredCheckpoint: checkpoint)
        addTeardownBlock {
            await cache.invalidate()
            await reader.close()
            try FileManager.default.removeItem(at: directory)
        }
        return ColdCacheContext(directory: directory, cache: cache, reader: reader, probe: probe)
    }

    private func reopened(_ c: ColdCacheContext) -> SearchIndexCache {
        let cache = SearchIndexCache(directory: c.directory, observeWork: { c.probe.record($0) })
        addTeardownBlock { await cache.invalidate() }
        return cache
    }

    private func fixtureRows(count: Int) -> [CachedPhoto] {
        (0..<count).map { index in
            // Repeated images deliberately create exact score ties. Distinct
            // places include canonically equivalent but byte-distinct text.
            let place: PlaceEmbedding?
            switch index % 4 {
            case 0: place = nil
            case 1: place = PlaceEmbedding(text: "caf\u{00E9}", vector: unit(seed: 41))
            case 2: place = PlaceEmbedding(text: "cafe\u{0301}", vector: unit(seed: 42))
            default: place = PlaceEmbedding(text: "Other", vector: unit(seed: 43))
            }
            return CachedPhoto(photo: IndexedPhoto(id: String(format: "row-%05d", index),
                modificationTime: 123, modelVersion: "test-model", imageEmbedding: unit(seed: index % 17),
                location: place, creationTime: index % 3 == 0 ? nil : Double(index)),
                geographyVersion: "test-places")
        }
    }

    private func unit(seed: Int) -> [Float] {
        let values = (0..<768).map { Float((($0 + seed * 13) * 37) % 101 - 50) }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        return values.map { Float(Double($0) / norm) }
    }

    private func same(_ lhs: [SearchHit], _ rhs: [SearchHit], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.map(\.id), rhs.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.map { $0.score.bitPattern }, rhs.map { $0.score.bitPattern }, file: file, line: line)
    }

    func testMeasuredEagerVersusDeferredColdPreparationPreservesEveryRankAndScoreBit() async throws {
        let count = 256
        let rows = fixtureRows(count: count)
        let c = try context(rows: rows)
        let ids = Set(rows.map(\.photo.id))
        let source = try Data(contentsOf: c.database)
        let query = unit(seed: 71)

        // Retained OLD path: full SHA + actual JSON loader + validation + v1
        // packing/plists/write + the unchanged Double matrix + exact scoring.
        let oldStart = ProcessInfo.processInfo.systemUptime
        let old = try await c.read(ids: ids, deferred: false)
        let oldIndex = try ResidentSearchIndex(photos: old.records.map(\.photo))
        let oldHits = try oldIndex.search(query: query, limit: Int.max, locationWeight: 0.6)
        let oldSeconds = ProcessInfo.processInfo.systemUptime - oldStart
        let oldWork = c.probe.snapshot()
        XCTAssertEqual(oldWork.sourceHashPasses, 1)
        XCTAssertEqual(oldWork.sourceHashBytes, source.count)
        XCTAssertEqual(oldWork.loads, 1)
        XCTAssertEqual(oldWork.validatedRecords, count)
        XCTAssertEqual(oldWork.encodingStarts, 1)
        XCTAssertEqual(oldWork.packedImageBytes, count * 768 * 4)
        XCTAssertEqual(oldWork.payloadEncodes, 1)
        XCTAssertEqual(oldWork.envelopeEncodes, 1)
        XCTAssertEqual(oldWork.publications, 1)
        XCTAssertGreaterThan(oldWork.stagedBytes, 0)
        let oldBinary = try Data(contentsOf: c.binary)
        await c.cache.invalidate()
        try FileManager.default.removeItem(at: c.binary)
        c.probe.reset()

        let newStart = ProcessInfo.processInfo.systemUptime
        let new = try await c.read(ids: ids)
        let newIndex = try ResidentSearchIndex(photos: new.records.map(\.photo))
        let newHits = try newIndex.search(query: query, limit: Int.max, locationWeight: 0.6)
        let newSeconds = ProcessInfo.processInfo.systemUptime - newStart
        let critical = c.probe.snapshot()
        XCTAssertEqual(critical.sourceHashPasses, oldWork.sourceHashPasses)
        XCTAssertEqual(critical.sourceHashBytes, oldWork.sourceHashBytes)
        XCTAssertEqual(critical.loads, oldWork.loads)
        XCTAssertEqual(critical.validatedRecords, oldWork.validatedRecords)
        XCTAssertEqual(critical.encodingStarts, 0)
        XCTAssertEqual(critical.packedImageBytes, 0)
        XCTAssertEqual(critical.payloadEncodes, 0)
        XCTAssertEqual(critical.envelopeEncodes, 0)
        XCTAssertEqual(critical.stagedBytes, 0)
        XCTAssertEqual(critical.publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        XCTAssertEqual(new.signature, old.signature)
        XCTAssertEqual(newIndex.packedImageElementCount, oldIndex.packedImageElementCount)
        same(newHits, oldHits)
        same(newHits, try VectorSearch.search(query: query, photos: new.records.map(\.photo),
                                             limit: Int.max, locationWeight: 0.6))

        let tailStart = ProcessInfo.processInfo.systemUptime
        await c.cache.persistDeferred(try XCTUnwrap(new.writebackToken))
        let tailSeconds = ProcessInfo.processInfo.systemUptime - tailStart
        let total = c.probe.snapshot()
        XCTAssertEqual(total.loads, 1, "Tail must use the same authoritative snapshot, never load SQL again.")
        XCTAssertEqual(total.sourceHashPasses, 1)
        XCTAssertEqual(total.encodingStarts, 1)
        XCTAssertEqual(total.packedImageBytes, oldWork.packedImageBytes)
        XCTAssertEqual(total.payloadEncodes, 1)
        XCTAssertEqual(total.envelopeEncodes, 1)
        XCTAssertEqual(total.publications, 1)
        // plist dictionary ordering is not a byte-level serialization contract;
        // inspect the envelope/key and compare every restored vector/score bit.
        let disk = try Data(contentsOf: c.binary)
        var schemaUnchanged = true
        for bytes in [oldBinary, disk] {
            let envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any])
            XCTAssertEqual(envelope["schema"] as? Int, 1)
            schemaUnchanged = schemaUnchanged && (envelope["schema"] as? Int == 1)
            let key = try XCTUnwrap(envelope["key"] as? [String: Any])
            XCTAssertEqual(key["databaseSHA256"] as? Data, Data(SHA256.hash(data: source)))
        }
        let restored = try await c.read(using: reopened(c), ids: ids)
        XCTAssertEqual(restored.source, .binary)
        XCTAssertNil(restored.writebackToken)
        let restoredIndex = try ResidentSearchIndex(photos: restored.records.map(\.photo))
        for weight in [Float(0), 0.25, 0.6, 1] {
            for query in [query, unit(seed: 72), unit(seed: 73)] {
                for limit in [0, 1, count, Int.max] {
                    let expected = try VectorSearch.search(query: query, photos: old.records.map(\.photo),
                                                           limit: limit, locationWeight: weight)
                    same(try newIndex.search(query: query, limit: limit, locationWeight: weight), expected)
                    same(try restoredIndex.search(query: query, limit: limit, locationWeight: weight), expected)
                }
            }
        }
        XCTAssertEqual(c.probe.snapshot().loads, 1)
        XCTAssertEqual(try Data(contentsOf: c.database), source)
        let report: [String: Any] = [
            "boundary": "native synthetic SQLite/cache/matrix/scoring; no PhotoKit, ML, translation, UI or OS-cold claim",
            "rows": count, "dimensions": 768, "source_bytes": source.count,
            "old_eager_seconds": oldSeconds, "new_critical_seconds": newSeconds,
            "deferred_tail_seconds": tailSeconds,
            "old_work": oldWork.json, "new_critical_work": critical.json, "new_with_tail_work": total.json,
            "rank_and_score_bits_equal": newHits.map(\.id) == oldHits.map(\.id) &&
                newHits.map { $0.score.bitPattern } == oldHits.map { $0.score.bitPattern },
            "timing_is_not_a_pass_gate": true,
            "source_and_schema_unchanged": try Data(contentsOf: c.database) == source && schemaUnchanged,
            "os_cache_state": "uncontrolled; eager runs first; no OS eviction; not a real-phone latency measurement"
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "TIMINGS-cold-search-preparation-old-new"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDeferredBinaryRetainsRawFloatBitsAndUTF8Metadata() async throws {
        for dimension in [512, 768] {
            let c = try context()
            var vector = TestFixtures.vector(dimension: dimension)
            vector[1] = Float(bitPattern: 0x80000000)
            vector[2] = Float(bitPattern: 1)
            let rows = ["caf\u{00E9}", "cafe\u{0301}"].enumerated().map { index, text in
                CachedPhoto(photo: IndexedPhoto(id: "\(index)", modificationTime: 42.125,
                    modelVersion: "test-model", imageEmbedding: vector,
                    location: PlaceEmbedding(text: text, vector: vector), creationTime: index == 0 ? nil : 12.25),
                    geographyVersion: "older-geography")
            }
            let result = try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["0", "1"],
                                                   deferPersistence: true) { rows }
            await c.cache.persistDeferred(try XCTUnwrap(result.writebackToken))
            let restored = try await c.read(using: reopened(c), ids: ["0", "1"])
            XCTAssertEqual(restored.source, .binary)
            XCTAssertEqual(restored.records.count, rows.count)
            for (expected, actual) in zip(rows, restored.records) {
                XCTAssertEqual(actual.photo.imageEmbedding.map(\.bitPattern), expected.photo.imageEmbedding.map(\.bitPattern))
                XCTAssertEqual(actual.photo.location?.vector.map(\.bitPattern), expected.photo.location?.vector.map(\.bitPattern))
                XCTAssertEqual(actual.photo.location.map { Data($0.text.utf8) }, expected.photo.location.map { Data($0.text.utf8) })
                XCTAssertEqual(actual.photo.modificationTime, expected.photo.modificationTime)
                XCTAssertEqual(actual.photo.creationTime, expected.photo.creationTime)
                XCTAssertEqual(actual.geographyVersion, expected.geographyVersion)
            }
            XCTAssertEqual(c.probe.snapshot().loads, 0)
        }
    }

    func testInvalidateClearAndCancellationRejectBothUnencodedAndEncodedTail() async throws {
        for stage in [SearchCacheDeferredCheckpoint.beforeEncoding, .beforeCommit] {
            for action in ["invalidate", "clear", "cancel"] {
                let gate = SearchColdGate()
                let c = try context(checkpoint: { checkpoint in
                    if checkpoint == stage { await gate.pause() }
                })
                let source = try Data(contentsOf: c.database)
                let result = try await c.read()
                let token = try XCTUnwrap(result.writebackToken)
                let task = Task { await c.cache.persistDeferred(token) }
                await gate.waitUntilEntered()
                switch action {
                case "invalidate": await c.cache.invalidate()
                case "clear": try await c.cache.clear()
                default: task.cancel()
                }
                await gate.release()
                await task.value
                XCTAssertEqual(c.probe.snapshot().encodingStarts, stage == .beforeEncoding ? 0 : 1)
                XCTAssertEqual(c.probe.snapshot().stagedBytes, 0)
                XCTAssertEqual(c.probe.snapshot().publications, 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
                XCTAssertEqual(try Data(contentsOf: c.database), source)
                let fresh = try await c.read()
                // Cancelling ONLY optional persistence keeps already returned,
                // fully checked records reusable. Lifecycle invalidation/clear
                // must instead drop both records and the uncommitted write.
                XCTAssertEqual(fresh.source, action == "cancel" ? .resident : .sqlite)
                XCTAssertNotEqual(fresh.writebackToken, token)
                // Even an explicit retry of a revoked ticket has no effect.
                await c.cache.persistDeferred(token)
                XCTAssertEqual(c.probe.snapshot().stagedBytes, 0)
            }
        }
    }

    func testSameSizeEmbeddingRewriteWithRestoredMtimeRejectsEncodedOldSnapshot() async throws {
        let gate = SearchColdGate()
        let row = TestFixtures.photo(id: "a")
        let c = try context(rows: [row], checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedTime], ofItemAtPath: c.database.path)
        let old = try await c.read(ids: ["a"])
        let before = try FileManager.default.attributesOfItem(atPath: c.database.path)
        let token = try XCTUnwrap(old.writebackToken)
        let task = Task { await c.cache.persistDeferred(token) }
        await gate.waitUntilEntered()
        // Same ID/model/revision/count and BLOB length; only embedding content
        // changes. No schema initialization by a second production writer.
        let changed = CachedPhoto(photo: IndexedPhoto(id: "a", modificationTime: 123, modelVersion: "test-model",
            imageEmbedding: TestFixtures.vector(axis: 1), creationTime: 100), geographyVersion: "test-places")
        try TestFixtures.seedRawCache([changed], directory: c.directory)
        try FileManager.default.setAttributes([.modificationDate: fixedTime], ofItemAtPath: c.database.path)
        let after = try FileManager.default.attributesOfItem(atPath: c.database.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        await gate.release()
        await task.value
        XCTAssertEqual(c.probe.snapshot().publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        let fresh = try await c.read(ids: ["a"])
        XCTAssertEqual(fresh.source, .sqlite)
        XCTAssertNotEqual(fresh.signature, old.signature)
        XCTAssertEqual(fresh.records.first?.photo.imageEmbedding.map(\.bitPattern), changed.photo.imageEmbedding.map(\.bitPattern))
        await c.cache.persistDeferred(try XCTUnwrap(fresh.writebackToken))
        let cold = try await c.read(using: reopened(c), ids: ["a"])
        XCTAssertEqual(cold.source, .binary)
        XCTAssertEqual(cold.signature, fresh.signature)
    }

    func testNewScopeOrModelCannotBeOverwrittenBySuspendedBroaderTail() async throws {
        for modelChange in [false, true] {
            let gate = SearchColdGate()
            let rows = [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "b"), TestFixtures.photo(id: "other", model: "other-model")]
            let c = try context(rows: rows, checkpoint: { stage in
                if stage == .beforeCommit { await gate.pause() }
            })
            let broad = try await c.read(ids: ["a", "b", "other"])
            let token = try XCTUnwrap(broad.writebackToken)
            let oldTask = Task { await c.cache.persistDeferred(token) }
            await gate.waitUntilEntered()
            let model = modelChange ? "other-model" : "test-model"
            let ids: Set<String> = modelChange ? ["a", "b", "other"] : ["a"]
            let narrow = try await c.read(model: model, ids: ids)
            await gate.release()
            await oldTask.value
            XCTAssertEqual(c.probe.snapshot().publications, 0)
            await c.cache.persistDeferred(try XCTUnwrap(narrow.writebackToken))
            let disk = try await c.read(using: reopened(c), model: model, ids: ids)
            XCTAssertEqual(disk.source, .binary)
            XCTAssertEqual(disk.signature, narrow.signature)
            XCTAssertEqual(disk.records.map(\.photo.id), modelChange ? ["other"] : ["a"])
            XCTAssertEqual(c.probe.snapshot().publications, 1)
        }
    }

    func testWarmReadReissuesUnwrittenTokenWithoutAnotherLoadHashOrMatrixInputChange() async throws {
        let c = try context()
        let first = try await c.read()
        let warm = try await c.read()
        XCTAssertEqual(warm.source, .resident)
        XCTAssertEqual(warm.signature, first.signature)
        XCTAssertNotEqual(warm.writebackToken, first.writebackToken)
        await c.cache.persistDeferred(try XCTUnwrap(first.writebackToken))
        XCTAssertEqual(c.probe.snapshot().encodingStarts, 0)
        await c.cache.persistDeferred(try XCTUnwrap(warm.writebackToken))
        await c.cache.persistDeferred(try XCTUnwrap(warm.writebackToken))
        XCTAssertEqual(c.probe.snapshot().loads, 1)
        XCTAssertEqual(c.probe.snapshot().sourceHashPasses, 1)
        XCTAssertEqual(c.probe.snapshot().encodingStarts, 1)
        XCTAssertEqual(c.probe.snapshot().publications, 1)
        let persisted = try await c.read()
        XCTAssertNil(persisted.writebackToken)
    }

    func testDeferredTailYieldsToCoordinatorAndReservedSQLiteWriterWithoutQueueing() async throws {
        for coordinated in [false, true] {
            let gate = SearchColdGate()
            let c = try context(checkpoint: { stage in
                if stage == .beforeCommit { await gate.pause() }
            })
            let access = IndexAccessCoordinator()
            let result = try await c.read()
            let token = try XCTUnwrap(result.writebackToken)
            let task = Task { await c.cache.persistDeferred(token, indexAccess: access) }
            await gate.waitUntilEntered()
            // Encoding must not hold a foreground read lease.
            let lease = try await access.acquireWrite()
            var handle: OpaquePointer?
            if !coordinated {
                lease.release()
                XCTAssertEqual(sqlite3_open_v2(c.database.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
                XCTAssertEqual(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
                XCTAssertFalse(FileManager.default.fileExists(atPath: c.database.path + "-journal"))
            }
            await gate.release()
            // Await while the writer is still held: optional persistence must
            // SKIP, not queue a read lease and deadlock the next foreground job.
            await task.value
            XCTAssertEqual(c.probe.snapshot().publications, 0)
            XCTAssertEqual(c.probe.snapshot().stagedBytes, 0)
            if let handle {
                XCTAssertEqual(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil), SQLITE_OK)
                XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
            }
            lease.release()
            let retry = try await c.read()
            await c.cache.persistDeferred(try XCTUnwrap(retry.writebackToken), indexAccess: access)
            XCTAssertEqual(c.probe.snapshot().publications, 1)
            XCTAssertTrue(access.canReadImmediately)
        }
    }

    func testOptionalDeferredWriteFailureLeavesSourceAndForeignFilesUntouched() async throws {
        let c = try context()
        let source = try Data(contentsOf: c.database)
        try FileManager.default.createDirectory(at: c.binary, withIntermediateDirectories: false)
        let sentinel = c.binary.appendingPathComponent("keep")
        try Data([1, 2, 3]).write(to: sentinel)
        let result = try await c.read()
        await c.cache.persistDeferred(try XCTUnwrap(result.writebackToken))
        let warm = try await c.read()
        XCTAssertEqual(warm.source, .resident)
        XCTAssertEqual(warm.signature, result.signature)
        XCTAssertNil(warm.writebackToken, "Do not loop on an optional disk failure.")
        XCTAssertEqual(c.probe.snapshot().publications, 0)
        XCTAssertEqual(try Data(contentsOf: c.database), source)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 2, 3]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: c.directory.path).contains { $0.hasSuffix(".tmp") })
    }

    func testSourceRemovalOrReplacementCannotPublishOldEncodedCache() async throws {
        for replace in [false, true] {
            let gate = SearchColdGate()
            let c = try context(checkpoint: { stage in
                if stage == .beforeCommit { await gate.pause() }
            })
            let replacement = try context(rows: [TestFixtures.photo(id: "replacement")])
            let result = try await c.read()
            let token = try XCTUnwrap(result.writebackToken)
            let task = Task { await c.cache.persistDeferred(token) }
            await gate.waitUntilEntered()
            try FileManager.default.removeItem(at: c.database)
            if replace { try FileManager.default.copyItem(at: replacement.database, to: c.database) }
            await gate.release()
            await task.value
            XCTAssertEqual(c.probe.snapshot().publications, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
            let fresh = try await c.read(ids: ["replacement"])
            XCTAssertEqual(fresh.source, .sqlite)
            XCTAssertEqual(fresh.records.map(\.photo.id), replace ? ["replacement"] : [])
            if !replace { XCTAssertNil(fresh.writebackToken) }
        }
    }

    func testDeferredFileKeepsV1ProtectionAndBackupExclusion() async throws {
        let c = try context()
        let result = try await c.read()
        await c.cache.persistDeferred(try XCTUnwrap(result.writebackToken))
        XCTAssertEqual(c.probe.snapshot().publications, 1)
        for url in [c.directory, c.binary] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            #endif
        }
    }
}

private struct ColdCacheContext: Sendable {
    let directory: URL
    let cache: SearchIndexCache
    let reader: SQLitePhotoStore
    let probe: SearchColdWorkProbe
    var database: URL { directory.appendingPathComponent("index.sqlite3") }
    var binary: URL { directory.appendingPathComponent("search-vectors-v1.bin") }

    func read(using other: SearchIndexCache? = nil, model: String = "test-model",
              ids: Set<String> = Set((0..<4).map { String(format: "row-%05d", $0) }), deferred: Bool = true)
        async throws -> SearchIndexCacheResult {
        try await (other ?? cache).records(modelVersion: model, accessibleIDs: ids, deferPersistence: deferred) {
            probe.loaded()
            return try await reader.searchRecords(modelVersion: model, accessibleIDs: ids)
        }
    }
}

/// Shared only by native cold/cache/worker tests. Lock-protected aggregate facts
/// from real production call sites, not guessed counts derived from fixture N.
final class SearchColdWorkProbe: @unchecked Sendable {
    struct Counts {
        var sourceHashPasses = 0, sourceHashBytes = 0, loads = 0, validatedRecords = 0
        var encodingStarts = 0, packedImageBytes = 0, payloadEncodes = 0, envelopeEncodes = 0
        var stagedBytes = 0, publications = 0
        var json: [String: Int] {
            ["source_hash_passes": sourceHashPasses, "source_hash_bytes": sourceHashBytes,
             "sql_loads": loads, "validated_records": validatedRecords, "encoding_starts": encodingStarts,
             "packed_image_bytes": packedImageBytes, "payload_encodes": payloadEncodes,
             "envelope_encodes": envelopeEncodes, "staged_bytes": stagedBytes, "publications": publications]
        }
    }
    private let lock = NSLock()
    private var counts = Counts()
    func snapshot() -> Counts { lock.lock(); defer { lock.unlock() }; return counts }
    func reset() { lock.lock(); defer { lock.unlock() }; counts = Counts() }
    func loaded() { lock.lock(); defer { lock.unlock() }; counts.loads += 1 }
    func record(_ event: SearchCachePreparationEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .sourceHashed(let bytes): counts.sourceHashPasses += 1; counts.sourceHashBytes += bytes
        case .recordsValidated(let count): counts.validatedRecords += count
        case .encodingStarted: counts.encodingStarts += 1
        case .imagesPacked(let bytes): counts.packedImageBytes += bytes
        case .payloadEncoded: counts.payloadEncodes += 1
        case .envelopeEncoded: counts.envelopeEncodes += 1
        case .fileStaged(let bytes): counts.stagedBytes += bytes
        case .filePublished: counts.publications += 1
        }
    }
}

/// Intentionally noncooperative pause: cancellation is observed but completion
/// waits for explicit release, allowing drain/late-publication assertions.
actor SearchColdGate {
    private var entered = false, released = false, cancelled = false
    private var pauses: [CheckedContinuation<Void, Never>] = []
    private var entries: [CheckedContinuation<Void, Never>] = []
    private var cancellations: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withTaskCancellationHandler {
            entered = true
            let waiting = entries; entries = []
            for continuation in waiting { continuation.resume() }
            if !released { await withCheckedContinuation { pauses.append($0) } }
        } onCancel: { Task { await self.didCancel() } }
    }
    private func didCancel() {
        cancelled = true
        let waiting = cancellations; cancellations = []
        for continuation in waiting { continuation.resume() }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entries.append($0) } }
    }
    func waitUntilCancelled() async {
        if !cancelled { await withCheckedContinuation { cancellations.append($0) } }
    }
    func release() {
        released = true
        let waiting = pauses; pauses = []
        for continuation in waiting { continuation.resume() }
    }
}