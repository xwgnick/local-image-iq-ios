import Foundation
import SQLite3
import ImageIQCore

/// Independent, optional, manually written OCR index in the image index's protected
/// directory. No image/vector schema changes, automatic pruning, or Photos access.
/// Reads (even on a writable store) never create a directory/database or migrate it.
actor SQLiteTextStore {
    let directory: URL
    private let readOnly: Bool
    private var connection: TextIndexDatabase?

    init(directory: URL, readOnly: Bool = false) {
        self.directory = directory
        self.readOnly = readOnly
    }

    private func database(writing: Bool = false) throws -> TextIndexDatabase? {
        if writing { try requireWritable() }
        if let connection, !writing || !connection.readOnly { return connection }
        connection = nil
        if !writing && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("text-index.sqlite3").path) {
            return nil
        }
        let opened = try TextIndexDatabase(directory: directory, readOnly: !writing)
        connection = opened
        return opened
    }

    private func requireWritable() throws {
        guard !readOnly else { throw AppFailure.storage("文字索引为只读，无法修改。") }
    }

    func record(id: String) throws -> PhotoTextRecord? {
        try Task.checkCancellation()
        guard let db = try database() else { return nil }
        return try db.statement("""
            SELECT id, revision, policy, text, pixel_width, pixel_height, is_reduced
            FROM text_records WHERE id = ? AND policy = ?
            """) { statement in
            try db.bind(id, at: 1, to: statement)
            try db.bind(PhotoTextPolicy.version, at: 2, to: statement)
            guard try db.next(statement) else { return nil }
            let record = PhotoTextRecord(id: try db.string(statement, at: 0),
                                         revision: sqlite3_column_double(statement, 1),
                                         policy: try db.string(statement, at: 2),
                                         text: try db.string(statement, at: 3),
                                         pixelWidth: Int(sqlite3_column_int64(statement, 4)),
                                         pixelHeight: Int(sqlite3_column_int64(statement, 5)),
                                         isReduced: sqlite3_column_int(statement, 6) != 0)
            try Task.checkCancellation()
            return record
        }
    }

    /// Empty completed OCR is a real record, so subsequent manual indexing can resume.
    /// Metadata, text, removal of obsolete postings and all new postings commit together.
    /// The synchronous access guard runs after actor entry and again before commit;
    /// throwing at the latter boundary rolls back both the row and its postings.
    func save(_ record: PhotoTextRecord, validate: @escaping @Sendable () throws -> Void = {}) throws {
        try requireWritable()
        try Task.checkCancellation()
        try validate()
        guard !record.id.isEmpty, record.revision.isFinite, !record.policy.isEmpty,
              record.pixelWidth >= 0, record.pixelHeight >= 0 else { throw TextIndexDatabase.failure() }
        let terms = PhotoTextLexicon.analyze(record.text, query: false).terms.sorted()
        try Task.checkCancellation()
        guard let db = try database(writing: true) else { throw TextIndexDatabase.failure() }
        try db.transaction {
            try db.statement("""
                INSERT INTO text_records (id, revision, policy, text, pixel_width, pixel_height, is_reduced, has_text)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET revision = excluded.revision, policy = excluded.policy,
                    text = excluded.text, pixel_width = excluded.pixel_width, pixel_height = excluded.pixel_height,
                    is_reduced = excluded.is_reduced, has_text = excluded.has_text
                """) { statement in
                try db.bind(record.id, at: 1, to: statement)
                try db.bind(record.revision, at: 2, to: statement)
                try db.bind(record.policy, at: 3, to: statement)
                try db.bind(record.text, at: 4, to: statement)
                try db.bind(record.pixelWidth, at: 5, to: statement)
                try db.bind(record.pixelHeight, at: 6, to: statement)
                try db.bind(record.isReduced ? 1 : 0, at: 7, to: statement)
                try db.bind(record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1, at: 8, to: statement)
                try db.execute(statement)
            }
            try db.statement("DELETE FROM text_terms WHERE record_id = ?") { statement in
                try db.bind(record.id, at: 1, to: statement)
                try db.execute(statement)
            }
            try db.statement("INSERT INTO text_terms (term, record_id) VALUES (?, ?)") { statement in
                for term in terms {
                    try Task.checkCancellation()
                    try db.reset(statement)
                    try db.bind(term, at: 1, to: statement)
                    try db.bind(record.id, at: 2, to: statement)
                    try db.execute(statement)
                }
            }
            try validate()
            try Task.checkCancellation()
        }
    }

    /// OR coverage = distinct matched query terms / distinct query terms; add 1 for
    /// an exact normalized lexical phrase. Ties use ID, independently of insertion order.
    /// No TF/IDF or global corpus statistics: inaccessible rows cannot influence ranking.
    /// Only posting hits are visited, and eligibility (exact ID/revision/current policy)
    /// is checked BEFORE any OCR text decoding or score contribution. Phrase text is
    /// fetched only for eligible hits in the same read transaction. No FTS or LIKE.
    func matches(query: String, revisions: [String: Double]) throws -> [PhotoTextMatch] {
        try Task.checkCancellation()
        let analysis = PhotoTextLexicon.analyze(query, query: true)
        guard !analysis.terms.isEmpty, !revisions.isEmpty else { return [] }
        guard let db = try database() else { return [] }
        return try db.transaction(writing: false) {
            var coverage: [String: Int] = [:]
            // Bind one term at a time: two variables regardless of query length.
            // This respects SQLite's actual variable limit without an arbitrary cap.
            try db.statement("""
                SELECT r.id, r.revision FROM text_terms t
                JOIN text_records r ON r.id = t.record_id
                WHERE t.term = ? AND r.policy = ?
                """) { statement in
                for term in analysis.terms.sorted() {
                    try db.reset(statement)
                    try db.bind(term, at: 1, to: statement)
                    try db.bind(PhotoTextPolicy.version, at: 2, to: statement)
                    while try db.next(statement) {
                        let id = try db.string(statement, at: 0)
                        guard let revision = revisions[id], revision == sqlite3_column_double(statement, 1) else { continue }
                        coverage[id, default: 0] += 1
                    }
                }
            }
            var result: [PhotoTextMatch] = []
            try db.statement("SELECT text FROM text_records WHERE id = ? AND revision = ? AND policy = ?") { statement in
                for (id, matched) in coverage {
                    try Task.checkCancellation()
                    guard let revision = revisions[id] else { continue }
                    try db.reset(statement)
                    try db.bind(id, at: 1, to: statement)
                    try db.bind(revision, at: 2, to: statement)
                    try db.bind(PhotoTextPolicy.version, at: 3, to: statement)
                    guard try db.next(statement) else { continue }
                    let text = try db.string(statement, at: 0)
                    let phrase = PhotoTextLexicon.analyze(text, query: false).phrase
                    let exact = phrase.contains(analysis.phrase)
                    let score = Double(matched) / Double(analysis.terms.count) + (exact ? 1.0 : 0.0)
                    result.append(PhotoTextMatch(id: id, score: score))
                }
            }
            try Task.checkCancellation()
            return result.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        }
    }

    /// Metadata-only counts. Old policy rows are missing to readers, not implicitly removed.
    func counts() throws -> TextIndexCounts {
        try Task.checkCancellation()
        guard let db = try database() else { return TextIndexCounts() }
        return try db.statement("""
            SELECT COUNT(*), COALESCE(SUM(has_text), 0), COALESCE(SUM(is_reduced), 0)
            FROM text_records WHERE policy = ?
            """) { statement in
            try db.bind(PhotoTextPolicy.version, at: 1, to: statement)
            guard try db.next(statement) else { throw TextIndexDatabase.failure() }
            return TextIndexCounts(records: Int(sqlite3_column_int64(statement, 0)),
                                   withText: Int(sqlite3_column_int64(statement, 1)),
                                   reduced: Int(sqlite3_column_int64(statement, 2)))
        }
    }

    /// Explicit manual-write operation only. Missing IDs, changed revisions and old
    /// policies (including their FK postings) are removed in one cancellable transaction.
    func reconcile(revisions: [String: Double]) throws {
        try requireWritable()
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("text-index.sqlite3").path) else { return }
        guard let db = try database(writing: true) else { throw TextIndexDatabase.failure() }
        try db.transaction {
            let obsolete = try db.statement("SELECT id, revision, policy FROM text_records") { statement -> [String] in
                var ids: [String] = []
                while try db.next(statement) {
                    let id = try db.string(statement, at: 0)
                    let policy = try db.string(statement, at: 2)
                    if revisions[id] != sqlite3_column_double(statement, 1)
                        || policy != PhotoTextPolicy.version {
                        ids.append(id)
                    }
                }
                return ids
            }
            try db.statement("DELETE FROM text_records WHERE id = ?") { statement in
                for id in obsolete {
                    try db.reset(statement)
                    try db.bind(id, at: 1, to: statement)
                    try db.execute(statement)
                }
            }
        }
    }

    /// Does not open/recreate a corrupt index and never deletes the shared directory.
    /// Only these four exact text-index paths are removed; image files are untouched.
    /// File deletion is not transactional; cancellation is checked before it starts.
    func clear() throws {
        try requireWritable()
        try Task.checkCancellation()
        connection = nil
        do {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let file = directory.appendingPathComponent("text-index.sqlite3" + suffix)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        } catch { throw TextIndexDatabase.failure() }
    }

    func close() { connection = nil }
}

