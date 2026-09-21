import Foundation
import SQLite3
import ImageIQCore

struct CachedPhoto: Sendable {
    let photo: IndexedPhoto
    let geographyVersion: String
}

/// A single actor owns one SQLite connection. No images or GPS are stored.
/// DELETE journaling avoids persistent WAL/SHM sidecars. The protected, backup-
/// excluded parent also covers transient rollback journals created by SQLite.
actor SQLitePhotoStore {
    let directory: URL
    private var connection: SQLiteConnection?

    init(directory: URL) { self.directory = directory }

    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
    }

    private func database() throws -> SQLiteConnection {
        if let connection { return connection }
        let opened = try SQLiteConnection(directory: directory)
        connection = opened
        return opened
    }

    func record(id: String) throws -> CachedPhoto? {
        let db = try database()
        return try db.statement(Self.select + " WHERE p.id = ?") { statement in
            try db.bind(id, at: 1, to: statement)
            return try db.next(statement) ? decode(statement) : nil
        }
    }

    func records(modelVersion: String) throws -> [CachedPhoto] {
        let db = try database()
        return try db.statement(Self.select + " WHERE p.model_version = ? ORDER BY p.id") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            var result: [CachedPhoto] = []
            while try db.next(statement) {
                try Task.checkCancellation()
                result.append(try decode(statement))
            }
            return result
        }
    }

    func place(text: String, modelVersion: String) throws -> [Float]? {
        let db = try database()
        return try db.statement("SELECT embedding FROM places WHERE text = ? AND model_version = ?") { statement in
            try db.bind(text, at: 1, to: statement)
            try db.bind(modelVersion, at: 2, to: statement)
            guard try db.next(statement) else { return nil }
            let vector = try JSONDecoder().decode([Float].self, from: db.blob(statement, at: 0))
            try EmbeddingValidation.validateUnit(vector)
            return vector
        }
    }

    func save(_ cached: CachedPhoto) throws {
        try Task.checkCancellation()
        let photo = cached.photo
        guard photo.modificationTime.isFinite, photo.creationTime?.isFinite != false,
              !photo.id.isEmpty, !photo.modelVersion.isEmpty else { throw AppFailure.storage("Invalid photo metadata.") }
        try EmbeddingValidation.validateUnit(photo.imageEmbedding)
        if let place = photo.location { try EmbeddingValidation.validateUnit(place.vector) }
        let db = try database()
        try db.transaction {
            if let place = photo.location {
                try db.statement("INSERT OR REPLACE INTO places (text, model_version, embedding) VALUES (?, ?, ?)") { statement in
                    try db.bind(place.text, at: 1, to: statement)
                    try db.bind(photo.modelVersion, at: 2, to: statement)
                    try db.bind(JSONEncoder().encode(place.vector), at: 3, to: statement)
                    try db.execute(statement)
                }
            }
            try db.statement("""
                INSERT OR REPLACE INTO photos
                (id, revision, model_version, image_embedding, creation_time, place_text, geography_version)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """) { statement in
                try db.bind(photo.id, at: 1, to: statement)
                try db.bind(photo.modificationTime, at: 2, to: statement)
                try db.bind(photo.modelVersion, at: 3, to: statement)
                try db.bind(JSONEncoder().encode(photo.imageEmbedding), at: 4, to: statement)
                try db.bind(photo.creationTime, at: 5, to: statement)
                try db.bind(photo.location?.text, at: 6, to: statement)
                try db.bind(cached.geographyVersion, at: 7, to: statement)
                try db.execute(statement)
            }
            try Task.checkCancellation()
        }
    }

    /// Call ONLY after enumerateAuthorizedImages returns successfully. Cancellation
    /// rolls the whole reconciliation back; completed indexing writes remain reusable.
    func reconcile(completeEnumeration: [PhotoRevision]) throws {
        try Task.checkCancellation()
        let revisions = Dictionary(completeEnumeration.map { ($0.id, $0.modificationTime) }, uniquingKeysWith: { _, last in last })
        let db = try database()
        try db.transaction {
            let obsolete: [String] = try db.statement("SELECT id, revision FROM photos") { statement in
                var ids: [String] = []
                while try db.next(statement) {
                    try Task.checkCancellation()
                    let id = try db.string(statement, at: 0)
                    if revisions[id] != sqlite3_column_double(statement, 1) { ids.append(id) }
                }
                return ids
            }
            for id in obsolete {
                try Task.checkCancellation()
                try db.statement("DELETE FROM photos WHERE id = ?") { statement in
                    try db.bind(id, at: 1, to: statement)
                    try db.execute(statement)
                }
            }
            try db.exec("""
                DELETE FROM places WHERE NOT EXISTS
                (SELECT 1 FROM photos p WHERE p.place_text = places.text AND p.model_version = places.model_version)
                """)
            try Task.checkCancellation()
        }
    }

    func clear() throws {
        try Task.checkCancellation()
        // Also recovers an unreadable/unsupported database without first opening it.
        connection = nil
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let file = directory.appendingPathComponent("index.sqlite3" + suffix)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        _ = try database()
    }

    func close() { connection = nil }

    private static let select = """
        SELECT p.id, p.revision, p.model_version, p.image_embedding, p.creation_time,
               p.place_text, p.geography_version, l.embedding
        FROM photos p LEFT JOIN places l ON p.place_text = l.text AND p.model_version = l.model_version
        """

    private func decode(_ statement: OpaquePointer) throws -> CachedPhoto {
        let db = try database()
        let image = try JSONDecoder().decode([Float].self, from: db.blob(statement, at: 3))
        try EmbeddingValidation.validateUnit(image)
        var place: PlaceEmbedding?
        if sqlite3_column_type(statement, 5) != SQLITE_NULL {
            let vector = try JSONDecoder().decode([Float].self, from: db.blob(statement, at: 7))
            try EmbeddingValidation.validateUnit(vector)
            place = PlaceEmbedding(text: try db.string(statement, at: 5), vector: vector)
        }
        let photo = IndexedPhoto(id: try db.string(statement, at: 0), modificationTime: sqlite3_column_double(statement, 1),
                                 modelVersion: try db.string(statement, at: 2), imageEmbedding: image, location: place,
                                 creationTime: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 4))
        return CachedPhoto(photo: photo, geographyVersion: try db.string(statement, at: 6))
    }
}

