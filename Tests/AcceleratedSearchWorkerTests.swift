import CryptoKit
import Foundation
import ImageIO
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Real SQLite and derived binary files; synthetic metadata/encoders only.
/// No PhotoKit, model loading, image requests, networking or elapsed-time gates.
final class AcceleratedSearchWorkerTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic search boundaries.")

    private func row(_ id: String, axis: Int = 0, revision: Double = 123,
                     creation: Double? = 100, model: String? = nil,
                     place: PlaceEmbedding? = nil, geography: String? = nil,
                     vector: [Float]? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision, modelVersion: model ?? version,
                                        imageEmbedding: vector ?? TestFixtures.vector(axis: axis),
                                        location: place, creationTime: creation),
                    geographyVersion: geography ?? resolver.version)
    }

    private func context(rows: [CachedPhoto]? = nil, revisions: [PhotoRevision]? = nil,
                         legacy: Bool = false, seed: Bool = true,
                         observeWork: (@Sendable (SearchCachePreparationEvent) -> Void)? = nil,
                         checkpoint: (@Sendable (SearchCacheDeferredCheckpoint) async -> Void)? = nil,
                         indexAccess: IndexAccessCoordinator? = nil) throws -> AcceleratedWorkerContext {
        let directory = try TestFixtures.temporaryDirectory()
        let rows = rows ?? [row("a"), row("b", axis: 1), row("c", axis: 2)]
        if seed { try TestFixtures.seedRawCache(rows, directory: directory) }
        let current = revisions ?? rows.map {
            PhotoRevision(id: $0.photo.id, modificationTime: $0.photo.modificationTime,
                          creationTime: $0.photo.creationTime)
        }
        let library: AcceleratedWorkerLibrary = legacy
            ? AcceleratedWorkerLibrary(current) : AcceleratedSnapshotLibrary(current)
        let encoders = try AcceleratedWorkerEncoders()
        let writer = SQLitePhotoStore(directory: directory)
        let cache = SearchIndexCache(directory: directory, observeWork: observeWork, deferredCheckpoint: checkpoint)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver,
                                      indexAccess: indexAccess, searchCache: cache)
        addTeardownBlock {
            await worker.releaseSearchMemory()
            await writer.close()
            try FileManager.default.removeItem(at: directory)
        }
        return AcceleratedWorkerContext(worker: worker, library: library, encoders: encoders,
                                        writer: writer, directory: directory)
    }

    private func anotherWorker(_ c: AcceleratedWorkerContext) -> PhotoIndexWorker {
        let worker = PhotoIndexWorker(library: c.library, encoders: c.encoders, directory: c.directory, resolver: resolver)
        addTeardownBlock { await worker.releaseSearchMemory() }
        return worker
    }

    private func search(_ c: AcceleratedWorkerContext, text: String = "first", original: String = "receipt",
                        limit: Int = Int.max, weight: Float = 0.6, filters: PhotoSearchFilters = .init(),
                        ocr: Bool = false, reference: Bool = false,
                        timing: SearchTimingRecorder? = nil, drainWriteback: Bool = true) async throws -> SearchResponse {
        let service: any PhotoWorkServicing = c.worker
        let response = try await service.search(text: text, originalText: original, limit: limit, locationWeight: weight,
                                               filters: filters, textSearchEnabled: ocr, timing: timing, referenceSearch: reference)
        // Existing disk assertions explicitly wait for optional persistence;
        // production search does NOT wait. Cold-path tests opt out below.
        if drainWriteback { await c.worker.waitForSearchCacheWriteback() }
        return response
    }

    private func measured(_ c: AcceleratedWorkerContext, text: String = "first", limit: Int = Int.max,
                          weight: Float = 0.6, reference: Bool = false) async throws
        -> (response: SearchResponse, report: SearchTimingReport) {
        let timing = SearchTimingRecorder(mode: reference ? "reference" : "accelerated")
        let response = try await search(c, text: text, limit: limit, weight: weight, reference: reference,
                        timing: timing, drainWriteback: false)
        // The caller owns publication/finish; worker marks but never freezes it.
        try response.validatePageAccess(Array(response.hits.prefix(12)).map(\.id))
        let report = timing.finish(.ready)
        await c.worker.waitForSearchCacheWriteback()
        return (response, report)
    }

    private func indexReport(_ report: SearchTimingReport, source: String, count: Int,
                             matrix: Bool, snapshot: Bool? = nil,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(report.cacheSource, source, file: file, line: line)
        XCTAssertEqual(report.candidateCount, count, file: file, line: line)
        XCTAssertEqual(report.matrixReused, matrix, file: file, line: line)
        if let snapshot { XCTAssertEqual(report.snapshotReused, snapshot, file: file, line: line) }
        XCTAssertEqual(report.outcome, .ready, file: file, line: line)
        XCTAssertNil(report.firstImageSeconds, file: file, line: line)
        XCTAssertEqual(report.totalSeconds, report.stages.reduce(0) { $0 + $1.seconds }, file: file, line: line)
    }

    private func sourceHash(_ c: AcceleratedWorkerContext) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: c.database)))
    }

    private func removeSyntheticPhotosTable(_ c: AcceleratedWorkerContext) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(c.database.path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle,
              sqlite3_exec(handle, "DROP TABLE photos", nil, nil, nil) == SQLITE_OK else {
            throw AppFailure.storage("Could not construct the synthetic SQL failure fixture.")
        }
    }

    private func seedText(_ c: AcceleratedWorkerContext, id: String, text: String, revision: Double = 123) async throws {
        let store = SQLiteTextStore(directory: c.directory)
        do {
            try await store.save(PhotoTextRecord(id: id, revision: revision, policy: PhotoTextPolicy.version,
                                                 text: text, pixelWidth: 640, pixelHeight: 480, isReduced: false))
            await store.close()
        } catch { await store.close(); throw error }
    }

    private func same(_ lhs: SearchResponse, _ rhs: SearchResponse,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.hits.map(\.id), rhs.hits.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.hits.map { $0.score.bitPattern }, rhs.hits.map { $0.score.bitPattern }, file: file, line: line)
        XCTAssertEqual(lhs.textMatchedIDs, rhs.textMatchedIDs, file: file, line: line)
        XCTAssertEqual(lhs.textSearchUsed, rhs.textSearchUsed, file: file, line: line)
        XCTAssertEqual(lhs.summary.indexedCount, rhs.summary.indexedCount, file: file, line: line)
        XCTAssertEqual(lhs.summary.locatedCount, rhs.summary.locatedCount, file: file, line: line)
    }

    private func photoFailure(_ operation: () async throws -> SearchResponse,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected an access/snapshot error.", file: file, line: line) }
        catch AppFailure.photo { }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func noPixels(_ c: AcceleratedWorkerContext, factories: Int = 0,
                          file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.images, 0, file: file, line: line)
        XCTAssertEqual(calls.originals, 0, file: file, line: line)
        XCTAssertEqual(calls.factories, factories, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
    }

    func testInitLaunchAndRefreshNeverCreateDerivedCacheOrEnumeratePhotos() async throws {
        for seed in [false, true] {
            let c = try context(seed: seed)
            let before = try FileManager.default.contentsOfDirectory(atPath: c.directory.path)
            let hash = seed ? (try sourceHash(c)) : nil
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
            _ = try await c.worker.prepareForLaunch { _ in }
            _ = try await c.worker.refresh()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.directory.path), before)
            if let hash { XCTAssertEqual(try sourceHash(c), hash) }
            XCTAssertEqual(c.library.enumerations, 0)
            let snapshots = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
            XCTAssertEqual(snapshots.captures, 0)
            let calls = await c.encoders.calls()
            XCTAssertTrue(calls.texts.isEmpty)
            await noPixels(c)
            if !seed {
                let empty = try await search(c)
                XCTAssertTrue(empty.hits.isEmpty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.directory.path), before,
                               "Even explicit search must not create a missing source database.")
            }
        }
    }

    func testOldOverloadsDefaultToAccelerationAndDifferentQueriesRemainFresh() async throws {
        let c = try context()
        let hash = try sourceHash(c)
        let first = try await measured(c, limit: 1, weight: 0)
        indexReport(first.report, source: "数据库读取", count: 3, matrix: false, snapshot: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.binary.path))
        let binary = try Data(contentsOf: c.binary)
        let second = try await measured(c, text: "second", limit: 1, weight: 0)
        indexReport(second.report, source: "内存驻留", count: 3, matrix: true, snapshot: true)
        let timing = SearchTimingRecorder()
        let third = try await anotherWorker(c).search(text: "second", originalText: "unused", limit: 1,
            locationWeight: 0, filters: .init(), textSearchEnabled: false, timing: timing, referenceSearch: false)
        indexReport(timing.finish(.ready), source: "二进制缓存", count: 3, matrix: false, snapshot: true)
        XCTAssertEqual(first.response.hits.first?.id, "a")
        XCTAssertEqual(second.response.hits.first?.id, "b")
        same(second.response, third)
        let simple = try await c.worker.search(text: "second", limit: 1, locationWeight: 0)
        let filtered = try await c.worker.search(text: "second", limit: 1, locationWeight: 0, filters: .init())
        same(simple, third)
        same(filtered, third)
        XCTAssertEqual(first.report.stages.map(\.stage), [.queue, .snapshot, .models, .indexRead, .queryEncoding,
            .counts, .accessCheck, .scoring, .filtering, .finalAccess, .publication])
        XCTAssertEqual(try Data(contentsOf: c.binary), binary)
        XCTAssertEqual(try sourceHash(c), hash)
        let snapshots = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
        XCTAssertEqual(snapshots.sourceLoads, 1, "Sorted metadata is retained, not re-enumerated at each capture.")
        XCTAssertEqual(snapshots.validations, 15, "Each search validates its epoch before models, after records and before scoring.")
        XCTAssertEqual(c.library.enumerations, 5, "One fresh final full enumeration per accelerated search.")
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.texts, ["first", "second", "second", "second", "second"], "No query embedding cache in this phase.")
        await noPixels(c)
    }

    func testTimedProtocolDefaultsForwardOldMockOverloadsAndArguments() async throws {
        let mock = AcceleratedLegacyService()
        let service: any PhotoWorkServicing = mock
        _ = try await service.search(text: "effective", originalText: "original", limit: -3, locationWeight: 0.37,
                                     filters: .init(albumID: "subset"), textSearchEnabled: true,
                                     timing: nil, referenceSearch: true)
        _ = try await service.searchSimilar(photoID: "seed", limit: 7, filters: .init(imageKind: .screenshots),
                                            timing: nil, referenceSearch: false)
        let requests = await mock.requests
        XCTAssertEqual(requests, ["effective|original|-3|0.37|subset|true", "seed|7|screenshots"])
    }

    func testReferenceAlwaysUsesThreeEnumerationsAndNeverCreatesOrUpdatesDerivedCache() async throws {
        let c = try context()
        let before = try sourceHash(c)
        let measuredReference = try await measured(c, reference: true)
        let reference = measuredReference.response
        indexReport(measuredReference.report, source: "参考基线", count: 3, matrix: false, snapshot: false)
        XCTAssertEqual(c.library.enumerations, 3)
        XCTAssertEqual((c.library as? AcceleratedSnapshotLibrary)?.captures, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        let fast = try await search(c)
        same(fast, reference)
        // Deliberately damage ONLY the disposable file: reference must neither
        // read it nor repair it, even if this worker already has a warm matrix.
        let sentinel = Data("not a binary cache".utf8)
        try sentinel.write(to: c.binary)
        let again = try await search(c, reference: true)
        same(again, reference)
        XCTAssertEqual(try Data(contentsOf: c.binary), sentinel)
        XCTAssertEqual(try sourceHash(c), before)
        XCTAssertEqual(c.library.enumerations, 7)
        await noPixels(c)
    }

    func testExactFloatBitsAcrossWeightsFiltersLimitsOCRAndColdBinaryReload() async throws {
        let a = PlaceEmbedding(text: "Place A", vector: TestFixtures.vector())
        let b = PlaceEmbedding(text: "Place B", vector: TestFixtures.vector(axis: 1))
        var mixed = TestFixtures.vector()
        mixed[0] = 0.6
        mixed[1] = 0.8
        let rows = [row("a", place: a, vector: mixed), row("b", axis: 1, creation: 200, place: b),
                    row("c", axis: 2, place: a), row("d", creation: nil),
                    row("e", place: b, geography: "stale")]
        let c = try context(rows: rows)
        try await seedText(c, id: "c", text: "receipt coffee")
        try await seedText(c, id: "b", text: "receipt")
        let source = try sourceHash(c)
        let textSource = try Data(contentsOf: c.directory.appendingPathComponent("text-index.sqlite3"))
        let filters: [PhotoSearchFilters] = [
            .init(), .init(albumID: "subset"), .init(imageKind: .photos), .init(imageKind: .screenshots),
            .init(imageKind: .livePhotos), .init(startDate: Date(timeIntervalSince1970: 100),
                                               endDateExclusive: Date(timeIntervalSince1970: 200))
        ]
        for weight in [Float(0), 0.25, 0.6, 1] {
            for filter in filters {
                for ocr in [false, true] {
                    for limit in [0, 1, Int.max] {
                        let raw = try await search(c, limit: limit, weight: weight, filters: filter, ocr: ocr, reference: true)
                        let fast = try await search(c, limit: limit, weight: weight, filters: filter, ocr: ocr)
                        same(fast, raw)
                    }
                }
            }
        }
        let cold = try await anotherWorker(c).search(text: "first", originalText: "receipt", limit: Int.max,
                                                    locationWeight: 0.6, filters: .init(), textSearchEnabled: true)
        let raw = try await search(c, ocr: true, reference: true)
        same(cold, raw)
        XCTAssertEqual(try sourceHash(c), source)
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("text-index.sqlite3")), textSource)
        await noPixels(c)
    }

    func testNoMatchOCRRetainsVisualScoreBitsAndOnlyCurrentRevisionsCanMatch() async throws {
        let c = try context()
        try await seedText(c, id: "b", text: "receipt")
        try await seedText(c, id: "c", text: "receipt", revision: 122)
        let visual = try await search(c)
        let noMatch = try await search(c, original: "unmatchedword", ocr: true)
        same(noMatch, visual)
        XCTAssertFalse(noMatch.textSearchUsed)
        let timing = SearchTimingRecorder()
        let matched = try await search(c, original: "receipt", ocr: true, timing: timing)
        let report = timing.finish(.ready)
        XCTAssertEqual(report.stages.filter { $0.stage == .counts }.count, 2)
        XCTAssertEqual(report.stages.filter { $0.stage == .textMatch }.count, 2)
        XCTAssertEqual(matched.textMatchedIDs, ["b"])
        XCTAssertTrue(matched.textSearchUsed)
        XCTAssertEqual(matched.summary.textIndexCounts.records, 2)
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.texts, ["first", "first", "first"], "OCR uses original text, visual encoding uses effective text.")
    }

    func testSimilarityUsesRawCachedSeedNoTextEncodingAndMatchesReferenceExactly() async throws {
        let c = try context()
        for filter in [PhotoSearchFilters(), .init(albumID: "subset")] {
            let fast = try await c.worker.searchSimilar(photoID: "b", limit: Int.max, filters: filter)
            let raw = try await c.worker.searchSimilar(photoID: "b", limit: Int.max, filters: filter,
                                                       timing: nil, referenceSearch: true)
            same(fast, raw)
            XCTAssertFalse(fast.hits.contains { $0.id == "b" })
            try fast.validateAccess()
        }
        let calls = await c.encoders.calls()
        XCTAssertTrue(calls.texts.isEmpty)
        await noPixels(c)
    }

    func testExternalSaveInvalidatesWarmRecordsAndMatrixWithoutPhotoEpochChange() async throws {
        let c = try context()
        let before = try await measured(c, weight: 0)
        XCTAssertEqual(before.response.hits.first?.id, "a")
        let warm = try await measured(c, weight: 0)
        indexReport(warm.report, source: "内存驻留", count: 3, matrix: true)
        try await c.writer.save(row("a", axis: 2, revision: 124))
        try await c.writer.save(row("b", axis: 0))
        let reloaded = try await measured(c, weight: 0)
        indexReport(reloaded.report, source: "数据库读取", count: 3, matrix: false)
        let after = reloaded.response
        let raw = try await search(c, weight: 0, reference: true)
        same(after, raw)
        XCTAssertEqual(after.hits.first?.id, "b")
        XCTAssertEqual(after.hits.first { $0.id == "a" }?.photo.modificationTime, 124)
        let cold = try await anotherWorker(c).search(text: "first", limit: Int.max, locationWeight: 0)
        same(cold, after)
    }

    func testExternalReconcileAndClearInvalidateWarmMatrix() async throws {
        let c = try context()
        _ = try await search(c)
        try await c.writer.reconcile(completeEnumeration: [PhotoRevision(id: "b", modificationTime: 123, creationTime: 100)])
        let pruned = try await measured(c)
        indexReport(pruned.report, source: "数据库读取", count: 1, matrix: false)
        XCTAssertEqual(pruned.response.hits.map(\.id), ["b"])
        XCTAssertEqual(pruned.response.summary.indexedCount, 1)
        try await c.writer.clear()
        let empty = try await measured(c)
        indexReport(empty.report, source: "数据库读取", count: 0, matrix: false)
        XCTAssertTrue(empty.response.hits.isEmpty)
        XCTAssertEqual(empty.response.summary.indexedCount, 0)
        try await c.writer.save(row("c"))
        let saved = try await search(c)
        XCTAssertEqual(saved.hits.map(\.id), ["c"])
    }

    func testManualIndexInvalidatesSearchMemoryWithoutDeletingDerivedFileAtEntry() async throws {
        let c = try context(rows: [row("a")])
        _ = try await search(c)
        let binary = try Data(contentsOf: c.binary)
        // Verify the early invalidation boundary even when indexing itself fails.
        c.library.setEnumerationFailure(AppFailure.photo("Synthetic incomplete enumeration"))
        do { _ = try await c.worker.index(networkAllowed: false) { _ in }; XCTFail("Expected failed enumeration.") }
        catch AppFailure.photo { }
        XCTAssertEqual(try Data(contentsOf: c.binary), binary)
        c.library.setEnumerationFailure(nil)
        let afterFailure = try await measured(c)
        indexReport(afterFailure.report, source: "二进制缓存", count: 1, matrix: false)
        let warm = try await measured(c)
        indexReport(warm.report, source: "内存驻留", count: 1, matrix: true)
        let summary = try await c.worker.index(networkAllowed: false) { _ in }
        XCTAssertEqual(summary.indexedCount, 1)
        let after = try await measured(c)
        XCTAssertFalse(after.report.matrixReused)
        XCTAssertNotEqual(after.report.cacheSource, "内存驻留")
        XCTAssertEqual(after.response.hits.map(\.id), ["a"])
        await noPixels(c, factories: 1)
    }

    func testClearRemovesPriorWorkersDerivedFileAndOptionalCacheFailureDoesNotBlockSourceClear() async throws {
        for failCacheClear in [false, true] {
            let c = try context()
            _ = try await search(c)
            try await seedText(c, id: "a", text: "receipt")
            await c.writer.close()
            if failCacheClear {
                try FileManager.default.removeItem(at: c.binary)
                try FileManager.default.createDirectory(at: c.binary, withIntermediateDirectories: false)
            }
            // Cover both warm-memory clear and a new worker clearing an old file.
            let clearingWorker = failCacheClear ? c.worker : anotherWorker(c)
            let summary = try await clearingWorker.clear()
            XCTAssertEqual(summary.indexedCount, 0)
            XCTAssertEqual(summary.textIndexCounts.records, 0)
            if !failCacheClear { XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path)) }
            let empty = try await measured(c)
            XCTAssertFalse(empty.report.matrixReused)
            XCTAssertTrue(empty.response.hits.isEmpty, "An older worker's matrix must also observe the replaced source DB.")
        }
    }

    func testAccessScopeChangesInvalidateCachedRowsAndStoredCountsRemainUnfiltered() async throws {
        let rows = [row("a"), row("b", place: PlaceEmbedding(text: "B", vector: TestFixtures.vector(axis: 1))),
                    row("c", model: "old-model")]
        let c = try context(rows: rows)
        _ = try await search(c)
        let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
        library.replace([PhotoRevision(id: "a", modificationTime: 124, creationTime: 100)])
        library.notifyChange()
        let narrowedTiming = try await measured(c, text: "PRIVATE_QUERY_SENTINEL")
        let narrowed = narrowedTiming.response
        indexReport(narrowedTiming.report, source: "数据库读取", count: 1, matrix: false, snapshot: false)
        let diagnostic = String(reflecting: narrowedTiming.report)
        XCTAssertFalse(diagnostic.contains("PRIVATE_QUERY_SENTINEL"))
        XCTAssertFalse(diagnostic.contains(c.directory.path))
        XCTAssertFalse(diagnostic.contains(version))
        XCTAssertEqual(narrowed.hits.map(\.id), ["a"])
        XCTAssertEqual(narrowed.hits.first?.photo.modificationTime, 123, "Accessible edits still use manually saved vectors.")
        XCTAssertEqual(narrowed.summary.authorizedCount, 1)
        XCTAssertEqual(narrowed.summary.indexedCount, 2, "Display counts retain all stored active-model rows.")
        XCTAssertEqual(narrowed.summary.locatedCount, 1)
        let raw = try await search(c, reference: true)
        same(narrowed, raw)
        library.replace(rows.map { PhotoRevision(id: $0.photo.id, modificationTime: 123, creationTime: 100) })
        library.notifyChange()
        let widened = try await measured(c)
        indexReport(widened.report, source: "数据库读取", count: 2, matrix: false, snapshot: false)
        XCTAssertEqual(Set(widened.response.hits.map(\.id)), ["a", "b"])
    }

    func testLegacyNilGenerationRetainsThreeFullReadsAndNoDerivedFile() async throws {
        let c = try context(legacy: true)
        let before = try sourceHash(c)
        _ = try await search(c)
        XCTAssertNil(c.library.changeGeneration)
        XCTAssertEqual(c.library.enumerations, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        for boundary in [2, 3] {
            let changed = try context(legacy: true)
            let library = changed.library
            library.onEnumeration(boundary) {
                library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
            }
            await photoFailure { try await self.search(changed, limit: 1) }
            XCTAssertEqual(library.enumerations, boundary)
        }
        XCTAssertEqual(try sourceHash(c), before)
    }

    func testCaptureMayAdvanceAuthorizationEpochBeforeWorkerBindsSnapshot() async throws {
        let c = try context()
        let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
        _ = try await search(c)
        let oldGeneration = library.changeGeneration
        library.setAuthorization(4) // Same IDs, authorized -> limited; no callback yet.
        let result = try await search(c)
        XCTAssertNotEqual(library.changeGeneration, oldGeneration)
        try result.validateAccess()
        XCTAssertEqual(result.hits.count, 3)
        XCTAssertEqual(library.sourceLoads, 2)
    }

    func testFinalFreshEnumerationRejectsUndeliveredDeletionOutsideReturnedPageAndInvalidatesSnapshot() async throws {
        let a = PlaceEmbedding(text: "A", vector: TestFixtures.vector())
        let b = PlaceEmbedding(text: "B", vector: TestFixtures.vector(axis: 1))
        let c = try context(rows: [row("a", place: a), row("b", axis: 1, place: b)])
        let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
        let first = try await search(c, limit: 1, weight: 1)
        XCTAssertEqual(first.hits.first?.id, "a")
        XCTAssertEqual(first.hits.first?.score, 0.5)
        let oldGeneration = library.changeGeneration
        library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
        XCTAssertEqual(library.changeGeneration, oldGeneration, "Intentionally no delivered change event.")
        await photoFailure { try await self.search(c, limit: 1, weight: 1) }
        XCTAssertEqual(library.invalidations, 1)
        XCTAssertNotEqual(library.changeGeneration, oldGeneration)
        let fresh = try await search(c, limit: 1, weight: 1)
        XCTAssertEqual(fresh.hits.first?.score, 0, "Deleted B must no longer center the remaining A.")
        XCTAssertEqual(library.sourceLoads, 2)
        XCTAssertEqual(c.library.enumerations, 3)
    }

    func testDeliveredNilDetailEventAndPermissionChangeDuringEncodingRejectLateSuccess() async throws {
        for denied in [false, true] {
            let c = try context()
            let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
            await c.encoders.onQuery {
                if denied { library.setReadable(false) }
                else { library.notifyChange() } // nil PHChange details still invalidate generation.
            }
            do { _ = try await search(c); XCTFail("Late query success must not bypass epoch checks.") }
            catch AppFailure.permission { XCTAssertTrue(denied) }
            catch AppFailure.photo { XCTAssertFalse(denied) }
            catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(c.library.enumerations, 0, "Reject at the cheap pre-scoring boundary.")
            await noPixels(c)
        }
    }

    func testPageValidationUsesOneBatchRejectsUnknownIDsAndAlwaysIncludesSeed() async throws {
        let c = try context()
        let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
        let result = try await c.worker.searchSimilar(photoID: "b", limit: Int.max, filters: .init(albumID: "subset"))
        let individual = library.individualReads
        try result.validatePageAccess(["a"])
        XCTAssertEqual(library.batches, [["a", "b"]])
        XCTAssertEqual(library.individualReads, individual, "No individual fetches during page validation.")
        XCTAssertThrowsError(try result.validatePageAccess(["unknown"]))
        XCTAssertThrowsError(try result.validatePageAccess(["b"]), "Seed is a dependency, not a returned hit.")
        XCTAssertEqual(library.batches.count, 1, "Reject invalid page IDs before any batch read.")
        try result.validatePageAccess([])
        XCTAssertEqual(library.batches.last, ["b"])
        library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                         PhotoRevision(id: "c", modificationTime: 123, creationTime: 100)])
        XCTAssertThrowsError(try result.validatePageAccess([]), "An unreturned seed remains required even on empty pages.")
        await noPixels(c)
    }

    func testPublicationAndPageCheckEpochBeforeAndAfterFreshBatch() async throws {
        for duringBatch in [false, true] {
            let c = try context()
            let library = try XCTUnwrap(c.library as? AcceleratedSnapshotLibrary)
            let result = try await search(c)
            if duringBatch { library.onBatch { library.notifyChange() } }
            else { library.notifyChange() }
            XCTAssertThrowsError(try result.validateAccess())
            XCTAssertEqual(library.batches.count, duringBatch ? 1 : 0)
        }
        let c = try context()
        let result = try await search(c)
        c.library.replace([PhotoRevision(id: "a", modificationTime: 124, creationTime: 100)])
        XCTAssertThrowsError(try result.validatePageAccess(["a"]), "Undelivered per-photo edits are checked fresh.")
    }

    func testCorruptDerivedCacheFallsBackButAccessibleSourceCorruptionAndShapeErrorsRemainFailures() async throws {
        let c = try context()
        _ = try await search(c)
        try Data("corrupt disposable binary".utf8).write(to: c.binary)
        let recoveringWorker = anotherWorker(c)
        let recovered = try await recoveringWorker.search(text: "first", limit: Int.max, locationWeight: 0.6)
        await recoveringWorker.waitForSearchCacheWriteback()
        let raw = try await search(c, reference: true)
        same(recovered, raw)
        XCTAssertNotEqual(try Data(contentsOf: c.binary), Data("corrupt disposable binary".utf8))

        let corrupt = try context(rows: [row("a"), row("hidden", vector: []), row("old", model: "old", vector: [])],
                                  revisions: [PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
        _ = try await search(corrupt) // Inaccessible/old rows never reach vector validation.
        corrupt.library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                                  PhotoRevision(id: "hidden", modificationTime: 123, creationTime: 100)])
        (corrupt.library as? AcceleratedSnapshotLibrary)?.notifyChange()
        for reference in [false, true] {
            do { _ = try await search(corrupt, reference: reference); XCTFail("Accessible source corruption must fail.") }
            catch AppFailure.modelContract { }
            catch { XCTFail("Cache must preserve the source error type: \(error)") }
        }
        let brokenSQL = try context()
        try removeSyntheticPhotosTable(brokenSQL)
        for reference in [false, true] {
            do { _ = try await search(brokenSQL, reference: reference); XCTFail("A SQL error must not become empty results.") }
            catch AppFailure.storage { }
            catch { XCTFail("The source loader's SQL error must remain a storage error: \(error)") }
        }
        let shape = try context(rows: [row("a", vector: TestFixtures.vector(dimension: 512))])
        for reference in [false, true] {
            do { _ = try await search(shape, limit: 0, weight: -1, reference: reference); XCTFail("Invalid weight.") }
            catch { XCTAssertEqual(error as? VectorSearchError, .invalidLocationWeight) }
            do { _ = try await search(shape, limit: 0, weight: 0, reference: reference); XCTFail("Mismatched active shape.") }
            catch { XCTAssertEqual(error as? EmbeddingError, .dimensionMismatch(expected: 768, actual: 512)) }
            do {
                _ = try await shape.worker.searchSimilar(photoID: "a", limit: 1, filters: .init(), timing: nil, referenceSearch: reference)
                XCTFail("A legacy-sized active seed must still satisfy the manifest.")
            } catch AppFailure.modelContract { }
            catch { XCTFail("Unexpected seed shape error: \(error)") }
        }
    }

    func testCancellationAbortsEncodingAndPrecancelledClearPreservesSourceAndDerivedFile() async throws {
        let c = try context()
        _ = try await search(c)
        let before = try sourceHash(c)
        let binary = try Data(contentsOf: c.binary)
        await c.encoders.onQuery { withUnsafeCurrentTask { $0?.cancel() } }
        let searchTask = Task { try await self.search(c, text: "second") }
        do { _ = try await searchTask.value; XCTFail("Cancelled query must not publish.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let clearTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await c.worker.clear()
        }
        do { _ = try await clearTask.value; XCTFail("Cancelled clear must not mutate storage.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try sourceHash(c), before)
        XCTAssertEqual(try Data(contentsOf: c.binary), binary)
        await noPixels(c)
    }

    func testColdResultIsReadyWhileCacheEncodingIsHeldAndMatchesReferenceBitForBit() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeEncoding { await gate.pause() }
        })
        let source = try sourceHash(c)
        let raw = try await search(c, reference: true)
        // This await must complete even though the optional encoder cannot run.
        let fast = try await search(c, drainWriteback: false)
        await gate.waitUntilEntered()
        same(fast, raw)
        try fast.validateAccess()
        XCTAssertEqual(probe.snapshot().encodingStarts, 0)
        XCTAssertEqual(probe.snapshot().publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        await gate.release()
        await c.worker.waitForSearchCacheWriteback()
        XCTAssertEqual(probe.snapshot().encodingStarts, 1)
        XCTAssertEqual(probe.snapshot().publications, 1)
        let diskWorker = anotherWorker(c)
        let disk = try await diskWorker.search(text: "first", limit: Int.max, locationWeight: 0.6)
        same(disk, raw)
        XCTAssertEqual(try sourceHash(c), source)
        await noPixels(c)
    }

    func testBackgroundReleaseCancelsAndDrainsEncodedCacheTailWithoutLateWrite() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        _ = try await search(c, drainWriteback: false)
        await gate.waitUntilEntered()
        XCTAssertEqual(probe.snapshot().encodingStarts, 1)
        let releasing = Task { await c.worker.releaseSearchMemory() }
        await gate.waitUntilCancelled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        await gate.release()
        await releasing.value
        XCTAssertEqual(probe.snapshot().publications, 0)
        let timing = SearchTimingRecorder()
        _ = try await search(c, timing: timing)
        indexReport(timing.finish(.ready), source: "数据库读取", count: 3, matrix: false)
        XCTAssertEqual(probe.snapshot().publications, 1)
    }

    func testNewQueryDoesNotWaitForCancelledOldCacheEncodingAndOnlyNewTailPublishes() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        _ = try await search(c, weight: 0, drainWriteback: false)
        await gate.waitUntilEntered()
        let timing = SearchTimingRecorder()
        let next = try await search(c, text: "second", weight: 0, timing: timing, drainWriteback: false)
        indexReport(timing.finish(.ready), source: "内存驻留", count: 3, matrix: true)
        XCTAssertEqual(next.hits.first?.id, "b")
        await gate.waitUntilCancelled()
        XCTAssertEqual(probe.snapshot().encodingStarts, 1, "Tail encoders must not overlap.")
        await gate.release()
        await c.worker.waitForSearchCacheWriteback()
        XCTAssertEqual(probe.snapshot().encodingStarts, 2)
        XCTAssertEqual(probe.snapshot().publications, 1)
        let raw = try await search(c, text: "second", weight: 0, reference: true)
        same(next, raw)
    }

    func testCancelledOrRejectedColdQueryNeverStartsOptionalCacheSerialization() async throws {
        for rejection in ["cancel", "permission", "undelivered-edit"] {
            let probe = SearchColdWorkProbe()
            let c = try context(observeWork: { probe.record($0) })
            let library = c.library
            await c.encoders.onQuery {
                switch rejection {
                case "cancel": throw CancellationError()
                case "permission": library.setReadable(false)
                default:
                    // Same generation, change an unreturned row's revision.
                    library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                                     PhotoRevision(id: "b", modificationTime: 123, creationTime: 100),
                                     PhotoRevision(id: "c", modificationTime: 124, creationTime: 100)])
                }
            }
            do { _ = try await search(c, limit: 1, drainWriteback: false); XCTFail("Rejected search must not return.") }
            catch is CancellationError { XCTAssertEqual(rejection, "cancel") }
            catch AppFailure.permission { XCTAssertEqual(rejection, "permission") }
            catch AppFailure.photo { XCTAssertEqual(rejection, "undelivered-edit") }
            await c.worker.waitForSearchCacheWriteback()
            XCTAssertEqual(probe.snapshot().sourceHashPasses, 1)
            XCTAssertEqual(probe.snapshot().encodingStarts, 0)
            XCTAssertEqual(probe.snapshot().publications, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
        }
    }

    func testWorkerPassesCoordinatorToTailAndDoesNotHoldReadLeaseDuringEncoding() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let coordinator = IndexAccessCoordinator()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        }, indexAccess: coordinator)
        _ = try await search(c, drainWriteback: false)
        await gate.waitUntilEntered()
        let writer = try await coordinator.acquireWrite()
        await gate.release()
        await c.worker.waitForSearchCacheWriteback()
        XCTAssertEqual(probe.snapshot().publications, 0)
        writer.release()
        _ = try await search(c)
        XCTAssertEqual(probe.snapshot().publications, 1)
        XCTAssertTrue(coordinator.canReadImmediately)
    }

    func testAccessRevocationWhileTailIsEncodedPreventsDiskPublication() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        let response = try await search(c, drainWriteback: false)
        await gate.waitUntilEntered()
        c.library.setReadable(false)
        XCTAssertThrowsError(try response.validateAccess())
        await gate.release()
        await c.worker.waitForSearchCacheWriteback()
        XCTAssertEqual(probe.snapshot().publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
    }

    func testClearCancelsAndDrainsTailBeforeMutatingSource() async throws {
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let c = try context(observeWork: { probe.record($0) }, checkpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        let before = try sourceHash(c)
        _ = try await search(c, drainWriteback: false)
        await gate.waitUntilEntered()
        let clearing = Task { try await c.worker.clear() }
        await gate.waitUntilCancelled()
        XCTAssertEqual(try sourceHash(c), before, "Source clear cannot overtake the cancelled tail's drain.")
        await gate.release()
        let summary = try await clearing.value
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(probe.snapshot().publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
    }

    func testTailDoesNotRetainWorkerAndDeinitCancelsPendingWrite() async throws {
        let c = try context()
        let gate = SearchColdGate()
        let probe = SearchColdWorkProbe()
        let cache = SearchIndexCache(directory: c.directory, observeWork: { probe.record($0) },
                                     deferredCheckpoint: { stage in
            if stage == .beforeCommit { await gate.pause() }
        })
        var worker: PhotoIndexWorker? = PhotoIndexWorker(library: c.library, encoders: c.encoders,
            directory: c.directory, resolver: resolver, searchCache: cache)
        weak var weakWorker = worker
        _ = try await worker?.search(text: "first", limit: Int.max, locationWeight: 0)
        await gate.waitUntilEntered()
        worker = nil
        XCTAssertNil(weakWorker, "Background tail must not keep the worker/matrix alive.")
        await gate.waitUntilCancelled()
        // Revoke the cache before releasing the deliberately noncooperative test
        // gate. Even after the worker is gone, no late disk commit is possible.
        await cache.invalidate()
        await gate.release()
        XCTAssertEqual(probe.snapshot().publications, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.binary.path))
    }
}

