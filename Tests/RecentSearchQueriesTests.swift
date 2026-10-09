import Foundation
import XCTest
@testable import LocalImageIQ

@MainActor
final class RecentSearchQueriesTests: XCTestCase {
    func testInitialThreeDefaultsHaveExactLabelsAndFullQueries() {
        let suggestions = RecentSearchQueries.suggestions(for: [])
        XCTAssertEqual(suggestions.map(\.label), ["身份证", "猫猫追逐逗猫棒", "海边日落"])
        XCTAssertEqual(suggestions.map(\.query), ["身份证", "猫猫追逐逗猫棒", "海边的日落"])
        XCTAssertEqual(Set(suggestions.map(\.id)).count, 3)
    }

    func testRecordingTrimsOnlyOuterWhitespaceAndIgnoresEmptyInput() {
        let text = "猫猫  with\ta toy\ninside"
        var history = RecentSearchQueries.recording(" \t\u{3000}\(text)\r\n ", in: [])
        XCTAssertEqual(history, [text])
        for empty in ["", " ", "\t\r\n\u{3000}"] {
            history = RecentSearchQueries.recording(empty, in: history)
            XCTAssertEqual(history, [text])
        }
        XCTAssertEqual(RecentSearchQueries.normalized([" ", " one ", "one", "two", "three", "four"]),
                       ["one", "two", "three"])
    }

    func testDuplicateMovesToLeftAndFourthDistinctQueryEvictsOldest() {
        var history: [String] = []
        for query in ["one", "two", "three"] {
            history = RecentSearchQueries.recording(query, in: history)
        }
        XCTAssertEqual(history, ["three", "two", "one"])
        history = RecentSearchQueries.recording(" two\n", in: history)
        XCTAssertEqual(history, ["two", "three", "one"])
        history = RecentSearchQueries.recording("four", in: history)
        XCTAssertEqual(history, ["four", "two", "three"])
    }

    func testExactQueriesAreNotCaseFoldedTranslatedOrUnicodeNormalized() {
        XCTAssertEqual(RecentSearchQueries.normalized(["Cat", "cat", "猫"]), ["Cat", "cat", "猫"])
        let composed = "caf\u{e9}"
        let decomposed = "cafe\u{301}"
        let history = RecentSearchQueries.normalized([composed, decomposed, "猫"])
        XCTAssertEqual(history.map { Data($0.utf8) }, [composed, decomposed, "猫"].map { Data($0.utf8) })
        XCTAssertEqual(Set(RecentSearchQueries.suggestions(for: history).map(\.id)).count, 3)
    }

    func testOneAndTwoHistoryEntriesProgressivelyReplaceDefaults() {
        XCTAssertEqual(RecentSearchQueries.suggestions(for: ["one"]).map(\.query),
                       ["one", "身份证", "猫猫追逐逗猫棒"])
        XCTAssertEqual(RecentSearchQueries.suggestions(for: ["two", "one"]).map(\.query),
                       ["two", "one", "身份证"])
        let three = RecentSearchQueries.suggestions(for: ["three", "two", "one"])
        XCTAssertEqual(three.map(\.query), ["three", "two", "one"])
        XCTAssertEqual(three.map(\.label), ["three", "two", "one"])
    }

    func testDefaultActualQueriesNeverProduceDuplicateBlocks() {
        let defaults = RecentSearchQueries.defaults.map(\.query)
        for first in defaults {
            let one = RecentSearchQueries.suggestions(for: [first])
            XCTAssertEqual(one.map(\.query), [first] + defaults.filter { $0 != first })
            XCTAssertEqual(one[0].label, first, "History labels use the complete submitted query")
            for second in defaults where second != first {
                let two = RecentSearchQueries.suggestions(for: [first, second])
                XCTAssertEqual(two.map(\.query), [first, second] + defaults.filter { $0 != first && $0 != second })
                XCTAssertEqual(two.count, 3)
                XCTAssertEqual(Set(two.map(\.id)).count, 3)
            }
        }
        let three = RecentSearchQueries.suggestions(for: Array(defaults.reversed()))
        XCTAssertEqual(three.map(\.label), Array(defaults.reversed()))
        XCTAssertEqual(three.map(\.query), Array(defaults.reversed()))
    }

    func testLongHistoryLabelAndQueryAreNeverTruncated() {
        let text = String(repeating: "猫 🐈 A\"B\n", count: 10_000) + "尾部"
        let suggestions = RecentSearchQueries.suggestions(for: [text])
        XCTAssertEqual(Data(suggestions[0].label.utf8), Data(text.utf8))
        XCTAssertEqual(Data(suggestions[0].query.utf8), Data(text.utf8))
        XCTAssertEqual(suggestions[0].id, Data(text.utf8))
    }

