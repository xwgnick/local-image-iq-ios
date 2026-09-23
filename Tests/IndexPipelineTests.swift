import Foundation
import CoreGraphics
import ImageIO
import Photos
import SQLite3
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic pixels/768-D vectors only. Latches establish ordering; no sleeps,
/// actual PhotoKit access, model loading or timing/speedup assumptions.
final class IndexPipelineTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic boundaries")

    private func context(_ rows: [PipelineRow], holdCall: Int? = nil,
                         imageFailure: AppFailure? = nil, textFailure: AppFailure? = nil,
                         previewHolds: [String: PipelinePreviewHold] = [:]) throws -> PipelineContext {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLitePhotoStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        let events = PipelineEvents()
        let library = try PipelineLibrary(rows, events: events, holds: previewHolds)
        let started = XCTestExpectation(description: "Held image encoder started")
        let finished = XCTestExpectation(description: "Held image encoder finished")
        // These expectations are explicitly awaited only when a call is held.
        let gate = PipelineLatch()
        let encoders = try PipelineEncoders(ids: rows.map { $0.revision.id }, events: events,
                                             holdCall: holdCall, started: started, finished: finished,
                                             gate: gate, imageFailure: imageFailure, textFailure: textFailure)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        return PipelineContext(worker: worker, library: library, encoders: encoders, store: store,
                               directory: directory, events: events, gate: gate,
                               encoderStarted: started, encoderFinished: finished, progress: PipelineProgress())
    }

    private func seed(_ context: PipelineContext, _ id: String, label: String? = nil,
                      geography: String? = nil, model: String? = nil) async throws {
        let place = label.map { PlaceEmbedding(text: "Photo taken in \($0).", vector: TestFixtures.vector(axis: 2)) }
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model ?? version,
                                 imageEmbedding: TestFixtures.vector(axis: 1), location: place, creationTime: 100)
        try await context.store.save(CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version))
    }

    private func start(_ context: PipelineContext, network: Bool = false) -> Task<LibrarySummary, Error> {
        Task {
            defer { context.events.append("worker-return") }
            return try await context.worker.index(networkAllowed: network) { await context.progress.append($0) }
        }
    }

    private func expectCancellation(_ task: Task<LibrarySummary, Error>,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line) }
    }

    private func assertDrained(_ context: PipelineContext, heldID: String = "b",
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let events = context.events.values
        let cancelled = try XCTUnwrap(events.firstIndex(of: "cancel:\(heldID)"), file: file, line: line)
        let finished = try XCTUnwrap(events.firstIndex(of: "request-end:\(heldID)"), file: file, line: line)
        let returned = try XCTUnwrap(events.firstIndex(of: "worker-return"), file: file, line: line)
        XCTAssertLessThan(cancelled, finished, file: file, line: line)
        XCTAssertLessThan(finished, returned, file: file, line: line)
        XCTAssertEqual(context.events.activeRequests, 0, file: file, line: line)
    }

    func testSecondPreviewStartsWhileFirstEncoderIsBlockedAndNeverRunsTwoAhead() async throws {
        let context = try context([PipelineRow("a"), PipelineRow("b"), PipelineRow("c"), PipelineRow("d")], holdCall: 1)
        let secondReady = expectation(description: "Second preview delivered")
        context.events.watch("preview:b", with: secondReady)
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, secondReady], timeout: 3)
        XCTAssertEqual(context.library.requests, ["a", "b"])
        XCTAssertFalse(context.events.values.contains("encode-end:a"))
        XCTAssertFalse(context.events.values.contains("request:c"))
        await context.gate.open()
        let summary = try await task.value
        XCTAssertEqual(summary.indexedCount, 4)
        XCTAssertEqual(context.library.requests, ["a", "b", "c", "d"])
        XCTAssertLessThanOrEqual(context.events.maximumRequests, 1)
        XCTAssertLessThanOrEqual(context.events.maximumUnencoded, 2, "Current pixels plus exactly one prepared following item")
        let calls = await context.encoders.imageCalls
        XCTAssertEqual(calls, ["a", "b", "c", "d"])
    }

    func testSnapshotCommitOrderAndProgressSeeOnlyPersistedRowsAndSources() async throws {
        let ids = ["c", "a", "b"] // Deliberately not SQLite's ORDER BY id.
        let context = try context([
            PipelineRow("c", place: .resolved("Shared")),
            PipelineRow("a", place: .noGPS, source: .localReducedPreview),
            PipelineRow("b", place: .resolved("Shared"), source: .networkPreview)
        ])
        let store = context.store
        let version = self.version
        let trace = context.progress
        let summary = try await context.worker.index(networkAllowed: true) { state in
            do {
                let saved = try await store.records(modelVersion: version)
                XCTAssertEqual(saved.map(\.photo.id), Array(ids.prefix(state.completed)).sorted())
                XCTAssertEqual(saved.count, state.encoded)
                XCTAssertEqual(state.localPreviews + state.reducedPreviews + state.networkPreviews, saved.count)
                XCTAssertEqual(state.placeChecked, state.completed)
                XCTAssertEqual(state.placeUpdated, saved.filter { $0.photo.location != nil }.count)
            } catch { XCTFail("Read committed synthetic rows: \(error)") }
            await trace.append(state)
        }
        let final = await trace.last
        XCTAssertEqual(summary.locatedCount, 2)
        XCTAssertEqual(final?.localPreviews, 1)
        XCTAssertEqual(final?.reducedPreviews, 1)
        XCTAssertEqual(final?.networkPreviews, 1)
        XCTAssertEqual(final?.placeUpdated, 2)
        let calls = await context.encoders.imageCalls
        XCTAssertEqual(calls, ids)
    }

    func testCancellationCancelsAndAwaitsLookaheadAcknowledgementBeforeReturning() async throws {
        let hold = PipelinePreviewHold()
        let context = try context([PipelineRow("a", place: .resolved("A")), PipelineRow("b"), PipelineRow("c")],
                                  holdCall: 1, previewHolds: ["b": hold])
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, hold.started], timeout: 3)
        task.cancel()
        await fulfillment(of: [hold.cancelled], timeout: 3)
        await context.gate.open() // Intentionally delivers late encoder success.
        await fulfillment(of: [context.encoderFinished], timeout: 3)
        XCTAssertFalse(context.events.values.contains("worker-return"))
        await hold.release.open()
        await expectCancellation(task)
        try assertDrained(context)
        XCTAssertEqual(context.library.requests, ["a", "b"])
        let rows = try await context.store.records(modelVersion: version)
        let final = await context.progress.last
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(final?.completed, 0)
        XCTAssertEqual(final?.placeChecked, 0)
        XCTAssertEqual(final?.placeUpdated, 0)
    }

    func testFatalImageTextModelAndStorageErrorsAllDrainLookaheadAndDoNotPublishProgress() async throws {
        // Real SQLite validation supplies the storage error, not a mock writer.
        let scenarios: [(AppFailure?, AppFailure?, Double)] = [
            (.modelContract("Synthetic contract"), nil, 100),
            (.modelsMissing("Synthetic missing"), nil, 100),
            (nil, .modelContract("Synthetic text contract"), 100),
            (nil, nil, .infinity)
        ]
        for (imageFailure, textFailure, creationTime) in scenarios {
            let hold = PipelinePreviewHold()
            let context = try context([
                PipelineRow("a", place: .resolved("A"), creationTime: creationTime), PipelineRow("b"), PipelineRow("c")
            ], holdCall: 1, imageFailure: imageFailure, textFailure: textFailure, previewHolds: ["b": hold])
            let task = start(context)
            await fulfillment(of: [context.encoderStarted, hold.started], timeout: 3)
            await context.gate.open()
            await fulfillment(of: [hold.cancelled], timeout: 3)
            XCTAssertFalse(context.events.values.contains("worker-return"))
            await hold.release.open()
            do { _ = try await task.value; XCTFail("Expected fatal error") }
            catch {
                if let expected = imageFailure ?? textFailure {
                    XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
                } else if case AppFailure.storage = error { }
                else { XCTFail("Expected SQLite metadata error, got \(error)") }
            }
            try assertDrained(context)
            XCTAssertEqual(context.library.requests, ["a", "b"])
            let final = await context.progress.last
            let rows = try await context.store.records(modelVersion: version)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(final?.completed, 0)
            XCTAssertEqual(final?.encoded, 0)
            XCTAssertEqual(final?.placeChecked, 0)
            XCTAssertEqual(final?.placeUpdated, 0)
        }
    }

    func testReusableRowsStillCheckPlacesWithoutPreviewEncodingOrPhotoWrites() async throws {
        let context = try context([PipelineRow("a", place: .resolved("A")), PipelineRow("b")])
        try await seed(context, "a", label: "A")
        try await seed(context, "b")
        try rejectPhotoInserts(directory: context.directory)
        let summary = try await start(context).value
        let final = await context.progress.last
        let calls = await context.encoders.imageCalls
        let texts = await context.encoders.texts
        XCTAssertEqual(summary.indexedCount, 2)
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertTrue(context.library.requests.isEmpty)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(context.library.placeLookups, ["a", "b"])
        XCTAssertEqual(final?.reused, 2)
        XCTAssertEqual(final?.placeChecked, 2)
        XCTAssertEqual(final?.gpsCount, 1)
        XCTAssertEqual(final?.noGPS, 1)
        XCTAssertEqual(final?.placeUpdated, 0)
        XCTAssertEqual(final?.encoded, 0)
    }

    func testGeographyVersionOnlyBackfillReusesExactImageAndStoredPlaceVector() async throws {
        let context = try context([PipelineRow("a", place: .resolved("Same label"))])
        try await seed(context, "a", label: "Same label", geography: "old-pack")
        let before = try await context.worker.refresh()
        XCTAssertEqual(before.locatedCount, 0, "Current geography still masks stale cached labels")
        let summary = try await start(context).value
        let saved = try await context.store.record(id: "a")
        let texts = await context.encoders.texts
        let final = await context.progress.last
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(saved?.photo.imageEmbedding, TestFixtures.vector(axis: 1))
        XCTAssertEqual(saved?.photo.location?.vector, TestFixtures.vector(axis: 2))
        XCTAssertEqual(saved?.geographyVersion, resolver.version)
        XCTAssertTrue(context.library.requests.isEmpty)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertEqual(final?.reused, 1)
        XCTAssertEqual(final?.placeUpdated, 1)
        XCTAssertEqual(final?.localPreviews, 0)
    }

    func testChangedLabelAndRemovedGPSUpdateWithoutRevisionOrImageChanges() async throws {
        let context = try context([PipelineRow("a", place: .resolved("New")), PipelineRow("b", place: .noGPS)])
        try await seed(context, "a", label: "Old")
        try await seed(context, "b", label: "Removed")
        let summary = try await start(context).value
        let a = try await context.store.record(id: "a")
        let b = try await context.store.record(id: "b")
        let final = await context.progress.last
        let texts = await context.encoders.texts
        XCTAssertEqual(a?.photo.location?.text, "Photo taken in New.")
        XCTAssertNil(b?.photo.location)
        for row in [a, b] {
            XCTAssertEqual(row?.photo.modificationTime, 123)
            XCTAssertEqual(row?.photo.imageEmbedding, TestFixtures.vector(axis: 1))
        }
        XCTAssertEqual(summary.locatedCount, 1)
        XCTAssertEqual(final?.reused, 2)
        XCTAssertEqual(final?.placeUpdated, 2)
        XCTAssertEqual(final?.noGPS, 1)
        XCTAssertEqual(texts, ["Photo taken in New."])
        XCTAssertTrue(context.library.requests.isEmpty)
    }

    func testAllPlaceCategoriesIncludeFailedImagesWithoutInventingMissingGPS() async throws {
        let context = try context([
            PipelineRow("resolved", place: .resolved("A")),
            PipelineRow("no-gps", place: .noGPS, source: .localReducedPreview),
            PipelineRow("no-pack", place: .noPack),
            PipelineRow("outside", place: .outsideCoverage),
            PipelineRow("unknown", place: .unavailable),
            PipelineRow("resolved-cloud", place: .resolved("Cloud"), failure: AppFailure.cloudOnly),
            PipelineRow("raw-cloud", place: .noPack, failure: NSError(domain: PHPhotosErrorDomain, code: 3164)),
            PipelineRow("resolved-failed", place: .resolved("Failed"), failure: NSError(domain: "SyntheticOther", code: 3164))
        ])
        let summary = try await start(context).value
        let last = await context.progress.last
        let final = try XCTUnwrap(last)
        XCTAssertEqual(final.completed, 8)
        XCTAssertEqual(final.encoded, 5)
        XCTAssertEqual(final.cloudSkipped, 2)
        XCTAssertEqual(final.failed, 1)
        XCTAssertEqual(final.placeChecked, 8)
        XCTAssertEqual(final.gpsCount, 6)
        XCTAssertEqual(final.placeResolved, 3)
        XCTAssertEqual(final.noGPS, 1)
        XCTAssertEqual(final.noPlacePack, 2)
        XCTAssertEqual(final.outsidePlaceCoverage, 1)
        XCTAssertEqual(final.placeUnavailable, 1)
        XCTAssertEqual(final.placeUpdated, 1)
        XCTAssertEqual(final.localPreviews, 4)
        XCTAssertEqual(final.reducedPreviews, 1)
        XCTAssertEqual(summary.locatedCount, 1, "Resolved labels are not committed embeddings when the image failed")
        XCTAssertEqual(context.library.placeLookups.count, 8)
    }

    func testNetworkAllowedCloudErrorsRemainFailuresWithCompletedPlaceChecks() async throws {
        let context = try context([
            PipelineRow("a", place: .noGPS, failure: AppFailure.cloudOnly),
            PipelineRow("b", place: .unavailable, failure: NSError(domain: PHPhotosErrorDomain, code: 3164))
        ])
        _ = try await start(context, network: true).value
        let final = await context.progress.last
        XCTAssertEqual(final?.failed, 2)
        XCTAssertEqual(final?.cloudSkipped, 0)
        XCTAssertEqual(final?.placeChecked, 2)
        XCTAssertEqual(final?.gpsCount, 0)
        XCTAssertEqual(final?.noGPS, 1)
        XCTAssertEqual(final?.placeUnavailable, 1)
        XCTAssertEqual(final?.encoded, 0)
    }

    func testCancelThenResumeReusesCommittedPrefixAndRechecksItsPlace() async throws {
        let hold = PipelinePreviewHold()
        let context = try context([PipelineRow("a"), PipelineRow("b"), PipelineRow("c")],
                                  holdCall: 2, previewHolds: ["c": hold])
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, hold.started], timeout: 3)
        task.cancel()
        await fulfillment(of: [hold.cancelled], timeout: 3)
        await context.gate.open()
        await hold.release.open()
        await expectCancellation(task)
        try assertDrained(context, heldID: "c")
        let prefix = try await context.store.records(modelVersion: version)
        let interrupted = await context.progress.last
        XCTAssertEqual(prefix.map(\.photo.id), ["a"])
        XCTAssertEqual(interrupted?.completed, 1)
        XCTAssertEqual(interrupted?.placeChecked, 1)
        let summary = try await context.worker.index(networkAllowed: false) { await context.progress.append($0) }
        let resumed = await context.progress.last
        let calls = await context.encoders.imageCalls
        XCTAssertEqual(summary.indexedCount, 3)
        XCTAssertEqual(resumed?.reused, 1)
        XCTAssertEqual(resumed?.encoded, 2)
        XCTAssertEqual(resumed?.placeChecked, 3)
        XCTAssertEqual(resumed?.localPreviews, 2)
        XCTAssertEqual(calls.filter { $0 == "a" }.count, 1)
        XCTAssertEqual(context.library.requests.filter { $0 == "a" }.count, 1)
        XCTAssertEqual(context.library.placeLookups.filter { $0 == "a" }.count, 2)
    }

    func testPreparedRevisionIsValidatedBeforeSaveAndDoesNotCountAStalePreview() async throws {
        let context = try context([PipelineRow("a"), PipelineRow("b", place: .resolved("B"))], holdCall: 1)
        let ready = expectation(description: "Following revision captured and preview ready")
        context.events.watch("preview:b", with: ready)
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, ready], timeout: 3)
        context.library.changeRevision(id: "b", to: 124)
        await context.gate.open()
        _ = try await task.value
        let rows = try await context.store.records(modelVersion: version)
        let final = await context.progress.last
        XCTAssertEqual(rows.map(\.photo.id), ["a"])
        XCTAssertEqual(final?.failed, 1)
        XCTAssertEqual(final?.encoded, 1)
        XCTAssertEqual(final?.localPreviews, 1)
        XCTAssertEqual(final?.placeChecked, 2)
        XCTAssertEqual(final?.placeResolved, 1)
        XCTAssertEqual(final?.placeUpdated, 0)
    }

    func testPlaceCacheUsesActiveModelVersionAndDeduplicatesLabelsAcrossScan() async throws {
        let context = try context([
            PipelineRow("a", place: .resolved("Shared")), PipelineRow("b", place: .resolved("Shared")),
            PipelineRow("c", place: .resolved("Shared"))
        ])
        try await seed(context, "a", label: "Shared", model: "old-model|photokit-preview-v1")
        _ = try await start(context).value
        let texts = await context.encoders.texts
        XCTAssertEqual(texts, ["Photo taken in Shared."], "Do not use the old-model place; encode the new text once")
        let active = try await context.store.place(text: "Photo taken in Shared.", modelVersion: version)
        XCTAssertEqual(active, TestFixtures.vector(axis: 3))
        // A later scan changes just one label to another already persisted label.
        // No additional image inference or text encoding is needed.
        context.library.changePlace(id: "c", to: .noGPS)
        _ = try await context.worker.index(networkAllowed: false) { _ in }
        context.library.changePlace(id: "c", to: .resolved("Shared"))
        _ = try await context.worker.index(networkAllowed: false) { _ in }
        let allTexts = await context.encoders.texts
        let calls = await context.encoders.imageCalls
        XCTAssertEqual(allTexts, texts)
        XCTAssertEqual(calls, ["a", "b", "c"])
        let c = try await context.store.record(id: "c")
        XCTAssertEqual(c?.photo.location?.vector, active)
    }

    func testFailedPlaceBackfillRetainsOldImageAndDoesNotPublishUncommittedCounters() async throws {
        let context = try context([PipelineRow("a", place: .resolved("New"))], textFailure: .modelsMissing("Text unavailable"))
        try await seed(context, "a", label: "Old", geography: "old-pack")
        do { _ = try await start(context).value; XCTFail("Expected text model error") }
        catch AppFailure.modelsMissing { }
        catch { XCTFail("Unexpected error: \(error)") }
        let saved = try await context.store.record(id: "a")
        let final = await context.progress.last
        XCTAssertEqual(saved?.photo.imageEmbedding, TestFixtures.vector(axis: 1))
        XCTAssertEqual(saved?.photo.location?.text, "Photo taken in Old.")
        XCTAssertEqual(saved?.geographyVersion, "old-pack")
        XCTAssertEqual(final?.completed, 0)
        XCTAssertEqual(final?.placeChecked, 0)
        XCTAssertEqual(final?.placeUpdated, 0)
        XCTAssertTrue(context.library.requests.isEmpty)
    }

    func testSearchAndRefreshDoNotRecomputeLocationObservations() async throws {
        let context = try context([PipelineRow("a", place: .resolved("A")), PipelineRow("b", place: .unavailable)])
        _ = try await start(context).value
        let before = context.library.placeLookups
        _ = try await context.worker.refresh()
        _ = try await context.worker.search(text: "synthetic query", limit: 2, locationWeight: 0.6)
        XCTAssertEqual(context.library.placeLookups, before)
        _ = try await context.worker.index(networkAllowed: false) { await context.progress.append($0) }
        let final = await context.progress.last
        XCTAssertEqual(context.library.placeLookups, ["a", "b", "a", "b"])
        XCTAssertEqual(final?.placeChecked, 2, "Counts reset each scan rather than accumulate")
        XCTAssertEqual(final?.reused, 2)
        XCTAssertEqual(final?.placeUnavailable, 1)
        XCTAssertEqual(final?.noGPS, 0)
    }

    func testAuthorizationLossStopsPlaceChecksAndDrainsFollowingRequest() async throws {
        let hold = PipelinePreviewHold()
        let context = try context([PipelineRow("a"), PipelineRow("b"), PipelineRow("c")],
                                  holdCall: 1, previewHolds: ["b": hold])
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, hold.started], timeout: 3)
        context.library.setReadable(false)
        await context.gate.open()
        await fulfillment(of: [hold.cancelled], timeout: 3)
        await hold.release.open()
        do { _ = try await task.value; XCTFail("Expected lost authorization") }
        catch AppFailure.permission { }
        catch { XCTFail("Unexpected error: \(error)") }
        try assertDrained(context)
        XCTAssertEqual(context.library.placeLookups, ["a"])
        XCTAssertEqual(context.library.requests, ["a", "b"])
        let final = await context.progress.last
        XCTAssertEqual(final?.completed, 0)
        XCTAssertEqual(final?.placeChecked, 0)
    }

    /// A trigger makes even an otherwise indistinguishable INSERT OR REPLACE
    /// observable. Only touches this test's temporary synthetic database.
    private func rejectPhotoInserts(directory: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                     &database, SQLITE_OPEN_READWRITE, nil)
        defer { if let database { sqlite3_close(database) } }
        guard result == SQLITE_OK, let database else { throw AppFailure.storage("Synthetic trigger connection") }
        let sql = "CREATE TRIGGER reject_photo_insert BEFORE INSERT ON photos BEGIN SELECT RAISE(ABORT, 'Unexpected photo write'); END;"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AppFailure.storage("Synthetic trigger installation")
        }
    }
}