/// Synchronous connection owned by SQLiteTextStore, never transferred across actors.
/// Internal visibility also permits deterministic transaction rollback tests without
/// timing-based cancellation or test hooks in the actor's public API.
final class TextIndexDatabase {
    let readOnly: Bool
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL, readOnly: Bool) throws {
        self.readOnly = readOnly
        let manager = FileManager.default
        let file = directory.appendingPathComponent("text-index.sqlite3")
        do {
            if !readOnly {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try Self.protect(directory)
            }
            var pointer: OpaquePointer?
            let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE)
            let status = sqlite3_open_v2(file.path, &pointer, flags | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw Self.failure()
            }
            handle = pointer
            try exec("PRAGMA foreign_keys = ON")
            let version = try statement("PRAGMA user_version") { statement -> Int32 in
                guard try next(statement) else { throw Self.failure() }
                return sqlite3_column_int(statement, 0)
            }
            guard version == 1 || (!readOnly && version == 0) else { throw Self.failure() }
            if !readOnly {
                // Parent protection also covers transient DELETE rollback journals.
                try Self.protect(file)
                try statement("PRAGMA journal_mode = DELETE") { statement in
                    guard try next(statement), try string(statement, at: 0) == "delete" else { throw Self.failure() }
                }
                try exec("PRAGMA synchronous = FULL; PRAGMA secure_delete = ON")
                try transaction {
                    try exec("""
                        CREATE TABLE IF NOT EXISTS text_records (
                            id TEXT PRIMARY KEY NOT NULL, revision REAL NOT NULL, policy TEXT NOT NULL,
                            text TEXT NOT NULL, pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL,
                            is_reduced INTEGER NOT NULL CHECK(is_reduced IN (0, 1)),
                            has_text INTEGER NOT NULL CHECK(has_text IN (0, 1)));
                        CREATE TABLE IF NOT EXISTS text_terms (
                            term TEXT NOT NULL, record_id TEXT NOT NULL,
                            PRIMARY KEY (term, record_id),
                            FOREIGN KEY (record_id) REFERENCES text_records(id) ON DELETE CASCADE) WITHOUT ROWID;
                        CREATE INDEX IF NOT EXISTS text_terms_by_record ON text_terms(record_id);
                        CREATE INDEX IF NOT EXISTS text_records_by_policy ON text_records(policy);
                        PRAGMA user_version = 1;
                        """)
                }
            }
        } catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            if error is CancellationError { throw error }
            // Never propagate SQLite messages, file paths, photo IDs or OCR contents.
            throw Self.failure()
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = url
        try excluded.setResourceValues(values)
    }

    static func failure() -> AppFailure { .storage("文字索引无法读写，请稍后重试。") }

    func transaction<T>(writing: Bool = true, _ operation: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try exec(writing ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let result = try operation()
            try Task.checkCancellation()
            try exec("COMMIT")
            return result
        } catch {
            // exec deliberately does not check cancellation, so ROLLBACK still runs.
            try? exec("ROLLBACK")
            throw error
        }
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure() }
    }

    func statement<T>(_ sql: String, _ operation: (OpaquePointer) throws -> T) throws -> T {
        try Task.checkCancellation()
        var pointer: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
        defer { if let pointer { sqlite3_finalize(pointer) } }
        guard status == SQLITE_OK, let pointer else { throw Self.failure() }
        return try operation(pointer)
    }

    func reset(_ statement: OpaquePointer) throws {
        try Task.checkCancellation()
        guard sqlite3_reset(statement) == SQLITE_OK, sqlite3_clear_bindings(statement) == SQLITE_OK else { throw Self.failure() }
    }

    func next(_ statement: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        let status = sqlite3_step(statement)
        try Task.checkCancellation()
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        throw Self.failure()
    }

    func execute(_ statement: OpaquePointer) throws {
        try Task.checkCancellation()
        let status = sqlite3_step(statement)
        try Task.checkCancellation()
        guard status == SQLITE_DONE else { throw Self.failure() }
    }

    func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        // Explicit UTF-8 byte length preserves embedded NULs and lets SQLite enforce
        // its own length limit; there is no agent-added row, term or byte ceiling.
        let status = value.withCString {
            sqlite3_bind_text64(statement, index, $0, UInt64(value.utf8.count), transient, UInt8(SQLITE_UTF8))
        }
        guard status == SQLITE_OK else { throw Self.failure() }
    }

    func bind(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw Self.failure() }
    }

    func bind(_ value: Int, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK else { throw Self.failure() }
    }

    func string(_ statement: OpaquePointer, at index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, index) else { throw Self.failure() }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, index)))
        guard let value = String(bytes: bytes, encoding: .utf8) else { throw Self.failure() }
        return value
    }
}