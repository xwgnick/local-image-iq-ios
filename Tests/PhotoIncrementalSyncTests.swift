import Foundation
import ImageIO
import Photos
import SQLite3
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic pixels and temporary SQLite only. All concurrency ordering uses
/// explicit gates; no real Photos, model weights, sleeps, or timing assertions.
final class PhotoIncrementalSyncTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic boundaries")

    private func context(_ rows: [SyncRow], generation: UInt64? = 0,
                         holds: [Int: SyncHold] = [:], imageFailure: AppFailure? = nil,
                         textFailure: AppFailure? = nil) throws -> SyncContext {
        let parent = try TestFixtures.temporaryDirectory()
        let directory = parent.appendingPathComponent("not-created", isDirectory: true)
        let enqueued = SyncSignal()
        let access = IndexAccessCoordinator(didEnqueue: { enqueued.send() })
        let library = try SyncLibrary(rows, generation: generation)
        let encoders = try SyncEncoders(holds: holds, imageFailure: imageFailure, textFailure: textFailure)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: resolver, indexAccess: access)
        let reader = SQLitePhotoStore(directory: directory, readOnly: true)
        addTeardownBlock {
            await reader.close()
            try FileManager.default.removeItem(at: parent)
        }
        return SyncContext(worker: worker, library: library, encoders: encoders, access: access,
                           directory: directory, reader: reader, enqueued: enqueued)
    }

    private func seed(_ context: SyncContext, _ rows: [SyncRow], model: String? = nil) throws {
        let cached = rows.map { row in
            CachedPhoto(photo: IndexedPhoto(id: row.revision.id, modificationTime: row.revision.modificationTime,
                modelVersion: model ?? version, imageEmbedding: TestFixtures.vector(axis: 1),
                location: row.label.map { PlaceEmbedding(text: "Photo taken in \($0).", vector: TestFixtures.vector(axis: 2)) },
                creationTime: row.revision.creationTime), geographyVersion: resolver.version)
        }
        try TestFixtures.seedRawCache(cached, directory: context.directory)
    }

    private func run(_ context: SyncContext, network: Bool = false) async throws -> PhotoSyncResult {
        try await context.worker.synchronize(networkAllowed: network, progress: { _ in }, committed: {})
    }

    private func start(_ context: SyncContext, holds: [SyncHold],
                       progress: @escaping @Sendable (PhotoSyncProgress) async -> Void = { _ in },
                       committed: @escaping @Sendable () async -> Void = {}) -> Task<PhotoSyncResult, Error> {
        let task = Task { try await context.worker.synchronize(networkAllowed: false, progress: progress, committed: committed) }
        addTeardownBlock {
            task.cancel()
            holds.forEach { $0.release.send() }
            _ = await task.result
        }
        return task
    }

    private func disk(_ context: SyncContext) throws -> Data {
        try Data(contentsOf: context.directory.appendingPathComponent("index.sqlite3"))
    }

    private func sql(_ context: SyncContext, _ sql: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(context.directory.appendingPathComponent("index.sqlite3").path,
                                    &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle,
              sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw AppFailure.storage("Synthetic SQL failed")
        }
    }

    func testProgressDistinguishesUnknownCheckingAndKnownPendingTotals() {
        XCTAssertNil(PhotoSyncProgress().fraction)
        XCTAssertEqual(PhotoSyncProgress(phase: .updating, total: 0).fraction, 1)
        XCTAssertEqual(PhotoSyncProgress(phase: .updating, total: 4, completed: 1).fraction, 0.25)
        XCTAssertEqual(PhotoSyncProgress().phase, .checking)
    }

    func testInitAndEmptySyncDoNotCreateFolderOrDatabaseOrPool() async throws {
        let context = try context([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        let states = SyncBox<[PhotoSyncProgress]>([])
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { state in
            states.modify { $0.append(state) }
        }, committed: { XCTFail("No mutation") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        XCTAssertEqual(states.value, [PhotoSyncProgress(), PhotoSyncProgress(phase: .updating, total: 0)])
        XCTAssertTrue(result.summary.authorizedCountKnown)
        XCTAssertFalse(result.summary.textIndexStatisticsKnown, "Parent must retain known OCR counts")
        XCTAssertEqual(context.access.revision, 0)
        let factory = await context.encoders.factoryCalls
        let prepared = await context.encoders.prepareCalls
        XCTAssertEqual(factory, 0)
        XCTAssertEqual(prepared, 0)
    }

    func testSyncRequiresExplicitSharedCoordinatorWithoutCreatingStorage() async throws {
        let context = try context([SyncRow("new")])
        let worker = PhotoIndexWorker(library: context.library, encoders: context.encoders, directory: context.directory)
        do {
            _ = try await worker.synchronize(networkAllowed: false, progress: { _ in }, committed: {})
            XCTFail("Missing shared coordinator must not silently create a private one")
        } catch AppFailure.storage { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
    }

    func testOnlyNewPhotoEncodesAndTotalsExcludeUnchangedLibrary() async throws {
        let context = try context([SyncRow("kept"), SyncRow("new")])
        try seed(context, [SyncRow("kept")])
        let states = SyncBox<[PhotoSyncProgress]>([])
        let mutations = SyncBox(0)
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { state in
            states.modify { $0.append(state) }
        }, committed: { mutations.modify { $0 += 1 } })
        XCTAssertEqual(context.library.requests.map(\.0), ["new"])
        XCTAssertTrue(context.library.requests.allSatisfy { !$0.1 })
        XCTAssertEqual(result.progress, PhotoSyncProgress(phase: .updating, total: 1, completed: 1, encoded: 1))
        XCTAssertEqual(result.summary.indexedCount, 2)
        XCTAssertEqual(result.summary.authorizedCount, 2)
        XCTAssertEqual(result.summary.modelVersion, "test-model|photokit-hq224-fast-fallback-v1")
        XCTAssertEqual(mutations.value, 1)
        XCTAssertNil(states.value.first?.total)
        XCTAssertEqual(states.value.dropFirst().map(\.total), [1, 1])
        let rows = try await context.reader.searchRecords(modelVersion: version, accessibleIDs: ["kept", "new"])
        XCTAssertEqual(rows.first { $0.photo.id == "kept" }?.photo.imageEmbedding, TestFixtures.vector(axis: 1))
    }

    func testUnchangedMetadataNeverDecodesBlobsOrWritesOrChangesDerivedCaches() async throws {
        let context = try context([SyncRow("kept", label: "Place")])
        try seed(context, [SyncRow("kept", label: "Place")])
        // Nonempty malformed payload deliberately proves this is a metadata-only
        // diff, not a decode of unchanged vectors. Search still owns validation.
        try sql(context, "UPDATE photos SET image_embedding = x'bad0'; UPDATE places SET embedding = x'bad1';")
        for table in ["photos", "places"] {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                try sql(context, "CREATE TRIGGER reject_\(table)_\(event) BEFORE \(event) ON \(table) BEGIN SELECT RAISE(ABORT, 'Unexpected mutation'); END;")
            }
        }
        let derived = context.directory.appendingPathComponent("search-vectors-v1.bin")
        try Data([1, 2, 3]).write(to: derived)
        let before = try disk(context)
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { _ in }, committed: { XCTFail("No change") })
        XCTAssertEqual(try disk(context), before)
        XCTAssertEqual(try Data(contentsOf: derived), Data([1, 2, 3]))
        XCTAssertEqual(context.access.revision, 0)
        XCTAssertEqual(result.summary.modelVersion, version)
        XCTAssertEqual(result.progress.total, 0)
        XCTAssertTrue(context.library.requests.isEmpty)
        XCTAssertEqual(context.library.placeLookups, 0)
        let factory = await context.encoders.factoryCalls
        let texts = await context.encoders.texts
        XCTAssertEqual(factory, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testEditedCreationTimeOldModelAndMissingEmbeddingBecomePending() async throws {
        let current = [SyncRow("edited", revision: 124), SyncRow("created", creation: 101),
                       SyncRow("old"), SyncRow("empty"), SyncRow("kept")]
        let context = try context(current)
        try seed(context, [SyncRow("edited"), SyncRow("created"), SyncRow("empty"), SyncRow("kept")])
        try seed(context, [SyncRow("old")], model: "old-model")
        try sql(context, "UPDATE photos SET image_embedding = x'' WHERE id = 'empty';")
        let result = try await run(context)
        XCTAssertEqual(result.progress.total, 4)
        XCTAssertEqual(result.progress.encoded, 4)
        XCTAssertEqual(result.progress.removed, 4)
        XCTAssertEqual(context.library.requests.map(\.0).sorted(), ["created", "edited", "empty", "old"])
        XCTAssertEqual(result.summary.indexedCount, 5)
        let rows = try await context.reader.syncMetadata()
        XCTAssertEqual(rows["created"]?.revision.creationTime, 101)
        XCTAssertEqual(rows["edited"]?.revision.modificationTime, 124)
        XCTAssertEqual(rows["old"]?.modelVersion, version)
    }

    func testFullPermissionPrunesOnlyObsoleteIndexRowsAndTheirOrphanPlaces() async throws {
        try await assertPrune(limited: false)
    }

    func testLimitedPermissionPrunesInaccessibleIndexWithGenericRemovedCount() async throws {
        try await assertPrune(limited: true)
    }

    private func assertPrune(limited: Bool) async throws {
        let context = try context([SyncRow("kept", label: "Keep")])
        if limited { context.library.change(.limited) }
        try seed(context, [SyncRow("kept", label: "Keep"), SyncRow("gone", label: "Gone")])
        let result = try await run(context)
        XCTAssertEqual(result.progress.removed, 1) // No PhotoKit delete API exists in this fake.
        XCTAssertEqual(result.progress.total, 0)
        XCTAssertEqual(result.progress.encoded, 0)
        let rows = try await context.reader.syncMetadata()
        let gone = try await context.reader.storedPlace(text: "Photo taken in Gone.", modelVersion: version)
        let kept = try await context.reader.storedPlace(text: "Photo taken in Keep.", modelVersion: version)
        XCTAssertEqual(Set(rows.keys), ["kept"])
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
        XCTAssertTrue(context.library.requests.isEmpty)
    }

    func testDeniedEmptyEnumerationCannotEraseSavedIndex() async throws {
        let context = try context([])
        try seed(context, [SyncRow("saved")])
        let before = try disk(context)
        context.library.change(.denied)
        do { _ = try await run(context); XCTFail("Denied") }
        catch AppFailure.permission { }
        XCTAssertEqual(try disk(context), before)
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.access.revision, 0)
    }

    func testRevocationDuringEnumerationCannotTurnEmptyScopeIntoDeletion() async throws {
        let context = try context([SyncRow("saved")])
        try seed(context, [SyncRow("saved")])
        let before = try disk(context)
        context.library.onEnumeration = { context.library.change(.denied) }
        do { _ = try await run(context); XCTFail("Revoked") }
        catch AppFailure.permission { }
        context.library.onEnumeration = nil
        XCTAssertEqual(try disk(context), before)
        XCTAssertEqual(context.access.revision, 0)
    }

    func testMalformedOrDuplicateAuthorizedRevisionsFailBeforeAnyWrites() async throws {
        let cases = [[SyncRow("")], [SyncRow("a"), SyncRow("a")],
                     [SyncRow("a", revision: .infinity)], [SyncRow("a", creation: .nan)]]
        for rows in cases {
            let context = try context(rows)
            try seed(context, [SyncRow("saved")])
            let before = try disk(context)
            do { _ = try await run(context); XCTFail("Invalid snapshot") }
            catch AppFailure.photo { }
            XCTAssertEqual(try disk(context), before)
            XCTAssertEqual(context.access.revision, 0)
        }
    }

    func testGenerationChangeDuringEncodingRejectsLateSuccess() async throws {
        let hold = SyncHold()
        let context = try context([SyncRow("new")], holds: [0: hold])
        let task = start(context, holds: [hold])
        await hold.started.wait(1)
        context.library.change(.generation)
        hold.release.send()
        do { _ = try await task.value; XCTFail("Changed generation") }
        catch AppFailure.photo { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        XCTAssertEqual(context.access.revision, 0)
    }

    func testGenerationRaceInsideSQLiteRollsBackPhotoAndPlace() async throws {
        try await assertTransactionRace(.generation)
    }

    func testFullRevisionRaceInsideSQLiteRollsBackPhotoAndPlace() async throws {
        for change in [SyncLibrary.Change.revision, .creation] { try await assertTransactionRace(change) }
    }

    func testAuthorizationRaceInsideSQLiteRollsBackPhotoAndPlace() async throws {
        for change in [SyncLibrary.Change.denied, .limited] { try await assertTransactionRace(change) }
    }

    private func assertTransactionRace(_ change: SyncLibrary.Change) async throws {
        let context = try context([SyncRow("new", label: "New place"), SyncRow("saved")])
        try seed(context, [SyncRow("saved")])
        // Writer checks: worker entry, save entry, transaction entry, final
        // pre-COMMIT. The fourth changes Photos AFTER both SQL INSERTs.
        context.library.changeOnWriterCheck(access: context.access, check: 4, change: change)
        do { _ = try await run(context); XCTFail("Transaction race") }
        catch AppFailure.photo { }
        catch AppFailure.permission { }
        XCTAssertEqual(context.library.writerChecks, 4)
        let rows = try await context.reader.syncMetadata()
        let place = try await context.reader.storedPlace(text: "Photo taken in New place.", modelVersion: version)
        XCTAssertEqual(Set(rows.keys), ["saved"])
        XCTAssertNil(place)
        XCTAssertEqual(context.access.revision, 1, "A rolled-back writer still invalidates old authority")
        XCTAssertFalse(context.access.isWriting)
    }

    func testNilGenerationFullSnapshotBeforePrunePreventsStaleScopeDeletion() async throws {
        let context = try context([], generation: nil)
        try seed(context, [SyncRow("saved")])
        let before = try disk(context)
        do {
            _ = try await context.worker.synchronize(networkAllowed: false, progress: { state in
                if state.phase == .updating { context.library.replace([SyncRow("saved")]) }
            }, committed: { XCTFail("Stale prune must not commit") })
            XCTFail("Changed scope")
        } catch AppFailure.photo { }
        XCTAssertEqual(try disk(context), before)
        XCTAssertEqual(context.access.revision, 0)
    }

    func testGenerationRaceAtPrunePreCommitRestoresRemovedRowsAndPlaces() async throws {
        let context = try context([])
        try seed(context, [SyncRow("saved", label: "Saved")])
        let writerEnumerations = SyncBox(0)
        context.library.onEnumeration = {
            if context.access.isWriting {
                writerEnumerations.modify { $0 += 1 }
                // Worker entry, remove entry, transaction entry, pre-COMMIT.
                if writerEnumerations.value == 4 { context.library.change(.generation) }
            }
        }
        defer { context.library.onEnumeration = nil }
        do {
            _ = try await context.worker.synchronize(networkAllowed: false, progress: { _ in },
                                                     committed: { XCTFail("Prune rolled back") })
            XCTFail("Changed prune authority")
        } catch AppFailure.photo { }
        XCTAssertEqual(writerEnumerations.value, 4)
        let rows = try await context.reader.syncMetadata()
        let place = try await context.reader.storedPlace(text: "Photo taken in Saved.", modelVersion: version)
        XCTAssertEqual(Set(rows.keys), ["saved"])
        XCTAssertNotNil(place)
        XCTAssertFalse(context.access.isWriting)
    }

    func testPruneNotifiesOnceAfterWriterReleaseAndDoesNotLoadImagePool() async throws {
        let context = try context([])
        try seed(context, [SyncRow("a"), SyncRow("b")])
        let callbacks = SyncBox(0)
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { _ in }, committed: {
            XCTAssertFalse(context.access.isWriting)
            do {
                let lease = try await context.access.acquireRead()
                defer { lease.release() }
                let rows = try await context.reader.syncMetadata()
                XCTAssertTrue(rows.isEmpty)
                callbacks.modify { $0 += 1 }
            } catch { XCTFail("Prune callback must be able to read") }
        })
        XCTAssertEqual(callbacks.value, 1)
        XCTAssertEqual(result.progress.removed, 2)
        let factory = await context.encoders.factoryCalls
        XCTAssertEqual(factory, 0)
    }

    func testNilGenerationEndSnapshotDetectsNewUnindexedIDButKeepsCommittedRow() async throws {
        let context = try context([SyncRow("new")], generation: nil)
        do {
            _ = try await context.worker.synchronize(networkAllowed: false, progress: { state in
                if state.completed == 1 { context.library.replace([SyncRow("new"), SyncRow("later")]) }
            }, committed: {})
            XCTFail("End snapshot must validate IDs outside the pending set")
        } catch AppFailure.photo { }
        let rows = try await context.reader.syncMetadata()
        XCTAssertEqual(Set(rows.keys), ["new"])
    }

    func testForegroundReadAllowsParallelEncodingButPreventsFirstDatabaseCreationUntilRelease() async throws {
        let hold = SyncHold()
        let context = try context([SyncRow("new")], holds: [0: hold])
        let foreground = try await context.access.acquireRead()
        defer { foreground.release() }
        let mutations = SyncBox(0)
        let task = start(context, holds: [hold], committed: { mutations.modify { $0 += 1 } })
        await hold.started.wait(1)
        XCTAssertFalse(context.access.isWriting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        hold.release.send()
        await context.enqueued.wait(3) // Foreground read, diff read, queued writer.
        XCTAssertFalse(context.access.isWriting)
        XCTAssertEqual(context.access.revision, 0)
        XCTAssertEqual(mutations.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        foreground.release()
        let result = try await task.value
        XCTAssertEqual(result.progress.encoded, 1)
        XCTAssertEqual(mutations.value, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("index.sqlite3").path))
    }

    func testCommittedCallbackCanAcquireReadAndSeesActualSavedOutcome() async throws {
        let context = try context([SyncRow("new")])
        let callbacks = SyncBox(0)
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { state in
            if state.encoded > 0 {
                let rows = try? await context.reader.syncMetadata()
                XCTAssertEqual(rows?.count, state.encoded)
            }
        }, committed: {
            XCTAssertFalse(context.access.isWriting)
            do {
                let lease = try await context.access.acquireRead()
                defer { lease.release() }
                let rows = try await context.reader.syncMetadata()
                XCTAssertEqual(Set(rows.keys), ["new"])
                callbacks.modify { $0 += 1 }
            } catch { XCTFail("Committed callback should read successfully") }
        })
        XCTAssertEqual(callbacks.value, 1)
        XCTAssertEqual(result.progress.completed, 1)
    }

    func testCancellationDrainsAllTwentyLatePredictionsAndNeverAdmitsTwentyFirst() async throws {
        let holds = (0..<20).map { _ in SyncHold() }
        let context = try context((0..<21).map { SyncRow("p\($0)") },
                                  holds: Dictionary(uniqueKeysWithValues: holds.enumerated().map { ($0.offset, $0.element) }))
        let returned = SyncBox(false)
        let task = Task {
            defer { returned.modify { $0 = true } }
            return try await context.worker.synchronize(networkAllowed: false, progress: { _ in }, committed: { XCTFail("Cancelled") })
        }
        addTeardownBlock {
            task.cancel()
            holds.forEach { $0.release.send() }
            _ = await task.result
        }
        for hold in holds { await hold.started.wait(1) }
        XCTAssertEqual(context.library.requests.count, 20)
        task.cancel()
        for hold in holds { await hold.cancelled.wait(1) }
        for hold in holds.dropLast() { hold.release.send(); await hold.finished.wait(1) }
        XCTAssertFalse(returned.value, "One noninterruptible prediction still owns the task scope")
        XCTAssertEqual(context.library.requests.count, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        holds.last!.release.send()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch is CancellationError { }
        XCTAssertTrue(returned.value)
        XCTAssertEqual(context.access.revision, 0)
        let factory = await context.encoders.factoryCalls
        XCTAssertEqual(factory, 1)
    }

    func testCancellationKeepsCompletedRecordButDiscardsUncommittedLateRecord() async throws {
        let hold = SyncHold()
        let context = try context([SyncRow("first"), SyncRow("second")], holds: [1: hold])
        let committed = SyncSignal()
        let task = start(context, holds: [hold], committed: { committed.send() })
        await hold.started.wait(1)
        await committed.wait(1)
        task.cancel()
        await hold.cancelled.wait(1)
        hold.release.send()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch is CancellationError { }
        let rows = try await context.reader.syncMetadata()
        XCTAssertEqual(Set(rows.keys), ["first"])
        XCTAssertEqual(context.access.revision, 1)
    }

    func testCancellationWhileWriterQueuedRemovesWaiterWithoutCreatingDatabase() async throws {
        let context = try context([SyncRow("new")])
        let foreground = try await context.access.acquireRead()
        defer { foreground.release() }
        let task = start(context, holds: [])
        await context.enqueued.wait(3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        XCTAssertEqual(context.access.revision, 0)
        let other = try XCTUnwrap(context.access.tryRead())
        other.release()
    }

    func testOneTwentySlotPoolForRollingWindowAndNoQueryOrOCREncoding() async throws {
        let context = try context((0..<41).map { SyncRow("p\($0)") })
        let result = try await run(context)
        XCTAssertEqual(result.progress.encoded, 41)
        let factory = await context.encoders.factoryCalls
        let slots = await context.encoders.slots
        let texts = await context.encoders.texts
        XCTAssertEqual(factory, 1)
        XCTAssertEqual(slots.count, 20)
        XCTAssertEqual(Set(slots.map { ObjectIdentifier($0) }).count, 20)
        for (index, slot) in slots.enumerated() {
            let calls = await slot.calls
            XCTAssertEqual(calls, index == 0 ? 3 : 2)
        }
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("text-index.sqlite3").path))
        _ = try await run(context)
        let secondFactory = await context.encoders.factoryCalls
        XCTAssertEqual(secondFactory, 1, "Unchanged second sync does not create another pool")
    }

    func testFinishedButUncommittedResultsStillOccupyTwentySlotWindow() async throws {
        let holds = (0..<20).map { _ in SyncHold() }
        let context = try context((0..<41).map { SyncRow("p\($0)") },
                                  holds: Dictionary(uniqueKeysWithValues: holds.enumerated().map { ($0.offset, $0.element) }))
        let task = start(context, holds: holds)
        for hold in holds { await hold.started.wait(1) }
        for hold in holds.dropFirst() { hold.release.send(); await hold.finished.wait(1) }
        XCTAssertEqual(context.library.requests.count, 20, "Completed tail cannot admit the twenty-first photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        holds[0].release.send()
        let result = try await task.value
        XCTAssertEqual(result.progress.encoded, 41)
        let factory = await context.encoders.factoryCalls
        XCTAssertEqual(factory, 1)
    }

    func testSecondSyncOnSameWorkerIsRejectedWhileFirstDrains() async throws {
        let hold = SyncHold()
        let context = try context([SyncRow("new")], holds: [0: hold])
        let first = start(context, holds: [hold])
        await hold.started.wait(1)
        do { _ = try await run(context); XCTFail("Do not reenter an async sync job") }
        catch AppFailure.storage { }
        hold.release.send()
        let result = try await first.value
        XCTAssertEqual(result.progress.encoded, 1)
        let factory = await context.encoders.factoryCalls
        XCTAssertEqual(factory, 1)
    }

    func testSQLiteFailureNeverPublishesCommittedOrEncodedProgress() async throws {
        let context = try context([SyncRow("new"), SyncRow("saved")])
        try seed(context, [SyncRow("saved")])
        try sql(context, "CREATE TRIGGER reject_sync BEFORE INSERT ON photos BEGIN SELECT RAISE(ABORT, 'Synthetic storage failure'); END;")
        let states = SyncBox<[PhotoSyncProgress]>([])
        do {
            _ = try await context.worker.synchronize(networkAllowed: false, progress: { state in
                states.modify { $0.append(state) }
            }, committed: { XCTFail("Failed SQL must not notify a commit") })
            XCTFail("Storage error")
        } catch AppFailure.storage { }
        XCTAssertEqual(states.value.last?.completed, 0)
        XCTAssertEqual(states.value.last?.encoded, 0)
        let rows = try await context.reader.syncMetadata()
        XCTAssertEqual(Set(rows.keys), ["saved"])
        XCTAssertFalse(context.access.isWriting)
        XCTAssertEqual(context.access.revision, 1)
    }

    func testOfflineCloudAndOrdinaryErrorsHaveAccurateProgressWithoutRawErrorText() async throws {
        let context = try context([SyncRow("ok"), SyncRow("cloud", failure: AppFailure.cloudOnly),
            SyncRow("raw-cloud", failure: NSError(domain: PHPhotosErrorDomain, code: 3164)),
            SyncRow("error", failure: NSError(domain: "Synthetic", code: 3164,
                                             userInfo: [NSLocalizedDescriptionKey: "private path must not enter progress"]))])
        let result = try await run(context)
        XCTAssertEqual(result.progress, PhotoSyncProgress(phase: .updating, total: 4, completed: 4,
                                                         encoded: 1, failed: 1, needsNetwork: 2))
        XCTAssertEqual(result.summary.indexedCount, 1)
        XCTAssertTrue(context.library.requests.allSatisfy { !$0.1 })
    }

    func testNetworkOptInIsExplicitAndCloudFailureIsNotReportedAsSuccess() async throws {
        let context = try context([SyncRow("online", networkOnly: true), SyncRow("failed", failure: AppFailure.cloudOnly)])
        let result = try await run(context, network: true)
        XCTAssertEqual(result.progress.encoded, 1)
        XCTAssertEqual(result.progress.failed, 1)
        XCTAssertEqual(result.progress.needsNetwork, 0)
        XCTAssertTrue(context.library.requests.allSatisfy { $0.1 })
    }

    func testEditedCloudOnlyPhotoLosesObsoleteEmbeddingRatherThanKeepingStaleVector() async throws {
        let context = try context([SyncRow("edited", revision: 124, failure: AppFailure.cloudOnly)])
        try seed(context, [SyncRow("edited", label: "Old")])
        let result = try await run(context)
        XCTAssertEqual(result.progress.removed, 1)
        XCTAssertEqual(result.progress.needsNetwork, 1)
        XCTAssertEqual(result.progress.encoded, 0)
        let rows = try await context.reader.syncMetadata()
        XCTAssertTrue(rows.isEmpty)
    }

    func testFatalModelPermissionAndStorageErrorsAreNotPerPhotoSuccessOrFailureCounts() async throws {
        for failure in [AppFailure.modelContract("Synthetic"), .modelsMissing("Synthetic"), .permission, .storage("Synthetic")] {
            let context = try context([SyncRow("new")], imageFailure: failure)
            let states = SyncBox<[PhotoSyncProgress]>([])
            do {
                _ = try await context.worker.synchronize(networkAllowed: false, progress: { state in
                    states.modify { $0.append(state) }
                }, committed: { XCTFail("Fatal failure") })
                XCTFail("Expected fatal error")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            XCTAssertEqual(states.value.last?.completed, 0)
            XCTAssertEqual(states.value.last?.failed, 0)
            XCTAssertEqual(context.access.revision, 0)
        }
    }

    func testPlaceTextIsPreparedOutsideWriterAndReusedAcrossPendingPhotos() async throws {
        let context = try context([SyncRow("a", label: "Shared"), SyncRow("b", label: "Shared")])
        await context.encoders.observeText { XCTAssertFalse(context.access.isWriting) }
        let result = try await run(context)
        let texts = await context.encoders.texts
        XCTAssertEqual(texts, ["Photo taken in Shared."])
        XCTAssertEqual(result.summary.locatedCount, 2)
        XCTAssertEqual(result.progress.encoded, 2)
    }

    func testExistingPlaceVectorIsReadOnlyReusedWithoutTextEncoding() async throws {
        let context = try context([SyncRow("saved", label: "Shared"), SyncRow("new", label: "Shared")])
        try seed(context, [SyncRow("saved", label: "Shared")])
        let result = try await run(context)
        let texts = await context.encoders.texts
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(result.summary.locatedCount, 2)
    }

    func testSQLiteSaveFinalValidatorRollsBackRowAndPlaceTogether() async throws {
        let context = try context([])
        try seed(context, [SyncRow("saved", label: "Old")])
        let store = SQLitePhotoStore(directory: context.directory)
        let validations = SyncBox(0)
        let replacement = TestFixtures.photo(id: "saved", model: version,
            location: PlaceEmbedding(text: "Replacement", vector: TestFixtures.vector()))
        do {
            try await store.save(replacement) {
                validations.modify { $0 += 1 }
                if validations.value == 3 { throw AppFailure.permission }
            }
            XCTFail("Final validator must roll back")
        } catch AppFailure.permission { }
        await store.close()
        let saved = try await context.reader.searchRecords(modelVersion: version, accessibleIDs: ["saved"])
        let replacementPlace = try await context.reader.storedPlace(text: "Replacement", modelVersion: version)
        XCTAssertEqual(saved.first?.photo.location?.text, "Photo taken in Old.")
        XCTAssertNil(replacementPlace)
        XCTAssertEqual(validations.value, 3)
    }

    func testExactRemovalFinalValidatorRollsBackThenCountsActualSQLiteChanges() async throws {
        let context = try context([])
        try seed(context, [SyncRow("keep", label: "Keep"), SyncRow("remove", label: "Remove")])
        let store = SQLitePhotoStore(directory: context.directory)
        let validations = SyncBox(0)
        do {
            _ = try await store.remove(recordIDs: ["remove"]) {
                validations.modify { $0 += 1 }
                if validations.value == 3 { throw AppFailure.permission }
            }
            XCTFail("Final validator must roll back")
        } catch AppFailure.permission { }
        let rolledBack = try await context.reader.syncMetadata()
        let rolledBackPlace = try await context.reader.storedPlace(text: "Photo taken in Remove.", modelVersion: version)
        XCTAssertEqual(rolledBack.count, 2)
        XCTAssertNotNil(rolledBackPlace)
        let removed = try await store.remove(recordIDs: ["remove", "remove", "nonexistent"])
        XCTAssertEqual(removed, 1)
        let rows = try await context.reader.syncMetadata()
        let removedPlace = try await context.reader.storedPlace(text: "Photo taken in Remove.", modelVersion: version)
        XCTAssertEqual(Set(rows.keys), ["keep"])
        XCTAssertNil(removedPlace)
        await store.close()
    }

    func testEmptyOrMissingRemovalDoesNotCreateDatabaseOrPruneUnrelatedPlaces() async throws {
        let context = try context([])
        let store = SQLitePhotoStore(directory: context.directory)
        let empty = try await store.remove(recordIDs: [])
        let missing = try await store.remove(recordIDs: ["missing"])
        XCTAssertEqual(empty, 0)
        XCTAssertEqual(missing, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        try seed(context, [SyncRow("saved", label: "Orphan")])
        try sql(context, "DELETE FROM photos WHERE id = 'saved';")
        let zero = try await store.remove(recordIDs: ["missing"])
        let place = try await context.reader.storedPlace(text: "Photo taken in Orphan.", modelVersion: version)
        XCTAssertEqual(zero, 0)
        XCTAssertNotNil(place, "Only an actual removal prunes places")
        await store.close()
    }

    func testLegacySyncServiceDefaultsToNoSummaryWithoutRunningSync() async throws {
        let service: any PhotoSyncServicing = SyncWithoutSummary()
        let summary = try await service.currentSummary()
        XCTAssertNil(summary)
    }

    func testCurrentSummaryRequiresSharedCoordinatorBeforeAnyStorageOrModelRead() async throws {
        let context = try context([])
        let worker = PhotoIndexWorker(library: context.library, encoders: context.encoders, directory: context.directory)
        do { _ = try await worker.currentSummary(); XCTFail("Missing shared coordinator") }
        catch AppFailure.storage { }
        let inspections = await context.encoders.inspections
        XCTAssertEqual(inspections, 0)
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
    }

    func testCurrentSummaryForMissingIndexIsReadOnlyAndDoesNotEnumerateOrPrepare() async throws {
        let context = try context([SyncRow("not-indexed")])
        let result = try await context.worker.currentSummary()
        let summary = try XCTUnwrap(result)
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertTrue(summary.indexStatisticsKnown)
        XCTAssertFalse(summary.authorizedCountKnown, "No Photos enumeration means no known authorized count.")
        XCTAssertEqual(summary.modelVersion, version)
        XCTAssertFalse(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        XCTAssertTrue(context.library.requests.isEmpty)
        XCTAssertEqual(context.access.revision, 0)
        let inspections = await context.encoders.inspections
        let prepares = await context.encoders.prepareCalls
        let pools = await context.encoders.factoryCalls
        let texts = await context.encoders.texts
        XCTAssertEqual(inspections, 1)
        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(pools, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testCurrentSummaryCountsStoredActiveModelWithoutPruningDecodingOrOpeningOCR() async throws {
        let context = try context([])
        try seed(context, [SyncRow("saved", label: "Place"), SyncRow("also-saved")])
        try seed(context, [SyncRow("old", label: "Old")], model: "old-model")
        try sql(context, "UPDATE photos SET image_embedding = x'bad0'; UPDATE places SET embedding = x'bad1';")
        for table in ["photos", "places"] {
            for event in ["INSERT", "UPDATE", "DELETE"] {
                try sql(context, "CREATE TRIGGER forbid_\(table)_\(event) BEFORE \(event) ON \(table) BEGIN SELECT RAISE(ABORT, 'Unexpected write'); END;")
            }
        }
        // Poisoned optional OCR must not become a warning or a measured zero.
        let ocr = context.directory.appendingPathComponent("text-index.sqlite3")
        let poison = Data("TEST invalid optional OCR database".utf8)
        try poison.write(to: ocr)
        let metadataLoads = SyncBox(0)
        let metadata = PlacePackMetadata(version: resolver.version, coverageDescription: "TEST metadata only")
        let worker = PhotoIndexWorker(library: context.library, encoders: context.encoders, directory: context.directory,
            metadataLoader: { metadataLoads.modify { $0 += 1 }; return metadata },
            boundaryLoader: { XCTFail("Do not parse full geography"); return .unavailable("TEST") },
            indexAccess: context.access)
        let before = try disk(context)
        let result = try await worker.currentSummary()
        let summary = try XCTUnwrap(result)
        XCTAssertEqual(summary.indexedCount, 2, "Actual stored rows, even though this fake Photos scope is empty.")
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, version)
        XCTAssertEqual(summary.placesDescription, "TEST metadata only")
        XCTAssertFalse(summary.authorizedCountKnown)
        XCTAssertFalse(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        XCTAssertEqual(try disk(context), before)
        XCTAssertEqual(try Data(contentsOf: ocr), poison)
        XCTAssertEqual(metadataLoads.value, 1)
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.library.placeLookups, 0)
        XCTAssertEqual(context.access.revision, 0)
        let prepares = await context.encoders.prepareCalls
        let pools = await context.encoders.factoryCalls
        let texts = await context.encoders.texts
        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(pools, 0)
        XCTAssertTrue(texts.isEmpty)
    }

    func testCurrentSummarySeesCommittedPrefixDuringInitialSyncAndAfterCancellation() async throws {
        let hold = SyncHold()
        let context = try context([SyncRow("first"), SyncRow("second")], holds: [1: hold])
        let before = try await context.worker.currentSummary()
        XCTAssertEqual(before?.indexedCount, 0)
        let committed = SyncSignal()
        let task = start(context, holds: [hold], committed: { committed.send() })
        await hold.started.wait(1)
        await committed.wait(1)
        let enumerations = context.library.enumerations
        let prepares = await context.encoders.prepareCalls
        let pools = await context.encoders.factoryCalls
        let during = try await context.worker.currentSummary()
        XCTAssertEqual(during?.indexedCount, 1)
        XCTAssertEqual(during?.modelVersion, version)
        XCTAssertEqual(during?.authorizedCountKnown, false)
        XCTAssertEqual(context.library.enumerations, enumerations)
        task.cancel()
        await hold.cancelled.wait(1)
        hold.release.send()
        do { _ = try await task.value; XCTFail("Cancellation must not claim complete sync") }
        catch is CancellationError { }
        let after = try await context.worker.currentSummary()
        XCTAssertEqual(after?.indexedCount, 1)
        XCTAssertEqual(context.access.revision, 1)
        let laterPrepares = await context.encoders.prepareCalls
        let laterPools = await context.encoders.factoryCalls
        XCTAssertEqual(laterPrepares, prepares)
        XCTAssertEqual(laterPools, pools)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("text-index.sqlite3").path))
    }

    func testCurrentSummaryCanReenterCommittedCallbackAndReportsPruneThenSavedCounts() async throws {
        let context = try context([SyncRow("new")])
        try seed(context, [SyncRow("obsolete")])
        let snapshots = SyncBox<[Int]>([])
        let result = try await context.worker.synchronize(networkAllowed: false, progress: { _ in }, committed: {
            do {
                let value = try await context.worker.currentSummary()
                XCTAssertNotNil(value)
                if let value { snapshots.modify { $0.append(value.indexedCount) } }
            } catch { XCTFail("Committed callback must allow read-only actor reentry: \(type(of: error))") }
        })
        XCTAssertEqual(snapshots.value, [0, 1])
        XCTAssertEqual(result.summary.indexedCount, 1)
        let after = try await context.worker.currentSummary()
        XCTAssertEqual(after?.indexedCount, 1)
    }

    func testCurrentSummaryWaitsForWriterWithoutWritingAndRechecksEmptyScopeAccess() async throws {
        for change in [SyncLibrary.Change.denied, .limited, .generation] {
            let context = try context([])
            let writer = try await context.access.acquireWrite()
            let read = Task { try await context.worker.currentSummary() }
            addTeardownBlock { read.cancel(); writer.release(); _ = await read.result }
            await context.enqueued.wait(2) // Held writer and queued metadata reader.
            XCTAssertTrue(context.access.isWriting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
            context.library.change(change)
            writer.release()
            do { _ = try await read.value; XCTFail("Changed access cannot publish even an empty index") }
            catch AppFailure.permission { XCTAssertEqual(change, .denied) }
            catch AppFailure.photo { XCTAssertNotEqual(change, .denied) }
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.access.revision, 1, "Only the test writer changed revision.")
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        }
    }

    func testCurrentSummaryRejectsRevocationDuringInspectionEvenWithoutGeneration() async throws {
        for change in [SyncLibrary.Change.denied, .limited] {
            let context = try context([], generation: nil)
            let library = context.library
            await context.encoders.observeInspection { library.change(change) }
            do { _ = try await context.worker.currentSummary(); XCTFail("Changed authorization") }
            catch AppFailure.permission { XCTAssertEqual(change, .denied) }
            catch AppFailure.photo { XCTAssertEqual(change, .limited) }
            XCTAssertEqual(context.library.enumerations, 0)
            XCTAssertEqual(context.access.revision, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        }
    }

    func testCancelledQueuedCurrentSummaryDoesNotReturnZeroOrLeakReader() async throws {
        let context = try context([])
        let writer = try await context.access.acquireWrite()
        let read = Task { try await context.worker.currentSummary() }
        addTeardownBlock { read.cancel(); writer.release(); _ = await read.result }
        await context.enqueued.wait(2)
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancelled read must not publish zero") }
        catch is CancellationError { }
        XCTAssertTrue(context.access.isWriting, "Cancelling a queued read does not cancel another operation.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        writer.release()
        let next = try XCTUnwrap(context.access.tryRead())
        next.release()
        XCTAssertEqual(context.access.revision, 1)
    }

    func testCurrentSummaryDeniedDoesNotResolveDefaultDirectoryOrInspectModels() async throws {
        let context = try context([])
        context.library.change(.denied)
        let worker = PhotoIndexWorker(library: context.library, encoders: context.encoders,
            metadataLoader: { XCTFail("No default metadata read without access"); return PlacePackMetadata(version: "TEST", coverageDescription: "TEST") },
            boundaryLoader: { XCTFail("No default boundaries read"); return .unavailable("TEST") },
            indexAccess: context.access)
        do { _ = try await worker.currentSummary(); XCTFail("Denied, not a known zero") }
        catch AppFailure.permission { }
        let inspections = await context.encoders.inspections
        XCTAssertEqual(inspections, 0)
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertEqual(context.access.revision, 0)
    }

    func testCurrentSummaryStorageFailurePropagatesInsteadOfReturningKnownZero() async throws {
        let context = try context([])
        try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true)
        let corrupt = Data("TEST not an image-index database".utf8)
        try corrupt.write(to: context.directory.appendingPathComponent("index.sqlite3"))
        do { _ = try await context.worker.currentSummary(); XCTFail("Corrupt storage is not empty storage") }
        catch AppFailure.storage { }
        XCTAssertEqual(try disk(context), corrupt)
        XCTAssertEqual(context.access.revision, 0)
        XCTAssertEqual(context.library.enumerations, 0)
        XCTAssertFalse(context.access.isWriting)
    }
}

private struct SyncWithoutSummary: PhotoSyncServicing {
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        XCTFail("A summary request must not run synchronization")
        throw CancellationError()
    }
}

private struct SyncContext: Sendable {
    let worker: PhotoIndexWorker
    let library: SyncLibrary
    let encoders: SyncEncoders
    let access: IndexAccessCoordinator
    let directory: URL
    let reader: SQLitePhotoStore
    let enqueued: SyncSignal
}

private struct SyncRow: Sendable {
    let revision: PhotoRevision
    let label: String?
    let failure: Error?
    let networkOnly: Bool
    init(_ id: String, revision: Double = 123, creation: Double? = 100,
         label: String? = nil, failure: Error? = nil, networkOnly: Bool = false) {
        self.revision = PhotoRevision(id: id, modificationTime: revision, creationTime: creation)
        self.label = label
        self.failure = failure
        self.networkOnly = networkOnly
    }
}

private final class SyncLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    enum Change: Equatable { case generation, revision, creation, denied, limited }
    private struct State {
        var rows: [SyncRow]
        var readable = true
        var authorization = PHAuthorizationStatus.authorized.rawValue
        var generation: UInt64?
        var requests: [(String, Bool)] = []
        var enumerations = 0
        var places = 0
        var enumerationHook: (@Sendable () -> Void)?
        var writerAccess: IndexAccessCoordinator?
        var writerTarget = 0
        var writerChecks = 0
        var writerChange: Change?
    }
    private let state: SyncBox<State>
    private let preview: IndexingImage
    init(_ rows: [SyncRow], generation: UInt64?) throws {
        state = SyncBox(State(rows: rows, generation: generation))
        preview = IndexingImage(cgImage: try TestFixtures.image(width: 2, height: 2) { _, _ in (30, 90, 170) },
                                orientation: .up, source: .localPreview)
    }
    var canReadImages: Bool { state.value.readable }
    var authorizationStatusRawValue: Int? { state.value.authorization }
    var changeGeneration: UInt64? { state.value.generation }
    var requests: [(String, Bool)] { state.value.requests }
    var enumerations: Int { state.value.enumerations }
    var placeLookups: Int { state.value.places }
    var writerChecks: Int { state.value.writerChecks }
    var onEnumeration: (@Sendable () -> Void)? {
        get { state.value.enumerationHook }
        set { state.modify { $0.enumerationHook = newValue } }
    }
    func replace(_ rows: [SyncRow]) { state.modify { $0.rows = rows } }
    func change(_ change: Change) { state.modify { Self.change(change, state: &$0) } }
    private static func change(_ change: Change, state: inout State) {
        switch change {
        case .generation: state.generation = (state.generation ?? 0) + 1
        case .denied: state.readable = false; state.authorization = PHAuthorizationStatus.denied.rawValue
        case .limited: state.authorization = PHAuthorizationStatus.limited.rawValue
        case .revision, .creation:
            if let first = state.rows.first {
                state.rows[0] = SyncRow(first.revision.id,
                    revision: first.revision.modificationTime + (change == .revision ? 1 : 0),
                    creation: change == .creation ? 900 : first.revision.creationTime, label: first.label)
            }
        }
    }
    func changeOnWriterCheck(access: IndexAccessCoordinator, check: Int, change: Change) {
        state.modify { $0.writerAccess = access; $0.writerTarget = check; $0.writerChange = change }
    }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        state.modify { $0.enumerations += 1 }
        state.value.enumerationHook?()
        let value = state.value
        return value.readable ? value.rows.map(\.revision) : []
    }
    func currentRevision(id: String) -> PhotoRevision? {
        state.modify { state in
            if state.writerAccess?.isWriting == true {
                state.writerChecks += 1
                if state.writerChecks == state.writerTarget, let change = state.writerChange {
                    Self.change(change, state: &state)
                }
            }
        }
        let value = state.value
        return value.readable ? value.rows.first { $0.revision.id == id }?.revision : nil
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        state.modify { $0.places += 1 }
        return state.value.rows.first { $0.revision.id == id }?.label
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        state.modify { $0.requests.append((id, networkAllowed)) }
        guard let row = state.value.rows.first(where: { $0.revision.id == id }) else { throw AppFailure.permission }
        if let failure = row.failure { throw failure }
        if row.networkOnly && !networkAllowed { throw AppFailure.cloudOnly }
        return preview
    }
}

private actor SyncEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let holds: [Int: SyncHold]
    private let imageFailure: AppFailure?
    private let textFailure: AppFailure?
    private var textObserver: (@Sendable () -> Void)?
    private var inspectionObserver: (@Sendable () -> Void)?
    private(set) var inspections = 0
    private(set) var factoryCalls = 0
    private(set) var prepareCalls = 0
    private(set) var slots: [SyncImageEncoder] = []
    private(set) var texts: [String] = []
    init(holds: [Int: SyncHold], imageFailure: AppFailure?, textFailure: AppFailure?) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        self.holds = holds
        self.imageFailure = imageFailure
        self.textFailure = textFailure
    }
    func inspectResources() -> ModelManifest {
        inspections += 1
        inspectionObserver?()
        return manifest
    }
    func observeInspection(_ observer: @escaping @Sendable () -> Void) { inspectionObserver = observer }
    func prepare() -> ModelManifest { prepareCalls += 1; return manifest }
    func makeIndexingImageEncoders() -> [any PhotoImageEncoding] {
        factoryCalls += 1
        slots = (0..<20).map { SyncImageEncoder(hold: holds[$0], failure: imageFailure) }
        return slots.map { $0 as any PhotoImageEncoding }
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        XCTFail("No original-data encoding")
        throw AppFailure.modelContract("Unexpected API")
    }
    func image(preview: IndexingImage) throws -> [Float] {
        XCTFail("Use the independent image slots")
        throw AppFailure.modelContract("Unexpected API")
    }
    func observeText(_ observer: @escaping @Sendable () -> Void) { textObserver = observer }
    func text(_ text: String) throws -> [Float] {
        textObserver?()
        texts.append(text)
        if let textFailure { throw textFailure }
        XCTAssertTrue(text.hasPrefix("Photo taken in "), "No query/OCR encoding in auto sync")
        return TestFixtures.vector(axis: 2)
    }
}

