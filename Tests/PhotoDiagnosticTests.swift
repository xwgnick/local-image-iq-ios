import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

final class PhotoDiagnosticTests: XCTestCase {
    private let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    private let resolver = OfflinePlaceResolver.unavailable("Synthetic diagnostic boundaries.")

    private func makeContext(_ records: [DiagnosticRecord], encoders: DiagnosticEncoders? = nil) throws -> DiagnosticContext {
        let root = try TestFixtures.temporaryDirectory()
        // Deliberately do not create the cache directory: a read-only check must not do so either.
        let directory = root.appendingPathComponent("cache", isDirectory: true)
        let store = SQLitePhotoStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: root)
        }
        let library = DiagnosticLibrary(records)
        let encoder = try encoders ?? DiagnosticEncoders()
        let worker = PhotoIndexWorker(library: library, encoders: encoder, directory: directory, resolver: resolver)
        return DiagnosticContext(root: root, directory: directory, store: store,
                                 library: library, encoders: encoder, worker: worker)
    }

    private func row(_ id: String, image: [Float] = TestFixtures.vector(), revision: Double = 123,
                     model: String? = nil, place: PlaceEmbedding? = nil, geography: String? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision, modelVersion: model ?? cacheVersion,
                                        imageEmbedding: image, location: place, creationTime: 100),
                    geographyVersion: geography ?? resolver.version)
    }

    private func seed(_ context: DiagnosticContext, _ rows: [CachedPhoto]) async throws {
        do {
            for row in rows { try await context.store.save(row) }
        } catch {
            await context.store.close()
            throw error
        }
        // Hash only a committed, closed SQLite file, not a live transaction/journal.
        await context.store.close()
    }

    private func preview(source: IndexingImage.Source = .localReducedPreview,
                         orientation: CGImagePropertyOrientation = .leftMirrored,
                         requested: CGSize? = CGSize(width: 224, height: 398.4),
                         degraded: Bool? = false) throws -> IndexingImage {
        let pixels = try TestFixtures.image(width: 7, height: 3) { x, y in
            (UInt8(20 + x * 20), UInt8(30 + y * 50), 170)
        }
        return IndexingImage(cgImage: pixels, orientation: orientation, source: source,
                             requestedSize: requested, photokitDegraded: degraded)
    }

    private func assertRanks(_ report: PhotoDiagnosticReport, photos: [IndexedPhoto], fresh: [Float],
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let query = TestFixtures.vector()
        let cached = try VectorSearch.search(query: query, photos: photos, limit: photos.count,
                                              locationWeight: report.locationWeight)
        let replaced = photos.map { photo -> IndexedPhoto in
            guard photo.id == report.photoID else { return photo }
            return IndexedPhoto(id: photo.id, modificationTime: photo.modificationTime,
                                modelVersion: photo.modelVersion, imageEmbedding: fresh,
                                location: photo.location, creationTime: photo.creationTime)
        }
        let updated = try VectorSearch.search(query: query, photos: replaced, limit: replaced.count,
                                               locationWeight: report.locationWeight)
        XCTAssertEqual(report.galleryCount, photos.count, file: file, line: line)
        XCTAssertEqual(report.cachedRank, cached.firstIndex { $0.id == report.photoID }.map { $0 + 1 }, file: file, line: line)
        XCTAssertEqual(report.cachedScore, cached.first { $0.id == report.photoID }?.score, file: file, line: line)
        XCTAssertEqual(report.freshRank, updated.firstIndex { $0.id == report.photoID }.map { $0 + 1 }, file: file, line: line)
        XCTAssertEqual(report.freshScore, updated.first { $0.id == report.photoID }?.score, file: file, line: line)
        // Replacing only the target image cannot change another photo's score or place center.
        for hit in cached where hit.id != report.photoID {
            XCTAssertEqual(updated.first { $0.id == hit.id }?.score, hit.score, file: file, line: line)
        }
        if let old = photos.first(where: { $0.id == report.photoID }) {
            let cosine = try EmbeddingMath.dot(old.imageEmbedding, fresh)
            XCTAssertEqual(report.cachedFreshCosine, cosine, file: file, line: line)
        } else {
            XCTAssertNil(report.cachedFreshCosine, file: file, line: line)
        }
    }

    private func assertNoRanks(_ report: PhotoDiagnosticReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(report.cachedRank, file: file, line: line)
        XCTAssertNil(report.cachedScore, file: file, line: line)
        XCTAssertNil(report.freshRank, file: file, line: line)
        XCTAssertNil(report.freshScore, file: file, line: line)
        XCTAssertNil(report.cachedFreshCosine, file: file, line: line)
    }

    private func assertOffline(_ context: DiagnosticContext, count: Int = 1,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context.library.requests.count, count, file: file, line: line)
        XCTAssertTrue(context.library.requests.allSatisfy { !$0.networkAllowed }, file: file, line: line)
        XCTAssertEqual(context.library.placeLookups, 0, "Diagnostics must not regenerate place vectors.", file: file, line: line)
    }

    func testFullGalleryRanksBeyondTopTwelveUseExactCoreUTF8Ties() async throws {
        let image = try preview()
        let ids = (0..<20).map { String(format: "ahead-%02d", $0) } + ["Z", "a", "é", "中"]
        let rows = ids.map { row($0, image: TestFixtures.vector(axis: $0 == "é" ? 1 : 0)) }
        let context = try makeContext(ids.reversed().map { DiagnosticRecord($0, .preview(image)) })
        try await seed(context, rows)
        let report = try await context.worker.checkPhoto(id: "é", query: "query", locationWeight: 0.6)
        try assertRanks(report, photos: rows.map(\.photo), fresh: TestFixtures.vector())
        XCTAssertEqual(report.galleryCount, 24)
        XCTAssertEqual(report.cachedRank, 24)
        XCTAssertEqual(report.freshRank, 23, "UTF-8 order puts é before 中, not ahead of ASCII IDs.")
        XCTAssertEqual(report.cachedStatus, "current")
        XCTAssertEqual(report.modelVersion, cacheVersion)
        XCTAssertNil(report.freshIssue)
        assertOffline(context)
    }

    func testLocationWeightUsesDistinctPlaceCenterAndOnlyReplacesTargetImage() async throws {
        let negative = TestFixtures.vector().map { -$0 }
        let north = PlaceEmbedding(text: "Photo taken in North.", vector: TestFixtures.vector())
        let south = PlaceEmbedding(text: "Photo taken in South.", vector: negative)
        let rows = [row("target", image: TestFixtures.vector(axis: 1), place: north),
                    row("south-a", place: south), row("south-b", place: south), row("south-c", place: south),
                    row("unlocated")]
        let image = try preview()
        let encoder = try DiagnosticEncoders(fresh: negative)
        let context = try makeContext(rows.map { DiagnosticRecord($0.photo.id, .preview(image)) }, encoders: encoder)
        try await seed(context, rows)
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let weights: [Float] = [0, 0.6, 1]
        for weight in weights {
            let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: weight)
            try assertRanks(report, photos: rows.map(\.photo), fresh: negative)
            XCTAssertEqual(report.locationWeight, weight)
            if weight == 0.6 {
                XCTAssertEqual(report.cachedRank, 1)
                XCTAssertEqual(report.freshRank, 2)
                XCTAssertEqual(try XCTUnwrap(report.cachedScore), 0.6, accuracy: 0.000001)
                XCTAssertEqual(try XCTUnwrap(report.freshScore), 0.2, accuracy: 0.000001)
            }
        }
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
        let texts = await encoder.texts
        XCTAssertEqual(texts, ["query", "query", "query"])
        assertOffline(context, count: 3)
        XCTAssertEqual(context.library.requests.map(\.id), ["target", "target", "target"])
    }

    func testRealSQLiteBytesAndDirectoryStayIdenticalDuringAndAfterCheck() async throws {
        let started = expectation(description: "Fresh encoder reached after read-only snapshot")
        let encoder = try DiagnosticEncoders(started: started)
        let image = try preview()
        let context = try makeContext([DiagnosticRecord("target", .preview(image))], encoders: encoder)
        try await seed(context, [row("target", image: TestFixtures.vector(axis: 1))])
        let before = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(before.paths, ["cache", "cache/index.sqlite3"])
        let originalBytes = try Data(contentsOf: context.directory.appendingPathComponent("index.sqlite3"))
        XCTAssertFalse(originalBytes.isEmpty)
        let worker = context.worker
        let task = Task { try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6) }
        await fulfillment(of: [started], timeout: 3)
        // Release even if inspection fails, so no checked continuation is stranded.
        do {
            let during = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(during, before, "No WAL, SHM, journal, image, report, or embedding export.")
        } catch {
            await encoder.release()
            _ = try? await task.value
            throw error
        }
        await encoder.release()
        let report = try await task.value
        XCTAssertEqual(report.cachedFreshCosine, 0)
        let finalBytes = try Data(contentsOf: context.directory.appendingPathComponent("index.sqlite3"))
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(finalBytes, originalBytes)
        XCTAssertEqual(after, before, "SHA-256 and every relative path must remain identical.")
        assertOffline(context)
    }

    func testUnauthorizedAndStaleRowsAreFilteredInMemoryWithoutPruningPhotosOrPlaces() async throws {
        let image = try preview()
        let place = PlaceEmbedding(text: "Photo taken in Retained Place.", vector: TestFixtures.vector())
        let rows = [row("target", image: TestFixtures.vector(axis: 1)), row("peer"),
                    row("revoked", place: place), row("edited", place: place),
                    row("old-model", model: "older-model", place: place)]
        let context = try makeContext([DiagnosticRecord("target", .preview(image)), DiagnosticRecord("peer", .preview(image)),
                                       DiagnosticRecord("edited", .preview(image), revision: 124),
                                       DiagnosticRecord("old-model", .preview(image))])
        try await seed(context, rows)
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6)
        try assertRanks(report, photos: Array(rows.prefix(2)).map(\.photo), fresh: TestFixtures.vector())
        let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
        for original in rows {
            let retained = try await reader.record(id: original.photo.id)
            XCTAssertEqual(retained?.photo.modificationTime, original.photo.modificationTime)
            XCTAssertEqual(retained?.photo.modelVersion, original.photo.modelVersion)
            XCTAssertEqual(retained?.photo.imageEmbedding, original.photo.imageEmbedding)
            XCTAssertEqual(retained?.photo.location?.text, original.photo.location?.text)
        }
        for model in [cacheVersion, "older-model"] {
            let retained = try await reader.place(text: place.text, modelVersion: model)
            XCTAssertEqual(retained, place.vector)
        }
        await reader.close()
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
        assertOffline(context)
    }

    func testOldModelOldPolicyAndOldRevisionTargetsAreStaleAndNeverReinserted() async throws {
        let image = try preview()
        let staleRows = [row("target", model: "older-model"),
                         row("target", model: "test-model|photokit-preview-v0"),
                         row("target", revision: 122)]
        for stale in staleRows {
            let context = try makeContext([DiagnosticRecord("target", .preview(image)), DiagnosticRecord("peer", .preview(image))])
            try await seed(context, [stale, row("peer", image: TestFixtures.vector(axis: 1))])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
            XCTAssertEqual(report.cachedStatus, "stale")
            XCTAssertEqual(report.galleryCount, 1)
            assertNoRanks(report)
            XCTAssertEqual(report.pixelWidth, 7, "Fresh encoding still reports request metadata, without insertion.")
            XCTAssertNil(report.freshIssue)
            let previews = await context.encoders.previews
            XCTAssertEqual(previews.count, 1)
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
            assertOffline(context)
        }
    }

    func testMissingTargetIsNotInsertedIntoAnExistingComparisonGalleryOrSQLite() async throws {
        let image = try preview()
        let context = try makeContext([DiagnosticRecord("target", .preview(image)), DiagnosticRecord("peer", .preview(image))])
        try await seed(context, [row("peer", image: TestFixtures.vector(axis: 1))])
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
        XCTAssertEqual(report.cachedStatus, "missing")
        XCTAssertEqual(report.galleryCount, 1)
        assertNoRanks(report)
        XCTAssertNil(report.freshIssue)
        let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
        let missing = try await reader.record(id: "target")
        XCTAssertNil(missing)
        await reader.close()
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
        assertOffline(context)
    }

    func testMissingDatabaseCreatesNeitherDirectoryNorFile() async throws {
        let image = try preview()
        for directoryExists in [false, true] {
            let context = try makeContext([DiagnosticRecord("target", .preview(image))])
            if directoryExists { try FileManager.default.createDirectory(at: context.directory, withIntermediateDirectories: true) }
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6)
            XCTAssertEqual(report.cachedStatus, "missing")
            XCTAssertEqual(report.galleryCount, 0)
            assertNoRanks(report)
            XCTAssertNil(report.freshIssue)
            XCTAssertEqual(report.pixelHeight, 3)
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.appendingPathComponent("index.sqlite3").path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: context.directory.path), directoryExists)
            assertOffline(context)
        }
    }

    func testReportsRawPixelsRequestedSizeOrientationSourceAndOptionalDegradedFlag() async throws {
        let images = [try preview(source: .localReducedPreview, orientation: .leftMirrored,
                                  requested: CGSize(width: 224.4, height: 398.6), degraded: false),
                      try preview(source: .localPreview, orientation: .right, degraded: true),
                      try preview(source: .networkPreview, orientation: .downMirrored, requested: nil, degraded: nil)]
        // Contrasting source/flag combinations prove raw metadata is copied, not inferred.
        for image in images {
            let context = try makeContext([DiagnosticRecord("target", .preview(image))])
            try await seed(context, [row("target")])
            let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
            XCTAssertEqual(report.pixelWidth, 7, "Raw dimensions must not be swapped by EXIF orientation.")
            XCTAssertEqual(report.pixelHeight, 3)
            XCTAssertEqual(report.requestedWidth, image.requestedSize.map { Int($0.width.rounded()) })
            XCTAssertEqual(report.requestedHeight, image.requestedSize.map { Int($0.height.rounded()) })
            XCTAssertEqual(report.orientationRawValue, image.orientation.rawValue)
            XCTAssertEqual(report.source, image.source.rawValue)
            XCTAssertEqual(report.degraded, image.photokitDegraded)
            let delivered = await context.encoders.previews
            let encoded = try XCTUnwrap(delivered.first)
            XCTAssertTrue(encoded.cgImage === image.cgImage)
            XCTAssertEqual(encoded.requestedSize, image.requestedSize)
            XCTAssertEqual(encoded.orientation, image.orientation)
            XCTAssertEqual(encoded.photokitDegraded, image.photokitDegraded)
            let dataCalls = await context.encoders.dataCalls
            XCTAssertEqual(dataCalls, 0)
            assertOffline(context)
        }
    }

    func testQueryIsPassedByteForByteUnchangedWithoutAnyNetworkSettingOrPlaceEncoding() async throws {
        let image = try preview()
        let context = try makeContext([DiagnosticRecord("target", .preview(image))])
        context.library.setAuthorization(nil)
        try await seed(context, [row("target")])
        let query = " \tDog eat my apple pen  照片 e\u{301}\n"
        let report = try await context.worker.checkPhoto(id: "target", query: query, locationWeight: 0.6)
        let texts = await context.encoders.texts
        XCTAssertEqual(texts.map { Array($0.utf8) }, [Array(query.utf8)])
        XCTAssertEqual(Array(report.query.utf8), Array(query.utf8))
        XCTAssertEqual(report.photoID, "target")
        // There is no settings service in this fixture; the worker must force offline itself.
        assertOffline(context)
    }

    func testFreshPreviewAndEncodingFailuresKeepCachedRankAndReturnSanitizedIssue() async throws {
        let image = try preview()
        let sensitive = "TEST-PRIVATE /synthetic/private/photo.jpg asset-secret"
        let cases: [(DiagnosticRecord.Response, AppFailure?)] = [
            (.failure(NSError(domain: PHPhotosErrorDomain, code: 3164,
                              userInfo: [NSLocalizedDescriptionKey: sensitive])), nil),
            (.failure(AppFailure.cloudOnly), nil),
            (.failure(NSError(domain: "DiagnosticTests", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: sensitive])), nil),
            (.preview(image), .photo(sensitive))
        ]
        for (response, failure) in cases {
            let encoder = try DiagnosticEncoders(imageFailure: failure)
            let context = try makeContext([DiagnosticRecord("target", response)], encoders: encoder)
            try await seed(context, [row("target")])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
            XCTAssertEqual(report.cachedStatus, "current")
            XCTAssertEqual(report.galleryCount, 1)
            XCTAssertEqual(report.cachedRank, 1)
            XCTAssertEqual(report.cachedScore, 1)
            XCTAssertNil(report.freshRank)
            XCTAssertNil(report.freshScore)
            XCTAssertNil(report.cachedFreshCosine)
            let issue = try XCTUnwrap(report.freshIssue)
            XCTAssertFalse(issue.isEmpty)
            XCTAssertFalse(issue.contains("TEST-PRIVATE"))
            XCTAssertFalse(issue.contains("asset-secret"))
            XCTAssertFalse(issue.contains("/synthetic/private"))
            if failure != nil {
                XCTAssertEqual(report.pixelWidth, 7)
                XCTAssertEqual(report.degraded, false)
            } else {
                XCTAssertNil(report.pixelWidth)
                XCTAssertNil(report.requestedWidth)
                XCTAssertNil(report.orientationRawValue)
                XCTAssertNil(report.source)
                XCTAssertNil(report.degraded)
            }
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
            assertOffline(context)
        }
    }

    func testPermissionAndModelFailuresAbortInsteadOfPublishingPartialReport() async throws {
        let image = try preview()
        let failures: [AppFailure] = [.permission, .modelContract("Synthetic mismatch"), .modelsMissing("Synthetic missing model")]
        for failure in failures {
            let encoder = try DiagnosticEncoders(imageFailure: failure)
            let context = try makeContext([DiagnosticRecord("target", .preview(image))], encoders: encoder)
            try await seed(context, [row("target")])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            do {
                _ = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
                XCTFail("Fatal permission/model failures must not become a freshIssue report.")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription) }
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
        }
    }

    func testAlreadyCancelledCheckDoesNoEncoderOrPreviewWorkAndCreatesNothing() async throws {
        let context = try makeContext([DiagnosticRecord("target", .preview(try preview()))])
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let worker = context.worker
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation, not a report.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let prepareCalls = await context.encoders.prepareCalls
        let texts = await context.encoders.texts
        let previews = await context.encoders.previews
        XCTAssertEqual(prepareCalls, 0)
        XCTAssertTrue(texts.isEmpty)
        XCTAssertTrue(previews.isEmpty)
        assertOffline(context, count: 0)
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
    }

    func testCancellationRejectsLateEncoderSuccessAndRecoverableFailure() async throws {
        let failures: [AppFailure?] = [nil, .photo("Late synthetic encoding failure")]
        for failure in failures {
            let started = expectation(description: "Fresh encoding suspended")
            let encoder = try DiagnosticEncoders(imageFailure: failure, started: started)
            let context = try makeContext([DiagnosticRecord("target", .preview(try preview()))], encoders: encoder)
            try await seed(context, [row("target")])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let worker = context.worker
            let task = Task { try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6) }
            await fulfillment(of: [started], timeout: 3)
            task.cancel()
            await encoder.release()
            do { _ = try await task.value; XCTFail("A late result must not escape cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
        }
    }

    func testSelectedRevisionChangeRejectsPublicationEvenBeforeEnumerationChanges() async throws {
        for updateSnapshot in [false, true] {
            let started = expectation(description: "Selected photo encoding suspended")
            let encoder = try DiagnosticEncoders(started: started)
            let image = try preview()
            let context = try makeContext([DiagnosticRecord("target", .preview(image))], encoders: encoder)
            try await seed(context, [row("target")])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let worker = context.worker
            let task = Task { try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0) }
            await fulfillment(of: [started], timeout: 3)
            if updateSnapshot {
                context.library.replace([DiagnosticRecord("target", .preview(image), revision: 124)])
            } else {
                context.library.overrideCurrent(PhotoRevision(id: "target", modificationTime: 124, creationTime: 100))
            }
            await encoder.release()
            do { _ = try await task.value; XCTFail("Changed selected revision must invalidate both ranks.") }
            catch AppFailure.photo { }
            catch { XCTFail("Unexpected error: \(error)") }
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before, "Reject publication without reconciling the stale row.")
        }
    }

    func testAuthorizationStatusChangeRejectsPublicationWithIdenticalReadableIDs() async throws {
        let started = expectation(description: "Encoding suspended before authorization transition")
        let encoder = try DiagnosticEncoders(started: started)
        let context = try makeContext([DiagnosticRecord("target", .preview(try preview()))], encoders: encoder)
        try await seed(context, [row("target")])
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let worker = context.worker
        let task = Task { try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6) }
        await fulfillment(of: [started], timeout: 3)
        context.library.setAuthorization(PHAuthorizationStatus.limited.rawValue)
        await encoder.release()
        do { _ = try await task.value; XCTFail("Full-to-limited transition must invalidate even identical IDs.") }
        catch AppFailure.photo { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(context.library.canReadImages)
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
    }

    func testOtherLibraryChangesAndRevokedAccessRejectPublicationWithoutPruning() async throws {
        let image = try preview()
        for change in 0..<3 {
            let started = expectation(description: "Encoding suspended before library change")
            // Exercise validation after both encoder success and a recoverable fresh failure.
            let encoder = try DiagnosticEncoders(imageFailure: change == 1 ? .photo("Late failure") : nil, started: started)
            let context = try makeContext([DiagnosticRecord("target", .preview(image)), DiagnosticRecord("peer", .preview(image))],
                                          encoders: encoder)
            try await seed(context, [row("target"), row("peer")])
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let worker = context.worker
            let task = Task { try await worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6) }
            await fulfillment(of: [started], timeout: 3)
            switch change {
            case 0: context.library.replace([DiagnosticRecord("target", .preview(image))])
            case 1: context.library.replace([DiagnosticRecord("target", .preview(image)),
                                             DiagnosticRecord("peer", .preview(image), revision: 124)])
            default: context.library.setReadable(false)
            }
            await encoder.release()
            do { _ = try await task.value; XCTFail("Do not publish scores centered on a changed authorized gallery.") }
            catch AppFailure.permission { XCTAssertEqual(change, 2) }
            catch AppFailure.photo { XCTAssertNotEqual(change, 2) }
            catch { XCTFail("Unexpected error: \(error)") }
            let after = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(after, before)
        }
    }

    func testReadOnlyConnectionRejectsSaveReconcileAndClearWithoutChangingOrCreatingFiles() async throws {
        for existing in [false, true] {
            let context = try makeContext([])
            let original = row("retained", place: PlaceEmbedding(text: "Photo taken in Kept Place.", vector: TestFixtures.vector()))
            if existing { try await seed(context, [original]) }
            let before = try DiagnosticDiskSnapshot(root: context.root)
            let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
            if existing {
                // Open the actual read-only connection before attempting mutation.
                let retained = try await reader.record(id: "retained")
                XCTAssertNotNil(retained)
            }
            do { try await reader.save(row("new")); XCTFail("Read-only save must throw.") }
            catch AppFailure.storage { }
            catch { XCTFail("Unexpected save error: \(error)") }
            let afterSave = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(afterSave, before)
            do { try await reader.reconcile(completeEnumeration: []); XCTFail("Read-only reconcile must throw.") }
            catch AppFailure.storage { }
            catch { XCTFail("Unexpected reconcile error: \(error)") }
            let afterReconcile = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(afterReconcile, before)
            do { try await reader.clear(); XCTFail("Read-only clear must throw before deleting any file.") }
            catch AppFailure.storage { }
            catch { XCTFail("Unexpected clear error: \(error)") }
            await reader.close()
            let afterClear = try DiagnosticDiskSnapshot(root: context.root)
            XCTAssertEqual(afterClear, before)
        }
    }

    func testStaleGeographyIsNeutralAndExcludedFromCenterWithoutRewritingStoredPlace() async throws {
        let image = try preview()
        let north = PlaceEmbedding(text: "Photo taken in North.", vector: TestFixtures.vector())
        let south = PlaceEmbedding(text: "Photo taken in South.", vector: TestFixtures.vector().map { -$0 })
        let target = row("target", place: south, geography: "obsolete-boundaries")
        let peer = row("peer", image: TestFixtures.vector(axis: 1), place: north)
        let context = try makeContext([DiagnosticRecord("target", .preview(image)), DiagnosticRecord("peer", .preview(image))])
        try await seed(context, [target, peer])
        let before = try DiagnosticDiskSnapshot(root: context.root)
        let report = try await context.worker.checkPhoto(id: "target", query: "query", locationWeight: 0.6)
        let neutralTarget = row("target").photo
        try assertRanks(report, photos: [neutralTarget, peer.photo], fresh: TestFixtures.vector())
        XCTAssertEqual(report.cachedStatus, "current", "Old geography alone must not stale the image embedding.")
        XCTAssertEqual(report.cachedRank, 1)
        XCTAssertEqual(try XCTUnwrap(report.cachedScore), 0.4, accuracy: 0.000001)
        let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
        let retained = try await reader.record(id: "target")
        XCTAssertEqual(retained?.geographyVersion, "obsolete-boundaries")
        XCTAssertEqual(retained?.photo.location?.vector, south.vector)
        await reader.close()
        let after = try DiagnosticDiskSnapshot(root: context.root)
        XCTAssertEqual(after, before)
        assertOffline(context)
    }
}

