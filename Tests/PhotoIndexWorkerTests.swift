import Foundation
import CoreGraphics
import ImageIO
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

final class PhotoIndexWorkerTests: XCTestCase {
    private let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("No test boundary pack.")

    private func makeWorker(_ records: [WorkerTestRecord], encoders supplied: WorkerTestEncoders? = nil) throws -> WorkerTestContext {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLitePhotoStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        let library = WorkerTestLibrary(records)
        let encoders = try supplied ?? WorkerTestEncoders()
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        return WorkerTestContext(worker: worker, library: library, encoders: encoders, store: store, directory: directory)
    }

    private func seed(_ context: WorkerTestContext, id: String, model: String, geography: String? = nil,
                      label: String? = nil) async throws {
        let place = label.map { PlaceEmbedding(text: "Photo taken in \($0).", vector: TestFixtures.vector(axis: 1)) }
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model,
                                 imageEmbedding: TestFixtures.vector(axis: 1), location: place, creationTime: 100)
        try await context.store.save(CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version))
    }

    private func assertSources(_ progress: IndexProgress, local: Int = 0, reduced: Int = 0, network: Int = 0,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(progress.localPreviews, local, file: file, line: line)
        XCTAssertEqual(progress.reducedPreviews, reduced, file: file, line: line)
        XCTAssertEqual(progress.networkPreviews, network, file: file, line: line)
        XCTAssertEqual(progress.localPreviews + progress.reducedPreviews + progress.networkPreviews,
                       progress.encoded, file: file, line: line)
    }

    func testOfflineIndexes114LocalAndCloudCachedPreviewsWithoutOriginalAPI() async throws {
        let local = try WorkerPreviewFactory.make(.localPreview)
        let reduced = try WorkerPreviewFactory.make(.localReducedPreview, orientation: .leftMirrored)
        var records = (0..<114).map { WorkerTestRecord("local-\($0)", .preview(local)) }
        // These stand in for optimized iCloud assets whose cached preview is readable
        // even though their original is absent. The mock has NO original-data API.
        records += (0..<6).map { WorkerTestRecord("cloud-cached-\($0)", .preview(reduced)) }
        let context = try makeWorker(records)
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.authorizedCount, 120)
        XCTAssertEqual(summary.indexedCount, 120)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        XCTAssertEqual(final.total, 120)
        XCTAssertEqual(final.completed, 120)
        XCTAssertEqual(final.encoded, 120)
        XCTAssertEqual(final.reused, 0)
        XCTAssertEqual(final.cloudSkipped, 0)
        XCTAssertEqual(final.failed, 0)
        assertSources(final, local: 114, reduced: 6)
        let requests = context.library.requests
        XCTAssertEqual(requests.count, 120)
        XCTAssertTrue(requests.allSatisfy { !$0.networkAllowed })
        let previews = await context.encoders.previews
        let dataCalls = await context.encoders.dataCalls
        XCTAssertEqual(previews.count, 120)
        XCTAssertEqual(dataCalls, 0)
        for preview in previews.prefix(114) {
            XCTAssertTrue(preview.cgImage === local.cgImage)
            XCTAssertEqual(preview.orientation, .right)
        }
        for preview in previews.suffix(6) {
            XCTAssertTrue(preview.cgImage === reduced.cgImage)
            XCTAssertEqual(preview.orientation, .leftMirrored)
        }
        let saved = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(saved.count, 120)
        XCTAssertTrue(saved.allSatisfy { $0.photo.imageEmbedding == TestFixtures.vector() })
        let states = await progress.states
        XCTAssertEqual(states.count, 121)
        for state in states {
            XCTAssertEqual(state.localPreviews + state.reducedPreviews + state.networkPreviews, state.encoded)
        }
    }

    func testNetworkOptInCountsActualSourcesOnlyAfterRecordsAreSaved() async throws {
        let context = try makeWorker([
            WorkerTestRecord("local", .preview(try WorkerPreviewFactory.make(.localPreview))),
            WorkerTestRecord("reduced", .preview(try WorkerPreviewFactory.make(.localReducedPreview))),
            WorkerTestRecord("network", .networkOnly(try WorkerPreviewFactory.make(.networkPreview)))
        ])
        let store = context.store
        let version = cacheVersion
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: true) { state in
            do {
                let saved = try await store.records(modelVersion: version)
                XCTAssertEqual(saved.count, state.encoded, "Progress must follow the SQLite commit.")
                XCTAssertEqual(state.localPreviews + state.reducedPreviews + state.networkPreviews, saved.count)
            } catch { XCTFail("Could not inspect committed records: \(error)") }
            await progress.append(state)
        }
        let final = try await progress.last()
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(final.completed, 3)
        XCTAssertEqual(final.failed, 0)
        XCTAssertEqual(final.cloudSkipped, 0)
        assertSources(final, local: 1, reduced: 1, network: 1)
        XCTAssertTrue(context.library.requests.allSatisfy(\.networkAllowed))
    }

    func testSecondRunReusesCacheWithoutRequestsOrSourceCounts() async throws {
        let context = try makeWorker([
            WorkerTestRecord("local", .preview(try WorkerPreviewFactory.make(.localPreview))),
            WorkerTestRecord("reduced", .preview(try WorkerPreviewFactory.make(.localReducedPreview))),
            WorkerTestRecord("network", .networkOnly(try WorkerPreviewFactory.make(.networkPreview)))
        ])
        _ = try await context.worker.index(networkAllowed: true) { _ in }
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(final.completed, 3)
        XCTAssertEqual(final.reused, 3)
        XCTAssertEqual(final.encoded, 0)
        XCTAssertEqual(final.cloudSkipped, 0)
        assertSources(final)
        XCTAssertEqual(context.library.requests.count, 3)
        let previews = await context.encoders.previews
        XCTAssertEqual(previews.count, 3)
    }

    func testRaw3164AndNormalizedCloudOnlyAreNeedNetworkWhenOffline() async throws {
        let context = try makeWorker([
            WorkerTestRecord("raw", .failure(NSError(domain: PHPhotosErrorDomain, code: 3164))),
            WorkerTestRecord("normalized", .cloudOnly)
        ])
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.authorizedCount, 2)
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(final.completed, 2)
        XCTAssertEqual(final.cloudSkipped, 2)
        XCTAssertEqual(final.failed, 0)
        XCTAssertNil(final.lastFailure)
        XCTAssertTrue(final.summary.contains("2 need network"))
        XCTAssertFalse(final.summary.contains("iCloud skipped"))
        assertSources(final)
        let previews = await context.encoders.previews
        XCTAssertTrue(previews.isEmpty)
    }

    func testRealErrorsAnd3164FromOtherDomainsRemainUnavailable() async throws {
        let real = NSError(domain: PHPhotosErrorDomain, code: 3300,
                           userInfo: [NSLocalizedDescriptionKey: "Synthetic inaccessible resource"])
        let otherDomain = NSError(domain: "WorkerTestOtherDomain", code: 3164,
                                  userInfo: [NSLocalizedDescriptionKey: "Not a PhotoKit network requirement"])
        let context = try makeWorker([
            WorkerTestRecord("real", .failure(real)), WorkerTestRecord("other-domain", .failure(otherDomain))
        ])
        let progress = WorkerProgressTrace()
        _ = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(final.completed, 2)
        XCTAssertEqual(final.failed, 2)
        XCTAssertEqual(final.cloudSkipped, 0)
        XCTAssertEqual(final.lastFailure, otherDomain.localizedDescription)
        XCTAssertTrue(final.summary.contains("2 unavailable"))
        assertSources(final)
    }

    func test3164WithNetworkAllowedRemainsFailure() async throws {
        let context = try makeWorker([
            WorkerTestRecord("raw", .failure(NSError(domain: PHPhotosErrorDomain, code: 3164))),
            WorkerTestRecord("normalized", .cloudOnly)
        ])
        let progress = WorkerProgressTrace()
        _ = try await context.worker.index(networkAllowed: true) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(final.completed, 2)
        XCTAssertEqual(final.failed, 2)
        XCTAssertEqual(final.cloudSkipped, 0)
        XCTAssertNotNil(final.lastFailure)
        assertSources(final)
    }

    func testEncoderFailureDoesNotCountPreviewSource() async throws {
        let encoders = try WorkerTestEncoders(imageFailure: .photo("Synthetic encoding failure"))
        let context = try makeWorker([
            WorkerTestRecord("asset", .preview(try WorkerPreviewFactory.make(.localReducedPreview)))
        ], encoders: encoders)
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 1)
        assertSources(final)
        let saved = try await context.store.record(id: "asset")
        XCTAssertNil(saved)
    }

    func testModelAndPreviewPolicyUpgradesRebuildWithoutClearingValidCache() async throws {
        let preview = try WorkerPreviewFactory.make(.localPreview)
        let context = try makeWorker(["original", "old-model", "old-policy", "current"].map {
            WorkerTestRecord($0, .preview(preview))
        })
        try await seed(context, id: "original", model: "test-model")
        try await seed(context, id: "old-model", model: IndexImagePolicy.cacheVersion(modelVersion: "older-model"))
        try await seed(context, id: "old-policy", model: "test-model|photokit-preview-v0")
        try await seed(context, id: "current", model: cacheVersion)
        let before = try await context.worker.refresh()
        XCTAssertEqual(before.authorizedCount, 4)
        XCTAssertEqual(before.indexedCount, 1)
        let beforeSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0)
        XCTAssertEqual(beforeSearch.hits.map(\.id), ["current"])
        XCTAssertEqual(beforeSearch.summary.indexedCount, 1)
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.indexedCount, 4)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertEqual(final.reused, 1)
        XCTAssertEqual(final.encoded, 3)
        assertSources(final, local: 3)
        XCTAssertEqual(context.library.requests.map(\.id), ["original", "old-model", "old-policy"])
        let saved = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(saved.count, 4)
        for record in saved {
            XCTAssertEqual(record.photo.modelVersion, cacheVersion)
            XCTAssertEqual(record.photo.imageEmbedding, TestFixtures.vector(axis: record.photo.id == "current" ? 1 : 0))
        }
        let afterSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0)
        XCTAssertEqual(afterSearch.hits.count, 4)
        XCTAssertTrue(afterSearch.hits.allSatisfy { $0.photo.modelVersion == cacheVersion })
        let manifest = try await context.encoders.prepare()
        XCTAssertEqual(manifest.modelVersion, "test-model", "Policy versioning must not mutate the model manifest.")
    }

    func testLegacy512CacheIsIgnoredThenReplacedBy768OnModelVersionChange() async throws {
        let preview = try WorkerPreviewFactory.make(.localPreview)
        let context = try makeWorker([
            WorkerTestRecord("legacy-a", .preview(preview), label: "Shared Place"),
            WorkerTestRecord("legacy-b", .preview(preview), label: "Shared Place"),
            WorkerTestRecord("current", .preview(preview))
        ])
        // Keep preview policy, revisions and geography identical. A modelVersion
        // change alone must trigger re-encoding, with no clear/recovery operation.
        let oldVersion = IndexImagePolicy.cacheVersion(modelVersion: TestFixtures.legacyModelVersion)
        XCTAssertNotEqual(oldVersion, cacheVersion)
        let text = "Photo taken in Shared Place."
        let oldPlace = PlaceEmbedding(text: text, vector: TestFixtures.vector(axis: 511, dimension: 512))
        let oldRows = ["legacy-a", "legacy-b"].map { id in
            CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: 123, modelVersion: oldVersion,
                                             imageEmbedding: TestFixtures.vector(axis: 510, dimension: 512),
                                             location: oldPlace, creationTime: 100), geographyVersion: resolver.version)
        }
        try TestFixtures.seedRawCache(oldRows, directory: context.directory)
        try await seed(context, id: "current", model: cacheVersion)

        let before = try await context.worker.refresh()
        XCTAssertEqual(before.authorizedCount, 3)
        XCTAssertEqual(before.indexedCount, 1)
        XCTAssertEqual(before.locatedCount, 0)
        XCTAssertNil(before.modelIssue)
        let beforeSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(beforeSearch.hits.map(\.id), ["current"])
        XCTAssertEqual(beforeSearch.summary.indexedCount, 1)
        XCTAssertTrue(context.library.requests.isEmpty)
        let retained = try await context.store.records(modelVersion: oldVersion)
        XCTAssertEqual(retained.map(\.photo.id), ["legacy-a", "legacy-b"])
        XCTAssertTrue(retained.allSatisfy { $0.photo.imageEmbedding.count == 512 && $0.photo.location?.vector.count == 512 })

        let trace = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await trace.append($0) }
        let final = try await trace.last()
        XCTAssertEqual(summary.authorizedCount, 3)
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(summary.locatedCount, 2)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(final.completed, 3)
        XCTAssertEqual(final.encoded, 2)
        XCTAssertEqual(final.reused, 1)
        XCTAssertEqual(final.failed, 0)
        XCTAssertEqual(final.cloudSkipped, 0)
        XCTAssertNil(final.lastFailure)
        assertSources(final, local: 2)
        XCTAssertEqual(context.library.requests.map(\.id), ["legacy-a", "legacy-b"])
        XCTAssertTrue(context.library.requests.allSatisfy { !$0.networkAllowed })

        let saved = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(saved.count, 3)
        for row in saved {
            XCTAssertEqual(row.photo.modelVersion, cacheVersion)
            XCTAssertEqual(row.photo.modificationTime, 123)
            XCTAssertEqual(row.photo.creationTime, 100)
            XCTAssertEqual(row.geographyVersion, resolver.version)
            XCTAssertEqual(row.photo.imageEmbedding.count, 768)
            XCTAssertEqual(row.photo.imageEmbedding, TestFixtures.vector(axis: row.photo.id == "current" ? 1 : 0))
            try EmbeddingValidation.validateUnit(row.photo.imageEmbedding)
            if row.photo.id != "current" {
                let place = try XCTUnwrap(row.photo.location)
                XCTAssertEqual(place.text, text)
                XCTAssertEqual(place.vector, TestFixtures.vector(axis: 2))
                try EmbeddingValidation.validateUnit(place.vector)
            }
        }
        let obsolete = try await context.store.records(modelVersion: oldVersion)
        let obsoletePlace = try await context.store.place(text: text, modelVersion: oldVersion)
        let activePlace = try await context.store.place(text: text, modelVersion: cacheVersion)
        XCTAssertTrue(obsolete.isEmpty)
        XCTAssertNil(obsoletePlace)
        XCTAssertEqual(activePlace, TestFixtures.vector(axis: 2))
        let encodedTexts = await context.encoders.texts
        XCTAssertEqual(encodedTexts.filter { $0.hasPrefix("Photo taken in ") }, [text],
                       "The old 512-D place must not be reused; the fresh 768-D place is encoded once.")
        let afterSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(Set(afterSearch.hits.map(\.id)), Set(["legacy-a", "legacy-b", "current"]))
        XCTAssertTrue(afterSearch.hits.allSatisfy { $0.photo.modelVersion == cacheVersion && $0.photo.imageEmbedding.count == 768 })

        let reusedTrace = WorkerProgressTrace()
        let reused = try await context.worker.index(networkAllowed: false) { await reusedTrace.append($0) }
        let reusedFinal = try await reusedTrace.last()
        XCTAssertEqual(reused.indexedCount, 3)
        XCTAssertEqual(reusedFinal.reused, 3)
        XCTAssertEqual(reusedFinal.encoded, 0)
        XCTAssertEqual(reusedFinal.failed, 0)
        assertSources(reusedFinal)
        XCTAssertEqual(context.library.requests.count, 2)
        let previews = await context.encoders.previews
        let dataCalls = await context.encoders.dataCalls
        XCTAssertEqual(previews.count, 2)
        XCTAssertEqual(dataCalls, 0)
    }

    func testFailedLegacy512UpgradeRetainsRowAndRetriesWithoutManualClear() async throws {
        let failure = NSError(domain: "WorkerTestLegacyUpgrade", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Synthetic preview unavailable"])
        let context = try makeWorker([WorkerTestRecord("legacy", .failure(failure), label: "Retained Place")])
        let oldVersion = IndexImagePolicy.cacheVersion(modelVersion: TestFixtures.legacyModelVersion)
        let place = PlaceEmbedding(text: "Photo taken in Retained Place.", vector: TestFixtures.vector(axis: 511, dimension: 512))
        let old = IndexedPhoto(id: "legacy", modificationTime: 123, modelVersion: oldVersion,
                               imageEmbedding: TestFixtures.vector(axis: 510, dimension: 512), location: place, creationTime: 100)
        try TestFixtures.seedRawCache([CachedPhoto(photo: old, geographyVersion: resolver.version)], directory: context.directory)
        let trace = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await trace.append($0) }
        let final = try await trace.last()
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 1)
        XCTAssertEqual(final.lastFailure, failure.localizedDescription)
        XCTAssertEqual(final.reused, 0)
        XCTAssertEqual(final.cloudSkipped, 0)
        assertSources(final)
        let retained = try await context.store.record(id: "legacy")
        XCTAssertEqual(retained?.photo.modelVersion, oldVersion)
        XCTAssertEqual(retained?.photo.imageEmbedding, old.imageEmbedding)
        XCTAssertEqual(retained?.photo.location?.vector, place.vector)
        let beforeSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertTrue(beforeSearch.hits.isEmpty)

        context.library.replace([WorkerTestRecord("legacy", .preview(try WorkerPreviewFactory.make(.localReducedPreview)),
                                                  label: "Retained Place")])
        let retryTrace = WorkerProgressTrace()
        let retried = try await context.worker.index(networkAllowed: false) { await retryTrace.append($0) }
        let retryFinal = try await retryTrace.last()
        XCTAssertEqual(retried.indexedCount, 1)
        XCTAssertEqual(retried.locatedCount, 1)
        XCTAssertEqual(retryFinal.encoded, 1)
        XCTAssertEqual(retryFinal.reused, 0)
        XCTAssertEqual(retryFinal.failed, 0)
        XCTAssertNil(retryFinal.lastFailure)
        assertSources(retryFinal, reduced: 1)
        let replaced = try await context.store.record(id: "legacy")
        XCTAssertEqual(replaced?.photo.modelVersion, cacheVersion)
        XCTAssertEqual(replaced?.photo.imageEmbedding, TestFixtures.vector())
        XCTAssertEqual(replaced?.photo.location?.vector, TestFixtures.vector(axis: 2))
        XCTAssertEqual(context.library.requests.map(\.id), ["legacy", "legacy"])
        XCTAssertTrue(context.library.requests.allSatisfy { !$0.networkAllowed })
        let afterSearch = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(afterSearch.hits.map(\.id), ["legacy"])
    }

    func testFailedUpgradeKeepsOldRowButNeverReusesOrSearchesItsVector() async throws {
        let context = try makeWorker([
            WorkerTestRecord("original", .networkOnly(try WorkerPreviewFactory.make(.networkPreview)))
        ])
        try await seed(context, id: "original", model: "test-model", label: "Old Place")
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertEqual(final.reused, 0)
        XCTAssertEqual(final.cloudSkipped, 1)
        assertSources(final)
        let retained = try await context.store.record(id: "original")
        XCTAssertEqual(retained?.photo.modelVersion, "test-model")
        let search = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertTrue(search.hits.isEmpty)
        XCTAssertEqual(search.summary.indexedCount, 0)
        XCTAssertEqual(search.summary.locatedCount, 0)
        let retried = WorkerProgressTrace()
        let upgraded = try await context.worker.index(networkAllowed: true) { await retried.append($0) }
        let upgradedProgress = try await retried.last()
        XCTAssertEqual(upgraded.indexedCount, 1)
        XCTAssertEqual(upgradedProgress.reused, 0)
        assertSources(upgradedProgress, network: 1)
        let row = try await context.store.record(id: "original")
        XCTAssertEqual(row?.photo.modelVersion, cacheVersion)
        XCTAssertEqual(row?.photo.imageEmbedding, TestFixtures.vector())
    }

    func testPlaceRowsAndWithinRunMemoryUsePreviewCacheVersion() async throws {
        let preview = try WorkerPreviewFactory.make(.localPreview)
        let context = try makeWorker([
            WorkerTestRecord("a", .preview(preview), label: "Test Place"),
            WorkerTestRecord("b", .preview(preview), label: "Test Place")
        ])
        let text = "Photo taken in Test Place."
        try await seed(context, id: "a", model: "test-model", label: "Test Place")
        let summary = try await context.worker.index(networkAllowed: false) { _ in }
        XCTAssertEqual(summary.locatedCount, 2)
        let firstTexts = await context.encoders.texts
        XCTAssertEqual(firstTexts, [text], "The second photo must reuse the within-run place vector.")
        let active = try await context.store.place(text: text, modelVersion: cacheVersion)
        let legacy = try await context.store.place(text: text, modelVersion: "test-model")
        XCTAssertEqual(active, TestFixtures.vector(axis: 2), "Do not read the legacy place vector at axis 1.")
        XCTAssertNil(legacy)
        context.library.replace([
            WorkerTestRecord("a", .preview(preview), label: "Test Place"),
            WorkerTestRecord("b", .preview(preview), revision: 124, label: "Test Place"),
            WorkerTestRecord("c", .preview(preview), label: "Test Place")
        ])
        let progress = WorkerProgressTrace()
        let second = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(second.locatedCount, 3)
        XCTAssertEqual(final.reused, 1)
        assertSources(final, local: 2)
        let secondTexts = await context.encoders.texts
        XCTAssertEqual(secondTexts, [text], "After reconcile clears memory, use the versioned SQLite place row.")
        let rows = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertTrue(rows.allSatisfy { $0.photo.location?.vector == TestFixtures.vector(axis: 2) })
    }

    func testGeographyOnlyRefreshReusesImageWithoutCountingItsSourceAgain() async throws {
        let context = try makeWorker([WorkerTestRecord("asset", .cloudOnly, label: "New Place")])
        try await seed(context, id: "asset", model: cacheVersion, geography: "old-boundaries", label: "Old Place")
        let before = try await context.worker.refresh()
        XCTAssertEqual(before.indexedCount, 1)
        XCTAssertEqual(before.locatedCount, 0)
        let progress = WorkerProgressTrace()
        let summary = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
        let final = try await progress.last()
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(final.reused, 1)
        XCTAssertEqual(final.cloudSkipped, 0)
        assertSources(final)
        XCTAssertTrue(context.library.requests.isEmpty)
        let saved = try await context.store.record(id: "asset")
        XCTAssertEqual(saved?.geographyVersion, resolver.version)
        XCTAssertEqual(saved?.photo.imageEmbedding, TestFixtures.vector(axis: 1))
        XCTAssertEqual(saved?.photo.location?.text, "Photo taken in New Place.")
    }

    func testCancellationDuringEncodingPreservesCompletedRowsAndResumesByReuse() async throws {
        let started = expectation(description: "Second preview reached encoder")
        let encoders = try WorkerTestEncoders(holdPreviewCall: 2, started: started)
        let context = try makeWorker([
            WorkerTestRecord("completed", .preview(try WorkerPreviewFactory.make(.localPreview))),
            WorkerTestRecord("interrupted", .preview(try WorkerPreviewFactory.make(.localReducedPreview)))
        ], encoders: encoders)
        let worker = context.worker
        let progress = WorkerProgressTrace()
        let task = Task { try await worker.index(networkAllowed: false) { await progress.append($0) } }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await encoders.release()
        do { _ = try await task.value; XCTFail("Expected cancellation despite a late encoder success.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(saved.map(\.photo.id), ["completed"])
        let final = try await progress.last()
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 0)
        assertSources(final, local: 1)
        let refreshed = try await worker.refresh()
        XCTAssertEqual(refreshed.indexedCount, 1)
        let resumed = WorkerProgressTrace()
        let summary = try await worker.index(networkAllowed: false) { await resumed.append($0) }
        let resumedProgress = try await resumed.last()
        XCTAssertEqual(summary.indexedCount, 2)
        XCTAssertEqual(resumedProgress.completed, 2)
        XCTAssertEqual(resumedProgress.reused, 1)
        assertSources(resumedProgress, reduced: 1)
        XCTAssertEqual(context.library.requests.map(\.id), ["completed", "interrupted", "interrupted"])
    }

    func testAccessRemovedDuringEncodingDoesNotSaveOrCountPreview() async throws {
        let started = expectation(description: "Preview reached encoder")
        let encoders = try WorkerTestEncoders(holdPreviewCall: 1, started: started)
        let context = try makeWorker([
            WorkerTestRecord("removed", .preview(try WorkerPreviewFactory.make(.localReducedPreview)))
        ], encoders: encoders)
        let worker = context.worker
        let progress = WorkerProgressTrace()
        let task = Task { try await worker.index(networkAllowed: false) { await progress.append($0) } }
        await fulfillment(of: [started], timeout: 3)
        context.library.replace([])
        await encoders.release()
        let summary = try await task.value
        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 0)
        let final = try await progress.last()
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 1)
        assertSources(final)
        let row = try await context.store.record(id: "removed")
        XCTAssertNil(row)
    }

    func testSaveFailureDoesNotPublishAnEncodedOrSourceCount() async throws {
        let context = try makeWorker([
            WorkerTestRecord("invalid-metadata", .preview(try WorkerPreviewFactory.make(.localPreview)),
                             creationTime: .infinity)
        ])
        let progress = WorkerProgressTrace()
        do {
            _ = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
            XCTFail("The actual SQLite store must reject nonfinite metadata.")
        } catch AppFailure.storage { }
        catch { XCTFail("Unexpected failure: \(error)") }
        let final = try await progress.last()
        XCTAssertEqual(final.completed, 0)
        assertSources(final)
        let row = try await context.store.record(id: "invalid-metadata")
        XCTAssertNil(row)
    }

    func testCompleteAuthorizationSnapshotPrunesRemovedAndModifiedRowsAndPlaces() async throws {
        let preview = try WorkerPreviewFactory.make(.localPreview)
        let context = try makeWorker([
            WorkerTestRecord("kept", .preview(preview), label: "Kept Place"),
            WorkerTestRecord("removed", .preview(preview), label: "Removed Place"),
            WorkerTestRecord("modified", .preview(preview), label: "Modified Place")
        ])
        _ = try await context.worker.index(networkAllowed: false) { _ in }
        context.library.replace([
            WorkerTestRecord("kept", .preview(preview), label: "Kept Place"),
            WorkerTestRecord("modified", .preview(preview), revision: 124, label: "Modified Place")
        ])
        let summary = try await context.worker.refresh()
        XCTAssertEqual(summary.authorizedCount, 2)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        let rows = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(rows.map(\.photo.id), ["kept"])
        for label in ["Removed Place", "Modified Place"] {
            let place = try await context.store.place(text: "Photo taken in \(label).", modelVersion: cacheVersion)
            XCTAssertNil(place)
        }
        let search = try await context.worker.search(text: "query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(search.hits.map(\.id), ["kept"])
        context.library.setReadable(false)
        let revoked = try await context.worker.refresh()
        XCTAssertEqual(revoked.authorizedCount, 0)
        XCTAssertEqual(revoked.indexedCount, 0)
        let remaining = try await context.store.records(modelVersion: cacheVersion)
        let place = try await context.store.place(text: "Photo taken in Kept Place.", modelVersion: cacheVersion)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(place)
    }

    func testIndexAndSearchUseInjectedReadPermission() async throws {
        let context = try makeWorker([])
        context.library.setReadable(false)
        do {
            _ = try await context.worker.index(networkAllowed: false) { _ in }
            XCTFail("Indexing must use the injected permission flag.")
        } catch AppFailure.permission { }
        catch { XCTFail("Unexpected failure: \(error)") }
        do {
            _ = try await context.worker.search(text: "query", limit: 3, locationWeight: 0.6)
            XCTFail("Search must use the injected permission flag.")
        } catch AppFailure.permission { }
        catch { XCTFail("Unexpected failure: \(error)") }
        XCTAssertTrue(context.library.requests.isEmpty)
    }

    func testFailedEnumerationDoesNotPruneCompletedRecords() async throws {
        let context = try makeWorker([WorkerTestRecord("kept", .cloudOnly)])
        try await seed(context, id: "kept", model: cacheVersion, label: "Kept Place")
        context.library.failEnumeration(AppFailure.photo("Incomplete enumeration"))
        do { _ = try await context.worker.refresh(); XCTFail("Expected enumeration failure.") }
        catch AppFailure.photo { }
        catch { XCTFail("Unexpected failure: \(error)") }
        let row = try await context.store.record(id: "kept")
        let place = try await context.store.place(text: "Photo taken in Kept Place.", modelVersion: cacheVersion)
        XCTAssertNotNil(row)
        XCTAssertNotNil(place)
    }

    func testCancelledEnumerationDoesNotPruneCompletedRecords() async throws {
        let context = try makeWorker([WorkerTestRecord("kept", .cloudOnly)])
        try await seed(context, id: "kept", model: cacheVersion, label: "Kept Place")
        context.library.cancelNextEnumeration()
        let worker = context.worker
        let task = Task { try await worker.refresh() }
        do { _ = try await task.value; XCTFail("Cancelled empty snapshot must not be reconciled.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let row = try await context.store.record(id: "kept")
        let place = try await context.store.place(text: "Photo taken in Kept Place.", modelVersion: cacheVersion)
        XCTAssertNotNil(row)
        XCTAssertNotNil(place)
    }

    func testModelFailuresStillAbortRatherThanBecomingUnavailablePhotos() async throws {
        let failures: [AppFailure] = [.modelContract("Synthetic mismatch"), .modelsMissing("Synthetic missing model")]
        for failure in failures {
            let encoders = try WorkerTestEncoders(imageFailure: failure)
            let context = try makeWorker([
                WorkerTestRecord("asset", .preview(try WorkerPreviewFactory.make(.localPreview)))
            ], encoders: encoders)
            let progress = WorkerProgressTrace()
            do {
                _ = try await context.worker.index(networkAllowed: false) { await progress.append($0) }
                XCTFail("Model failures must abort the index run.")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            let final = try await progress.last()
            XCTAssertEqual(final.completed, 0)
            XCTAssertEqual(final.failed, 0)
            assertSources(final)
        }
    }

    func testProgressSummaryAppendsSourcesAfterExistingTotals() {
        let progress = IndexProgress(total: 10, completed: 10, encoded: 3, reused: 2, cloudSkipped: 4, failed: 1,
                                     localPreviews: 1, reducedPreviews: 1, networkPreviews: 1)
        XCTAssertEqual(progress.summary,
                       "10/10 checked · 3 encoded · 2 reused · 4 need network · 1 unavailable · 1 local previews · 1 reduced previews · 1 online-fallback previews")
        XCTAssertEqual(progress.fraction, 1)
        assertSources(IndexProgress())
    }
}

private struct WorkerTestContext {
    let worker: PhotoIndexWorker
    let library: WorkerTestLibrary
    let encoders: WorkerTestEncoders
    let store: SQLitePhotoStore
    let directory: URL
}

private enum WorkerPreviewFactory {
    static func make(_ source: IndexingImage.Source, orientation: CGImagePropertyOrientation = .right) throws -> IndexingImage {
        let pixels = try TestFixtures.image(width: 3, height: 2) { x, y in
            (UInt8(30 + x * 40), UInt8(50 + y * 60), 170)
        }
        return IndexingImage(cgImage: pixels, orientation: orientation, source: source)
    }
}

private struct WorkerTestRecord: Sendable {
    enum Response: Sendable {
        case preview(IndexingImage)
        case networkOnly(IndexingImage)
        case cloudOnly
        case failure(NSError)
    }

    let revision: PhotoRevision
    let response: Response
    let label: String?

    init(_ id: String, _ response: Response, revision: Double = 123, creationTime: Double? = 100, label: String? = nil) {
        self.revision = PhotoRevision(id: id, modificationTime: revision, creationTime: creationTime)
        self.response = response
        self.label = label
    }
}

/// Implements ONLY the production indexing protocol, not PhotoLibraryClient or
/// any original-data surface. Synchronous snapshot/access methods share one lock.
private final class WorkerTestLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    struct Request: Sendable {
        let id: String
        let networkAllowed: Bool
    }

    private let lock = NSLock()
    private var records: [WorkerTestRecord]
    private var readable = true
    private var history: [Request] = []
    private var enumerationError: Error?
    private var cancelEnumeration = false

    init(_ records: [WorkerTestRecord]) { self.records = records }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var canReadImages: Bool { locked { readable } }
    var requests: [Request] { locked { history } }
    func replace(_ records: [WorkerTestRecord]) { locked { self.records = records } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func failEnumeration(_ error: Error) { locked { enumerationError = error } }
    func cancelNextEnumeration() { locked { cancelEnumeration = true } }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try locked {
            if let enumerationError { throw enumerationError }
            if cancelEnumeration {
                cancelEnumeration = false
                withUnsafeCurrentTask { $0?.cancel() }
                return []
            }
            return readable ? records.map(\.revision) : []
        }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        locked { readable ? records.first { $0.revision.id == id }?.revision : nil }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        // Labels are injected independently of optional bundled geography, never GPS.
        locked { readable ? records.first { $0.revision.id == id }?.label : nil }
    }

    private func response(id: String, networkAllowed: Bool) throws -> WorkerTestRecord.Response {
        try locked {
            history.append(Request(id: id, networkAllowed: networkAllowed))
            guard readable, let record = records.first(where: { $0.revision.id == id }) else { throw AppFailure.permission }
            return record.response
        }
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        switch try response(id: id, networkAllowed: networkAllowed) {
        case .preview(let preview): return preview
        case .networkOnly(let preview):
            guard networkAllowed else { throw NSError(domain: PHPhotosErrorDomain, code: 3164) }
            return preview
        case .cloudOnly: throw AppFailure.cloudOnly
        case .failure(let error): throw error
        }
    }
}

private actor WorkerProgressTrace {
    private(set) var states: [IndexProgress] = []
    func append(_ state: IndexProgress) { states.append(state) }
    func last() throws -> IndexProgress { try XCTUnwrap(states.last) }
}

private actor WorkerEncoderLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// Unit vectors are synthetic TEST ONLY. The held prediction intentionally returns
/// after cancellation, so the real worker must reject it before saving/counting it.
private actor WorkerTestEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let imageFailure: AppFailure?
    private let holdPreviewCall: Int?
    private let started: XCTestExpectation?
    private let latch = WorkerEncoderLatch()
    private(set) var previews: [IndexingImage] = []
    private(set) var texts: [String] = []
    private(set) var dataCalls = 0

    init(imageFailure: AppFailure? = nil, holdPreviewCall: Int? = nil, started: XCTestExpectation? = nil) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        self.imageFailure = imageFailure
        self.holdPreviewCall = holdPreviewCall
        self.started = started
    }

    func prepare() throws -> ModelManifest {
        try manifest.validate()
        return manifest
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        dataCalls += 1
        XCTFail("PhotoIndexWorker must never use the original-data encoder overload.")
        throw AppFailure.modelContract("Unexpected original-data encoding")
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        previews.append(preview)
        if previews.count == holdPreviewCall {
            started?.fulfill()
            await latch.wait()
        }
        if let imageFailure { throw imageFailure }
        return TestFixtures.vector()
    }

    func text(_ text: String) throws -> [Float] {
        texts.append(text)
        return TestFixtures.vector(axis: text.hasPrefix("Photo taken in ") ? 2 : 0)
    }

    func release() async { await latch.open() }
}