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
                         previewHolds: [String: PipelinePreviewHold] = [:],
                         imageHolds: [String: PipelineEncodeHold] = [:]) throws -> PipelineContext {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLitePhotoStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        let events = PipelineEvents()
        let library = try PipelineLibrary(rows, events: events, holds: previewHolds)
        let hold = PipelineEncodeHold()
        var holds = imageHolds
        // Select a snapshot identity, NOT the nondeterministic call arrival order.
        if let holdCall { holds[rows[holdCall - 1].revision.id] = hold }
        let encoders = try PipelineEncoders(ids: rows.map { $0.revision.id }, events: events,
                                             holds: holds, imageFailure: imageFailure, textFailure: textFailure)
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory, resolver: resolver)
        return PipelineContext(worker: worker, library: library, encoders: encoders, store: store,
                               directory: directory, events: events, gate: hold.release,
                               allGates: holds.values.map(\.release) + previewHolds.values.map(\.release),
                               encoderStarted: hold.started, encoderFinished: hold.finished, progress: PipelineProgress())
    }

    private func seed(_ context: PipelineContext, _ id: String, label: String? = nil,
                      geography: String? = nil, model: String? = nil) async throws {
        let place = label.map { PlaceEmbedding(text: "Photo taken in \($0).", vector: TestFixtures.vector(axis: 2)) }
        let photo = IndexedPhoto(id: id, modificationTime: 123, modelVersion: model ?? version,
                                 imageEmbedding: TestFixtures.vector(axis: 1), location: place, creationTime: 100)
        try await context.store.save(CachedPhoto(photo: photo, geographyVersion: geography ?? resolver.version))
    }

    private func start(_ context: PipelineContext, network: Bool = false,
                       committedIDs: [String]? = nil) -> Task<LibrarySummary, Error> {
        let cacheVersion = version
        let task = Task {
            defer { context.events.append("worker-return") }
            return try await context.worker.index(networkAllowed: network) { state in
                if let committedIDs {
                    do {
                        let saved = try await context.store.records(modelVersion: cacheVersion)
                        XCTAssertEqual(saved.map(\.photo.id), Array(committedIDs.prefix(state.completed)).sorted())
                        XCTAssertEqual(saved.count, state.encoded)
                        XCTAssertEqual(state.placeChecked, state.completed)
                        XCTAssertEqual(state.localPreviews + state.reducedPreviews + state.networkPreviews, saved.count)
                    } catch { XCTFail("Read committed synthetic prefix: \(error)") }
                }
                await context.progress.append(state)
                context.events.append("commit:\(state.completed)")
            }
        }
        // Even a throwing assertion/read must not leave a held child using a
        // temporary database after teardown. These gates open only AFTER the test.
        addTeardownBlock {
            task.cancel()
            for gate in context.allGates { await gate.open() }
            _ = await task.result
        }
        return task
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

    func testFourOverlappingRequestsAndEncodesUseOrderedRollingWindowNotBatchBarrier() async throws {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let previews = Dictionary(uniqueKeysWithValues: ids.prefix(4).map { ($0, PipelinePreviewHold()) })
        let images = Dictionary(uniqueKeysWithValues: ids.prefix(4).map { ($0, PipelineEncodeHold()) })
        let context = try context(ids.map { PipelineRow($0) }, previewHolds: previews, imageHolds: images)
        let fifthEncoded = expectation(description: "Fifth image encoded while second and third remain held")
        context.events.watch("encode-end:e", with: fifthEncoded)
        let task = start(context, committedIDs: ids)
        await fulfillment(of: ids.prefix(4).map { previews[$0]!.started }, timeout: 3)
        XCTAssertEqual(context.library.requests.sorted(), Array(ids.prefix(4)))
        XCTAssertEqual(context.events.activeRequests, 4)
        XCTAssertEqual(context.events.maximumRequests, 4)
        XCTAssertEqual(context.events.activeEncodes, 0)
        for id in ids.prefix(4) { await previews[id]!.release.open() }
        await fulfillment(of: ids.prefix(4).map { images[$0]!.started }, timeout: 3)
        XCTAssertEqual(context.events.activeEncodes, 4)
        XCTAssertEqual(context.events.maximumEncodes, 4)
        XCTAssertEqual(context.events.activeRequests, 0)
        let initialRows = try await context.store.records(modelVersion: version)
        XCTAssertTrue(initialRows.isEmpty)
        XCTAssertTrue(context.library.placeLookups.isEmpty)

        // A finished fourth child still owns a window position until ordered commit.
        await images["d"]!.release.open()
        await fulfillment(of: [images["d"]!.finished], timeout: 3)
        XCTAssertFalse(context.events.values.contains("request:e"))
        let speculativeRows = try await context.store.records(modelVersion: version)
        XCTAssertTrue(speculativeRows.isEmpty)
        await images["a"]!.release.open()
        await fulfillment(of: [fifthEncoded], timeout: 3)
        XCTAssertFalse(context.events.values.contains("encode-end:b"))
        XCTAssertFalse(context.events.values.contains("encode-end:c"))
        XCTAssertFalse(context.events.values.contains("request:f"))
        let prefix = try await context.store.records(modelVersion: version)
        let partial = await context.progress.last
        XCTAssertEqual(prefix.map(\.photo.id), ["a"])
        XCTAssertEqual(partial?.completed, 1)
        XCTAssertEqual(partial?.encoded, 1)
        XCTAssertEqual(context.library.placeLookups, ["a"])
        await images["c"]!.release.open()
        await fulfillment(of: [images["c"]!.finished], timeout: 3)
        XCTAssertFalse(context.events.values.contains("request:f"))
        await images["b"]!.release.open()
        let summary = try await task.value
        XCTAssertEqual(summary.indexedCount, 8)
        XCTAssertEqual(context.library.requests.sorted(), ids)
        XCTAssertTrue(context.library.networkFlags.allSatisfy { !$0 })
        XCTAssertEqual(context.library.placeLookups, ids)
        XCTAssertEqual(context.events.maximumUnencoded, 4)
        XCTAssertEqual(context.events.activeEncodes, 0)
        XCTAssertEqual(context.events.maximumEncodesPerSlot, [0: 1, 1: 1, 2: 1, 3: 1])
        let calls = await context.encoders.imageCalls
        let factoryCalls = await context.encoders.factoryCalls
        let workers = await context.encoders.workers
        XCTAssertEqual(calls.sorted(), ids)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(workers.count, 4)
        XCTAssertEqual(Set(workers.map { ObjectIdentifier($0) }).count, 4)
        for (slot, encoder) in workers.enumerated() {
            let slotCalls = await encoder.calls
            let peak = await encoder.peakActive
            XCTAssertEqual(slotCalls, [ids[slot], ids[slot + 4]])
            XCTAssertEqual(peak, 1, "One active image per slot, even across window rollover")
        }
        let events = context.events.values
        for (index, id) in ids.enumerated() where index >= 4 {
            let admission = try XCTUnwrap(events.firstIndex(of: "request:\(id)"))
            let commit = try XCTUnwrap(events.firstIndex(of: "commit:\(index - 3)"))
            XCTAssertLessThan(commit, admission, "Finished-but-uncommitted work must not admit a fifth item")
        }
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "encode-end:d")),
                          try XCTUnwrap(events.firstIndex(of: "encode-end:a")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "request:e")),
                          try XCTUnwrap(events.firstIndex(of: "encode-end:b")))
        XCTAssertLessThan(try XCTUnwrap(events.firstIndex(of: "request:e")),
                          try XCTUnwrap(events.firstIndex(of: "encode-end:c")))
        let states = await context.progress.states
        XCTAssertEqual(states.map(\.completed), Array(0...8))
        XCTAssertTrue(states.allSatisfy { $0.encoded == $0.completed && $0.localPreviews == $0.encoded })
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
        XCTAssertEqual(calls.sorted(), ids.sorted())
        XCTAssertEqual(context.library.placeLookups, ids, "Only commits, not child completion order, resolve places")
        let texts = await context.encoders.texts
        XCTAssertEqual(texts, ["Photo taken in Shared."])
    }

    func testCancellationCancelsAndAwaitsAllFourChildrenBeforeReturning() async throws {
        let ids = ["b", "c", "d"]
        let holds = Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelinePreviewHold()) })
        let context = try context([PipelineRow("a", place: .resolved("A"))] + ["b", "c", "d", "e"].map { PipelineRow($0) },
                                  holdCall: 1, previewHolds: holds)
        let task = start(context)
        await fulfillment(of: [context.encoderStarted] + ids.map { holds[$0]!.started }, timeout: 3)
        task.cancel()
        await fulfillment(of: ids.map { holds[$0]!.cancelled }, timeout: 3)
        await context.gate.open() // Intentionally delivers late encoder success.
        await fulfillment(of: [context.encoderFinished], timeout: 3)
        XCTAssertFalse(context.events.values.contains("worker-return"))
        for id in ids { await holds[id]!.release.open() }
        await expectCancellation(task)
        for id in ids { try assertDrained(context, heldID: id) }
        XCTAssertEqual(context.library.requests.sorted(), ["a", "b", "c", "d"])
        XCTAssertTrue(context.library.placeLookups.isEmpty)
        let rows = try await context.store.records(modelVersion: version)
        let final = await context.progress.last
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(final?.completed, 0)
        XCTAssertEqual(final?.placeChecked, 0)
        XCTAssertEqual(final?.placeUpdated, 0)
    }

    func testFatalImageTextModelAndStorageErrorsDrainWindowAndNeverSaveSpeculativeRows() async throws {
        // Real SQLite validation supplies the storage error, not a mock writer.
        let scenarios: [(AppFailure?, AppFailure?, Double)] = [
            (.modelContract("Synthetic contract"), nil, 100),
            (.modelsMissing("Synthetic missing"), nil, 100),
            (.storage("Synthetic image storage"), nil, 100),
            (.permission, nil, 100),
            (nil, .modelContract("Synthetic text contract"), 100),
            (nil, .modelsMissing("Synthetic missing text"), 100),
            (nil, nil, .infinity)
        ]
        for (imageFailure, textFailure, creationTime) in scenarios {
            let hold = PipelinePreviewHold()
            let context = try context([
                PipelineRow("a", place: .resolved("A"), creationTime: creationTime),
                PipelineRow("b"), PipelineRow("c"), PipelineRow("d"), PipelineRow("e")
            ], holdCall: 1, imageFailure: imageFailure, textFailure: textFailure, previewHolds: ["b": hold])
            let speculative = ["c", "d"].map { id -> XCTestExpectation in
                let ready = expectation(description: "Speculative \(id) finished successfully")
                context.events.watch("encode-end:\(id)", with: ready)
                return ready
            }
            let task = start(context)
            await fulfillment(of: [context.encoderStarted, hold.started] + speculative, timeout: 3)
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
            XCTAssertEqual(context.library.requests.sorted(), ["a", "b", "c", "d"])
            XCTAssertEqual(context.library.placeLookups, ["a"])
            let final = await context.progress.last
            let rows = try await context.store.records(modelVersion: version)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertEqual(final?.completed, 0)
            XCTAssertEqual(final?.encoded, 0)
            XCTAssertEqual(final?.placeChecked, 0)
            XCTAssertEqual(final?.placeUpdated, 0)
            XCTAssertEqual(final?.failed, 0)
            XCTAssertEqual(final?.localPreviews, 0)
            let place = try await context.store.place(text: "Photo taken in A.", modelVersion: version)
            XCTAssertNil(place, "A fatal head must not persist even its place vector")
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
        let ids = ["c", "d", "e"]
        let holds = Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelinePreviewHold()) })
        let context = try context(["a", "b", "c", "d", "e"].map { PipelineRow($0) },
                                  holdCall: 2, previewHolds: holds)
        let committed = expectation(description: "First row committed before cancellation")
        context.events.watch("commit:1", with: committed)
        let task = start(context)
        await fulfillment(of: [context.encoderStarted, committed] + ids.map { holds[$0]!.started }, timeout: 3)
        task.cancel()
        await fulfillment(of: ids.map { holds[$0]!.cancelled }, timeout: 3)
        await context.gate.open()
        for id in ids { await holds[id]!.release.open() }
        await expectCancellation(task)
        for id in ids { try assertDrained(context, heldID: id) }
        let prefix = try await context.store.records(modelVersion: version)
        let interrupted = await context.progress.last
        XCTAssertEqual(prefix.map(\.photo.id), ["a"])
        XCTAssertEqual(interrupted?.completed, 1)
        XCTAssertEqual(interrupted?.placeChecked, 1)
        let summary = try await context.worker.index(networkAllowed: false) { await context.progress.append($0) }
        let resumed = await context.progress.last
        let calls = await context.encoders.imageCalls
        XCTAssertEqual(summary.indexedCount, 5)
        XCTAssertEqual(resumed?.reused, 1)
        XCTAssertEqual(resumed?.encoded, 4)
        XCTAssertEqual(resumed?.placeChecked, 5)
        XCTAssertEqual(resumed?.localPreviews, 4)
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
        XCTAssertEqual(calls.sorted(), ["a", "b", "c"])
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

    func testAuthorizationLossStopsPlaceChecksAndDrainsAllFollowingRequests() async throws {
        let ids = ["b", "c", "d"]
        let holds = Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelinePreviewHold()) })
        let context = try context(["a", "b", "c", "d", "e"].map { PipelineRow($0) },
                                  holdCall: 1, previewHolds: holds)
        let task = start(context)
        await fulfillment(of: [context.encoderStarted] + ids.map { holds[$0]!.started }, timeout: 3)
        context.library.setReadable(false)
        await context.gate.open()
        await fulfillment(of: ids.map { holds[$0]!.cancelled }, timeout: 3)
        for id in ids { await holds[id]!.release.open() }
        do { _ = try await task.value; XCTFail("Expected lost authorization") }
        catch AppFailure.permission { }
        catch { XCTFail("Unexpected error: \(error)") }
        for id in ids { try assertDrained(context, heldID: id) }
        XCTAssertTrue(context.library.placeLookups.isEmpty, "No place/GPS read before a head result or after revocation")
        XCTAssertEqual(context.library.requests.sorted(), ["a", "b", "c", "d"])
        let final = await context.progress.last
        XCTAssertEqual(final?.completed, 0)
        XCTAssertEqual(final?.placeChecked, 0)
        let rows = try await context.store.records(modelVersion: version)
        XCTAssertTrue(rows.isEmpty)
    }

    func testFourCachedSlotsBackfillGeographyWithoutImagesAndEncodeSharedPlaceOnce() async throws {
        let ids = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let context = try context(ids.map { PipelineRow($0, place: .resolved("Shared")) })
        for id in ids { try await seed(context, id, geography: "old-pack") }
        let summary = try await start(context).value
        let final = await context.progress.last
        let calls = await context.encoders.imageCalls
        let texts = await context.encoders.texts
        let factoryCalls = await context.encoders.factoryCalls
        let workers = await context.encoders.workers
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(workers.count, 4)
        XCTAssertEqual(Set(workers.map { ObjectIdentifier($0) }).count, 4)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(context.library.requests.isEmpty)
        XCTAssertEqual(context.events.maximumEncodes, 0, "Cache-only slots must not invoke image inference")
        for worker in workers {
            let slotCalls = await worker.calls
            XCTAssertTrue(slotCalls.isEmpty)
        }
        XCTAssertEqual(texts, ["Photo taken in Shared."])
        XCTAssertEqual(context.library.placeLookups, ids)
        XCTAssertEqual(summary.indexedCount, 8)
        XCTAssertEqual(summary.locatedCount, 8)
        XCTAssertEqual(summary.modelVersion, version)
        XCTAssertEqual(summary.placesDescription, resolver.coverageDescription)
        XCTAssertEqual(final?.completed, 8)
        XCTAssertEqual(final?.reused, 8)
        XCTAssertEqual(final?.encoded, 0)
        XCTAssertEqual(final?.placeChecked, 8)
        XCTAssertEqual(final?.placeUpdated, 8)
        XCTAssertEqual(final?.gpsCount, 8)
        XCTAssertEqual(final?.failed, 0)
        XCTAssertEqual(final?.cloudSkipped, 0)
        XCTAssertEqual(final?.localPreviews, 0)
        XCTAssertEqual(final?.reducedPreviews, 0)
        XCTAssertEqual(final?.networkPreviews, 0)
        let rows = try await context.store.records(modelVersion: version)
        XCTAssertEqual(rows.map(\.photo.id), ids)
        for row in rows {
            XCTAssertEqual(row.photo.imageEmbedding, TestFixtures.vector(axis: 1))
            XCTAssertEqual(row.photo.location?.vector, TestFixtures.vector(axis: 3))
            XCTAssertEqual(row.geographyVersion, resolver.version)
        }
    }

    func testFourConcurrentImageResultsShareCentralTextCacheWithoutChangingModelOrPreviewPolicy() async throws {
        let ids = ["a", "b", "c", "d"]
        let holds = Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelineEncodeHold()) })
        let context = try context([
            PipelineRow("a", place: .resolved("Shared")),
            PipelineRow("b", place: .resolved("Shared"), source: .localReducedPreview),
            PipelineRow("c", place: .resolved("Shared"), source: .networkPreview),
            PipelineRow("d", place: .resolved("Shared")),
            PipelineRow("e", place: .resolved("Shared"))
        ], imageHolds: holds)
        let legacyVersion = "old-model|photokit-preview-v1"
        try await seed(context, "a", label: "Shared", model: legacyVersion)
        try await seed(context, "e", geography: "old-pack")
        let task = start(context, network: true)
        await fulfillment(of: ids.map { holds[$0]!.started }, timeout: 3)
        XCTAssertEqual(context.events.activeEncodes, 4)
        for id in ["d", "c", "b"] {
            await holds[id]!.release.open()
            await fulfillment(of: [holds[id]!.finished], timeout: 3)
        }
        let speculativeTexts = await context.encoders.texts
        XCTAssertTrue(speculativeTexts.isEmpty, "Children must not each encode the shared label")
        XCTAssertTrue(context.library.placeLookups.isEmpty)
        await holds["a"]!.release.open()
        let summary = try await task.value
        let final = await context.progress.last
        let texts = await context.encoders.texts
        let calls = await context.encoders.imageCalls
        let factoryCalls = await context.encoders.factoryCalls
        let workers = await context.encoders.workers
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(workers.count, 4)
        XCTAssertEqual(Set(workers.map { ObjectIdentifier($0) }).count, 4)
        XCTAssertEqual(texts, ["Photo taken in Shared."])
        XCTAssertEqual(calls.sorted(), ids)
        XCTAssertEqual(context.library.requests.sorted(), ids, "The old cached current-model image e must bypass PhotoKit")
        XCTAssertTrue(context.library.networkFlags.allSatisfy { $0 })
        XCTAssertEqual(summary.modelVersion, "test-model|photokit-preview-v1")
        XCTAssertEqual(summary.indexedCount, 5)
        XCTAssertEqual(summary.locatedCount, 5)
        XCTAssertEqual(final?.completed, 5)
        XCTAssertEqual(final?.encoded, 4)
        XCTAssertEqual(final?.reused, 1)
        XCTAssertEqual(final?.localPreviews, 2)
        XCTAssertEqual(final?.reducedPreviews, 1)
        XCTAssertEqual(final?.networkPreviews, 1)
        XCTAssertEqual(final?.placeChecked, 5)
        XCTAssertEqual(final?.placeUpdated, 4)
        XCTAssertEqual(final?.failed, 0)
        XCTAssertEqual(final?.cloudSkipped, 0)
        let rows = try await context.store.records(modelVersion: version)
        XCTAssertEqual(rows.map(\.photo.id), ids + ["e"])
        for row in rows {
            XCTAssertEqual(row.photo.imageEmbedding, TestFixtures.vector(axis: row.photo.id == "e" ? 1 : 0))
            XCTAssertEqual(row.photo.location?.vector, TestFixtures.vector(axis: 3))
            XCTAssertEqual(row.geographyVersion, resolver.version)
        }
        let oldPlace = try await context.store.place(text: "Photo taken in Shared.", modelVersion: legacyVersion)
        let currentPlace = try await context.store.place(text: "Photo taken in Shared.", modelVersion: version)
        XCTAssertNil(oldPlace)
        XCTAssertEqual(currentPlace, TestFixtures.vector(axis: 3))
    }

    func testCancellationDrainsFourPhotoRequestsBeforeSerializedRefreshAndSearch() async throws {
        try await assertSuccessorWaitsForCancelledWindow(holdingImages: false)
    }

    func testCancellationDrainsFourImageEncodesBeforeSerializedRefreshAndSearch() async throws {
        try await assertSuccessorWaitsForCancelledWindow(holdingImages: true)
    }

    private func assertSuccessorWaitsForCancelledWindow(holdingImages: Bool) async throws {
        let ids = ["a", "b", "c", "d"]
        let previews = holdingImages ? [:] : Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelinePreviewHold()) })
        let images = holdingImages ? Dictionary(uniqueKeysWithValues: ids.map { ($0, PipelineEncodeHold()) }) : [:]
        let context = try context((ids + ["e"]).map { PipelineRow($0, place: .resolved("Shared")) },
                                  previewHolds: previews, imageHolds: images)
        let started = holdingImages ? ids.map { images[$0]!.started } : ids.map { previews[$0]!.started }
        let cancelled = holdingImages ? ids.map { images[$0]!.cancelled } : ids.map { previews[$0]!.cancelled }
        let ended = ids.map { id -> XCTestExpectation in
            let expectation = XCTestExpectation(description: "Old child \(id) returned from its noninterruptible gate")
            context.events.watch("\(holdingImages ? "encode-end" : "request-end"):\(id)", with: expectation)
            return expectation
        }
        let task = start(context)
        await fulfillment(of: started, timeout: 3)
        XCTAssertEqual(context.library.requests.sorted(), ids)
        XCTAssertTrue(context.library.networkFlags.allSatisfy { !$0 })
        XCTAssertEqual(holdingImages ? context.events.activeEncodes : context.events.activeRequests, 4)
        let waiting = expectation(description: "Successor is waiting for the old index operation")
        context.events.watch("successor-waiting", with: waiting)
        // Match AppState's documented predecessor-await contract WITHOUT creating
        // a real PhotoLibraryClient. PhotoIndexWorker alone is a reentrant actor,
        // not a whole-job mutex. Both subsequent operations use the synthetic library.
        let successor = Task {
            context.events.append("successor-waiting")
            _ = await task.result
            context.events.append("successor-refresh")
            let refreshed = try await context.worker.refresh()
            context.events.append("successor-search")
            let searched = try await context.worker.search(text: "synthetic query", limit: 5, locationWeight: 0.6)
            return (refreshed, searched)
        }
        await fulfillment(of: [waiting], timeout: 3)
        task.cancel()
        await fulfillment(of: cancelled, timeout: 3)
        for (index, id) in ids.enumerated() {
            // Before EACH release, at least one old child is still unable to return.
            XCTAssertFalse(context.events.values.contains("worker-return"))
            XCTAssertFalse(context.events.values.contains("successor-refresh"))
            XCTAssertFalse(context.events.values.contains("successor-search"))
            XCTAssertEqual(context.events.values.filter { $0 == "enumerate" }.count, 1)
            XCTAssertEqual(context.events.values.filter { $0 == "prepare-model" }.count, 1)
            let texts = await context.encoders.texts
            XCTAssertTrue(texts.isEmpty)
            if holdingImages { await images[id]!.release.open() }
            else { await previews[id]!.release.open() }
            await fulfillment(of: [ended[index]], timeout: 3)
        }
        await expectCancellation(task)
        let (refreshed, searched) = try await successor.value
        XCTAssertEqual(refreshed.indexedCount, 0)
        XCTAssertTrue(searched.hits.isEmpty)
        XCTAssertEqual(searched.summary.indexedCount, 0)
        XCTAssertEqual(context.library.requests.sorted(), ids, "Cancelled window must never admit e")
        XCTAssertTrue(context.library.placeLookups.isEmpty)
        XCTAssertEqual(context.events.activeRequests, 0)
        XCTAssertEqual(context.events.activeEncodes, 0)
        let rows = try await context.store.records(modelVersion: version)
        let states = await context.progress.states
        let texts = await context.encoders.texts
        let factoryCalls = await context.encoders.factoryCalls
        XCTAssertTrue(rows.isEmpty)
        XCTAssertEqual(states, [IndexProgress(total: 5)])
        XCTAssertEqual(texts, ["synthetic query"])
        XCTAssertEqual(factoryCalls, 1, "Refresh and search must not create a new indexing pool")
        let events = context.events.values
        let returned = try XCTUnwrap(events.firstIndex(of: "worker-return"))
        let refresh = try XCTUnwrap(events.firstIndex(of: "successor-refresh"))
        let search = try XCTUnwrap(events.firstIndex(of: "successor-search"))
        XCTAssertLessThan(returned, refresh)
        XCTAssertLessThan(refresh, search)
        for id in ids {
            let cancel = try XCTUnwrap(events.firstIndex(of: "\(holdingImages ? "encode-cancel" : "cancel"):\(id)"))
            let end = try XCTUnwrap(events.firstIndex(of: "\(holdingImages ? "encode-end" : "request-end"):\(id)"))
            XCTAssertLessThan(cancel, end)
            XCTAssertLessThan(end, returned, "All four children must drain before the parent returns")
        }
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
    let allGates: [PipelineLatch]
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
    private(set) var states: [IndexProgress] = []
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
    let started = XCTestExpectation(description: "Window request started")
    let cancelled = XCTestExpectation(description: "Window request received cancellation")
    let release = PipelineLatch()
    private let lock = NSLock()
    private var used = false

    private func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }

    func wait(id: String, events: PipelineEvents) async throws {
        guard claim() else { return }
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

/// Noninterruptible image prediction: cancellation is observable but cannot open
/// the gate. Returning a late unit vector exercises the production cancellation check.
private final class PipelineEncodeHold: @unchecked Sendable {
    let started = XCTestExpectation(description: "Image encoder started")
    let finished = XCTestExpectation(description: "Image encoder finished")
    let cancelled = XCTestExpectation(description: "Image encoder received cancellation")
    let release = PipelineLatch()
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }

    func wait(id: String, events: PipelineEvents) async {
        await withTaskCancellationHandler(operation: {
            started.fulfill()
            await release.wait()
        }, onCancel: {
            events.append("encode-cancel:\(id)")
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
    private var encodes = 0
    private var maxEncodes = 0
    private var slots: [Int: Int] = [:]
    private var maxSlots: [Int: Int] = [:]

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var values: [String] { locked { log } }
    var activeRequests: Int { locked { requests } }
    var maximumRequests: Int { locked { maxRequests } }
    var maximumUnencoded: Int { locked { maxUnencoded } }
    var activeEncodes: Int { locked { encodes } }
    var maximumEncodes: Int { locked { maxEncodes } }
    var maximumEncodesPerSlot: [Int: Int] { locked { maxSlots } }
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
            let parts = event.split(separator: ":")
            if parts.count == 3, let slot = Int(parts[1]) {
                if parts[0] == "slot-start" {
                    encodes += 1
                    maxEncodes = max(maxEncodes, encodes)
                    slots[slot, default: 0] += 1
                    maxSlots[slot] = max(maxSlots[slot, default: 0], slots[slot, default: 0])
                } else if parts[0] == "slot-end" {
                    encodes -= 1
                    slots[slot, default: 0] -= 1
                }
            }
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
    private var networks: [Bool] = []
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
    var networkFlags: [Bool] { locked { networks } }
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
        events.append("enumerate")
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
    private func requestedRow(_ id: String, networkAllowed: Bool) throws -> PipelineRow {
        try locked {
            guard readable, let row = rows.first(where: { $0.revision.id == id }) else { throw AppFailure.permission }
            history.append(id)
            networks.append(networkAllowed)
            return row
        }
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        try Task.checkCancellation()
        let row = try requestedRow(id, networkAllowed: networkAllowed)
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
    private let holds: [String: PipelineEncodeHold]
    private let imageFailure: AppFailure?
    private let textFailure: AppFailure?
    private(set) var factoryCalls = 0
    private(set) var workers: [PipelineImageEncoder] = []
    private(set) var texts: [String] = []

    init(ids: [String], events: PipelineEvents, holds: [String: PipelineEncodeHold],
         imageFailure: AppFailure?, textFailure: AppFailure?) throws {
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        self.ids = ids
        self.events = events
        self.holds = holds
        self.imageFailure = imageFailure
        self.textFailure = textFailure
    }

    var imageCalls: [String] {
        events.values.filter { $0.hasPrefix("encode:") }.map { String($0.dropFirst("encode:".count)) }
    }

    func prepare() throws -> ModelManifest {
        events.append("prepare-model")
        try manifest.validate()
        return manifest
    }

    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        factoryCalls += 1
        // Deliberately do not use the protocol's [self, self, self, self] fallback.
        let made = (0..<4).map { slot in
            PipelineImageEncoder(slot: slot, ids: ids, events: events, holds: holds,
                                 headFailure: imageFailure)
        }
        workers = made
        return made.map { $0 as any PhotoImageEncoding }
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        XCTFail("Never use original data")
        throw AppFailure.modelContract("Unexpected data overload")
    }
    func image(preview: IndexingImage) throws -> [Float] {
        XCTFail("Index images must use factory actors, never the central text encoder")
        throw AppFailure.modelContract("Bypassed image factory")
    }
    func text(_ text: String) throws -> [Float] {
        events.append("text:\(text)")
        texts.append(text)
        if let textFailure { throw textFailure }
        return TestFixtures.vector(axis: text.hasPrefix("Photo taken in ") ? 3 : 0)
    }
}

/// Separate reentrant actors make accidental concurrent reuse of a slot visible:
/// the active count spans the await, rather than being hidden by a serial mock.
private actor PipelineImageEncoder: PhotoImageEncoding {
    private let slot: Int
    private let ids: [String]
    private let events: PipelineEvents
    private let holds: [String: PipelineEncodeHold]
    private let headFailure: AppFailure?
    private var active = 0
    private(set) var peakActive = 0
    private(set) var calls: [String] = []

    init(slot: Int, ids: [String], events: PipelineEvents, holds: [String: PipelineEncodeHold], headFailure: AppFailure?) {
        self.slot = slot
        self.ids = ids
        self.events = events
        self.holds = holds
        self.headFailure = headFailure
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        let index = preview.cgImage.width - 2
        guard ids.indices.contains(index) else { throw AppFailure.modelContract("Synthetic preview identity") }
        let id = ids[index]
        calls.append(id)
        active += 1
        peakActive = max(peakActive, active)
        let hold = holds[id]
        let held = hold?.claim() == true
        events.append("slot-start:\(slot):\(id)")
        events.append("encode:\(id)")
        defer {
            active -= 1
            events.append("slot-end:\(slot):\(id)")
            events.append("encode-end:\(id)")
            if held { hold?.finished.fulfill() }
        }
        if held { await hold?.wait(id: id, events: events) }
        // Only the head fails; later completed items really are successful speculation.
        if index == 0, let headFailure { throw headFailure }
        // Deliberate late success on cancellation: the worker must reject it.
        return TestFixtures.vector()
    }
}