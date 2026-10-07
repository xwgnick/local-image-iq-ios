import Darwin
import Foundation
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Synthetic SQLite only; no Photos, model execution, protected-file assumptions
/// or simulator-specific permission behavior. Fault injection cannot authorize a
/// read that fails the real filesystem/VFS chain.
final class SimilarSourceDiagnosticTests: XCTestCase {
    private typealias Diagnostic = SimilarCleanupDiagnostic
    private let model = "test-model"

    func testUnchangedSourceKeepsTwoSnapshotsVectorsAndSourceBytes() async throws {
        let root = try directory()
        let before = try Data(contentsOf: file(root))
        let probe = SourceDiagnosticProbe()
        let authority = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { probe.inspect() })
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let first = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"], authority: authority)
        let second = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"], authority: authority)
        let records = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a"], eligibleIDs: ["a"],
            expectedSnapshot: first, authority: authority)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.revisions.count, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.imageEmbedding, TestFixtures.vector())
        XCTAssertEqual(probe.calls, 16, "Two lock probes per data_version, with entry/exit checks unchanged.")
        XCTAssertEqual(try Data(contentsOf: file(root)), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["index.sqlite3"])
    }

    func testMissingIndexDoesNotCreateFilesAndAppearanceHasIdentityCode() throws {
        let parent = try directory(seed: false)
        let root = parent.appendingPathComponent("not-created")
        let authority = try SimilarGroupingSourceAuthority(directory: root)
        try authority.validate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try authority.validate()
        try TestFixtures.seedRawCache([], directory: root)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
    }

    func testParentSymlinkIsNotFollowed() throws {
        let root = try directory()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: alias) }.code, .sourceParentSymlink)
    }

    func testParentNonDirectoryHasOwnCode() throws {
        let root = try directory()
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: file(root)) }.code, .sourceParentKind)
    }

    func testParentLstatCapturesErrnoWithoutCopyingPath() throws {
        let root = try directory()
        let invalid = file(root).appendingPathComponent("synthetic-private-child")
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: invalid) }
        XCTAssertEqual(diagnostic.code, .sourceParentStat)
        XCTAssertEqual(diagnostic.nativeCode, ENOTDIR)
        XCTAssertFalse(diagnostic.message(operation: .restore).contains("synthetic-private-child"))
        XCTAssertFalse(diagnostic.message(operation: .restore).contains(root.path))
    }

    func testSourceSymlinkHasOwnCode() throws {
        let root = try directory()
        let target = root.appendingPathComponent("synthetic-original")
        try FileManager.default.moveItem(at: file(root), to: target)
        try FileManager.default.createSymbolicLink(at: file(root), withDestinationURL: target)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }.code, .sourceFileSymlink)
    }

    func testSourceDirectoryHasOwnCode() throws {
        let root = try directory(seed: false)
        try FileManager.default.createDirectory(at: file(root), withIntermediateDirectories: false)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }.code, .sourceFileKind)
    }

    func testMultiplyLinkedSourceHasOwnCode() throws {
        let root = try directory()
        try FileManager.default.linkItem(at: file(root), to: root.appendingPathComponent("second-link"))
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }.code, .sourceFileLinks)
    }

    func testEachSidecarIsRejectedEvenWhenDirectoryOrDanglingSymlink() throws {
        let root = try directory()
        let before = try Data(contentsOf: file(root))
        let cases: [(String, Diagnostic.Code)] = [("-journal", .sourceJournalPresent), ("-wal", .sourceWALPresent), ("-shm", .sourceSHMPresent)]
        for (suffix, code) in cases {
            let sidecar = URL(fileURLWithPath: file(root).path + suffix)
            for kind in 0..<3 {
                if kind == 0 { try Data().write(to: sidecar) }
                else if kind == 1 { try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false) }
                else { try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: root.appendingPathComponent("absent")) }
                let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }
                XCTAssertEqual(diagnostic.code, code)
                XCTAssertNil(diagnostic.nativeCode)
                XCTAssertFalse(diagnostic.message(operation: .restore).contains("正被写入占用"))
                try FileManager.default.removeItem(at: sidecar)
            }
        }
        XCTAssertEqual(try Data(contentsOf: file(root)), before)
    }

    func testSidecarInspectionOrderRemainsJournalThenWALThenSHM() throws {
        let root = try directory()
        for suffix in ["-journal", "-wal", "-shm"] { try Data().write(to: URL(fileURLWithPath: file(root).path + suffix)) }
        let cases: [(String, Diagnostic.Code)] = [("-journal", .sourceJournalPresent), ("-wal", .sourceWALPresent), ("-shm", .sourceSHMPresent)]
        for (suffix, code) in cases {
            XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }.code, code)
            try FileManager.default.removeItem(at: URL(fileURLWithPath: file(root).path + suffix))
        }
        try SimilarGroupingSourceAuthority(directory: root).validate()
    }

    func testInvalidSQLiteSourceCapturesActualQueryStageAndCodeBeforeClose() throws {
        let root = try directory(seed: false)
        let bytes = Data(repeating: 0x78, count: 4096)
        try bytes.write(to: file(root))
        // SQLite versions may detect a bad header at prepare or first step.
        // Compare against the actual native call, not a guessed detection stage.
        let expectedCode: Diagnostic.Code
        let expectedNative: Int32
        do {
            var pointer: OpaquePointer?
            let openRC = sqlite3_open_v2(file(root).path, &pointer,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
            defer { if let pointer { sqlite3_close(pointer) } }
            XCTAssertEqual(openRC, SQLITE_OK)
            let db = try XCTUnwrap(pointer)
            var statement: OpaquePointer?
            defer { if let statement { sqlite3_finalize(statement) } }
            let prepareRC = sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &statement, nil)
            if prepareRC == SQLITE_OK {
                let stepRC = sqlite3_step(try XCTUnwrap(statement))
                XCTAssertEqual(stepRC & 0xff, SQLITE_NOTADB)
                expectedCode = .sourceQueryStep
            } else {
                XCTAssertEqual(prepareRC & 0xff, SQLITE_NOTADB)
                expectedCode = .sourceQueryPrepare
            }
            expectedNative = sqlite3_extended_errcode(db)
        }
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }
        XCTAssertEqual(diagnostic.code, expectedCode)
        XCTAssertEqual(diagnostic.nativeCode, expectedNative)
        XCTAssertEqual(expectedNative & 0xff, SQLITE_NOTADB)
        XCTAssertEqual(try Data(contentsOf: file(root)), bytes)
    }

    func testFileControlUnavailableRetainsExactNativeReturnCode() throws {
        let root = try directory()
        let diagnostic = try capture {
            _ = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { .unavailable(SQLITE_NOTFOUND) })
        }
        XCTAssertEqual(diagnostic, .init(phase: .sourceCheck, code: .sourceFileControl, nativeCode: SQLITE_NOTFOUND))
    }

    func testMissingFilePointerHasNoInventedSQLiteCode() throws {
        let root = try directory()
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { .missingFile }) }
        XCTAssertEqual(diagnostic, .init(phase: .sourceCheck, code: .sourceFilePointerMissing))
    }

    func testMissingLockMethodIsDistinctFromFileControlAndWriter() throws {
        let root = try directory()
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { .missingMethod }) }
        XCTAssertEqual(diagnostic, .init(phase: .sourceCheck, code: .sourceLockMethodMissing))
    }

    func testLockErrorKeepsExtendedVFSReturnCode() throws {
        let root = try directory()
        // SQLITE_IOERR_CHECKRESERVEDLOCK: extended subtype 14, primary IOERR.
        let native = SQLITE_IOERR | (14 << 8)
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { .failed(native) }) }
        XCTAssertEqual(diagnostic, .init(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: native))
    }

    func testInjectedReservedWriterDoesNotBecomeLockInspectionFailure() throws {
        let root = try directory()
        let diagnostic = try capture { _ = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { .writer }) }
        XCTAssertEqual(diagnostic, .init(phase: .sourceCheck, code: .sourceWriterReserved))
    }

    func testRealReservedWriterWinsOverInjectedDifferentFaultWithoutSidecar() throws {
        let root = try directory()
        let probe = SourceDiagnosticProbe()
        let authority = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { probe.inspect() })
        let sql = try SourceDiagnosticSQL(root)
        let before = try Data(contentsOf: file(root))
        try sql.exec("BEGIN IMMEDIATE")
        defer { _ = sql.execStatus("ROLLBACK") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root).path + "-journal"))
        let calls = probe.calls
        probe.arm(.missingMethod)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceWriterReserved)
        XCTAssertEqual(probe.calls, calls, "A real failure must not reach the fault-only adapter.")
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: root) }.code, .sourceWriterReserved)
        XCTAssertEqual(try Data(contentsOf: file(root)), before)
    }

    func testInvalidationPreservesFirstReasonAndNativeCodeAfterLaterFileChange() throws {
        let root = try directory()
        let probe = SourceDiagnosticProbe()
        let authority = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { probe.inspect() })
        probe.arm(.failed(SQLITE_IOERR))
        let first = try capture { try authority.validate() }
        probe.arm(nil)
        try replaceWithSameBytes(root)
        XCTAssertEqual(try capture { try authority.validate() }, first)
        XCTAssertEqual(try capture { try authority.validate() }, first)
        XCTAssertEqual(first.code, .sourceLockCheckFailed)
        XCTAssertEqual(first.nativeCode, SQLITE_IOERR)
        try SimilarGroupingSourceAuthority(directory: root).validate()
    }

    func testSameBytesReplacementReportsFileIdentityNotDataVersion() throws {
        let root = try directory()
        let authority = try SimilarGroupingSourceAuthority(directory: root)
        try replaceWithSameBytes(root)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
    }

    func testCommittedRewriteObservedBeforeFirstStatReportsIdentityCheck() throws {
        let root = try directory()
        let authority = try SimilarGroupingSourceAuthority(directory: root)
        let sql = try SourceDiagnosticSQL(root)
        // Change file size deterministically, not a timestamp-resolution guess.
        try sql.exec("CREATE TABLE synthetic_extra (payload BLOB); INSERT INTO synthetic_extra VALUES (zeroblob(65536))")
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
    }

    func testRealCommitBetweenStatAndPragmaReportsDataVersionCheck() throws {
        let root = try directory()
        let sql = try SourceDiagnosticSQL(root)
        let probe = SourceDiagnosticProbe()
        let authority = try SimilarGroupingSourceAuthority(directory: root, lockProbe: { probe.inspect() })
        probe.onNextInspection { sql.execStatus("UPDATE photos SET revision = 456") }
        let diagnostic = try capture { try authority.validate() }
        XCTAssertEqual(probe.actionStatus, SQLITE_OK)
        XCTAssertEqual(diagnostic.code, .sourceDataVersionChanged)
        XCTAssertNil(diagnostic.nativeCode, "Do not expose the source's data_version value.")
        XCTAssertEqual(try capture { try authority.validate() }, diagnostic)
    }

    func testJournalModeMappingIsExactAndDoesNotRetainUnknownMode() {
        XCTAssertNil(SimilarGroupingSourceAuthority.unsupportedJournalMode("delete"))
        let cases: [(String, Diagnostic.Code)] = [("wal", .sourceJournalModeWAL), ("memory", .sourceJournalModeMemory),
            ("truncate", .sourceJournalModeTruncate), ("persist", .sourceJournalModePersist), ("off", .sourceJournalModeOff),
            ("DELETE", .sourceJournalModeUnknown), ("synthetic-private-mode", .sourceJournalModeUnknown)]
        for (mode, code) in cases {
            let diagnostic = SimilarGroupingSourceAuthority.unsupportedJournalMode(mode)
            XCTAssertEqual(diagnostic?.code, code)
            XCTAssertNil(diagnostic?.nativeCode)
            XCTAssertFalse(diagnostic?.message(operation: .restore).contains(mode) ?? true)
        }
    }

    func testAuthorityCancellationIsNotClassifiedOrLatched() async throws {
        let root = try directory()
        let authority = try SimilarGroupingSourceAuthority(directory: root)
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try authority.validate()
        }
        do { try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        try authority.validate()
    }

    func testUnsupportedSchemaIsTypedOnlyForGroupingAndDoesNotExposeVersion() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("PRAGMA user_version = 123456")
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: ["a"]) }
        XCTAssertEqual(diagnostic.code, .indexSchemaUnsupported)
        XCTAssertNil(diagnostic.nativeCode)
        XCTAssertFalse(diagnostic.message(operation: .restore).contains("123456"))
        do { _ = try await reader.searchRecords(modelVersion: model, accessibleIDs: ["a"]); XCTFail("Expected legacy storage failure.") }
        catch AppFailure.storage { }
        catch { XCTFail("Ordinary reader diagnostics changed.") }
    }

    func testPrepareFailureUsesActualCodeAndCannotReuseLegacyConnectionMode() async throws {
        let root = try directory()
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        _ = try await reader.record(id: "a") // Leaves a normal connection resident.
        try SourceDiagnosticSQL(root).exec("DROP TABLE photos")
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: ["a"]) }
        XCTAssertEqual(diagnostic.code, .indexPrepare)
        XCTAssertEqual(diagnostic.nativeCode, SQLITE_ERROR)
        let empty = SimilarGroupingInputSnapshot(revisions: [:], imagePayloadSignature: Data())
        let decodeFailure = try await captureAsync {
            _ = try await reader.groupingImageRecords(modelVersion: self.model, accessibleIDs: ["a"], eligibleIDs: ["a"], expectedSnapshot: empty)
        }
        XCTAssertEqual(decodeFailure, diagnostic)
        do { _ = try await reader.records(modelVersion: model); XCTFail("Expected legacy storage failure.") }
        catch AppFailure.storage { }
        catch { XCTFail("Cleanup mode escaped into a normal reader.") }
        await reader.close()
    }

    func testStepFailureUsesActualSQLiteCodeNotItsErrorMessage() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("""
            ALTER TABLE photos RENAME TO synthetic_rows;
            CREATE VIEW photos AS SELECT id, abs(-9223372036854775808) AS revision,
                creation_time, model_version, image_embedding FROM synthetic_rows;
            """)
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: ["a"]) }
        XCTAssertEqual(diagnostic.code, .indexStep)
        XCTAssertEqual(diagnostic.nativeCode, SQLITE_ERROR)
        XCTAssertFalse(diagnostic.message(operation: .restore).contains("integer overflow"))
    }

    func testInvalidUTF8MetadataIsRejectedBeforeAccessFiltering() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("UPDATE photos SET id = CAST(X'FF' AS TEXT)")
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: []) }
        XCTAssertEqual(diagnostic.code, .indexMetadataInvalid)
        XCTAssertNil(diagnostic.nativeCode)
    }

    func testMissingMetadataHasDifferentCodeFromInvalidUTF8() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("""
            ALTER TABLE photos RENAME TO synthetic_rows;
            CREATE TABLE photos AS SELECT * FROM synthetic_rows;
            UPDATE photos SET id = NULL;
            """)
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: []) }
        XCTAssertEqual(diagnostic.code, .indexMetadataMissing)
    }

    func testDuplicateIdentityRetainsExistingRejectionWithoutDisclosingID() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("""
            ALTER TABLE photos RENAME TO synthetic_rows;
            CREATE TABLE photos AS SELECT * FROM synthetic_rows UNION ALL SELECT * FROM synthetic_rows;
            """)
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let diagnostic = try await captureAsync { _ = try await reader.groupingInputSnapshot(modelVersion: self.model, accessibleIDs: ["a"]) }
        XCTAssertEqual(diagnostic.code, .indexDuplicateIdentity)
        XCTAssertNil(diagnostic.nativeCode)
    }

    func testChangedImageBytesStillFailExactSnapshotWithoutAuthority() async throws {
        let root = try directory()
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let snapshot = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"])
        try SourceDiagnosticSQL(root).exec("UPDATE photos SET image_embedding = X'FF'")
        let diagnostic = try await captureAsync {
            _ = try await reader.groupingImageRecords(modelVersion: self.model, accessibleIDs: ["a"], eligibleIDs: [], expectedSnapshot: snapshot)
        }
        XCTAssertEqual(diagnostic.code, .indexSnapshotChanged)
    }

    func testMalformedStaleBlobIsHashedButOnlyEligibleBlobDecodeFails() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("UPDATE photos SET image_embedding = X'FF'")
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let snapshot = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"])
        let excluded = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a"], eligibleIDs: [], expectedSnapshot: snapshot)
        XCTAssertTrue(excluded.isEmpty)
        do {
            _ = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a"], eligibleIDs: ["a"], expectedSnapshot: snapshot)
            XCTFail("An eligible malformed vector must still fail.")
        } catch {
            XCTAssertTrue(error is DecodingError, "Service-phase wrapper owns JSON classification.")
            XCTAssertEqual(Diagnostic.classify(error, phase: .indexRead).code, .invalidIndex)
        }
    }

    func testGroupingCancellationWinsBeforeBrokenSourceAndDoesNotBecomeDiagnostic() async throws {
        let root = try directory()
        try SourceDiagnosticSQL(root).exec("DROP TABLE photos")
        let reader = SQLitePhotoStore(directory: root, readOnly: true)
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await reader.groupingInputSnapshot(modelVersion: "test-model", accessibleIDs: ["a"])
        }
        do { try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func directory(seed: Bool = true) throws -> URL {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        if seed { try TestFixtures.seedRawCache([TestFixtures.photo(id: "a")], directory: root) }
        return root
    }

    private func file(_ root: URL) -> URL { root.appendingPathComponent("index.sqlite3") }

    private func replaceWithSameBytes(_ root: URL) throws {
        let bytes = try Data(contentsOf: file(root))
        // Keep the old inode alive to avoid inode-reuse assumptions.
        try FileManager.default.moveItem(at: file(root), to: root.appendingPathComponent("previous.sqlite3"))
        try bytes.write(to: file(root))
        XCTAssertEqual(try Data(contentsOf: file(root)), bytes)
    }

    private func capture(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws -> Diagnostic {
        do { try operation() }
        catch { return try XCTUnwrap(error as? Diagnostic, "Expected a typed diagnostic.", file: file, line: line) }
        XCTFail("Expected rejection.", file: file, line: line)
        throw SourceDiagnosticFixtureError.expectedFailure
    }

    private func captureAsync(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async throws -> Diagnostic {
        do { try await operation() }
        catch { return try XCTUnwrap(error as? Diagnostic, "Expected a typed diagnostic.", file: file, line: line) }
        XCTFail("Expected rejection.", file: file, line: line)
        throw SourceDiagnosticFixtureError.expectedFailure
    }
}

private enum SourceDiagnosticFixtureError: Error { case sqlite(Int32), expectedFailure }

private final class SourceDiagnosticSQL: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()

    init(_ directory: URL) throws {
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SourceDiagnosticFixtureError.sqlite(rc)
        }
        handle = pointer
    }

    deinit { sqlite3_close(handle) }

    func execStatus(_ sql: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return sqlite3_exec(handle, sql, nil, nil, nil)
    }

    func exec(_ sql: String) throws {
        let rc = execStatus(sql)
        guard rc == SQLITE_OK else { throw SourceDiagnosticFixtureError.sqlite(rc) }
    }
}

private final class SourceDiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fault: SourceLockInspectionFault?
    private var action: (@Sendable () -> Int32)?
    private var count = 0
    private var status: Int32?

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var actionStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }

    func arm(_ fault: SourceLockInspectionFault?) {
        lock.lock(); defer { lock.unlock() }
        self.fault = fault
    }

    func onNextInspection(_ action: @escaping @Sendable () -> Int32) {
        lock.lock(); defer { lock.unlock() }
        self.action = action
    }

    func inspect() -> SourceLockInspectionFault? {
        lock.lock()
        count += 1
        let action = self.action
        self.action = nil
        let fault = self.fault
        lock.unlock()
        if let action {
            let result = action()
            lock.lock(); status = result; lock.unlock()
        }
        return fault
    }
}