import Foundation
import ImageIO
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real read-only SQLite search; all metadata, permissions and encoders below
/// are test-owned. No PhotoKit calls, model resources, images or network access.
final class FilteredSimilarSearchTests: XCTestCase {
    private let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic boundaries.")
    private let missingSeedMessage = "照片尚无可用索引，请先更新索引"

    private func row(_ id: String, axis: Int = 0, creation: Double? = 100,
                     revision: Double = 123, model: String? = nil,
                     place: PlaceEmbedding? = nil, geography: String? = nil,
                     vector: [Float]? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision,
                                        modelVersion: model ?? cacheVersion,
                                        imageEmbedding: vector ?? TestFixtures.vector(axis: axis),
                                        location: place, creationTime: creation),
                    geographyVersion: geography ?? resolver.version)
    }

    private func context(_ assets: [FilteredAsset], rows: [CachedPhoto]? = nil,
                         generation: UInt64? = 0, injectFiltering: Bool = true,
                         libraryFiltering: Bool = false, seedDatabase: Bool = true,
                         query: [Float] = TestFixtures.vector()) throws -> FilteredContext {
        let directory = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        if seedDatabase {
            try TestFixtures.seedRawCache(rows ?? assets.map { row($0.revision.id) }, directory: directory)
        }
        let metadata = FilteredMetadata(assets)
        let library: FilteredLibrary
        if libraryFiltering {
            library = FilteringLibrary(assets, generation: generation, metadata: metadata)
        } else { library = FilteredLibrary(assets, generation: generation) }
        let encoders = try FilteredEncoders(query: query)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: resolver, filtering: injectFiltering ? metadata : nil)
        return FilteredContext(worker: worker, library: library, metadata: metadata,
                               encoders: encoders, directory: directory)
    }

    private func disk(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func assertSameHits(_ actual: [SearchHit], _ expected: [SearchHit],
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern },
                       "Filtering must preserve Float score bits, not just approximate order.", file: file, line: line)
    }

    private func assertPhotoFailure(_ operation: () async throws -> SearchResponse, message: String? = nil,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected an explicit photo error.", file: file, line: line) }
        catch AppFailure.photo(let actual) {
            if let message { XCTAssertEqual(actual, message, file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    private func assertNoPixels(_ c: FilteredContext, textCalls: Int,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.texts.count, textCalls, file: file, line: line)
        XCTAssertEqual(calls.images, 0, file: file, line: line)
        XCTAssertEqual(calls.originals, 0, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
        XCTAssertEqual(c.library.placeCalls, 0, file: file, line: line)
    }

    func testEmptyFiltersExactlyPreserveLegacyHitsAndAvoidMetadataFetches() async throws {
        let c = try context([FilteredAsset("a"), FilteredAsset("b")], rows: [row("a"), row("b", axis: 1)])
        let before = try disk(c.directory)
        let old = try await c.worker.search(text: "query", limit: 1, locationWeight: 0.6)
        let service: any PhotoWorkServicing = c.worker
        let empty = try await service.search(text: "query", limit: 1, locationWeight: 0.6, filters: .init())
        assertSameHits(empty.hits, old.hits)
        XCTAssertEqual(c.metadata.callCount, 0)
        XCTAssertEqual(c.library.enumerationCount, 6)
        XCTAssertEqual(empty.summary.indexedCount, old.summary.indexedCount)
        try empty.validateAccess()
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoPixels(c, textCalls: 2)
    }

    func testLegacyServiceDefaultForwardsEmptyFiltersWithExactArguments() async throws {
        let legacy = FilteredLegacyService()
        let service: any PhotoWorkServicing = legacy
        _ = try await service.search(text: "unchanged", limit: -7, locationWeight: 0.37, filters: .init())
        let requests = await legacy.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.text, "unchanged")
        XCTAssertEqual(requests.first?.limit, -7)
        XCTAssertEqual(requests.first?.weight, 0.37)
    }

    func testLegacyServiceDefaultsExplicitlyRejectFilteringAndSimilarity() async throws {
        let legacy = FilteredLegacyService()
        let service: any PhotoWorkServicing = legacy
        await assertPhotoFailure {
            try await service.search(text: "query", limit: 1, locationWeight: 0,
                                     filters: .init(imageKind: .screenshots))
        }
        await assertPhotoFailure { try await service.searchSimilar(photoID: "seed", limit: 1, filters: .init()) }
        let requests = await legacy.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testInvalidRangesAndAlbumIDsFailBeforeAnySearchWork() async throws {
        let c = try context([FilteredAsset("seed")])
        let legacy = FilteredLegacyService()
        let invalid: [(PhotoSearchFilters, PhotoSearchFilterError)] = [
            (.init(startDate: Date(timeIntervalSince1970: 2), endDateExclusive: Date(timeIntervalSince1970: 1)), .invalidDateRange),
            (.init(startDate: Date(timeIntervalSince1970: 1), endDateExclusive: Date(timeIntervalSince1970: 1)), .invalidDateRange),
            (.init(startDate: Date(timeIntervalSinceReferenceDate: .infinity)), .invalidDateRange),
            (.init(endDateExclusive: Date(timeIntervalSinceReferenceDate: .nan)), .invalidDateRange),
            (.init(albumID: " \n "), .invalidAlbumID)
        ]
        for (filters, expected) in invalid {
            for mode in 0..<3 {
                do {
                    if mode == 0 {
                        _ = try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: filters)
                    } else if mode == 1 {
                        _ = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: filters)
                    } else {
                        _ = try await legacy.search(text: "query", limit: 1, locationWeight: 0, filters: filters)
                    }
                    XCTFail("Invalid filters must fail.")
                } catch { XCTAssertEqual(error as? PhotoSearchFilterError, expected) }
            }
        }
        XCTAssertEqual(c.library.enumerationCount, 0)
        XCTAssertEqual(c.metadata.callCount, 0)
        let requests = await legacy.requests
        XCTAssertTrue(requests.isEmpty)
        await assertNoPixels(c, textCalls: 0)
    }

    func testWorkerWithoutFilteringSupportsOnlyEmptyFilters() async throws {
        let c = try context([FilteredAsset("seed"), FilteredAsset("other")], injectFiltering: false)
        _ = try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init())
        let similar = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
        XCTAssertEqual(similar.hits.map(\.id), ["other"])
        await assertPhotoFailure {
            try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(imageKind: .photos))
        }
        await assertPhotoFailure {
            try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init(imageKind: .photos))
        }
        XCTAssertEqual(c.metadata.callCount, 0)
        await assertNoPixels(c, textCalls: 1)
    }

    func testLibraryFilteringFallbackAndExplicitInjectionPrecedence() async throws {
        let c = try context([FilteredAsset("photo"), FilteredAsset("screen", screenshot: true)],
                            injectFiltering: false, libraryFiltering: true)
        let fallback = try await c.worker.search(text: "query", limit: 9, locationWeight: 0,
                                                filters: .init(imageKind: .screenshots))
        XCTAssertEqual(fallback.hits.map(\.id), ["screen"])
        XCTAssertEqual(c.metadata.callCount, 1)
        let override = FilteredMetadata([FilteredAsset("photo", screenshot: true)])
        let worker = PhotoIndexWorker(library: c.library, encoders: c.encoders, directory: c.directory,
                                      resolver: resolver, filtering: override)
        let explicit = try await worker.search(text: "query", limit: 9, locationWeight: 0,
                                               filters: .init(imageKind: .screenshots))
        XCTAssertEqual(explicit.hits.map(\.id), ["photo"])
        XCTAssertEqual(override.callCount, 1)
        XCTAssertEqual(c.metadata.callCount, 1, "Explicit filtering must override library conformance.")
    }

    func testDateBoundsAreHalfOpenAndMissingDatesAreExcludedOnlyWithBounds() async throws {
        let c = try context([FilteredAsset("before", creation: 99), FilteredAsset("start", creation: 100),
                             FilteredAsset("inside", creation: 199.5), FilteredAsset("end", creation: 200),
                             FilteredAsset("missing", creation: nil)])
        let filters = PhotoSearchFilters(startDate: Date(timeIntervalSince1970: 100),
                                         endDateExclusive: Date(timeIntervalSince1970: 200))
        let bounded = try await c.worker.search(text: "query", limit: 99, locationWeight: 0, filters: filters)
        XCTAssertEqual(Set(bounded.hits.map(\.id)), Set(["start", "inside"]))
        let openStart = try await c.worker.search(text: "query", limit: 99, locationWeight: 0,
                                                  filters: .init(endDateExclusive: filters.endDateExclusive))
        XCTAssertEqual(Set(openStart.hits.map(\.id)), Set(["before", "start", "inside"]))
        let openEnd = try await c.worker.search(text: "query", limit: 99, locationWeight: 0,
                                                filters: .init(startDate: filters.startDate))
        XCTAssertEqual(Set(openEnd.hits.map(\.id)), Set(["start", "inside", "end"]))
        let kindOnly = try await c.worker.search(text: "query", limit: 99, locationWeight: 0,
                                                 filters: .init(imageKind: .photos))
        XCTAssertEqual(kindOnly.hits.count, 5)
    }

    func testCalendarDayUsesNextMidnightAcrossDSTNotFixedSeconds() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let c = try context([FilteredAsset("midnight", creation: start.timeIntervalSince1970),
                             FilteredAsset("last", creation: end.timeIntervalSince1970 - 0.5),
                             FilteredAsset("next-day", creation: end.timeIntervalSince1970)])
        let response = try await c.worker.search(text: "day", limit: 99, locationWeight: 0,
                                                 filters: .init(startDate: start, endDateExclusive: end))
        XCTAssertEqual(Set(response.hits.map(\.id)), Set(["midnight", "last"]))
    }

    func testAllOrdinaryScreenshotAndLiveKindsRespectIndependentFlags() async throws {
        let c = try context([FilteredAsset("ordinary"), FilteredAsset("screen", screenshot: true),
                             FilteredAsset("live", live: true), FilteredAsset("both", screenshot: true, live: true)])
        let expected: [(PhotoSearchImageKind, Set<String>)] = [
            (.all, ["ordinary", "screen", "live", "both"]), (.photos, ["ordinary"]),
            (.screenshots, ["screen", "both"]), (.livePhotos, ["live", "both"])
        ]
        for (kind, ids) in expected {
            let result = try await c.worker.search(text: "kind", limit: 99, locationWeight: 0,
                                                   filters: .init(imageKind: kind))
            XCTAssertEqual(Set(result.hits.map(\.id)), ids)
        }
        XCTAssertEqual(c.metadata.callCount, 3, "The all/no-date/no-album filter performs no metadata fetch.")
    }

    func testAlbumDateAndKindIntersectCurrentAccessibleImages() async throws {
        let c = try context([FilteredAsset("match", creation: 100, screenshot: true),
                             FilteredAsset("wrong-kind", creation: 100),
                             FilteredAsset("wrong-date", creation: 200, screenshot: true),
                             FilteredAsset("wrong-album", creation: 100, screenshot: true),
                             FilteredAsset("not-indexed", creation: 100, screenshot: true)],
                            rows: [row("match"), row("wrong-kind"), row("wrong-date"), row("wrong-album"), row("hidden")])
        c.metadata.setAlbum("chosen", ids: ["match", "wrong-kind", "wrong-date", "not-indexed", "hidden"])
        let filters = PhotoSearchFilters(startDate: Date(timeIntervalSince1970: 100),
                                         endDateExclusive: Date(timeIntervalSince1970: 200),
                                         albumID: "chosen", imageKind: .screenshots)
        let response = try await c.worker.search(text: "query", limit: 99, locationWeight: 0, filters: filters)
        XCTAssertEqual(response.hits.map(\.id), ["match"])
        XCTAssertEqual(response.summary.authorizedCount, 5)
        XCTAssertEqual(response.summary.indexedCount, 5)
        XCTAssertEqual(c.metadata.snapshots.first?.count, 5, "Pass the complete access snapshot, including unindexed IDs.")
    }

    func testDeletedOrMissingAlbumThrowsEvenWithNoHitsOrZeroLimit() async throws {
        let c = try context([FilteredAsset("seed"), FilteredAsset("other")])
        c.metadata.setAlbum("gone", ids: ["seed", "other"])
        c.metadata.removeAlbum("gone")
        let before = try disk(c.directory)
        for limit in [0, 10] {
            await assertPhotoFailure {
                try await c.worker.search(text: "query", limit: limit, locationWeight: 0, filters: .init(albumID: "gone"))
            }
            await assertPhotoFailure {
                try await c.worker.searchSimilar(photoID: "seed", limit: limit, filters: .init(albumID: "gone"))
            }
        }
        let empty = try context([], rows: [])
        await assertPhotoFailure {
            try await empty.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(albumID: "gone"))
        }
        XCTAssertEqual(try disk(c.directory), before)
    }

    func testExistingEmptyAlbumReturnsEmptyAndDoesNotMeanAllAlbums() async throws {
        let c = try context([FilteredAsset("seed"), FilteredAsset("other")])
        c.metadata.setAlbum("empty", ids: [])
        let text = try await c.worker.search(text: "query", limit: 10, locationWeight: 0, filters: .init(albumID: "empty"))
        let image = try await c.worker.searchSimilar(photoID: "seed", limit: 10, filters: .init(albumID: "empty"))
        XCTAssertTrue(text.hits.isEmpty)
        XCTAssertTrue(image.hits.isEmpty)
        let all = try await c.worker.search(text: "query", limit: 10, locationWeight: 0, filters: .init())
        XCTAssertEqual(all.hits.count, 2)
        XCTAssertEqual(c.metadata.callCount, 2)
    }

    func testCurrentCreationDateFiltersWithoutRewritingStoredDateOrVisual() async throws {
        let c = try context([FilteredAsset("now-inside", creation: 150, revision: 124),
                             FilteredAsset("now-outside", creation: 300, revision: 124)],
                            rows: [row("now-inside", axis: 1, creation: 300), row("now-outside", creation: 150)])
        let before = try disk(c.directory)
        let result = try await c.worker.search(text: "query", limit: 10, locationWeight: 0,
                                               filters: .init(startDate: Date(timeIntervalSince1970: 100),
                                                              endDateExclusive: Date(timeIntervalSince1970: 200)))
        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(result.hits.map(\.id), ["now-inside"])
        XCTAssertEqual(hit.photo.creationTime, 300)
        XCTAssertEqual(hit.photo.modificationTime, 123)
        XCTAssertEqual(hit.photo.imageEmbedding, TestFixtures.vector(axis: 1))
        try result.validateAccess() // The validator uses current revision 124, not stored 123.
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoPixels(c, textCalls: 1)
    }

    func testFiltersPreserveGlobalDistinctPlaceCenterAndExactScoreBits() async throws {
        let placeA = PlaceEmbedding(text: "A", vector: TestFixtures.vector())
        let placeB = PlaceEmbedding(text: "B", vector: TestFixtures.vector(axis: 1))
        let rows = [row("keep-a", axis: 1, place: placeA), row("keep-duplicate", axis: 1, place: placeA),
                    row("keep-unlocated"), row("drop-b", place: placeB)]
        let c = try context(rows.map { FilteredAsset($0.photo.id) }, rows: rows)
        c.metadata.setAlbum("subset", ids: ["keep-a", "keep-duplicate", "keep-unlocated"])
        for weight in [Float(0), 0.6, 1] {
            let full = try await c.worker.search(text: "query", limit: Int.max, locationWeight: weight)
            let subset = try await c.worker.search(text: "query", limit: Int.max, locationWeight: weight,
                                                   filters: .init(albumID: "subset"))
            assertSameHits(subset.hits, full.hits.filter { $0.id != "drop-b" })
            let limited = try await c.worker.search(text: "query", limit: 1, locationWeight: weight,
                                                    filters: .init(albumID: "subset"))
            assertSameHits(limited.hits, Array(subset.hits.prefix(1)))
            if weight == 1 {
                XCTAssertEqual(subset.hits.first?.score, 0.5, "Duplicate A contributes once; excluded B still centers scores.")
                let incorrectlyCentered = try VectorSearch.search(query: TestFixtures.vector(),
                    photos: rows.filter { $0.photo.id != "drop-b" }.map(\.photo), limit: Int.max, locationWeight: weight)
                XCTAssertNotEqual(subset.hits.first?.score.bitPattern, incorrectlyCentered.first?.score.bitPattern)
            }
        }
    }

    func testMetadataFilteringPrecedesLimitRatherThanFilteringAlreadyTruncatedHits() async throws {
        let excluded = (0..<15).map { String(format: "a-excluded-%02d", $0) }
        let ids = excluded + ["z-allowed"]
        let c = try context(ids.map { FilteredAsset($0) }, rows: ids.map { row($0, axis: $0 == "z-allowed" ? 1 : 0) })
        c.metadata.setAlbum("allowed", ids: ["z-allowed"])
        let result = try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(albumID: "allowed"))
        XCTAssertEqual(result.hits.map(\.id), ["z-allowed"])
        XCTAssertEqual(result.hits.first?.score, 0)
    }

    func testInaccessibleCorruptRowsAreHiddenBeforeDecodeButFiltersCannotHideAccessibleCorruption() async throws {
        for corruptImage in [true, false] {
            let invalid = [Float](repeating: 0, count: 768)
            let badPlace = PlaceEmbedding(text: "hidden place", vector: corruptImage ? TestFixtures.vector() : invalid)
            let c = try context([FilteredAsset("seed"), FilteredAsset("visible")], rows: [
                row("seed"), row("visible"), row("hidden", place: badPlace,
                                                 vector: corruptImage ? invalid : TestFixtures.vector())
            ])
            c.metadata.setAlbum("visible", ids: ["visible"])
            let before = try disk(c.directory)
            let text = try await c.worker.search(text: "query", limit: 9, locationWeight: 0.6, filters: .init(albumID: "visible"))
            let similar = try await c.worker.searchSimilar(photoID: "seed", limit: 9, filters: .init(albumID: "visible"))
            XCTAssertEqual(text.hits.map(\.id), ["visible"])
            XCTAssertEqual(try XCTUnwrap(text.hits.first).score, 0.4, accuracy: 0.000001)
            XCTAssertEqual(similar.hits.map(\.id), ["visible"])
            XCTAssertEqual(text.summary.indexedCount, 3)
            c.library.replace([FilteredAsset("seed"), FilteredAsset("visible"), FilteredAsset("hidden", revision: 124)])
            for similarMode in [false, true] {
                do {
                    if similarMode {
                        _ = try await c.worker.searchSimilar(photoID: "seed", limit: 9, filters: .init(albumID: "visible"))
                    } else {
                        _ = try await c.worker.search(text: "query", limit: 9, locationWeight: 0, filters: .init(albumID: "visible"))
                    }
                    XCTFail("All accessible current-model rows must decode before applying metadata filters.")
                } catch AppFailure.modelContract { }
                catch { XCTFail("Unexpected corruption failure: \(error)") }
            }
            XCTAssertEqual(c.metadata.callCount, 2)
            XCTAssertEqual(try disk(c.directory), before)
        }
    }

    func testNegativeLimitsRetainCoreErrorsAndZeroLimitsStillValidateVectors() async throws {
        let c = try context([FilteredAsset("seed"), FilteredAsset("other")])
        for filters in [PhotoSearchFilters(), PhotoSearchFilters(imageKind: .photos)] {
            do {
                _ = try await c.worker.search(text: "query", limit: -1, locationWeight: 0, filters: filters)
                XCTFail("Expected Core's negative limit error.")
            } catch { XCTAssertEqual(error as? VectorSearchError, .negativeLimit) }
            do {
                _ = try await c.worker.searchSimilar(photoID: "seed", limit: -1, filters: filters)
                XCTFail("Expected Core's negative limit error.")
            } catch { XCTAssertEqual(error as? VectorSearchError, .negativeLimit) }
            do {
                _ = try await c.worker.search(text: "query", limit: -1, locationWeight: -1, filters: filters)
                XCTFail("Weight validation must retain precedence over the negative limit.")
            } catch { XCTAssertEqual(error as? VectorSearchError, .invalidLocationWeight) }
            let zero = try await c.worker.search(text: "query", limit: 0, locationWeight: 0, filters: filters)
            XCTAssertTrue(zero.hits.isEmpty)
        }
        // SQLite accepts legacy dimension 512, but it cannot score against this
        // current query/seed's 768 dimensions, even when no hits will be returned.
        let mismatch = try context([FilteredAsset("seed"), FilteredAsset("excluded")], rows: [
            row("seed"), row("excluded", vector: TestFixtures.vector(dimension: 512))
        ])
        mismatch.metadata.setAlbum("empty", ids: [])
        for similarMode in [false, true] {
            do {
                if similarMode {
                    _ = try await mismatch.worker.searchSimilar(photoID: "seed", limit: 0, filters: .init(albumID: "empty"))
                } else {
                    _ = try await mismatch.worker.search(text: "query", limit: 0, locationWeight: 0, filters: .init(albumID: "empty"))
                }
                XCTFail("Zero-limit filtered searches must still validate every accessible vector.")
            } catch { XCTAssertEqual(mismatch.metadata.callCount, 0) }
        }
        let badQuery = try context([FilteredAsset("photo")], query: [])
        do {
            _ = try await badQuery.worker.search(text: "query", limit: 0, locationWeight: 0, filters: .init(imageKind: .photos))
            XCTFail("Zero limit must not skip query validation.")
        } catch { XCTAssertEqual(badQuery.metadata.callCount, 0) }
    }

    func testNilGenerationLibrariesStillValidateFullSnapshotAtBothScoringBoundaries() async throws {
        for boundary in [2, 3] {
            for change in ["edit", "creation", "delete", "authorization", "deny"] {
                let c = try context([FilteredAsset("keep"), FilteredAsset("excluded")], generation: nil)
                c.metadata.setAlbum("keep", ids: ["keep"])
                let library = c.library
                library.onEnumeration(boundary) {
                    switch change {
                    case "edit": library.replace([FilteredAsset("keep"), FilteredAsset("excluded", revision: 124)])
                    case "creation": library.replace([FilteredAsset("keep"), FilteredAsset("excluded", creation: 101)])
                    case "delete": library.replace([FilteredAsset("keep")])
                    case "authorization": library.setAuthorization(4)
                    default: library.setReadable(false)
                    }
                }
                do {
                    _ = try await c.worker.search(text: "query", limit: 1,
                                                  locationWeight: boundary == 2 ? -1 : 0.6,
                                                  filters: .init(albumID: "keep"))
                    XCTFail("Excluded candidates still belong to the access/scoring snapshot.")
                } catch AppFailure.permission { XCTAssertEqual(change, "deny") }
                catch AppFailure.photo { XCTAssertNotEqual(change, "deny") }
                catch { XCTFail("Access checks must precede Core at boundary 2: \(error)") }
                XCTAssertEqual(library.enumerationCount, boundary)
            }
        }
    }

    func testGenerationOnlyChangesAtEitherBoundaryRejectUnchangedRevisionLists() async throws {
        for boundary in [2, 3] {
            let c = try context([FilteredAsset("seed"), FilteredAsset("other")])
            let library = c.library
            library.onEnumeration(boundary) { library.setGeneration(1) }
            await assertPhotoFailure {
                try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init(imageKind: .photos))
            }
            XCTAssertEqual(library.enumerationCount, boundary)
        }
    }

    func testCancellationInsideMetadataIsCheckedBeforePublishingEitherQueryKind() async throws {
        for similarMode in [false, true] {
            let c = try context([FilteredAsset("seed"), FilteredAsset("other")])
            let before = try disk(c.directory)
            c.metadata.afterMatch { withUnsafeCurrentTask { $0?.cancel() } }
            let task = Task {
                if similarMode {
                    return try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init(imageKind: .photos))
                }
                return try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(imageKind: .photos))
            }
            do { _ = try await task.value; XCTFail("Cancelled metadata results must not publish.") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(c.metadata.callCount, 1)
            XCTAssertEqual(try disk(c.directory), before)
            await assertNoPixels(c, textCalls: similarMode ? 0 : 1)
        }
    }

    func testMetadataMutationIsCaughtByPostFilterFullSnapshotCheck() async throws {
        let c = try context([FilteredAsset("keep"), FilteredAsset("excluded")], generation: nil)
        c.metadata.setAlbum("keep", ids: ["keep"])
        let library = c.library
        c.metadata.afterMatch { library.replace([FilteredAsset("keep"), FilteredAsset("excluded", revision: 124)]) }
        await assertPhotoFailure {
            try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(albumID: "keep"))
        }
        XCTAssertEqual(library.enumerationCount, 3)
    }

    func testSimilarityUsesEditedSeedsOldIndexedVisualAndNeverCallsEitherEncoder() async throws {
        let c = try context([FilteredAsset("seed", revision: 124), FilteredAsset("same"), FilteredAsset("different")],
                            rows: [row("seed", axis: 1), row("same", axis: 1), row("different")])
        let before = try disk(c.directory)
        let service: any PhotoWorkServicing = c.worker
        let result = try await service.searchSimilar(photoID: "seed", limit: 10, filters: .init())
        XCTAssertEqual(result.hits.map(\.id), ["same", "different"])
        XCTAssertEqual(result.hits.map(\.score), [1, 0])
        try result.validateAccess()
        XCTAssertEqual(c.metadata.callCount, 0)
        XCTAssertEqual(c.library.enumerationCount, 3)
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoPixels(c, textCalls: 0)
    }

    func testSeedOutsideDateKindAndAlbumFilterStillSuppliesQueryAndCannotConsumeLimit() async throws {
        let c = try context([FilteredAsset("00-seed", creation: 0),
                             FilteredAsset("allowed", creation: 150, screenshot: true),
                             FilteredAsset("excluded", creation: 150)])
        c.metadata.setAlbum("chosen", ids: ["allowed", "excluded"])
        let filters = PhotoSearchFilters(startDate: Date(timeIntervalSince1970: 100),
                                         endDateExclusive: Date(timeIntervalSince1970: 200),
                                         albumID: "chosen", imageKind: .screenshots)
        let result = try await c.worker.searchSimilar(photoID: "00-seed", limit: 1, filters: filters)
        XCTAssertEqual(result.hits.map(\.id), ["allowed"])
        XCTAssertEqual(result.hits.first?.score, 1)
        try result.validateAccess()
        XCTAssertTrue(c.library.revisionReads.contains("00-seed"))
        await assertNoPixels(c, textCalls: 0)
    }

    func testSameVectorSimilarityTiesUseDeterministicUTF8IDOrdering() async throws {
        let ids = ["z", "中", "a", "é", "A", "00-seed"]
        let c = try context(ids.map { FilteredAsset($0) })
        let expected = ids.filter { $0 != "00-seed" }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let full = try await c.worker.searchSimilar(photoID: "00-seed", limit: Int.max, filters: .init())
        XCTAssertEqual(full.hits.map(\.id), expected)
        XCTAssertTrue(full.hits.allSatisfy { $0.score.bitPattern == Float(1).bitPattern })
        let top = try await c.worker.searchSimilar(photoID: "00-seed", limit: 2, filters: .init())
        assertSameHits(top.hits, Array(full.hits.prefix(2)))
    }

    func testSimilarityPagesBeyondTwelveReuseOneRankingWithoutEncodingOrMetadataRefetch() async throws {
        let candidates = (0..<29).map { String(format: "candidate-%02d", $0) }
        let c = try context((["00-seed"] + candidates).map { FilteredAsset($0, screenshot: true) })
        let before = try disk(c.directory)
        let result = try await c.worker.searchSimilar(photoID: "00-seed", limit: Int.max,
                                                       filters: .init(imageKind: .screenshots))
        XCTAssertEqual(result.hits.map(\.id), candidates)
        for start in stride(from: 0, to: result.hits.count, by: 12) {
            let page = Array(result.hits[start..<min(start + 12, result.hits.count)])
            try result.validatePageAccess(page.map(\.id))
        }
        XCTAssertEqual(c.metadata.callCount, 1)
        XCTAssertEqual(c.library.enumerationCount, 3)
        let limited = try await c.worker.searchSimilar(photoID: "00-seed", limit: 12,
                                                        filters: .init(imageKind: .screenshots))
        assertSameHits(limited.hits, Array(result.hits.prefix(12)))
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoPixels(c, textCalls: 0)
    }

    func testSimilarityIsImageOnlyWithCurrentAndStaleGeography() async throws {
        let rows = [row("seed", place: PlaceEmbedding(text: "Seed place", vector: TestFixtures.vector())),
                    row("current", place: PlaceEmbedding(text: "Current", vector: TestFixtures.vector(axis: 1))),
                    row("stale", place: PlaceEmbedding(text: "Stale", vector: TestFixtures.vector()), geography: "old"),
                    row("other", axis: 1)]
        let c = try context(rows.map { FilteredAsset($0.photo.id) }, rows: rows)
        let response = try await c.worker.searchSimilar(photoID: "seed", limit: 99, filters: .init(imageKind: .photos))
        let expected = try VectorSearch.search(query: TestFixtures.vector(), photos: rows.map { cached in
            IndexedPhoto(id: cached.photo.id, modificationTime: 123, modelVersion: cacheVersion,
                         imageEmbedding: cached.photo.imageEmbedding, location: nil)
        }, limit: Int.max, locationWeight: 0).filter { $0.id != "seed" }
        assertSameHits(response.hits, expected)
        XCTAssertNil(response.hits.first { $0.id == "stale" }?.photo.location)
        await assertNoPixels(c, textCalls: 0)
    }

    func testMissingDeletedInaccessibleAndWrongModelSeedsUseGenericIndexError() async throws {
        let c = try context([FilteredAsset("no-row"), FilteredAsset("wrong-model"), FilteredAsset("candidate")], rows: [
            row("wrong-model", model: "old-model"), row("inaccessible"), row("candidate")
        ])
        let before = try disk(c.directory)
        for id in ["", "deleted", "inaccessible", "no-row", "wrong-model"] {
            await assertPhotoFailure({
                try await c.worker.searchSimilar(photoID: id, limit: 1, filters: .init())
            }, message: missingSeedMessage)
        }
        XCTAssertEqual(try disk(c.directory), before)
        await assertNoPixels(c, textCalls: 0)
    }

    func testInvalidSeedEmbeddingFailsWithoutReadingPixelsOrRebuildingIndex() async throws {
        for vector in [[Float](repeating: 0, count: 768), TestFixtures.vector(dimension: 512)] {
            let c = try context([FilteredAsset("seed")], rows: [row("seed", vector: vector)])
            let before = try disk(c.directory)
            do {
                _ = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
                XCTFail("Invalid cached seeds cannot be silently repaired or freshly encoded.")
            } catch AppFailure.modelContract { }
            catch { XCTFail("Unexpected failure: \(error)") }
            XCTAssertEqual(try disk(c.directory), before)
            await assertNoPixels(c, textCalls: 0)
        }
    }

    func testFirstPublicationValidatesFilteredOutSeedCurrentRevisionAndAccess() async throws {
        for change in ["edit", "delete", "creation"] {
            let c = try context([FilteredAsset("seed"), FilteredAsset("candidate", screenshot: true)], generation: nil)
            let result = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init(imageKind: .screenshots))
            switch change {
            case "edit": c.library.replace([FilteredAsset("seed", revision: 124), FilteredAsset("candidate", screenshot: true)])
            case "creation": c.library.replace([FilteredAsset("seed", creation: 101), FilteredAsset("candidate", screenshot: true)])
            default: c.library.replace([FilteredAsset("candidate", screenshot: true)])
            }
            XCTAssertThrowsError(try result.validateAccess())
            XCTAssertThrowsError(try result.validatePageAccess(["candidate"]))
        }
    }

    func testLaterPageAlwaysValidatesSeedEvenWhenNoCandidateIDsAreRequested() async throws {
        for deleted in [false, true] {
            let candidates = (0..<25).map { FilteredAsset(String(format: "page-%02d", $0), screenshot: true) }
            let c = try context([FilteredAsset("seed")] + candidates, generation: nil)
            let result = try await c.worker.searchSimilar(photoID: "seed", limit: Int.max, filters: .init(imageKind: .screenshots))
            try result.validatePageAccess(Array(result.hits.prefix(12)).map(\.id))
            c.library.replace(deleted ? candidates : [FilteredAsset("seed", revision: 124)] + candidates)
            XCTAssertThrowsError(try result.validatePageAccess(Array(result.hits[12..<24]).map(\.id)))
            XCTAssertThrowsError(try result.validatePageAccess([]))
        }
    }

    func testPageValidatorRejectsUnknownIDsSeedAsHitAndEditedRequestedCandidates() async throws {
        let c = try context([FilteredAsset("seed"), FilteredAsset("a"), FilteredAsset("b")], generation: nil)
        let result = try await c.worker.searchSimilar(photoID: "seed", limit: Int.max, filters: .init())
        XCTAssertThrowsError(try result.validatePageAccess(["unknown"]))
        XCTAssertThrowsError(try result.validatePageAccess(["seed"]))
        try result.validatePageAccess(["a"])
        c.library.replace([FilteredAsset("seed"), FilteredAsset("a"), FilteredAsset("b", revision: 124)])
        XCTAssertThrowsError(try result.validatePageAccess(["b"]))
    }

    func testPageGenerationIsCheckedBeforeAndAfterSeedAndCandidateReads() async throws {
        for changedID in ["before", "candidate", "seed"] {
            let c = try context([FilteredAsset("seed"), FilteredAsset("candidate")])
            let response = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
            let library = c.library
            if changedID == "before" { library.setGeneration(1) }
            else { library.afterRevisionRead(changedID) { library.setGeneration(1) } }
            XCTAssertThrowsError(try response.validatePageAccess(["candidate"]))
        }
    }

    func testPagePermissionIsCheckedBeforeAndAfterRevisionReads() async throws {
        for change in ["denied-before", "limited-before", "denied-after", "limited-after"] {
            let c = try context([FilteredAsset("seed"), FilteredAsset("candidate")])
            let result = try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
            let library = c.library
            let action: @Sendable () -> Void = {
                if change.hasPrefix("denied") { library.setReadable(false) }
                else { library.setAuthorization(4) }
            }
            if change.hasSuffix("before") { action() }
            else { library.afterRevisionRead("seed", action) }
            XCTAssertThrowsError(try result.validatePageAccess(["candidate"]))
        }
    }

    func testEmptySimilarResultsStillRetainSeedValidationDependency() async throws {
        let c = try context([FilteredAsset("seed")], generation: nil)
        c.metadata.setAlbum("empty", ids: [])
        let result = try await c.worker.searchSimilar(photoID: "seed", limit: 0, filters: .init(albumID: "empty"))
        XCTAssertTrue(result.hits.isEmpty)
        try result.validateAccess()
        try result.validatePageAccess([])
        c.library.replace([])
        XCTAssertThrowsError(try result.validateAccess())
        XCTAssertThrowsError(try result.validatePageAccess([]))
    }

    func testMissingDatabaseSearchNeverCreatesIndexFiles() async throws {
        let c = try context([FilteredAsset("seed")], seedDatabase: false)
        let before = try disk(c.directory)
        XCTAssertTrue(before.isEmpty)
        let text = try await c.worker.search(text: "query", limit: 1, locationWeight: 0, filters: .init(imageKind: .photos))
        XCTAssertTrue(text.hits.isEmpty)
        await assertPhotoFailure({
            try await c.worker.searchSimilar(photoID: "seed", limit: 1, filters: .init())
        }, message: missingSeedMessage)
        XCTAssertEqual(try disk(c.directory), before)
    }

    func testResponseOwnsLibraryValidationButNotWorkerOrEncoders() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try TestFixtures.seedRawCache([row("seed"), row("candidate")], directory: directory)
        let before = try disk(directory)
        var library: FilteredLibrary? = FilteredLibrary([FilteredAsset("seed"), FilteredAsset("candidate")], generation: nil)
        var encoders: FilteredEncoders? = try FilteredEncoders()
        var worker: PhotoIndexWorker? = PhotoIndexWorker(library: try XCTUnwrap(library), encoders: try XCTUnwrap(encoders),
                                                        directory: directory, resolver: resolver)
        weak var weakLibrary = library
        weak var weakWorker = worker
        weak var weakEncoders = encoders
        var response: SearchResponse? = try await worker?.searchSimilar(photoID: "seed", limit: 1, filters: .init())
        worker = nil
        encoders = nil
        library = nil
        XCTAssertNil(weakWorker)
        XCTAssertNil(weakEncoders)
        XCTAssertNotNil(weakLibrary)
        try XCTUnwrap(response).validatePageAccess(["candidate"])
        weakLibrary?.replace([FilteredAsset("candidate")])
        XCTAssertThrowsError(try XCTUnwrap(response).validatePageAccess(["candidate"]))
        response = nil
        XCTAssertNil(weakLibrary)
        XCTAssertEqual(try disk(directory), before)
    }
}