private struct PipelineContext: Sendable {
    let worker: PhotoIndexWorker
    let library: PipelineLibrary
    let encoders: PipelineEncoders
    let store: SQLitePhotoStore
    let directory: URL
    let events: PipelineEvents
    let gate: PipelineLatch
    let encoderStarted: XCTestExpectation
    let encoderFinished: XCTestExpectation
    let progress: PipelineProgress
}

private struct PipelineRow: Sendable {
    var revision: PhotoRevision
    var place: PhotoPlaceResult
    let source: IndexingImage.Source
    let failure: Error?

    init(_ id: String, place: PhotoPlaceResult = .noGPS, source: IndexingImage.Source = .localPreview,
         creationTime: Double = 100, failure: Error? = nil) {
        revision = PhotoRevision(id: id, modificationTime: 123, creationTime: creationTime)
        self.place = place
        self.source = source
        self.failure = failure
    }
}

private actor PipelineProgress {
    private var states: [IndexProgress] = []
    func append(_ state: IndexProgress) { states.append(state) }
    var last: IndexProgress? { states.last }
}

/// Opening before waiting is safe, making tests independent of executor order.
private actor PipelineLatch {
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

private final class PipelinePreviewHold: @unchecked Sendable {
    let started = XCTestExpectation(description: "Lookahead request started")
    let cancelled = XCTestExpectation(description: "Lookahead received cancellation")
    let release = PipelineLatch()

    func wait(id: String, events: PipelineEvents) async throws {
        try await withTaskCancellationHandler(operation: {
            started.fulfill()
            // Cancellation deliberately does not resume this latch. The worker
            // must await the request's delayed acknowledgement, not just cancel.
            await release.wait()
            try Task.checkCancellation()
        }, onCancel: {
            events.append("cancel:\(id)")
            self.cancelled.fulfill()
        })
    }
}

private final class PipelineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var watchers: [String: XCTestExpectation] = [:]
    private var requests = 0
    private var maxRequests = 0
    private var unencoded = 0
    private var maxUnencoded = 0

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var values: [String] { locked { log } }
    var activeRequests: Int { locked { requests } }
    var maximumRequests: Int { locked { maxRequests } }
    var maximumUnencoded: Int { locked { maxUnencoded } }
    func watch(_ event: String, with expectation: XCTestExpectation) {
        let already = locked { () -> Bool in
            if log.contains(event) { return true }
            watchers[event] = expectation
            return false
        }
        if already { expectation.fulfill() }
    }
    func append(_ event: String) {
        let watcher = locked { () -> XCTestExpectation? in
            log.append(event)
            if event.hasPrefix("request:") { requests += 1; maxRequests = max(maxRequests, requests) }
            if event.hasPrefix("request-end:") { requests -= 1 }
            if event.hasPrefix("preview:") { unencoded += 1; maxUnencoded = max(maxUnencoded, unencoded) }
            if event.hasPrefix("encode-end:") { unencoded -= 1 }
            return watchers.removeValue(forKey: event)
        }
        watcher?.fulfill()
    }
}

