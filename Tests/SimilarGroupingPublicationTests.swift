import CryptoKit
import Foundation
import ImageIO
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real service, SQLite metadata/vector reads and grouping arithmetic. Only the
/// photo metadata source and resource inspector are fake; no PhotoKit access.
final class SimilarGroupingPublicationTests: XCTestCase {
    private func photo(_ id: String, axis: Int = 0, vector: [Float]? = nil) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: 123,
                     modelVersion: IndexImagePolicy.cacheVersion(modelVersion: "test-model"),
                     imageEmbedding: vector ?? TestFixtures.vector(axis: axis), location: nil, creationTime: 100)
    }

    private func photos(count: Int) -> [IndexedPhoto] {
        var result: [IndexedPhoto] = []
        for index in 0..<count { result.append(photo("photo-\(index)")) }
        return result
    }

    private func revisions(_ photos: [IndexedPhoto]) -> [PhotoRevision] {
        var result: [PhotoRevision] = []
        for photo in photos {
            result.append(PhotoRevision(id: photo.id, modificationTime: photo.modificationTime,
                                        creationTime: photo.creationTime))
        }
        return result
    }

    private func context(photos: [IndexedPhoto]? = nil, accessible: [PhotoRevision]? = nil,
                         generation: UInt64? = 0) throws -> PublicationContext {
        let cached = photos ?? self.photos(count: 2)
        let directory = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        var rows: [CachedPhoto] = []
        for photo in cached { rows.append(CachedPhoto(photo: photo, geographyVersion: "unused")) }
        try TestFixtures.seedRawCache(rows, directory: directory)
        let library = PublicationBatchLibrary(accessible ?? revisions(cached), generation: generation)
        let encoders = try PublicationMetadataEncoders()
        let service = SimilarPhotoGroupingService(library: library, directory: directory, encoders: encoders)
        return PublicationContext(service: service, library: library, encoders: encoders, directory: directory)
    }

    private func disk(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var result: [String: Data] = [:]
        for file in files { result[file.lastPathComponent] = try Data(contentsOf: file) }
        return result
    }

    /// Explicit grouping may add only its completed cache. All existing files
    /// must remain byte-identical, with no source writes or leftover sidecars.
    private func assertOnlyDerivedCacheAdded(_ directory: URL, since before: [String: Data],
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let cacheName = SimilarGroupingCache.fileName
        XCTAssertEqual(cacheName, "similar-groups-v1.bin", file: file, line: line)
        XCTAssertNil(before[cacheName], "These fixtures start without a completed grouping cache.", file: file, line: line)
        let after = try disk(directory)
        XCTAssertEqual(after.filter { $0.key != cacheName }, before,
                       "Only the derived grouping cache may be added; every original byte must be unchanged.", file: file, line: line)
        let bytes = try XCTUnwrap(after[cacheName], "Successful fixture grouping must persist its completed cache.",
                                  file: file, line: line)
        XCTAssertTrue(bytes.starts(with: Data("bplist00".utf8)), file: file, line: line)
        let envelope = try PropertyListDecoder().decode(SimilarGroupingCacheEnvelope.self, from: bytes)
        XCTAssertEqual(envelope.magic, SimilarGroupingCacheEnvelope.magicValue, file: file, line: line)
        XCTAssertEqual(envelope.schema, 1, file: file, line: line)
        XCTAssertEqual(envelope.payloadSHA256, Data(SHA256.hash(data: envelope.payload)), file: file, line: line)
        for url in [directory, directory.appendingPathComponent(cacheName)] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                           true, file: file, line: line)
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication, file: file, line: line)
            #endif
        }
    }

    private func assertMetadataOnly(_ c: PublicationContext,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.inspections, 1, file: file, line: line)
        XCTAssertEqual(calls.forbidden, 0, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
        XCTAssertEqual(c.library.placeCalls, 0, file: file, line: line)
        XCTAssertEqual(c.library.singleReads, [], file: file, line: line)
    }

    private func expectFailure(_ operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected validation failure.", file: file, line: line) }
        catch { }
    }

    @MainActor
    func testMainActorPublicationValidates128ActualGroupedRowsOffMainWithExactlyOneBatch() async throws {
        let input = photos(count: 128)
        let expectedIDs = input.map(\.id).sorted()
        let c = try context(photos: input)
        let before = try disk(c.directory)
        let result = try await c.service.group(threshold: 0.96) { _ in }
        XCTAssertEqual(result.candidateCount, 128)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.photos.map(\.id), expectedIDs)
        XCTAssertEqual(result.groups.first?.minimumSimilarity, 1)
        XCTAssertEqual(result.threshold, 0.96)
        XCTAssertEqual(c.library.events, [.full, .full, .full])

        try await result.prepareForPublication()
        // Recorded in the synchronous, non-actor batch implementation reached
        // through the real result.validateAccess closure, not in this test actor.
        XCTAssertEqual(c.library.batchThreads, [false])
        XCTAssertEqual(c.library.events, [.full, .full, .full, .batch(expectedIDs)])
        XCTAssertTrue(Thread.isMainThread)
        try result.validatePublicationEpoch()
        XCTAssertEqual(c.library.events, [.full, .full, .full, .batch(expectedIDs)],
                       "The immediate MainActor fence must not fetch Photos again.")
        try assertOnlyDerivedCacheAdded(c.directory, since: before)
        await assertMetadataOnly(c)
    }

    func testOnlyReturnedGroupMembersAreBatchValidatedAndRequestedIDsAreDeduplicated() async throws {
        let input: [IndexedPhoto] = [photo("a"), photo("b"), photo("c", axis: 1), photo("d", axis: 1),
                                     photo("single", axis: 2), photo("stale", vector: [])]
        var accessible = revisions(input)
        accessible[5] = PhotoRevision(id: "stale", modificationTime: 123, creationTime: 101)
        accessible.append(PhotoRevision(id: "new", modificationTime: 123, creationTime: 100))
        let c = try context(photos: input, accessible: accessible, generation: nil)
        let before = try disk(c.directory)
        let result = try await c.service.group(threshold: 0.96) { _ in }
        XCTAssertEqual(result.candidateCount, 5)
        XCTAssertEqual(result.staleCount, 1, "Creation-stale malformed vectors must be excluded before decoding.")
        XCTAssertEqual(result.unindexedCount, 1)
        try await result.prepareForPublication()
        XCTAssertEqual(c.library.batchRequests, [["a", "b", "c", "d"]])
        XCTAssertEqual(c.library.events, [.full, .full, .full, .batch(["a", "b", "c", "d"]), .full],
                   "Nil-generation publication rechecks the full library after member validation succeeds.")

        c.library.setRevision("c", modification: 124, creation: 100)
        try result.validatePhotos(["b", "a", "b"])
        XCTAssertEqual(c.library.batchRequests, [["a", "b", "c", "d"], ["b", "a"]])
        for id in ["single", "stale", "new", "unknown", ""] {
            XCTAssertThrowsError(try result.validatePhotos(["a", id]))
        }
        try result.validatePhotos([])
        XCTAssertEqual(c.library.batchRequests.count, 2, "Reject invalid scope before any batch read.")
        XCTAssertThrowsError(try result.validateAccess(), "Full access still checks the changed, unselected group.")
        XCTAssertEqual(c.library.batchRequests.last, ["a", "b", "c", "d"])
        // Three grouping snapshots plus one successful publication snapshot;
        // the later changed member fails batch validation before another full read.
        XCTAssertEqual(c.library.enumerationCount, 4)
        try assertOnlyDerivedCacheAdded(c.directory, since: before)
        await assertMetadataOnly(c)
    }

    func testBatchRequiresExactCountAndIDSetWithoutDependingOnReturnOrder() async throws {
        let c = try context(photos: [photo("a"), photo("b")], generation: nil)
        let result = try await c.service.group(threshold: 0.96) { _ in }
        let a = PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)
        let b = PhotoRevision(id: "b", modificationTime: 123, creationTime: 100)
        let other = PhotoRevision(id: "not-requested", modificationTime: 123, creationTime: 100)
        let invalid: [[PhotoRevision]] = [[], [a], [a, a], [a, other], [a, b, other]]
        for reply in invalid {
            c.library.overrideBatch(reply)
            await expectFailure { try await result.prepareForPublication() }
            XCTAssertEqual(c.library.enumerationCount, 3, "Invalid batches fail before the global snapshot.")
        }
        c.library.overrideBatch([b, a])
        try await result.prepareForPublication()
        XCTAssertEqual(c.library.batchRequests.count, invalid.count + 1)
        for request in c.library.batchRequests { XCTAssertEqual(request, ["a", "b"]) }
        XCTAssertEqual(c.library.enumerationCount, 4, "Only the successful reversed batch reaches the global snapshot.")
        await assertMetadataOnly(c)
    }

    func testNilGenerationStillChecksFullModificationCreationAndMissingRevisions() async throws {
        let c = try context(photos: [photo("a"), photo("b")], generation: nil)
        let result = try await c.service.group(threshold: 0.96) { _ in }
        try await result.prepareForPublication()
        XCTAssertEqual(c.library.enumerationCount, 4, "Successful nil-generation publication adds one global snapshot.")
        let changes: [(modification: Double, creation: Double?)] = [(124, 100), (123, 101), (123, nil)]
        for change in changes {
            c.library.setRevision("a", modification: change.modification, creation: change.creation)
            await expectFailure { try await result.prepareForPublication() }
            XCTAssertEqual(c.library.enumerationCount, 4, "Changed member revisions fail before another global snapshot.")
        }
        c.library.setRevision("a", modification: 123, creation: 100)
        c.library.remove("b")
        await expectFailure { try await result.prepareForPublication() }
        XCTAssertEqual(c.library.batchRequests.count, 5)
        XCTAssertEqual(c.library.enumerationCount, 4, "Missing members also fail before another global snapshot.")
        await assertMetadataOnly(c)
    }

    func testEpochIsCheckedBeforeAndAfterBatchIncludingChangesInReadCallback() async throws {
        for change in PublicationEpochChange.allCases {
            for duringRead in [false, true] {
                let c = try context(generation: nil)
                let result = try await c.service.group(threshold: 0.96) { _ in }
                let library = c.library
                if duringRead {
                    library.afterBatchRead { library.changeEpoch(change) }
                } else {
                    library.changeEpoch(change)
                }
                await expectFailure { try await result.prepareForPublication() }
                XCTAssertThrowsError(try result.validatePhotos([]), "An empty selection must still check access.")
                XCTAssertThrowsError(try result.validatePublicationEpoch())
                XCTAssertEqual(library.batchRequests.count, duringRead ? 1 : 0)
                XCTAssertEqual(library.enumerationCount, 3)
                library.afterBatchRead(nil)
                await assertMetadataOnly(c)
            }
        }
    }

    @MainActor
    func testImmediateMainActorEpochFenceRejectsInvalidationAfterAsyncValidation() async throws {
        for change in PublicationEpochChange.allCases {
            let c = try context()
            let result = try await c.service.group(threshold: 0.96) { _ in }
            try await result.prepareForPublication()
            XCTAssertEqual(c.library.batchThreads, [false])
            let eventsBeforeFence = c.library.events
            c.library.changeEpoch(change)
            XCTAssertTrue(Thread.isMainThread)
            // Models the parent's final no-await fence, not a claim of testing
            // the UI/state agent's separate phase/token/foreground integration.
            var published = false
            do {
                try result.validatePublicationEpoch()
                published = true
                XCTFail("An invalidated result must not publish.")
            } catch { }
            XCTAssertFalse(published)
            XCTAssertEqual(c.library.events, eventsBeforeFence, "No second validateAccess or metadata fetch.")
            await assertMetadataOnly(c)
        }
    }

    func testFinalFullSnapshotStillDetectsUnindexedCreationChangeWithoutGeneration() async throws {
        let input = photos(count: 2)
        var accessible = revisions(input)
        accessible.append(PhotoRevision(id: "unindexed", modificationTime: 123, creationTime: 100))
        let c = try context(photos: input, accessible: accessible, generation: nil)
        let library = c.library
        let trace = PublicationProgressTrace()
        library.onEnumeration { number in
            if number == 3 { library.setRevision("unindexed", modification: 123, creation: 101) }
        }
        defer { library.onEnumeration(nil) }
        await expectFailure {
            _ = try await c.service.group(threshold: 0.96) { await trace.append($0) }
        }
        let states = await trace.values()
        XCTAssertEqual(states.last, SimilarPhotoGroupingProgress(total: 2, completed: 2, groupCount: 1))
        XCTAssertEqual(library.events, [.full, .full, .full])
        await assertMetadataOnly(c)
    }

    func testCancellationBeforePrepareSkipsValidationEntirely() async throws {
        let c = try context()
        let result = try await c.service.group(threshold: 0.96) { _ in }
        let gate = PublicationAsyncGate()
        let task = Task {
            await gate.block()
            try await result.prepareForPublication()
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("Cancelled preparation succeeded.") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error).") }
        XCTAssertEqual(c.library.events, [.full, .full, .full])
        await assertMetadataOnly(c)
    }

    func testCancellationDuringBatchOrLegacyValidationRejectsLateSuccess() async throws {
        let c = try context()
        let result = try await c.service.group(threshold: 0.96) { _ in }
        c.library.afterBatchRead { withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { try await result.prepareForPublication() }
        do { try await task.value; XCTFail("Cancelled batch returned publishable success.") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error).") }
        c.library.afterBatchRead(nil)
        XCTAssertEqual(c.library.batchRequests.count, 1)
        await assertMetadataOnly(c)

        // This legacy closure returns normally after cancelling its own task;
        // only prepareForPublication's post-validation cancellation check stops it.
        let probe = PublicationValidationProbe()
        let legacy = SimilarPhotoGroupingResult(groups: [], candidateCount: 0, staleCount: 0,
                                               unindexedCount: 0, threshold: 0.96,
                                               validateAccess: { try probe.validate(cancel: true) })
        let legacyTask = Task { try await legacy.prepareForPublication() }
        do { try await legacyTask.value; XCTFail("Late legacy success escaped cancellation.") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error).") }
        XCTAssertEqual(probe.threads, [false])
    }

    func testUnknownBatchFailureIsPropagatedWithoutPerIDOrFullSnapshotFallback() async throws {
        let c = try context()
        let result = try await c.service.group(threshold: 0.96) { _ in }
        c.library.afterBatchRead { throw PublicationTestFailure.unavailable }
        do {
            try await result.prepareForPublication()
            XCTFail("Batch failure must not become success or an empty result.")
        } catch {
            XCTAssertEqual(error as? PublicationTestFailure, .unavailable)
        }
        XCTAssertEqual(c.library.events, [.full, .full, .full, .batch(["photo-0", "photo-1"])])
        await assertMetadataOnly(c)
    }

    func testEmptyGroupsRemainValidWithoutAnyBatchOrAdditionalFullEnumeration() async throws {
        let inputs: [[IndexedPhoto]] = [[], [photo("single")]]
        for input in inputs {
            let c = try context(photos: input)
            let trace = PublicationProgressTrace()
            let result = try await c.service.group(threshold: 0.96) { await trace.append($0) }
            XCTAssertTrue(result.groups.isEmpty)
            XCTAssertEqual(result.candidateCount, input.count)
            XCTAssertEqual(result.staleCount, 0)
            XCTAssertEqual(result.unindexedCount, 0)
            try await result.prepareForPublication()
            try result.validatePublicationEpoch()
            try result.validatePhotos([])
            XCTAssertThrowsError(try result.validatePhotos(["single"]))
            XCTAssertEqual(c.library.events, [.full, .full, .full])
            let states = await trace.values()
            XCTAssertEqual(states.last, SimilarPhotoGroupingProgress(total: input.count, completed: input.count))
            XCTAssertEqual(states.last?.fraction, 1)
            if input.isEmpty { XCTAssertEqual(states, [SimilarPhotoGroupingProgress()]) }
            await assertMetadataOnly(c)
        }
    }

    @MainActor
    func testLegacyInitializerRunsOldClosureOnceOffMainAndDefaultEpochDoesNotRepeatIt() async throws {
        for fail in [false, true] {
            let probe = PublicationValidationProbe()
            // Explicitly synthetic compatibility coverage, not production access
            // validation. Older callers omit the appended epoch parameter.
            let legacy = SimilarPhotoGroupingResult(groups: [], candidateCount: 0, staleCount: 0,
                                                   unindexedCount: 0, threshold: 0.96,
                                                   validateAccess: { try probe.validate(fail: fail) })
            do {
                try await legacy.prepareForPublication()
                XCTAssertFalse(fail)
            } catch {
                XCTAssertTrue(fail)
                XCTAssertEqual(error as? PublicationTestFailure, .unavailable)
            }
            XCTAssertEqual(probe.threads, [false])
            XCTAssertTrue(Thread.isMainThread)
            try legacy.validatePublicationEpoch()
            XCTAssertEqual(probe.threads.count, 1)
        }
    }
}