private struct FilteredContext {
    let worker: PhotoIndexWorker
    let library: FilteredLibrary
    let metadata: FilteredMetadata
    let encoders: FilteredEncoders
    let directory: URL
}

private struct FilteredAsset: Sendable {
    let revision: PhotoRevision
    let screenshot: Bool
    let live: Bool

    init(_ id: String, creation: Double? = 100, revision: Double = 123,
         screenshot: Bool = false, live: Bool = false) {
        self.revision = PhotoRevision(id: id, modificationTime: revision, creationTime: creation)
        self.screenshot = screenshot
        self.live = live
    }
}

private final class FilteredMetadata: PhotoSearchFiltering, @unchecked Sendable {
    private let lock = NSLock()
    private let assets: [FilteredAsset]
    private var albums: [String: Set<String>] = [:]
    private var history: [[PhotoRevision]] = []
    private var afterMatching: (@Sendable () -> Void)?

    init(_ assets: [FilteredAsset]) { self.assets = assets }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    var callCount: Int { locked { history.count } }
    var snapshots: [[PhotoRevision]] { locked { history } }
    func setAlbum(_ id: String, ids: Set<String>) { locked { albums[id] = ids } }
    func removeAlbum(_ id: String) { locked { _ = albums.removeValue(forKey: id) } }
    func afterMatch(_ action: @escaping @Sendable () -> Void) { locked { afterMatching = action } }

    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String> {
        try filters.validate()
        let (albums, action) = locked {
            history.append(snapshot)
            return (self.albums, afterMatching)
        }
        let membership: Set<String>?
        if let album = filters.albumID {
            guard let ids = albums[album] else { throw AppFailure.photo("所选相册已删除或无法访问，请重新选择相册。") }
            membership = ids
        } else { membership = nil }
        let accessible = Set(snapshot.map(\.id))
        let matching = Set(assets.filter { asset in
            accessible.contains(asset.revision.id)
                && (membership?.contains(asset.revision.id) ?? true)
                && filters.matches(creationDate: asset.revision.creationTime.map { Date(timeIntervalSince1970: $0) },
                                   isScreenshot: asset.screenshot, isLivePhoto: asset.live)
        }.map(\.revision.id))
        // Deliberately allow late success after mutation/cancellation: the real
        // worker, not the test provider, must reject publication in these tests.
        action?()
        return matching
    }
}