private final class PipelineLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PipelineRow]
    private let previews: [String: IndexingImage]
    private let events: PipelineEvents
    private let holds: [String: PipelinePreviewHold]
    private var readable = true
    private var history: [String] = []
    private var places: [String] = []

    init(_ rows: [PipelineRow], events: PipelineEvents, holds: [String: PipelinePreviewHold]) throws {
        self.rows = rows
        self.events = events
        self.holds = holds
        var pixels: [String: IndexingImage] = [:]
        for (index, row) in rows.enumerated() {
            // Width is just a synthetic identity marker used by the test encoder.
            let image = try TestFixtures.image(width: index + 2, height: 2) { _, _ in (60, 110, 170) }
            pixels[row.revision.id] = IndexingImage(cgImage: image, orientation: .up, source: row.source)
        }
        previews = pixels
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    var canReadImages: Bool { locked { readable } }
    var requests: [String] { locked { history } }
    var placeLookups: [String] { locked { places } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func changePlace(id: String, to place: PhotoPlaceResult) {
        locked { if let index = rows.firstIndex(where: { $0.revision.id == id }) { rows[index].place = place } }
    }
    func changeRevision(id: String, to revision: Double) {
        locked {
            if let index = rows.firstIndex(where: { $0.revision.id == id }) {
                rows[index].revision = PhotoRevision(id: id, modificationTime: revision, creationTime: 100)
            }
        }
    }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        try Task.checkCancellation()
        return locked { readable ? rows.map(\.revision) : [] }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        locked { readable ? rows.first { $0.revision.id == id }?.revision : nil }
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        XCTFail("Worker must use placeResult once, not reread placeLabel")
        return nil
    }
    func placeResult(id: String, resolver: OfflinePlaceResolver) -> PhotoPlaceResult {
        locked {
            places.append(id)
            return readable ? (rows.first { $0.revision.id == id }?.place ?? .unavailable) : .unavailable
        }
    }
    private func requestedRow(_ id: String) throws -> PipelineRow {
        try locked {
            guard readable, let row = rows.first(where: { $0.revision.id == id }) else { throw AppFailure.permission }
            history.append(id)
            return row
        }
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        try Task.checkCancellation()
        let row = try requestedRow(id)
        events.append("request:\(id)")
        defer { events.append("request-end:\(id)") }
        if let hold = holds[id] { try await hold.wait(id: id, events: events) }
        try Task.checkCancellation()
        if let failure = row.failure { throw failure }
        guard let preview = previews[id] else { throw AppFailure.photo("Synthetic preview missing") }
        events.append("preview:\(id)")
        return preview
    }
}

