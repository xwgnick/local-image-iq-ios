import CryptoKit
import Foundation
import SQLite3
import ImageIQCore

struct CachedPhoto: Sendable {
    let photo: IndexedPhoto
    let geographyVersion: String
}

/// Cleanup identity deliberately excludes places, geography, OCR and SQLite file
/// layout. Revisions include stale active-model rows for accurate coverage counts.
struct SimilarGroupingInputSnapshot: Sendable, Equatable {
    let revisions: [String: PhotoRevision]
    let imagePayloadSignature: Data
}

/// A single actor owns one SQLite connection. No images or GPS are stored.
/// DELETE journaling avoids persistent WAL/SHM sidecars. The protected, backup-
/// excluded parent also covers transient rollback journals created by SQLite.
actor SQLitePhotoStore {
    let directory: URL
    private let readOnly: Bool
    private var connection: SQLiteConnection?

    init(directory: URL, readOnly: Bool = false) {
        self.directory = directory
        self.readOnly = readOnly
    }

    static func defaultDirectory(create: Bool = true) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: create)
        return support.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
    }

    private func database(cleanupDiagnostics: Bool = false) throws -> SQLiteConnection {
        if let connection, connection.cleanupDiagnostics == cleanupDiagnostics { return connection }
        // Do not leak cleanup's typed errors into normal search/write callers,
        // or reuse a legacy diagnostic mode for a cleanup read.
        connection = nil
        let opened = try SQLiteConnection(directory: directory, readOnly: readOnly, cleanupDiagnostics: cleanupDiagnostics)
        connection = opened
        return opened
    }

    /// One SELECT establishes a consistent cached-gallery snapshot and checks
    /// target row presence even under an older model. No obsolete vectors are
    /// decoded for that presence check. The private read-only handle is closed
    /// on every exit, BEFORE the caller starts any Photos/encoder work.
    func diagnosticSnapshot(modelVersion: String, selectedID: String) throws
        -> (records: [CachedPhoto], selectedExists: Bool) {
        guard readOnly else { throw AppFailure.storage("Diagnostics require a read-only cache connection.") }
        defer { connection = nil }
        try Task.checkCancellation()
        let file = directory.appendingPathComponent("index.sqlite3")
        guard FileManager.default.fileExists(atPath: file.path) else { return ([], false) }
        let db = try database()
        return try db.statement(Self.select + " WHERE p.model_version = ? OR p.id = ? ORDER BY p.id") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            try db.bind(selectedID, at: 2, to: statement)
            var records: [CachedPhoto] = []
            var selectedExists = false
            while try db.next(statement) {
                try Task.checkCancellation()
                if try db.string(statement, at: 0) == selectedID { selectedExists = true }
                if try db.string(statement, at: 2) == modelVersion { records.append(try decode(statement)) }
            }
            try Task.checkCancellation()
            return (records, selectedExists)
        }
    }

    private func requireWritable() throws {
        guard !readOnly else { throw AppFailure.storage("This cache connection is read-only.") }
    }

    /// Automatic launch/refresh never creates or changes a database. A fresh
    /// install has no index yet, which is a normal empty result, not corruption.
    func storedCounts(modelVersion: String, geographyVersion: String) throws -> (indexed: Int, located: Int) {
        guard readOnly else { throw AppFailure.storage("Stored counts require a read-only connection.") }
        defer { connection = nil }
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path) else {
            return (0, 0)
        }
        return try counts(modelVersion: modelVersion, geographyVersion: geographyVersion)
    }

    /// Access filtering happens before vector decoding. Inaccessible rows do not
    /// contribute to scores, place means, or errors about their vector contents.
    /// This is a SELECT-only handle, never an implicit update/prune operation.
    func searchRecords(modelVersion: String, accessibleIDs: Set<String>) throws -> [CachedPhoto] {
        guard readOnly else { throw AppFailure.storage("Search requires a read-only connection.") }
        defer { connection = nil }
        try Task.checkCancellation()
        guard !accessibleIDs.isEmpty,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path) else { return [] }
        let db = try database()
        return try db.statement(Self.select + " WHERE p.model_version = ? ORDER BY p.id") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            var records: [CachedPhoto] = []
            while try db.next(statement) {
                try Task.checkCancellation()
                guard accessibleIDs.contains(try db.string(statement, at: 0)) else { continue }
                records.append(try decode(statement))
            }
            try Task.checkCancellation()
            return records
        }
    }

    /// Manual text indexing needs only active-image IDs/revisions, not pixels,
    /// embeddings, place joins, migrations or an image-cache reconciliation.
    func searchRevisions(modelVersion: String, accessibleIDs: Set<String>) throws -> [String: Double] {
        guard readOnly else { throw AppFailure.storage("Search revisions require a read-only connection.") }
        defer { connection = nil }
        try Task.checkCancellation()
        guard !accessibleIDs.isEmpty,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path) else { return [:] }
        let db = try database()
        return try db.statement("SELECT id, revision FROM photos WHERE model_version = ? ORDER BY id") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            var revisions: [String: Double] = [:]
            while try db.next(statement) {
                try Task.checkCancellation()
                let id = try db.string(statement, at: 0)
                guard accessibleIDs.contains(id) else { continue }
                revisions[id] = sqlite3_column_double(statement, 1)
            }
            try Task.checkCancellation()
            return revisions
        }
    }

    /// Grouping requires the full cached revision, including a nullable creation
    /// time. Read metadata only so stale rows are excluded before vector decoding.
    func searchPhotoRevisions(modelVersion: String, accessibleIDs: Set<String>) throws -> [String: PhotoRevision] {
        guard readOnly else { throw AppFailure.storage("Search revisions require a read-only connection.") }
        defer { connection = nil }
        try Task.checkCancellation()
        guard !accessibleIDs.isEmpty,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path) else { return [:] }
        let db = try database()
        return try db.statement("SELECT id, revision, creation_time FROM photos WHERE model_version = ? ORDER BY id") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            var revisions: [String: PhotoRevision] = [:]
            while try db.next(statement) {
                try Task.checkCancellation()
                let id = try db.string(statement, at: 0)
                guard accessibleIDs.contains(id) else { continue }
                revisions[id] = PhotoRevision(id: id, modificationTime: sqlite3_column_double(statement, 1),
                                              creationTime: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2))
            }
            try Task.checkCancellation()
            return revisions
        }
    }

    /// One read-only SELECT, BINARY UTF-8 ordering and length-framed hashing.
    /// Only authorized active-model rows enter the digest; image BLOBs are hashed
    /// row by row WITHOUT JSON decoding or retaining all source vector bytes.
    func groupingInputSnapshot(modelVersion: String, accessibleIDs: Set<String>,
                               authority: SimilarGroupingSourceAuthority? = nil) throws -> SimilarGroupingInputSnapshot {
        guard readOnly else { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexUnavailable) }
        defer { connection = nil }
        try Task.checkCancellation()
        try authority?.validate()
        var hash = SHA256()
        SimilarGroupingDigest.frame(Data("grouping-image-input-v1".utf8), into: &hash)
        SimilarGroupingDigest.frame(Data(modelVersion.utf8), into: &hash)
        var revisions: [String: PhotoRevision] = [:]
        let file = directory.appendingPathComponent("index.sqlite3")
        // Unlike fileExists, an unreadable existing index is not an empty index.
        if try Self.groupingFileExists(file) {
            let db = try database(cleanupDiagnostics: true)
            let exactIDs = Set(accessibleIDs.map { Data($0.utf8) })
            try db.statement("SELECT id, revision, creation_time, model_version, image_embedding FROM photos WHERE model_version = ? ORDER BY id COLLATE BINARY") { statement in
                try db.bind(modelVersion, at: 1, to: statement)
                while try db.next(statement) {
                    try Task.checkCancellation()
                    let id = try db.groupingString(statement, at: 0)
                    guard exactIDs.contains(Data(id.utf8)) else { continue }
                    let model = try db.groupingString(statement, at: 3)
                    guard Data(model.utf8) == Data(modelVersion.utf8) else { continue }
                    let revision = PhotoRevision(id: id, modificationTime: sqlite3_column_double(statement, 1),
                                                 creationTime: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2))
                    try SimilarGroupingDigest.validate(revision)
                    guard revisions[id] == nil else {
                        throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexDuplicateIdentity)
                    }
                    revisions[id] = revision
                    SimilarGroupingDigest.revision(revision, into: &hash)
                    SimilarGroupingDigest.frame(Data(model.utf8), into: &hash)
                    // A malformed/empty stale BLOB can still be fingerprinted.
                    // Eligible vectors are validated only by groupingImageRecords.
                    let count = Int(sqlite3_column_bytes(statement, 4))
                    let bytes: Data
                    if count == 0 { bytes = Data() }
                    else { bytes = try db.blob(statement, at: 4) }
                    SimilarGroupingDigest.frame(bytes, into: &hash)
                }
            }
        }
        SimilarGroupingDigest.frame(SimilarGroupingDigest.bits(UInt64(revisions.count)), into: &hash)
        try Task.checkCancellation()
        try authority?.validate()
        return SimilarGroupingInputSnapshot(revisions: revisions, imagePayloadSignature: Data(hash.finalize()))
    }

    /// Manual grouping's image-only reader: no place JOIN/JSON, even if an
    /// irrelevant location BLOB is malformed. Restore never calls this method.
    func groupingImageRecords(modelVersion: String, accessibleIDs: Set<String>, eligibleIDs: Set<String>,
                              expectedSnapshot: SimilarGroupingInputSnapshot,
                              authority: SimilarGroupingSourceAuthority? = nil) throws -> [IndexedPhoto] {
        guard readOnly else { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexUnavailable) }
        defer { connection = nil }
        try Task.checkCancellation()
        try authority?.validate()
        guard try Self.groupingFileExists(directory.appendingPathComponent("index.sqlite3")) else {
            guard expectedSnapshot.revisions.isEmpty else {
                throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexSnapshotChanged)
            }
            try authority?.validate()
            return []
        }
        let db = try database(cleanupDiagnostics: true)
        let exactIDs = Set(accessibleIDs.map { Data($0.utf8) })
        let exactEligibleIDs = Set(eligibleIDs.map { Data($0.utf8) })
        return try db.statement("SELECT id, revision, creation_time, model_version, image_embedding FROM photos WHERE model_version = ? ORDER BY id COLLATE BINARY") { statement in
            try db.bind(modelVersion, at: 1, to: statement)
            var photos: [IndexedPhoto] = []
            var revisions: [String: PhotoRevision] = [:]
            var hash = SHA256()
            SimilarGroupingDigest.frame(Data("grouping-image-input-v1".utf8), into: &hash)
            SimilarGroupingDigest.frame(Data(modelVersion.utf8), into: &hash)
            while try db.next(statement) {
                try Task.checkCancellation()
                let id = try db.groupingString(statement, at: 0)
                guard exactIDs.contains(Data(id.utf8)) else { continue }
                let model = try db.groupingString(statement, at: 3)
                guard Data(model.utf8) == Data(modelVersion.utf8) else { continue }
                let revision = PhotoRevision(id: id, modificationTime: sqlite3_column_double(statement, 1),
                                             creationTime: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2))
                try SimilarGroupingDigest.validate(revision)
                guard revisions[id] == nil else {
                    throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexDuplicateIdentity)
                }
                revisions[id] = revision
                SimilarGroupingDigest.revision(revision, into: &hash)
                SimilarGroupingDigest.frame(Data(model.utf8), into: &hash)
                let bytes: Data
                if sqlite3_column_bytes(statement, 4) == 0 { bytes = Data() }
                else { bytes = try db.blob(statement, at: 4) }
                SimilarGroupingDigest.frame(bytes, into: &hash)
                guard exactEligibleIDs.contains(Data(id.utf8)) else { continue }
                let vector = try Self.decodeEmbedding(bytes)
                try EmbeddingValidation.validateUnit(vector, dimension: 768)
                photos.append(IndexedPhoto(id: id, modificationTime: revision.modificationTime,
                                           modelVersion: model, imageEmbedding: vector, location: nil,
                                           creationTime: revision.creationTime))
            }
            SimilarGroupingDigest.frame(SimilarGroupingDigest.bits(UInt64(revisions.count)), into: &hash)
            let actual = SimilarGroupingInputSnapshot(revisions: revisions, imagePayloadSignature: Data(hash.finalize()))
            guard actual == expectedSnapshot else {
                throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexSnapshotChanged)
            }
            try Task.checkCancellation()
            try authority?.validate()
            return photos
        }
    }

    private static func groupingFileExists(_ file: URL) throws -> Bool {
        do { return try SimilarGroupingCache.regularFileExists(file) }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SimilarCleanupDiagnostic.classify(error, phase: .indexRead)
        }
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

    /// Display-only metadata counts, not vector validation. No embeddings are read.
    /// Cancellation is checked around SQLite work; it cannot interrupt the aggregate's sqlite3_step.
    func counts(modelVersion: String, geographyVersion: String) throws -> (indexed: Int, located: Int) {
        try Task.checkCancellation()
        let db = try database()
        try Task.checkCancellation()
        let result = try db.statement("""
            SELECT COUNT(*), COALESCE(SUM(CASE WHEN p.place_text IS NOT NULL
                AND p.geography_version = ? AND l.text IS NOT NULL THEN 1 ELSE 0 END), 0)
            FROM photos p LEFT JOIN places l ON p.place_text = l.text AND p.model_version = l.model_version
            WHERE p.model_version = ?
            """) { statement -> (indexed: Int, located: Int) in
            try db.bind(geographyVersion, at: 1, to: statement)
            try db.bind(modelVersion, at: 2, to: statement)
            try Task.checkCancellation()
            guard try db.next(statement) else { throw AppFailure.storage("Missing cache counts.") }
            try Task.checkCancellation()
            return (Int(sqlite3_column_int64(statement, 0)), Int(sqlite3_column_int64(statement, 1)))
        }
        try Task.checkCancellation()
        return result
    }

    func place(text: String, modelVersion: String) throws -> [Float]? {
        let db = try database()
        return try db.statement("SELECT embedding FROM places WHERE text = ? AND model_version = ?") { statement in
            try db.bind(text, at: 1, to: statement)
            try db.bind(modelVersion, at: 2, to: statement)
            guard try db.next(statement) else { return nil }
            return try Self.decodeEmbedding(db.blob(statement, at: 0))
        }
    }

    func save(_ cached: CachedPhoto) throws {
        try Task.checkCancellation()
        try requireWritable()
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
        try requireWritable()
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
            try Task.checkCancellation()
            // Form the orphan key set once. A compound NOT IN can fall back to
            // scanning its RHS on misses; EXCEPT also preserves BINARY key pairs.
            try db.exec("""
                DELETE FROM places WHERE (text, model_version) IN
                (SELECT text, model_version FROM places
                 EXCEPT SELECT place_text, model_version FROM photos WHERE place_text IS NOT NULL)
                """)
            try Task.checkCancellation()
        }
    }

    func clear() throws {
        try Task.checkCancellation()
        try requireWritable()
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

    /// Old records must decode before the worker can reject their model version
    /// and replace them. This compatibility path is read-only; save still requires 768.
    private static func decodeEmbedding(_ data: Data) throws -> [Float] {
        let vector = try JSONDecoder().decode([Float].self, from: data)
        guard vector.count == 512 || vector.count == 768 else {
            throw AppFailure.modelContract("Cached embeddings must have 512 legacy or 768 active values.")
        }
        try EmbeddingValidation.validateUnit(vector, dimension: vector.count)
        return vector
    }

    private func decode(_ statement: OpaquePointer) throws -> CachedPhoto {
        let db = try database()
        let image = try Self.decodeEmbedding(db.blob(statement, at: 3))
        var place: PlaceEmbedding?
        if sqlite3_column_type(statement, 5) != SQLITE_NULL {
            let vector = try Self.decodeEmbedding(db.blob(statement, at: 7))
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
    let cleanupDiagnostics: Bool

    init(directory: URL, readOnly: Bool = false, cleanupDiagnostics: Bool = false) throws {
        self.cleanupDiagnostics = cleanupDiagnostics
        let manager = FileManager.default
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        if !readOnly {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            var excluded = directory
            try excluded.setResourceValues(values)
        }
        let file = directory.appendingPathComponent("index.sqlite3")
        var pointer: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
        let result = sqlite3_open_v2(file.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let pointer else {
            let native = cleanupDiagnostics ? Self.nativeCode(pointer, status: result) : result
            if let pointer { sqlite3_close(pointer) }
            if cleanupDiagnostics {
                throw SimilarCleanupDiagnostic(phase: .indexRead,
                    code: result == SQLITE_OK ? .indexUnavailable : .indexOpen,
                    nativeCode: result == SQLITE_OK ? nil : native)
            }
            throw AppFailure.storage("Unable to open SQLite (\(result)).")
        }
        handle = pointer
        // Clear the handle on failure so initialization cleanup cannot close twice.
        do {
            if !readOnly {
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                var excludedFile = file
                try excludedFile.setResourceValues(values)
                try exec("PRAGMA journal_mode = DELETE")
                try exec("PRAGMA synchronous = FULL")
                try exec("PRAGMA secure_delete = ON")
            }
            let version = try statement("PRAGMA user_version") { statement -> Int32 in
                guard try next(statement) else {
                    if cleanupDiagnostics { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexSchemaMissing) }
                    throw AppFailure.storage("Missing schema version.")
                }
                return sqlite3_column_int(statement, 0)
            }
            if readOnly {
                guard version == 1 else {
                    if cleanupDiagnostics { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexSchemaUnsupported) }
                    throw AppFailure.storage("Unsupported cache schema version.")
                }
                return
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
        guard status == SQLITE_OK, let statement else {
            if cleanupDiagnostics {
                let diagnostic = failure(code: status == SQLITE_OK ? .indexUnavailable : .indexPrepare,
                                         status: status == SQLITE_OK ? nil : status)
                if let statement { sqlite3_finalize(statement) }
                throw diagnostic
            }
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        return try operation(statement)
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw failure(code: .indexStep, status: status)
    }

    func execute(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let status: Int32
        if let value {
            status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        } else { status = sqlite3_bind_null(statement, index) }
        guard status == SQLITE_OK else { throw failure(code: .indexBind, status: status) }
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

    /// Exact UTF-8 (including framing-sensitive bytes), rather than C-string
    /// termination. Kept local to the new cleanup reads; legacy APIs are intact.
    func groupingString(_ statement: OpaquePointer, at index: Int32) throws -> String {
        guard let pointer = sqlite3_column_text(statement, index) else {
            if cleanupDiagnostics { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexMetadataMissing) }
            throw AppFailure.storage("Missing grouping metadata.")
        }
        let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        guard let value = String(data: bytes, encoding: .utf8) else {
            if cleanupDiagnostics { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexMetadataInvalid) }
            throw AppFailure.storage("Invalid grouping metadata.")
        }
        return value
    }

    func blob(_ statement: OpaquePointer, at index: Int32) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
            if cleanupDiagnostics { throw SimilarCleanupDiagnostic(phase: .indexRead, code: .indexBlobMissing) }
            throw AppFailure.storage("Missing embedding column.")
        }
        return Data(bytes: pointer, count: count)
    }

    private static func nativeCode(_ handle: OpaquePointer?, status: Int32) -> Int32 {
        guard let handle else { return status }
        let extended = sqlite3_extended_errcode(handle)
        return extended != SQLITE_OK && (extended & 0xff) == (status & 0xff) ? extended : status
    }

    private func failure(code: SimilarCleanupDiagnostic.Code = .indexUnavailable, status: Int32? = nil) -> Error {
        if cleanupDiagnostics {
            return SimilarCleanupDiagnostic(phase: .indexRead, code: code,
                nativeCode: status.map { Self.nativeCode(handle, status: $0) })
        }
        let message = sqlite3_errmsg(handle).map { String(cString: $0) } ?? "Unknown SQLite error"
        return AppFailure.storage(message)
    }
}