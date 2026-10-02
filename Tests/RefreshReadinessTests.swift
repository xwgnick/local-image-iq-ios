import Foundation
import ImageIO
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Metadata/call-boundary contracts only, not phone performance measurements.
/// All rows and labels are synthetic TEST fixtures; no Photos or model payloads.
final class RefreshReadinessTests: XCTestCase {
    private let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: TESTRefreshEncoders.modelVersion)
    private let resolver = OfflinePlaceResolver.unavailable("TEST-no-boundary-pack")

    func testRefreshCountsCurrentModelAndPolicyRowsButExcludesStaleGeographyFromLocatedCount() async throws {
        let oldModel = IndexImagePolicy.cacheVersion(modelVersion: "TEST-old-model")
        let oldPolicy = TESTRefreshEncoders.modelVersion + "|TEST-old-policy"
        let context = try makeTESTContext([
            TESTRow("TEST-current-a", label: "TEST-shared-place"),
            TESTRow("TEST-current-b", label: "TEST-shared-place"),
            TESTRow("TEST-no-place"),
            TESTRow("TEST-stale-geography", geography: "TEST-old-geography", label: "TEST-stale-place"),
            TESTRow("TEST-old-model", model: oldModel, label: "TEST-shared-place"),
            TESTRow("TEST-old-policy", model: oldPolicy, label: "TEST-shared-place"),
            TESTRow("TEST-no-policy", model: TESTRefreshEncoders.modelVersion, label: "TEST-shared-place")
        ])

        let summary = try await context.worker.refresh()
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 4)
        XCTAssertEqual(summary.locatedCount, 2, "Count photos, not distinct shared place labels.")
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)

        let stale = try await context.store.record(id: "TEST-stale-geography")
        XCTAssertEqual(stale?.geographyVersion, "TEST-old-geography")
        XCTAssertEqual(stale?.photo.location?.text, "TEST-stale-place")
        for version in [oldModel, oldPolicy, TESTRefreshEncoders.modelVersion] {
            let retained = try await context.store.records(modelVersion: version)
            XCTAssertEqual(retained.count, 1, "Version exclusion must not delete saved rows.")
        }
        try await assertCacheUnchanged(context)
    }

    func testSecondRefreshStillUsesInspectionWithoutFullPreparationOrEncoding() async throws {
        let context = try makeTESTContext([TESTRow("TEST-repeated", label: "TEST-repeated-place")])
        for refreshNumber in 1...2 {
            let summary = try await context.worker.refresh()
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertEqual(summary.authorizedCount, 0)
            XCTAssertEqual(summary.indexedCount, 1)
            XCTAssertEqual(summary.locatedCount, 1)
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertNil(summary.modelIssue)
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: refreshNumber))
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            try await assertCacheUnchanged(context)
        }
    }

    func testRefreshRetainsDeletedEditedRevokedRowsAndOrphanPlacesUntilManualUpdate() async throws {
        let context = try makeTESTContext([
            // Replacing this photo in the raw seed leaves its first label orphaned.
            TESTRow("TEST-kept", label: "TEST-orphan-place"),
            TESTRow("TEST-kept", label: "TEST-kept-place"),
            TESTRow("TEST-deleted", label: "TEST-deleted-place"),
            TESTRow("TEST-edited", label: "TEST-edited-place")
        ])
        context.library.replace([
            PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100),
            PhotoRevision(id: "TEST-edited", modificationTime: 124, creationTime: 100)
        ])

        let summary = try await context.worker.refresh()
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(summary.locatedCount, 3)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        let rows = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(rows.map(\.photo.id), ["TEST-deleted", "TEST-edited", "TEST-kept"])
        XCTAssertTrue(rows.allSatisfy { $0.photo.modificationTime == 123 })
        for label in ["TEST-deleted-place", "TEST-edited-place", "TEST-orphan-place"] {
            let place = try await context.store.place(text: label, modelVersion: cacheVersion)
            XCTAssertEqual(place, TestFixtures.vector(axis: 1))
        }
        let keptPlace = try await context.store.place(text: "TEST-kept-place", modelVersion: cacheVersion)
        XCTAssertEqual(keptPlace, TestFixtures.vector(axis: 1))
        try await assertCacheUnchanged(context)

        context.library.replace([], readable: false)
        let revoked = try await context.worker.refresh()
        XCTAssertFalse(revoked.authorizedCountKnown)
        XCTAssertEqual(revoked.authorizedCount, 0)
        XCTAssertEqual(revoked.indexedCount, 3)
        XCTAssertEqual(revoked.locatedCount, 3)
        XCTAssertEqual(revoked.modelVersion, cacheVersion)
        XCTAssertNil(revoked.modelIssue)
        let remaining = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(remaining.map(\.photo.id), rows.map(\.photo.id))
        for label in ["TEST-kept-place", "TEST-deleted-place", "TEST-edited-place", "TEST-orphan-place"] {
            let place = try await context.store.place(text: label, modelVersion: cacheVersion)
            XCTAssertEqual(place, TestFixtures.vector(axis: 1))
        }
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 2))
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        try await assertCacheUnchanged(context)
    }

    func testInspectionFailureReturnsZeroCountsAndIssueWithoutPruningOrPreparing() async throws {
        for failure in [AppFailure.modelsMissing("TEST-inspection-failure"), .modelContract("TEST-corrupt-model")] {
            let encoders = try TESTRefreshEncoders(inspectFailure: failure)
            let context = try makeTESTContext([
                TESTRow("TEST-kept", label: "TEST-kept-place"),
                TESTRow("TEST-deleted", label: "TEST-deleted-place")
            ], snapshot: [PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100)], encoders: encoders)

            let summary = try await context.worker.refresh()
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertEqual(summary.authorizedCount, 0)
            XCTAssertEqual(summary.indexedCount, 0)
            XCTAssertEqual(summary.locatedCount, 0)
            XCTAssertNil(summary.modelVersion)
            XCTAssertEqual(summary.modelIssue, failure.localizedDescription)
            XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
            let rows = try await context.store.records(modelVersion: cacheVersion)
            let place = try await context.store.place(text: "TEST-deleted-place", modelVersion: cacheVersion)
            XCTAssertEqual(rows.map(\.photo.id), ["TEST-deleted", "TEST-kept"])
            XCTAssertEqual(place, TestFixtures.vector(axis: 1))
            let calls = await encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            try await assertCacheUnchanged(context)
        }
    }

    func testFullPreparationFailureIsDeferredUntilSearchAndPreservesCache() async throws {
        let encoders = try TESTRefreshEncoders(prepareFailure: .modelContract("TEST-prepare-failure"))
        let cached = TESTRow("TEST-retained", label: "TEST-retained-place")
        let context = try makeTESTContext([cached], encoders: encoders)

        let summary = try await context.worker.refresh()
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        let refreshCalls = await encoders.calls
        XCTAssertEqual(refreshCalls, TESTRefreshEncoders.Calls(inspect: 1))
        XCTAssertEqual(context.library.enumerations, 0)
        try await assertCacheUnchanged(context)

        do {
            _ = try await context.worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6)
            XCTFail("A full preparation failure must throw, not return an empty hit list.")
        } catch AppFailure.modelContract(let detail) {
            XCTAssertEqual(detail, "TEST-prepare-failure")
        } catch { XCTFail("Unexpected search failure: \(error)") }

        let retainedRows = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(retainedRows.count, 1)
        let retained = try XCTUnwrap(retainedRows.first)
        XCTAssertEqual(retained.photo.id, cached.photo.id)
        XCTAssertEqual(retained.photo.modificationTime, cached.photo.modificationTime)
        XCTAssertEqual(retained.photo.creationTime, cached.photo.creationTime)
        XCTAssertEqual(retained.photo.imageEmbedding, cached.photo.imageEmbedding)
        XCTAssertEqual(retained.photo.location?.text, cached.photo.location?.text)
        XCTAssertEqual(retained.photo.location?.vector, cached.photo.location?.vector)
        XCTAssertEqual(retained.geographyVersion, cached.geographyVersion)
        let calls = await encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 1))
        XCTAssertEqual(context.library.enumerations, 1, "Only search's initial enumeration precedes failed preparation.")
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        try await assertCacheUnchanged(context)
    }

    func testRefreshCountsZeroVectorsButSearchStillRejectsAccessibleImageAndPlaceCorruption() async throws {
        // Valid JSON and dimensions, invalid norm: metadata counting must not decode
        // the blobs, while search must validate every accessible current row.
        let zero = [Float](repeating: 0, count: 768)
        for corrupt in [TESTRow("TEST-zero-image", label: "TEST-valid-place", image: zero),
                        TESTRow("TEST-zero-place", label: "TEST-invalid-place", placeVector: zero)] {
            let context = try makeTESTContext([corrupt])
            let summary = try await context.worker.refresh()
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertEqual(summary.authorizedCount, 0)
            XCTAssertEqual(summary.indexedCount, 1)
            XCTAssertEqual(summary.locatedCount, 1)
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertNil(summary.modelIssue)
            let refreshCalls = await context.encoders.calls
            XCTAssertEqual(refreshCalls, TESTRefreshEncoders.Calls(inspect: 1))
            XCTAssertEqual(context.library.enumerations, 0)
            try await assertCacheUnchanged(context)
            do {
                _ = try await context.worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6)
                XCTFail("Corrupt accessible vectors must throw, not be silently skipped as empty hits.")
            } catch AppFailure.modelContract { }
            catch { XCTFail("Expected full vector validation failure, got \(error)") }

            let counts = try await context.store.storedCounts(modelVersion: cacheVersion, geographyVersion: resolver.version)
            XCTAssertEqual(counts.indexed, 1, "Search validation must not delete the corrupt fixture.")
            XCTAssertEqual(counts.located, 1)
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 1))
            XCTAssertGreaterThan(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            try await assertCacheUnchanged(context)
        }
    }

    func testRefreshIgnoresEnumerationFailuresButSearchPropagatesThemWithoutPreparingOrWriting() async throws {
        for cancel in [false, true] {
            let cached = TESTRow("TEST-retained", label: "TEST-retained-place")
            // Readiness must not consume this failure or the incomplete snapshot.
            let context = try makeTESTContext([cached], snapshot: [])
            if cancel { context.library.cancelNextEnumeration() }
            else { context.library.failEnumeration(.photo("TEST-incomplete-enumeration")) }
            let summary = try await context.worker.refresh()
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertEqual(summary.authorizedCount, 0)
            XCTAssertEqual(summary.indexedCount, 1)
            XCTAssertEqual(summary.locatedCount, 1)
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertNil(summary.modelIssue)
            XCTAssertEqual(context.library.enumerations, 0)
            try await assertCacheUnchanged(context)
            let worker = context.worker
            let task = Task { try await worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6) }
            do {
                _ = try await task.value
                XCTFail("Incomplete or cancelled enumeration must not publish search results.")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch AppFailure.photo(let detail) {
                XCTAssertFalse(cancel)
                XCTAssertEqual(detail, "TEST-incomplete-enumeration")
            } catch { XCTFail("Unexpected enumeration failure: \(error)") }

            let rows = try await context.store.records(modelVersion: cacheVersion)
            XCTAssertEqual(rows.map(\.photo.id), [cached.photo.id])
            XCTAssertEqual(rows.first?.photo.imageEmbedding, cached.photo.imageEmbedding)
            XCTAssertEqual(rows.first?.photo.modificationTime, cached.photo.modificationTime)
            XCTAssertEqual(rows.first?.geographyVersion, cached.geographyVersion)
            let place = try await context.store.place(text: "TEST-retained-place", modelVersion: cacheVersion)
            XCTAssertEqual(place, cached.photo.location?.vector)
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
            XCTAssertEqual(context.library.enumerations, 1)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            try await assertCacheUnchanged(context)
        }
    }

    func testCancelledInspectionPropagatesCancellationInsteadOfReturningReadinessOrIssue() async throws {
        let modes: [TESTRefreshEncoders.InspectionCancellation] = [.throwCancellation, .returnAfterCancellation]
        for mode in modes {
            let encoders = try TESTRefreshEncoders(inspectionCancellation: mode)
            let context = try makeTESTContext([TESTRow("TEST-retained")], encoders: encoders)
            let worker = context.worker
            // Cancellation is confined to this task, never XCTest's calling task.
            let task = Task { try await worker.refresh() }
            do {
                _ = try await task.value
                XCTFail("Inspection cancellation must not return a ready or model-issue summary.")
            } catch is CancellationError { }
            catch { XCTFail("Expected CancellationError, got \(error)") }

            let rows = try await context.store.records(modelVersion: cacheVersion)
            XCTAssertEqual(rows.map(\.photo.id), ["TEST-retained"])
            let calls = await encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            try await assertCacheUnchanged(context)
        }
    }

    func testPreCancelledRefreshDoesNotInspectEnumerateOrModifyCache() async throws {
        let context = try makeTESTContext([TESTRow("TEST-retained", label: "TEST-retained-place")], snapshot: [])
        let worker = context.worker
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.refresh()
        }
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled refresh must not publish readiness.")
        } catch is CancellationError { }
        catch { XCTFail("Expected CancellationError, got \(error)") }
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls())
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        try await assertCacheUnchanged(context)
    }

    func testFreshReadinessAndReadOnlyCountsReturnZeroWithoutCreatingDirectoryOrDatabase() async throws {
        for existingDirectory in [false, true] {
            let context = try makeTESTContext([], snapshot: [PhotoRevision(id: "TEST-not-indexed", modificationTime: 123)],
                                              seedCache: false)
            let directory = await context.store.directory
            if existingDirectory {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let counts = try await context.store.storedCounts(modelVersion: cacheVersion, geographyVersion: resolver.version)
            XCTAssertEqual(counts.indexed, 0)
            XCTAssertEqual(counts.located, 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), existingDirectory)
            try await assertCacheUnchanged(context)

            let launch = try await context.worker.prepareForLaunch { _ in }
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), existingDirectory)
            try await assertCacheUnchanged(context)
            let refresh = try await context.worker.refresh()
            for summary in [launch, refresh] {
                XCTAssertFalse(summary.authorizedCountKnown)
                XCTAssertEqual(summary.authorizedCount, 0, "A not-yet-indexed photo is not a known empty library.")
                XCTAssertEqual(summary.indexedCount, 0)
                XCTAssertEqual(summary.locatedCount, 0)
                XCTAssertEqual(summary.modelVersion, cacheVersion)
                XCTAssertNil(summary.modelIssue)
                XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
            }
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 1))
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            XCTAssertEqual(FileManager.default.fileExists(atPath: directory.path), existingDirectory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path))
            try await assertCacheUnchanged(context)
        }
    }

    func testMetadataLoaderIsCachedOnceAndBoundariesNeverLoadDuringLaunchRefreshSearchOrClear() async throws {
        let metadata = PlacePackMetadata(version: "TEST-metadata-only", coverageDescription: "TEST-small-manifest-coverage")
        let loaders = TESTRefreshPlaceLoaders(metadata: metadata)
        let context = try makeTESTContext([
            TESTRow("TEST-retained", geography: metadata.version, label: "TEST-retained-place")
        ], loaders: loaders)
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls())

        let launch = try await context.worker.prepareForLaunch { _ in }
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls(metadata: 1))
        XCTAssertFalse(launch.authorizedCountKnown)
        XCTAssertEqual(launch.authorizedCount, 0)
        XCTAssertEqual(launch.indexedCount, 1)
        XCTAssertEqual(launch.locatedCount, 1)
        try await assertCacheUnchanged(context)

        let refresh = try await context.worker.refresh()
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls(metadata: 1))
        XCTAssertFalse(refresh.authorizedCountKnown)
        XCTAssertEqual(refresh.authorizedCount, 0)
        XCTAssertEqual(refresh.indexedCount, 1)
        XCTAssertEqual(refresh.locatedCount, 1)
        XCTAssertEqual(context.library.enumerations, 0)
        try await assertCacheUnchanged(context)

        let search = try await context.worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6)
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls(metadata: 1))
        XCTAssertEqual(search.hits.map(\.id), ["TEST-retained"])
        XCTAssertTrue(search.summary.authorizedCountKnown)
        XCTAssertEqual(search.summary.authorizedCount, 1)
        XCTAssertEqual(search.summary.indexedCount, 1)
        XCTAssertEqual(search.summary.locatedCount, 1)
        XCTAssertGreaterThan(context.library.enumerations, 0)
        try await assertCacheUnchanged(context) // Closes the observing read-only handle before clear.

        let enumerationsBeforeClear = context.library.enumerations
        let cleared = try await context.worker.clear()
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls(metadata: 1))
        let afterClear = try await context.worker.refresh()
        for summary in [cleared, afterClear] {
            XCTAssertFalse(summary.authorizedCountKnown)
            XCTAssertEqual(summary.authorizedCount, 0)
            XCTAssertEqual(summary.indexedCount, 0)
            XCTAssertEqual(summary.locatedCount, 0)
        }
        for summary in [launch, refresh, search.summary, cleared, afterClear] {
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertNil(summary.modelIssue)
            XCTAssertEqual(summary.placesDescription, metadata.coverageDescription)
        }
        let remaining = try await context.store.records(modelVersion: cacheVersion)
        let place = try await context.store.place(text: "TEST-retained-place", modelVersion: cacheVersion)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(place, "Explicit clear, unlike readiness/search, does remove saved content.")
        await context.store.close()
        XCTAssertEqual(loaders.calls, TESTRefreshPlaceLoaders.Calls(metadata: 1))
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 3, prepare: 2, text: 1))
        XCTAssertEqual(context.library.enumerations, enumerationsBeforeClear)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
    }

    func testSearchFiltersInaccessibleRowsBeforeDecodingImageAndPlaceVectors() async throws {
        let zero = [Float](repeating: 0, count: 768)
        let context = try makeTESTContext([
            TESTRow("TEST-visible", label: "TEST-visible-place"),
            TESTRow("TEST-hidden-image", label: "TEST-hidden-image-place", image: zero),
            TESTRow("TEST-hidden-place", label: "TEST-hidden-place", placeVector: zero)
        ], snapshot: [PhotoRevision(id: "TEST-visible", modificationTime: 123, creationTime: 100)])

        let summary = try await context.worker.refresh()
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(summary.locatedCount, 3)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(context.library.enumerations, 0)
        try await assertCacheUnchanged(context)
        let response = try await context.worker.search(text: "TEST-query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(response.hits.map(\.id), ["TEST-visible"])
        let hit = try XCTUnwrap(response.hits.first)
        XCTAssertEqual(hit.score, 0.4, accuracy: 0.000001)
        XCTAssertEqual(hit.photo.imageEmbedding, TestFixtures.vector())
        XCTAssertEqual(hit.photo.location?.vector, TestFixtures.vector(axis: 1))
        XCTAssertTrue(response.summary.authorizedCountKnown)
        XCTAssertEqual(response.summary.authorizedCount, 1)
        XCTAssertEqual(response.summary.indexedCount, 3, "Search must display saved, not transiently filtered, counts.")
        XCTAssertEqual(response.summary.locatedCount, 3)
        XCTAssertEqual(response.summary.modelVersion, cacheVersion)
        XCTAssertNil(response.summary.modelIssue)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 1, text: 1))
        XCTAssertGreaterThan(context.library.enumerations, 0)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        try await assertCacheUnchanged(context)
    }

    func testSearchRetainsEditedEmbeddingsExcludesNewPhotosAndCentersOnlyAccessibleCurrentPlaces() async throws {
        let edited = TESTRow("TEST-edited", label: "TEST-edited-place", placeVector: TestFixtures.vector())
        let context = try makeTESTContext([
            edited,
            TESTRow("TEST-kept", label: "TEST-kept-place", image: TestFixtures.vector(axis: 1)),
            TESTRow("TEST-hidden", label: "TEST-hidden-place", placeVector: TestFixtures.vector()),
            TESTRow("TEST-stale-geography", geography: "TEST-old-geography", label: "TEST-stale-place",
                    image: TestFixtures.vector(axis: 1), placeVector: TestFixtures.vector())
        ], snapshot: [
            PhotoRevision(id: "TEST-edited", modificationTime: 124, creationTime: 100),
            PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100),
            PhotoRevision(id: "TEST-stale-geography", modificationTime: 123, creationTime: 100),
            PhotoRevision(id: "TEST-new", modificationTime: 123, creationTime: 100)
        ])
        let response = try await context.worker.search(text: "TEST-query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(response.hits.map(\.id), ["TEST-edited", "TEST-stale-geography", "TEST-kept"])
        let editedHit = try XCTUnwrap(response.hits.first { $0.id == "TEST-edited" })
        let staleHit = try XCTUnwrap(response.hits.first { $0.id == "TEST-stale-geography" })
        let keptHit = try XCTUnwrap(response.hits.first { $0.id == "TEST-kept" })
        // q=e0; accessible current place projections are 1 and 0, so mean=0.5.
        // Hidden/current and accessible/stale labels must not shift that mean.
        XCTAssertEqual(editedHit.score, 0.7, accuracy: 0.000001)
        XCTAssertEqual(keptHit.score, -0.3, accuracy: 0.000001)
        XCTAssertEqual(staleHit.score, 0, accuracy: 0.000001)
        XCTAssertNil(staleHit.photo.location)
        XCTAssertEqual(editedHit.photo.modificationTime, 123, "An accessible edit keeps its OLD indexed content until manual update.")
        XCTAssertEqual(editedHit.photo.imageEmbedding, edited.photo.imageEmbedding)
        XCTAssertEqual(editedHit.photo.location?.vector, edited.photo.location?.vector)
        XCTAssertTrue(response.summary.authorizedCountKnown)
        XCTAssertEqual(response.summary.authorizedCount, 4, "Current authorization includes the not-yet-indexed photo.")
        XCTAssertEqual(response.summary.indexedCount, 4)
        XCTAssertEqual(response.summary.locatedCount, 3)
        XCTAssertEqual(response.summary.modelVersion, cacheVersion)
        XCTAssertNil(response.summary.modelIssue)
        let newPhoto = try await context.store.record(id: "TEST-new")
        let savedEdit = try await context.store.record(id: "TEST-edited")
        let savedStale = try await context.store.record(id: "TEST-stale-geography")
        XCTAssertNil(newPhoto)
        XCTAssertEqual(savedEdit?.photo.modificationTime, 123)
        XCTAssertEqual(savedStale?.photo.location?.text, "TEST-stale-place")
        try await assertCacheUnchanged(context)

        // Access filtering is recomputed for each search without pruning saved rows.
        context.library.replace([PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100)])
        let limited = try await context.worker.search(text: "TEST-query", limit: 10, locationWeight: 0.6)
        XCTAssertEqual(limited.hits.map(\.id), ["TEST-kept"])
        XCTAssertEqual(try XCTUnwrap(limited.hits.first).score, 0, accuracy: 0.000001)
        XCTAssertTrue(limited.summary.authorizedCountKnown)
        XCTAssertEqual(limited.summary.authorizedCount, 1)
        XCTAssertEqual(limited.summary.indexedCount, 4)
        XCTAssertEqual(limited.summary.locatedCount, 3)
        try await assertCacheUnchanged(context)

        context.library.replace([], readable: false)
        do {
            _ = try await context.worker.search(text: "TEST-query", limit: 10, locationWeight: 0.6)
            XCTFail("Revoked access must not expose saved hits.")
        } catch AppFailure.permission { }
        catch { XCTFail("Expected permission failure, got \(error)") }
        try await assertCacheUnchanged(context)
        let revoked = try await context.worker.refresh()
        XCTAssertFalse(revoked.authorizedCountKnown)
        XCTAssertEqual(revoked.authorizedCount, 0)
        XCTAssertEqual(revoked.indexedCount, 4)
        XCTAssertEqual(revoked.locatedCount, 3)
        XCTAssertEqual(revoked.modelVersion, cacheVersion)
        XCTAssertNil(revoked.modelIssue)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 2, text: 2))
        XCTAssertGreaterThan(context.library.enumerations, 0)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        try await assertCacheUnchanged(context)
    }

    func testAccessChangesDuringQueryEncodingRejectResultsWithoutPersistentWrites() async throws {
        for revoked in [false, true] {
            let context = try makeTESTContext([
                TESTRow("TEST-kept", label: "TEST-kept-place"),
                TESTRow("TEST-removed", label: "TEST-removed-place")
            ])
            let library = context.library
            await context.encoders.setBeforeTextReturn {
                library.replace([PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100)],
                                readable: !revoked)
            }
            do {
                _ = try await context.worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6)
                XCTFail("Late access changes must not publish scores based on the earlier snapshot.")
            } catch AppFailure.permission {
                XCTAssertTrue(revoked)
            } catch AppFailure.photo(let detail) {
                XCTAssertFalse(revoked)
                XCTAssertEqual(detail, "The authorized library changed during search. Search again; the saved index is unchanged.")
            } catch { XCTFail("Unexpected search failure: \(error)") }
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(prepare: 1, text: 1))
            XCTAssertGreaterThan(context.library.enumerations, 0)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
            let rows = try await context.store.records(modelVersion: cacheVersion)
            let place = try await context.store.place(text: "TEST-removed-place", modelVersion: cacheVersion)
            XCTAssertEqual(rows.map(\.photo.id), ["TEST-kept", "TEST-removed"])
            XCTAssertEqual(place, TestFixtures.vector(axis: 1))
            try await assertCacheUnchanged(context)
        }
    }

    private func TESTRow(_ id: String, model: String? = nil, geography: String? = nil,
                         label: String? = nil, image: [Float] = TestFixtures.vector(),
                         placeVector: [Float] = TestFixtures.vector(axis: 1)) -> CachedPhoto {
        let place = label.map { PlaceEmbedding(text: $0, vector: placeVector) }
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model ?? cacheVersion,
                                 imageEmbedding: image, location: place, creationTime: 100)
        return CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version)
    }

    private func makeTESTContext(_ rows: [CachedPhoto], snapshot: [PhotoRevision]? = nil,
                                 encoders supplied: TESTRefreshEncoders? = nil, seedCache: Bool = true,
                                 loaders: TESTRefreshPlaceLoaders? = nil) throws -> TESTRefreshContext {
        let temporaryDirectory = try TestFixtures.temporaryDirectory()
        let directory = temporaryDirectory.appendingPathComponent("TEST-refresh-readiness", isDirectory: true)
        let store = SQLitePhotoStore(directory: directory, readOnly: true)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        // The shared raw writer closes its connection before the worker opens the DB.
        // It is also the only intentional validation bypass for zero-vector fixtures.
        if seedCache { try TestFixtures.seedRawCache(rows, directory: directory) }
        let library = TESTRefreshLibrary(snapshot ?? rows.map {
            PhotoRevision(id: $0.photo.id, modificationTime: $0.photo.modificationTime, creationTime: $0.photo.creationTime)
        })
        let encoders = try supplied ?? TESTRefreshEncoders()
        let worker: PhotoIndexWorker
        if let loaders {
            // Do not supply a resolver: that would bypass both injected loaders.
            worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      metadataLoader: { loaders.loadMetadata() },
                                      boundaryLoader: { loaders.loadBoundaries() })
        } else {
            worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        }
        return TESTRefreshContext(worker: worker, library: library, encoders: encoders, store: store,
                                  savedFiles: try cacheFiles(in: directory))
    }

    private func cacheFiles(in directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try files.reduce(into: [String: Data]()) { result, file in
            result[file.lastPathComponent] = try Data(contentsOf: file)
        }
    }

    private func assertCacheUnchanged(_ context: TESTRefreshContext,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        await context.store.close()
        let directory = await context.store.directory
        XCTAssertEqual(try cacheFiles(in: directory), context.savedFiles,
                       "Automatic operations must preserve DB bytes and create no files.", file: file, line: line)
    }
}

