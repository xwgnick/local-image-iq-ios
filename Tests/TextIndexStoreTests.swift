import Foundation
import XCTest
import SQLite3
import ImageIQCore
@testable import LocalImageIQ

final class TextIndexStoreTests: XCTestCase {
    private func makeStore() throws -> (SQLiteTextStore, URL) {
        let directory = try TestFixtures.temporaryDirectory()
        let store = SQLiteTextStore(directory: directory)
        addTeardownBlock {
            await store.close()
            try FileManager.default.removeItem(at: directory)
        }
        return (store, directory)
    }

    private func fixture(_ id: String = "a", text: String = "北京 Train123", revision: Double = 1,
                         policy: String = PhotoTextPolicy.version, reduced: Bool = false) -> PhotoTextRecord {
        PhotoTextRecord(id: id, revision: revision, policy: policy, text: text,
                        pixelWidth: 640, pixelHeight: 480, isReduced: reduced)
    }

    private func assertRecord(_ actual: PhotoTextRecord?, equals expected: PhotoTextRecord,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(actual, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.revision.bitPattern, expected.revision.bitPattern, file: file, line: line)
        XCTAssertEqual(actual.policy, expected.policy, file: file, line: line)
        XCTAssertEqual(actual.text, expected.text, file: file, line: line)
        XCTAssertEqual(actual.pixelWidth, expected.pixelWidth, file: file, line: line)
        XCTAssertEqual(actual.pixelHeight, expected.pixelHeight, file: file, line: line)
        XCTAssertEqual(actual.isReduced, expected.isReduced, file: file, line: line)
    }

