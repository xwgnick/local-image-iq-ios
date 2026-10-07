import Darwin
import Foundation
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Real temporary SQLite and explicit synthetic Application Support aliases.
/// No Photos, permissions, model resources, inference or production data.
final class SimilarGroupingLocationTests: XCTestCase {
    private typealias Diagnostic = SimilarCleanupDiagnostic
    private let model = "test-model"

    func testRawNoFollowAndStrictInjectedAncestorAliasStillReject1550() throws {
        let f = try fixture()
        let strict = SimilarGroupingLocation(directory: f.originalDirectory)
        XCTAssertEqual(strict.directory, f.originalDirectory)
        XCTAssertEqual(strict.originalDirectory, f.originalDirectory)
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(f.originalFile.path, &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        XCTAssertEqual(rc, SQLITE_CANTOPEN)
        let extended = sqlite3_extended_errcode(try XCTUnwrap(pointer))
        XCTAssertEqual(extended, SQLITE_CANTOPEN | (6 << 8))
        let expected = Diagnostic(phase: .sourceOpen, code: .sourceOpen, nativeCode: extended)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(directory: f.originalDirectory) }, expected)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(location: strict) }, expected)
    }

    func testTrustedBaseLinkReadsIdenticalSnapshotsVectorsAndBytesWithSixteenProbes() async throws {
        let f = try fixture()
        XCTAssertEqual(f.location.directory.path, f.directory.path)
        XCTAssertEqual(f.location.originalDirectory.path, f.originalDirectory.path)
        let before = try Data(contentsOf: f.file)
        let probe = LocationLockProbe()
        let authority = try SimilarGroupingSourceAuthority(location: f.location, lockProbe: { probe.inspect() })
        let reader = SQLitePhotoStore(directory: f.location.directory, readOnly: true)
        let first = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"], authority: authority)
        let second = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"], authority: authority)
        let records = try await reader.groupingImageRecords(modelVersion: model, accessibleIDs: ["a"], eligibleIDs: ["a"],
            expectedSnapshot: first, authority: authority)
        XCTAssertEqual(probe.calls, 16, "No additional SQLite/VFS checks for dual-path validation.")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.revisions.count, 1)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try XCTUnwrap(records.first).imageEmbedding.map(\.bitPattern), TestFixtures.vector().map(\.bitPattern))
        let reference = SQLitePhotoStore(directory: f.directory, readOnly: true)
        let expected = try await reference.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"])
        XCTAssertEqual(first, expected)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertEqual(try names(f.directory), ["index.sqlite3"])
        XCTAssertEqual(try names(f.base), ["LocalImageIQIndex"])
        XCTAssertEqual(try names(f.root), ["alias", "physical"])
    }

    func testTrustedBaseWithNestedAncestorLinkResolvesOnlyTheBase() async throws {
        let f = try fixture(nested: true)
        XCTAssertEqual(f.location.directory.path, f.directory.path)
        XCTAssertEqual(f.location.originalDirectory.path, f.originalDirectory.path)
        let before = try Data(contentsOf: f.file)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        let reader = SQLitePhotoStore(directory: f.location.directory, readOnly: true)
        let source = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"], authority: authority)
        let reference = SQLitePhotoStore(directory: f.directory, readOnly: true)
        let expected = try await reference.groupingInputSnapshot(modelVersion: model, accessibleIDs: ["a"])
        XCTAssertEqual(source, expected)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        XCTAssertEqual(try names(f.directory), ["index.sqlite3"])
    }

    func testIndexDirectoryLinkUnderTrustedBaseIsNeverCanonicalized() throws {
        let f = try fixture()
        let moved = f.base.appendingPathComponent("other-index", isDirectory: true)
        try FileManager.default.moveItem(at: f.directory, to: moved)
        try FileManager.default.createSymbolicLink(atPath: f.directory.path, withDestinationPath: moved.path)
        let location = try SimilarGroupingLocation.applicationSupport(f.originalBase)
        XCTAssertEqual(location.directory.path, f.directory.path)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(location: location) }.code, .sourceParentSymlink)
    }

    func testSourceSymlinkHardlinkAndNonregularFileRetainExistingRejections() throws {
        let codes: [Diagnostic.Code] = [.sourceFileSymlink, .sourceFileLinks, .sourceFileKind]
        for (kind, code) in codes.enumerated() {
            let f = try fixture()
            let saved = f.directory.appendingPathComponent("saved.sqlite3")
            if kind == 1 {
                try FileManager.default.linkItem(at: f.file, to: saved)
            } else {
                try FileManager.default.moveItem(at: f.file, to: saved)
                if kind == 0 { try FileManager.default.createSymbolicLink(at: f.file, withDestinationURL: saved) }
                else { try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false) }
            }
            let location = try SimilarGroupingLocation.applicationSupport(f.originalBase)
            XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(location: location) }.code, code)
        }
    }

    func testAliasRetargetBetweenLocationCaptureAndAuthorityCreationFails() throws {
        let f = try fixture()
        let other = try replacementBase(f.root)
        try f.retarget(to: other)
        let probe = LocationLockProbe()
        XCTAssertEqual(try capture {
            _ = try SimilarGroupingSourceAuthority(location: f.location, lockProbe: { probe.inspect() })
        }.code, .sourceFileIdentityChanged)
        XCTAssertEqual(probe.calls, 0)
        // A fresh operation can explicitly capture the now-current system base.
        let fresh = try SimilarGroupingLocation.applicationSupport(f.originalBase)
        try SimilarGroupingSourceAuthority(location: fresh).validate()
    }

    func testObservedAliasRetargetInvalidatesAndStaysLatchedAfterRestoration() throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.file)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        let other = try replacementBase(f.root)
        try f.retarget(to: other)
        let first = try capture { try authority.validate() }
        XCTAssertEqual(first, .init(phase: .sourceCheck, code: .sourceFileIdentityChanged))
        try f.retarget(to: f.base)
        XCTAssertEqual(try capture { try authority.validate() }, first)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
        try SimilarGroupingSourceAuthority(location: f.location).validate()
    }

    func testRetargetWithBothDatabasesMissingIsNotAnEmptySourceSuccess() throws {
        let f = try fixture(seed: false)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        let other = try replacementBase(f.root, seed: false)
        try f.retarget(to: other)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.originalFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path))
        let first = try capture { try authority.validate() }
        XCTAssertEqual(first.code, .sourceFileIdentityChanged)
        try f.retarget(to: f.base)
        XCTAssertEqual(try capture { try authority.validate() }, first)
    }

    func testRemovingOriginalAliasIsDetectedEvenWithoutAnIndex() throws {
        let f = try fixture(seed: false)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        try FileManager.default.removeItem(at: f.alias)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.path))
    }

    func testLegitimateBaseMetadataChangesAndRealCacheSaveDoNotInvalidate() async throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.file)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        let reader = SQLitePhotoStore(directory: f.location.directory, readOnly: true)
        let source = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: [], authority: authority)
        let key = try SimilarGroupingCacheKey(authorized: [:], imagePayloadSignature: source.imagePayloadSignature,
            modelVersion: model, authorization: nil, threshold: 0.8)
        // Alter base metadata as well as the direct index directory's metadata.
        let sibling = f.base.appendingPathComponent("other-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        let cache = SimilarGroupingCache(directory: f.location.directory)
        try cache.save(groups: [], candidateCount: 0, staleCount: 0, unindexedCount: 0, key: key,
            authorized: [:], indexed: [:], validate: { try authority.validate() })
        try FileManager.default.removeItem(at: sibling)
        try authority.validate()
        guard case .restored(let result) = try cache.read(key: key, authorized: [:], indexed: [:]) else {
            XCTFail("Expected a real completed empty cache."); return
        }
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testAliasSidecarsKeepJournalWALSHMOrderAndLiveRejections() throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.file)
        let cases: [(String, Diagnostic.Code)] = [
            ("-journal", .sourceJournalPresent), ("-wal", .sourceWALPresent), ("-shm", .sourceSHMPresent)
        ]
        for (suffix, _) in cases { try Data().write(to: URL(fileURLWithPath: f.originalFile.path + suffix)) }
        for (suffix, code) in cases {
            XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(location: f.location) }.code, code)
            try FileManager.default.removeItem(at: URL(fileURLWithPath: f.originalFile.path + suffix))
        }
        for (suffix, code) in cases {
            let authority = try SimilarGroupingSourceAuthority(location: f.location)
            let sidecar = URL(fileURLWithPath: f.originalFile.path + suffix)
            // A dangling link is also present; it must not be silently followed.
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: f.root.appendingPathComponent("absent"))
            XCTAssertEqual(try capture { try authority.validate() }.code, code)
            try FileManager.default.removeItem(at: sidecar)
            XCTAssertEqual(try capture { try authority.validate() }.code, code)
        }
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testActualReservedWriterOpenedThroughAliasStillWinsBeforeFaultProbe() throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.file)
        let probe = LocationLockProbe()
        let authority = try SimilarGroupingSourceAuthority(location: f.location, lockProbe: { probe.inspect() })
        let writer = try LocationSQL(f.originalDirectory)
        try writer.exec("BEGIN IMMEDIATE")
        defer { _ = writer.execStatus("ROLLBACK") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.originalFile.path + "-journal"))
        let calls = probe.calls
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceWriterReserved)
        XCTAssertEqual(probe.calls, calls)
        XCTAssertEqual(try capture { _ = try SimilarGroupingSourceAuthority(location: f.location) }.code, .sourceWriterReserved)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testAliasWriterCommitBetweenStatAndPragmaKeepsDataVersionDiagnostic() throws {
        let f = try fixture()
        let writer = try LocationSQL(f.originalDirectory)
        let probe = LocationLockProbe()
        let authority = try SimilarGroupingSourceAuthority(location: f.location, lockProbe: { probe.inspect() })
        probe.onNextInspection { writer.execStatus("UPDATE photos SET revision = 456") }
        let first = try capture { try authority.validate() }
        XCTAssertEqual(probe.actionStatus, SQLITE_OK)
        XCTAssertEqual(first, .init(phase: .sourceCheck, code: .sourceDataVersionChanged))
        XCTAssertEqual(try capture { try authority.validate() }, first)
    }

    func testSameBytesSourceReplacementStillInvalidatesCanonicalAuthority() throws {
        let f = try fixture()
        let before = try Data(contentsOf: f.file)
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        // Retain the old inode rather than assuming the filesystem cannot reuse it.
        try FileManager.default.moveItem(at: f.file, to: f.directory.appendingPathComponent("previous.sqlite3"))
        try before.write(to: f.originalFile)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
        XCTAssertEqual(try Data(contentsOf: f.file), before)
    }

    func testMissingSupportAndIndexReadsCreateNothingAndPermitEmptyDirectoryAppearance() async throws {
        let root = try temporaryRoot()
        let base = root.appendingPathComponent("missing-support", isDirectory: true)
        let location = try SimilarGroupingLocation.applicationSupport(base)
        let authority = try SimilarGroupingSourceAuthority(location: location)
        let reader = SQLitePhotoStore(directory: location.directory, readOnly: true)
        let source = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: [], authority: authority)
        XCTAssertTrue(source.revisions.isEmpty)
        let key = try SimilarGroupingCacheKey(authorized: [:], imagePayloadSignature: source.imagePayloadSignature,
            modelVersion: model, authorization: nil, threshold: 0.8)
        let cache = SimilarGroupingCache(directory: location.directory)
        guard case .missing = try cache.read(key: key, authorized: [:], indexed: [:]) else {
            XCTFail("Missing directories must remain a read-only empty source."); return
        }
        XCTAssertEqual(try names(root), [])
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try authority.validate()
        try TestFixtures.seedRawCache([], directory: location.directory)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
    }

    func testMissingBaseCannotRetargetToAnotherMissingBase() throws {
        let f = try fixture(seed: false)
        let original = f.originalBase.appendingPathComponent("missing-support", isDirectory: true)
        let location = try SimilarGroupingLocation.applicationSupport(original)
        XCTAssertEqual(location.directory.path, f.base.appendingPathComponent("missing-support/LocalImageIQIndex").path)
        let authority = try SimilarGroupingSourceAuthority(location: location)
        let other = try replacementBase(f.root, seed: false)
        try f.retarget(to: other)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
        try f.retarget(to: f.base)
        XCTAssertEqual(try capture { try authority.validate() }.code, .sourceFileIdentityChanged)
    }

    func testBaseStatAndCanonicalKindFailuresKeepSanitizedDiagnostics() throws {
        let f = try fixture()
        XCTAssertEqual(try capture { _ = try SimilarGroupingLocation.applicationSupport(f.file) }.code, .sourceParentKind)
        let invalid = f.file.appendingPathComponent("synthetic-private-child")
        let statFailure = try capture { _ = try SimilarGroupingLocation.applicationSupport(invalid) }
        XCTAssertEqual(statFailure, .init(phase: .sourceCheck, code: .sourceParentStat, nativeCode: ENOTDIR))
        XCTAssertFalse(statFailure.message(operation: .restore).contains(f.root.path))
        XCTAssertFalse(statFailure.message(operation: .restore).contains("synthetic-private-child"))
        // Original alias still identifies the captured base, but its canonical
        // path has become a non-directory. Checking only the alias would pass.
        let moved = f.root.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: f.base, to: moved)
        try Data().write(to: URL(fileURLWithPath: f.base.path, isDirectory: false))
        try f.retarget(to: moved)
        XCTAssertEqual(try capture { try f.location.validate() }.code, .sourceParentKind)
    }

    func testCancellationWinsOverRetargetAndLatchedFailureWithoutLatchingCancellation() async throws {
        let f = try fixture()
        let authority = try SimilarGroupingSourceAuthority(location: f.location)
        let other = try replacementBase(f.root)
        try f.retarget(to: other)
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try authority.validate()
        }
        do { try await cancelled.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
        try f.retarget(to: f.base)
        try authority.validate() // Cancellation did not latch the unobserved change.
        try f.retarget(to: other)
        let first = try capture { try authority.validate() }
        try f.retarget(to: f.base)
        let cancelledAfterFailure = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try authority.validate()
        }
        do { try await cancelledAfterFailure.value; XCTFail("Expected cancellation before latched failure.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(first.code, .sourceFileIdentityChanged)
        XCTAssertEqual(try capture { try authority.validate() }, first)
    }

    private func temporaryRoot() throws -> URL {
        // Remove incidental simulator temp ancestors from the fixture; the
        // explicit alias below is the only link that this suite relies on.
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let pointer = root.path.withCString { Darwin.realpath($0, nil) }
        let path = try XCTUnwrap(pointer)
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }

    private func fixture(seed: Bool = true, nested: Bool = false) throws -> LocationFixture {
        let root = try temporaryRoot()
        let physical = root.appendingPathComponent("physical", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        let base = nested ? physical.appendingPathComponent("support", isDirectory: true) : physical
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: physical.path)
        let original = nested ? alias.appendingPathComponent("support", isDirectory: true) : alias
        if seed {
            try TestFixtures.seedRawCache([TestFixtures.photo(id: "a")],
                directory: base.appendingPathComponent("LocalImageIQIndex", isDirectory: true))
        }
        return LocationFixture(root: root, base: base, alias: alias, originalBase: original,
            location: try SimilarGroupingLocation.applicationSupport(original))
    }

    private func replacementBase(_ root: URL, seed: Bool = true) throws -> URL {
        let base = root.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        if seed {
            try TestFixtures.seedRawCache([TestFixtures.photo(id: "other")],
                directory: base.appendingPathComponent("LocalImageIQIndex", isDirectory: true))
        }
        return base
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func capture(_ operation: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) throws -> Diagnostic {
        do { try operation() }
        catch { return try XCTUnwrap(error as? Diagnostic, "Expected a typed diagnostic.", file: file, line: line) }
        XCTFail("Expected rejection.", file: file, line: line)
        throw LocationFixtureError.expectedFailure
    }
}

private struct LocationFixture: Sendable {
    let root: URL
    let base: URL
    let alias: URL
    let originalBase: URL
    let location: SimilarGroupingLocation
    var directory: URL { base.appendingPathComponent("LocalImageIQIndex", isDirectory: true) }
    var originalDirectory: URL { originalBase.appendingPathComponent("LocalImageIQIndex", isDirectory: true) }
    var file: URL { directory.appendingPathComponent("index.sqlite3") }
    var originalFile: URL { originalDirectory.appendingPathComponent("index.sqlite3") }

    func retarget(to base: URL) throws {
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: base.path)
    }
}