private struct AcceleratedWorkerContext: Sendable {
    let worker: PhotoIndexWorker
    let library: AcceleratedWorkerLibrary
    let encoders: AcceleratedWorkerEncoders
    let writer: SQLitePhotoStore
    let directory: URL
    var database: URL { directory.appendingPathComponent("index.sqlite3") }
    var binary: URL { directory.appendingPathComponent("search-vectors-v1.bin") }
}

private class AcceleratedWorkerLibrary: PhotoLibraryIndexing, PhotoSearchFiltering, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [PhotoRevision]
    private var readable = true
    private var authorization = 3
    private var enumerationCount = 0
    private var pixelCount = 0
    private var individualCount = 0
    private var batchHistory: [[String]] = []
    private var enumerationFailure: Error?
    private var enumerationHooks: [Int: @Sendable () -> Void] = [:]
    private var batchHook: (@Sendable () -> Void)?

    init(_ revisions: [PhotoRevision]) { self.revisions = revisions.sorted { $0.id < $1.id } }
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { nil }
    var enumerations: Int { locked { enumerationCount } }
    var pixelCalls: Int { locked { pixelCount } }
    var individualReads: Int { locked { individualCount } }
    var batches: [[String]] { locked { batchHistory } }
    func replace(_ rows: [PhotoRevision]) { locked { revisions = rows.sorted { $0.id < $1.id } } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int) { locked { authorization = value } }
    func setEnumerationFailure(_ error: Error?) { locked { enumerationFailure = error } }
    func onEnumeration(_ number: Int, _ hook: @escaping @Sendable () -> Void) { locked { enumerationHooks[number] = hook } }
    func onBatch(_ hook: @escaping @Sendable () -> Void) { locked { batchHook = hook } }

    func freshRows() throws -> [PhotoRevision] {
        try locked {
            guard readable else { throw AppFailure.permission }
            return revisions
        }
    }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let hook = try locked { () throws -> (@Sendable () -> Void)? in
            enumerationCount += 1
            if let enumerationFailure { throw enumerationFailure }
            return enumerationHooks.removeValue(forKey: enumerationCount)
        }
        hook?()
        return try freshRows()
    }

    func currentRevision(id: String) -> PhotoRevision? {
        locked {
            individualCount += 1
            return readable ? revisions.first { $0.id == id } : nil
        }
    }

    func freshBatch(_ ids: [String]) throws -> [PhotoRevision] {
        let hook = locked { () -> (@Sendable () -> Void)? in
            batchHistory.append(ids)
            let hook = batchHook
            batchHook = nil
            return hook
        }
        hook?()
        let requested = Set(ids)
        return try freshRows().filter { requested.contains($0.id) }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { nil }
    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult { .noGPS }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixelCount += 1 }
        XCTFail("Search and cache-only manual indexing must never request pixels.")
        throw AppFailure.photo("Unexpected image request")
    }

    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String> {
        try filters.validate()
        let album: Set<String>?
        switch filters.albumID {
        case nil: album = nil
        case "subset": album = ["a", "c"]
        case "empty": album = []
        default: throw AppFailure.photo("Synthetic missing album")
        }
        return Set(snapshot.filter { revision in
            let created = revision.creationTime.map { Date(timeIntervalSince1970: $0) }
            return (album?.contains(revision.id) ?? true) && filters.matches(creationDate: created,
                isScreenshot: revision.id == "b", isLivePhoto: revision.id == "c")
        }.map(\.id))
    }
}

