import Foundation
import ImageIO
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real SQLite, synthetic rows and stubbed resource/warmup boundaries only.
/// No Photos authorization requests, model payloads, predictions or timed sleeps.
final class LaunchWorkerTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "TEST-launch-model")
    private let resolver = OfflinePlaceResolver.unavailable("TEST-launch-boundaries")

    func testStagesBracketActualEnumerationReconciliationAndWarmup() async throws {
        let context = try context([row("TEST-kept"), row("TEST-deleted")])
        context.library.replace([PhotoRevision(id: "TEST-kept", modificationTime: 123)])
        let version = version
        let geography = resolver.version

        let summary = try await context.worker.prepareForLaunch { stage in
            context.events.append(stage)
            do {
                let counts = try await context.store.counts(modelVersion: version, geographyVersion: geography)
                XCTAssertEqual(counts.indexed, stage == .checkingLibrary ? 2 : 1,
                               "Checking precedes pruning; preparing follows committed reconciliation.")
            } catch { XCTFail("Unable to inspect synthetic cache at stage: \(error)") }
        }
        context.events.append("returned")

        XCTAssertEqual(context.events.values, ["checking", "enumerate", "preparing", "prepare-start",
                                               "prepare-end", "enumerate", "returned"])
        XCTAssertEqual(summary.authorizedCount, 1)
        XCTAssertEqual(summary.indexedCount, 1)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(summary.modelVersion, version)
        XCTAssertNil(summary.modelIssue)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        let orphan = try await context.store.place(text: "TEST-deleted", modelVersion: version)
        XCTAssertNil(orphan)
        await assertCalls(context, inspect: 0, prepare: 1, enumerations: 2)
    }

    func testLaunchUsesMetadataCountsNotVectorValidationAndRefreshRemainsInspectionOnly() async throws {
        let context = try context([
            row("TEST-current"),
            row("TEST-zero-vector", image: [Float](repeating: 0, count: 768)),
            row("TEST-stale-geography", geography: "TEST-old-geography"),
            row("TEST-old-model", model: "TEST-old-model|TEST-old-policy"),
            row("TEST-old-policy", model: "TEST-launch-model|TEST-old-policy")
        ])
        let before = try await context.worker.refresh()
        await assertCalls(context, inspect: 1, prepare: 0, enumerations: 1)
        let launched = try await context.worker.prepareForLaunch { context.events.append($0) }
        await assertCalls(context, inspect: 1, prepare: 1, enumerations: 3)
        let foreground = try await context.worker.refresh()
        await assertCalls(context, inspect: 2, prepare: 1, enumerations: 4)

        for summary in [before, launched, foreground] {
            XCTAssertEqual(summary.authorizedCount, 5)
            XCTAssertEqual(summary.indexedCount, 3)
            XCTAssertEqual(summary.locatedCount, 2)
            XCTAssertEqual(summary.modelVersion, version)
            XCTAssertNil(summary.modelIssue)
        }
        // A successful warmup is NOT proof that all cached search vectors are valid.
        // The same real SQLite row must still fail the normal full-vector read.
        do {
            _ = try await context.store.records(modelVersion: version)
            XCTFail("Zero vectors must still fail full validation.")
        } catch AppFailure.modelContract { }
        catch { XCTFail("Unexpected validation error: \(error)") }
    }

    func testMissingAndCorruptModelsReturnInitialSnapshotIssueNotSuccessfulReadiness() async throws {
        for failure in [AppFailure.modelsMissing("TEST-missing"), .modelContract("TEST-corrupt")] {
            let hold = TESTLaunchHold()
            let context = try context([row("TEST-kept"), row("TEST-deleted")],
                                      outcome: .failure(failure), hold: hold)
            context.library.replace([PhotoRevision(id: "TEST-kept", modificationTime: 123)])
            let task = start(context, hold: hold)
            await fulfillment(of: [hold.started], timeout: 3)
            context.library.replace([], readable: false)
            await hold.release.open()
            let summary = try await task.value

            XCTAssertEqual(summary.authorizedCount, 1, "Failed warmup reports the initial snapshot only.")
            XCTAssertEqual(summary.indexedCount, 0)
            XCTAssertEqual(summary.locatedCount, 0)
            XCTAssertNil(summary.modelVersion)
            XCTAssertEqual(summary.modelIssue, failure.localizedDescription)
            XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
            let rows = try await context.store.records(modelVersion: version)
            let orphan = try await context.store.place(text: "TEST-deleted", modelVersion: version)
            XCTAssertEqual(rows.map(\.photo.id), ["TEST-kept"])
            XCTAssertNil(orphan, "Initial reconciliation still precedes failed warmup.")
            XCTAssertEqual(context.events.values, ["checking", "enumerate", "preparing", "prepare-start", "prepare-end"])
            await assertCalls(context, inspect: 0, prepare: 1, enumerations: 1)
        }
    }

    func testPreCancelledLaunchAndCancellationInsideEitherProgressStageStopBeforeNextWork() async throws {
        let targets: [LaunchStage?] = [nil, .checkingLibrary, .preparingSearch]
        for target in targets {
            let context = try context([row("TEST-kept"), row("TEST-deleted")])
            context.library.replace([PhotoRevision(id: "TEST-kept", modificationTime: 123)])
            let task = Task {
                if target == nil { withUnsafeCurrentTask { $0?.cancel() } }
                return try await context.worker.prepareForLaunch { stage in
                    context.events.append(stage)
                    if stage == target { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            await expectCancellation(task)
            let expected: [String]
            switch target {
            case nil: expected = []
            case .checkingLibrary: expected = ["checking"]
            case .preparingSearch: expected = ["checking", "enumerate", "preparing"]
            }
            XCTAssertEqual(context.events.values, expected)
            let rows = try await context.store.records(modelVersion: version)
            XCTAssertEqual(rows.count, target == .preparingSearch ? 1 : 2)
            await assertCalls(context, inspect: 0, prepare: 0, enumerations: target == .preparingSearch ? 1 : 0)
        }
    }

    func testCancelledWarmupCannotPublishLateSuccessOrLateModelError() async throws {
        let outcomes: [TESTLaunchEncoders.Outcome] = [.cancelled, .success, .failure(.modelContract("TEST-late-error"))]
        for outcome in outcomes {
            let hold = TESTLaunchHold()
            let context = try context([row("TEST-kept")], outcome: outcome, hold: hold)
            let task = start(context, hold: hold)
            await fulfillment(of: [hold.started], timeout: 3)
            context.library.replace([], readable: false)
            // Also test an encoder's CancellationError without cancelling the caller.
            if case .cancelled = outcome { } else { task.cancel() }
            await hold.release.open()
            await expectCancellation(task)

            let rows = try await context.store.records(modelVersion: version)
            XCTAssertEqual(rows.map(\.photo.id), ["TEST-kept"], "No second reconciliation after cancellation.")
            XCTAssertEqual(context.events.values, ["checking", "enumerate", "preparing", "prepare-start", "prepare-end"])
            await assertCalls(context, inspect: 0, prepare: 1, enumerations: 1)
        }
    }

    func testAuthorizationRevocationAndEditsDuringHeldWarmupAreReconciledBeforeSuccess() async throws {
        for revoked in [false, true] {
            let hold = TESTLaunchHold()
            let context = try context([row("TEST-kept"), row("TEST-edited"), row("TEST-deleted")], hold: hold)
            let task = start(context, hold: hold)
            await fulfillment(of: [hold.started], timeout: 3)
            let initial = try await context.store.records(modelVersion: version)
            XCTAssertEqual(initial.count, 3)
            context.library.replace([
                PhotoRevision(id: "TEST-kept", modificationTime: 123),
                PhotoRevision(id: "TEST-edited", modificationTime: 124),
                PhotoRevision(id: "TEST-added", modificationTime: 123)
            ], readable: !revoked)
            await hold.release.open()
            let summary = try await task.value

            XCTAssertEqual(summary.authorizedCount, revoked ? 0 : 3)
            XCTAssertEqual(summary.indexedCount, revoked ? 0 : 1)
            XCTAssertEqual(summary.locatedCount, revoked ? 0 : 1)
            XCTAssertEqual(summary.modelVersion, version)
            XCTAssertNil(summary.modelIssue)
            let rows = try await context.store.records(modelVersion: version)
            XCTAssertEqual(rows.map(\.photo.id), revoked ? [] : ["TEST-kept"])
            for label in revoked ? ["TEST-kept", "TEST-edited", "TEST-deleted"] : ["TEST-edited", "TEST-deleted"] {
                let orphan = try await context.store.place(text: label, modelVersion: version)
                XCTAssertNil(orphan)
            }
            XCTAssertEqual(context.events.values, ["checking", "enumerate", "preparing", "prepare-start", "prepare-end", "enumerate"])
            await assertCalls(context, inspect: 0, prepare: 1, enumerations: 2)
        }
    }

    func testInitiallyUnauthorizedLaunchPrunesCacheAndPreparesWithoutRequestingAccess() async throws {
        let context = try context([row("TEST-now-inaccessible")])
        context.library.replace([], readable: false)
        let summary = try await context.worker.prepareForLaunch { context.events.append($0) }

        XCTAssertEqual(summary.authorizedCount, 0)
        XCTAssertEqual(summary.indexedCount, 0)
        XCTAssertEqual(summary.locatedCount, 0)
        XCTAssertEqual(summary.modelVersion, version)
        XCTAssertNil(summary.modelIssue)
        let rows = try await context.store.records(modelVersion: version)
        let orphan = try await context.store.place(text: "TEST-now-inaccessible", modelVersion: version)
        XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(orphan)
        // The injected PhotoLibraryIndexing witness has no authorization-request API.
        XCTAssertFalse(context.library.canReadImages)
        XCTAssertEqual(context.events.values, ["checking", "enumerate", "preparing", "prepare-start", "prepare-end", "enumerate"])
        await assertCalls(context, inspect: 0, prepare: 1, enumerations: 2)
    }

    func testOldServiceUsesDefaultCheckingThenRefreshWithoutImplementingNewRequirement() async throws {
        let events = TESTLaunchEvents()
        let service: any PhotoWorkServicing = TESTLegacyLaunchService(events: events)
        let summary = try await service.prepareForLaunch { events.append($0) }
        XCTAssertEqual(events.values, ["checking", "legacy-refresh"])
        XCTAssertEqual(summary.authorizedCount, 7)
        XCTAssertEqual(summary.modelIssue, "TEST-legacy-summary")
        let task = Task {
            try await service.prepareForLaunch { stage in
                events.append(stage)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await expectCancellation(task)
        XCTAssertEqual(events.values, ["checking", "legacy-refresh", "checking"])
    }

    private func row(_ id: String, model: String? = nil, geography: String? = nil,
                     image: [Float] = TestFixtures.vector()) -> CachedPhoto {
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model ?? version,
                                 imageEmbedding: image,
                                 location: PlaceEmbedding(text: id, vector: TestFixtures.vector(axis: 1)), creationTime: 100)
        return CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version)
    }

    private func context(_ rows: [CachedPhoto], outcome: TESTLaunchEncoders.Outcome = .success,
                         hold: TESTLaunchHold? = nil) throws -> TESTLaunchContext {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLitePhotoStore(directory: directory, readOnly: true)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        try TestFixtures.seedRawCache(rows, directory: directory)
        let events = TESTLaunchEvents()
        let library = TESTLaunchLibrary(rows.map {
            PhotoRevision(id: $0.photo.id, modificationTime: $0.photo.modificationTime, creationTime: $0.photo.creationTime)
        }, events: events)
        let encoders = try TESTLaunchEncoders(events: events, outcome: outcome, hold: hold)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        return TESTLaunchContext(worker: worker, library: library, encoders: encoders, store: store, events: events)
    }

    private func start(_ context: TESTLaunchContext, hold: TESTLaunchHold) -> Task<LibrarySummary, Error> {
        let task = Task { try await context.worker.prepareForLaunch { context.events.append($0) } }
        addTeardownBlock {
            task.cancel()
            await hold.release.open()
            _ = await task.result
        }
        return task
    }

    private func expectCancellation(_ task: Task<LibrarySummary, Error>,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Cancelled launch returned a summary", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    private func assertCalls(_ context: TESTLaunchContext, inspect: Int, prepare: Int, enumerations: Int,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await context.encoders.calls
        XCTAssertEqual(calls, TESTLaunchEncoders.Calls(inspect: inspect, prepare: prepare), file: file, line: line)
        let events = context.events.values
        XCTAssertEqual(events.filter { $0 == "enumerate" }.count, enumerations, file: file, line: line)
        XCTAssertFalse(events.contains("preview-request"), file: file, line: line)
        XCTAssertFalse(events.contains("place-lookup"), file: file, line: line)
        XCTAssertFalse(events.contains("revision-lookup"), file: file, line: line)
    }
}

private struct TESTLaunchContext: Sendable {
    let worker: PhotoIndexWorker
    let library: TESTLaunchLibrary
    let encoders: TESTLaunchEncoders
    let store: SQLitePhotoStore
    let events: TESTLaunchEvents
}

private final class TESTLaunchEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
    func append(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(event)
    }
    func append(_ stage: LaunchStage) {
        switch stage {
        case .checkingLibrary: append("checking")
        case .preparingSearch: append("preparing")
        }
    }
}

/// Synchronous protocol witnesses use a lock, never held across an await.
/// Deliberately cannot request permission, register observers or construct Photos.
private final class TESTLaunchLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: [PhotoRevision]
    private var readable = true
    private let events: TESTLaunchEvents
    init(_ snapshot: [PhotoRevision], events: TESTLaunchEvents) {
        self.snapshot = snapshot
        self.events = events
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var canReadImages: Bool { locked { readable } }
    func replace(_ snapshot: [PhotoRevision], readable: Bool = true) {
        locked { self.snapshot = snapshot; self.readable = readable }
    }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        events.append("enumerate")
        return locked { readable ? snapshot : [] }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        events.append("revision-lookup")
        return locked { readable ? snapshot.first { $0.id == id } : nil }
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        events.append("place-lookup")
        return nil
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        events.append("preview-request")
        throw AppFailure.photo("TEST-unexpected-preview-request")
    }
}

