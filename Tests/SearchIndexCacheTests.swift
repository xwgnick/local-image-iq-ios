import CryptoKit
import Foundation
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

final class SearchIndexCacheTests: XCTestCase {
    private func context(rows: [CachedPhoto] = [TestFixtures.photo(id: "a")]) async throws -> SearchCacheTestContext {
        let directory = try TestFixtures.temporaryDirectory()
        let writer = SQLitePhotoStore(directory: directory)
        let loader = SearchCacheTestLoader(directory: directory)
        let cache = SearchIndexCache(directory: directory)
        addTeardownBlock {
            await cache.invalidate()
            await loader.close()
            await writer.close()
            try FileManager.default.removeItem(at: directory)
        }
        for row in rows { try await writer.save(row) }
        return SearchCacheTestContext(directory: directory, writer: writer, loader: loader, cache: cache)
    }

    private func reopened(_ context: SearchCacheTestContext) -> SearchIndexCache {
        let cache = SearchIndexCache(directory: context.directory)
        addTeardownBlock { await cache.invalidate() }
        return cache
    }

    private func rawWriter(_ context: SearchCacheTestContext) throws -> SearchCacheTestSQLWriter {
        let writer = try SearchCacheTestSQLWriter(directory: context.directory)
        addTeardownBlock { await writer.close() }
        return writer
    }