private struct DiagnosticContext {
    let root: URL
    let directory: URL
    let store: SQLitePhotoStore
    let library: DiagnosticLibrary
    let encoders: DiagnosticEncoders
    let worker: PhotoIndexWorker
}

/// Only traverses the small, generated per-test sandbox. Nothing is exported.
private struct DiagnosticDiskSnapshot: Equatable {
    let paths: [String]
    let hashes: [String: Data]

    init(root: URL) throws {
        let manager = FileManager.default
        paths = try manager.subpathsOfDirectory(atPath: root.path).sorted()
        var hashes: [String: Data] = [:]
        for path in paths {
            let url = root.appendingPathComponent(path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                hashes[path] = Data(SHA256.hash(data: try Data(contentsOf: url)))
            }
        }
        self.hashes = hashes
    }
}

private struct DiagnosticRecord: Sendable {
    enum Response: Sendable {
        case preview(IndexingImage)
        case failure(Error)
    }
    let revision: PhotoRevision
    let response: Response

    init(_ id: String, _ response: Response, revision: Double = 123) {
        self.revision = PhotoRevision(id: id, modificationTime: revision, creationTime: 100)
        self.response = response
    }
}

/// Test-only PhotoKit boundary: no actual photo library, original-data API, or network setting.
private final class DiagnosticLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    struct Request: Sendable {
        let id: String
        let networkAllowed: Bool
    }
    private let lock = NSLock()
    private var records: [DiagnosticRecord]
    private var readable = true
    private var authorization: Int? = PHAuthorizationStatus.authorized.rawValue
    private var currentOverride: PhotoRevision?
    private var history: [Request] = []
    private var lookupCount = 0

    init(_ records: [DiagnosticRecord]) { self.records = records }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var requests: [Request] { locked { history } }
    var placeLookups: Int { locked { lookupCount } }
    func replace(_ records: [DiagnosticRecord]) { locked { self.records = records } }
    func setReadable(_ readable: Bool) { locked { self.readable = readable } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func overrideCurrent(_ revision: PhotoRevision) { locked { currentOverride = revision } }

    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        locked { readable ? records.map(\.revision) : [] }
    }

    func currentRevision(id: String) -> PhotoRevision? {
        locked {
            guard readable else { return nil }
            if let currentOverride, currentOverride.id == id { return currentOverride }
            return records.first { $0.revision.id == id }?.revision
        }
    }

    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { lookupCount += 1 }
        XCTFail("Read-only diagnostics must not look up or regenerate places.")
        return nil
    }

    private func response(id: String, networkAllowed: Bool) throws -> DiagnosticRecord.Response {
        try locked {
            history.append(Request(id: id, networkAllowed: networkAllowed))
            guard readable, let record = records.first(where: { $0.revision.id == id }) else { throw AppFailure.permission }
            return record.response
        }
    }

    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        switch try response(id: id, networkAllowed: networkAllowed) {
        case .preview(let image): return image
        case .failure(let error): throw error
        }
    }
}

