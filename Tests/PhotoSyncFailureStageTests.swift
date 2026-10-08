import Foundation
import ImageIO
import Photos
import SQLite3
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real worker and SQLite; synthetic Photos/encoders only. No authorization,
/// private assets, model weights, wall-clock waits or production data changes.
@MainActor
final class PhotoSyncFailureStageTests: XCTestCase {
    func testFirstPermissionFailureReachesFailedStateWithoutPhotosOrResourceReads() async throws {
        let context = try make([])
        context.library.state.modify { $0.readable = false }
        let state = PhotoSyncState(service: context.worker)
        var settlements = 0
        state.onSettled = { settlements += 1 }
        state.onCommitted = { XCTFail("No write") }
        state.onCompleted = { _ in XCTFail("No successful summary") }
        state.updateAvailability(ready: true, networkAllowed: false)
        XCTAssertEqual(state.phase, .checking)
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failureDiagnostic?.stage, .photos)
        XCTAssertEqual(state.failureDiagnostic?.code, .permission)
        XCTAssertEqual(PhotoSyncToast(state: state).detail, state.failureDiagnostic?.message)
        XCTAssertEqual(settlements, 1)
        XCTAssertEqual(context.library.state.value.enumerations, 0)
        let inspections = await context.encoders.inspections
        XCTAssertEqual(inspections, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
    }

    func testSetupAndPhotosFailuresKeepTheirOriginalCausesAndExactStages() async throws {
        let context = try make([])
        let noCoordinator = PhotoIndexWorker(library: context.library, encoders: context.encoders,
                                            directory: context.directory)
        do {
            _ = try await noCoordinator.synchronize(networkAllowed: false, progress: { _ in }, committed: {})
            XCTFail("Missing coordinator")
        } catch let error as PhotoSyncFailure {
            XCTAssertEqual(error.diagnostic.stage, .setup)
            XCTAssertEqual(error.diagnostic.code, .storage)
            guard case AppFailure.storage = error.underlyingError else { return XCTFail("Keep original type") }
        }
        let original = NSError(domain: "private-enumeration", code: 14,
                               userInfo: [NSLocalizedDescriptionKey: "private photo path"])
        context.library.state.modify { $0.enumerationError = original }
        let error = try await failure(context)
        XCTAssertEqual(error.diagnostic.stage, .photos)
        XCTAssertEqual(error.diagnostic.code, .unknown)
        XCTAssertNil(error.diagnostic.nativeCode)
        XCTAssertTrue((error.underlyingError as NSError) === original)
        XCTAssertFalse(error.localizedDescription.contains("private"))
    }

    func testResourceInspectionAndManifestValidationAreNotReportedAsIndexFailures() async throws {
        let unknown = NSError(domain: "private-model-path", code: 14)
        let cases: [(FailureStageEncoders, PhotoSyncDiagnostic.Code)] = [
            (try FailureStageEncoders(inspectError: AppFailure.modelsMissing("private")), .resources),
            (try FailureStageEncoders(invalidManifest: true), .model),
            (try FailureStageEncoders(inspectError: unknown), .unknown)
        ]
        for (encoders, code) in cases {
            let context = try make([], encoders: encoders)
            let error = try await failure(context)
            XCTAssertEqual(error.diagnostic.stage, .resources)
            XCTAssertEqual(error.diagnostic.code, code)
            XCTAssertNil(error.diagnostic.nativeCode)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        }
    }

    func testRealSQLiteOpenSchemaAndQueryFailuresUseReadOnlyOptInDiagnostics() async throws {
        let cases: [(String, SimilarCleanupDiagnostic.Code, Int32?)] = [
            ("open", .indexOpen, SQLITE_CANTOPEN),
            ("PRAGMA user_version = 7;", .indexSchemaUnsupported, nil),
            ("DROP TABLE photos;", .indexPrepare, SQLITE_ERROR)
        ]
        for (change, expected, native) in cases {
            let context = try make([])
            if change == "open" {
                try FileManager.default.createDirectory(at: context.file, withIntermediateDirectories: true)
            } else {
                try TestFixtures.seedRawCache([], directory: context.directory)
                try failureStageSQL(context.directory, change)
            }
            let before: Data? = try (change == "open" ? nil : Data(contentsOf: context.file))
            let legacy = SQLitePhotoStore(directory: context.directory, readOnly: true)
            do { _ = try await legacy.syncMetadata(); XCTFail("Default contract must still fail") }
            catch AppFailure.storage { }
            await legacy.close()
            let error = try await failure(context)
            XCTAssertEqual(error.diagnostic.stage, .indexRead)
            XCTAssertEqual(error.diagnostic.code, .sqlite)
            XCTAssertEqual(error.diagnostic.sqliteCode, expected)
            XCTAssertEqual(error.diagnostic.nativeCode.map { $0 & 0xff }, native)
            XCTAssertTrue(error.underlyingError is SimilarCleanupDiagnostic)
            XCTAssertFalse(error.localizedDescription.contains("SG-"))
            XCTAssertFalse(error.localizedDescription.contains(context.directory.path))
            if let before { XCTAssertEqual(try Data(contentsOf: context.file), before) }
            XCTAssertEqual(context.access.revision, 0)
        }
    }

