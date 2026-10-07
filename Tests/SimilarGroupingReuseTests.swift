import Foundation
import ImageIO
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Actual SQLite and binary-cache integration; Photos metadata and the resource
/// inspector alone are fake. No physical photos, OCR, inference, CI or network.
final class SimilarGroupingReuseTests: XCTestCase {
    private let model = IndexImagePolicy.cacheVersion(modelVersion: "test-model")

    private func photo(_ id: String, axis: Int = 0, modification: Double = 123,
                       creation: Double? = 100, model: String? = nil, vector: [Float]? = nil,
                       place: Bool = false) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: modification, modelVersion: model ?? self.model,
                     imageEmbedding: vector ?? TestFixtures.vector(axis: axis),
                     location: place ? PlaceEmbedding(text: "Unused place", vector: TestFixtures.vector(axis: 6)) : nil,
                     creationTime: creation)
    }

    private func context(photos: [IndexedPhoto]? = nil, authorized: [PhotoRevision]? = nil,
                         generation: UInt64? = 0, seed: Bool = true) throws -> ReuseContext {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let input = photos ?? [photo("a"), photo("b")]
        if seed { try TestFixtures.seedRawCache(input.map { CachedPhoto(photo: $0, geographyVersion: "geo-v1") }, directory: root) }
        let revisions: [PhotoRevision] = authorized ?? input.map {
            PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime)
        }
        return ReuseContext(directory: root, library: ReuseLibrary(revisions, generation: generation), encoders: try ReuseEncoders())
    }

    private func fresh(_ c: ReuseContext, threshold: Float = 0.80,
                       cache: SimilarGroupingCache? = nil) async throws -> SimilarPhotoGroupingResult {
        try await c.service(cache: cache).group(threshold: threshold) { _ in }
    }

    private func restored(_ outcome: SimilarPhotoGroupingRestore, file: StaticString = #filePath,
                          line: UInt = #line) throws -> SimilarPhotoGroupingResult {
        guard case .restored(let result) = outcome else {
            XCTFail("Expected restored completed groups.", file: file, line: line)
            throw ReuseFailure.test
        }
        return result
    }

    private func assertStale(_ outcome: SimilarPhotoGroupingRestore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .stale = outcome else { XCTFail("Changed/corrupt is stale, not missing.", file: file, line: line); return }
    }

    private func assertMissing(_ outcome: SimilarPhotoGroupingRestore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .missing = outcome else { XCTFail("Expected no completed cache.", file: file, line: line); return }
    }

    private func failure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure, not fallback computation.", file: file, line: line) }
        catch { }
    }

    private func storageFailure(_ operation: () async throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Source invalidation must throw storage, not return a warning.", file: file, line: line) }
        catch AppFailure.storage { }
        catch { XCTFail("Wrong failure: \(error).", file: file, line: line) }
    }

    private func assertStorage(_ operation: () throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) {
        do { try operation(); XCTFail("Expected storage failure.", file: file, line: line) }
        catch AppFailure.storage { }
        catch { XCTFail("Wrong failure: \(error).", file: file, line: line) }
    }

    private func assertNoInference(_ c: ReuseContext, file: StaticString = #filePath, line: UInt = #line) async {
        let counts = await c.encoders.counts()
        XCTAssertEqual(counts.forbidden, 0, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
        XCTAssertEqual(c.library.placeCalls, 0, file: file, line: line)
    }

    private func snapshot(_ c: ReuseContext, ids: Set<String>? = nil, model: String? = nil) async throws -> SimilarGroupingInputSnapshot {
        let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
        return try await reader.groupingInputSnapshot(modelVersion: model ?? self.model,
                                                      accessibleIDs: ids ?? Set(c.library.values().map(\.id)))
    }

    func testApprovedPolicyDefaultAndProtocolDefaultKeepLegacyMocksCompatible() async throws {
        XCTAssertEqual(SimilarPhotoGroupingPolicy.defaultThreshold, 0.80)
        XCTAssertEqual(SimilarPhotoGroupingPolicy.thresholdRange, Float(0.50)...Float(0.99))
        let legacy: any SimilarPhotoGrouping = ReuseLegacyGrouping()
        assertMissing(try await legacy.restore(threshold: 0.80))
        let result = try await legacy.group(threshold: 0.80) { _ in }
        XCTAssertNil(result.persistenceIssue)
        try await result.prepareForPublication()
    }

    func testInitIsIdleAndMissingRestoreNeverCreatesFolderOrComputes() async throws {
        let c = try context(seed: false)
        let root = c.directory.appendingPathComponent("missing", isDirectory: true)
        let service = SimilarPhotoGroupingService(library: c.library, directory: root, encoders: c.encoders)
        XCTAssertEqual(c.library.enumerations, 0)
        let before = await c.encoders.counts()
        XCTAssertEqual(before.inspections, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        assertMissing(try await service.restore(threshold: 0.80))
        XCTAssertEqual(c.library.enumerations, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await assertNoInference(c)
    }

    func testManualGroupingUsesThreeFullSnapshotsThenColdRestoreUsesTwoAndKeepsExactBinaryVectors() async throws {
        let c = try context(photos: [photo("a", place: true), photo("b", place: true), photo("single", axis: 2)])
        let source = try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3"))
        let first = try await fresh(c)
        XCTAssertEqual(c.library.enumerations, 3)
        XCTAssertEqual(first.groups.map(\.id), ["a"])
        XCTAssertEqual(first.candidateCount, 3)
        XCTAssertNil(first.persistenceIssue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.cacheURL.path))
        let bytes = try Data(contentsOf: c.cacheURL)
        let second = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(c.library.enumerations, 5)
        XCTAssertEqual(second.groups.map(\.id), first.groups.map(\.id))
        XCTAssertEqual(second.candidateCount, first.candidateCount)
        XCTAssertEqual(second.groups[0].photos[0].imageEmbedding.map(\.bitPattern), first.groups[0].photos[0].imageEmbedding.map(\.bitPattern))
        XCTAssertTrue(second.groups.flatMap(\.photos).allSatisfy { $0.location == nil })
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), bytes, "Restore is read-only.")
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3")), source)
        await assertNoInference(c)
    }

    func testNewServiceAndNewMetadataInspectorRestoreAfterSimulatedRestart() async throws {
        let c = try context()
        _ = try await fresh(c)
        let library = ReuseLibrary(Array(c.library.values().reversed()), generation: 900)
        let encoders = try ReuseEncoders()
        let service = SimilarPhotoGroupingService(library: library, directory: c.directory, encoders: encoders)
        let result = try restored(await service.restore(threshold: 0.80))
        XCTAssertEqual(result.groups[0].photos.map(\.id), ["a", "b"])
        XCTAssertEqual(library.enumerations, 2)
        let counts = await encoders.counts()
        XCTAssertEqual(counts.inspections, 1)
        XCTAssertEqual(counts.forbidden, 0)
        XCTAssertEqual(library.pixelCalls, 0)
    }

    func testCompletedZeroGroupsReuseWithoutRerunningGrouperIncludingNoImageIndex() async throws {
        let inputs: [[IndexedPhoto]] = [[], [photo("single")], [photo("a"), photo("b", axis: 1)]]
        for input in inputs {
            let c = try context(photos: input)
            let first = try await fresh(c)
            XCTAssertTrue(first.groups.isEmpty)
            let cold = try restored(await c.service().restore(threshold: 0.80))
            XCTAssertTrue(cold.groups.isEmpty)
            XCTAssertEqual(cold.candidateCount, input.count)
            XCTAssertEqual(c.library.enumerations, 5)
            await assertNoInference(c)
        }
        let c = try context(seed: false)
        let zero = try await fresh(c)
        XCTAssertEqual(zero.unindexedCount, 2)
        let cold = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(cold.unindexedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.appendingPathComponent("index.sqlite3").path))
    }

    func testCountsIncludeStaleActiveRowsButExcludeOldModelsAndUnauthorizedRows() async throws {
        let photos: [IndexedPhoto] = [photo("a"), photo("b"), photo("single", axis: 1),
            photo("stale", modification: 122, vector: []), photo("old", model: "retired", vector: []), photo("hidden", vector: [])]
        var authorized: [PhotoRevision] = []
        for id in ["a", "b", "single", "stale", "old", "new"] {
            authorized.append(PhotoRevision(id: id, modificationTime: 123, creationTime: 100))
        }
        let c = try context(photos: photos, authorized: authorized)
        let first = try await fresh(c)
        XCTAssertEqual(first.candidateCount, 3)
        XCTAssertEqual(first.staleCount, 1)
        XCTAssertEqual(first.unindexedCount, 2)
        let read = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(read.candidateCount, 3)
        XCTAssertEqual(read.staleCount, 1)
        XCTAssertEqual(read.unindexedCount, 2)
        await assertNoInference(c)
    }

    func testFavoriteAlbumOnlyGenerationChangesReuseWhenFullRevisionsMatch() async throws {
        let c = try context()
        _ = try await fresh(c)
        for generation in [UInt64(1), 8, 99] {
            c.library.setGeneration(generation)
            let result = try restored(await c.service().restore(threshold: 0.80))
            try await result.prepareForPublication()
            try result.validatePublicationEpoch()
            XCTAssertEqual(result.groups.count, 1)
        }
        await assertNoInference(c)
    }

    func testThresholdAndModelChangesAreStaleAndNeverOverwriteExistingCache() async throws {
        let c = try context()
        _ = try await fresh(c)
        let before = try Data(contentsOf: c.cacheURL)
        assertStale(try await c.service().restore(threshold: Float(0.80).nextUp))
        let changed = try ReuseEncoders(model: "next-model")
        let service = SimilarPhotoGroupingService(library: c.library, directory: c.directory, encoders: changed)
        assertStale(try await service.restore(threshold: 0.80))
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), before)
        let counts = await changed.counts()
        XCTAssertEqual(counts.forbidden, 0)
        await assertNoInference(c)
    }

    func testEqualCountIDSwapAndModificationCreationNilChangesInvalidateWithoutGeneration() async throws {
        for change in 0..<4 {
            let c = try context(generation: nil)
            _ = try await fresh(c)
            switch change {
            case 0: c.library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100), PhotoRevision(id: "c", modificationTime: 123, creationTime: 100)])
            case 1: c.library.setRevision("b", modification: 124, creation: 100)
            case 2: c.library.setRevision("b", modification: 123, creation: 101)
            default: c.library.setRevision("b", modification: 123, creation: nil)
            }
            XCTAssertEqual(c.library.values().count, 2)
            assertStale(try await c.service().restore(threshold: 0.80))
            await assertNoInference(c)
        }
    }

    func testNewUnindexedAndSingletonRevisionChangesInvalidateTheEntireCompletedResult() async throws {
        let photos: [IndexedPhoto] = [photo("a"), photo("b"), photo("single", axis: 2)]
        var authorized = photos.map { PhotoRevision(id: $0.id, modificationTime: 123, creationTime: 100) }
        authorized.append(PhotoRevision(id: "new", modificationTime: 123, creationTime: 100))
        for id in ["single", "new"] {
            let c = try context(photos: photos, authorized: authorized, generation: nil)
            _ = try await fresh(c)
            c.library.setRevision(id, modification: 123, creation: 101)
            assertStale(try await c.service().restore(threshold: 0.80))
        }
    }

    func testAuthorizationChangesStaleEvenWhenFullScopeAndCountStaySame() async throws {
        let c = try context()
        _ = try await fresh(c)
        c.library.setAuthorization(4)
        assertStale(try await c.service().restore(threshold: 0.80))
        c.library.setAuthorization(nil)
        assertStale(try await c.service().restore(threshold: 0.80))
        await assertNoInference(c)
    }

    func testPermissionFailureRetainsClassificationAndDoesNotBecomeMissing() async throws {
        let c = try context()
        _ = try await fresh(c)
        c.library.setReadable(false)
        let before = try Data(contentsOf: c.cacheURL)
        do { _ = try await c.service().restore(threshold: 0.80); XCTFail("Expected permission.") }
        catch AppFailure.permission { }
        XCTAssertEqual(c.library.enumerations, 3)
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), before)
        c.library.setReadable(true)
        _ = try restored(await c.service().restore(threshold: 0.80))
    }

    func testPermissionLossDuringInspectionAndFinalSnapshotIsNotSwallowed() async throws {
        for duringInspection in [true, false] {
            let c = try context()
            _ = try await fresh(c)
            let library = c.library
            if duringInspection { await c.encoders.onInspection { library.setReadable(false) } }
            else { library.onEnumeration { number in if number == 5 { library.setReadable(false) } } }
            defer { library.onEnumeration(nil) }
            do { _ = try await c.service().restore(threshold: 0.80); XCTFail("Expected permission classification.") }
            catch AppFailure.permission { }
            await assertNoInference(c)
        }
    }

    func testGenerationOrAuthorizationChangeDuringRestoreRequiresManualRetry() async throws {
        for change in 0..<3 {
            let c = try context()
            _ = try await fresh(c)
            let library = c.library
            if change == 0 { await c.encoders.onInspection { library.setGeneration(1) } }
            else {
                library.onEnumeration { number in
                    if number == 5 {
                        if change == 1 { library.setGeneration(1) }
                        else { library.setAuthorization(4) }
                    }
                }
            }
            defer { library.onEnumeration(nil) }
            await failure { _ = try await c.service().restore(threshold: 0.80) }
            await assertNoInference(c)
        }
    }

    func testFinalRestoreFullSnapshotDetectsUnindexedMutationWithNilGeneration() async throws {
        let authorized: [PhotoRevision] = [PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
            PhotoRevision(id: "b", modificationTime: 123, creationTime: 100), PhotoRevision(id: "new", modificationTime: 123, creationTime: 100)]
        let c = try context(authorized: authorized, generation: nil)
        _ = try await fresh(c)
        let library = c.library
        library.onEnumeration { number in if number == 5 { library.setRevision("new", modification: 123, creation: 101) } }
        defer { library.onEnumeration(nil) }
        await failure { _ = try await c.service().restore(threshold: 0.80) }
        XCTAssertEqual(library.enumerations, 5)
    }

    func testSameRevisionImageVectorRewriteInvalidatesButIdenticalSaveDoesNot() async throws {
        let c = try context()
        _ = try await fresh(c)
        let writer = SQLitePhotoStore(directory: c.directory)
        try await writer.save(CachedPhoto(photo: photo("a"), geographyVersion: "changed-geography"))
        await writer.close()
        _ = try restored(await c.service().restore(threshold: 0.80))
        try await writer.save(CachedPhoto(photo: photo("a", axis: 1), geographyVersion: "changed-geography"))
        await writer.close()
        assertStale(try await c.service().restore(threshold: 0.80))
        await assertNoInference(c)
    }

    func testGeographyOnlyInvalidLocationBlobAndOCRChangesDoNotInvalidateOrDecode() async throws {
        let c = try context(photos: [photo("a", place: true), photo("b", place: true)])
        _ = try await fresh(c)
        let before = try await snapshot(c)
        try ReuseSQL.execute(c.directory, "UPDATE places SET embedding = X'FF00FE'; UPDATE photos SET geography_version = 'changed', place_text = 'Unused place'")
        try Data("invalid OCR SQLite and JSON".utf8).write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        try Data("invalid geography".utf8).write(to: c.directory.appendingPathComponent("Places.geojson"))
        let after = try await snapshot(c)
        XCTAssertEqual(before, after)
        c.library.setGeneration(2)
        let result = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(result.groups.count, 1)
        // Demonstrate that the OLD joined loader would fail on these exact bytes.
        let old = SQLitePhotoStore(directory: c.directory, readOnly: true)
        await failure { _ = try await old.searchRecords(modelVersion: model, accessibleIDs: ["a", "b"]) }
        let manual = try await fresh(c)
        XCTAssertNil(manual.persistenceIssue)
        await assertNoInference(c)
    }

    func testSourceSnapshotHashesOpaqueInvalidImageJSONAndRestoreReadsOnlyBinaryVectors() async throws {
        let c = try context()
        // Strong no-source-JSON proof: seed a synthetic completed cache bound to
        // invalid source JSON. Cache vectors are still full valid 768-D binaries.
        try ReuseSQL.execute(c.directory, "UPDATE photos SET image_embedding = X'FF00FE'")
        let source = try await snapshot(c)
        let authorized = Dictionary(uniqueKeysWithValues: c.library.values().map { ($0.id, $0) })
        let identity = try SimilarGroupingCacheKey(authorized: authorized, imagePayloadSignature: source.imagePayloadSignature,
                                                  modelVersion: model, authorization: 3, threshold: 0.80)
        try SimilarGroupingCache(directory: c.directory).save(groups: [SimilarPhotoGroup(id: "a", photos: [photo("a"), photo("b")], minimumSimilarity: 1)],
            candidateCount: 2, staleCount: 0, unindexedCount: 0, key: identity, authorized: authorized, indexed: source.revisions)
        let result = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(result.groups[0].photos[0].imageEmbedding.count, 768)
        XCTAssertEqual(c.library.enumerations, 2)
        await failure { _ = try await fresh(c) } // Manual computation MUST decode/validate source vectors.
        await assertNoInference(c)
    }

    func testActiveImageRewriteToInvalidJSONIsStaleNotDecodeFailureAndSourceIsPreserved() async throws {
        let c = try context()
        _ = try await fresh(c)
        try ReuseSQL.execute(c.directory, "UPDATE photos SET image_embedding = X'FF00' WHERE id = 'a'")
        let before = try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3"))
        assertStale(try await c.service().restore(threshold: 0.80))
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3")), before)
        await assertNoInference(c)
    }

    func testStaleActiveVectorRewriteAlsoInvalidatesButInaccessibleAndOldModelWritesDoNot() async throws {
        let input: [IndexedPhoto] = [photo("a"), photo("b"), photo("stale", modification: 122, vector: []),
            photo("hidden", vector: []), photo("old", model: "retired", vector: [])]
        let authorized = ["a", "b", "stale", "old"].map { PhotoRevision(id: $0, modificationTime: 123, creationTime: 100) }
        let c = try context(photos: input, authorized: authorized)
        _ = try await fresh(c)
        try ReuseSQL.execute(c.directory, "UPDATE photos SET image_embedding = X'FF0001', revision = 999 WHERE id IN ('hidden', 'old')")
        _ = try restored(await c.service().restore(threshold: 0.80))
        try ReuseSQL.execute(c.directory, "UPDATE photos SET image_embedding = X'FF0002' WHERE id = 'stale'")
        assertStale(try await c.service().restore(threshold: 0.80))
    }

    func testMissingRowEmptyIndexAndUnsupportedSourceSchemaNeverRestoreOldGroups() async throws {
        for mutation in ["DELETE FROM photos WHERE id = 'b'", "DELETE FROM photos", "PRAGMA user_version = 99"] {
            let c = try context()
            _ = try await fresh(c)
            try ReuseSQL.execute(c.directory, mutation)
            if mutation.contains("user_version") {
                await failure { _ = try await c.service().restore(threshold: 0.80) }
            } else { assertStale(try await c.service().restore(threshold: 0.80)) }
        }
        let c = try context()
        _ = try await fresh(c)
        try FileManager.default.removeItem(at: c.directory.appendingPathComponent("index.sqlite3"))
        assertStale(try await c.service().restore(threshold: 0.80))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.appendingPathComponent("index.sqlite3").path))
    }

    func testSourceSnapshotFiltersBeforeVectorBytesIncludesFullStaleMetadataAndRequiresReadOnly() async throws {
        let c = try context(photos: [photo("a"), photo("b", creation: nil), photo("stale", modification: 122, vector: []),
                                    photo("hidden", vector: []), photo("old", model: "retired", vector: [])])
        try ReuseSQL.execute(c.directory, "UPDATE photos SET image_embedding = X'FF' WHERE id IN ('hidden', 'old')")
        let source = try await snapshot(c, ids: ["a", "b", "stale", "old", "new"])
        XCTAssertEqual(source.revisions.count, 3)
        XCTAssertEqual(source.revisions["stale"]?.modificationTime, 122)
        XCTAssertNil(source.revisions["b"]?.creationTime)
        XCTAssertEqual(source.imagePayloadSignature.count, 32)
        let reversed = try await snapshot(c, ids: Set(["new", "old", "stale", "b", "a"]))
        XCTAssertEqual(source, reversed)
        let writer = SQLitePhotoStore(directory: c.directory)
        await failure { _ = try await writer.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"]) }
        XCTAssertEqual(c.library.enumerations, 0)
        await assertNoInference(c)
    }

    func testGroupingReaderRejectsChangedBytesBetweenInitialSignatureAndActualDecode() async throws {
        let c = try context()
        let source = try await snapshot(c)
        let encoded = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
        try ReuseSQL.setImage(c.directory, id: "a", bytes: encoded)
        let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
        await failure {
            _ = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a", "b"],
                                                       eligibleIDs: ["a", "b"], expectedSnapshot: source)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
    }

    func testVectorRewriteDuringManualComputeFailsBeforePersistenceDespiteSamePhotosRevisions() async throws {
        let c = try context()
        let directory = c.directory
        let rewritten = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
        let mutation = ReuseOnce()
        await failure {
            _ = try await c.service().group(threshold: 0.80) { state in
                if state.completed == state.total, mutation.take() {
                    do { try ReuseSQL.setImage(directory, id: "a", bytes: rewritten) }
                    catch { XCTFail("Synthetic mutation failed: \(error).") }
                }
            }
        }
        XCTAssertEqual(c.library.enumerations, 2, "The live source fence rejects immediately after progress, before the final snapshot.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
        await assertNoInference(c)
    }

    func testVectorRewriteDuringRestoreFinalSnapshotRequiresRetryInsteadOfReturningCachedGroups() async throws {
        let c = try context()
        _ = try await fresh(c)
        let directory = c.directory
        let rewritten = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
        c.library.onEnumeration { number in if number == 5 { try ReuseSQL.setImage(directory, id: "a", bytes: rewritten) } }
        defer { c.library.onEnumeration(nil) }
        await failure { _ = try await c.service().restore(threshold: 0.80) }
        XCTAssertEqual(c.library.enumerations, 5)
        await assertNoInference(c)
    }

    @MainActor
    func testRestoredPublicationRetainsOffMainBatchAndCheapFinalEpochFence() async throws {
        let c = try context()
        _ = try await fresh(c)
        c.library.setGeneration(42)
        let value = try restored(await c.service().restore(threshold: 0.80))
        XCTAssertEqual(c.library.batchRequests, [])
        try await value.prepareForPublication()
        XCTAssertEqual(c.library.batchThreads, [false])
        XCTAssertEqual(c.library.batchRequests, [["a", "b"]])
        XCTAssertTrue(Thread.isMainThread)
        try value.validatePublicationEpoch()
        XCTAssertEqual(c.library.enumerations, 5)
        XCTAssertEqual(c.library.batchRequests.count, 1)
        c.library.setGeneration(43)
        XCTAssertThrowsError(try value.validatePublicationEpoch())
        await assertNoInference(c)
    }

    func testRestoredSelectionChecksExactScopeBeforeBatchAndDeduplicatesRequests() async throws {
        let c = try context(photos: [photo("a"), photo("b"), photo("single", axis: 1)])
        _ = try await fresh(c)
        let value = try restored(await c.service().restore(threshold: 0.80))
        for id in ["single", "outside", ""] { XCTAssertThrowsError(try value.validatePhotos(["a", id])) }
        XCTAssertEqual(c.library.batchRequests, [])
        try value.validatePhotos(["b", "a", "b"])
        XCTAssertEqual(c.library.batchRequests, [["b", "a"]])
        try value.validatePhotos([])
        XCTAssertEqual(c.library.batchRequests.count, 1)
    }

    func testRestoredBatchRequiresExactCountUniqueIDsAndFullRevisionIncludingNilGeneration() async throws {
        let c = try context(generation: nil)
        _ = try await fresh(c)
        let value = try restored(await c.service().restore(threshold: 0.80))
        let a = PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)
        let b = PhotoRevision(id: "b", modificationTime: 123, creationTime: 100)
        let other = PhotoRevision(id: "other", modificationTime: 123, creationTime: 100)
        let bad: [[PhotoRevision]] = [[], [a], [a, a], [a, other], [a, b, other],
            [a, PhotoRevision(id: "b", modificationTime: 124, creationTime: 100)],
            [a, PhotoRevision(id: "b", modificationTime: 123, creationTime: nil)]]
        for reply in bad {
            c.library.overrideBatch(reply)
            await failure { try await value.prepareForPublication() }
        }
        c.library.overrideBatch([b, a])
        try await value.prepareForPublication()
        XCTAssertEqual(c.library.singleReads, 0)
        XCTAssertEqual(c.library.enumerations, 6, "Successful nil-generation preparation also checks the complete authorized scope.")
    }

    func testRestoredBatchEpochChecksBeforeAndAfterReadingAndPropagatesBatchFailure() async throws {
        for change in 0..<4 {
            let c = try context()
            _ = try await fresh(c)
            let value = try restored(await c.service().restore(threshold: 0.80))
            let library = c.library
            library.afterBatch {
                switch change {
                case 0: library.setReadable(false)
                case 1: library.setAuthorization(4)
                case 2: library.setGeneration(1)
                default: throw ReuseFailure.test
                }
            }
            defer { library.afterBatch(nil) }
            await failure { try await value.prepareForPublication() }
            XCTAssertEqual(library.batchRequests.count, 1)
            XCTAssertEqual(library.singleReads, 0)
            if change < 3 { XCTAssertThrowsError(try value.validatePhotos([])) }
        }
    }

    func testRestoredLegacyPerIDValidatorDeduplicatesAndStillChecksFullRevisions() async throws {
        let c = try context(generation: nil)
        _ = try await fresh(c)
        let legacy = ReuseLegacyLibrary(base: c.library)
        let service = SimilarPhotoGroupingService(library: legacy, directory: c.directory, encoders: c.encoders)
        let result = try restored(await service.restore(threshold: 0.80))
        XCTAssertThrowsError(try result.validatePhotos(["a", "unknown"]))
        XCTAssertEqual(c.library.singleReads, 0)
        try result.validatePhotos(["b", "a", "b"])
        XCTAssertEqual(c.library.singleReads, 2)
        XCTAssertEqual(c.library.batchRequests, [])
        c.library.setRevision("b", modification: 123, creation: nil)
        XCTAssertThrowsError(try result.validatePhotos(["b"]))
        XCTAssertEqual(c.library.enumerations, 5)
    }

    func testRestoredBatchRejectsCancellationAfterReadAndBeforeEpochPublication() async throws {
        let c = try context()
        _ = try await fresh(c)
        let result = try restored(await c.service().restore(threshold: 0.80))
        c.library.afterBatch { withUnsafeCurrentTask { $0?.cancel() } }
        defer { c.library.afterBatch(nil) }
        let task = Task { try await result.prepareForPublication() }
        do { try await task.value; XCTFail("Cancelled batch cannot publish cached groups.") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error).") }
        XCTAssertEqual(c.library.batchRequests, [["a", "b"]])
    }

    func testRestoredZeroGroupsPrepareWithoutBatchButStillEnforceCurrentEpoch() async throws {
        let c = try context(photos: [photo("single")])
        _ = try await fresh(c)
        let result = try restored(await c.service().restore(threshold: 0.80))
        try await result.prepareForPublication()
        try result.validatePhotos([])
        XCTAssertEqual(c.library.batchRequests, [])
        c.library.setGeneration(1)
        XCTAssertThrowsError(try result.validatePublicationEpoch())
        XCTAssertThrowsError(try result.validatePhotos([]))
    }

    func testUnknownAlgorithmVersionInCompletedPayloadIsStaleAtServiceBoundary() async throws {
        let c = try context()
        let source = try await snapshot(c)
        let authorized = Dictionary(uniqueKeysWithValues: c.library.values().map { ($0.id, $0) })
        let key = try SimilarGroupingCacheKey(authorized: authorized, imagePayloadSignature: source.imagePayloadSignature,
                                             modelVersion: model, authorization: 3, threshold: 0.80,
                                             algorithmVersion: "retired-algorithm")
        try SimilarGroupingCache(directory: c.directory).save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                                                               key: key, authorized: authorized, indexed: source.revisions)
        assertStale(try await c.service().restore(threshold: 0.80))
        await assertNoInference(c)
    }

    func testMissingCachedMemberAfterRestoreIsRejectedBeforePublicationWithNilGeneration() async throws {
        let c = try context(generation: nil)
        _ = try await fresh(c)
        let value = try restored(await c.service().restore(threshold: 0.80))
        c.library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
        await failure { try await value.prepareForPublication() }
        XCTAssertThrowsError(try value.validatePhotos(["b"]))
    }

    func testCancelledRestoreDoesNotComputeDeleteOrRewriteCache() async throws {
        let c = try context()
        _ = try await fresh(c)
        let bytes = try Data(contentsOf: c.cacheURL)
        let gate = ReuseGate()
        await c.encoders.onInspection { await gate.block() }
        let service = c.service()
        let task = Task { try await service.restore(threshold: 0.80) }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled restore returned.") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error).") }
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), bytes)
        await assertNoInference(c)
    }

    func testConcurrentNewOperationInvalidatesSuspendedGroupingBeforeItCanSave() async throws {
        let c = try context()
        let service = c.service()
        let gate = ReuseGate()
        let task = Task {
            try await service.group(threshold: 0.80) { progress in if progress.completed == 0 { await gate.block() } }
        }
        await gate.waitUntilEntered()
        assertMissing(try await service.restore(threshold: 0.80))
        await gate.release()
        do { _ = try await task.value; XCTFail("Superseded computation must not save.") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error).") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
    }

    func testWriteFailureReturnsValidFreshGroupsAndOptionalIssueInsteadOfFailingOperation() async throws {
        let c = try context()
        _ = try await fresh(c)
        let before = try Data(contentsOf: c.cacheURL)
        let failing = SimilarGroupingCache(directory: c.directory, beforeCommit: { throw ReuseFailure.test })
        let result = try await fresh(c, threshold: 0.90, cache: failing)
        XCTAssertEqual(result.groups[0].photos.map(\.id), ["a", "b"])
        XCTAssertEqual(result.candidateCount, 2)
        XCTAssertNotNil(result.persistenceIssue)
        try await result.prepareForPublication()
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), before)
        assertStale(try await c.service().restore(threshold: 0.90))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.directory.path).filter { $0.hasSuffix(".tmp") }, [])
        await assertNoInference(c)
    }

    func testRealUnsafeCacheDestinationReturnsFreshGroupsWithWarningAndPreservesImageDatabase() async throws {
        let c = try context()
        let sourceURL = c.directory.appendingPathComponent("index.sqlite3")
        let before = try Data(contentsOf: sourceURL)
        try FileManager.default.createSymbolicLink(at: c.cacheURL, withDestinationURL: sourceURL)
        let result = try await fresh(c)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertNotNil(result.persistenceIssue)
        try await result.prepareForPublication()
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: c.cacheURL.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        assertStale(try await c.service().restore(threshold: 0.80))
        await assertNoInference(c)
    }

    func testFirstWriteFailureDoesNotPretendCompletionWasPersisted() async throws {
        let c = try context()
        let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: { throw ReuseFailure.test })
        let result = try await fresh(c, cache: cache)
        XCTAssertNotNil(result.persistenceIssue)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
        assertMissing(try await c.service().restore(threshold: 0.80))
    }

    func testCancellationDuringCacheCommitIsFatalNotOptionalPersistenceWarning() async throws {
        let c = try context()
        _ = try await fresh(c)
        let before = try Data(contentsOf: c.cacheURL)
        let cancelling = SimilarGroupingCache(directory: c.directory, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let service = c.service(cache: cancelling)
        let task = Task { try await service.group(threshold: 0.90) { _ in } }
        do { _ = try await task.value; XCTFail("Cancellation must not return groups plus warning.") }
        catch is CancellationError { }
        catch { XCTFail("Wrong error: \(error).") }
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), before)
    }

    func testPermissionLossAtCacheCommitPropagatesAndPreservesOldFile() async throws {
        let c = try context()
        _ = try await fresh(c)
        let before = try Data(contentsOf: c.cacheURL)
        let library = c.library
        let denied = SimilarGroupingCache(directory: c.directory, beforeCommit: { library.setReadable(false) })
        do { _ = try await fresh(c, threshold: 0.90, cache: denied); XCTFail("Permission must not become a persistence warning.") }
        catch AppFailure.permission { }
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), before)
    }

    func testCorruptAndSymlinkCompletedCachesAreStaleWithoutFallbackOrSourceWrites() async throws {
        for symlink in [false, true] {
            let c = try context()
            let sourceURL = c.directory.appendingPathComponent("index.sqlite3")
            let before = try Data(contentsOf: sourceURL)
            if symlink { try FileManager.default.createSymbolicLink(at: c.cacheURL, withDestinationURL: sourceURL) }
            else { try Data("broken completed cache".utf8).write(to: c.cacheURL) }
            assertStale(try await c.service().restore(threshold: 0.80))
            XCTAssertEqual(try Data(contentsOf: sourceURL), before)
            await assertNoInference(c)
        }
    }

    func testSameRevisionSourceRewriteAtBeforeCommitRejectsRenameAndNeverInstallsResident() async throws {
        for existingCache in [false, true] {
            let c = try context()
            if existingCache { _ = try await fresh(c) }
            let previous: Data?
            if existingCache { previous = try Data(contentsOf: c.cacheURL) }
            else { previous = nil }
            let directory = c.directory
            let bytes = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
            let attempts = ReuseCounter()
            let cache = SimilarGroupingCache(directory: directory, beforeCommit: {
                try attempts.record { try ReuseSQL.setImage(directory, id: "a", bytes: bytes) }
            })
            let service = c.service(cache: cache)
            await storageFailure { _ = try await service.group(threshold: 0.90) { _ in } }
            XCTAssertEqual(attempts.count, 1)
            if let previous { XCTAssertEqual(try Data(contentsOf: c.cacheURL), previous) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path)) }
            let outcome = try await service.restore(threshold: 0.90)
            if existingCache { assertStale(outcome) } else { assertMissing(outcome) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }, [])
            XCTAssertEqual(c.library.values().map(\.modificationTime), [123, 123])
            await assertNoInference(c)
        }
    }

    func testOptionalPersistenceErrorCannotSwallowConcurrentSourceRewrite() async throws {
        let c = try context()
        _ = try await fresh(c)
        let previous = try Data(contentsOf: c.cacheURL)
        let directory = c.directory
        let bytes = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
        let cache = SimilarGroupingCache(directory: directory, beforeCommit: {
            try ReuseSQL.setImage(directory, id: "a", bytes: bytes)
            throw ReuseFailure.test // The optional I/O catch still has to check the source.
        })
        await storageFailure { _ = try await c.service(cache: cache).group(threshold: 0.90) { _ in } }
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), previous)
    }

    func testComputedAndRestoredResultsRejectRewriteAfterReturnBeforePreparation() async throws {
        for restore in [false, true] {
            let c = try context()
            let service = c.service()
            let computed = try await service.group(threshold: 0.80) { _ in }
            let result: SimilarPhotoGroupingResult
            if restore { result = try restored(await c.service().restore(threshold: 0.80)) }
            else { result = computed }
            let before = c.library.enumerations
            try ReuseSQL.setImage(c.directory, id: "a", bytes: JSONEncoder().encode(TestFixtures.vector(axis: 1)))
            await storageFailure { try await result.prepareForPublication() }
            assertStorage { try result.validatePublicationEpoch() }
            assertStorage { try result.validatePhotos(["a"]) }
            assertStorage { try result.validatePhotos([]) }
            XCTAssertEqual(c.library.batchRequests, [], "Reject known-stale source before Photos reads.")
            XCTAssertEqual(c.library.enumerations, before)
            assertStale(try await service.restore(threshold: 0.80))
        }
    }

    @MainActor
    func testComputedAndRestoredFinalMainActorFenceRejectsPostPreparationRewriteWithoutFullReads() async throws {
        for restore in [false, true] {
            let c = try context()
            let computed = try await fresh(c)
            let result: SimilarPhotoGroupingResult
            if restore { result = try restored(await c.service().restore(threshold: 0.80)) }
            else { result = computed }
            try await result.prepareForPublication()
            XCTAssertEqual(c.library.batchThreads, [false])
            let enumerations = c.library.enumerations
            let batches = c.library.batchRequests
            try ReuseSQL.setImage(c.directory, id: "a", bytes: JSONEncoder().encode(TestFixtures.vector(axis: 1)))
            XCTAssertTrue(Thread.isMainThread)
            assertStorage { try result.validatePublicationEpoch() }
            XCTAssertEqual(c.library.enumerations, enumerations)
            XCTAssertEqual(c.library.batchRequests, batches)
        }
    }

    func testComputedAndRestoredBatchPostReadFenceRejectsSourceRewrite() async throws {
        for restore in [false, true] {
            let c = try context()
            let computed = try await fresh(c)
            let result: SimilarPhotoGroupingResult
            if restore { result = try restored(await c.service().restore(threshold: 0.80)) }
            else { result = computed }
            let directory = c.directory
            let bytes = try JSONEncoder().encode(TestFixtures.vector(axis: 1))
            c.library.afterBatch { try ReuseSQL.setImage(directory, id: "a", bytes: bytes) }
            defer { c.library.afterBatch(nil) }
            await storageFailure { try await result.prepareForPublication() }
            XCTAssertEqual(c.library.batchRequests, [["a", "b"]])
        }
    }

    func testLocationOnlyCommitInvalidatesOldLiveAuthorityButFreshResidentFingerprintReuses() async throws {
        let c = try context(photos: [photo("a", place: true), photo("b", place: true)])
        let saves = ReuseCounter()
        let progress = ReuseCounter()
        let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: { saves.record {} })
        let service = c.service(cache: cache)
        let first = try await service.group(threshold: 0.80) { _ in progress.record {} }
        let ticks = progress.count
        let bytes = try Data(contentsOf: c.cacheURL)
        try ReuseSQL.execute(c.directory, "UPDATE places SET embedding = X'FF'; UPDATE photos SET geography_version = 'new'")
        assertStorage { try first.validatePublicationEpoch() }
        let reused = try restored(await service.restore(threshold: 0.80))
        try await reused.prepareForPublication()
        try reused.validatePublicationEpoch()
        XCTAssertEqual(reused.groups.map(\.id), first.groups.map(\.id))
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(progress.count, ticks)
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), bytes)
        await assertNoInference(c)
    }

    func testPreviouslyMissingSourceAppearingAtBeforeCommitRejectsOldEmptyResult() async throws {
        let c = try context(seed: false)
        let directory = c.directory
        let rows: [CachedPhoto] = [CachedPhoto(photo: photo("a"), geographyVersion: "unused"),
                                   CachedPhoto(photo: photo("b"), geographyVersion: "unused")]
        let cache = SimilarGroupingCache(directory: directory, beforeCommit: {
            try TestFixtures.seedRawCache(rows, directory: directory)
        })
        await storageFailure { _ = try await c.service(cache: cache).group(threshold: 0.80) { _ in } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path))
    }

    func testReaderActorRejectsAuthorityThatChangedBeforeInitialSnapshotOrDecode() async throws {
        for beforeInitial in [false, true] {
            let c = try context()
            let authority = try SimilarGroupingSourceAuthority(directory: c.directory)
            let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
            let original = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a", "b"], authority: authority)
            try ReuseSQL.setImage(c.directory, id: "a", bytes: JSONEncoder().encode(TestFixtures.vector(axis: 1)))
            await storageFailure {
                if beforeInitial {
                    _ = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a", "b"], authority: authority)
                } else {
                    _ = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a", "b"],
                        eligibleIDs: ["a", "b"], expectedSnapshot: original, authority: authority)
                }
            }
        }
    }

    func testAuthorityMissingSourceIsReadOnlyAndDetectsAppearanceEvenWithEmptyScope() async throws {
        let c = try context(seed: false)
        let root = c.directory.appendingPathComponent("not-created", isDirectory: true)
        let authority = try SimilarGroupingSourceAuthority(directory: root)
        try authority.validate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try authority.validate() // Creating only the optional cache directory is fine.
        try TestFixtures.seedRawCache([], directory: root)
        assertStorage { try authority.validate() }
    }

    func testSameBytesDatabaseReplacementInvalidatesLiveButFreshRestoreCanReuse() async throws {
        let c = try context()
        let first = try await fresh(c)
        let source = c.directory.appendingPathComponent("index.sqlite3")
        let bytes = try Data(contentsOf: source)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        // Keep the unlinked connection's original inode alive, guaranteeing a
        // different object even with the same bytes, size and restored mtime.
        try FileManager.default.moveItem(at: source, to: c.directory.appendingPathComponent("previous.sqlite3"))
        try bytes.write(to: source)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        assertStorage { try first.validatePublicationEpoch() }
        let reused = try restored(await c.service().restore(threshold: 0.80))
        try await reused.prepareForPublication()
        XCTAssertEqual(reused.groups.map(\.id), first.groups.map(\.id))
    }

    func testAuthorityRejectsDatabaseAndDirectorySymlinksWithoutFollowingThem() async throws {
        let c = try context()
        let source = c.directory.appendingPathComponent("index.sqlite3")
        let bytes = try Data(contentsOf: source)
        let alias = c.directory.appendingPathComponent("directory-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: c.directory)
        assertStorage { _ = try SimilarGroupingSourceAuthority(directory: alias) }
        let target = c.directory.appendingPathComponent("actual.sqlite3")
        try FileManager.default.moveItem(at: source, to: target)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        assertStorage { _ = try SimilarGroupingSourceAuthority(directory: c.directory) }
        await storageFailure { _ = try await c.service().restore(threshold: 0.80) }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    func testAuthorityRejectsReservedWriterBeforeAnyDataVersionCommit() throws {
        let c = try context()
        let authority = try SimilarGroupingSourceAuthority(directory: c.directory)
        let bytes = try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3"))
        try ReuseSQL.withPendingWriter(c.directory) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.appendingPathComponent("index.sqlite3-journal").path))
            assertStorage { try authority.validate() }
            assertStorage { _ = try SimilarGroupingSourceAuthority(directory: c.directory) }
        }
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3")), bytes)
        let fresh = try SimilarGroupingSourceAuthority(directory: c.directory)
        try fresh.validate()
    }

    func testFirstWriteFailureRetainsResidentAcrossUnrelatedGenerationWithoutComputeOrSave() async throws {
        let c = try context()
        let saves = ReuseCounter()
        let progress = ReuseCounter()
        let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: {
            try saves.record { throw ReuseFailure.test }
        })
        let service = c.service(cache: cache)
        let first = try await service.group(threshold: 0.80) { _ in progress.record {} }
        XCTAssertNotNil(first.persistenceIssue)
        let ticks = progress.count
        c.library.setGeneration(1)
        XCTAssertThrowsError(try first.validatePublicationEpoch())
        let reused = try restored(await service.restore(threshold: 0.80))
        try await reused.prepareForPublication()
        try reused.validatePublicationEpoch()
        XCTAssertEqual(reused.persistenceIssue, first.persistenceIssue)
        XCTAssertEqual(reused.groups[0].photos.map(\.imageEmbedding), first.groups[0].photos.map(\.imageEmbedding))
        XCTAssertEqual(c.library.enumerations, 5, "Group 3 + restore 2; nonnil publication needs no full scan.")
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(progress.count, ticks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
        assertMissing(try await c.service().restore(threshold: 0.80))
        await assertNoInference(c)
    }

    func testMatchingResidentWinsOverDifferentThresholdDiskCacheAndCarriesWriteWarning() async throws {
        let c = try context()
        _ = try await fresh(c, threshold: 0.80)
        let disk = try Data(contentsOf: c.cacheURL)
        let saves = ReuseCounter()
        let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: {
            try saves.record { throw ReuseFailure.test }
        })
        let service = c.service(cache: cache)
        let first = try await service.group(threshold: 0.90) { _ in }
        c.library.setGeneration(1)
        let reused = try restored(await service.restore(threshold: 0.90))
        XCTAssertEqual(reused.threshold, 0.90)
        XCTAssertEqual(reused.persistenceIssue, first.persistenceIssue)
        XCTAssertNotNil(reused.persistenceIssue)
        try await reused.prepareForPublication()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(try Data(contentsOf: c.cacheURL), disk)
        assertStale(try await c.service().restore(threshold: 0.90))
        let fallback = try restored(await service.restore(threshold: 0.80))
        XCTAssertEqual(fallback.threshold, 0.80)
        XCTAssertNil(fallback.persistenceIssue, "A matching disk payload did persist successfully.")
        XCTAssertEqual(saves.count, 1)
    }

    func testResidentMismatchCannotExposeOldScopeRevisionsVectorsOrThresholdAsMissingFirstUse() async throws {
        for change in 0..<5 {
            let c = try context()
            let saves = ReuseCounter()
            let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: {
                try saves.record { throw ReuseFailure.test }
            })
            let service = c.service(cache: cache)
            let first = try await service.group(threshold: 0.80) { _ in }
            var threshold: Float = 0.80
            switch change {
            case 0:
                c.library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
                c.library.setGeneration(1)
                XCTAssertThrowsError(try first.validatePhotos(["b"]))
            case 1: c.library.setRevision("b", modification: 123, creation: nil)
            case 2: try ReuseSQL.setImage(c.directory, id: "a", bytes: JSONEncoder().encode(TestFixtures.vector(axis: 1)))
            case 3: c.library.setAuthorization(4)
            default: threshold = 0.90
            }
            assertStale(try await service.restore(threshold: threshold))
            assertStale(try await service.restore(threshold: threshold))
            XCTAssertEqual(saves.count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
            await assertNoInference(c)
        }
    }

    func testFailedWriteZeroGroupPayloadsRemainReusableInSameService() async throws {
        let inputs: [[IndexedPhoto]] = [[], [photo("single")], [photo("a"), photo("b", axis: 1)]]
        for input in inputs {
            let c = try context(photos: input)
            let saves = ReuseCounter()
            let cache = SimilarGroupingCache(directory: c.directory, beforeCommit: {
                try saves.record { throw ReuseFailure.test }
            })
            let service = c.service(cache: cache)
            let first = try await service.group(threshold: 0.80) { _ in }
            c.library.setGeneration(100)
            let reused = try restored(await service.restore(threshold: 0.80))
            XCTAssertTrue(reused.groups.isEmpty)
            XCTAssertEqual(reused.candidateCount, input.count)
            XCTAssertEqual(reused.persistenceIssue, first.persistenceIssue)
            XCTAssertNotNil(reused.persistenceIssue)
            try await reused.prepareForPublication()
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(c.library.enumerations, 5)
        }
    }

    func testDiskRestoredPayloadAlsoBecomesInstanceResidentWithoutRepairingMissingDisk() async throws {
        let c = try context()
        _ = try await fresh(c)
        let service = c.service()
        _ = try restored(await service.restore(threshold: 0.80))
        try FileManager.default.removeItem(at: c.cacheURL)
        c.library.setGeneration(1)
        let reused = try restored(await service.restore(threshold: 0.80))
        XCTAssertEqual(reused.groups.count, 1)
        try await reused.prepareForPublication()
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path), "Restore must not repair or save.")
        assertMissing(try await c.service().restore(threshold: 0.80))
    }

    @MainActor
    func testNilGenerationPublicationDetectsUnindexedCountRevisionChangesOffMain() async throws {
        let input = [photo("a"), photo("b")]
        let original = [PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                        PhotoRevision(id: "b", modificationTime: 123, creationTime: 100),
                        PhotoRevision(id: "new", modificationTime: 123, creationTime: 100)]
        var changed = original
        changed[2] = PhotoRevision(id: "new", modificationTime: 123, creationTime: 101)
        try await assertNilGenerationPublicationRejects(input: input, original: original, changed: changed)
    }

    @MainActor
    func testNilGenerationPublicationDetectsUngroupedSingletonChangesOffMain() async throws {
        let input = [photo("a"), photo("b"), photo("single", axis: 1)]
        let original = input.map { PhotoRevision(id: $0.id, modificationTime: 123, creationTime: 100) }
        var changed = original
        changed[2] = PhotoRevision(id: "single", modificationTime: 124, creationTime: 100)
        try await assertNilGenerationPublicationRejects(input: input, original: original, changed: changed)
    }

    @MainActor
    func testNilGenerationPublicationDetectsNewScopeAfterSuccessfulZeroGroupsOffMain() async throws {
        try await assertNilGenerationPublicationRejects(input: [], original: [],
            changed: [PhotoRevision(id: "new", modificationTime: 123, creationTime: 100)])
    }

    @MainActor
    private func assertNilGenerationPublicationRejects(input: [IndexedPhoto], original: [PhotoRevision],
                                                       changed: [PhotoRevision]) async throws {
        for restore in [false, true] {
            let c = try context(photos: input, authorized: original, generation: nil)
            let computed = try await fresh(c)
            let result: SimilarPhotoGroupingResult
            if restore { result = try restored(await c.service().restore(threshold: 0.80)) }
            else { result = computed }
            let before = c.library.enumerations
            c.library.replace(changed)
            await failure { try await result.prepareForPublication() }
            XCTAssertEqual(c.library.enumerations, before + 1)
            XCTAssertEqual(c.library.enumerationThreads.last, false)
            c.library.replace(original)
            try await result.prepareForPublication()
            XCTAssertEqual(c.library.enumerations, before + 2)
            XCTAssertTrue(Thread.isMainThread)
            try result.validatePublicationEpoch()
            try result.validatePhotos([])
            XCTAssertEqual(c.library.enumerations, before + 2, "The final synchronous fence must remain cheap.")
        }
    }

    func testInvalidThresholdAndDuplicatePhotoMetadataFailWithoutCreatingCache() async throws {
        let c = try context()
        await failure { _ = try await c.service().restore(threshold: .nan) }
        XCTAssertEqual(c.library.enumerations, 0)
        let a = PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)
        c.library.replace([a, a])
        await failure { _ = try await c.service().restore(threshold: 0.80) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.cacheURL.path))
        let counts = await c.encoders.counts()
        XCTAssertEqual(counts.inspections, 0)
    }
}