/// Exercises the real versioned metadata-cache implementation. replace() without
/// notifyChange() deliberately simulates an OS change whose callback is pending.
private final class AcceleratedSnapshotLibrary: AcceleratedWorkerLibrary, PhotoSearchSnapshotting, @unchecked Sendable {
    private let cache = PhotoSearchSnapshotCache<[PhotoRevision]>()
    private var captureCount = 0
    private var loadCount = 0
    private var invalidationCount = 0
    private var validationCount = 0

    override init(_ revisions: [PhotoRevision]) {
        super.init(revisions)
        cache.synchronizeObservation(isRegistered: true, access: .init(authorization: 3, canRead: true))
    }
    override var changeGeneration: UInt64? { cache.changeGeneration }
    var captures: Int { locked { captureCount } }
    var sourceLoads: Int { locked { loadCount } }
    var invalidations: Int { locked { invalidationCount } }
    var validations: Int { locked { validationCount } }
    func notifyChange() { cache.libraryDidChange { _ in nil } }
    func invalidateSearchSnapshot() {
        locked { invalidationCount += 1 }
        cache.invalidate()
    }

    func searchSnapshot() throws -> PhotoSearchSnapshot {
        locked { captureCount += 1 }
        let snapshot = try cache.capture(readAccess: { [self] in
            .init(authorization: authorizationStatusRawValue ?? -1, canRead: canReadImages)
        }, loadSource: { [self] in
            locked { loadCount += 1 }
            return try freshRows()
        }, loadRevisions: { $0 }, loadPhotos: { [self] in try freshBatch($0) })
        return PhotoSearchSnapshot(revisions: snapshot.revisions, reused: snapshot.reused, validate: { [self] in
            locked { validationCount += 1 }
            try snapshot.validate()
        }, validatePhotos: snapshot.validatePhotos)
    }
}

