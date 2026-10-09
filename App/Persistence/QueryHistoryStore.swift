import Darwin
import Foundation
import UIKit

@MainActor
protocol QueryHistoryStoring {
    func load() throws -> [String]
    func save(_ queries: [String]) throws
}

enum QueryHistoryStoreError: Error, LocalizedError {
    case unavailable, invalid

    var errorDescription: String? { "无法读取或保存本机搜索记录。请解锁设备后重试。" }
}

/// Local query text only, outside the image/OCR index and outside UserDefaults.
/// Init is inert. Missing reads create nothing; locked reads/writes fail without
/// treating existing protected data as an empty history. No query/error logging.
@MainActor
struct QueryHistoryStore: QueryHistoryStoring {
    static let directoryName = "LocalImageIQQueryHistory"
    static let fileName = "recent-queries-v1.json"
    static let fileProtection: FileProtectionType = .complete
    static let excludedFromBackup = true
    static var fileAttributes: [FileAttributeKey: Any] {
        [.protectionKey: fileProtection, .posixPermissions: 0o600]
    }

    private let suppliedDirectory: URL?
    private let protectedDataAvailable: @MainActor () -> Bool
    // Deterministic pre-commit fault/cancellation seam; no production retries.
    private let beforeCommit: @MainActor () throws -> Void

    init(directory: URL? = nil,
            protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
            beforeCommit: @escaping @MainActor () throws -> Void = {}) {
        suppliedDirectory = directory
        self.protectedDataAvailable = protectedDataAvailable
        self.beforeCommit = beforeCommit
    }

    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: false)
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    func load() throws -> [String] {
        try requireAvailable()
        do {
            let directory = try suppliedDirectory ?? Self.defaultDirectory()
            let file = directory.appendingPathComponent(Self.fileName)
            guard try Self.isItem(directory, type: .typeDirectory),
                  try Self.isItem(file, type: .typeRegular) else { return [] }
            try requireAvailable()
            let bytes = try Data(contentsOf: file)
            try requireAvailable()
            let queries: [String]
            do { queries = try JSONDecoder().decode([String].self, from: bytes) }
            catch { throw QueryHistoryStoreError.invalid }
            return RecentSearchQueries.normalized(queries)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QueryHistoryStoreError {
            throw error
        } catch {
            throw QueryHistoryStoreError.unavailable
        }
    }

    /// Empty history is an atomic JSON replacement too. It does not delete an
    /// index, mutate Photos, or promise secure erasure of filesystem remnants.
    func save(_ queries: [String]) throws {
        try requireAvailable()
        do {
            let bytes = try JSONEncoder().encode(RecentSearchQueries.normalized(queries))
            let directory = try suppliedDirectory ?? Self.defaultDirectory()
            let manager = FileManager.default
            if try Self.isItem(directory, type: .typeDirectory) == false {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: Self.fileProtection])
            }
            try manager.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: directory.path)
            try Self.excludeFromBackup(directory)
            let destination = directory.appendingPathComponent(Self.fileName)
            _ = try Self.isItem(destination, type: .typeRegular)
            let temporary = directory.appendingPathComponent(".query-history-\(UUID().uuidString).tmp")
            // Create an empty, protected file; exclude it before writing any text.
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: Self.fileAttributes) else {
                throw QueryHistoryStoreError.unavailable
            }
            defer { try? manager.removeItem(at: temporary) }
            try Self.excludeFromBackup(temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try requireAvailable()
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            try handle.close()
            try beforeCommit()
            try requireAvailable()
            _ = try Self.isItem(destination, type: .typeRegular)
            // Same-directory rename publishes the already-protected/excluded
            // inode atomically, including replacement of an existing history.
            let status = temporary.path.withCString { from in
                destination.path.withCString { to in Darwin.rename(from, to) }
            }
            guard status == 0 else { throw QueryHistoryStoreError.unavailable }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QueryHistoryStoreError {
            throw error
        } catch {
            throw QueryHistoryStoreError.unavailable
        }
    }

    private func requireAvailable() throws {
        try Task.checkCancellation()
        guard protectedDataAvailable() else { throw QueryHistoryStoreError.unavailable }
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excludedFromBackup
        try url.setResourceValues(values)
    }

    /// Missing is distinct from unreadable. Do not follow a direct symlink into
    /// another store, and never overwrite a directory with query data.
    private static func isItem(_ url: URL, type: FileAttributeType) throws -> Bool {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == type else { throw QueryHistoryStoreError.invalid }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }
}