private struct ReuseContext: Sendable {
    let directory: URL
    let library: ReuseLibrary
    let encoders: ReuseEncoders
    var cacheURL: URL { directory.appendingPathComponent(SimilarGroupingCache.fileName) }
    func service(cache: SimilarGroupingCache? = nil) -> SimilarPhotoGroupingService {
        SimilarPhotoGroupingService(library: library, directory: directory, encoders: encoders, cache: cache)
    }
}

private enum ReuseFailure: Error { case test }

private final class ReuseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    // Fault hooks must support throwing closures; never erase/reclassify errors.
    func record<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        value += 1
        lock.unlock()
        return try operation()
    }
}

/// Deliberately does not conform to PhotoRevisionBatchReading.
private struct ReuseLegacyLibrary: PhotoLibraryIndexing {
    let base: ReuseLibrary
    var canReadImages: Bool { base.canReadImages }
    var authorizationStatusRawValue: Int? { base.authorizationStatusRawValue }
    var changeGeneration: UInt64? { base.changeGeneration }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] { try base.enumerateAuthorizedImages() }
    func currentRevision(id: String) -> PhotoRevision? { base.currentRevision(id: id) }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { base.placeLabel(id: id, resolver: resolver) }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        try await base.indexImage(id: id, networkAllowed: networkAllowed)
    }
}