    func testStoreInitAndMissingReadDoNotCreateAnything() throws {
        let directory = try historyDirectory()
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try store.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDefaultLocationIsApplicationSupportAndSeparateFromIndex() throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: false)
        let directory = try QueryHistoryStore.defaultDirectory()
        XCTAssertEqual(directory, support.appendingPathComponent(QueryHistoryStore.directoryName, isDirectory: true))
        XCTAssertNotEqual(directory, try SQLitePhotoStore.defaultDirectory(create: false))
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL, support.standardizedFileURL)
    }

    func testJSONRoundTripKeepsOnlyThreeFullOriginalStringsAndNoExtraMetadata() throws {
        let directory = try historyDirectory()
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        let long = String(repeating: "中文 🐈 \"q\"\n", count: 10_000) + "end"
        let exact = "cafe\u{301}\0\tinside"
        try store.save([" \(long)\n", exact, "three", "four"])
        let file = directory.appendingPathComponent(QueryHistoryStore.fileName)
        let bytes = try Data(contentsOf: file)
        let decoded = try JSONDecoder().decode([String].self, from: bytes)
        XCTAssertEqual(decoded.map { Data($0.utf8) }, [long, exact, "three"].map { Data($0.utf8) })
        XCTAssertEqual(try QueryHistoryStore(directory: directory, protectedDataAvailable: { true }).load(), decoded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [QueryHistoryStore.fileName])
    }

    func testCorruptJSONIsNotMissingAndReadDoesNotRewriteIt() throws {
        let directory = try historyDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(QueryHistoryStore.fileName)
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        for bytes in [Data("not JSON".utf8), Data("{\"queries\":[]}".utf8), Data("[42]".utf8)] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try store.load()) { error in
                guard case QueryHistoryStoreError.invalid = error else { return XCTFail("Expected a safe invalid-file error") }
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testExistingJSONIsNormalizedWithoutImplicitRepairWrite() throws {
        let directory = try historyDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(QueryHistoryStore.fileName)
        let bytes = try JSONEncoder().encode([" ", " newest ", "newest", "second", "third", "fourth"])
        try bytes.write(to: file)
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        XCTAssertEqual(try store.load(), ["newest", "second", "third"])
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testProtectionAndBackupPolicyApplyBeforeCommitAndAfterReplacement() throws {
        let directory = try historyDirectory()
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true }, beforeCommit: {
            let staged = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "tmp" }
            XCTAssertEqual(staged.count, 1)
            try Self.assertPrivateFile(try XCTUnwrap(staged.first))
            XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        })
        XCTAssertEqual(QueryHistoryStore.fileProtection, FileProtectionType.complete)
        XCTAssertEqual(QueryHistoryStore.fileAttributes[.protectionKey] as? FileProtectionType, .complete)
        XCTAssertEqual(QueryHistoryStore.fileAttributes[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(QueryHistoryStore.excludedFromBackup)
        for text in ["first", "replacement"] {
            try store.save([text])
            try Self.assertPrivateFile(directory.appendingPathComponent(QueryHistoryStore.fileName))
            XCTAssertEqual(try store.load(), [text])
        }
        // Simulator validates the applied policy and backup metadata above; only
        // hardware can attest the OS protection-class attribute. No test skip.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }

    func testPreCommitFailureAndCancellationPreservePreviousJSONAndRemoveStaging() async throws {
        let directory = try historyDirectory()
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        try store.save(["old"])
        let file = directory.appendingPathComponent(QueryHistoryStore.fileName)
        let old = try Data(contentsOf: file)
        let failing = QueryHistoryStore(directory: directory, protectedDataAvailable: { true }, beforeCommit: {
            throw QueryHistoryStoreError.unavailable
        })
        XCTAssertThrowsError(try failing.save(["replacement"]))
        XCTAssertEqual(try Data(contentsOf: file), old)
        let cancelled = Task { @MainActor in
            let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true }, beforeCommit: {
                withUnsafeCurrentTask { $0?.cancel() }
            })
            do { try store.save(["cancelled"]); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let wasCancelled = await cancelled.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(try Data(contentsOf: file), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [QueryHistoryStore.fileName])
    }

    func testLockGuardPrecedesReadAndWriteAndIsRecheckedBeforeCommit() throws {
        let directory = try historyDirectory()
        let unlocked = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        try unlocked.save(["old"])
        let file = directory.appendingPathComponent(QueryHistoryStore.fileName)
        let old = try Data(contentsOf: file)
        let locked = QueryHistoryStore(directory: directory, protectedDataAvailable: { false })
        XCTAssertThrowsError(try locked.load())
        XCTAssertThrowsError(try locked.save(["new"]))
        XCTAssertThrowsError(try locked.save([]))
        XCTAssertEqual(try Data(contentsOf: file), old)
        var available = true
        let relocked = QueryHistoryStore(directory: directory, protectedDataAvailable: { available },
                                        beforeCommit: { available = false })
        XCTAssertThrowsError(try relocked.save(["new"]))
        XCTAssertEqual(try Data(contentsOf: file), old)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [QueryHistoryStore.fileName])
        try Data("bad JSON".utf8).write(to: file)
        XCTAssertThrowsError(try locked.load()) { error in
            guard case QueryHistoryStoreError.unavailable = error else { return XCTFail("Locked data must not be decoded") }
        }
    }

    func testClearPersistsAcrossRecreationWithoutChangingSyntheticIndex() throws {
        let directory = try historyDirectory()
        let index = directory.deletingLastPathComponent().appendingPathComponent("LocalImageIQIndex", isDirectory: true)
        try TestFixtures.seedRawCache([TestFixtures.photo()], directory: index)
        let database = index.appendingPathComponent("index.sqlite3")
        let before = try Data(contentsOf: database)
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        try store.save(["one", "two"])
        try store.save([])
        XCTAssertEqual(try QueryHistoryStore(directory: directory, protectedDataAvailable: { true }).load(), [])
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: directory.appendingPathComponent(QueryHistoryStore.fileName))), [])
    }

    private func historyDirectory() throws -> URL {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("history", isDirectory: true)
    }

    private static func assertPrivateFile(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true,
                       file: file, line: line)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file: file, line: line)
        #if !targetEnvironment(simulator)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete, file: file, line: line)
        #endif
    }
}