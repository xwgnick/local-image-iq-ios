import Foundation
import ImageIO
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// These tests exercise the production cache core with immutable synthetic fetch
/// results. They do not request Photos access or manufacture PHChange, and do not
/// establish real OS callback timing, limited-library behavior or atomic privacy.
final class PhotoSearchSnapshotTests: XCTestCase {
    private let a = PhotoRevision(id: "synthetic-a", modificationTime: 1, creationTime: 10)
    private let b = PhotoRevision(id: "synthetic-b", modificationTime: 2, creationTime: 20)

    func testSyntheticSnapshotDefaultsNeedNoValidators() throws {
        let snapshot = PhotoSearchSnapshot(revisions: [a])
        XCTAssertEqual(snapshot.revisions, [a])
        XCTAssertFalse(snapshot.reused)
        try snapshot.validate()
        try snapshot.validatePhotos([a.id])
    }

    func testProductionConformanceDoesNotRequireClientInitialization() {
        func requireSnapshotting<T: PhotoSearchSnapshotting>(_ type: T.Type) {}
        requireSnapshotting(PhotoLibraryClient.self)
    }

    func testConstructionObservationAndInvalidationDoNotLoadAnything() {
        let fixture = SnapshotFixture([a])
        XCTAssertFalse(fixture.cache.isObserving)
        fixture.register()
        fixture.cache.invalidate()
        fixture.register()
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 0)
        XCTAssertEqual(fixture.read { $0.enumerations }, 0)
        XCTAssertEqual(fixture.read { $0.batches.count }, 0)
    }

    func testRepeatedObservedCapturesAndGlobalChecksEnumerateOnlyOnce() throws {
        let fixture = SnapshotFixture([b, a])
        fixture.register()
        let first = try fixture.capture()
        XCTAssertEqual(first.revisions, [a, b])
        XCTAssertFalse(first.reused)
        for _ in 0..<8 {
            let next = try fixture.capture()
            XCTAssertTrue(next.reused)
            XCTAssertEqual(next.revisions, first.revisions)
            try first.validate()
            try next.validate()
        }
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertEqual(fixture.read { $0.enumerations }, 1)
        XCTAssertTrue(fixture.read { $0.batches.isEmpty })
    }

    func testConcurrentCapturesShareOneColdEnumeration() {
        let fixture = SnapshotFixture([a, b])
        fixture.register()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let snapshot = try fixture.capture()
                try snapshot.validate()
                fixture.update { $0.reuseResults.append(snapshot.reused) }
            } catch {
                fixture.update { $0.failures += 1 }
            }
        }
        XCTAssertEqual(fixture.read { $0.failures }, 0)
        XCTAssertEqual(fixture.read { $0.reuseResults.filter { !$0 }.count }, 1)
        XCTAssertEqual(fixture.read { $0.reuseResults.filter { $0 }.count }, 7)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertEqual(fixture.read { $0.enumerations }, 1)
    }

    func testUnchangedRefreshDoesNotDefeatWarmReuse() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        let generation = fixture.cache.changeGeneration
        fixture.register()
        XCTAssertEqual(fixture.cache.changeGeneration, generation)
        XCTAssertTrue(try fixture.capture().reused)
        try first.validate()
        XCTAssertEqual(fixture.read { $0.enumerations }, 1)
    }

    func testLifecycleInvalidationRequiresFreshFetchAndRejectsOldSnapshots() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        let generation = fixture.cache.changeGeneration
        fixture.cache.invalidate() // Parent background/foreground hook.
        XCTAssertGreaterThan(fixture.cache.changeGeneration, generation)
        XCTAssertThrowsError(try first.validate())
        XCTAssertThrowsError(try first.validatePhotos([a.id]))
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        XCTAssertEqual(fixture.read { $0.enumerations }, 2)
    }

    func testSameIDsWithDifferentEffectiveAuthorizationInvalidate() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        fixture.update { $0.access = .init(authorization: 4, canRead: true) }
        fixture.register()
        XCTAssertThrowsError(try first.validate())
        let second = try fixture.capture()
        XCTAssertFalse(second.reused)
        XCTAssertEqual(second.revisions, first.revisions)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testActualAuthorizationCheckedWithoutWaitingForLifecycleOrEvent() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        fixture.update { $0.access = .init(authorization: 4, canRead: true) }
        XCTAssertThrowsError(try first.validate())
        XCTAssertThrowsError(try first.validatePhotos([a.id]))
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        XCTAssertTrue(fixture.read { $0.batches.isEmpty })
    }

    func testDeniedCaptureDoesNotFetchOrAutomaticallyRegister() {
        let fixture = SnapshotFixture([a])
        fixture.update { $0.access = .init(authorization: 2, canRead: false) }
        XCTAssertThrowsError(try fixture.capture()) { error in
            guard case AppFailure.permission = error else { return XCTFail("Expected permission failure") }
        }
        XCTAssertFalse(fixture.cache.isObserving)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 0)
        XCTAssertEqual(fixture.read { $0.enumerations }, 0)
    }

    func testRevocationRejectsBothValidatorsAndCaptureBeforeMetadataReads() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        fixture.update { $0.access = .init(authorization: 2, canRead: false) }
        XCTAssertThrowsError(try first.validate())
        XCTAssertThrowsError(try first.validatePhotos([a.id]))
        XCTAssertThrowsError(try fixture.capture())
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertTrue(fixture.read { $0.batches.isEmpty })
        fixture.update { $0.access = .init(authorization: 3, canRead: true) }
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertThrowsError(try first.validate(), "Restored access must not revive an old epoch")
    }

    func testNoObserverMeansFreshCapturesAndFullMetadataAtEveryBoundary() throws {
        let fixture = SnapshotFixture([a, b])
        let first = try fixture.capture()
        let second = try fixture.capture()
        XCTAssertFalse(first.reused)
        XCTAssertFalse(second.reused)
        XCTAssertFalse(fixture.cache.isObserving)
        try first.validate()
        try second.validate()
        try first.validatePhotos([a.id, b.id])
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 5)
        XCTAssertEqual(fixture.read { $0.enumerations }, 5)
        XCTAssertEqual(fixture.read { $0.batches }, [[a.id, b.id]])
    }

    func testStoppingObservationInvalidatesAndPreventsReuse() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        fixture.unregister()
        XCTAssertThrowsError(try first.validate())
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 3)
    }

    func testUnobservedFullCheckCatchesEqualCountIDSwapAndCreationOnlyEdit() throws {
        let replacements = [[b], [PhotoRevision(id: a.id, modificationTime: a.modificationTime, creationTime: 99)]]
        for replacement in replacements {
            let fixture = SnapshotFixture([a])
            let first = try fixture.capture()
            fixture.update { $0.photos = replacement }
            XCTAssertThrowsError(try first.validate())
            XCTAssertEqual(try fixture.capture().revisions, replacement)
        }
    }

    func testUnobservedPageChecksAlsoRevalidateUnselectedGlobalMetadata() throws {
        let fixture = SnapshotFixture([a, b])
        let first = try fixture.capture()
        fixture.update { $0.photos = [a] }
        XCTAssertThrowsError(try first.validatePhotos([a.id]))
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        XCTAssertEqual(fixture.read { $0.batches }, [[a.id]])
    }

    func testChangeRebuildsFromUpdatedRetainedResultWithoutNewWholeFetch() throws {
        let fixture = SnapshotFixture([a, b])
        fixture.register()
        let first = try fixture.capture()
        let edited = PhotoRevision(id: a.id, modificationTime: 100, creationTime: a.creationTime)
        let added = PhotoRevision(id: "synthetic-c", modificationTime: 3)
        let updated = [added, edited] // Addition, removal and edit in one event.
        fixture.update { $0.photos = updated }
        let generation = fixture.cache.changeGeneration
        fixture.cache.libraryDidChange { previous in
            XCTAssertEqual(previous, [a, b])
            return updated
        }
        XCTAssertGreaterThan(fixture.cache.changeGeneration, generation)
        // This is the state the client's later notification handler will see.
        XCTAssertThrowsError(try first.validate())
        let next = try fixture.capture()
        XCTAssertFalse(next.reused)
        XCTAssertEqual(next.revisions, [edited, added])
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertEqual(fixture.read { $0.enumerations }, 2)
        XCTAssertTrue(try fixture.capture().reused)
    }

    func testUnrelatedEventStillAdvancesGenerationAndInvalidatesSortedMetadata() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let first = try fixture.capture()
        let generation = fixture.cache.changeGeneration
        fixture.cache.libraryDidChange { $0 } // Analog of nil changeDetails.
        XCTAssertGreaterThan(fixture.cache.changeGeneration, generation)
        XCTAssertThrowsError(try first.validate())
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertEqual(fixture.read { $0.enumerations }, 2)
    }

    func testEventWithoutRetainedSourceStillAdvancesGeneration() {
        let fixture = SnapshotFixture([a])
        let generation = fixture.cache.changeGeneration
        fixture.cache.libraryDidChange { _ in
            XCTFail("No source has been captured")
            return nil
        }
        XCTAssertGreaterThan(fixture.cache.changeGeneration, generation)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 0)
    }

    func testDroppingRetainedSourceRequiresFreshLoad() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        _ = try fixture.capture()
        fixture.cache.libraryDidChange { _ in nil }
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testEventDuringInitialFetchCannotInstallStaleResult() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        fixture.update { state in
            state.onLoad = {
                fixture.cache.libraryDidChange { $0 }
            }
        }
        XCTAssertThrowsError(try fixture.capture())
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        XCTAssertTrue(try fixture.capture().reused)
    }

    func testInvalidationDuringEnumerationCannotInstallStaleResult() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        fixture.update { $0.onEnumeration = { fixture.cache.invalidate() } }
        XCTAssertThrowsError(try fixture.capture())
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testAuthorizationChangeDuringFetchCannotInstallStaleResult() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        fixture.update { state in
            state.onLoad = { fixture.update { $0.access = .init(authorization: 4, canRead: true) } }
        }
        XCTAssertThrowsError(try fixture.capture())
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testRegistrationChangesDuringFetchCannotInstallStaleResult() throws {
        for startRegistered in [false, true] {
            let fixture = SnapshotFixture([a])
            if startRegistered { fixture.register() }
            fixture.update { state in
                state.onLoad = {
                    if startRegistered { fixture.unregister() }
                    else { fixture.register() }
                }
            }
            XCTAssertThrowsError(try fixture.capture())
            XCTAssertFalse(try fixture.capture().reused)
            XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        }
    }

    func testSelectedIDsUseOneFreshBatchAndDeduplicateDependencies() throws {
        let fixture = SnapshotFixture([b, a])
        fixture.register()
        let snapshot = try fixture.capture()
        try snapshot.validatePhotos([b.id, a.id, a.id])
        XCTAssertEqual(fixture.read { $0.batches }, [[a.id, b.id]])
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 1)
        XCTAssertEqual(fixture.read { $0.enumerations }, 1)
        try snapshot.validatePhotos([])
        XCTAssertEqual(fixture.read { $0.batches.count }, 1)
    }

    func testNonmemberRejectedBeforeBatchAndErrorContainsNoIDs() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let snapshot = try fixture.capture()
        let unknown = "private-id-must-not-be-in-error"
        XCTAssertThrowsError(try snapshot.validatePhotos([unknown])) { error in
            XCTAssertFalse(String(describing: error).contains(unknown))
            XCTAssertFalse(error.localizedDescription.contains(unknown))
            XCTAssertFalse(error.localizedDescription.contains(self.a.id))
        }
        XCTAssertTrue(fixture.read { $0.batches.isEmpty })
        XCTAssertTrue(try fixture.capture().reused, "Invalid caller input is not evidence of a stale library")
    }

    func testBatchRequiresExactReturnedIDSetCountAndCompleteRevision() throws {
        let edited = PhotoRevision(id: a.id, modificationTime: 90, creationTime: a.creationTime)
        let creationEdit = PhotoRevision(id: a.id, modificationTime: a.modificationTime, creationTime: 90)
        let foreign = PhotoRevision(id: "private-foreign-id", modificationTime: 0)
        let invalidBatches: [[PhotoRevision]] = [[a], [a, a], [a, foreign], [a, b, foreign],
                                                [edited, b], [creationEdit, b]]
        for batch in invalidBatches {
            let fixture = SnapshotFixture([a, b])
            fixture.register()
            let first = try fixture.capture()
            let sibling = try fixture.capture()
            fixture.update { $0.batchOverride = batch }
            XCTAssertThrowsError(try first.validatePhotos([a.id, b.id])) { error in
                XCTAssertFalse(error.localizedDescription.contains(self.a.id))
                XCTAssertFalse(error.localizedDescription.contains(foreign.id))
            }
            XCTAssertThrowsError(try sibling.validate(), "A mismatch invalidates all snapshots of that generation")
            fixture.update { $0.batchOverride = nil }
            XCTAssertFalse(try fixture.capture().reused)
            XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        }
    }

    func testEventDuringBatchRejectsEvenMatchingReturnedRows() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let snapshot = try fixture.capture()
        fixture.update { $0.onBatch = { fixture.cache.libraryDidChange { $0 } } }
        XCTAssertThrowsError(try snapshot.validatePhotos([a.id]))
        XCTAssertEqual(fixture.read { $0.batches.count }, 1)
        XCTAssertFalse(try fixture.capture().reused)
    }

    func testAuthorizationChangeDuringBatchRejectsMatchingReturnedRows() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let snapshot = try fixture.capture()
        fixture.update { state in
            state.onBatch = { fixture.update { $0.access = .init(authorization: 4, canRead: true) } }
        }
        XCTAssertThrowsError(try snapshot.validatePhotos([a.id]))
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testUndeliveredEventWindowIsNotMistakenForFullGlobalValidation() throws {
        let fixture = SnapshotFixture([a, b])
        fixture.register()
        let snapshot = try fixture.capture()
        fixture.update { $0.photos = [a] } // Synthetic removal, deliberately NO event.
        try snapshot.validate() // Known narrower contract, NOT global freshness.
        try snapshot.validatePhotos([a.id]) // Does not prove the unselected b is accessible.
        XCTAssertEqual(try fixture.capture().revisions, [a, b])
        XCTAssertThrowsError(try snapshot.validatePhotos([b.id])) // Fresh batch catches b.
        XCTAssertThrowsError(try snapshot.validate())
        let fresh = try fixture.capture()
        XCTAssertFalse(fresh.reused)
        XCTAssertEqual(fresh.revisions, [a])
    }

    func testOldValidatorDoesNotEvictNewGeneration() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let old = try fixture.capture()
        fixture.cache.invalidate()
        let current = try fixture.capture()
        let generation = fixture.cache.changeGeneration
        XCTAssertThrowsError(try old.validate())
        XCTAssertThrowsError(try old.validatePhotos([a.id]))
        XCTAssertEqual(fixture.cache.changeGeneration, generation)
        try current.validate()
        XCTAssertTrue(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testThrowingLoadDoesNotInstallPartialCache() throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        fixture.update { $0.failLoad = true }
        XCTAssertThrowsError(try fixture.capture())
        fixture.update { $0.failLoad = false }
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertTrue(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
        XCTAssertEqual(fixture.read { $0.enumerations }, 1)
    }

    func testCancelledCaptureDoesNotReadOrRegister() async {
        let fixture = SnapshotFixture([a])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.capture()
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 0)
        XCTAssertFalse(fixture.cache.isObserving)
    }

    func testCancellationDuringEnumerationDoesNotInstallOrPoisonNextCapture() async throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        fixture.update { $0.onEnumeration = { withUnsafeCurrentTask { $0?.cancel() } } }
        let task = Task.detached { try fixture.capture() }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try fixture.capture().reused)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 2)
    }

    func testCancelledValidatorsDoNotFetchAndLeaveWarmCacheAvailable() async throws {
        let fixture = SnapshotFixture([a])
        fixture.register()
        let snapshot = try fixture.capture()
        let id = a.id
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try snapshot.validate()) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try snapshot.validatePhotos([id])) { XCTAssertTrue($0 is CancellationError) }
        }
        try await task.value
        XCTAssertTrue(fixture.read { $0.batches.isEmpty })
        XCTAssertTrue(try fixture.capture().reused)
    }

    func testLegacyFakeKeepsActualWorkersThreeFullEnumerationsPerSearch() async throws {
        let fixture = SnapshotFixture([])
        let library: any PhotoLibraryIndexing = SnapshotLegacyLibrary(fixture: fixture)
        XCTAssertNil(library as? any PhotoSearchSnapshotting)
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoders = try SnapshotLegacyEncoders()
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: .unavailable("Synthetic no-pack fixture"))
        let first = try await worker.search(text: "first", limit: 12, locationWeight: 0)
        XCTAssertTrue(first.hits.isEmpty)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 3)
        XCTAssertEqual(fixture.read { $0.enumerations }, 3)
        _ = try await worker.search(text: "different query", limit: 12, locationWeight: 0)
        XCTAssertEqual(fixture.read { $0.sourceLoads }, 6)
        XCTAssertEqual(fixture.read { $0.enumerations }, 6)
        XCTAssertFalse(fixture.cache.isObserving)
    }
}

