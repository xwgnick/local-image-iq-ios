import XCTest
import SQLite3
import ImageIQCore
@testable import LocalImageIQ

final class SQLitePhotoStoreTests: XCTestCase {
    private func makeStore() throws -> (SQLitePhotoStore, URL) {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLitePhotoStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        return (store, directory)
    }

    func testRoundTripAndReopenPreservesIDRevisionModelAndPlace() async throws {
        let (store, directory) = try makeStore()
        let id = "synthetic-'quote-照片"
        let place = PlaceEmbedding(text: "Photo taken in Test Region.", vector: TestFixtures.vector(axis: 1))
        try await store.save(TestFixtures.photo(id: id, location: place))
        await store.close()
        let reopened = SQLitePhotoStore(directory: directory)
        let result = try await reopened.record(id: id)
        let cached = try XCTUnwrap(result)
        XCTAssertEqual(cached.photo.id, id)
        XCTAssertEqual(cached.photo.modificationTime, 123)
        XCTAssertEqual(cached.photo.creationTime, 100)
        XCTAssertEqual(cached.photo.modelVersion, "test-model")
        XCTAssertEqual(cached.photo.imageEmbedding, TestFixtures.vector())
        XCTAssertEqual(cached.photo.location?.vector, place.vector)
        XCTAssertEqual(cached.geographyVersion, "test-places")
        await reopened.close()
    }

    func testCompleteAuthorizationReconciliationPrunesMissingAndModifiedAssets() async throws {
        let (store, _) = try makeStore()
        for id in ["kept", "revoked", "edited"] { try await store.save(TestFixtures.photo(id: id)) }
        try await store.reconcile(completeEnumeration: [PhotoRevision(id: "kept", modificationTime: 123),
                                                       PhotoRevision(id: "edited", modificationTime: 456)])
        let records = try await store.records(modelVersion: "test-model")
        XCTAssertEqual(records.map(\.photo.id), ["kept"])
    }

    func testCancelledReconciliationDoesNotPruneCompletedRecords() async throws {
        let (store, _) = try makeStore()
        try await store.save(TestFixtures.photo())
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.reconcile(completeEnumeration: [])
        }
        do { try await cancelled.value; XCTFail("Cancelled reconciliation must throw.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let remaining = try await store.records(modelVersion: "test-model")
        XCTAssertEqual(remaining.count, 1)
    }

    func testPlacesAreReusedPerModelAndUnreferencedPlacesAreRemoved() async throws {
        let (store, _) = try makeStore()
        let text = "Photo taken in Synthetic Place."
        let place = PlaceEmbedding(text: text, vector: TestFixtures.vector(axis: 2))
        try await store.save(TestFixtures.photo(id: "a", location: place))
        try await store.save(TestFixtures.photo(id: "b", location: place))
        let reused = try await store.place(text: text, modelVersion: "test-model")
        let wrongModel = try await store.place(text: text, modelVersion: "different-model")
        XCTAssertEqual(reused, place.vector)
        XCTAssertNil(wrongModel)
        try await store.reconcile(completeEnumeration: [PhotoRevision(id: "a", modificationTime: 123)])
        let stillReferenced = try await store.place(text: text, modelVersion: "test-model")
        XCTAssertEqual(stillReferenced, place.vector)
        try await store.reconcile(completeEnumeration: [])
        let removed = try await store.place(text: text, modelVersion: "test-model")
        XCTAssertNil(removed)
    }

    func testInvalidVectorCannotOverwriteCompletedRecord() async throws {
        let (store, _) = try makeStore()
        try await store.save(TestFixtures.photo())
        let invalid = IndexedPhoto(id: "synthetic-asset", modificationTime: 999, modelVersion: "test-model", imageEmbedding: [1])
        do {
            try await store.save(CachedPhoto(photo: invalid, geographyVersion: "test-places"))
            XCTFail("Invalid embeddings must be rejected.")
        } catch { }
        let kept = try await store.record(id: "synthetic-asset")
        XCTAssertEqual(kept?.photo.modificationTime, 123)
    }

    func testCacheIsProtectedAndExcludedFromBackup() async throws {
        let (store, directory) = try makeStore()
        try await store.save(TestFixtures.photo())
        for url in [directory, directory.appendingPathComponent("index.sqlite3")] {
            let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
            XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
    }

    func testClearRemovesPhotosAndPlaceVectors() async throws {
        let (store, _) = try makeStore()
        let text = "Photo taken in Synthetic Place."
        try await store.save(TestFixtures.photo(location: PlaceEmbedding(text: text, vector: TestFixtures.vector())))
        try await store.clear()
        let records = try await store.records(modelVersion: "test-model")
        let place = try await store.place(text: text, modelVersion: "test-model")
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(place)
    }

    func testClearRecoversUnreadableDatabase() async throws {
        let (store, directory) = try makeStore()
        try Data("not a SQLite database".utf8).write(to: directory.appendingPathComponent("index.sqlite3"))
        do { _ = try await store.records(modelVersion: "test-model"); XCTFail("Corrupt file must fail.") }
        catch { }
        try await store.clear()
        try await store.save(TestFixtures.photo())
        let records = try await store.records(modelVersion: "test-model")
        XCTAssertEqual(records.count, 1)
    }

    func testDatabaseSchemaDoesNotPersistGPSOrImageBytes() async throws {
        let (store, directory) = try makeStore()
        try await store.save(TestFixtures.photo())
        await store.close()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "PRAGMA table_info(photos)", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement)
        defer { sqlite3_finalize(query) }
        var columns: [String] = []
        while sqlite3_step(query) == SQLITE_ROW {
            let text = try XCTUnwrap(sqlite3_column_text(query, 1))
            columns.append(String(cString: text))
        }
        XCTAssertEqual(Set(columns), Set(["id", "revision", "model_version", "image_embedding", "creation_time", "place_text", "geography_version"]))
    }
}