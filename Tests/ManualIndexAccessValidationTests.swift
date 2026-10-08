import Foundation
import ImageIO
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real temporary SQLite, synthetic Photos/embeddings only. Transaction faults
/// fire on the third validator call (entry, BEGIN, pre-COMMIT), not on a timer.
final class ManualIndexAccessValidationTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic manual boundaries")

    private func context(_ revisions: [PhotoRevision] = [], generation: UInt64? = nil,
                         access: IndexAccessCoordinator? = nil) throws -> ManualValidationContext {
        let parent = try TestFixtures.temporaryDirectory()
        let directory = parent.appendingPathComponent("index", isDirectory: true)
        let library = try ManualValidationLibrary(revisions, generation: generation)
        let encoders = try ManualValidationEncoders()
        let writer = SQLitePhotoStore(directory: directory)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: resolver, indexAccess: access)
        addTeardownBlock {
            await writer.close()
            try FileManager.default.removeItem(at: parent)
        }
        return ManualValidationContext(worker: worker, library: library, encoders: encoders,
                                       writer: writer, directory: directory)
    }

    private func revision(_ id: String = "asset", modification: Double = 123,
                          creation: Double? = 100) -> PhotoRevision {
        PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
    }

    private func cached(_ revision: PhotoRevision, label: String? = nil, axis: Int = 1) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: revision.id, modificationTime: revision.modificationTime,
            modelVersion: version, imageEmbedding: TestFixtures.vector(axis: axis),
            location: label.map { PlaceEmbedding(text: "Photo taken in \($0).", vector: TestFixtures.vector(axis: 2)) },
            creationTime: revision.creationTime), geographyVersion: resolver.version)
    }

    private func disk(_ c: ManualValidationContext) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: c.directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: c.directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func assertSame(_ actual: CachedPhoto?, _ expected: CachedPhoto,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual?.photo.id, expected.photo.id, file: file, line: line)
        XCTAssertEqual(actual?.photo.modificationTime, expected.photo.modificationTime, file: file, line: line)
        XCTAssertEqual(actual?.photo.creationTime, expected.photo.creationTime, file: file, line: line)
        XCTAssertEqual(actual?.photo.modelVersion, expected.photo.modelVersion, file: file, line: line)
        XCTAssertEqual(actual?.photo.imageEmbedding, expected.photo.imageEmbedding, file: file, line: line)
        XCTAssertEqual(actual?.photo.location?.text, expected.photo.location?.text, file: file, line: line)
        XCTAssertEqual(actual?.photo.location?.vector, expected.photo.location?.vector, file: file, line: line)
        XCTAssertEqual(actual?.geographyVersion, expected.geographyVersion, file: file, line: line)
    }

    private func run(_ c: ManualValidationContext,
                     progress: @escaping @Sendable (IndexProgress) async -> Void = { _ in }) async throws -> LibrarySummary {
        try await c.worker.index(networkAllowed: false, progress: progress)
    }

    func testDeniedBeforeEnumerationPreservesPhotosPlacesAndEveryFile() async throws {
        let c = try context([revision()])
        let old = cached(revision(), label: "Kept")
        try await c.writer.save(old)
        let before = try disk(c)
        c.library.mutate { $0.readable = false }
        do { _ = try await run(c); XCTFail("Denied indexing must fail before enumeration") }
        catch AppFailure.permission { }
        XCTAssertEqual(c.library.value.enumerations, 0)
        XCTAssertEqual(c.library.value.requests, [])
        let calls = await c.encoders.prepareCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try disk(c), before)
        let retained = try await c.writer.record(id: "asset")
        assertSame(retained, old)
    }

    func testDeniedFreshIndexDoesNotCreateDirectoryOrDatabase() async throws {
        let c = try context()
        c.library.mutate { $0.readable = false }
        do { _ = try await run(c); XCTFail("Expected denied access") }
        catch AppFailure.permission { }
        XCTAssertEqual(c.library.value.enumerations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path))
    }

    func testEnumerationFailureCannotPruneExistingRows() async throws {
        let c = try context([revision()])
        try await c.writer.save(cached(revision(), label: "Kept"))
        let before = try disk(c)
        c.library.mutate { $0.enumerationFailure = true }
        do { _ = try await run(c); XCTFail("Expected enumeration failure") }
        catch AppFailure.photo { }
        XCTAssertEqual(c.library.value.enumerations, 1)
        XCTAssertEqual(try disk(c), before)
    }

    func testRevocationInsideEnumerationReturningEmptyCannotPrune() async throws {
        let c = try context([revision()])
        try await c.writer.save(cached(revision(), label: "Kept"))
        let before = try disk(c)
        c.library.onEnumeration { $0.readable = false }
        do { _ = try await run(c); XCTFail("An unreadable [] is not a deletion snapshot") }
        catch AppFailure.permission { }
        XCTAssertEqual(c.library.value.enumerations, 1)
        XCTAssertEqual(try disk(c), before)
        XCTAssertTrue(c.library.value.requests.isEmpty)
    }

    func testFullToLimitedChangeInsideEnumerationRejectsEvenReadableEmptySnapshot() async throws {
        let c = try context([revision()])
        try await c.writer.save(cached(revision(), label: "Kept"))
        let before = try disk(c)
        c.library.onEnumeration {
            $0.authorization = PHAuthorizationStatus.limited.rawValue
            $0.revisions = []
        }
        do { _ = try await run(c); XCTFail("Do not capture a new authorization after enumeration") }
        catch AppFailure.photo { }
        XCTAssertEqual(c.library.value.enumerations, 1)
        XCTAssertEqual(try disk(c), before)
    }

    func testGenerationChangeInsideEnumerationRejectsUnchangedIDs() async throws {
        let c = try context([revision()], generation: 7)
        try await c.writer.save(cached(revision(), label: "Kept"))
        let before = try disk(c)
        c.library.onEnumeration { $0.generation = 8 }
        do { _ = try await run(c); XCTFail("Same IDs must not hide a changed generation") }
        catch AppFailure.photo { }
        XCTAssertEqual(try disk(c), before)
        XCTAssertTrue(c.library.value.requests.isEmpty)
    }

    func testWorkerReconcileRechecksAccessInsideTransactionAndRollsBackOrphans() async throws {
        let selected = revision()
        let c = try context([selected], generation: 0)
        // The writer and worker lazily open separate writable connections. Warm
        // the worker before measuring rollback: its schema-init transaction can
        // change database bytes independently of the later reconcile transaction.
        // Match the fake's no-GPS result so this cache-hit pass prunes no rows or
        // places and requests no pixels. Constructors/read-only refresh won't do.
        let warmRecord = cached(selected)
        try await c.writer.save(warmRecord)
        let warm = try await run(c)
        XCTAssertEqual(warm.indexedCount, 1)
        XCTAssertEqual(c.library.value.enumerations, 2)
        XCTAssertTrue(c.library.value.requests.isEmpty)
        let imageCalls = await c.encoders.imageCalls
        XCTAssertEqual(imageCalls, 0)
        let warmed = try await c.writer.record(id: selected.id)
        assertSame(warmed, warmRecord)

        // Seed the exact photo/place pair AFTER warm-up, then measure only the
        // faulted empty-snapshot reconcile on the already-open worker connection.
        let old = cached(selected, label: "Orphan after delete")
        try await c.writer.save(old)
        c.library.mutate {
            $0.revisions = []
            $0.enumerations = 0
            $0.requests = []
            $0.places = []
        }
        let before = try disk(c)
        // The first destructive reconcile creates a rollback journal. Its next
        // Photos guard is pre-COMMIT, not the pre-enumeration or BEGIN guard.
        c.library.revokeWhenJournalExists(c.directory.appendingPathComponent("index.sqlite3-journal"))
        do { _ = try await run(c); XCTFail("Expected transaction-boundary revocation") }
        catch AppFailure.permission { }
        XCTAssertEqual(c.library.value.journalFaults, 1)
        XCTAssertEqual(c.library.value.enumerations, 1)
        XCTAssertTrue(c.library.value.requests.isEmpty)
        XCTAssertTrue(c.library.value.places.isEmpty)
        XCTAssertEqual(try disk(c), before)
        let retained = try await c.writer.record(id: "asset")
        assertSame(retained, old)
    }

    func testReconcileValidatorDeniedAtEntryDoesNotCreateFiles() async throws {
        let c = try context()
        let calls = ManualValidationBox(0)
        do {
            try await c.writer.reconcile(completeEnumeration: []) {
                calls.modify { $0 += 1 }
                throw AppFailure.permission
            }
            XCTFail("Expected entry guard")
        } catch AppFailure.permission { }
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path))
    }

    func testReconcilePrecommitAuthorizationFaultRollsBackPhotosAndPlaces() async throws {
        let c = try context([revision()])
        let first = cached(revision(), label: "First")
        let second = cached(revision("second"), label: "Second")
        try await c.writer.save(first)
        try await c.writer.save(second)
        let before = try disk(c)
        let calls = ManualValidationBox(0)
        let library = c.library
        let journal = c.directory.appendingPathComponent("index.sqlite3-journal")
        do {
            try await c.writer.reconcile(completeEnumeration: []) {
                let call = calls.modify { $0 += 1; return $0 }
                if call == 3 {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path), "Fault must follow real DELETEs")
                    library.mutate { $0.readable = false }
                }
                guard library.canReadImages else { throw AppFailure.permission }
            }
            XCTFail("Expected rollback")
        } catch AppFailure.permission { }
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(try disk(c), before)
        let a = try await c.writer.record(id: "asset")
        let b = try await c.writer.record(id: "second")
        assertSame(a, first)
        assertSame(b, second)
    }

    func testSavePrecommitRevisionFaultRollsBackReplacementAndNewPlace() async throws {
        let selected = revision()
        let c = try context([selected])
        let old = cached(selected, label: "Old")
        try await c.writer.save(old)
        let before = try disk(c)
        let replacement = cached(selected, label: "New", axis: 0)
        let calls = ManualValidationBox(0)
        let library = c.library
        let changed = revision(creation: 101)
        let journal = c.directory.appendingPathComponent("index.sqlite3-journal")
        do {
            try await c.writer.save(replacement) {
                let call = calls.modify { $0 += 1; return $0 }
                if call == 3 {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
                    library.mutate { $0.revisions = [changed] }
                }
                guard library.currentRevision(id: selected.id) == selected else {
                    throw AppFailure.photo("Synthetic changed revision")
                }
            }
            XCTFail("Expected save rollback")
        } catch AppFailure.photo { }
        XCTAssertEqual(calls.value, 3)
        XCTAssertEqual(try disk(c), before)
        let retained = try await c.writer.record(id: "asset")
        let newPlace = try await c.writer.place(text: "Photo taken in New.", modelVersion: version)
        assertSame(retained, old)
        XCTAssertNil(newPlace)
    }

    func testWorkerSavePrecommitCreationChangeIsOneFailureNotFatalOrEncoded() async throws {
        let c = try context([revision()])
        let old = cached(revision(creation: 99), label: "Old")
        try await c.writer.save(old)
        let library = c.library
        let changed = revision(creation: 101)
        let journal = c.directory.appendingPathComponent("index.sqlite3-journal")
        // Start counting only after image encoding. Reads 1/2 are preparation
        // return and parent prequeue; 3/4/5 are save entry/BEGIN/pre-COMMIT.
        await c.encoders.afterImage {
            library.changeOnRevisionRead(5, to: changed, journal: journal)
        }
        let states = ManualValidationBox<[IndexProgress]>([])
        let result = try await run(c) { value in states.modify { $0.append(value) } }
        let final = try XCTUnwrap(states.value.last)
        XCTAssertEqual(library.value.revisionFaults, 1)
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 1)
        XCTAssertEqual(final.encoded, 0)
        XCTAssertEqual(final.reused, 0)
        XCTAssertEqual(final.placeUpdated, 0)
        XCTAssertEqual(final.localPreviews + final.reducedPreviews + final.networkPreviews, 0)
        // Manual final reconciliation still compares modification time only.
        // It must not erase the old row just because creation time changed.
        XCTAssertEqual(result.indexedCount, 1)
        let retained = try await c.writer.record(id: "asset")
        assertSame(retained, old)
    }

    func testCreationOnlyCacheChangesReencodeIncludingNilTransitions() async throws {
        let pairs: [(Double?, Double?)] = [(99, 100), (nil, 100), (100, nil)]
        for (oldCreation, newCreation) in pairs {
            let current = revision(creation: newCreation)
            let c = try context([current])
            try await c.writer.save(cached(revision(creation: oldCreation)))
            let states = ManualValidationBox<[IndexProgress]>([])
            _ = try await run(c) { state in states.modify { $0.append(state) } }
            let final = try XCTUnwrap(states.value.last)
            XCTAssertEqual(final.encoded, 1)
            XCTAssertEqual(final.reused, 0)
            XCTAssertEqual(final.failed, 0)
            XCTAssertEqual(c.library.value.requests, ["asset"])
            let saved = try await c.writer.record(id: "asset")
            XCTAssertEqual(saved?.photo.creationTime, newCreation)
            XCTAssertEqual(saved?.photo.imageEmbedding, TestFixtures.vector())
        }
    }

    func testRevisionChangeDuringPreviewSkipsEncodingAndKeepsManualFailureCount() async throws {
        let c = try context([revision()])
        let changed = revision(modification: 124)
        c.library.onPreview { $0.revisions = [changed] }
        let states = ManualValidationBox<[IndexProgress]>([])
        let result = try await run(c) { state in states.modify { $0.append(state) } }
        let final = try XCTUnwrap(states.value.last)
        XCTAssertEqual(result.authorizedCount, 1)
        XCTAssertEqual(result.indexedCount, 0)
        XCTAssertEqual(final.completed, 1)
        XCTAssertEqual(final.failed, 1)
        XCTAssertEqual(final.encoded, 0)
        let imageCalls = await c.encoders.imageCalls
        XCTAssertEqual(imageCalls, 0)
        XCTAssertEqual(c.library.value.enumerations, 2)
    }

    func testAuthorizationEpochFromInitialSnapshotSurvivesModelAwait() async throws {
        let c = try context([revision()])
        let library = c.library
        await c.encoders.afterPrepare { library.mutate { $0.authorization = PHAuthorizationStatus.limited.rawValue } }
        do { _ = try await run(c); XCTFail("Do not recapture authorization after model preparation") }
        catch AppFailure.photo { }
        XCTAssertTrue(library.value.requests.isEmpty)
        let rows = try await c.writer.records(modelVersion: version)
        XCTAssertTrue(rows.isEmpty)
    }

    func testGenerationFromInitialSnapshotRejectsLateImageResult() async throws {
        let c = try context([revision()], generation: 10)
        let library = c.library
        await c.encoders.afterImage { library.mutate { $0.generation = 11 } }
        let states = ManualValidationBox<[IndexProgress]>([])
        do {
            _ = try await run(c) { state in states.modify { $0.append(state) } }
            XCTFail("Final reconciliation must not silently adopt a new epoch")
        } catch AppFailure.photo { }
        XCTAssertTrue(states.value.allSatisfy { $0.encoded == 0 && $0.reused == 0 })
        let rows = try await c.writer.records(modelVersion: version)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(library.value.enumerations, 1)
    }

    func testDefaultReconcilePreservesModificationOnlyMetadataSemantics() async throws {
        let c = try context()
        let old = cached(revision(creation: 99), label: "Kept")
        try await c.writer.save(old)
        try await c.writer.save(cached(revision("deleted"), label: "Deleted"))
        try await c.writer.save(cached(revision("modified"), label: "Modified"))
        // Existing callers omit the new validator and keep their API/semantics.
        try await c.writer.reconcile(completeEnumeration: [revision(creation: 100), revision("modified", modification: 124)])
        let rows = try await c.writer.records(modelVersion: version)
        XCTAssertEqual(rows.map(\.photo.id), ["asset"])
        assertSame(rows.first, old)
        let removedPlace = try await c.writer.place(text: "Photo taken in Deleted.", modelVersion: version)
        let modifiedPlace = try await c.writer.place(text: "Photo taken in Modified.", modelVersion: version)
        XCTAssertNil(removedPlace)
        XCTAssertNil(modifiedPlace)
    }

    func testManualKeepsSnapshotOrderTwoEnumerationsAndParentOwnedWriteLease() async throws {
        let enqueues = ManualValidationBox(0)
        let access = IndexAccessCoordinator(didEnqueue: { enqueues.modify { $0 += 1 } })
        let ids = ["c", "a", "b"]
        let c = try context(ids.map { revision($0) }, access: access)
        let lease = try await access.acquireWrite()
        defer { lease.release() }
        let writer = c.writer
        let version = self.version
        let states = ManualValidationBox<[IndexProgress]>([])
        let result = try await run(c) { state in
            states.modify { $0.append(state) }
            do {
                let rows = try await writer.records(modelVersion: version)
                XCTAssertEqual(rows.map(\.photo.id), Array(ids.prefix(state.completed)).sorted())
                XCTAssertEqual(rows.count, state.encoded)
            } catch { XCTFail("Unable to inspect committed prefix: \(error)") }
        }
        XCTAssertEqual(result.indexedCount, 3)
        XCTAssertEqual(c.library.value.enumerations, 2)
        XCTAssertEqual(c.library.value.places, ids)
        XCTAssertEqual(states.value.map(\.completed), [0, 1, 2, 3])
        XCTAssertEqual(enqueues.value, 1, "Manual worker must not acquire a nested read/write lease")
        XCTAssertTrue(access.isWriting)
    }
}

