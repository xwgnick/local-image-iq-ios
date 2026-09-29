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
        XCTAssertEqual(summary.authorizedCount, 7)
        XCTAssertEqual(summary.indexedCount, 4)
        XCTAssertEqual(summary.locatedCount, 2, "Count photos, not distinct shared place labels.")
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
        XCTAssertEqual(context.library.enumerations, 1)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)

        let stale = try await context.store.record(id: "TEST-stale-geography")
        XCTAssertEqual(stale?.geographyVersion, "TEST-old-geography")
        XCTAssertEqual(stale?.photo.location?.text, "TEST-stale-place")
        for version in [oldModel, oldPolicy, TESTRefreshEncoders.modelVersion] {
            let retained = try await context.store.records(modelVersion: version)
            XCTAssertEqual(retained.count, 1, "Version exclusion must not delete an authorized, unchanged row.")
        }
    }

    func testSecondRefreshStillUsesInspectionWithoutFullPreparationOrEncoding() async throws {
        let context = try makeTESTContext([TESTRow("TEST-repeated", label: "TEST-repeated-place")])
        for refreshNumber in 1...2 {
            let summary = try await context.worker.refresh()
            XCTAssertEqual(summary.authorizedCount, 1)
            XCTAssertEqual(summary.indexedCount, 1)
            XCTAssertEqual(summary.locatedCount, 1)
            XCTAssertEqual(summary.modelVersion, cacheVersion)
            XCTAssertNil(summary.modelIssue)
            let calls = await context.encoders.calls
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: refreshNumber))
            XCTAssertEqual(context.library.enumerations, refreshNumber)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
        }
    }

    func testRefreshStillPrunesDeletedEditedAndRevokedSnapshotsWithoutImages() async throws {
        let context = try makeTESTContext([
            TESTRow("TEST-kept", label: "TEST-kept-place"),
            TESTRow("TEST-deleted", label: "TEST-deleted-place"),
            TESTRow("TEST-edited", label: "TEST-edited-place")
        ])
        context.library.replace([
            PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100),
            PhotoRevision(id: "TEST-edited", modificationTime: 124, creationTime: 100)
        ])

        let summary = try await context.worker.refresh()
        XCTAssertEqual(summary.authorizedCount, 2)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        let rows = try await context.store.records(modelVersion: cacheVersion)
        XCTAssertEqual(rows.map(\.photo.id), ["TEST-kept"])
        for label in ["TEST-deleted-place", "TEST-edited-place"] {
            let place = try await context.store.place(text: label, modelVersion: cacheVersion)
            XCTAssertNil(place)
        }
        let keptPlace = try await context.store.place(text: "TEST-kept-place", modelVersion: cacheVersion)
        XCTAssertEqual(keptPlace, TestFixtures.vector(axis: 1))

        context.library.replace([], readable: false)
        let revoked = try await context.worker.refresh()
        XCTAssertEqual(revoked.authorizedCount, 0)
        XCTAssertEqual(revoked.indexedCount, 0)
        XCTAssertEqual(revoked.locatedCount, 0)
        XCTAssertEqual(revoked.modelVersion, cacheVersion)
        XCTAssertNil(revoked.modelIssue)
        let remaining = try await context.store.records(modelVersion: cacheVersion)
        let orphan = try await context.store.place(text: "TEST-kept-place", modelVersion: cacheVersion)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(orphan)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 2))
        XCTAssertEqual(context.library.enumerations, 2)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
    }

    func testInspectionFailureReturnsIssueWithoutModelVersionOrFullPreparationAfterReconciliation() async throws {
        let failure = AppFailure.modelsMissing("TEST-inspection-failure")
        let encoders = try TESTRefreshEncoders(inspectFailure: failure)
        let context = try makeTESTContext([
            TESTRow("TEST-kept", label: "TEST-kept-place"),
            TESTRow("TEST-deleted", label: "TEST-deleted-place")
        ], snapshot: [PhotoRevision(id: "TEST-kept", modificationTime: 123, creationTime: 100)], encoders: encoders)

        let summary = try await context.worker.refresh()
        XCTAssertEqual(summary.authorizedCount, 1)
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertNil(summary.modelVersion)
        XCTAssertEqual(summary.modelIssue, failure.localizedDescription)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        let rows = try await context.store.records(modelVersion: cacheVersion)
        let orphan = try await context.store.place(text: "TEST-deleted-place", modelVersion: cacheVersion)
        XCTAssertEqual(rows.map(\.photo.id), ["TEST-kept"])
        XCTAssertNil(orphan, "Reconciliation must precede even a failed resource inspection.")
        let calls = await encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1))
        XCTAssertEqual(context.library.enumerations, 1)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
    }

    func testFullPreparationFailureIsDeferredUntilSearchAndPreservesCache() async throws {
        let encoders = try TESTRefreshEncoders(prepareFailure: .modelContract("TEST-prepare-failure"))
        let cached = TESTRow("TEST-retained", label: "TEST-retained-place")
        let context = try makeTESTContext([cached], encoders: encoders)

        let summary = try await context.worker.refresh()
        XCTAssertEqual(summary.authorizedCount, 1)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        let refreshCalls = await encoders.calls
        XCTAssertEqual(refreshCalls, TESTRefreshEncoders.Calls(inspect: 1))

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
        XCTAssertEqual(context.library.enumerations, 2)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
    }

    func testRefreshCountsZeroImageVectorButSearchStillRejectsFullVectorValidation() async throws {
        // Valid JSON and dimensions, invalid norm: metadata counting must not decode
        // this blob, while the normal search records() path must still reject it.
        let corrupt = TESTRow("TEST-zero-image", label: "TEST-valid-place",
                              image: [Float](repeating: 0, count: 768))
        let context = try makeTESTContext([corrupt])

        let summary = try await context.worker.refresh()
        XCTAssertEqual(summary.authorizedCount, 1)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, cacheVersion)
        XCTAssertNil(summary.modelIssue)
        let refreshCalls = await context.encoders.calls
        XCTAssertEqual(refreshCalls, TESTRefreshEncoders.Calls(inspect: 1))
        do {
            _ = try await context.worker.search(text: "TEST-query", limit: 3, locationWeight: 0.6)
            XCTFail("Corrupt current vectors must throw, not be silently skipped as empty hits.")
        } catch AppFailure.modelContract { }
        catch { XCTFail("Expected full vector validation failure, got \(error)") }

        let counts = try await context.store.counts(modelVersion: cacheVersion, geographyVersion: resolver.version)
        XCTAssertEqual(counts.indexed, 1, "Search validation must not delete the corrupt fixture.")
        XCTAssertEqual(counts.located, 1)
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTRefreshEncoders.Calls(inspect: 1, prepare: 1))
        XCTAssertEqual(context.library.enumerations, 2)
        XCTAssertEqual(context.library.imageRequests, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
    }

    func testFailedAndCancelledEnumerationPreserveRecordsWithoutInspectingResources() async throws {
        for cancel in [false, true] {
            let cached = TESTRow("TEST-retained", label: "TEST-retained-place")
            // An empty replacement would prune the row if erroneously reconciled.
            let context = try makeTESTContext([cached], snapshot: [])
            if cancel { context.library.cancelNextEnumeration() }
            else { context.library.failEnumeration(.photo("TEST-incomplete-enumeration")) }
            let worker = context.worker
            let task = Task { try await worker.refresh() }
            do {
                _ = try await task.value
                XCTFail("Incomplete or cancelled enumeration must not produce readiness.")
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
            XCTAssertEqual(calls, TESTRefreshEncoders.Calls())
            XCTAssertEqual(context.library.enumerations, 1)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
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
            XCTAssertEqual(context.library.enumerations, 1)
            XCTAssertEqual(context.library.imageRequests, 0)
            XCTAssertEqual(context.library.placeLookups, 0)
        }
    }

    private func TESTRow(_ id: String, model: String? = nil, geography: String? = nil,
                         label: String? = nil, image: [Float] = TestFixtures.vector()) -> CachedPhoto {
        let place = label.map { PlaceEmbedding(text: $0, vector: TestFixtures.vector(axis: 1)) }
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model ?? cacheVersion,
                                 imageEmbedding: image, location: place, creationTime: 100)
        return CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version)
    }

    private func makeTESTContext(_ rows: [CachedPhoto], snapshot: [PhotoRevision]? = nil,
                                 encoders supplied: TESTRefreshEncoders? = nil) throws
        -> (worker: PhotoIndexWorker, library: TESTRefreshLibrary, encoders: TESTRefreshEncoders, store: SQLitePhotoStore) {
        let temporaryDirectory = try TestFixtures.temporaryDirectory()
        let directory = temporaryDirectory.appendingPathComponent("TEST-refresh-readiness", isDirectory: true)
        let store = SQLitePhotoStore(directory: directory, readOnly: true)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        // The shared raw writer closes its connection before the worker opens the DB.
        // It is also the only intentional validation bypass for the zero-vector test.
        try TestFixtures.seedRawCache(rows, directory: directory)
        let library = TESTRefreshLibrary(snapshot ?? rows.map {
            PhotoRevision(id: $0.photo.id, modificationTime: $0.photo.modificationTime, creationTime: $0.photo.creationTime)
        })
        let encoders = try supplied ?? TESTRefreshEncoders()
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        return (worker, library, encoders, store)
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
        return TestFixtures.vector()
    }

    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        calls.factories += 1
        return [any PhotoImageEncoding](repeating: self, count: PhotoIndexWorker.indexingWorkerCount)
    }
}