    private func assertStorage(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        switch error {
        case AppFailure.storage(let detail):
            XCTAssertTrue(["文字索引无法读写，请稍后重试。", "文字索引为只读，无法修改。"].contains(detail), file: file, line: line)
        default: XCTFail("Expected a sanitized storage failure.", file: file, line: line)
        }
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    /// Raw SQL is confined to synthetic fixtures; production always binds user values.
    private func withRaw<T>(_ directory: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("text-index.sqlite3").path,
                                     &pointer, SQLITE_OPEN_READWRITE, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        guard status == SQLITE_OK, let pointer else { throw TextIndexDatabase.failure() }
        return try body(pointer)
    }

    private func rawSQL(_ sql: String, at directory: URL) throws {
        try withRaw(directory) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw TextIndexDatabase.failure() }
        }
    }

    private func rawInteger(_ sql: String, at directory: URL) throws -> Int {
        try withRaw(directory) { db in
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
            defer { if let statement { sqlite3_finalize(statement) } }
            guard status == SQLITE_OK, let statement, sqlite3_step(statement) == SQLITE_ROW else {
                throw TextIndexDatabase.failure()
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    func testDurableRoundTripAndPostingsSurviveReopenIncludingNULAndQuotedID() async throws {
        let (store, directory) = try makeStore()
        let expected = fixture("synthetic-'quote-\0照片", text: "北京\0Train123", revision: 123.125, reduced: true)
        try await store.save(expected)
        await store.close()
        let reader = SQLiteTextStore(directory: directory, readOnly: true)
        addTeardownBlock { await reader.close() }
        let record = try await reader.record(id: expected.id)
        try assertRecord(record, equals: expected)
        let matches = try await reader.matches(query: "ｔｒａｉｎ１２３", revisions: [expected.id: expected.revision])
        XCTAssertEqual(matches, [PhotoTextMatch(id: expected.id, score: 2)])
        XCTAssertEqual(try rawInteger("PRAGMA user_version", at: directory), 1)
        XCTAssertGreaterThan(try rawInteger("SELECT COUNT(*) FROM text_terms", at: directory), 0)
    }

    func testUpsertAtomicallyReplacesMetadataAndRemovesOldPostings() async throws {
        let (store, directory) = try makeStore()
        try await store.save(fixture(text: "old 北京"))
        let replacement = fixture(text: "new 上海", revision: 2, reduced: true)
        try await store.save(replacement)
        await store.close()
        let record = try await store.record(id: "a")
        try assertRecord(record, equals: replacement)
        let old = try await store.matches(query: "old 北京", revisions: ["a": 2])
        let new = try await store.matches(query: "new 上海", revisions: ["a": 2])
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.map(\.id), ["a"])
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms WHERE term IN ('w:old','b:北京','h:北','h:京')", at: directory), 0)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records", at: directory), 1)
    }

    func testCompletedEmptyOCRIsResumableAndReducedMetadataCountsIndependently() async throws {
        let (store, _) = try makeStore()
        let empty = fixture("empty", text: "", reduced: true)
        try await store.save(empty)
        try await store.save(fixture("blank", text: " \n\t"))
        try await store.save(fixture("written", text: "train", reduced: true))
        await store.close()
        let retained = try await store.record(id: "empty")
        try assertRecord(retained, equals: empty)
        let counts = try await store.counts()
        XCTAssertEqual(counts, TextIndexCounts(records: 3, withText: 1, reduced: 2))
        let matches = try await store.matches(query: "train", revisions: ["empty": 1, "blank": 1, "written": 1])
        XCTAssertEqual(matches.map(\.id), ["written"])
        try await store.save(fixture("written", text: ""))
        let replaced = try await store.counts()
        let removed = try await store.matches(query: "train", revisions: ["written": 1])
        XCTAssertEqual(replaced, TextIndexCounts(records: 3, withText: 0, reduced: 1))
        XCTAssertTrue(removed.isEmpty)
    }

    func testChineseBigramsForLongQueryAndUnigramsOnlyForSingleHanRun() async throws {
        let (store, _) = try makeStore()
        for (id, text) in [("full", "北京大学"), ("partial", "北京饭店"), ("one", "京城"), ("split", "北，京")] {
            try await store.save(fixture(id, text: text))
        }
        let revisions: [String: Double] = ["full": 1, "partial": 1, "one": 1, "split": 1]
        let long = try await store.matches(query: "北京大学", revisions: revisions)
        XCTAssertEqual(long.map(\.id), ["full", "partial"])
        XCTAssertEqual(long[0].score, 2)
        XCTAssertEqual(long[1].score, 1.0 / 3.0, accuracy: 0.000001)
        let single = try await store.matches(query: "京", revisions: revisions)
        XCTAssertEqual(Set(single.map(\.id)), Set(revisions.keys))
        let adjacent = try await store.matches(query: "北京", revisions: revisions)
        XCTAssertEqual(Set(adjacent.map(\.id)), ["full", "partial"], "No bigram across punctuation; no single-character fallback.")
    }

    func testWholeLatinIdentifiersWidthCaseUnicodeAndPunctuation() async throws {
        let (store, _) = try makeStore()
        try await store.save(fixture("exact", text: "ＡＢＣ１２３，Café; Foo_Bar / 北京"))
        try await store.save(fixture("longer", text: "ABC1234 foobar"))
        let revisions: [String: Double] = ["exact": 1, "longer": 1]
        for query in ["abc123", "CAFÉ", "cafe\u{301}", "foo", "BAR", "abc123 北京"] {
            let matches = try await store.matches(query: query, revisions: revisions)
            XCTAssertEqual(matches.map(\.id), ["exact"], query)
        }
        for query in ["abc", "123", "cafe", "oo"] {
            let matches = try await store.matches(query: query, revisions: revisions)
            XCTAssertTrue(matches.isEmpty, query)
        }
    }

    func testEmptyAndPunctuationOnlyQueriesHaveNoMatchesOrWildcardMeaning() async throws {
        let (store, _) = try makeStore()
        try await store.save(fixture(text: "ordinary text 123"))
        for query in ["", " \n\t", "%", "_", "*", "\"';--()", "，。！？", "😀"] {
            let matches = try await store.matches(query: query, revisions: ["a": 1])
            XCTAssertTrue(matches.isEmpty)
        }
        let noAccess = try await store.matches(query: "ordinary", revisions: [:])
        XCTAssertTrue(noAccess.isEmpty)
    }

    func testSQLInjectionLookingIDsAndQueriesAreInnocuousLexicalValues() async throws {
        let (store, directory) = try makeStore()
        let id = "x'); DROP TABLE text_records; --"
        let record = fixture(id, text: "needle")
        try await store.save(record)
        try await store.save(fixture("word", text: "OR"))
        let matches = try await store.matches(query: "'; OR 1=1 --", revisions: [id: 1, "word": 1])
        XCTAssertEqual(matches.map(\.id), ["word"], "OR is an ordinary term, not executable SQL.")
        let wildcard = try await store.matches(query: "%needle%", revisions: [id: 1])
        XCTAssertEqual(wildcard.map(\.id), [id])
        let retained = try await store.record(id: id)
        try assertRecord(retained, equals: record)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records", at: directory), 2)
    }

    func testNumericIdentifier123DoesNotMatch1234OrReceiveFalsePhraseBonus() async throws {
        let (store, _) = try makeStore()
        try await store.save(fixture("a-longer", text: "订单1234"))
        try await store.save(fixture("z-exact", text: "订单１２３"))
        let revisions: [String: Double] = ["a-longer": 1, "z-exact": 1]
        let number = try await store.matches(query: "123", revisions: revisions)
        XCTAssertEqual(number, [PhotoTextMatch(id: "z-exact", score: 2)])
        let mixed = try await store.matches(query: "订单123", revisions: revisions)
        XCTAssertEqual(mixed, [PhotoTextMatch(id: "z-exact", score: 2), PhotoTextMatch(id: "a-longer", score: 0.5)])
    }

    func testORCoverageExactNormalizedPhrasePriorityAndDeterministicTies() async throws {
        let (store, _) = try makeStore()
        for (id, text) in [("d", "train red"), ("c", "red red red"), ("b", "ＲＥＤ，ＴＲＡＩＮ"), ("a", "red fast train")] {
            try await store.save(fixture(id, text: text))
        }
        let revisions: [String: Double] = ["a": 1, "b": 1, "c": 1, "d": 1]
        let expected = [PhotoTextMatch(id: "b", score: 2), PhotoTextMatch(id: "a", score: 1),
                        PhotoTextMatch(id: "d", score: 1), PhotoTextMatch(id: "c", score: 0.5)]
        let matches = try await store.matches(query: "red train", revisions: revisions)
        await store.close()
        let reopened = try await store.matches(query: "red train", revisions: revisions)
        XCTAssertEqual(matches, expected)
        XCTAssertEqual(reopened, expected)
    }

    func testEligibilityIsolationPrecedesTextDecodeAndUnmatchedTextIsNeverScanned() async throws {
        let (store, directory) = try makeStore()
        try await store.save(fixture("visible", text: "red train"))
        let before = try await store.matches(query: "red train", revisions: ["visible": 1])
        for id in ["hidden", "stale", "old"] {
            try await store.save(fixture(id, text: "red train", policy: id == "old" ? "old-policy" : PhotoTextPolicy.version))
        }
        try await store.save(fixture("unmatched", text: "unrelated"))
        await store.close()
        try rawSQL("UPDATE text_records SET text = x'FF' WHERE id != 'visible'", at: directory)
        let disk = try snapshot(directory)
        let reader = SQLiteTextStore(directory: directory, readOnly: true)
        addTeardownBlock { await reader.close() }
        let after = try await reader.matches(query: "red train", revisions: ["visible": 1, "stale": 2, "old": 1, "unmatched": 1])
        XCTAssertEqual(after, before)
        let absent = try await reader.matches(query: "doesnotexist", revisions: ["hidden": 1, "unmatched": 1])
        XCTAssertTrue(absent.isEmpty, "No text decoding at all without posting hits.")
        let counts = try await reader.counts()
        XCTAssertEqual(counts.records, 4, "Counts do not decode text or count old policy rows.")
        do {
            _ = try await reader.matches(query: "red train", revisions: ["hidden": 1])
            XCTFail("Eligible matching corrupt text must report a sanitized failure.")
        } catch { assertStorage(error) }
        let again = try await reader.matches(query: "red train", revisions: ["visible": 1])
        XCTAssertEqual(again, before, "No cached access decisions after a failure.")
        await reader.close()
        XCTAssertEqual(try snapshot(directory), disk)
    }

    func testExactRevisionAndCurrentPolicyRequiredWithoutImplicitPruning() async throws {
        let (store, directory) = try makeStore()
        try await store.save(fixture("current", text: "train"))
        try await store.save(fixture("old", text: "train", policy: "old-policy", reduced: true))
        await store.close()
        let disk = try snapshot(directory)
        let stale = try await store.matches(query: "train", revisions: ["current": Double(1).nextUp, "old": 1])
        let exact = try await store.matches(query: "train", revisions: ["current": 1, "old": 1])
        let old = try await store.record(id: "old")
        let counts = try await store.counts()
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(exact.map(\.id), ["current"])
        XCTAssertNil(old)
        XCTAssertEqual(counts, TextIndexCounts(records: 1, withText: 1, reduced: 0))
        await store.close()
        XCTAssertEqual(try snapshot(directory), disk, "Writable-store reads are also genuinely read-only.")
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records", at: directory), 2)
    }

    func testManualReconcileRemovesMissingChangedOldPolicyAndCascadesPostings() async throws {
        let (store, directory) = try makeStore()
        for id in ["keep", "missing", "changed", "old", "empty"] {
            try await store.save(fixture(id, text: id == "empty" ? "" : "train",
                                         policy: id == "old" ? "old-policy" : PhotoTextPolicy.version))
        }
        try await store.reconcile(revisions: ["keep": 1, "changed": 2, "old": 1, "empty": 1])
        let matches = try await store.matches(query: "train", revisions: ["keep": 1, "missing": 1, "changed": 1, "old": 1])
        let counts = try await store.counts()
        XCTAssertEqual(matches.map(\.id), ["keep"])
        XCTAssertEqual(counts, TextIndexCounts(records: 2, withText: 1, reduced: 0))
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms WHERE record_id != 'keep'", at: directory), 0)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms t LEFT JOIN text_records r ON r.id = t.record_id WHERE r.id IS NULL", at: directory), 0)
        try await store.reconcile(revisions: [:])
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records", at: directory), 0)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms", at: directory), 0)
    }

    func testPreCancelledSaveReconcileAndReadsLeaveRecordsAndPostingsUnchanged() async throws {
        let (store, directory) = try makeStore()
        let original = fixture(text: "original")
        let replacement = fixture(text: "replacement", revision: 2)
        try await store.save(original)
        await store.close()
        let disk = try snapshot(directory)
        for operation in 0..<4 {
            let task = Task<Void, Error> {
                withUnsafeCurrentTask { $0?.cancel() }
                switch operation {
                case 0: try await store.save(replacement)
                case 1: try await store.reconcile(revisions: [:])
                case 2: _ = try await store.matches(query: "original", revisions: ["a": 1])
                default: _ = try await store.counts()
                }
            }
            do { try await task.value; XCTFail("Cancellation must propagate.") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(try snapshot(directory), disk)
        let retained = try await store.record(id: "a")
        try assertRecord(retained, equals: original)
    }

    func testSaveValidationBeforeMutationDoesNotCreateMissingStorage() async throws {
        for missingDirectory in [false, true] {
            let (_, root) = try makeStore()
            let directory = missingDirectory ? root.appendingPathComponent("not-created") : root
            let store = SQLiteTextStore(directory: directory)
            addTeardownBlock { await store.close() }
            do {
                try await store.save(fixture()) { throw AppFailure.photo("Synthetic access changed.") }
                XCTFail("Actor-entry validation must run before creating or mutating storage.")
            } catch AppFailure.photo(let issue) { XCTAssertEqual(issue, "Synthetic access changed.") }
            XCTAssertEqual(try snapshot(root), [:])
            if missingDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
        }
    }

    func testSavePrecommitValidationAndCancellationRollBackPriorRowAndPostings() async throws {
        for cancelAtCommit in [false, true] {
            let (store, directory) = try makeStore()
            let original = fixture(text: "original retained")
            let replacement = fixture(text: "first new", revision: 2, reduced: true)
            try await store.save(original)
            let validation = TextStoreValidationCounter()
            let journal = directory.appendingPathComponent("text-index.sqlite3-journal")
            let task = Task<Void, Error> {
                try await store.save(replacement) {
                    if validation.next() == 2 {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path),
                                      "Precommit validation must run inside the dirty transaction.")
                        if cancelAtCommit { withUnsafeCurrentTask { $0?.cancel() } }
                        else { throw AppFailure.photo("Synthetic access changed.") }
                    }
                }
            }
            do { try await task.value; XCTFail("A failed precommit guard must roll back the upsert.") }
            catch AppFailure.photo(let issue) {
                XCTAssertFalse(cancelAtCommit)
                XCTAssertEqual(issue, "Synthetic access changed.")
            } catch {
                XCTAssertTrue(cancelAtCommit)
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(validation.count, 2)
            await store.close()
            let retained = try await store.record(id: "a")
            try assertRecord(retained, equals: original)
            let old = try await store.matches(query: "original retained", revisions: ["a": 1])
            XCTAssertEqual(old, [PhotoTextMatch(id: "a", score: 2)])
            XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records", at: directory), 1)
            XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms", at: directory), 2)
            XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms WHERE term IN ('w:first', 'w:new')", at: directory), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        }
    }

    func testCancellationAfterActualTransactionalMutationsRollsBackRowsAndFKPostings() async throws {
        let (store, directory) = try makeStore()
        try await store.save(fixture(text: "original"))
        await store.close()
        // Exercise the same transaction primitive as save/reconcile, deterministically
        // cancelling AFTER real mutations rather than racing an asynchronous timer.
        let task = Task<Void, Error> {
            let db = try TextIndexDatabase(directory: directory, readOnly: false)
            try db.transaction {
                try db.exec("DELETE FROM text_records WHERE id = 'a'")
                try db.exec("INSERT INTO text_records VALUES ('temporary', 2, 'synthetic', 'cancelled', 1, 1, 0, 1)")
                try db.exec("INSERT INTO text_terms VALUES ('w:cancelled', 'temporary')")
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("A cancelled transaction cannot commit.") }
        catch { XCTAssertTrue(error is CancellationError) }
        let original = try await store.matches(query: "original", revisions: ["a": 1])
        XCTAssertEqual(original.map(\.id), ["a"])
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_records WHERE id = 'temporary'", at: directory), 0)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms WHERE record_id = 'a'", at: directory), 1)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms WHERE record_id = 'temporary'", at: directory), 0)
    }

    func testPostingsFailureDuringUpsertRollsBackTextMetadataAndAlreadyInsertedTerms() async throws {
        let (store, directory) = try makeStore()
        let original = fixture(text: "original")
        try await store.save(original)
        await store.close()
        try rawSQL("""
            CREATE TRIGGER reject_new_term BEFORE INSERT ON text_terms WHEN NEW.term = 'w:new'
            BEGIN SELECT RAISE(ABORT, 'Synthetic private OCR should not escape'); END;
            """, at: directory)
        do {
            try await store.save(fixture(text: "first new", revision: 2, reduced: true))
            XCTFail("Synthetic posting failure should abort the entire upsert.")
        } catch { assertStorage(error) }
        await store.close()
        let retained = try await store.record(id: "a")
        try assertRecord(retained, equals: original)
        let old = try await store.matches(query: "original", revisions: ["a": 1])
        let new = try await store.matches(query: "first new", revisions: ["a": 1])
        XCTAssertEqual(old.map(\.id), ["a"])
        XCTAssertTrue(new.isEmpty)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM text_terms", at: directory), 1)
    }

    func testAllMissingDatabaseReadsNeverCreateDirectoryOrDatabaseInEitherMode() async throws {
        for readOnly in [false, true] {
            for missingDirectory in [false, true] {
                let (_, root) = try makeStore()
                let directory = missingDirectory ? root.appendingPathComponent("absent", isDirectory: true) : root
                let store = SQLiteTextStore(directory: directory, readOnly: readOnly)
                addTeardownBlock { await store.close() }
                let record = try await store.record(id: "a")
                let counts = try await store.counts()
                let matches = try await store.matches(query: "train", revisions: ["a": 1])
                XCTAssertNil(record)
                XCTAssertEqual(counts, TextIndexCounts())
                XCTAssertTrue(matches.isEmpty)
                if !readOnly {
                    try await store.reconcile(revisions: [:])
                    try await store.clear()
                }
                XCTAssertEqual(try snapshot(root), [:])
                if missingDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
            }
        }
    }

    func testReadOnlyRejectsEveryWriteForExistingAndMissingDatabase() async throws {
        for existing in [false, true] {
            let (writer, directory) = try makeStore()
            if existing { try await writer.save(fixture()) }
            await writer.close()
            let before = try snapshot(directory)
            let reader = SQLiteTextStore(directory: directory, readOnly: true)
            addTeardownBlock { await reader.close() }
            do { try await reader.save(fixture()); XCTFail("Read-only save must fail.") }
            catch { assertStorage(error) }
            do { try await reader.reconcile(revisions: [:]); XCTFail("Read-only reconcile must fail.") }
            catch { assertStorage(error) }
            do { try await reader.clear(); XCTFail("Read-only clear must fail.") }
            catch { assertStorage(error) }
            XCTAssertEqual(try snapshot(directory), before)
        }
    }

    func testClearDeletesOnlyExactTextDatabaseAndSidecarsPreservingImageStore() async throws {
        let (store, directory) = try makeStore()
        let images = SQLitePhotoStore(directory: directory)
        addTeardownBlock { await images.close() }
        try await images.save(TestFixtures.photo())
        await images.close()
        try await store.save(fixture())
        await store.close()
        // Clear must also recover corrupt text storage without trying to open it.
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try Data("synthetic broken text sidecar".utf8).write(to: directory.appendingPathComponent("text-index.sqlite3" + suffix))
        }
        for name in ["index.sqlite3-journal", "index.sqlite3-wal", "index.sqlite3-shm", "text-index.sqlite3-extra", "unrelated"] {
            try Data("retain".utf8).write(to: directory.appendingPathComponent(name))
        }
        let retained = try snapshot(directory).filter { !["text-index.sqlite3", "text-index.sqlite3-journal", "text-index.sqlite3-wal", "text-index.sqlite3-shm"].contains($0.key) }
        try await store.clear()
        let counts = try await store.counts()
        XCTAssertEqual(counts, TextIndexCounts())
        XCTAssertEqual(try snapshot(directory), retained)
        try await store.clear()
        XCTAssertEqual(try snapshot(directory), retained)
    }

    func testIndependentSchemaBackupExclusionProtectionAndDeleteJournal() async throws {
        let (store, directory) = try makeStore()
        try await store.save(fixture())
        await store.close()
        let file = directory.appendingPathComponent("text-index.sqlite3")
        for url in [directory, file] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            #if os(iOS) && !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            #endif
        }
        let db = try TextIndexDatabase(directory: directory, readOnly: true)
        let mode = try db.statement("PRAGMA journal_mode") { statement -> String in
            guard try db.next(statement) else { throw TextIndexDatabase.failure() }
            return try db.string(statement, at: 0)
        }
        XCTAssertEqual(mode, "delete")
        XCTAssertEqual(try rawInteger("PRAGMA user_version", at: directory), 1)
        XCTAssertEqual(try rawInteger("SELECT COUNT(*) FROM pragma_foreign_key_list('text_terms')", at: directory), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("index.sqlite3").path))
        for suffix in ["-journal", "-wal", "-shm"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + suffix))
        }
    }

    func testCorruptAndUnsupportedExistingDatabaseFailGenericallyWithoutRepair() async throws {
        for corrupt in [false, true] {
            let (store, directory) = try makeStore()
            try await store.save(fixture())
            await store.close()
            if corrupt {
                try Data("synthetic private OCR not a database".utf8).write(to: directory.appendingPathComponent("text-index.sqlite3"))
            } else {
                try rawSQL("PRAGMA user_version = 99", at: directory)
            }
            let before = try snapshot(directory)
            for readOnly in [false, true] {
                let reader = SQLiteTextStore(directory: directory, readOnly: readOnly)
                do { _ = try await reader.counts(); XCTFail("Existing invalid storage is not a missing index.") }
                catch { assertStorage(error) }
                await reader.close()
            }
            XCTAssertEqual(try snapshot(directory), before)
        }
    }

    func testManyDistinctQueryTermsNeedNoVariableLimitCapOrFullTextScan() async throws {
        let (store, _) = try makeStore()
        try await store.save(fixture(text: "token1999"))
        let query = (0..<2000).map { "token\($0)" }.joined(separator: " ")
        let matches = try await store.matches(query: query, revisions: ["a": 1])
        XCTAssertEqual(matches, [PhotoTextMatch(id: "a", score: 1.0 / 2000.0)])
    }

    func testSharedModelDefaultsAndGenericChineseProgress() {
        XCTAssertEqual(PhotoTextPolicy.version, "vision-ocr-r3-accurate-zh-en-fit-v1")
        XCTAssertEqual(TextIndexCounts(), TextIndexCounts(records: 0, withText: 0, reduced: 0))
        let summary = LibrarySummary()
        XCTAssertEqual(summary.textIndexCounts, TextIndexCounts())
        XCTAssertFalse(summary.textIndexStatisticsKnown)
        XCTAssertNil(summary.textIndexIssue)
        var progress = TextIndexProgress()
        XCTAssertEqual(progress.fraction, 0)
        progress.total = 4
        progress.completed = 2
        progress.recognized = 1
        progress.reused = 1
        XCTAssertEqual(progress.fraction, 0.5)
        XCTAssertTrue(progress.summary.contains("已检查 2/4"))
        XCTAssertTrue(progress.summary.contains("已识别 1"))
        XCTAssertTrue(progress.summary.contains("已复用 1"))
        progress.completed = 5
        XCTAssertEqual(progress.fraction, 1)
        let recognized = RecognizedPhotoText(text: "", pixelWidth: 20, pixelHeight: 10, isReduced: true)
        XCTAssertEqual(recognized.pixelWidth, 20)
        XCTAssertTrue(recognized.isReduced)
    }
}

private final class TextStoreValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}