private struct PublicationContext: Sendable {
    let service: SimilarPhotoGroupingService
    let library: PublicationBatchLibrary
    let encoders: PublicationMetadataEncoders
    let directory: URL
}

private enum PublicationEvent: Sendable, Equatable {
    case full, batch([String]), single(String)
}

private enum PublicationEpochChange: Sendable, CaseIterable {
    case permission, authorization, generation
}

private enum PublicationTestFailure: Error, Equatable { case unavailable }

/// Deliberately does not validate epochs itself, so service fences cannot be
/// accidentally tested by reproducing those guards in the injected fake.
private final class PublicationBatchLibrary: PhotoLibraryIndexing, PhotoRevisionBatchReading, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [PhotoRevision]
    private var readable = true
    private var authorization: Int? = 3
    private var generation: UInt64?
    private var recordedEvents: [PublicationEvent] = []
    private var recordedThreads: [Bool] = []
    private var enumerations = 0
    private var pixels = 0
    private var places = 0
    private var batchOverride: [PhotoRevision]?
    private var batchAction: (@Sendable () throws -> Void)?
    private var enumerationAction: (@Sendable (Int) -> Void)?

    init(_ revisions: [PhotoRevision], generation: UInt64?) {
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
    var events: [PublicationEvent] { locked { recordedEvents } }
    var batchThreads: [Bool] { locked { recordedThreads } }
    var enumerationCount: Int { locked { enumerations } }
    var pixelCalls: Int { locked { pixels } }
    var placeCalls: Int { locked { places } }
    var batchRequests: [[String]] {
        locked {
            recordedEvents.compactMap { event in
                if case let .batch(ids) = event { return ids }
                return nil
            }
        }
    }
    var singleReads: [String] {
        locked {
            recordedEvents.compactMap { event in
                if case let .single(id) = event { return id }
                return nil
            }
        }
    }

    func changeEpoch(_ change: PublicationEpochChange) {
        locked {
            switch change {
            case .permission: readable = false
            case .authorization: authorization = 4
            case .generation: generation = 1
            }
        }
    }
    func overrideBatch(_ revisions: [PhotoRevision]) { locked { batchOverride = revisions } }
    func afterBatchRead(_ action: (@Sendable () throws -> Void)?) { locked { batchAction = action } }
    func onEnumeration(_ action: (@Sendable (Int) -> Void)?) { locked { enumerationAction = action } }
    func setRevision(_ id: String, modification: Double, creation: Double?) {
        locked {
            if let index = revisions.firstIndex(where: { $0.id == id }) {
                revisions[index] = PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
            }
        }
    }
    func remove(_ id: String) { locked { revisions.removeAll { $0.id == id } } }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let (number, action) = locked {
            enumerations += 1
            recordedEvents.append(.full)
            return (enumerations, enumerationAction)
        }
        action?(number)
        return locked { revisions }
    }

    func currentRevisions(ids: [String]) throws -> [PhotoRevision] {
        // Synchronous, non-actor helper reached by production validateAccess.
        // All observed thread/call data is stored under the same lock.
        let (result, action) = locked {
            recordedEvents.append(.batch(ids))
            recordedThreads.append(Thread.isMainThread)
            let requested = Set(ids)
            let result = batchOverride ?? revisions.filter { requested.contains($0.id) }
            return (result, batchAction)
        }
        try action?() // May invalidate the epoch/cancel/throw after capturing valid metadata.
        return result
    }

    func currentRevision(id: String) -> PhotoRevision? {
        locked {
            recordedEvents.append(.single(id))
            return revisions.first { $0.id == id }
        }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { places += 1 }
        XCTFail("Publication must not resolve geography.")
        return nil
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixels += 1 }
        XCTFail("Publication must not request pixels.")
        throw PublicationTestFailure.unavailable
    }
}