private struct ManualValidationContext: Sendable {
    let worker: PhotoIndexWorker
    let library: ManualValidationLibrary
    let encoders: ManualValidationEncoders
    let writer: SQLitePhotoStore
    let directory: URL
}

private final class ManualValidationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { modify { $0 } }
    @discardableResult
    func modify<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&storage)
    }
}

private final class ManualValidationLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    struct State {
        var revisions: [PhotoRevision]
        var generation: UInt64?
        var authorization = PHAuthorizationStatus.authorized.rawValue
        var readable = true
        var enumerations = 0
        var requests: [String] = []
        var places: [String] = []
        var enumerationFailure = false
        var enumerationAction: (@Sendable (inout State) -> Void)?
        var previewAction: (@Sendable (inout State) -> Void)?
        var revokeJournal: URL?
        var journalFaults = 0
        var revisionFault: (remaining: Int, revision: PhotoRevision, journal: URL)?
        var revisionFaults = 0
    }

    private let state: ManualValidationBox<State>
    private let preview: IndexingImage
    init(_ revisions: [PhotoRevision], generation: UInt64?) throws {
        state = ManualValidationBox(State(revisions: revisions, generation: generation))
        preview = IndexingImage(cgImage: try TestFixtures.image(width: 2, height: 2) { _, _ in (60, 110, 170) },
                                orientation: .up, source: .localPreview)
    }
    var value: State { state.value }
    func mutate(_ body: (inout State) -> Void) { state.modify(body) }
    func onEnumeration(_ body: @escaping @Sendable (inout State) -> Void) { mutate { $0.enumerationAction = body } }
    func onPreview(_ body: @escaping @Sendable (inout State) -> Void) { mutate { $0.previewAction = body } }
    func revokeWhenJournalExists(_ file: URL) { mutate { $0.revokeJournal = file } }
    func changeOnRevisionRead(_ count: Int, to revision: PhotoRevision, journal: URL) {
        mutate { $0.revisionFault = (count, revision, journal) }
    }

    var canReadImages: Bool {
        state.modify {
            if let journal = $0.revokeJournal, FileManager.default.fileExists(atPath: journal.path) {
                $0.revokeJournal = nil
                $0.journalFaults += 1
                $0.readable = false
            }
            return $0.readable
        }
    }
    var authorizationStatusRawValue: Int? { state.value.authorization }
    var changeGeneration: UInt64? { state.value.generation }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try state.modify {
            $0.enumerations += 1
            let action = $0.enumerationAction
            $0.enumerationAction = nil
            action?(&$0)
            if $0.enumerationFailure { throw AppFailure.photo("Synthetic enumeration failure") }
            return $0.readable ? $0.revisions : []
        }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        state.modify {
            if var fault = $0.revisionFault {
                fault.remaining -= 1
                if fault.remaining == 0 {
                    XCTAssertTrue(FileManager.default.fileExists(atPath: fault.journal.path),
                                  "The scripted worker fault must be inside a written SQLite transaction")
                    $0.revisions = [fault.revision]
                    $0.revisionFault = nil
                    $0.revisionFaults += 1
                } else { $0.revisionFault = fault }
            }
            return $0.readable ? $0.revisions.first { $0.id == id } : nil
        }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { nil }
    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult {
        mutate { $0.places.append(id) }
        return .noGPS
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        mutate {
            $0.requests.append(id)
            let action = $0.previewAction
            $0.previewAction = nil
            action?(&$0)
        }
        return preview
    }
}

private actor ManualValidationEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private var prepared: (@Sendable () -> Void)?
    private var encoded: (@Sendable () -> Void)?
    private(set) var prepareCalls = 0
    private(set) var imageCalls = 0

    init() throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
    }
    func afterPrepare(_ action: @escaping @Sendable () -> Void) { prepared = action }
    func afterImage(_ action: @escaping @Sendable () -> Void) { encoded = action }
    func prepare() throws -> ModelManifest {
        prepareCalls += 1
        let action = prepared
        prepared = nil
        action?()
        return manifest
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        XCTFail("Manual indexing must never request original-data encoding")
        throw AppFailure.modelContract("Unexpected original-data API")
    }
    func image(preview: IndexingImage) throws -> [Float] {
        imageCalls += 1
        let action = encoded
        encoded = nil
        action?()
        return TestFixtures.vector()
    }
    func text(_ text: String) throws -> [Float] { TestFixtures.vector(axis: 2) }
}