/// Private synchronous implementation, never handed outside SQLitePhotoStore.
private final class SQLiteConnection {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let file = directory.appendingPathComponent("index.sqlite3")
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(file.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw AppFailure.storage("Unable to open SQLite (\(result)).")
        }
        handle = pointer
        // Clear the handle on failure so initialization cleanup cannot close twice.
        do {
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            var excludedFile = file
            try excludedFile.setResourceValues(values)
            try exec("PRAGMA journal_mode = DELETE")
            try exec("PRAGMA synchronous = FULL")
            try exec("PRAGMA secure_delete = ON")
            let version = try statement("PRAGMA user_version") { statement -> Int32 in
                guard try next(statement) else { throw AppFailure.storage("Missing schema version.") }
                return sqlite3_column_int(statement, 0)
            }
            guard version == 0 || version == 1 else { throw AppFailure.storage("Unsupported cache schema version.") }
            try transaction {
                try exec("""
                    CREATE TABLE IF NOT EXISTS photos (
                        id TEXT PRIMARY KEY NOT NULL, revision REAL NOT NULL, model_version TEXT NOT NULL,
                        image_embedding BLOB NOT NULL, creation_time REAL, place_text TEXT,
                        geography_version TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS places (
                        text TEXT NOT NULL, model_version TEXT NOT NULL, embedding BLOB NOT NULL,
                        PRIMARY KEY (text, model_version));
                    PRAGMA user_version = 1;
                    """)
            }
        } catch {
            sqlite3_close(pointer)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func transaction(_ operation: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try operation(); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw failure()
    }

    func execute(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let status: Int32
        if let value {
            status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        } else { status = sqlite3_bind_null(statement, index) }
        guard status == SQLITE_OK else { throw failure() }
    }

    func bind(_ value: Double?, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.map { sqlite3_bind_double(statement, index, $0) } ?? sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw failure() }
    }

    func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient) }
        guard status == SQLITE_OK else { throw failure() }
    }

    func string(_ statement: OpaquePointer, at index: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, index) else { throw AppFailure.storage("Missing text column.") }
        return String(cString: value)
    }

    func blob(_ statement: OpaquePointer, at index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { throw AppFailure.storage("Missing embedding column.") }
        return Data(bytes: pointer, count: count)
    }

    private func failure() -> AppFailure {
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? "Unknown SQLite error"
        return .storage(message)
    }
}