private class FilteredLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [FilteredAsset]
    private var readable = true
    private var authorization: Int? = 3
    private var generation: UInt64?
    private var enumerations = 0
    private var readIDs: [String] = []
    private var pixels = 0
    private var places = 0
    private var enumerationActions: [Int: @Sendable () -> Void] = [:]
    private var revisionActions: [String: @Sendable () -> Void] = [:]

    init(_ assets: [FilteredAsset], generation: UInt64? = 0) {
        self.assets = assets
        self.generation = generation
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { generation } }
    var enumerationCount: Int { locked { enumerations } }
    var revisionReads: [String] { locked { readIDs } }
    var pixelCalls: Int { locked { pixels } }
    var placeCalls: Int { locked { places } }
    func replace(_ assets: [FilteredAsset]) { locked { self.assets = assets } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func setGeneration(_ value: UInt64?) { locked { generation = value } }
    func onEnumeration(_ call: Int, _ action: @escaping @Sendable () -> Void) {
        locked { enumerationActions[call] = action }
    }
    func afterRevisionRead(_ id: String, _ action: @escaping @Sendable () -> Void) {
        locked { revisionActions[id] = action }
    }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let action = locked { () -> (@Sendable () -> Void)? in
            enumerations += 1
            return enumerationActions.removeValue(forKey: enumerations)
        }
        action?()
        return locked { readable ? assets.map(\.revision).sorted { $0.id < $1.id } : [] }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        let (revision, action) = locked { () -> (PhotoRevision?, (@Sendable () -> Void)?) in
            readIDs.append(id)
            let revision = readable ? assets.first { $0.revision.id == id }?.revision : nil
            return (revision, revisionActions.removeValue(forKey: id))
        }
        action?() // Can change generation after returning the old revision to the caller.
        return revision
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { places += 1 }
        XCTFail("Search must not resolve places or read GPS.")
        return nil
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixels += 1 }
        XCTFail("Search must not read local or network image pixels.")
        throw AppFailure.photo("Unexpected pixel request.")
    }
}