    private func assertCalls(_ loader: SearchCacheTestLoader, _ expected: Int,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await loader.calls
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func testInitAndMissingDatabaseCreateNothingAndAlwaysUseLoader() async throws {
        let root = try await context(rows: [])
        let directory = root.directory.appendingPathComponent("not-created", isDirectory: true)
        let cache = SearchIndexCache(directory: directory)
        let loader = SearchCacheTestLoader(directory: directory)
        addTeardownBlock { await cache.invalidate(); await loader.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        for _ in 0..<2 {
            let result = try await cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                try await loader.load(model: "test-model", ids: ["a"])
            }
            XCTAssertEqual(result.source, .sqlite)
            XCTAssertTrue(result.records.isEmpty)
        }
        await assertCalls(loader, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.directory.path), [])
        try await cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testColdSQLiteThenResidentThenNewActorBinaryWithoutJSONLoader() async throws {
        let c = try await context()
        let sourceBefore = try Data(contentsOf: c.database)
        let first = try await c.read()
        let binaryBefore = try Data(contentsOf: c.binary)
        let second = try await c.read()
        let third = try await c.read(using: reopened(c))
        XCTAssertEqual(first.source, .sqlite)
        XCTAssertEqual(second.source, .resident)
        XCTAssertEqual(third.source, .binary)
        XCTAssertEqual(first.signature, second.signature)
        XCTAssertEqual(first.signature, third.signature)
        XCTAssertEqual(first.signature.count, 64)
        XCTAssertEqual(third.records.map(\.photo.id), ["a"])
        XCTAssertEqual(third.records.first?.photo.imageEmbedding, TestFixtures.vector())
        await assertCalls(c.loader, 1)
        XCTAssertEqual(try Data(contentsOf: c.database), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: c.binary), binaryBefore)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: c.directory.path)),
                       ["index.sqlite3", "search-vectors-v1.bin"])
    }

    func testBinaryPreservesMetadataNullablePlacesUTF8AndFloatBits() async throws {
        var vector = TestFixtures.vector()
        vector[0] = 0.6
        vector[1] = 0.8
        vector[2] = Float(bitPattern: 0x80000000) // Negative zero must not be normalized away.
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let a = CachedPhoto(photo: IndexedPhoto(id: "a", modificationTime: 42.125, modelVersion: "test-model",
                                                imageEmbedding: vector,
                                                location: PlaceEmbedding(text: composed, vector: TestFixtures.vector(axis: 3)),
                                                creationTime: nil), geographyVersion: "older-geography")
        let b = CachedPhoto(photo: IndexedPhoto(id: "b", modificationTime: 43.5, modelVersion: "test-model",
                                                imageEmbedding: TestFixtures.vector(axis: 767),
                                                location: PlaceEmbedding(text: decomposed, vector: TestFixtures.vector(axis: 4)),
                                                creationTime: 12.25), geographyVersion: "new-geography")
        let c = try await context(rows: [a, b, TestFixtures.photo(id: "c")])
        // Exercise the exact supplied snapshot's bits, independent of whether
        // Foundation's source JSON round-trip preserves its spelling of -0.
        let rows = [a, b, TestFixtures.photo(id: "c")]
        _ = try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a", "b", "c"]) { rows }
        let result = try await c.read(using: reopened(c), ids: ["a", "b", "c"])
        XCTAssertEqual(result.source, .binary)
        XCTAssertEqual(result.records.count, 3)
        let decoded = result.records[0]
        XCTAssertEqual(decoded.photo.imageEmbedding.map(\.bitPattern), vector.map(\.bitPattern))
        XCTAssertEqual(decoded.photo.modificationTime, 42.125)
        XCTAssertNil(decoded.photo.creationTime)
        XCTAssertEqual(decoded.photo.modelVersion, "test-model")
        XCTAssertEqual(decoded.geographyVersion, "older-geography")
        XCTAssertEqual(Array(try XCTUnwrap(decoded.photo.location).text.utf8), Array(composed.utf8))
        XCTAssertEqual(decoded.photo.location?.vector, TestFixtures.vector(axis: 3))
        XCTAssertEqual(Array(try XCTUnwrap(result.records[1].photo.location).text.utf8), Array(decomposed.utf8))
        XCTAssertEqual(result.records[1].photo.location?.vector, TestFixtures.vector(axis: 4))
        XCTAssertEqual(result.records[1].photo.creationTime, 12.25)
        XCTAssertEqual(result.records[1].geographyVersion, "new-geography")
        XCTAssertNil(result.records[2].photo.location)
        await assertCalls(c.loader, 0)
    }

    func testLegacy512ImageAndLocationRemainReadableWithoutManifestMigration() async throws {
        let c = try await context(rows: [])
        let row = CachedPhoto(photo: IndexedPhoto(id: "a", modificationTime: 1, modelVersion: "legacy",
                                                  imageEmbedding: TestFixtures.vector(axis: 511, dimension: 512),
                                                  location: PlaceEmbedding(text: "Legacy", vector: TestFixtures.vector(dimension: 512))),
                              geographyVersion: "legacy-places")
        try TestFixtures.seedRawCache([row], directory: c.directory)
        let before = try Data(contentsOf: c.database)
        let first = try await c.read(model: "legacy")
        let binary = try await c.read(using: reopened(c), model: "legacy")
        XCTAssertEqual(first.source, .sqlite)
        XCTAssertEqual(binary.source, .binary)
        XCTAssertEqual(binary.records.first?.photo.imageEmbedding.count, 512)
        XCTAssertEqual(binary.records.first?.photo.location?.vector.count, 512)
        XCTAssertEqual(try Data(contentsOf: c.database), before)
    }

    func testExternalSaveInvalidatesResidentAndExistingDiskCache() async throws {
        let c = try await context()
        let first = try await c.read()
        try await c.writer.save(TestFixtures.photo(id: "a", revision: 124))
        let fresh = try await c.read()
        XCTAssertEqual(fresh.source, .sqlite)
        XCTAssertNotEqual(fresh.signature, first.signature)
        XCTAssertEqual(fresh.records.first?.photo.modificationTime, 124)
        try await c.writer.save(TestFixtures.photo(id: "a", revision: 125))
        let newActor = try await c.read(using: reopened(c))
        XCTAssertEqual(newActor.source, .sqlite)
        XCTAssertEqual(newActor.records.first?.photo.modificationTime, 125)
        XCTAssertNotEqual(newActor.signature, fresh.signature)
        await assertCalls(c.loader, 3)
    }

    func testExternalReconcileAndClearInvalidateCachedRecords() async throws {
        let c = try await context(rows: [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "b")])
        let first = try await c.read(ids: ["a", "b"])
        try await c.writer.reconcile(completeEnumeration: [PhotoRevision(id: "a", modificationTime: 123)])
        let pruned = try await c.read(ids: ["a", "b"])
        XCTAssertEqual(pruned.source, .sqlite)
        XCTAssertEqual(pruned.records.map(\.photo.id), ["a"])
        XCTAssertNotEqual(pruned.signature, first.signature)
        try await c.writer.clear()
        let cleared = try await c.read(ids: ["a", "b"])
        XCTAssertEqual(cleared.source, .sqlite)
        XCTAssertTrue(cleared.records.isEmpty)
        XCTAssertNotEqual(cleared.signature, pruned.signature)
        let binary = try await c.read(using: reopened(c), ids: ["a", "b"])
        XCTAssertEqual(binary.source, .binary)
        XCTAssertTrue(binary.records.isEmpty)
    }

    func testSameSizeWriteWithRestoredMtimeDetectedByLiveDataVersionAndColdSHA() async throws {
        for useNewActor in [false, true] {
            let c = try await context()
            let old = try await c.read()
            let attributes = try FileManager.default.attributesOfItem(atPath: c.database.path)
            let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
            try await c.writer.save(TestFixtures.photo(id: "a", revision: 124))
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: c.database.path)
            let after = try FileManager.default.attributesOfItem(atPath: c.database.path)
            XCTAssertEqual(attributes[.size] as? NSNumber, after[.size] as? NSNumber)
            XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
            let result = try await c.read(using: useNewActor ? reopened(c) : c.cache)
            XCTAssertEqual(result.source, .sqlite)
            XCTAssertEqual(result.records.first?.photo.modificationTime, 124)
            XCTAssertNotEqual(result.signature, old.signature)
            await assertCalls(c.loader, 2)
        }
    }

    func testFileReplacementDoesNotReuseOldConnectionsDataVersion() async throws {
        let c = try await context()
        let replacement = try await context(rows: [TestFixtures.photo(id: "a", revision: 456)])
        let old = try await c.read()
        await c.writer.close()
        await replacement.writer.close()
        let oldAttributes = try FileManager.default.attributesOfItem(atPath: c.database.path)
        try FileManager.default.removeItem(at: c.database)
        try FileManager.default.copyItem(at: replacement.database, to: c.database)
        try FileManager.default.setAttributes([.modificationDate: try XCTUnwrap(oldAttributes[.modificationDate])],
                                             ofItemAtPath: c.database.path)
        let current = try await c.read()
        XCTAssertEqual(current.source, .sqlite)
        XCTAssertEqual(current.records.first?.photo.modificationTime, 456)
        XCTAssertNotEqual(current.signature, old.signature)
    }

    func testScopeChangeExcludesPrivateInvalidAndOldModelVectorsBeforeDecode() async throws {
        let c = try await context(rows: [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "private"),
                                          TestFixtures.photo(id: "obsolete", model: "older-model")])
        let broad = try await c.read(ids: ["a", "private"])
        let sql = try rawWriter(c)
        try await sql.exec("UPDATE photos SET image_embedding = x'FF' WHERE id IN ('private', 'obsolete')")
        let narrowed = try await c.read(ids: ["a", "obsolete", "absent"])
        XCTAssertEqual(narrowed.source, .sqlite)
        XCTAssertEqual(narrowed.records.map(\.photo.id), ["a"])
        XCTAssertNotEqual(narrowed.signature, broad.signature)
        let binary = try await c.read(using: reopened(c), ids: ["a", "obsolete", "absent"])
        XCTAssertEqual(binary.source, .binary)
        do {
            _ = try await c.read(ids: ["a", "private"])
            XCTFail("Accessible corrupt SQLite vectors must still fail, never fall back to old derived records.")
        } catch { XCTAssertFalse(error is CancellationError) }
    }

    func testExactScopeDigestIsOrderIndependentAndIncludesAbsentIDsAndBoundaries() async throws {
        let c = try await context(rows: [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "b")])
        let first = try await c.read(ids: Set(["a", "b"]))
        let reordered = try await c.read(ids: Set(["b", "a"]))
        XCTAssertEqual(reordered.source, .resident)
        XCTAssertEqual(reordered.signature, first.signature)
        let extra = try await c.read(ids: ["a", "b", "not-indexed"])
        XCTAssertEqual(extra.source, .sqlite)
        XCTAssertNotEqual(extra.signature, first.signature)
        let left = try await c.read(ids: ["a", "bc"])
        let right = try await c.read(ids: ["ab", "c"])
        XCTAssertNotEqual(left.signature, right.signature)
        let empty = try await c.read(ids: [])
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertNotEqual(empty.signature, right.signature)
    }

    func testModelChangeNeverUsesOtherModelsBinaryOrResidentRecords() async throws {
        let c = try await context(rows: [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "b", model: "other")])
        let first = try await c.read(ids: ["a", "b"])
        let other = try await c.read(model: "other", ids: ["a", "b"])
        XCTAssertEqual(other.source, .sqlite)
        XCTAssertEqual(other.records.map(\.photo.id), ["b"])
        XCTAssertNotEqual(first.signature, other.signature)
        let original = try await c.read(using: reopened(c), ids: ["a", "b"])
        XCTAssertEqual(original.source, .sqlite)
        XCTAssertEqual(original.records.map(\.photo.id), ["a"])
    }

    func testMissingSourceClearsMemoryAndDoesNotRewriteExistingDerivedFile() async throws {
        let c = try await context()
        let original = try await c.read()
        let binary = try Data(contentsOf: c.binary)
        await c.writer.close()
        try FileManager.default.removeItem(at: c.database)
        let first = try await c.read()
        let second = try await c.read()
        XCTAssertEqual(first.source, .sqlite)
        XCTAssertTrue(first.records.isEmpty)
        XCTAssertTrue(second.records.isEmpty)
        XCTAssertNotEqual(first.signature, second.signature)
        XCTAssertNotEqual(first.signature, original.signature)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.database.path))
        XCTAssertEqual(try Data(contentsOf: c.binary), binary)
        await assertCalls(c.loader, 3)
    }

    func testFailedLoaderPublishesNothingAndErrorsAreGeneric() async throws {
        let c = try await context()
        do {
            _ = try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                throw NSError(domain: "synthetic-private-id", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "synthetic-private-id and private vector bytes"])
            }
            XCTFail("Loader failures must propagate.")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-id"))
            XCTAssertFalse(error.localizedDescription.contains("vector bytes"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        let valid = try await c.read()
        XCTAssertEqual(valid.source, .sqlite)
    }

    func testCorruptDatabasePreflightCallsSQLLoaderOnceAndDoesNotHideItsFailure() async throws {
        let c = try await context(rows: [])
        // A non-SQLite file makes the monitor fail deterministically, without
        // chmod assumptions that differ between simulators and physical devices.
        let corrupt = Data("synthetic-private-database: not SQLite".utf8)
        try corrupt.write(to: c.database)
        do {
            _ = try await c.read()
            XCTFail("An unavailable monitor must still let the SQL loader report its failure.")
        } catch {
            XCTAssertFalse(error is CancellationError)
            XCTAssertFalse(error.localizedDescription.contains(c.directory.path))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private-database"))
        }
        await assertCalls(c.loader, 1)
        // The cache may sanitize its outward error. The worker retains this
        // original loader error separately; preflight must not prevent that read.
        let loaderFailure = await c.loader.failure
        let failure = try XCTUnwrap(loaderFailure as? AppFailure)
        guard case .storage = failure else { return XCTFail("Expected the original SQL storage failure.") }
        XCTAssertEqual(try Data(contentsOf: c.database), corrupt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.directory.path), ["index.sqlite3"])
    }

    func testUnavailableMonitorReturnsSuppliedSnapshotUncachedWithoutPublishing() async throws {
        let c = try await context(rows: [])
        let source = try await context()
        let corrupt = Data("synthetic-private-database: not SQLite".utf8)
        try corrupt.write(to: c.database)
        var signatures: Set<String> = []
        // Repeat on the same actor and a new actor: neither resident nor binary
        // records may be published when observation is unavailable.
        for (index, cache) in [c.cache, c.cache, reopened(c)].enumerated() {
            let result = try await cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                try await source.loader.load(model: "test-model", ids: ["a"])
            }
            XCTAssertEqual(result.source, .sqlite)
            XCTAssertEqual(result.records.map(\.photo.id), ["a"])
            XCTAssertEqual(result.records.first?.photo.imageEmbedding, TestFixtures.vector())
            XCTAssertNotNil(UUID(uuidString: result.signature))
            XCTAssertTrue(signatures.insert(result.signature).inserted)
            await assertCalls(source.loader, index + 1)
            XCTAssertEqual(try Data(contentsOf: c.database), corrupt)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.directory.path), ["index.sqlite3"])
        }
    }

    func testPreCancelledReadDoesNotLoadOrWrite() async throws {
        let c = try await context()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await c.read()
        }
        do { _ = try await task.value; XCTFail("Cancellation must throw.") }
        catch { XCTAssertTrue(error is CancellationError) }
        await assertCalls(c.loader, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
    }

    func testCancellationDuringSuspendedLoaderCannotPublishLate() async throws {
        let c = try await context()
        let gate = SearchCacheTestGate()
        let task = Task {
            try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                let records = try await c.loader.load(model: "test-model", ids: ["a"])
                await gate.pause()
                return records // Deliberately non-cooperative loader.
            }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Late loader result must not be published.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        let next = try await c.read()
        XCTAssertEqual(next.source, .sqlite)
    }

    func testInvalidateAndClearDuringLoadPreventLateMemoryAndDiskPublication() async throws {
        for clear in [false, true] {
            let c = try await context()
            let gate = SearchCacheTestGate()
            let task = Task {
                try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                    let rows = try await c.loader.load(model: "test-model", ids: ["a"])
                    await gate.pause()
                    return rows
                }
            }
            await gate.waitUntilEntered()
            if clear { try await c.cache.clear() } else { await c.cache.invalidate() }
            await gate.release()
            do { _ = try await task.value; XCTFail("Invalidated work cannot publish.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
            let next = try await c.read()
            XCTAssertEqual(next.source, .sqlite)
        }
    }

    func testCommitBetweenHashAndPublicationIsDetectedWithoutRetry() async throws {
        let c = try await context()
        let gate = SearchCacheTestGate()
        let task = Task {
            try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                let rows = try await c.loader.load(model: "test-model", ids: ["a"])
                await gate.pause()
                return rows
            }
        }
        await gate.waitUntilEntered()
        try await c.writer.save(TestFixtures.photo(id: "a", revision: 999))
        await gate.release()
        do { _ = try await task.value; XCTFail("A mixed source/snapshot must not be cached or returned as stable.") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        await assertCalls(c.loader, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        let next = try await c.read()
        XCTAssertEqual(next.records.first?.photo.modificationTime, 999)
    }

    func testNewNarrowRequestWinsOverSuspendedBroaderLoader() async throws {
        let c = try await context(rows: [TestFixtures.photo(id: "a"), TestFixtures.photo(id: "b")])
        let gate = SearchCacheTestGate()
        let broad = Task {
            try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a", "b"]) {
                let rows = try await c.loader.load(model: "test-model", ids: ["a", "b"])
                await gate.pause()
                return rows
            }
        }
        await gate.waitUntilEntered()
        let narrow = try await c.read(ids: ["a"])
        await gate.release()
        do { _ = try await broad.value; XCTFail("An older broad scope must not overwrite the new result.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let warm = try await c.read(ids: ["a"])
        let binary = try await c.read(using: reopened(c), ids: ["a"])
        XCTAssertEqual(warm.source, .resident)
        XCTAssertEqual(binary.source, .binary)
        XCTAssertEqual(warm.signature, narrow.signature)
        XCTAssertEqual(binary.records.map(\.photo.id), ["a"])
        await assertCalls(c.loader, 2)
    }

    func testReservedWriterBeforeJournalCreationAlsoBypassesResidentAndDisk() async throws {
        let c = try await context()
        _ = try await c.read()
        let binary = try Data(contentsOf: c.binary)
        let sql = try rawWriter(c)
        try await sql.exec("BEGIN IMMEDIATE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.database.path + "-journal"))
        let first = try await c.read()
        let second = try await c.read(using: reopened(c))
        XCTAssertEqual(first.source, .sqlite)
        XCTAssertEqual(second.source, .sqlite)
        XCTAssertEqual(first.records.map(\.photo.id), ["a"])
        XCTAssertNotEqual(first.signature, second.signature)
        XCTAssertEqual(try Data(contentsOf: c.binary), binary)
        await assertCalls(c.loader, 3)
        try await sql.exec("ROLLBACK")
    }

    func testJournalAndWALBypassBothCachesUseLoaderOnceAndUniqueSignatures() async throws {
        for wal in [false, true] {
            let c = try await context()
            _ = try await c.read()
            let binary = try Data(contentsOf: c.binary)
            let sql = try rawWriter(c)
            if wal {
                try await sql.exec("PRAGMA journal_mode = WAL; UPDATE photos SET revision = 456")
                XCTAssertTrue(FileManager.default.fileExists(atPath: c.database.path + "-wal"))
            } else {
                try await sql.exec("BEGIN IMMEDIATE; UPDATE photos SET revision = 456")
                XCTAssertTrue(FileManager.default.fileExists(atPath: c.database.path + "-journal"))
            }
            let first = try await c.read()
            let second = try await c.read(using: reopened(c))
            XCTAssertEqual(first.source, .sqlite)
            XCTAssertEqual(second.source, .sqlite)
            XCTAssertEqual(first.records.first?.photo.modificationTime, wal ? 456 : 123)
            XCTAssertNotEqual(first.signature, second.signature)
            XCTAssertEqual(try Data(contentsOf: c.binary), binary)
            await assertCalls(c.loader, 3)
            if !wal { try await sql.exec("ROLLBACK") }
        }
    }

    func testWriterAppearingDuringLoaderReturnsSnapshotUncachedRatherThanFailClosed() async throws {
        let c = try await context()
        let sql = try rawWriter(c)
        let gate = SearchCacheTestGate()
        let task = Task {
            try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) {
                let rows = try await c.loader.load(model: "test-model", ids: ["a"])
                await gate.pause()
                return rows
            }
        }
        await gate.waitUntilEntered()
        try await sql.exec("BEGIN IMMEDIATE; UPDATE photos SET revision = 456")
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.source, .sqlite)
        XCTAssertEqual(result.records.first?.photo.modificationTime, 123)
        XCTAssertNotNil(UUID(uuidString: result.signature))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        await assertCalls(c.loader, 1)
        try await sql.exec("ROLLBACK")
    }

    func testCorruptChecksumTruncationAndMalformedPlistFallBackToSQLite() async throws {
        let c = try await context()
        let initial = try await c.read()
        let good = try Data(contentsOf: c.binary)
        var badEnvelope = try envelope(good)
        badEnvelope["payloadSHA256"] = Data(repeating: 0, count: 32)
        let checksum = try plist(badEnvelope)
        var badPayload = try envelope(good)
        var changed = try XCTUnwrap(badPayload["payload"] as? Data)
        changed[changed.startIndex] ^= 1
        badPayload["payload"] = changed
        let corruptions = [checksum, try plist(badPayload), Data(good.prefix(good.count / 2)),
                   Data("not a binary cache".utf8)]
        for corruption in corruptions {
            try corruption.write(to: c.binary)
            let rebuilt = try await c.read(using: reopened(c))
            XCTAssertEqual(rebuilt.source, .sqlite)
            XCTAssertEqual(rebuilt.signature, initial.signature)
            XCTAssertEqual(rebuilt.records.map(\.photo.id), ["a"])
            let verified = try await c.read(using: reopened(c))
            XCTAssertEqual(verified.source, .binary)
        }
        await assertCalls(c.loader, 5)
    }

    func testChecksummedInvalidVectorBoundsNonfiniteNormAndLocationPairAreRejected() async throws {
        let c = try await context()
        _ = try await c.read()
        let good = try Data(contentsOf: c.binary)
        var nan = Data(repeating: 0, count: 768 * 4)
        nan.replaceSubrange(0..<4, with: [0, 0, 0xC0, 0x7F])
        for bad in [Data([0, 0, 0]), Data(repeating: 0, count: 768 * 4), nan] {
            let corruption = try corruptRows(good) { rows in rows[0]["image"] = bad }
            try corruption.write(to: c.binary)
            let result = try await c.read(using: reopened(c))
            XCTAssertEqual(result.source, .sqlite)
            XCTAssertEqual(result.records.first?.photo.imageEmbedding, TestFixtures.vector())
        }
        let missingVector = try corruptRows(good) { rows in rows[0]["locationText"] = "Synthetic" }
        try missingVector.write(to: c.binary)
        let result = try await c.read(using: reopened(c))
        XCTAssertEqual(result.source, .sqlite)
        XCTAssertNil(result.records.first?.photo.location)
        await assertCalls(c.loader, 5)
    }

    func testInvalidAccessibleLoaderVectorsAreNotSilentlyNormalizedOrCached() async throws {
        let c = try await context()
        for invalid in [[Float(1)], [Float](repeating: 0, count: 768), [Float](repeating: .infinity, count: 768)] {
            let bad = CachedPhoto(photo: IndexedPhoto(id: "a", modificationTime: 1, modelVersion: "test-model",
                                                       imageEmbedding: invalid), geographyVersion: "test-places")
            do {
                _ = try await c.cache.records(modelVersion: "test-model", accessibleIDs: ["a"]) { [bad] }
                XCTFail("Invalid active vectors must fail without normalizing or faking records.")
            } catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        }
    }

    func testDerivedWriteFailureDoesNotBlockSearchOrTouchDatabase() async throws {
        let c = try await context()
        let source = try Data(contentsOf: c.database)
        // A directory at the exact final path makes atomic replacement fail,
        // without relying on simulator/root-dependent chmod behavior.
        try FileManager.default.createDirectory(at: c.binary, withIntermediateDirectories: false)
        let sentinel = c.binary.appendingPathComponent("keep")
        try Data([1, 2, 3]).write(to: sentinel)
        let first = try await c.read()
        let warm = try await c.read()
        XCTAssertEqual(first.source, .sqlite)
        XCTAssertEqual(warm.source, .resident)
        XCTAssertEqual(first.records.map(\.photo.id), ["a"])
        XCTAssertEqual(try Data(contentsOf: c.database), source)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([1, 2, 3]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: c.directory.path).contains { $0.hasSuffix(".tmp") })
        do { try await c.cache.clear(); XCTFail("Clear must not recursively delete an unexpected directory.") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path)) }
    }

    func testInvalidateRetainsBinaryAndClearDeletesOnlyDerivedFile() async throws {
        let c = try await context()
        let first = try await c.read()
        let source = try Data(contentsOf: c.database)
        let ocr = c.directory.appendingPathComponent("text-index.sqlite3")
        let foreignPartial = c.directory.appendingPathComponent(".search-vectors-v1-someone-else.tmp")
        try Data("synthetic OCR sentinel".utf8).write(to: ocr)
        try Data([7]).write(to: foreignPartial)
        await c.cache.invalidate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.binary.path))
        let disk = try await c.read()
        XCTAssertEqual(disk.source, .binary)
        XCTAssertEqual(disk.signature, first.signature)
        try await c.cache.clear()
        try await c.cache.clear() // Idempotent.
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        XCTAssertEqual(try Data(contentsOf: c.database), source)
        XCTAssertEqual(try Data(contentsOf: ocr), Data("synthetic OCR sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: foreignPartial), Data([7]))
        let rebuilt = try await c.read()
        XCTAssertEqual(rebuilt.source, .sqlite)
        await assertCalls(c.loader, 2)
    }

    func testDerivedFileAndParentAreExcludedFromBackupAndProtected() async throws {
        let c = try await context()
        _ = try await c.read()
        for url in [c.directory, c.binary] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            #endif
        }
    }

    // Test-only corruption of the documented v1 binary-plist envelope. Recompute
    // both checksums to test structural/vector validation, not just bit rot.
    private func envelope(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }

    private func plist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func corruptRows(_ original: Data, edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var outer = try envelope(original)
        let payload = try XCTUnwrap(outer["payload"] as? Data)
        var rows = try XCTUnwrap(PropertyListSerialization.propertyList(from: payload, options: [], format: nil) as? [[String: Any]])
        edit(&rows)
        let changed = try plist(rows)
        let payloadHash = Data(SHA256.hash(data: changed))
        outer["payload"] = changed
        outer["payloadSHA256"] = payloadHash
        let key = try XCTUnwrap(outer["key"] as? [String: Any])
        let scope = try XCTUnwrap(key["scope"] as? [String: Any])
        var keyHash = SHA256()
        keyHash.update(data: Data("search-vectors-v1".utf8))
        for data in [try XCTUnwrap(scope["modelUTF8"] as? Data), try XCTUnwrap(scope["idsSHA256"] as? Data),
                     try XCTUnwrap(key["databaseSHA256"] as? Data)] {
            var count = UInt64(data.count).littleEndian
            Swift.withUnsafeBytes(of: &count) { keyHash.update(data: Data($0)) }
            keyHash.update(data: data)
        }
        var header = SHA256()
        header.update(data: Data("LocalImageIQ.SearchVectors:1".utf8))
        header.update(data: Data(keyHash.finalize()))
        header.update(data: payloadHash)
        outer["headerSHA256"] = Data(header.finalize())
        return try plist(outer)
    }
}

