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
        XCTAssertEqual(cached.photo.imageEmbedding.count, 768)
        XCTAssertEqual(cached.photo.location?.vector.count, 768)
        try EmbeddingValidation.validateUnit(cached.photo.imageEmbedding)
        try EmbeddingValidation.validateUnit(try XCTUnwrap(cached.photo.location).vector)
        XCTAssertEqual(cached.geographyVersion, "test-places")
        await reopened.close()
    }

    func testRawLegacy512PhotosAndPlacesRemainReadableButAreExcludedFromCurrentModel() async throws {
        let (store, directory) = try makeStore()
        let oldVersion = IndexImagePolicy.cacheVersion(modelVersion: TestFixtures.legacyModelVersion)
        let text = "Photo taken in Shared Synthetic Place."
        let legacyPlace = PlaceEmbedding(text: text, vector: TestFixtures.vector(axis: 511, dimension: 512))
        let legacyPhoto = IndexedPhoto(id: "legacy-'quote-照片", modificationTime: 123, modelVersion: oldVersion,
                                        imageEmbedding: TestFixtures.vector(axis: 510, dimension: 512),
                                        location: legacyPlace, creationTime: 100)
        try TestFixtures.seedRawCache([CachedPhoto(photo: legacyPhoto, geographyVersion: "test-places")], directory: directory)
        let currentPlace = PlaceEmbedding(text: text, vector: TestFixtures.vector(axis: 767))
        try await store.save(TestFixtures.photo(id: "current", location: currentPlace))
        await store.close()

        for readOnly in [false, true] {
            let reader = SQLitePhotoStore(directory: directory, readOnly: readOnly)
            do {
                let result = try await reader.record(id: legacyPhoto.id)
                let retained = try XCTUnwrap(result)
                XCTAssertEqual(retained.photo.modificationTime, 123)
                XCTAssertEqual(retained.photo.creationTime, 100)
                XCTAssertEqual(retained.photo.modelVersion, oldVersion)
                XCTAssertEqual(retained.photo.imageEmbedding, legacyPhoto.imageEmbedding)
                XCTAssertEqual(retained.photo.imageEmbedding.count, 512)
                XCTAssertEqual(retained.photo.location?.text, legacyPlace.text)
                XCTAssertEqual(retained.photo.location?.vector, legacyPlace.vector)
                XCTAssertEqual(retained.geographyVersion, "test-places")
                let oldRows = try await reader.records(modelVersion: oldVersion)
                let currentRows = try await reader.records(modelVersion: "test-model")
                let oldPlace = try await reader.place(text: text, modelVersion: oldVersion)
                let activePlace = try await reader.place(text: text, modelVersion: "test-model")
                XCTAssertEqual(oldRows.map(\.photo.id), [legacyPhoto.id])
                XCTAssertEqual(currentRows.map(\.photo.id), ["current"])
                XCTAssertEqual(currentRows.first?.photo.imageEmbedding.count, 768)
                XCTAssertEqual(oldPlace, legacyPlace.vector)
                XCTAssertEqual(activePlace, currentPlace.vector)
            } catch {
                await reader.close()
                throw error
            }
            await reader.close()
        }
    }

    func testNewSaveRejectsLegacy512ImageAndPlaceVectorsEvenWithOldModelVersion() async throws {
        let (store, _) = try makeStore()
        for model in ["test-model", TestFixtures.legacyModelVersion] {
            for legacyImage in [true, false] {
                let id = "rejected-\(model)-\(legacyImage)"
                let text = "Photo taken in Rejected \(id)."
                let place = PlaceEmbedding(text: text, vector: TestFixtures.vector(dimension: legacyImage ? 768 : 512))
                let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model,
                                         imageEmbedding: TestFixtures.vector(dimension: legacyImage ? 512 : 768),
                                         location: place, creationTime: 100)
                do {
                    try await store.save(CachedPhoto(photo: photo, geographyVersion: "test-places"))
                    XCTFail("Only legacy reads may accept 512 values; new saves must reject them.")
                } catch AppFailure.modelContract { }
                catch { XCTFail("Unexpected error: \(error)") }
                let rejected = try await store.record(id: id)
                let rejectedPlace = try await store.place(text: text, modelVersion: model)
                XCTAssertNil(rejected)
                XCTAssertNil(rejectedPlace, "Validation must precede both writes.")
            }
        }
    }

    func testCurrentCacheReadsRejectNonUnitAndUnsupportedDimensionBlobs() async throws {
        let invalidVectors = [[Float](repeating: 0, count: 768), TestFixtures.vector().map { $0 * 2 },
                              [Float(1)], TestFixtures.vector(dimension: 767), TestFixtures.vector(dimension: 769)]
        for invalid in invalidVectors {
            for invalidImage in [true, false] {
                let (store, directory) = try makeStore()
                let place = PlaceEmbedding(text: "Photo taken in Invalid Synthetic Place.",
                                           vector: invalidImage ? TestFixtures.vector() : invalid)
                let photo = IndexedPhoto(id: "invalid", modificationTime: 123, modelVersion: "test-model",
                                         imageEmbedding: invalidImage ? invalid : TestFixtures.vector(), location: place)
                try TestFixtures.seedRawCache([CachedPhoto(photo: photo, geographyVersion: "test-places")], directory: directory)
                do { _ = try await store.record(id: "invalid"); XCTFail("Malformed cached vectors must not be normalized on read.") }
                catch AppFailure.modelContract { }
                catch { XCTFail("Unexpected row error: \(error)") }
                do { _ = try await store.records(modelVersion: "test-model"); XCTFail("Gallery reads must validate cached vectors.") }
                catch AppFailure.modelContract { }
                catch { XCTFail("Unexpected gallery error: \(error)") }
                if !invalidImage {
                    do { _ = try await store.place(text: place.text, modelVersion: "test-model"); XCTFail("Place reads must validate cached vectors.") }
                    catch AppFailure.modelContract { }
                    catch { XCTFail("Unexpected place error: \(error)") }
                }
            }
        }
    }

    func testCountsFilterModelAndGeographyAndCountSharedPlacesPerPhoto() async throws {
        let (store, _) = try makeStore()
        let empty = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        XCTAssertEqual(empty.indexed, 0)
        XCTAssertEqual(empty.located, 0)

        let place = PlaceEmbedding(text: "Photo taken in Shared '照片' Place.", vector: TestFixtures.vector(axis: 2))
        for id in ["a", "b"] { try await store.save(TestFixtures.photo(id: id, location: place)) }
        let stale = TestFixtures.photo(id: "stale-geography", location: place)
        try await store.save(CachedPhoto(photo: stale.photo, geographyVersion: "old-places"))
        try await store.save(TestFixtures.photo(id: "no-place"))
        try await store.save(TestFixtures.photo(id: "other-model", model: "other-model", location: place))

        let current = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        XCTAssertEqual(current.indexed, 4)
        XCTAssertEqual(current.located, 2, "Shared places count once per photo, not once per label.")
        let oldGeography = try await store.counts(modelVersion: "test-model", geographyVersion: "old-places")
        XCTAssertEqual(oldGeography.indexed, 4)
        XCTAssertEqual(oldGeography.located, 1)
        let missingGeography = try await store.counts(modelVersion: "test-model", geographyVersion: "missing-places")
        XCTAssertEqual(missingGeography.indexed, 4)
        XCTAssertEqual(missingGeography.located, 0)
        let otherModel = try await store.counts(modelVersion: "other-model", geographyVersion: "test-places")
        XCTAssertEqual(otherModel.indexed, 1)
        XCTAssertEqual(otherModel.located, 1)
        let missingModel = try await store.counts(modelVersion: "missing-model", geographyVersion: "test-places")
        XCTAssertEqual(missingModel.indexed, 0)
        XCTAssertEqual(missingModel.located, 0)
    }

    func testCountsDoNotLocateDanglingOrWrongModelPlaceReferences() async throws {
        let (store, directory) = try makeStore()
        let shared = PlaceEmbedding(text: "Photo taken in Shared Place.", vector: TestFixtures.vector(axis: 1))
        let missing = PlaceEmbedding(text: "Photo taken in Missing Place.", vector: TestFixtures.vector(axis: 2))
        try await store.save(TestFixtures.photo(id: "wrong-model-reference", location: shared))
        try await store.save(TestFixtures.photo(id: "missing-reference", location: missing))
        try await store.save(TestFixtures.photo(id: "other-model", model: "other-model", location: shared))
        await store.close()
        do {
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                         &handle, SQLITE_OPEN_READWRITE, nil)
            defer { if let handle { sqlite3_close(handle) } }
            XCTAssertEqual(status, SQLITE_OK)
            let database = try XCTUnwrap(handle)
            XCTAssertEqual(sqlite3_exec(database, "DELETE FROM places WHERE model_version = 'test-model'", nil, nil, nil), SQLITE_OK)
        }

        let counts = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        XCTAssertEqual(counts.indexed, 2)
        XCTAssertEqual(counts.located, 0, "A same-text place under another model does not repair a broken reference.")
        let otherModel = try await store.counts(modelVersion: "other-model", geographyVersion: "test-places")
        XCTAssertEqual(otherModel.indexed, 1)
        XCTAssertEqual(otherModel.located, 1)
    }

    func testCountsAreMetadataOnlyWhileRecordsStillRejectInvalidEmbeddings() async throws {
        let invalid = [Float](repeating: 0, count: 768)
        for invalidImage in [true, false] {
            let (store, directory) = try makeStore()
            let place = PlaceEmbedding(text: "Photo taken in Invalid Vector Place.",
                                       vector: invalidImage ? TestFixtures.vector() : invalid)
            let photo = IndexedPhoto(id: "invalid", modificationTime: 123, modelVersion: "test-model",
                                     imageEmbedding: invalidImage ? invalid : TestFixtures.vector(), location: place)
            // Valid JSON with an invalid unit vector bypasses save's validation deliberately.
            try TestFixtures.seedRawCache([CachedPhoto(photo: photo, geographyVersion: "test-places")], directory: directory)
            let counts = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
            XCTAssertEqual(counts.indexed, 1)
            XCTAssertEqual(counts.located, 1, "Metadata presence must not be mistaken for a validated place vector.")
            do {
                _ = try await store.records(modelVersion: "test-model")
                XCTFail("Gallery reads must still reject invalid image and place vectors.")
            } catch AppFailure.modelContract { }
            catch { XCTFail("Unexpected gallery error: \(error)") }
            let unchanged = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
            XCTAssertEqual(unchanged.indexed, 1)
            XCTAssertEqual(unchanged.located, 1)
        }
    }

    func testCancelledCountsLeavePhotosAndOrphanPlacesUnchanged() async throws {
        let (store, _) = try makeStore()
        let oldPlace = PlaceEmbedding(text: "Photo taken in Old Place.", vector: TestFixtures.vector(axis: 1))
        let newPlace = PlaceEmbedding(text: "Photo taken in New Place.", vector: TestFixtures.vector(axis: 2))
        try await store.save(TestFixtures.photo(location: oldPlace))
        try await store.save(TestFixtures.photo(location: newPlace))
        let before = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        XCTAssertEqual(before.indexed, 1)
        XCTAssertEqual(before.located, 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled counts must throw.") }
        catch { XCTAssertTrue(error is CancellationError) }

        let after = try await store.counts(modelVersion: "test-model", geographyVersion: "test-places")
        XCTAssertEqual(after.indexed, before.indexed)
        XCTAssertEqual(after.located, before.located)
        let records = try await store.records(modelVersion: "test-model")
        XCTAssertEqual(records.map(\.photo.id), ["synthetic-asset"])
        XCTAssertEqual(records.first?.photo.modificationTime, 123)
        XCTAssertEqual(records.first?.photo.imageEmbedding, TestFixtures.vector())
        XCTAssertEqual(records.first?.photo.location?.text, newPlace.text)
        XCTAssertEqual(records.first?.photo.location?.vector, newPlace.vector)
        XCTAssertEqual(records.first?.geographyVersion, "test-places")
        let orphan = try await store.place(text: oldPlace.text, modelVersion: "test-model")
        XCTAssertEqual(orphan, oldPlace.vector, "Neither successful nor cancelled counts may perform orphan cleanup.")
    }

    func testReconciliationRemovesOverwriteOrphansWithoutObsoletePhotos() async throws {
        let oldPlace = PlaceEmbedding(text: "Photo taken in Old Place.", vector: TestFixtures.vector(axis: 1))
        let newPlace = PlaceEmbedding(text: "Photo taken in New Place.", vector: TestFixtures.vector(axis: 2))
        for (model, place) in [("test-model", newPlace), ("other-model", oldPlace), ("other-model", newPlace)] {
            let (store, _) = try makeStore()
            try await store.save(TestFixtures.photo(id: "kept", location: oldPlace))
            try await store.save(TestFixtures.photo(id: "kept", model: model, location: place))
            let orphanBefore = try await store.place(text: oldPlace.text, modelVersion: "test-model")
            XCTAssertEqual(orphanBefore, oldPlace.vector, "Overwriting a retained photo can leave a place orphan.")

            try await store.reconcile(completeEnumeration: [PhotoRevision(id: "kept", modificationTime: 123)])
            let records = try await store.records(modelVersion: model)
            XCTAssertEqual(records.map(\.photo.id), ["kept"])
            XCTAssertEqual(records.first?.photo.modificationTime, 123)
            XCTAssertEqual(records.first?.photo.location?.text, place.text)
            let orphanAfter = try await store.place(text: oldPlace.text, modelVersion: "test-model")
            let referenced = try await store.place(text: place.text, modelVersion: model)
            XCTAssertNil(orphanAfter, "Cleanup must run even when no photo is obsolete.")
            XCTAssertEqual(referenced, place.vector)
        }
    }

    func testReconciliationMatchesExactModelTextPairsIncludingBinaryUnicode() async throws {
        let (store, _) = try makeStore()
        let text = "Caf\u{00E9}-照片's Place"
        let rows: [(id: String, model: String, text: String?, keep: Bool)] = [
            ("kept-place", "test-model", text, true),
            ("removed-same-text", "other-model", text, false),
            ("kept-other-model", "other-model", "Different Place", true),
            ("removed-decomposed", "test-model", "Cafe\u{0301}-照片's Place", false),
            ("removed-case-variant", "test-model", "CAF\u{00C9}-照片's Place", false),
            ("kept-without-place", "test-model", nil, true)
        ]
        for row in rows {
            let place = row.text.map { PlaceEmbedding(text: $0, vector: TestFixtures.vector(axis: 2)) }
            try await store.save(TestFixtures.photo(id: row.id, model: row.model, location: place))
        }
        let retained = rows.filter { $0.keep }.map { PhotoRevision(id: $0.id, modificationTime: 123) }
        try await store.reconcile(completeEnumeration: retained)

        for row in rows {
            let cached = try await store.record(id: row.id)
            XCTAssertEqual(cached != nil, row.keep, row.id)
            if let text = row.text {
                let vector = try await store.place(text: text, modelVersion: row.model)
                if row.keep { XCTAssertEqual(vector, TestFixtures.vector(axis: 2), row.id) }
                else { XCTAssertNil(vector, "Only the exact binary (text, model) pair may retain \(row.id).") }
            }
        }
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
        let originalPlace = PlaceEmbedding(text: "Photo taken in Kept Place.", vector: TestFixtures.vector(axis: 767))
        try await store.save(TestFixtures.photo(location: originalPlace))
        var invalidVectors = [[Float(1)], TestFixtures.vector(dimension: 512)]
        for value in [Float(0), 2, .nan, .infinity, -.infinity] {
            var invalid = [Float](repeating: 0, count: 768)
            invalid[0] = value
            invalidVectors.append(invalid)
        }
        for vector in invalidVectors {
            for invalidImage in [true, false] {
                let invalid = IndexedPhoto(id: "synthetic-asset", modificationTime: 999, modelVersion: "test-model",
                                           imageEmbedding: invalidImage ? vector : TestFixtures.vector(),
                                           location: PlaceEmbedding(text: originalPlace.text,
                                                                    vector: invalidImage ? originalPlace.vector : vector))
                do {
                    try await store.save(CachedPhoto(photo: invalid, geographyVersion: "changed-places"))
                    XCTFail("Invalid embeddings must be rejected, not normalized on save.")
                } catch AppFailure.modelContract { }
                catch { XCTFail("Unexpected error: \(error)") }
                let kept = try await store.record(id: "synthetic-asset")
                XCTAssertEqual(kept?.photo.modificationTime, 123)
                XCTAssertEqual(kept?.photo.modelVersion, "test-model")
                XCTAssertEqual(kept?.photo.imageEmbedding, TestFixtures.vector())
                XCTAssertEqual(kept?.photo.location?.text, originalPlace.text)
                XCTAssertEqual(kept?.photo.location?.vector, originalPlace.vector)
                XCTAssertEqual(kept?.geographyVersion, "test-places")
            }
        }
    }

    func testCacheIsExcludedFromBackup() async throws {
        let (store, directory) = try makeStore()
        try await store.save(TestFixtures.photo())
        for url in [directory, directory.appendingPathComponent("index.sqlite3")] {
            let resourceValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
        }
    }

    func testCacheFileProtectionOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Simulator filesystem does not expose iOS data-protection attributes. Run on a physical iPhone; production protection settings remain enabled.")
        #else
        let (store, directory) = try makeStore()
        try await store.save(TestFixtures.photo())
        for url in [directory, directory.appendingPathComponent("index.sqlite3")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? (attributes[.protectionKey] as? String)
            XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
        #endif
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