private final class SnapshotFixture: @unchecked Sendable {
    typealias Cache = PhotoSearchSnapshotCache<[PhotoRevision]>
    let cache = Cache()
    private let lock = NSLock()
    private var state: State

    struct State {
        var photos: [PhotoRevision]
        var access = Cache.Access(authorization: 3, canRead: true)
        var sourceLoads = 0
        var enumerations = 0
        var batches: [[String]] = []
        var reuseResults: [Bool] = []
        var failures = 0
        var failLoad = false
        var batchOverride: [PhotoRevision]?
        var onLoad: (@Sendable () -> Void)?
        var onEnumeration: (@Sendable () -> Void)?
        var onBatch: (@Sendable () -> Void)?
    }

    init(_ photos: [PhotoRevision]) { state = State(photos: photos) }

    func read<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    @discardableResult
    func update<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }

    func register() { cache.synchronizeObservation(isRegistered: true, access: read { $0.access }) }
    func unregister() { cache.synchronizeObservation(isRegistered: false, access: read { $0.access }) }

    func capture() throws -> PhotoSearchSnapshot {
        try cache.capture(readAccess: { [self] in read { $0.access } },
                          loadSource: { [self] in try source() },
                          loadRevisions: { [self] in revisions($0) },
                          loadPhotos: { [self] in batch($0) })
    }

    func source() throws -> [PhotoRevision] {
        let captured = update { state -> State in
            state.sourceLoads += 1
            let captured = state
            state.onLoad = nil
            return captured
        }
        captured.onLoad?()
        if captured.failLoad { throw AppFailure.photo("Synthetic load failure") }
        return captured.photos
    }

    func revisions(_ source: [PhotoRevision]) -> [PhotoRevision] {
        let hook = update { state -> (@Sendable () -> Void)? in
            state.enumerations += 1
            let hook = state.onEnumeration
            state.onEnumeration = nil
            return hook
        }
        hook?()
        return source
    }

    private func batch(_ ids: [String]) -> [PhotoRevision] {
        let captured = update { state -> State in
            state.batches.append(ids)
            let captured = state
            state.onBatch = nil
            return captured
        }
        captured.onBatch?()
        let requested = Set(ids)
        return captured.batchOverride ?? captured.photos.filter { requested.contains($0.id) }
    }
}

/// Intentionally does NOT opt in to PhotoSearchSnapshotting.
private struct SnapshotLegacyLibrary: PhotoLibraryIndexing {
    let fixture: SnapshotFixture
    var canReadImages: Bool { true }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try fixture.revisions(fixture.source()).sorted { $0.id < $1.id }
    }
    func currentRevision(id: String) -> PhotoRevision? { nil }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        throw AppFailure.photo("Unexpected image request")
    }
}

private struct SnapshotLegacyEncoders: PhotoEncoding {
    let manifest: ModelManifest
    init() throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
    }
    func prepare() async throws -> ModelManifest { manifest }
    func text(_ text: String) async throws -> [Float] { TestFixtures.vector() }
    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float] {
        throw AppFailure.photo("Unexpected original-data request")
    }
    func image(preview: IndexingImage) async throws -> [Float] {
        throw AppFailure.photo("Unexpected preview request")
    }
}