private struct SearchCacheTestContext: Sendable {
    let directory: URL
    let writer: SQLitePhotoStore
    let loader: SearchCacheTestLoader
    let cache: SearchIndexCache
    var database: URL { directory.appendingPathComponent("index.sqlite3") }
    var binary: URL { directory.appendingPathComponent("search-vectors-v1.bin") }

    func read(using other: SearchIndexCache? = nil, model: String = "test-model",
              ids: Set<String> = ["a"]) async throws -> SearchIndexCacheResult {
        let loader = self.loader
        return try await (other ?? cache).records(modelVersion: model, accessibleIDs: ids) {
            try await loader.load(model: model, ids: ids)
        }
    }
}

private actor SearchCacheTestLoader {
    private let reader: SQLitePhotoStore
    private(set) var calls = 0
    private(set) var failure: Error?

    init(directory: URL) { reader = SQLitePhotoStore(directory: directory, readOnly: true) }
    func load(model: String, ids: Set<String>) async throws -> [CachedPhoto] {
        calls += 1
        do { return try await reader.searchRecords(modelVersion: model, accessibleIDs: ids) }
        catch { failure = error; throw error }
    }
    func close() async { await reader.close() }
}

/// Deterministic suspension; no sleeps, polling, arbitrary timeouts or retries.
private actor SearchCacheTestGate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

/// The only extra writable SQL connection is to synthetic test data. It can hold
/// a real DELETE-journal transaction or WAL open while the cache is exercised.
private actor SearchCacheTestSQLWriter {
    private var connection: SearchCacheTestSQLConnection?
    init(directory: URL) throws { connection = try SearchCacheTestSQLConnection(directory: directory) }
    func exec(_ sql: String) throws {
        guard let connection else { throw SearchCacheTestError.closed }
        try connection.exec(sql)
    }
    func close() { connection = nil }
}

private enum SearchCacheTestError: Error { case closed, sqlite }

private final class SearchCacheTestSQLConnection {
    private let handle: OpaquePointer
    init(directory: URL) throws {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &pointer,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SearchCacheTestError.sqlite
        }
        handle = pointer
    }
    deinit { sqlite3_close(handle) }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw SearchCacheTestError.sqlite }
    }
}