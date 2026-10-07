import Darwin
import Foundation
import SQLite3

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
    private var invalidated = false

    init(directory: URL) throws {
        self.directory = directory
        file = directory.appendingPathComponent("index.sqlite3")
        identity = try Self.readIdentity(directory: directory, file: file)
        // A missing index is a valid empty source, but its later appearance is
        // not. Do not create even the parent directory or an empty database.
        guard identity != nil else { return }
        try requireNoSidecars()
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw Self.changed()
        }
        handle = pointer
        do {
            guard sqlite3_db_readonly(pointer, "main") == 1 else { throw Self.changed() }
            // The app's image store uses DELETE journaling. Like SearchIndexCache,
            // do not claim the rollback-journal lock test covers WAL writers.
            let mode = try statement("PRAGMA journal_mode") { query -> String in
                guard let text = sqlite3_column_text(query, 0) else { throw Self.changed() }
                return String(cString: text)
            }
            guard mode == "delete" else { throw Self.changed() }
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
        guard !invalidated else { throw Self.changed() }
        do {
            guard try Self.readIdentity(directory: directory, file: file) == identity else { throw Self.changed() }
            if identity != nil {
                try requireNoSidecars()
                guard try dataVersion() == version else { throw Self.changed() }
                try requireNoSidecars()
                guard try Self.readIdentity(directory: directory, file: file) == identity else { throw Self.changed() }
            }
        } catch {
            invalidated = true
            throw Self.changed()
        }
        try Task.checkCancellation()
    }

    private static func changed() -> AppFailure {
        .storage("The image index changed or is unavailable. Run similarity grouping again.")
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
        var file: UnsafeMutablePointer<sqlite3_file>?
        guard let handle,
              sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK,
              let file, let methods = file.pointee.pMethods,
              let checkLock = methods.pointee.xCheckReservedLock else { throw Self.changed() }
        var reserved: Int32 = 0
        guard checkLock(file, &reserved) == SQLITE_OK, reserved == 0 else { throw Self.changed() }
    }

    private func statement<T>(_ sql: String, read: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        defer { if let query { sqlite3_finalize(query) } }
        guard let handle, sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK,
              let query, sqlite3_step(query) == SQLITE_ROW else { throw Self.changed() }
        return try read(query)
    }

    private func requireNoSidecars() throws {
        for suffix in ["-journal", "-wal", "-shm"] {
            guard try Self.attributes(URL(fileURLWithPath: file.path + suffix)) == nil else { throw Self.changed() }
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

    private static func attributes(_ url: URL) throws -> stat? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return nil }
            throw changed()
        }
        return info
    }

    private static func readIdentity(directory: URL, file: URL) throws -> FileIdentity? {
        if let parent = try attributes(directory) {
            guard (parent.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else { throw changed() }
        }
        guard let info = try attributes(file) else { return nil }
        // Same no-follow convention as the completed cache; never trust a
        // symlink, nonregular object or multiply-linked source as live authority.
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1 else { throw changed() }
        return FileIdentity(info)
    }
}