private struct TESTRefreshContext: Sendable {
    let worker: PhotoIndexWorker
    let library: TESTRefreshLibrary
    let encoders: TESTRefreshEncoders
    let store: SQLitePhotoStore
    let savedFiles: [String: Data]
}

private final class TESTRefreshPlaceLoaders: @unchecked Sendable {
    struct Calls: Equatable, Sendable {
        var metadata = 0
        var boundaries = 0
    }
    private let metadata: PlacePackMetadata
    private let lock = NSLock()
    private var recorded = Calls()

    init(metadata: PlacePackMetadata) { self.metadata = metadata }

    var calls: Calls {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func loadMetadata() -> PlacePackMetadata {
        lock.lock()
        defer { lock.unlock() }
        recorded.metadata += 1
        return metadata
    }

    func loadBoundaries() -> OfflinePlaceResolver {
        lock.lock()
        recorded.boundaries += 1
        lock.unlock()
        XCTFail("Startup, refresh, search and clear must never parse full boundaries.")
        return .unavailable("TEST-unexpected-boundary-load")
    }
}

/// Synchronous protocol witnesses cannot use an actor. NSLock protects every
/// mutable field for @unchecked Sendable; locks are held only in synchronous
/// scopes, never across await. This fake never constructs or requests Photos.
private final class TESTRefreshLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [PhotoRevision]
    private var readable = true
    private var enumerationError: AppFailure?
    private var cancelEnumeration = false
    private var enumerationCount = 0
    private var imageRequestCount = 0
    private var placeLookupCount = 0

