import Foundation
import ImageIO
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real SQLite stores; synthetic authorized revisions and injected recognition.
/// These tests do not call Vision, PhotoKit, CoreML, or the network.
final class TextIndexWorkerTests: XCTestCase {
    private let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic boundaries.")

    private func row(_ id: String, revision: Double = 123, axis: Int = 0,
                     model: String? = nil, place: PlaceEmbedding? = nil,
                     vector: [Float]? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision,
                                        modelVersion: model ?? cacheVersion,
                                        imageEmbedding: vector ?? TestFixtures.vector(axis: axis),
                                        location: place, creationTime: 100), geographyVersion: resolver.version)
    }

    private func context(_ ids: [String] = ["a"], rows: [CachedPhoto]? = nil,
                         recognizer: TextWorkerRecognizer = TextWorkerRecognizer(),
                         seedImages: Bool = true, missingDirectory: Bool = false,
                         forbidGeographyLoads: Bool = false,
                         query: [Float] = TestFixtures.vector()) throws -> TextWorkerContext {
        let root = try TestFixtures.temporaryDirectory()
        let directory = missingDirectory ? root.appendingPathComponent("not-created") : root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        if seedImages { try TestFixtures.seedRawCache(rows ?? ids.map { row($0) }, directory: directory) }
        let library = TextWorkerLibrary(ids.map { PhotoRevision(id: $0, modificationTime: 123, creationTime: 100) })
        let encoders = try TextWorkerEncoders(query: query)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: forbidGeographyLoads ? nil : resolver,
                                      metadataLoader: {
                                          XCTFail("Manual OCR must not load geography metadata.")
                                          return PlacePackMetadata(version: "unexpected", coverageDescription: "unexpected")
                                      }, boundaryLoader: {
                                          XCTFail("Manual OCR must not load boundaries.")
                                          return OfflinePlaceResolver.unavailable("unexpected")
                                      }, textRecognizer: recognizer)
        return TextWorkerContext(worker: worker, library: library, encoders: encoders,
                                 recognizer: recognizer, directory: directory)
    }

    private func textRow(_ id: String, text: String = "receipt", revision: Double = 123,
                         reduced: Bool = false, policy: String = PhotoTextPolicy.version) -> PhotoTextRecord {
        PhotoTextRecord(id: id, revision: revision, policy: policy, text: text,
                        pixelWidth: 640, pixelHeight: 480, isReduced: reduced)
    }

    private func seedText(_ rows: [PhotoTextRecord], in c: TextWorkerContext) async throws {
        let store = SQLiteTextStore(directory: c.directory)
        do {
            for row in rows { try await store.save(row) }
            await store.close()
        } catch { await store.close(); throw error }
    }

    private func saved(_ id: String, in c: TextWorkerContext) async throws -> PhotoTextRecord? {
        let reader = SQLiteTextStore(directory: c.directory, readOnly: true)
        do {
            let row = try await reader.record(id: id)
            await reader.close()
            return row
        } catch { await reader.close(); throw error }
    }

    private func disk(_ directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func search(_ c: TextWorkerContext, original: String = "receipt", limit: Int = Int.max,
                        weight: Float = 0, filters: PhotoSearchFilters = .init(), enabled: Bool = true) async throws -> SearchResponse {
        try await c.worker.search(text: "effective query", originalText: original, limit: limit,
                                  locationWeight: weight, filters: filters, textSearchEnabled: enabled)
    }

    private func assertSame(_ actual: [SearchHit], _ expected: [SearchHit],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern }, file: file, line: line)
    }

    private func assertNoRecognition(_ c: TextWorkerContext,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let requests = await c.recognizer.requests
        let calls = await c.encoders.calls()
        XCTAssertTrue(requests.isEmpty, file: file, line: line)
        XCTAssertEqual(calls.images, 0, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
    }

    func testRevisionSELECTIgnoresVectorsModelsAccessAndDoesNotCreateMissingDatabase() async throws {
        let c = try context(["a", "old"], rows: [row("a", vector: []), row("hidden"), row("old", model: "old")])
        let before = try disk(c.directory)
        let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
        let revisions = try await reader.searchRevisions(modelVersion: cacheVersion, accessibleIDs: ["a", "old", "new"])
        XCTAssertEqual(revisions, ["a": 123])
        XCTAssertEqual(try disk(c.directory), before)
        let writable = SQLitePhotoStore(directory: c.directory)
        do {
            _ = try await writable.searchRevisions(modelVersion: cacheVersion, accessibleIDs: ["a"])
            XCTFail("Metadata search must require a read-only handle.")
        } catch AppFailure.storage { }
        let missing = c.directory.appendingPathComponent("absent")
        let empty = try await SQLitePhotoStore(directory: missing, readOnly: true)
            .searchRevisions(modelVersion: cacheVersion, accessibleIDs: ["a"])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testManualOCRScopesCurrentImageRevisionsWithoutEncodersGeographyOrImageWrites() async throws {
        let c = try context(["a", "stale", "unindexed"], rows: [row("a", vector: []), row("stale", revision: 122),
                            row("hidden"), row("old", model: "old")], forbidGeographyLoads: true)
        try await seedText([textRow("stale", revision: 122), textRow("hidden"), textRow("unindexed")], in: c)
        let imageBefore = try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3"))
        let trace = TextWorkerProgress()
        let summary = try await c.worker.indexText(networkAllowed: false) { await trace.append($0) }
        let state = try await trace.last()
        XCTAssertEqual(state.total, 2)
        XCTAssertEqual(state.completed, 2)
        XCTAssertEqual(state.recognized, 1)
        XCTAssertEqual(state.staleSkipped, 1)
        XCTAssertEqual(state.failed, 0)
        XCTAssertEqual(summary.authorizedCount, 3)
        XCTAssertTrue(summary.authorizedCountKnown)
        XCTAssertEqual(summary.indexedCount, 3, "Display counts are actual stored active-model rows, not authorized counts.")
        XCTAssertEqual(summary.textIndexCounts.records, 1)
        XCTAssertTrue(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        let requests = await c.recognizer.requests
        XCTAssertEqual(requests.map(\.id), ["a"])
        XCTAssertTrue(requests.allSatisfy { !$0.networkAllowed })
        for id in ["stale", "hidden", "unindexed"] {
            let value = try await saved(id, in: c)
            XCTAssertNil(value)
        }
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.inspections, 1)
        XCTAssertEqual(calls.preparations, 0)
        XCTAssertEqual(calls.images, 0)
        XCTAssertEqual(calls.slots, 0)
        XCTAssertTrue(calls.texts.isEmpty)
        XCTAssertEqual(c.library.pixelCalls, 0)
        XCTAssertEqual(c.library.placeCalls, 0)
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("index.sqlite3")), imageBefore)
    }

    func testFullQualityAndEmptyRecordsReuseButObsoletePoliciesRetry() async throws {
        let recognizer = TextWorkerRecognizer { id, _, _ in workerTextResult(id == "empty" ? "" : "receipt") }
        let c = try context(["a", "empty"], recognizer: recognizer)
        let first = try await c.worker.indexText(networkAllowed: false) { _ in }
        XCTAssertEqual(first.textIndexCounts.records, 2)
        XCTAssertEqual(first.textIndexCounts.withText, 1)
        let trace = TextWorkerProgress()
        let second = try await c.worker.indexText(networkAllowed: true) { await trace.append($0) }
        let last = try await trace.last()
        XCTAssertEqual(last.reused, 2)
        XCTAssertEqual(last.recognized, 0)
        XCTAssertEqual(last.completed, 2)
        XCTAssertEqual(last.withText, 1)
        XCTAssertEqual(second.textIndexCounts, first.textIndexCounts)
        let requests = await recognizer.requests
        XCTAssertEqual(requests.count, 2, "Changing network preference alone must not retry completed full-quality rows.")
        let empty = try await saved("empty", in: c)
        XCTAssertEqual(empty?.text, "")
        XCTAssertEqual(empty?.isReduced, false)
        try await seedText([textRow("a", text: "obsolete", policy: "old-policy")], in: c)
        let retry = TextWorkerProgress()
        _ = try await c.worker.indexText(networkAllowed: false) { await retry.append($0) }
        let retried = try await retry.last()
        let replacement = try await saved("a", in: c)
        XCTAssertEqual(retried.recognized, 1)
        XCTAssertEqual(retried.reused, 1)
        XCTAssertEqual(replacement?.policy, PhotoTextPolicy.version)
        XCTAssertEqual(replacement?.text, "receipt")
    }

    func testReducedRecordsRetryOnlyOnNextManualRunThenBecomeReusable() async throws {
        let recognizer = TextWorkerRecognizer { _, _, call in workerTextResult("receipt", reduced: call == 1) }
        let c = try context(recognizer: recognizer)
        let first = try await c.worker.indexText(networkAllowed: false) { _ in }
        XCTAssertEqual(first.textIndexCounts.reduced, 1)
        let trace = TextWorkerProgress()
        let upgraded = try await c.worker.indexText(networkAllowed: true) { await trace.append($0) }
        let upgradeProgress = try await trace.last()
        XCTAssertEqual(upgradeProgress.recognized, 1)
        XCTAssertEqual(upgradeProgress.reused, 0)
        XCTAssertEqual(upgraded.textIndexCounts.reduced, 0)
        let finalTrace = TextWorkerProgress()
        _ = try await c.worker.indexText(networkAllowed: false) { await finalTrace.append($0) }
        let last = try await finalTrace.last()
        let requests = await recognizer.requests
        XCTAssertEqual(last.reused, 1)
        XCTAssertEqual(requests.map(\.networkAllowed), [false, true])
    }

    func testCancellationRejectsLateRecognitionAndResumesOnlyCommittedPrefix() async throws {
        let gate = TextWorkerGate()
        let recognizer = TextWorkerRecognizer { id, _, call in
            if id == "b" && call == 2 { await gate.block() }
            return workerTextResult()
        }
        let c = try context(["a", "b", "c"], recognizer: recognizer)
        let trace = TextWorkerProgress()
        let task = Task { try await c.worker.indexText(networkAllowed: false) { await trace.append($0) } }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Late native success must not finish a cancelled run.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let a = try await saved("a", in: c)
        let b = try await saved("b", in: c)
        let last = try await trace.last()
        XCTAssertNotNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(last.completed, 1)
        let resumed = TextWorkerProgress()
        let summary = try await c.worker.indexText(networkAllowed: false) { await resumed.append($0) }
        let final = try await resumed.last()
        XCTAssertEqual(final.reused, 1)
        XCTAssertEqual(final.recognized, 2)
        XCTAssertEqual(summary.textIndexCounts.records, 3)
        let requests = await recognizer.requests
        XCTAssertEqual(requests.map(\.id), ["a", "b", "b", "c"])
    }

    func testAccessAndRevisionChangesDuringRecognitionAbortInsteadOfOrdinarySkip() async throws {
        for change in ["generation", "permission", "authorization", "revision", "deleted"] {
            for lateFailure in [false, true] {
                let gate = TextWorkerGate()
                let recognizer = TextWorkerRecognizer { _, _, _ in
                    await gate.block()
                    if lateFailure { throw AppFailure.cloudOnly }
                    return workerTextResult()
                }
                let c = try context(recognizer: recognizer)
                let trace = TextWorkerProgress()
                let task = Task { try await c.worker.indexText(networkAllowed: false) { await trace.append($0) } }
                await gate.waitUntilEntered()
                switch change {
                case "generation": c.library.setGeneration(1)
                case "permission": c.library.setReadable(false)
                case "authorization": c.library.setAuthorization(4)
                case "revision": c.library.replace([PhotoRevision(id: "a", modificationTime: 124)])
                default: c.library.replace([])
                }
                await gate.release()
                do { _ = try await task.value; XCTFail("Access/revision changes must terminate OCR.") }
                catch AppFailure.permission { XCTAssertEqual(change, "permission") }
                catch AppFailure.photo { XCTAssertNotEqual(change, "permission") }
                let record = try await saved("a", in: c)
                let last = try await trace.last()
                XCTAssertNil(record)
                XCTAssertEqual(last.completed, 0)
                XCTAssertEqual(last.cloudSkipped, 0)
                XCTAssertEqual(last.failed, 0)
            }
        }
    }

    func testRecognizerPermissionAndCancellationAreFatalEvenWithReadableLibrary() async throws {
        for permission in [true, false] {
            let recognizer = TextWorkerRecognizer { _, _, _ in
                if permission { throw AppFailure.permission }
                throw CancellationError()
            }
            let c = try context(recognizer: recognizer)
            let trace = TextWorkerProgress()
            do {
                _ = try await c.worker.indexText(networkAllowed: false) { await trace.append($0) }
                XCTFail("Fatal recognition errors must propagate.")
            } catch AppFailure.permission { XCTAssertTrue(permission) }
            catch { XCTAssertFalse(permission); XCTAssertTrue(error is CancellationError) }
            let record = try await saved("a", in: c)
            let last = try await trace.last()
            XCTAssertNil(record)
            XCTAssertEqual(last.completed, 0)
            XCTAssertEqual(last.failed, 0)
        }
    }

    func testCloudAndUnavailableFailuresDoNotPersistCompletionOrExposePrivateErrors() async throws {
        let secret = "private-asset-id/private/path"
        let recognizer = TextWorkerRecognizer { id, _, _ in
            if id == "a" { throw AppFailure.cloudOnly }
            if id == "b" { throw NSError(domain: PHPhotosErrorDomain, code: 3164) }
            if id == "c" { throw NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: secret]) }
            return workerTextResult()
        }
        let c = try context(["a", "b", "c", "d"], recognizer: recognizer)
        let trace = TextWorkerProgress()
        let summary = try await c.worker.indexText(networkAllowed: false) { await trace.append($0) }
        let last = try await trace.last()
        XCTAssertEqual(last.completed, 4)
        XCTAssertEqual(last.recognized, 1)
        XCTAssertEqual(last.cloudSkipped, 2)
        XCTAssertEqual(last.failed, 1)
        XCTAssertEqual(summary.textIndexCounts.records, 1)
        XCTAssertFalse(last.summary.contains(secret))
        for id in ["a", "b", "c"] {
            let record = try await saved(id, in: c)
            XCTAssertNil(record)
        }
        let retry = TextWorkerProgress()
        _ = try await c.worker.indexText(networkAllowed: true) { await retry.append($0) }
        let online = try await retry.last()
        XCTAssertEqual(online.failed, 3)
        XCTAssertEqual(online.cloudSkipped, 0)
        XCTAssertEqual(online.reused, 1)
    }

    func testProgressMutationOrCancellationStopsBeforeNextRecognitionAndPreservesCommit() async throws {
        for boundary in [0, 1] {
            for change in ["permission", "generation", "cancel"] {
                let c = try context(["a", "b"])
                let trace = TextWorkerProgress()
                let task = Task {
                    try await c.worker.indexText(networkAllowed: false) { state in
                        await trace.append(state)
                        if state.completed == boundary {
                            if change == "permission" { c.library.setReadable(false) }
                            else if change == "generation" { c.library.setGeneration(1) }
                            else { withUnsafeCurrentTask { $0?.cancel() } }
                        }
                    }
                }
                do { _ = try await task.value; XCTFail("Progress is a suspension/access boundary.") }
                catch AppFailure.permission { XCTAssertEqual(change, "permission") }
                catch AppFailure.photo { XCTAssertEqual(change, "generation") }
                catch { XCTAssertEqual(change, "cancel"); XCTAssertTrue(error is CancellationError) }
                let a = try await saved("a", in: c)
                let b = try await saved("b", in: c)
                let requests = await c.recognizer.requests
                XCTAssertEqual(a != nil, boundary == 1)
                XCTAssertNil(b)
                XCTAssertEqual(requests.count, boundary)
            }
        }
    }

    func testUnsupportedDefaultsRejectEnabledOCRAndForwardDisabledFiltersExactly() async throws {
        let legacy = TextWorkerLegacyService()
        let service: any PhotoWorkServicing = legacy
        let filters = PhotoSearchFilters(albumID: "album")
        _ = try await service.search(text: "effective", originalText: "original", limit: -7,
                                      locationWeight: 0.37, filters: filters, textSearchEnabled: false)
        let calls = await legacy.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.text, "effective")
        XCTAssertEqual(calls.first?.limit, -7)
        XCTAssertEqual(calls.first?.weight, 0.37)
        XCTAssertEqual(calls.first?.filters, filters)
        do {
            _ = try await service.search(text: "effective", originalText: "original", limit: 1,
                                          locationWeight: 0, filters: .init(), textSearchEnabled: true)
            XCTFail("Enabled OCR must not silently fall back.")
        } catch AppFailure.photo { }
        do { _ = try await service.indexText(networkAllowed: false) { _ in }; XCTFail("Unsupported OCR.") }
        catch AppFailure.photo { }
        let c = try context(seedImages: false)
        let worker = PhotoIndexWorker(library: c.library, encoders: c.encoders, directory: c.directory, resolver: resolver)
        do { _ = try await worker.indexText(networkAllowed: false) { _ in }; XCTFail("A fake library must not implicitly use Vision.") }
        catch AppFailure.photo { }
        XCTAssertEqual(c.library.enumerationCount, 0)
        XCTAssertTrue(try disk(c.directory).isEmpty)
    }

    func testReadinessAndMissingDatabaseSearchNeverRecognizeEnumerateAtLaunchOrCreateFiles() async throws {
        let c = try context(seedImages: false, missingDirectory: true)
        let launch = try await c.worker.prepareForLaunch { _ in }
        let refresh = try await c.worker.refresh()
        XCTAssertFalse(launch.authorizedCountKnown)
        XCTAssertFalse(refresh.authorizedCountKnown)
        XCTAssertTrue(launch.textIndexStatisticsKnown)
        XCTAssertTrue(refresh.textIndexStatisticsKnown)
        XCTAssertNil(launch.textIndexIssue)
        XCTAssertNil(refresh.textIndexIssue)
        XCTAssertEqual(refresh.textIndexCounts, TextIndexCounts())
        XCTAssertEqual(c.library.enumerationCount, 0)
        let result = try await search(c)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.textSearchUsed)
        XCTAssertTrue(result.summary.textIndexStatisticsKnown)
        XCTAssertEqual(result.summary.textIndexCounts, TextIndexCounts())
        XCTAssertNil(result.summary.textIndexIssue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path))
        await assertNoRecognition(c)
    }

    func testCorruptOCRDatabaseDoesNotBlockLaunchOrRefreshAndIsNotRepaired() async throws {
        let c = try context()
        try Data("private OCR contents, not SQLite".utf8)
            .write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        let before = try disk(c.directory)
        let launch = try await c.worker.prepareForLaunch { _ in }
        let refresh = try await c.worker.refresh()
        for summary in [launch, refresh] {
            XCTAssertNil(summary.modelIssue)
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertTrue(summary.indexStatisticsKnown)
            XCTAssertEqual(summary.indexedCount, 1)
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertFalse(summary.textIndexStatisticsKnown)
            XCTAssertEqual(summary.textIndexCounts, TextIndexCounts())
            XCTAssertEqual(summary.textIndexIssue, "文字索引统计暂不可用，请稍后重试。")
        }
        XCTAssertEqual(c.library.enumerationCount, 0)
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testModelFailureSummaryStillReportsIndependentOptionalOCRStatus() async throws {
        for corrupt in [false, true] {
            let c = try context(seedImages: false)
            if corrupt {
                try Data("private OCR contents, not SQLite".utf8)
                    .write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
            }
            await c.encoders.failResources()
            let before = try disk(c.directory)
            let launch = try await c.worker.prepareForLaunch { _ in }
            let refresh = try await c.worker.refresh()
            for summary in [launch, refresh] {
                XCTAssertEqual(summary.modelIssue, AppFailure.modelContract("Synthetic model unavailable.").localizedDescription)
                XCTAssertNil(summary.modelVersion)
                XCTAssertFalse(summary.authorizedCountKnown)
                XCTAssertEqual(summary.textIndexStatisticsKnown, !corrupt)
                XCTAssertEqual(summary.textIndexCounts, TextIndexCounts())
                XCTAssertEqual(summary.textIndexIssue, corrupt ? "文字索引统计暂不可用，请稍后重试。" : nil)
            }
            XCTAssertEqual(c.library.enumerationCount, 0)
            XCTAssertEqual(try disk(c.directory), before)
            await assertNoRecognition(c)
        }
    }

    func testCorruptOCRDatabaseDoesNotBlockImageIndexSummary() async throws {
        let c = try context(["a", "b"])
        try Data("private OCR contents, not SQLite".utf8)
            .write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        let before = try disk(c.directory).filter { $0.key.hasPrefix("text-index.sqlite3") }
        let summary = try await c.worker.index(networkAllowed: false) { _ in }
        XCTAssertEqual(summary.authorizedCount, 2)
        XCTAssertTrue(summary.authorizedCountKnown)
        XCTAssertTrue(summary.indexStatisticsKnown)
        XCTAssertEqual(summary.indexedCount, 2)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        XCTAssertFalse(summary.textIndexStatisticsKnown)
        XCTAssertEqual(summary.textIndexCounts, TextIndexCounts())
        XCTAssertEqual(summary.textIndexIssue, "文字索引统计暂不可用，请稍后重试。")
        XCTAssertEqual(try disk(c.directory).filter { $0.key.hasPrefix("text-index.sqlite3") }, before)
        await assertNoRecognition(c)
    }

    func testManualOCRDetectsLibraryAdditionsWithoutGenerationBeforeWriting() async throws {
        let c = try context()
        c.library.setGeneration(nil)
        let before = try disk(c.directory)
        let expanded = [PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                        PhotoRevision(id: "new", modificationTime: 123, creationTime: 100)]
        do {
            _ = try await c.worker.indexText(networkAllowed: false) { progress in
                if progress.completed == 0 { c.library.replace(expanded) }
            }
            XCTFail("A fresh full snapshot must detect additions even without change notifications.")
        } catch AppFailure.photo { }
        XCTAssertGreaterThan(c.library.enumerationCount, 1)
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testReadinessCountsCurrentPolicyStoredRowsWithoutClaimingAuthorizationOrPruning() async throws {
        let c = try context(seedImages: false)
        try await seedText([textRow("hidden", text: ""), textRow("reduced", reduced: true),
                            textRow("old", policy: "old-policy")], in: c)
        c.library.setReadable(false)
        let before = try disk(c.directory)
        let summary = try await c.worker.refresh()
        XCTAssertEqual(summary.textIndexCounts.records, 2)
        XCTAssertEqual(summary.textIndexCounts.withText, 1)
        XCTAssertEqual(summary.textIndexCounts.reduced, 1)
        XCTAssertTrue(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertEqual(c.library.enumerationCount, 0)
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testDisabledSearchIsBitExactAndNeverOpensEvenCorruptOCRStorage() async throws {
        let c = try context(["a", "b", "c"], rows: [row("a"), row("b", axis: 1), row("c", axis: 1)])
        try Data("not a sqlite database".utf8).write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        let before = try disk(c.directory)
        for filters in [PhotoSearchFilters(), PhotoSearchFilters(imageKind: .photos)] {
            let legacy = try await c.worker.search(text: "effective query", limit: 2, locationWeight: 0.6, filters: filters)
            let disabled = try await search(c, limit: 2, weight: 0.6, filters: filters, enabled: false)
            assertSame(disabled.hits, legacy.hits)
            XCTAssertTrue(disabled.textMatchedIDs.isEmpty)
            XCTAssertFalse(disabled.textSearchUsed)
            for summary in [legacy.summary, disabled.summary] {
                XCTAssertFalse(summary.textIndexStatisticsKnown, "Unread OCR is unknown, not a factual zero.")
                XCTAssertNil(summary.textIndexIssue)
            }
        }
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testEnabledNoOCRMatchesExactlyPreservesVisualOrderAndScoreBits() async throws {
        for existingTextStore in [false, true] {
            let c = try context(["a", "b", "c"], rows: [row("a", axis: 1), row("b"), row("c")])
            if existingTextStore { try await seedText([textRow("a", text: "")], in: c) }
            let before = try disk(c.directory)
            for limit in [0, 1, Int.max] {
                let visual = try await search(c, limit: limit, weight: 0.6, enabled: false)
                let hybrid = try await search(c, original: "unmatched", limit: limit, weight: 0.6)
                assertSame(hybrid.hits, visual.hits)
                XCTAssertFalse(hybrid.textSearchUsed)
                XCTAssertTrue(hybrid.textMatchedIDs.isEmpty)
                XCTAssertFalse(visual.summary.textIndexStatisticsKnown)
                XCTAssertTrue(hybrid.summary.textIndexStatisticsKnown)
                XCTAssertEqual(hybrid.summary.textIndexCounts.records, existingTextStore ? 1 : 0)
                XCTAssertNil(hybrid.summary.textIndexIssue)
            }
            XCTAssertEqual(try disk(c.directory), before)
            await assertNoRecognition(c)
        }
    }

    func testOriginalOCRQueryAndEffectiveVisualQueryAreSeparateAndFusionPrecedesLimit() async throws {
        let c = try context(["a", "b", "z"], rows: [row("a"), row("b", axis: 1), row("z", axis: 1)])
        try await seedText([textRow("z", text: "收据")], in: c)
        let before = try disk(c.directory)
        let result = try await search(c, original: "收据", limit: 1)
        XCTAssertEqual(result.hits.map(\.id), ["z"], "OCR may promote a visual candidate beyond the original top-K.")
        XCTAssertEqual(result.hits.first?.score.bitPattern, Float(0).bitPattern)
        XCTAssertEqual(result.textMatchedIDs, ["z"])
        XCTAssertTrue(result.textSearchUsed)
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.texts, ["effective query"])
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testDeterministicEqualRRFUsesFullVisualRankingBeforeFiltersAndLimit() async throws {
        let ids = (0..<80).map { String(format: "id-%02d", $0) }
        let c = try context(ids, rows: ids.map { row($0, axis: $0 == ids[0] ? 0 : 1) })
        try await seedText([textRow(ids[79]), textRow(ids[60])], in: c)
        let visual = try await search(c, enabled: false)
        let reader = SQLiteTextStore(directory: c.directory, readOnly: true)
        let matches = try await reader.matches(query: "receipt", revisions: Dictionary(uniqueKeysWithValues: ids.map { ($0, Double(123)) }))
        await reader.close()
        XCTAssertEqual(matches.count, 2)
        let visualRanks = Dictionary(uniqueKeysWithValues: visual.hits.enumerated().map { ($0.element.id, $0.offset) })
        var rrf: [String: Double] = [:]
        for (index, hit) in visual.hits.enumerated() { rrf[hit.id] = 1 / Double(60 + index + 1) }
        for (index, match) in matches.enumerated() { rrf[match.id, default: 0] += 1 / Double(60 + index + 1) }
        let expected = visual.hits.sorted {
            let left = rrf[$0.id, default: 0], right = rrf[$1.id, default: 0]
            return left == right ? visualRanks[$0.id, default: 0] < visualRanks[$1.id, default: 0] : left > right
        }
        let first = try await search(c)
        let repeated = try await search(c)
        assertSame(first.hits, expected)
        assertSame(repeated.hits, expected)
        let keep: Set<String> = [ids[0], ids[79]]
        c.library.setMatchingIDs(keep)
        let filtered = try await search(c, limit: 1, filters: .init(albumID: "subset"))
        assertSame(filtered.hits, Array(expected.filter { keep.contains($0.id) }.prefix(1)))
        XCTAssertEqual(filtered.textMatchedIDs, Set(filtered.hits.map(\.id)).intersection(Set(matches.map(\.id))))
        c.library.setMatchingIDs([])
        let empty = try await search(c, filters: .init(albumID: "empty"))
        XCTAssertTrue(empty.hits.isEmpty)
        XCTAssertTrue(empty.textMatchedIDs.isEmpty)
        XCTAssertFalse(empty.textSearchUsed)

        // Deliberately distinguish fuse-then-filter from filter-then-fuse:
        // A has visual/text ranks 1/10; B has ranks 4/1, so B wins globally.
        // Filtering either input first renumbers them to 1/2 and 2/1, incorrectly
        // producing a tie won by A's original visual rank.
        func gradedRow(_ id: String, cosine: Float) -> CachedPhoto {
            var vector = TestFixtures.vector(axis: 1)
            vector[0] = cosine
            vector[1] = (1 - cosine * cosine).squareRoot()
            return row(id, vector: vector)
        }
        let drops = (0..<8).map { "drop-\($0)" }
        var globalRows = [row("a-keep"), gradedRow("b-keep", cosine: 0.25)]
        globalRows += drops.enumerated().map {
            gradedRow($0.element, cosine: $0.offset == 0 ? 0.75 : ($0.offset == 1 ? 0.5 : 0))
        }
        let global = try context(["a-keep", "b-keep"] + drops, rows: globalRows)
        try await seedText([textRow("a-keep", text: "receipt"), textRow("b-keep", text: "receipt total")]
                           + drops.map { textRow($0, text: "receipt total") }, in: global)
        global.library.setMatchingIDs(["a-keep", "b-keep"])
        let selected = try await search(global, original: "receipt total", limit: 1, filters: .init(albumID: "keep"))
        XCTAssertEqual(selected.hits.map(\.id), ["b-keep"])
        XCTAssertEqual(selected.hits.first?.score.bitPattern, Float(0.25).bitPattern)
    }

    func testHybridFilteringPreservesGlobalDistinctPlaceCenterAndOriginalScores() async throws {
        let a = PlaceEmbedding(text: "A", vector: TestFixtures.vector())
        let b = PlaceEmbedding(text: "B", vector: TestFixtures.vector(axis: 1))
        let rows = [row("keep-a", axis: 1, place: a), row("keep-duplicate", axis: 1, place: a),
                    row("keep-neutral"), row("drop-b", place: b)]
        let c = try context(rows.map { $0.photo.id }, rows: rows)
        try await seedText([textRow("keep-neutral")], in: c)
        c.library.setMatchingIDs(["keep-a", "keep-duplicate", "keep-neutral"])
        let full = try await search(c, weight: 1, enabled: false)
        let mixed = try await search(c, weight: 1, filters: .init(albumID: "keep"))
        let scoreBits = Dictionary(uniqueKeysWithValues: full.hits.map { ($0.id, $0.score.bitPattern) })
        for hit in mixed.hits { XCTAssertEqual(hit.score.bitPattern, scoreBits[hit.id]) }
        XCTAssertEqual(mixed.hits.first { $0.id == "keep-a" }?.score, 0.5)
        XCTAssertEqual(mixed.hits.first { $0.id == "keep-neutral" }?.score, 0)
    }

    func testOCRCannotLeakUnindexedInaccessibleWrongModelPolicyOrStaleRevisionCandidates() async throws {
        let c = try context(["current", "edited", "wrong-text-revision", "old-policy", "unindexed", "wrong-model"], rows: [
            row("current"), row("edited", revision: 122), row("wrong-text-revision"), row("old-policy"),
            row("hidden"), row("wrong-model", model: "old")
        ])
        try await seedText([textRow("current"), textRow("edited", revision: 122),
                            textRow("wrong-text-revision", revision: 122), textRow("old-policy", policy: "old-policy"),
                            textRow("unindexed"), textRow("hidden"), textRow("wrong-model")], in: c)
        let before = try disk(c.directory)
        let visual = try await search(c, enabled: false)
        let result = try await search(c)
        XCTAssertEqual(result.textMatchedIDs, ["current"])
        XCTAssertEqual(Set(result.hits.map(\.id)), Set(visual.hits.map(\.id)))
        XCTAssertTrue(result.hits.contains { $0.id == "edited" }, "Edited visuals retain the explicit manual-update policy.")
        let bits = Dictionary(uniqueKeysWithValues: visual.hits.map { ($0.id, $0.score.bitPattern) })
        for hit in result.hits { XCTAssertEqual(hit.score.bitPattern, bits[hit.id]) }
        XCTAssertEqual(try disk(c.directory), before, "Searching must not reconcile stale OCR rows.")
    }

    func testSimilarityRemainsVectorOnlyEvenWithCorruptOCRStorageAndRetainsSeedGuard() async throws {
        let c = try context(["seed", "a", "b"], rows: [row("seed", axis: 1), row("a", axis: 1), row("b")])
        try Data("broken text database".utf8).write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        let before = try disk(c.directory)
        let result = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
        XCTAssertEqual(result.hits.map(\.id), ["a"])
        XCTAssertEqual(result.hits.first?.score.bitPattern, Float(1).bitPattern)
        XCTAssertFalse(result.textSearchUsed)
        XCTAssertTrue(result.textMatchedIDs.isEmpty)
        XCTAssertFalse(result.summary.textIndexStatisticsKnown)
        XCTAssertNil(result.summary.textIndexIssue)
        let calls = await c.encoders.calls()
        XCTAssertTrue(calls.texts.isEmpty)
        try result.validatePageAccess(["a"])
        c.library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)])
        XCTAssertThrowsError(try result.validatePageAccess([]))
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testEnabledOCRStorageFailureIsExplicitWithoutVisualFallback() async throws {
        let c = try context()
        try Data("broken text database".utf8).write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        let before = try disk(c.directory)
        do { _ = try await search(c); XCTFail("Opt-in OCR failure must be visible.") }
        catch AppFailure.storage(let issue) { XCTAssertEqual(issue, "文字索引无法读写，请稍后重试。") }
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoRecognition(c)
    }

    func testHybridZeroAndNegativeLimitsRetainCoreValidationAndNeverPrefixNegative() async throws {
        let c = try context()
        try await seedText([textRow("a")], in: c)
        for filters in [PhotoSearchFilters(), PhotoSearchFilters(imageKind: .photos)] {
            do { _ = try await search(c, limit: -1, filters: filters); XCTFail("Negative limit.") }
            catch { XCTAssertEqual(error as? VectorSearchError, .negativeLimit) }
            do { _ = try await search(c, limit: -1, weight: -1, filters: filters); XCTFail("Invalid weight first.") }
            catch { XCTAssertEqual(error as? VectorSearchError, .invalidLocationWeight) }
            let zero = try await search(c, limit: 0, filters: filters)
            XCTAssertTrue(zero.hits.isEmpty)
            XCTAssertTrue(zero.textMatchedIDs.isEmpty)
            XCTAssertFalse(zero.textSearchUsed)
        }
        let invalid = try context(query: [])
        do { _ = try await search(invalid, limit: 0); XCTFail("Zero limit must validate the query vector.") }
        catch { XCTAssertEqual(invalid.library.filterCalls, 0) }
    }

    func testHybridPublicationAndPageGuardsRejectUnknownIDsEditsPermissionAndGeneration() async throws {
        for change in ["edit", "permission", "authorization", "generation"] {
            let c = try context(["a", "b"])
            try await seedText([textRow("b")], in: c)
            let response = try await search(c)
            try response.validateAccess()
            try response.validatePageAccess(["b"])
            XCTAssertThrowsError(try response.validatePageAccess(["unknown"]))
            switch change {
            case "edit": c.library.replace([PhotoRevision(id: "b", modificationTime: 124)])
            case "permission": c.library.setReadable(false)
            case "authorization": c.library.setAuthorization(4)
            default: c.library.setGeneration(1)
            }
            XCTAssertThrowsError(try response.validateAccess())
            XCTAssertThrowsError(try response.validatePageAccess(["b"]))
        }
    }

    func testImageIndexNeverRecognizesOrReconcilesTextAndStaleTextCannotBoost() async throws {
        let c = try context(["a", "b"])
        try await seedText([textRow("b", revision: 122), textRow("orphan")], in: c)
        let textBefore = try Data(contentsOf: c.directory.appendingPathComponent("text-index.sqlite3"))
        let summary = try await c.worker.index(networkAllowed: false) { _ in }
        XCTAssertTrue(summary.textIndexStatisticsKnown)
        XCTAssertEqual(summary.textIndexCounts.records, 2)
        XCTAssertNil(summary.textIndexIssue)
        let result = try await search(c)
        XCTAssertFalse(result.textSearchUsed)
        XCTAssertTrue(result.textMatchedIDs.isEmpty)
        let orphan = try await saved("orphan", in: c)
        XCTAssertNotNil(orphan)
        XCTAssertEqual(try Data(contentsOf: c.directory.appendingPathComponent("text-index.sqlite3")), textBefore)
        await assertNoRecognition(c)
    }

    func testClearRemovesBothIndexesAndDoesNotRecognizeOrEnumerate() async throws {
        let c = try context()
        try await seedText([textRow("a"), textRow("orphan")], in: c)
        let summary = try await c.worker.clear()
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.textIndexCounts, TextIndexCounts())
        XCTAssertTrue(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        let revisions = try await SQLitePhotoStore(directory: c.directory, readOnly: true)
            .searchRevisions(modelVersion: cacheVersion, accessibleIDs: ["a"])
        let record = try await saved("a", in: c)
        XCTAssertTrue(revisions.isEmpty)
        XCTAssertNil(record)
        XCTAssertEqual(c.library.enumerationCount, 0)
        await assertNoRecognition(c)
    }

    func testHybridRevalidatesFullLibraryAfterQueryAndAfterFiltering() async throws {
        for atQuery in [true, false] {
            let c = try context(["a", "excluded"])
            try await seedText([textRow("a")], in: c)
            c.library.setGeneration(nil)
            c.library.setMatchingIDs(["a"])
            let library = c.library
            let change: @Sendable () -> Void = {
                library.replace([PhotoRevision(id: "a", modificationTime: 123, creationTime: 100),
                                 PhotoRevision(id: "excluded", modificationTime: 124, creationTime: 100)])
            }
            if atQuery { await c.encoders.afterText(change) }
            else { c.library.afterFiltering(change) }
            do { _ = try await search(c, filters: .init(albumID: "keep")); XCTFail("Excluded rows still affect global scoring.") }
            catch AppFailure.photo { }
            await assertNoRecognition(c)
        }
    }
}

private func workerTextResult(_ text: String = "receipt", reduced: Bool = false) -> RecognizedPhotoText {
    RecognizedPhotoText(text: text, pixelWidth: 640, pixelHeight: 480, isReduced: reduced)
}

private struct TextWorkerContext: Sendable {
    let worker: PhotoIndexWorker
    let library: TextWorkerLibrary
    let encoders: TextWorkerEncoders
    let recognizer: TextWorkerRecognizer
    let directory: URL
}

private actor TextWorkerRecognizer: PhotoTextRecognizing {
    struct Request: Sendable { let id: String; let networkAllowed: Bool }
    private let handler: @Sendable (String, Bool, Int) async throws -> RecognizedPhotoText
    private(set) var requests: [Request] = []
    init(_ handler: @escaping @Sendable (String, Bool, Int) async throws -> RecognizedPhotoText = { _, _, _ in workerTextResult() }) {
        self.handler = handler
    }
    func recognize(id: String, networkAllowed: Bool) async throws -> RecognizedPhotoText {
        requests.append(Request(id: id, networkAllowed: networkAllowed))
        // Deliberately permit late success after cancellation, like native callbacks.
        return try await handler(id, networkAllowed, requests.count)
    }
}

private actor TextWorkerProgress {
    private var states: [TextIndexProgress] = []
    func append(_ state: TextIndexProgress) { states.append(state) }
    func last() throws -> TextIndexProgress { try XCTUnwrap(states.last) }
}

private actor TextWorkerGate {
    private var entered = false
    private var waitingForEntry: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        waitingForEntry.forEach { $0.resume() }
        waitingForEntry.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waitingForEntry.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private final class TextWorkerLibrary: PhotoLibraryIndexing, PhotoSearchFiltering, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [PhotoRevision]
    private var readable = true
    private var authorization: Int? = 3
    private var generation: UInt64? = 0
    private var enumerations = 0
    private var pixels = 0
    private var places = 0
    private var filters = 0
    private var matchingIDs: Set<String>?
    private var filteringAction: (@Sendable () -> Void)?
    init(_ revisions: [PhotoRevision]) { self.revisions = revisions }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { generation } }
    var enumerationCount: Int { locked { enumerations } }
    var pixelCalls: Int { locked { pixels } }
    var placeCalls: Int { locked { places } }
    var filterCalls: Int { locked { filters } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func setGeneration(_ value: UInt64?) { locked { generation = value } }
    func replace(_ value: [PhotoRevision]) { locked { revisions = value } }
    func setMatchingIDs(_ value: Set<String>) { locked { matchingIDs = value } }
    func afterFiltering(_ action: @escaping @Sendable () -> Void) { locked { filteringAction = action } }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try locked {
            enumerations += 1
            guard readable else { throw AppFailure.permission }
            return revisions.sorted { $0.id < $1.id }
        }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        locked { readable ? revisions.first { $0.id == id } : nil }
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { locked { places += 1 }; return nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixels += 1 }
        XCTFail("Unexpected pixel request outside the injected text recognizer.")
        throw AppFailure.photo("Unexpected image request.")
    }
    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String> {
        try filters.validate()
        let (ids, action) = locked { self.filters += 1; return (matchingIDs, filteringAction) }
        let result = Set(snapshot.filter {
            (ids?.contains($0.id) ?? true)
                && filters.matches(creationDate: $0.creationTime.map { Date(timeIntervalSince1970: $0) },
                                   isScreenshot: false, isLivePhoto: false)
        }.map(\.id))
        action?()
        return result
    }
}

private actor TextWorkerEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let query: [Float]
    private var inspections = 0
    private var preparations = 0
    private var texts: [String] = []
    private var images = 0
    private var slots = 0
    private var textAction: (@Sendable () -> Void)?
    private var resourcesFail = false
    init(query: [Float]) throws {
        self.query = query
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
    }
    func failResources() { resourcesFail = true }
    func inspectResources() throws -> ModelManifest {
        inspections += 1
        if resourcesFail { throw AppFailure.modelContract("Synthetic model unavailable.") }
        return manifest
    }
    func prepare() throws -> ModelManifest {
        preparations += 1
        if resourcesFail { throw AppFailure.modelContract("Synthetic model unavailable.") }
        return manifest
    }
    func afterText(_ action: @escaping @Sendable () -> Void) { textAction = action }
    func text(_ text: String) -> [Float] { texts.append(text); textAction?(); return query }
    func image(preview: IndexingImage) throws -> [Float] {
        images += 1
        XCTFail("Unexpected image encoding.")
        throw AppFailure.photo("Unexpected image encoding.")
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        images += 1
        XCTFail("Unexpected original encoding.")
        throw AppFailure.photo("Unexpected original encoding.")
    }
    func makeIndexingImageEncoders() -> [any PhotoImageEncoding] {
        slots += 1
        return [any PhotoImageEncoding](repeating: self, count: PhotoIndexWorker.indexingWorkerCount)
    }
    func calls() -> (inspections: Int, preparations: Int, texts: [String], images: Int, slots: Int) {
        (inspections, preparations, texts, images, slots)
    }
}

private actor TextWorkerLegacyService: PhotoWorkServicing {
    struct Request: Sendable {
        let text: String
        let limit: Int
        let weight: Float
        let filters: PhotoSearchFilters
    }
    private(set) var calls: [Request] = []
    func refresh() -> LibrarySummary { LibrarySummary() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) -> LibrarySummary { LibrarySummary() }
    func search(text: String, limit: Int, locationWeight: Float) -> SearchResponse {
        SearchResponse(summary: LibrarySummary(), hits: [])
    }
    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) -> SearchResponse {
        calls.append(Request(text: text, limit: limit, weight: locationWeight, filters: filters))
        return SearchResponse(summary: LibrarySummary(), hits: [])
    }
    func clear() -> LibrarySummary { LibrarySummary() }
}