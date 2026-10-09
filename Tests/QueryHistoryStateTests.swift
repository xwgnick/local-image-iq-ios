import Foundation
import Photos
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// All queries, rows, failures and services are synthetic. No model loading,
/// Apple translation session, image fetching, OCR or network is started. Like
/// other AppState tests, the normal library wrapper still reads authorization.
@MainActor
final class QueryHistoryStateTests: XCTestCase {
    func testDefaultsAreMemoryOnlyAndDraftEditingNeverRecords() async {
        let c = await ready()
        XCTAssertEqual(c.state.searchSuggestions.map(\.label), ["身份证", "猫猫追逐逗猫棒", "海边日落"])
        c.state.query = "draft"
        XCTAssertTrue(c.state.canSearch)
        XCTAssertTrue(c.state.recentSearchQueries.isEmpty)
        XCTAssertTrue(c.worker.texts.isEmpty)
        c.state.submitSearchQuery()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.recentSearchQueries, ["draft"])

        let independent = AppState(worker: QueryHistoryWorker(), authorizationStatus: { .authorized },
                                   queryTranslator: QueryHistoryTranslator())
        XCTAssertEqual(independent.recentSearchQueries, [])
        XCTAssertNil(independent.searchHistoryIssue)
        XCTAssertEqual(independent.searchSuggestions, RecentSearchQueries.defaults)
    }

    func testInjectedLoadIsNormalizedWithoutWritingOrDoingPhotoWork() {
        let store = QueryHistoryMemoryStore([" newest ", "newest", "second", "third", "fourth"])
        let worker = QueryHistoryWorker()
        let state = AppState(worker: worker, authorizationStatus: { .denied },
                             queryTranslator: QueryHistoryTranslator(), queryHistoryStore: store)
        XCTAssertEqual(state.recentSearchQueries, ["newest", "second", "third"])
        XCTAssertEqual(state.searchSuggestions.map(\.query), ["newest", "second", "third"])
        XCTAssertEqual(store.loads, 1)
        XCTAssertEqual(store.saves, [])
        XCTAssertEqual(worker.refreshes, 0)
        XCTAssertTrue(worker.texts.isEmpty)
        XCTAssertEqual(worker.indexes + worker.textIndexes + worker.clears, 0)
    }

    func testDisabledSubmissionsNeverRecordOrPersist() async {
        for variant in 0..<6 {
            let worker = QueryHistoryWorker()
            let store = QueryHistoryMemoryStore(["existing"])
            if variant == 1 { worker.summary.modelVersion = nil }
            if variant == 2 { worker.summary.indexStatisticsKnown = false }
            if variant == 3 { worker.summary.indexedCount = 0 }
            let c = await ready(worker: worker, store: store,
                                authorization: variant == 0 ? .denied : .authorized)
            c.state.query = variant == 4 ? " \t\r\n\u{3000}" : "draft"
            if variant == 5 { c.state.enterBackground(); await c.state.waitUntilIdle() }
            XCTAssertFalse(c.state.canSearch)
            c.state.submitSearchQuery()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.recentSearchQueries, ["existing"])
            XCTAssertTrue(store.saves.isEmpty)
            XCTAssertTrue(worker.texts.isEmpty)
            assertNoIndexWork(c)
        }
        let store = QueryHistoryMemoryStore()
        let pending = AppState(worker: QueryHistoryWorker(), authorizationStatus: { .authorized },
                               queryTranslator: QueryHistoryTranslator(), queryHistoryStore: store)
        pending.query = "not ready"
        pending.submitSearchQuery()
        XCTAssertFalse(pending.canSearch)
        XCTAssertTrue(pending.recentSearchQueries.isEmpty)
        XCTAssertTrue(store.saves.isEmpty)
    }

    func testSubmissionRecordsImmediatelyButSearchStillReceivesUntouchedOriginal() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        let original = " \tCat  with\na WHITE toy\r\n "
        c.state.query = original
        c.state.submitSearchQuery()
        XCTAssertEqual(c.state.recentSearchQueries, ["Cat  with\na WHITE toy"])
        XCTAssertEqual(store.saves, [["Cat  with\na WHITE toy"]])
        XCTAssertEqual(c.state.query, original)
        XCTAssertEqual(c.state.activity, .searching)
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.texts, [original])
        XCTAssertEqual(c.state.completedSearchQuery?.original, original)
        XCTAssertEqual(c.state.searchSuggestions.map(\.query), ["Cat  with\na WHITE toy", "身份证", "猫猫追逐逗猫棒"])
        XCTAssertNil(c.state.searchHistoryIssue)
        assertNoIndexWork(c)
    }

    func testRepeatedSubmissionsMoveExactDuplicateFirstAndFourthEvictsOldest() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        for query in ["one", "two", "three", " two ", "four"] {
            c.state.query = query
            c.state.submitSearchQuery()
            await c.state.waitUntilIdle()
        }
        XCTAssertEqual(c.state.recentSearchQueries, ["four", "two", "three"])
        XCTAssertEqual(store.saves, [["one"], ["two", "one"], ["three", "two", "one"],
                                     ["two", "three", "one"], ["four", "two", "three"]])
        XCTAssertEqual(c.state.searchSuggestions.map(\.label), ["four", "two", "three"])
        assertNoIndexWork(c)
    }

    func testFailedSearchStillRecordsTheExplicitSubmission() async {
        let c = await ready(store: QueryHistoryMemoryStore())
        c.worker.failSearch = true
        c.state.query = "failed synthetic query"
        c.state.submitSearchQuery()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.texts, ["failed synthetic query"])
        XCTAssertEqual(c.state.recentSearchQueries, ["failed synthetic query"])
        XCTAssertNotNil(c.state.errorMessage)
        XCTAssertNil(c.state.completedQuery)
        XCTAssertNil(c.state.searchHistoryIssue)
        assertNoIndexWork(c)
    }

    func testImmediateCancellationBeforeExecutionStillRecordsSubmission() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        c.state.query = "cancelled before execution"
        c.state.submitSearchQuery()
        c.state.cancel()
        await c.state.waitUntilIdle()
        XCTAssertTrue(c.worker.texts.isEmpty)
        XCTAssertNil(c.state.completedQuery)
        XCTAssertEqual(c.state.recentSearchQueries, ["cancelled before execution"])
        XCTAssertEqual(store.saves, [["cancelled before execution"]])
        assertNoIndexWork(c)
    }

    func testInFlightCancellationAndRejectedBusyDraftDoNotRewriteHistory() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        let entered = expectation(description: "Synthetic search is suspended")
        c.worker.entered = entered
        c.worker.gate = QueryHistoryGate()
        c.state.query = "submitted"
        c.state.submitSearchQuery()
        await fulfillment(of: [entered], timeout: 3)
        c.state.query = "new draft while busy"
        XCTAssertFalse(c.state.canSearch)
        c.state.submitSearchQuery()
        c.state.cancel()
        c.worker.release()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.recentSearchQueries, ["submitted"])
        XCTAssertEqual(store.saves, [["submitted"]])
        XCTAssertEqual(c.worker.texts, ["submitted"])
        XCTAssertTrue(c.state.results.isEmpty, "The held worker's late success must remain rejected")
        assertNoIndexWork(c)
    }

    func testTranslatedSubmissionPersistsOnlyTrimmedOriginalNotTranslatedValue() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        let original = " \t猫猫追逐逗猫棒\n "
        c.state.query = original
        c.state.submitSearchQuery()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.translator.originals, [original])
        XCTAssertEqual(c.worker.texts, [c.translator.translatedText])
        XCTAssertEqual(c.state.completedSearchQuery?.original, original)
        XCTAssertEqual(c.state.completedSearchQuery?.effective, c.translator.translatedText)
        XCTAssertEqual(store.stored, ["猫猫追逐逗猫棒"])
        XCTAssertEqual(c.state.searchSuggestions.map(\.query), ["猫猫追逐逗猫棒", "身份证", "海边的日落"])
        XCTAssertEqual(c.state.searchSuggestions.map(\.label), ["猫猫追逐逗猫棒", "身份证", "海边日落"])
        XCTAssertEqual(c.translator.preparations, 0)
        assertNoIndexWork(c)
    }

    func testExecutionOriginalToggleFiltersPaginationAndSimilarityNeverRecordOrPromote() async throws {
        let store = QueryHistoryMemoryStore(["newest", "猫猫追逐逗猫棒", "oldest"])
        let c = await ready(store: store)
        let originalHistory = c.state.recentSearchQueries
        // Rerun an older entry, so recording would visibly promote it.
        c.state.query = "猫猫追逐逗猫棒"
        c.state.search()
        await c.state.waitUntilIdle()
        XCTAssertTrue(c.state.completedSearchQuery?.translated == true)
        c.state.search(useOriginal: true)
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.completedSearchQuery?.translated ?? true)
        let translations = c.translator.originals.count
        c.state.applySearchFilters(.init(imageKind: .screenshots))
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.filters.last, PhotoSearchFilters(imageKind: .screenshots))
        XCTAssertEqual(c.translator.originals.count, translations)
        let session = try XCTUnwrap(c.state.resultSessionID)
        XCTAssertEqual(c.state.results.count, 12)
        c.state.loadMoreResults(sessionID: session, after: 12)
        XCTAssertEqual(c.state.results.count, 14)
        c.state.searchSimilar(to: try XCTUnwrap(c.state.results.first?.id))
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.similarSearches, 1)
        c.state.chineseSearchEnabled = false
        c.state.query = "a different execution-only query"
        c.state.search()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.recentSearchQueries, originalHistory)
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(c.translator.preparations, 0)
        assertNoIndexWork(c)
    }

    func testClearRestartsEmptyAndPreservesQueryResultsSelectionAndSyntheticIndex() async throws {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history", isDirectory: true)
        let index = root.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
        try TestFixtures.seedRawCache([TestFixtures.photo()], directory: index)
        let database = index.appendingPathComponent("index.sqlite3")
        let before = try Data(contentsOf: database)
        let store = QueryHistoryStore(directory: directory, protectedDataAvailable: { true })
        let c = await ready(store: store)
        c.state.query = "preserved query"
        c.state.submitSearchQuery()
        await c.state.waitUntilIdle()
        let beforeClearRestart = AppState(worker: QueryHistoryWorker(), authorizationStatus: { .authorized },
                         queryTranslator: QueryHistoryTranslator(),
                         queryHistoryStore: QueryHistoryStore(directory: directory, protectedDataAvailable: { true }))
        XCTAssertEqual(beforeClearRestart.recentSearchQueries, ["preserved query"])
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        let session = c.state.resultSessionID
        let results = c.state.results.map(\.id)
        let selection = c.state.selectedResultIDs
        let epoch = c.state.photoLibraryEpoch
        let completed = c.state.completedSearchQuery
        c.state.clearSearchHistory()
        XCTAssertEqual(c.state.recentSearchQueries, [])
        XCTAssertEqual(c.state.searchSuggestions, RecentSearchQueries.defaults)
        XCTAssertEqual(c.state.query, "preserved query")
        XCTAssertEqual(c.state.resultSessionID, session)
        XCTAssertEqual(c.state.results.map(\.id), results)
        XCTAssertEqual(c.state.selectedResultIDs, selection)
        XCTAssertEqual(c.state.completedSearchQuery, completed)
        XCTAssertEqual(c.state.photoLibraryEpoch, epoch)
        XCTAssertEqual(c.state.summary.indexedCount, 14)
        XCTAssertNil(c.state.searchHistoryIssue)
        let restarted = AppState(worker: QueryHistoryWorker(), authorizationStatus: { .authorized },
                                 queryTranslator: QueryHistoryTranslator(),
                                 queryHistoryStore: QueryHistoryStore(directory: directory, protectedDataAvailable: { true }))
        XCTAssertEqual(restarted.recentSearchQueries, [])
        XCTAssertEqual(try Data(contentsOf: database), before)
        assertNoIndexWork(c)
    }

    func testClearDuringSearchDoesNotCancelItOrAllowLateHistoryRestoration() async {
        let store = QueryHistoryMemoryStore()
        let c = await ready(store: store)
        let entered = expectation(description: "Search suspended before clearing history")
        c.worker.entered = entered
        c.worker.gate = QueryHistoryGate()
        c.state.query = "submitted"
        c.state.submitSearchQuery()
        await fulfillment(of: [entered], timeout: 3)
        c.state.clearSearchHistory()
        XCTAssertEqual(c.state.activity, .searching)
        c.worker.release()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.completedQuery, "submitted")
        XCTAssertEqual(c.state.recentSearchQueries, [])
        XCTAssertEqual(store.saves, [["submitted"], []])
        XCTAssertEqual(store.stored, [])
        assertNoIndexWork(c)
    }

    func testSaveFailureIsSanitizedNonfatalAndMemoryHistoryContinuesThenRecovers() async {
        let store = QueryHistoryMemoryStore()
        store.saveError = QueryHistoryPrivateError()
        let c = await ready(store: store)
        for query in ["first", "second"] {
            c.state.query = query
            c.state.submitSearchQuery()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.completedQuery, query)
            XCTAssertNil(c.state.errorMessage)
            XCTAssertEqual(c.state.searchHistoryIssue, "搜索记录暂未保存到本机。请解锁设备后重试；本次搜索不受影响。")
        }
        XCTAssertEqual(c.state.recentSearchQueries, ["second", "first"])
        XCTAssertEqual(store.stored, [])
        store.saveError = nil
        c.state.query = "third"
        c.state.submitSearchQuery()
        await c.state.waitUntilIdle()
        XCTAssertNil(c.state.searchHistoryIssue)
        XCTAssertEqual(store.stored, ["third", "second", "first"])
        assertNoIndexWork(c)
    }

    func testLoadFailureDoesNotReadErrorDescriptionOrImplicitlyOverwriteHistory() {
        let store = QueryHistoryMemoryStore(["saved"])
        store.loadError = QueryHistoryPrivateError()
        let worker = QueryHistoryWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             queryTranslator: QueryHistoryTranslator(), queryHistoryStore: store)
        XCTAssertEqual(state.recentSearchQueries, [])
        XCTAssertEqual(state.searchHistoryIssue, "无法读取本机搜索记录。请解锁设备后重新打开应用。")
        XCTAssertEqual(store.stored, ["saved"])
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(worker.refreshes, 0)
    }

    func testFailedClearReportsThatDiskHistoryRemainsAndRetryClearsIt() async {
        let store = QueryHistoryMemoryStore(["saved"])
        let c = await ready(store: store)
        store.saveError = QueryHistoryPrivateError()
        c.state.clearSearchHistory()
        XCTAssertEqual(c.state.recentSearchQueries, [])
        XCTAssertEqual(store.stored, ["saved"])
        XCTAssertEqual(c.state.searchHistoryIssue,
                       "未能清除已保存的搜索记录。请解锁设备后重试；重新打开应用时旧记录可能仍会出现。")
        let restarted = AppState(worker: QueryHistoryWorker(), authorizationStatus: { .authorized },
                                 queryTranslator: QueryHistoryTranslator(), queryHistoryStore: store)
        XCTAssertEqual(restarted.recentSearchQueries, ["saved"])
        store.saveError = nil
        c.state.clearSearchHistory()
        XCTAssertEqual(store.stored, [])
        XCTAssertNil(c.state.searchHistoryIssue)
        assertNoIndexWork(c)
    }

    func testIndexClearAndLibraryInvalidationDoNotClearQueryHistory() async {
        let store = QueryHistoryMemoryStore(["saved"])
        let c = await ready(store: store)
        c.state.clearIndex()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.clears, 1)
        XCTAssertEqual(c.state.recentSearchQueries, ["saved"])
        c.state.libraryChanged()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.recentSearchQueries, ["saved"])
        XCTAssertEqual(store.stored, ["saved"])
        XCTAssertTrue(store.saves.isEmpty)
        XCTAssertEqual(c.worker.indexes + c.worker.textIndexes, 0)
    }

    private struct Context {
        let state: AppState
        let worker: QueryHistoryWorker
        let translator: QueryHistoryTranslator
    }

    private func ready(worker suppliedWorker: QueryHistoryWorker? = nil,
                       store: (any QueryHistoryStoring)? = nil,
                       authorization: PHAuthorizationStatus = .authorized) async -> Context {
        let worker = suppliedWorker ?? QueryHistoryWorker()
        let translator = QueryHistoryTranslator()
        let state = AppState(worker: worker, authorizationStatus: { authorization },
                             queryTranslator: translator, queryHistoryStore: store)
        addTeardownBlock { await worker.release(); await state.waitUntilIdle() }
        state.refresh()
        await state.waitUntilIdle()
        return Context(state: state, worker: worker, translator: translator)
    }

    private func assertNoIndexWork(_ c: Context, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.worker.indexes, 0, file: file, line: line)
        XCTAssertEqual(c.worker.textIndexes, 0, file: file, line: line)
        XCTAssertEqual(c.worker.clears, 0, file: file, line: line)
        XCTAssertEqual(c.translator.preparations, 0, file: file, line: line)
        XCTAssertFalse(c.state.photoSync.isEnabled, file: file, line: line)
        XCTAssertEqual(c.state.photoSync.phase, .idle, file: file, line: line)
    }
}