    func testInvalidPhotosMetadataIdentifiesFieldWithoutRetainingIDOrChangingIndex() async throws {
        let cases: [([PhotoRevision], PhotoSyncDiagnostic.MetadataField)] = [
            ([revision("")], .id), ([revision("private\0id")], .id),
            ([revision("private", modified: .infinity)], .modificationTime),
            ([revision("private", created: .nan)], .creationTime),
            ([revision("private"), revision("private")], .duplicateID)
        ]
        for (rows, field) in cases {
            let context = try make(rows)
            try TestFixtures.seedRawCache([TestFixtures.photo()], directory: context.directory)
            let before = try Data(contentsOf: context.file)
            let error = try await failure(context)
            XCTAssertEqual(error.diagnostic.stage, .photos)
            XCTAssertEqual(error.diagnostic.code, .invalidPhotoMetadata)
            XCTAssertEqual(error.diagnostic.metadataField, field)
            XCTAssertFalse(String(reflecting: error.diagnostic).contains("private"))
            guard case AppFailure.photo = error.underlyingError else { return XCTFail("Keep original type") }
            XCTAssertEqual(try Data(contentsOf: context.file), before)
            XCTAssertEqual(context.access.revision, 0)
        }
    }

    func testInvalidIndexMetadataIdentifiesFieldAndDefaultAPIStillThrowsLegacyStorage() async throws {
        let cases: [(String, PhotoSyncDiagnostic.MetadataField)] = [
            ("UPDATE photos SET id = '';", .id),
            ("UPDATE photos SET id = CAST(x'610062' AS TEXT);", .id),
            ("UPDATE photos SET revision = 1e999;", .modificationTime),
            ("UPDATE photos SET creation_time = 1e999;", .creationTime),
            ("UPDATE photos SET model_version = '';", .modelVersion),
            ("UPDATE photos SET id = CAST(x'ff' AS TEXT);", .id),
            ("UPDATE photos SET model_version = CAST(x'ff' AS TEXT);", .modelVersion),
            ("CREATE TABLE copied AS SELECT * FROM photos; INSERT INTO copied SELECT * FROM photos; " +
                "DROP TABLE photos; ALTER TABLE copied RENAME TO photos;", .duplicateID)
        ]
        for (sql, field) in cases {
            let context = try make([])
            try TestFixtures.seedRawCache([TestFixtures.photo()], directory: context.directory)
            try failureStageSQL(context.directory, sql)
            let before = try Data(contentsOf: context.file)
            let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
            do { _ = try await reader.syncMetadata(); XCTFail("Invalid metadata") }
            catch AppFailure.storage { }
            await reader.close()
            let error = try await failure(context)
            XCTAssertEqual(error.diagnostic.stage, .indexRead)
            XCTAssertEqual(error.diagnostic.code, .invalidIndexMetadata)
            XCTAssertEqual(error.diagnostic.metadataField, field)
            XCTAssertNil(error.diagnostic.nativeCode)
            XCTAssertEqual(try Data(contentsOf: context.file), before)
            XCTAssertEqual(context.access.revision, 0)
        }
    }