private actor TESTLaunchGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Immutable references to a thread-safe XCTest expectation and an actor gate.
private final class TESTLaunchHold: @unchecked Sendable {
    let started = XCTestExpectation(description: "TEST warmup entered")
    let release = TESTLaunchGate()
}

private actor TESTLaunchEncoders: PhotoEncoding {
    enum Outcome: Sendable { case success, failure(AppFailure), cancelled }
    struct Calls: Sendable, Equatable {
        var inspect = 0
        var prepare = 0
        var factories = 0
        var dataImages = 0
        var previewImages = 0
        var text = 0
    }
    private let manifest: ModelManifest
    private let events: TESTLaunchEvents
    private let outcome: Outcome
    private let hold: TESTLaunchHold?
    private(set) var calls = Calls()
    init(events: TESTLaunchEvents, outcome: Outcome, hold: TESTLaunchHold?) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(
            TestFixtures.manifest.replacingOccurrences(of: "test-model", with: "TEST-launch-model").utf8))
        self.events = events
        self.outcome = outcome
        self.hold = hold
    }
    func inspectResources() async throws -> ModelManifest {
        calls.inspect += 1
        events.append("inspect")
        return manifest
    }
    func prepare() async throws -> ModelManifest {
        calls.prepare += 1
        events.append("prepare-start")
        defer { events.append("prepare-end") }
        if let hold {
            hold.started.fulfill()
            await hold.release.wait()
        }
        // Deliberately ignores caller cancellation to exercise the worker boundary.
        switch outcome {
        case .success: return manifest
        case .failure(let error): throw error
        case .cancelled: throw CancellationError()
        }
    }
    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        calls.factories += 1
        throw AppFailure.modelContract("TEST-unexpected-indexing-factory")
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float] {
        calls.dataImages += 1
        throw AppFailure.modelContract("TEST-unexpected-data-prediction")
    }
    func image(preview: IndexingImage) async throws -> [Float] {
        calls.previewImages += 1
        throw AppFailure.modelContract("TEST-unexpected-preview-prediction")
    }
    func text(_ text: String) async throws -> [Float] {
        calls.text += 1
        throw AppFailure.modelContract("TEST-unexpected-text-prediction")
    }
}

/// No prepareForLaunch witness: compilation itself exercises source compatibility.
private struct TESTLegacyLaunchService: PhotoWorkServicing {
    let events: TESTLaunchEvents
    func refresh() async throws -> LibrarySummary {
        events.append("legacy-refresh")
        return LibrarySummary(authorizedCount: 7, modelIssue: "TEST-legacy-summary")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw AppFailure.photo("TEST-unexpected-index")
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        throw AppFailure.photo("TEST-unexpected-search")
    }
    func clear() async throws -> LibrarySummary { throw AppFailure.photo("TEST-unexpected-clear") }
}