private actor SyncImageEncoder: PhotoImageEncoding {
    let hold: SyncHold?
    let failure: AppFailure?
    private(set) var calls = 0
    init(hold: SyncHold?, failure: AppFailure?) { self.hold = hold; self.failure = failure }
    func image(preview: IndexingImage) async throws -> [Float] {
        calls += 1
        if let hold {
            await withTaskCancellationHandler {
                hold.started.send()
                await hold.release.wait(1)
            } onCancel: { hold.cancelled.send() }
            hold.finished.send() // Deliberately returns success even after cancellation.
        }
        if let failure { throw failure }
        return TestFixtures.vector()
    }
}

private final class SyncHold: Sendable {
    let started = SyncSignal()
    let cancelled = SyncSignal()
    let finished = SyncSignal()
    let release = SyncSignal()
}

private final class SyncBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func modify(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}

private final class SyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func send() {
        lock.lock()
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        lock.unlock()
        ready.forEach { $0.1.resume() }
    }
    func wait(_ target: Int) async { await withCheckedContinuation { install($0, target: target) } }
    private func install(_ continuation: CheckedContinuation<Void, Never>, target: Int) {
        lock.lock()
        if count >= target { lock.unlock(); continuation.resume() }
        else { waiters.append((target, continuation)); lock.unlock() }
    }
}