    func testAuthorizationGenerationFullSnapshotAndSelectedPhotoChangesAreDistinct() async throws {
        let expected: [(PhotoSyncDiagnostic.Stage, PhotoSyncDiagnostic.Code)] = [
            (.resources, .accessChanged), (.resources, .generationChanged),
            (.difference, .libraryChanged), (.encoding, .photoChanged)
        ]
        for (index, pair) in expected.enumerated() {
            let library = FailureStageLibrary([revision("new")])
            let encoders = try FailureStageEncoders(inspectionHook: {
                if index == 0 { library.state.modify { $0.authorization = PHAuthorizationStatus.limited.rawValue } }
                if index == 1 { library.state.modify { $0.generation = 1 } }
            })
            let context = try make([], library: library, encoders: encoders)
            if index == 2 { library.state.modify { $0.generation = nil } }
            if index == 3 {
                library.state.modify { value in
                    value.previewHook = {
                        library.state.modify { $0.rows = [PhotoRevision(id: "new", modificationTime: 124, creationTime: 100)] }
                    }
                }
            }
            defer { library.state.modify { $0.previewHook = nil } }
            let error = try await failure(context, progress: { value in
                if index == 2 && value.phase == .updating {
                    library.state.modify { $0.rows = [] }
                }
            })
            XCTAssertEqual(error.diagnostic.stage, pair.0)
            XCTAssertEqual(error.diagnostic.code, pair.1)
            XCTAssertEqual(context.access.revision, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: context.directory.path))
        }
    }

    func testModelsEncodingPruneSaveAndSummaryFailuresKeepActualPhaseAndCommittedCounts() async throws {
        let stages: [PhotoSyncDiagnostic.Stage] = [.models, .encoding, .prune, .save, .summary]
        for stage in stages {
            let encoders = try FailureStageEncoders(
                prepareError: stage == .models ? AppFailure.modelContract("private") : nil,
                imageError: stage == .encoding ? AppFailure.modelContract("private") : nil)
            let context = try make(stage == .prune ? [] : [revision("new")], encoders: encoders)
            try TestFixtures.seedRawCache(stage == .prune ? [TestFixtures.photo()] : [], directory: context.directory)
            if stage == .prune || stage == .save {
                let event = stage == .prune ? "DELETE" : "INSERT"
                try failureStageSQL(context.directory,
                    "CREATE TRIGGER reject_sync BEFORE \(event) ON photos BEGIN SELECT RAISE(ABORT, 'private'); END;")
            }
            let values = FailureStageBox<[PhotoSyncProgress]>([])
            let commits = FailureStageBox(0)
            let error = try await failure(context, progress: { value in values.modify { $0.append(value) } }, committed: {
                commits.modify { $0 += 1 }
                if stage == .summary {
                    do { try failureStageSQL(context.directory, "DROP TABLE places;") }
                    catch { XCTFail("Synthetic fault injection failed") }
                }
            })
            XCTAssertEqual(error.diagnostic.stage, stage)
            XCTAssertEqual(error.diagnostic.code, stage == .models || stage == .encoding ? .model : .storage)
            XCTAssertNil(error.diagnostic.nativeCode, "Uninstrumented write/summary errors cannot supply a guessed SQLite number.")
            XCTAssertEqual(values.value.last?.encoded, stage == .summary ? 1 : 0)
            XCTAssertEqual(values.value.last?.completed, stage == .summary ? 1 : 0)
            XCTAssertEqual(values.value.last?.failed, 0)
            XCTAssertEqual(commits.value, stage == .summary ? 1 : 0)
            XCTAssertFalse(context.access.isWriting)
            if stage == .summary {
                let reader = SQLitePhotoStore(directory: context.directory, readOnly: true)
                let rows = try await reader.syncMetadata()
                await reader.close()
                XCTAssertEqual(Set(rows.keys), ["new"], "The committed prefix is not discarded on summary failure.")
            }
        }
    }

    func testPerPhotoCloudAndUnknownFailuresRemainNonfatalAndCancelledWorkerDoesNotWrap() async throws {
        let context = try make([revision("cloud"), revision("unknown")])
        context.library.state.modify {
            $0.previewErrors = ["cloud": AppFailure.cloudOnly,
                                "unknown": NSError(domain: "private", code: 14)]
        }
        let state = PhotoSyncState(service: context.worker)
        var settled = 0
        state.onSettled = { settled += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .needsAttention)
        XCTAssertEqual(state.progress.completed, 2)
        XCTAssertEqual(state.progress.needsNetwork, 1)
        XCTAssertEqual(state.progress.failed, 1)
        XCTAssertNil(state.failureDiagnostic)
        XCTAssertNil(state.failureMessage)
        XCTAssertEqual(settled, 1)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await context.worker.synchronize(networkAllowed: false,
                progress: { _ in XCTFail("Already cancelled") }, committed: { XCTFail("No commit") })
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
    }

    private func revision(_ id: String, modified: Double = 123, created: Double? = 100) -> PhotoRevision {
        PhotoRevision(id: id, modificationTime: modified, creationTime: created)
    }

    private func make(_ rows: [PhotoRevision], library: FailureStageLibrary? = nil,
                      encoders: FailureStageEncoders? = nil) throws -> FailureStageContext {
        let parent = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("not-created", isDirectory: true)
        let library = library ?? FailureStageLibrary(rows)
        let encoders = try encoders ?? FailureStageEncoders()
        let access = IndexAccessCoordinator()
        let worker = PhotoIndexWorker(library: library, encoders: encoders, directory: directory,
                                      resolver: .unavailable("TEST"), indexAccess: access)
        return FailureStageContext(worker: worker, library: library, encoders: encoders,
                                   directory: directory, access: access)
    }

    private func failure(_ context: FailureStageContext,
                         progress: @escaping @Sendable (PhotoSyncProgress) async -> Void = { _ in },
                         committed: @escaping @Sendable () async -> Void = {}) async throws -> PhotoSyncFailure {
        do {
            _ = try await context.worker.synchronize(networkAllowed: false, progress: progress, committed: committed)
            XCTFail("Expected a typed sync failure")
            throw FailureStageTestError.expectedFailure
        } catch let error as PhotoSyncFailure { return error }
    }
}