private struct ReuseLegacyGrouping: SimilarPhotoGrouping {
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        SimilarPhotoGroupingResult(groups: [], candidateCount: 0, staleCount: 0, unindexedCount: 0, threshold: threshold)
    }
}

private final class ReuseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

private actor ReuseGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private actor ReuseEncoders: PhotoEncoding {
    struct Counts: Sendable { var inspections = 0; var forbidden = 0 }
    private var counters = Counts()
    private let manifest: ModelManifest
    private var inspectionAction: (@Sendable () async throws -> Void)?
    init(model: String = "test-model") throws {
        let text = TestFixtures.manifest.replacingOccurrences(of: "test-model", with: model)
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(text.utf8))
    }
    func counts() -> Counts { counters }
    func onInspection(_ action: @escaping @Sendable () async throws -> Void) { inspectionAction = action }
    func inspectResources() async throws -> ModelManifest {
        counters.inspections += 1
        try await inspectionAction?()
        return manifest
    }
    private func forbidden() -> AppFailure {
        counters.forbidden += 1
        XCTFail("Cleanup restore/group must not prepare models, infer, or create encoder workers.")
        return .modelContract("Unexpected inference.")
    }
    func prepare() throws -> ModelManifest { throw forbidden() }
    func image(preview: IndexingImage) throws -> [Float] { throw forbidden() }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] { throw forbidden() }
    func text(_ text: String) throws -> [Float] { throw forbidden() }
    func makeIndexingImageEncoders() throws -> [any PhotoImageEncoding] { throw forbidden() }
}