private actor PipelineEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let ids: [String]
    private let events: PipelineEvents
    private let holdCall: Int?
    private let started: XCTestExpectation
    private let finished: XCTestExpectation
    private let gate: PipelineLatch
    private let imageFailure: AppFailure?
    private let textFailure: AppFailure?
    private(set) var imageCalls: [String] = []
    private(set) var texts: [String] = []

    init(ids: [String], events: PipelineEvents, holdCall: Int?, started: XCTestExpectation,
         finished: XCTestExpectation, gate: PipelineLatch, imageFailure: AppFailure?, textFailure: AppFailure?) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        self.ids = ids
        self.events = events
        self.holdCall = holdCall
        self.started = started
        self.finished = finished
        self.gate = gate
        self.imageFailure = imageFailure
        self.textFailure = textFailure
    }
    func prepare() throws -> ModelManifest { try manifest.validate(); return manifest }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        XCTFail("Never use original data")
        throw AppFailure.modelContract("Unexpected data overload")
    }
    func image(preview: IndexingImage) async throws -> [Float] {
        let index = preview.cgImage.width - 2
        guard ids.indices.contains(index) else { throw AppFailure.modelContract("Synthetic preview identity") }
        let id = ids[index]
        imageCalls.append(id)
        let held = imageCalls.count == holdCall
        events.append("encode:\(id)")
        defer {
            events.append("encode-end:\(id)")
            if held { finished.fulfill() }
        }
        if held { started.fulfill(); await gate.wait() }
        if let imageFailure { throw imageFailure }
        // Deliberate late success on cancellation: the worker must reject it.
        return TestFixtures.vector()
    }
    func text(_ text: String) throws -> [Float] {
        texts.append(text)
        if let textFailure { throw textFailure }
        return TestFixtures.vector(axis: text.hasPrefix("Photo taken in ") ? 3 : 0)
    }
}