private actor DiagnosticLatch {
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

/// Implements the real encoder protocol, not an empty PhotoWorkServicing replacement.
/// Fixtures are validated 512-D unit vectors; no model bundle is opened.
private actor DiagnosticEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let fresh: [Float]
    private let imageFailure: AppFailure?
    private let started: XCTestExpectation?
    private let latch = DiagnosticLatch()
    private(set) var prepareCalls = 0
    private(set) var texts: [String] = []
    private(set) var previews: [IndexingImage] = []
    private(set) var dataCalls = 0

    init(fresh: [Float] = TestFixtures.vector(), imageFailure: AppFailure? = nil, started: XCTestExpectation? = nil) throws {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        try manifest.validate()
        try EmbeddingValidation.validateUnit(fresh)
        self.manifest = manifest
        self.fresh = fresh
        self.imageFailure = imageFailure
        self.started = started
    }

    func prepare() throws -> ModelManifest {
        prepareCalls += 1
        return manifest
    }

    func text(_ text: String) throws -> [Float] {
        texts.append(text)
        return TestFixtures.vector()
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        dataCalls += 1
        XCTFail("Diagnostics must never call the original-data encoder overload.")
        throw AppFailure.modelContract("Unexpected original-data encoder call")
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        previews.append(preview)
        if let started {
            started.fulfill()
            await latch.wait()
        }
        // Intentionally ignore task cancellation: the production worker must reject late results.
        if let imageFailure { throw imageFailure }
        return fresh
    }

    func release() async { await latch.open() }
}