private final class ReuseLibrary: PhotoLibraryIndexing, PhotoRevisionBatchReading, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [PhotoRevision]
    private var readable = true
    private var authorization: Int? = 3
    private var generation: UInt64?
    private var fullCalls = 0
    private var fullThreads: [Bool] = []
    private var pixelCount = 0
    private var placeCount = 0
    private var singles = 0
    private var batches: [[String]] = []
    private var threads: [Bool] = []
    private var batchOverride: [PhotoRevision]?
    private var enumerationAction: (@Sendable (Int) throws -> Void)?
    private var batchAction: (@Sendable () throws -> Void)?

    init(_ revisions: [PhotoRevision], generation: UInt64? = 0) {
        self.revisions = revisions
        self.generation = generation
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { generation } }
    var enumerations: Int { locked { fullCalls } }
    var enumerationThreads: [Bool] { locked { fullThreads } }
    var pixelCalls: Int { locked { pixelCount } }
    var placeCalls: Int { locked { placeCount } }
    var singleReads: Int { locked { singles } }
    var batchRequests: [[String]] { locked { batches } }
    var batchThreads: [Bool] { locked { threads } }
    func values() -> [PhotoRevision] { locked { revisions } }
    func replace(_ value: [PhotoRevision]) { locked { revisions = value } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func setGeneration(_ value: UInt64?) { locked { generation = value } }
    func setRevision(_ id: String, modification: Double, creation: Double?) {
        locked {
            if let index = revisions.firstIndex(where: { $0.id == id }) {
                revisions[index] = PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
            }
        }
    }
    func onEnumeration(_ action: (@Sendable (Int) throws -> Void)?) { locked { enumerationAction = action } }
    func afterBatch(_ action: (@Sendable () throws -> Void)?) { locked { batchAction = action } }
    func overrideBatch(_ value: [PhotoRevision]?) { locked { batchOverride = value } }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let (number, action) = locked {
            fullCalls += 1
            fullThreads.append(Thread.isMainThread)
            return (fullCalls, enumerationAction)
        }
        try action?(number)
        return try locked {
            guard readable else { throw AppFailure.permission }
            return number.isMultiple(of: 2) ? Array(revisions.reversed()) : revisions
        }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        locked { singles += 1; return readable ? revisions.first { $0.id == id } : nil }
    }
    func currentRevisions(ids: [String]) throws -> [PhotoRevision] {
        let (result, action) = try locked { () throws -> ([PhotoRevision], (@Sendable () throws -> Void)?) in
            batches.append(ids)
            threads.append(Thread.isMainThread)
            guard readable else { throw AppFailure.permission }
            let wanted = Set(ids)
            let values = batchOverride ?? Array(revisions.filter { wanted.contains($0.id) }.reversed())
            return (values, batchAction)
        }
        try action?()
        return result
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { placeCount += 1 }
        XCTFail("Cleanup must not resolve geography.")
        return nil
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixelCount += 1 }
        XCTFail("Cleanup must not enumerate/read photo pixels.")
        throw ReuseFailure.test
    }
}