private enum FailureStageTestError: Error { case expectedFailure, sql }

private struct FailureStageContext: Sendable {
    let worker: PhotoIndexWorker
    let library: FailureStageLibrary
    let encoders: FailureStageEncoders
    let directory: URL
    let access: IndexAccessCoordinator
    var file: URL { directory.appendingPathComponent("index.sqlite3") }
}

private func failureStageSQL(_ directory: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                &handle, SQLITE_OPEN_READWRITE, nil)
    defer { if let handle { sqlite3_close(handle) } }
    guard status == SQLITE_OK, let handle,
          sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FailureStageTestError.sql }
}

private final class FailureStageBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func modify(_ operation: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation(&stored)
    }
}

private final class FailureStageLibrary: PhotoLibraryIndexing, Sendable {
    struct State {
        var rows: [PhotoRevision]
        var readable = true
        var authorization = PHAuthorizationStatus.authorized.rawValue
        var generation: UInt64? = 0
        var enumerationError: Error?
        var enumerations = 0
        var previewErrors: [String: Error] = [:]
        var previewHook: (@Sendable () -> Void)?
    }
    let state: FailureStageBox<State>
    init(_ rows: [PhotoRevision]) { state = FailureStageBox(State(rows: rows)) }
    var canReadImages: Bool { state.value.readable }
    var authorizationStatusRawValue: Int? { state.value.authorization }
    var changeGeneration: UInt64? { state.value.generation }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        state.modify { $0.enumerations += 1 }
        let value = state.value
        if let error = value.enumerationError { throw error }
        return value.rows
    }
    func currentRevision(id: String) -> PhotoRevision? { state.value.rows.first { $0.id == id } }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        let value = state.value
        value.previewHook?()
        if let error = value.previewErrors[id] { throw error }
        return IndexingImage(cgImage: try TestFixtures.image(width: 2, height: 2) { _, _ in (10, 20, 30) },
                             orientation: .up, source: .localPreview)
    }
}

private actor FailureStageEncoders: PhotoEncoding {
    private let manifest: ModelManifest
    private let inspectError: Error?
    private let prepareError: Error?
    private let imageError: Error?
    private let inspectionHook: @Sendable () -> Void
    private(set) var inspections = 0
    init(inspectError: Error? = nil, prepareError: Error? = nil, imageError: Error? = nil,
         invalidManifest: Bool = false, inspectionHook: @escaping @Sendable () -> Void = {}) throws {
        let json = invalidManifest ? TestFixtures.manifest.replacingOccurrences(of: "\"dimension\":768", with: "\"dimension\":2")
            : TestFixtures.manifest
        manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(json.utf8))
        self.inspectError = inspectError
        self.prepareError = prepareError
        self.imageError = imageError
        self.inspectionHook = inspectionHook
    }
    func inspectResources() throws -> ModelManifest {
        inspections += 1
        inspectionHook()
        if let inspectError { throw inspectError }
        return manifest
    }
    func prepare() throws -> ModelManifest {
        if let prepareError { throw prepareError }
        return manifest
    }
    func image(preview: IndexingImage) throws -> [Float] {
        if let imageError { throw imageError }
        return TestFixtures.vector()
    }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        XCTFail("Sync must use previews")
        throw FailureStageTestError.expectedFailure
    }
    func text(_ text: String) -> [Float] { TestFixtures.vector(axis: 1) }
}