private actor AcceleratedWorkerEncoders: PhotoEncoding {
    struct Calls: Sendable {
        var texts: [String] = []
        var images = 0
        var originals = 0
        var factories = 0
    }
    private let manifest: ModelManifest
    private var history = Calls()
    private var queryAction: (@Sendable () async throws -> Void)?

    init() throws { manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8)) }
    func calls() -> Calls { history }
    func onQuery(_ action: @escaping @Sendable () async throws -> Void) { queryAction = action }
    func inspectResources() -> ModelManifest { manifest }
    func prepare() -> ModelManifest { manifest }
    func text(_ text: String) async throws -> [Float] {
        history.texts.append(text)
        try await queryAction?()
        return TestFixtures.vector(axis: text == "second" ? 1 : 0)
    }
    func makeIndexingImageEncoders() -> [any PhotoImageEncoding] {
        history.factories += 1
        return [any PhotoImageEncoding](repeating: self, count: PhotoIndexWorker.indexingWorkerCount)
    }
    func image(preview: IndexingImage) throws -> [Float] {
        history.images += 1
        XCTFail("Unexpected image encoding")
        throw AppFailure.modelContract("Unexpected image encoding")
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        history.originals += 1
        XCTFail("Unexpected original image encoding")
        throw AppFailure.modelContract("Unexpected original image encoding")
    }
}

/// Deliberately implements only the old search requirements.
private actor AcceleratedLegacyService: PhotoWorkServicing {
    private(set) var requests: [String] = []
    func refresh() -> LibrarySummary { LibrarySummary() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) -> LibrarySummary { LibrarySummary() }
    func clear() -> LibrarySummary { LibrarySummary() }
    func search(text: String, limit: Int, locationWeight: Float) -> SearchResponse { SearchResponse(summary: LibrarySummary(), hits: []) }
    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool) -> SearchResponse {
        requests.append("\(text)|\(originalText)|\(limit)|\(locationWeight)|\(filters.albumID ?? "")|\(textSearchEnabled)")
        return SearchResponse(summary: LibrarySummary(), hits: [])
    }
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) -> SearchResponse {
        requests.append("\(photoID)|\(limit)|\(filters.imageKind.rawValue)")
        return SearchResponse(summary: LibrarySummary(), hits: [])
    }
}