/// Synchronous synthetic SQLite mutations only, each handle is closed before the
/// real service next reads it. Never operates on a user's Photos or index.
private enum ReuseSQL {
    static func execute(_ directory: URL, _ sql: String) throws {
        try withDatabase(directory) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ReuseFailure.test }
        }
    }

    static func setImage(_ directory: URL, id: String, bytes: Data) throws {
        try withDatabase(directory) { db in
            var query: OpaquePointer?
            defer { if let query { sqlite3_finalize(query) } }
            guard sqlite3_prepare_v2(db, "UPDATE photos SET image_embedding = ? WHERE id = ?", -1, &query, nil) == SQLITE_OK,
                  let query else { throw ReuseFailure.test }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let blobStatus = bytes.withUnsafeBytes { sqlite3_bind_blob(query, 1, $0.baseAddress, Int32(bytes.count), transient) }
            let textStatus = id.withCString { sqlite3_bind_text(query, 2, $0, -1, transient) }
            guard blobStatus == SQLITE_OK, textStatus == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE,
                  sqlite3_changes(db) == 1 else { throw ReuseFailure.test }
        }
    }

    static func withPendingWriter<T>(_ directory: URL, operation: () throws -> T) throws -> T {
        try withDatabase(directory) { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw ReuseFailure.test }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            return try operation()
        }
    }

    private static func withDatabase<T>(_ directory: URL, operation: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                     &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        guard status == SQLITE_OK, let pointer else { throw ReuseFailure.test }
        return try operation(pointer)
    }
}