private actor PublicationMetadataEncoders: PhotoEncoding {
    struct Calls: Sendable { var inspections = 0; var forbidden = 0 }
    private let manifest: ModelManifest
    private var count = Calls()

    init() throws { manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8)) }
    func calls() -> Calls { count }
    func inspectResources() throws -> ModelManifest { count.inspections += 1; return manifest }
    private func unexpected() -> PublicationTestFailure {
        count.forbidden += 1
        XCTFail("Only metadata inspection is allowed; no prepare, encoding or encoder factory.")
        return .unavailable
    }
    func prepare() throws -> ModelManifest { throw unexpected() }
    func image(preview: IndexingImage) throws -> [Float] { throw unexpected() }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] { throw unexpected() }
    func text(_ text: String) throws -> [Float] { throw unexpected() }
    func makeIndexingImageEncoders() throws -> [any PhotoImageEncoding] { throw unexpected() }
}

/// Must remain non-actor: assertions inspect the thread of the legacy validation
/// body, not an actor-isolated test helper accidentally running on MainActor.
private final class PublicationValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedThreads: [Bool] = []
    var threads: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedThreads
    }
    func validate(cancel: Bool = false, fail: Bool = false) throws {
        lock.lock()
        recordedThreads.append(Thread.isMainThread)
        lock.unlock()
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        if fail { throw PublicationTestFailure.unavailable }
    }
}

private actor PublicationProgressTrace {
    private var states: [SimilarPhotoGroupingProgress] = []
    func append(_ value: SimilarPhotoGroupingProgress) { states.append(value) }
    func values() -> [SimilarPhotoGroupingProgress] { states }
}

private actor PublicationAsyncGate {
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