private final class FilteringLibrary: FilteredLibrary, PhotoSearchFiltering, @unchecked Sendable {
    let metadata: FilteredMetadata

    init(_ assets: [FilteredAsset], generation: UInt64?, metadata: FilteredMetadata) {
        self.metadata = metadata
        super.init(assets, generation: generation)
    }

    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String> {
        try metadata.matchingPhotoIDs(filters: filters, snapshot: snapshot)
    }
}

private actor FilteredEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let query: [Float]
    private var texts: [String] = []
    private var images = 0
    private var originals = 0

    init(query: [Float] = TestFixtures.vector()) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        self.query = query
    }

    func prepare() throws -> ModelManifest {
        try manifest.validate()
        return manifest
    }
    func text(_ text: String) -> [Float] {
        texts.append(text)
        return query
    }
    func image(preview: IndexingImage) throws -> [Float] {
        images += 1
        XCTFail("Search must not invoke the image encoder.")
        throw AppFailure.photo("Unexpected image encoding.")
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        originals += 1
        XCTFail("Search must not invoke the original-data encoder.")
        throw AppFailure.photo("Unexpected original-data encoding.")
    }
    func calls() -> (texts: [String], images: Int, originals: Int) { (texts, images, originals) }
}

/// Intentionally implements only the old search requirement. New requirements
/// must dispatch to safe defaults through a PhotoWorkServicing existential.
private actor FilteredLegacyService: PhotoWorkServicing {
    struct Request: Sendable { let text: String; let limit: Int; let weight: Float }
    private(set) var requests: [Request] = []

    func refresh() -> LibrarySummary { LibrarySummary() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) -> LibrarySummary {
        LibrarySummary()
    }
    func search(text: String, limit: Int, locationWeight: Float) -> SearchResponse {
        requests.append(Request(text: text, limit: limit, weight: locationWeight))
        return SearchResponse(summary: LibrarySummary(), hits: [])
    }
    func clear() -> LibrarySummary { LibrarySummary() }
}