@MainActor
private final class QueryHistoryMemoryStore: QueryHistoryStoring {
    var stored: [String]
    var loads = 0
    var saves: [[String]] = []
    var loadError: Error?
    var saveError: Error?
    init(_ stored: [String] = []) { self.stored = stored }
    func load() throws -> [String] {
        loads += 1
        if let loadError { throw loadError }
        return stored
    }
    func save(_ queries: [String]) throws {
        saves.append(queries)
        if let saveError { throw saveError }
        stored = queries
    }
}

private struct QueryHistoryPrivateError: LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    var errorDescription: String? { XCTFail("Do not evaluate a private persistence error"); return "private-query-path" }
    var description: String { XCTFail("Do not describe a private persistence error"); return "private-query-path" }
    var debugDescription: String { XCTFail("Do not debug-log a private persistence error"); return "private-query-path" }
}

@MainActor
private final class QueryHistoryGate {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class QueryHistoryTranslator: QueryTranslating {
    let isSupported = true
    let translatedText = "synthetic English translation"
    var originals: [String] = []
    var preparations = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .installed }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        originals.append(text)
        return translatedText
    }
    func prepare(_ language: QueryTranslationLanguage) async throws { preparations += 1 }
}

@MainActor
private final class QueryHistoryWorker: PhotoWorkServicing {
    var summary = LibrarySummary(authorizedCount: 14, indexedCount: 14, modelVersion: "test-model")
    var texts: [String] = []
    var filters: [PhotoSearchFilters] = []
    var refreshes = 0
    var indexes = 0
    var textIndexes = 0
    var clears = 0
    var similarSearches = 0
    var failSearch = false
    var entered: XCTestExpectation?
    var gate: QueryHistoryGate?

    func release() { gate?.open() }
    func refresh() async throws -> LibrarySummary { refreshes += 1; return summary }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        indexes += 1
        return summary
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        textIndexes += 1
        return summary
    }
    func clear() async throws -> LibrarySummary { clears += 1; return LibrarySummary(modelVersion: "test-model") }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        try await search(text: text, limit: limit, locationWeight: locationWeight, filters: .init())
    }
    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse {
        texts.append(text)
        self.filters.append(filters)
        entered?.fulfill()
        if let gate { await gate.wait() }
        if failSearch { throw AppFailure.photo("Synthetic search failed") }
        // Deliberately returns even after cancellation; AppState owns rejection.
        return try response()
    }
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        similarSearches += 1
        return try response()
    }
    private func response() throws -> SearchResponse {
        let photos = (0..<14).map { TestFixtures.photo(id: "history-fixture-\($0)").photo }
        let hits = try VectorSearch.search(query: TestFixtures.vector(), photos: photos, limit: Int.max, locationWeight: 0)
        return SearchResponse(summary: summary, hits: hits)
    }
}