private enum LocationFixtureError: Error { case sqlite(Int32), expectedFailure }

private final class LocationSQL: @unchecked Sendable {
    private let handle: OpaquePointer
    private let lock = NSLock()

    init(_ directory: URL) throws {
        var pointer: OpaquePointer?
        let rc = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &pointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw LocationFixtureError.sqlite(rc)
        }
        handle = pointer
    }

    deinit { sqlite3_close(handle) }

    func execStatus(_ sql: String) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_exec(handle, sql, nil, nil, nil)
    }

    func exec(_ sql: String) throws {
        let rc = execStatus(sql)
        guard rc == SQLITE_OK else { throw LocationFixtureError.sqlite(rc) }
    }
}

private final class LocationLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var action: (@Sendable () -> Int32)?
    private var status: Int32?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    var actionStatus: Int32? { lock.lock(); defer { lock.unlock() }; return status }

    func onNextInspection(_ action: @escaping @Sendable () -> Int32) {
        lock.lock(); defer { lock.unlock() }
        self.action = action
    }

    func inspect() -> SourceLockInspectionFault? {
        lock.lock()
        count += 1
        let action = self.action
        self.action = nil
        lock.unlock()
        if let action {
            let result = action()
            lock.lock(); status = result; lock.unlock()
        }
        return nil
    }
}