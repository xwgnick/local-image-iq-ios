import Darwin
import Foundation
import SQLite3

/// Fault-only seam: nil keeps the real VFS result. No injected success can
/// override an actual failure; real file-control and lock checks always run.
enum SourceLockInspectionFault: Sendable {
    case unavailable(Int32), missingFile, missingMethod, failed(Int32), writer

    var diagnostic: SimilarCleanupDiagnostic {
        switch self {
        case .unavailable(let rc): return .init(phase: .sourceCheck, code: .sourceFileControl, nativeCode: rc)
        case .missingFile: return .init(phase: .sourceCheck, code: .sourceFilePointerMissing)
        case .missingMethod: return .init(phase: .sourceCheck, code: .sourceLockMethodMissing)
        case .failed(let rc): return .init(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: rc)
        case .writer: return .init(phase: .sourceCheck, code: .sourceWriterReserved)
        }
    }
}

/// Live authority for ONE grouping/restore operation, allocated before its first
/// SQLite snapshot. data_version is meaningful only on this retained connection.
/// No source BLOBs, hashes, migrations, busy timeout or write transactions here.
/// The lock protects synchronous result validators, including the MainActor fence.
final class SimilarGroupingSourceAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let file: URL
    private let identity: FileIdentity?
    private var handle: OpaquePointer?
    private var version: Int64?
    private var invalidated: SimilarCleanupDiagnostic?
    private let lockProbe: @Sendable () -> SourceLockInspectionFault?

    init(directory: URL, lockProbe: @escaping @Sendable () -> SourceLockInspectionFault? = { nil }) throws {
        self.directory = directory
        self.lockProbe = lockProbe
        file = directory.appendingPathComponent("index.sqlite3")
        identity = try Self.readIdentity(directory: directory, file: file)
        // A missing index is a valid empty source, but its later appearance is
        // not. Do not create even the parent directory or an empty database.
        guard identity != nil else { return }
        try requireNoSidecars()
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK else {
            let rc = Self.sqliteCode(pointer, status: status)
            if let pointer { sqlite3_close(pointer) }
            throw SimilarCleanupDiagnostic(phase: .sourceOpen, code: .sourceOpen, nativeCode: rc)
        }
        guard let pointer else {
            throw SimilarCleanupDiagnostic(phase: .sourceOpen, code: .sourceConnectionMissing)
        }
        handle = pointer
        do {
            let readOnly = sqlite3_db_readonly(pointer, "main")
            guard readOnly == 1 else {
                throw SimilarCleanupDiagnostic(phase: .sourceOpen, code: .sourceReadOnly, nativeCode: readOnly)
            }
            // The app's image store uses DELETE journaling. Like SearchIndexCache,
            // do not claim the rollback-journal lock test covers WAL writers.
            let mode = try statement("PRAGMA journal_mode") { query -> String in
                guard let text = sqlite3_column_text(query, 0) else {
                    throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceJournalModeMissing)
                }
                return String(cString: text)
            }
            if let diagnostic = Self.unsupportedJournalMode(mode) { throw diagnostic }
            version = try dataVersion()
            try validate()
        } catch {
            sqlite3_close(pointer)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    /// Constant-size metadata/PRAGMA work, with no full-library work on main.
    /// Conservative: ANY committed DB write invalidates this live authority.
    /// A later operation may still reuse groups via its fresh image-only digest.
    func validate() throws {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        if let invalidated { throw invalidated }
        do {
            guard try Self.readIdentity(directory: directory, file: file) == identity else {
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceFileIdentityChanged)
            }
            if identity != nil {
                try requireNoSidecars()
                guard try dataVersion() == version else {
                    throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceDataVersionChanged)
                }
                try requireNoSidecars()
                guard try Self.readIdentity(directory: directory, file: file) == identity else {
                    throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceFileIdentityChanged)
                }
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            let diagnostic = SimilarCleanupDiagnostic.classify(error, phase: .sourceCheck)
            invalidated = diagnostic
            throw diagnostic
        }
        try Task.checkCancellation()
    }

    /// Exact DELETE comparison is unchanged. Never retain/output unknown mode
    /// text, and never infer that a sidecar proves a live writer.
    static func unsupportedJournalMode(_ mode: String) -> SimilarCleanupDiagnostic? {
        let code: SimilarCleanupDiagnostic.Code
        switch mode {
        case "delete": return nil
        case "wal": code = .sourceJournalModeWAL
        case "memory": code = .sourceJournalModeMemory
        case "truncate": code = .sourceJournalModeTruncate
        case "persist": code = .sourceJournalModePersist
        case "off": code = .sourceJournalModeOff
        default: code = .sourceJournalModeUnknown
        }
        return SimilarCleanupDiagnostic(phase: .sourceCheck, code: code)
    }

    private func dataVersion() throws -> Int64 {
        try requireNoReservedWriter()
        let value = try statement("PRAGMA data_version") { sqlite3_column_int64($0, 0) }
        try requireNoReservedWriter()
        return value
    }

    /// Also detects BEGIN IMMEDIATE before a rollback journal has been created.
    /// It does NOT reserve the DB across Photos checks/publication. A writer that
    /// starts after our final check is the same unavoidable cross-store TOCTOU.
    private func requireNoReservedWriter() throws {
        guard let handle else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceConnectionMissing)
        }
        if let fault = Self.inspectLock(handle) ?? lockProbe() { throw fault.diagnostic }
    }

    private static func inspectLock(_ handle: OpaquePointer) -> SourceLockInspectionFault? {
        var file: UnsafeMutablePointer<sqlite3_file>?
        let rc = sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &file)
        guard rc == SQLITE_OK else { return .unavailable(rc) }
        guard let file else { return .missingFile }
        guard let methods = file.pointee.pMethods,
              let checkLock = methods.pointee.xCheckReservedLock else { return .missingMethod }
        var reserved: Int32 = 0
        let lockRC = checkLock(file, &reserved)
        guard lockRC == SQLITE_OK else { return .failed(lockRC) }
        return reserved == 0 ? nil : .writer
    }

    private func statement<T>(_ sql: String, read: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        defer { if let query { sqlite3_finalize(query) } }
        guard let handle else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceConnectionMissing)
        }
        let prepareRC = sqlite3_prepare_v2(handle, sql, -1, &query, nil)
        guard prepareRC == SQLITE_OK else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceQueryPrepare,
                                          nativeCode: Self.sqliteCode(handle, status: prepareRC))
        }
        guard let query else { throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceQueryMissing) }
        let stepRC = sqlite3_step(query)
        guard stepRC == SQLITE_ROW else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceQueryStep,
                                          nativeCode: Self.sqliteCode(handle, status: stepRC))
        }
        return try read(query)
    }

    private static func sqliteCode(_ handle: OpaquePointer?, status: Int32) -> Int32 {
        guard let handle else { return status }
        let extended = sqlite3_extended_errcode(handle)
        return extended != SQLITE_OK && (extended & 0xff) == (status & 0xff) ? extended : status
    }

    private func requireNoSidecars() throws {
        let sidecars: [(String, SimilarCleanupDiagnostic.Code, SimilarCleanupDiagnostic.Code)] = [
            ("-journal", .sourceJournalStat, .sourceJournalPresent),
            ("-wal", .sourceWALStat, .sourceWALPresent),
            ("-shm", .sourceSHMStat, .sourceSHMPresent)
        ]
        for (suffix, statCode, presentCode) in sidecars {
            guard try Self.attributes(URL(fileURLWithPath: file.path + suffix), failureCode: statCode) == nil else {
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: presentCode)
            }
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private static func attributes(_ url: URL, failureCode: SimilarCleanupDiagnostic.Code) throws -> stat? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT { return nil }
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: failureCode, nativeCode: savedErrno)
        }
        return info
    }

    private static func readIdentity(directory: URL, file: URL) throws -> FileIdentity? {
        if let parent = try attributes(directory, failureCode: .sourceParentStat) {
            guard (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                let code: SimilarCleanupDiagnostic.Code = (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                    ? .sourceParentSymlink : .sourceParentKind
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: code)
            }
        }
        guard let info = try attributes(file, failureCode: .sourceFileStat) else { return nil }
        // Same no-follow convention as the completed cache; never trust a
        // symlink, nonregular object or multiply-linked source as live authority.
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            let code: SimilarCleanupDiagnostic.Code = (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK)
                ? .sourceFileSymlink : .sourceFileKind
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: code)
        }
        guard info.st_nlink == 1 else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceFileLinks)
        }
        return FileIdentity(info)
    }
}