    init(_ snapshot: [PhotoRevision]) { self.snapshot = snapshot }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var canReadImages: Bool { locked { readable } }
    var enumerations: Int { locked { enumerationCount } }
    var imageRequests: Int { locked { imageRequestCount } }
    var placeLookups: Int { locked { placeLookupCount } }

    func replace(_ snapshot: [PhotoRevision], readable: Bool = true) {
        locked { self.snapshot = snapshot; self.readable = readable }
    }

    func failEnumeration(_ error: AppFailure) { locked { enumerationError = error } }
    func cancelNextEnumeration() { locked { cancelEnumeration = true } }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try locked {
            enumerationCount += 1
            if let enumerationError { throw enumerationError }
            if cancelEnumeration {
                cancelEnumeration = false
                withUnsafeCurrentTask { $0?.cancel() }
                return [] // Incomplete snapshot must never reach reconciliation.
            }
            return readable ? snapshot : []
        }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        locked { readable ? snapshot.first { $0.id == id } : nil }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { placeLookupCount += 1 }
        return nil
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { imageRequestCount += 1 }
        throw AppFailure.photo("TEST-unexpected-image-request")
    }
}

/// Explicitly overrides inspectResources: the protocol's compatibility default
/// delegates to prepare and would not test the lightweight production boundary.
private actor TESTRefreshEncoders: PhotoEncoding {
    static let modelVersion = "TEST-refresh-model"

    struct Calls: Equatable, Sendable {
        var inspect = 0
        var prepare = 0
        var dataImages = 0
        var previewImages = 0
        var text = 0
        var factories = 0
    }

    enum InspectionCancellation: Sendable {
        case none, throwCancellation, returnAfterCancellation
    }

    private let manifest: ModelManifest
    private let inspectFailure: AppFailure?
    private let prepareFailure: AppFailure?
    private let inspectionCancellation: InspectionCancellation
    private var beforeTextReturn: (@Sendable () -> Void)?
    private(set) var calls = Calls()

    init(inspectFailure: AppFailure? = nil, prepareFailure: AppFailure? = nil,
         inspectionCancellation: InspectionCancellation = .none) throws {
        // Reuse shared contract metadata only, without model files or production asset IDs.
        let metadata = TestFixtures.manifest.replacingOccurrences(of: "test-model", with: Self.modelVersion)
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(metadata.utf8))
        self.inspectFailure = inspectFailure
        self.prepareFailure = prepareFailure
        self.inspectionCancellation = inspectionCancellation
    }

    func inspectResources() async throws -> ModelManifest {
        calls.inspect += 1
        switch inspectionCancellation {
        case .none: break
        case .throwCancellation: throw CancellationError()
        case .returnAfterCancellation:
            withUnsafeCurrentTask { $0?.cancel() }
            return manifest // Deliberate late success; worker must check cancellation.
        }
        if let inspectFailure { throw inspectFailure }
        return manifest
    }

    func prepare() async throws -> ModelManifest {
        calls.prepare += 1
        if let prepareFailure { throw prepareFailure }
        return manifest
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float] {
        calls.dataImages += 1
        throw AppFailure.modelContract("TEST-unexpected-data-encoding")
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        calls.previewImages += 1
        throw AppFailure.modelContract("TEST-unexpected-preview-encoding")
    }

    func text(_ text: String) async throws -> [Float] {
        calls.text += 1
        beforeTextReturn?()
        return TestFixtures.vector()
    }

    func setBeforeTextReturn(_ callback: @escaping @Sendable () -> Void) {
        beforeTextReturn = callback
    }

    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        calls.factories += 1
        return [any PhotoImageEncoding](repeating: self, count: PhotoIndexWorker.indexingWorkerCount)
    }
}