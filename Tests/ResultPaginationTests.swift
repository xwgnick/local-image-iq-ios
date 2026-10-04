import Foundation
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Model-free AppState contracts. The injected worker ranks synthetic 768-D unit
/// vectors with the real VectorSearch; it never opens Photos, SQLite or a model.
/// Access/generation checks are synchronous spies, not real PhotoKit coverage.
/// Initial publication validates only its first page (including an empty page);
/// later publication validates only new IDs against the same global generation.
/// All fake async methods finish immediately: no sleeps, polling, held tasks,
/// disabled tests or wall-clock-dependent success conditions.
@MainActor
final class ResultPaginationTests: XCTestCase {
    func testDefaultTwelveExposesStableGlobalPrefixesThroughThirtySevenAndExhaustion() async throws {
        let context = await readyContext()
        let state = context.state
        XCTAssertEqual(state.resultLimit, 12)
        await search(context)
        let session = try XCTUnwrap(state.resultSessionID)
        let hits = context.worker.lastHits
        let reference = try VectorSearch.search(query: PaginationFixtures.queryVector,
                                                photos: context.worker.photos, limit: Int.max,
                                                locationWeight: Float(state.locationWeight))
        XCTAssertEqual(hits.count, 37)
        XCTAssertEqual(hits.map(\.id), reference.map(\.id))
        XCTAssertEqual(hits.map { $0.score.bitPattern }, reference.map { $0.score.bitPattern })
        XCTAssertNotEqual(hits.map(\.id), context.worker.photos.map(\.id))
        XCTAssertTrue(hits.contains { $0.score < 0 }, "Negative scores are still results, not a cutoff")
        // This fixture distinguishes one global place center from reranking an
        // independently sliced page. The expected prefix is NOT page-local work.
        let pageLocal = try VectorSearch.search(query: PaginationFixtures.queryVector,
                                                photos: Array(hits.prefix(12)).map(\.photo), limit: Int.max,
                                                locationWeight: Float(state.locationWeight))
        XCTAssertNotEqual(pageLocal.map { $0.score.bitPattern },
                          Array(hits.prefix(12)).map { $0.score.bitPattern })

        assertPrefix(context, hits: hits, count: 12, session: session)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs, [Array(hits.prefix(12)).map(\.id)])
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
        XCTAssertEqual(context.worker.requests.map(\.text), [PaginationFixtures.english])
        XCTAssertEqual(context.worker.requests.map { $0.weight.bitPattern }, [Float(0.6).bitPattern])
        XCTAssertTrue(context.translator.availabilityRequests.isEmpty)
        XCTAssertTrue(context.translator.translationRequests.isEmpty)
        let work = context.worker.counts
        let summary = state.summary
        let status = state.status
        state.selection = AppState.Selection(id: hits[0].id)

        for (before, after) in [(12, 24), (24, 36), (36, 37)] {
            state.loadMoreResults(sessionID: session, after: before)
            // Deliberately no await: validation and publication must be synchronous.
            assertPrefix(context, hits: hits, count: after, session: session)
            XCTAssertEqual(state.selection?.id, hits[0].id)
            XCTAssertEqual(state.completedQuery, PaginationFixtures.english)
            XCTAssertEqual(state.completedSearchQuery?.effective, PaginationFixtures.english)
            XCTAssertEqual(state.status, status)
            assertSummary(state.summary, equals: summary)
            XCTAssertEqual(context.worker.counts, work)
            XCTAssertEqual(context.access.snapshot.pageIDs.last, Array(hits[before..<after]).map(\.id))
            XCTAssertEqual(context.access.snapshot.pageIDs.flatMap { $0 }, Array(hits.prefix(after)).map(\.id))
        }
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id), Array(hits[24..<36]).map(\.id),
                        Array(hits[36..<37]).map(\.id)])
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs.map { $0.count }, [12, 12, 12, 1])
        XCTAssertEqual(context.access.snapshot.pageIDs.reduce(0) { $0 + $1.count }, 37,
                       "One ID check per exposed result, not a full 37-ID validation before page one")
        let access = context.access.snapshot
        state.loadMoreResults(sessionID: session, after: 37)
        state.loadMoreResults(sessionID: session, after: 37)
        assertPrefix(context, hits: hits, count: 37, session: session)
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(context.worker.counts, work)
        assertNoIndexWork(context)
    }

    func testDuplicateBottomCallbackAndIncorrectCountsDoNotAppendOrValidate() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        let before = context.access.snapshot
        for count in [-1, 0, 11, 13, Int.max] {
            context.state.loadMoreResults(sessionID: session, after: count)
        }
        context.state.loadMoreResults(sessionID: UUID(), after: 12)
        assertPrefix(context, hits: hits, count: 12, session: session)
        XCTAssertEqual(context.access.snapshot, before)

        context.state.loadMoreResults(sessionID: session, after: 12)
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.loadMoreResults(sessionID: session, after: 12)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertPrefix(context, hits: hits, count: 24, session: session)
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertTrue(access.fullIDs.isEmpty)
        XCTAssertEqual(access.pageIDs, [Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id)])
    }

    func testOldSessionCannotAppendToNewQueryWithTheSameVisibleCount() async throws {
        let context = await readyContext()
        await search(context)
        let oldSession = try XCTUnwrap(context.state.resultSessionID)
        let oldFirstPageIDs = context.state.results.map(\.id)
        context.state.query = "another synthetic English query"
        assertCleared(context.state)
        await search(context)
        let newSession = try XCTUnwrap(context.state.resultSessionID)
        XCTAssertNotEqual(oldSession, newSession)
        let hits = context.worker.lastHits
        let access = context.access.snapshot
        let work = context.worker.counts

        context.state.loadMoreResults(sessionID: oldSession, after: 12)
        assertPrefix(context, hits: hits, count: 12, session: newSession)
        XCTAssertEqual(context.access.snapshot, access)
        context.state.loadMoreResults(sessionID: newSession, after: 12)
        assertPrefix(context, hits: hits, count: 24, session: newSession)
        XCTAssertEqual(context.state.completedQuery, "another synthetic English query")
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max, Int.max])
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [oldFirstPageIDs, Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id)])
    }

    func testQueryEditImmediatelyInvalidatesAllPagesAndSelection() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        context.state.selection = AppState.Selection(id: context.state.results[0].id)
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.query += " changed"
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.access.snapshot, access)
        assertNoIndexWork(context)
    }

    func testWeightEditInvalidatesPagesAndOnlyExplicitSearchReranks() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let previousIDs = context.worker.lastHits.map(\.id)
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.locationWeight = 0
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.access.snapshot, access)
        await search(context)
        let replacement = try XCTUnwrap(context.state.resultSessionID)
        XCTAssertNotEqual(replacement, session)
        XCTAssertNotEqual(context.worker.lastHits.map(\.id), previousIDs)
        XCTAssertEqual(context.worker.requests.map(\.weight), [Float(0.6), 0])
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max, Int.max])
        assertPrefix(context, hits: context.worker.lastHits, count: 12, session: replacement)
        assertNoIndexWork(context)
    }

    func testPageSizeChangeInvalidatesRatherThanReslicingOldSession() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.resultLimit = 3
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.access.snapshot, access)
        await search(context)
        let replacement = try XCTUnwrap(context.state.resultSessionID)
        XCTAssertNotEqual(replacement, session)
        assertPrefix(context, hits: context.worker.lastHits, count: 3, session: replacement)
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max, Int.max])
        assertNoIndexWork(context)
    }

    func testCancelRevokesCompletedSessionAndRejectsItsNextPage() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        context.state.selection = AppState.Selection(id: context.state.results[0].id)
        let access = context.access.snapshot
        let work = context.worker.counts
        // Regression contract, intentionally not XCTExpectFailure: cancel must
        // revoke a stored page capability even if the search task already ended.
        context.state.cancel()
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(context.worker.counts, work)
        assertNoIndexWork(context)
    }

    func testBackgroundInvalidatesPagesAndForegroundDoesNotResurrectThem() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.enterBackground()
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.access.snapshot, access)
        context.state.enterForeground()
        await context.state.waitUntilIdle()
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.worker.counts.refreshes, work.refreshes + 1)
        XCTAssertEqual(context.worker.counts.searches, 1)
        XCTAssertEqual(context.worker.counts.rankings, 1)
        XCTAssertEqual(context.worker.counts.queryEncodings, 1)
        XCTAssertEqual(context.access.snapshot, access)
        assertNoIndexWork(context)
    }

    func testLibraryNotificationInvalidatesPagesBeforeRefreshCompletes() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let access = context.access.snapshot
        context.state.selection = AppState.Selection(id: context.state.results[0].id)
        context.state.libraryChanged()
        assertCleared(context.state)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        await context.state.waitUntilIdle()
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(context.worker.counts.refreshes, 2)
        XCTAssertEqual(context.worker.counts.searches, 1)
        assertNoIndexWork(context)
    }

    func testAccessGenerationChangeWithoutNotificationRejectsNextPage() async throws {
        let context = await readyContext()
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        let work = context.worker.counts
        let summary = context.state.summary
        context.state.selection = AppState.Selection(id: hits[0].id)
        // No rejected page ID, refresh, libraryChanged or settings edit: a global
        // generation change alone must revoke even otherwise valid page IDs.
        context.access.advanceGeneration()
        XCTAssertEqual(context.state.resultSessionID, session)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertCleared(context.state)
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id)])
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertNotNil(context.state.errorMessage)
        XCTAssertNotNil(context.state.actionHint)
        XCTAssertEqual(context.worker.counts, work)
        assertSummary(context.state.summary, equals: summary)
        assertNoIndexWork(context)
    }

    func testRevokedPermissionClearsEverythingBeforeCallingPageValidator() async throws {
        for initial in [PHAuthorizationStatus.authorized, .limited] {
            let context = await readyContext(authorization: initial)
            await search(context)
            let session = try XCTUnwrap(context.state.resultSessionID)
            context.state.selection = AppState.Selection(id: context.state.results[0].id)
            let work = context.worker.counts
            let access = context.access.snapshot
            let summary = context.state.summary
            context.permission.status = .denied
            XCTAssertEqual(context.state.authorization, initial)
            context.state.loadMoreResults(sessionID: session, after: 12)
            assertCleared(context.state)
            XCTAssertEqual(context.state.authorization, .denied)
            XCTAssertFalse(context.state.canRead)
            XCTAssertEqual(context.access.snapshot, access, "Authorization must precede page validation")
            XCTAssertNotNil(context.state.errorMessage)
            XCTAssertNotNil(context.state.actionHint)
            XCTAssertEqual(context.worker.counts, work)
            assertSummary(context.state.summary, equals: summary)
            assertNoIndexWork(context)
        }
    }

    func testNewPageValidationFailureClearsEarlierPagesWithoutMutatingIndex() async throws {
        let context = await readyContext()
        let ranked = try VectorSearch.search(query: PaginationFixtures.queryVector,
                                             photos: context.worker.photos, limit: Int.max,
                                             locationWeight: Float(context.state.locationWeight))
        // A hidden ID is not checked during initial publication. Without a
        // generation change, reject it only when its own page is first exposed.
        context.access.rejectPage(containing: ranked[25].id)
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        assertPrefix(context, hits: hits, count: 12, session: session)
        context.state.loadMoreResults(sessionID: session, after: 12)
        assertPrefix(context, hits: hits, count: 24, session: session)
        context.state.selection = AppState.Selection(id: hits[0].id)
        let work = context.worker.counts
        let summary = context.state.summary
        context.state.loadMoreResults(sessionID: session, after: 24)
        assertCleared(context.state)
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id), Array(hits[24..<36]).map(\.id)])
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertNotNil(context.state.errorMessage)
        XCTAssertTrue(context.state.actionHint?.contains("index is unchanged") == true)
        assertSummary(context.state.summary, equals: summary)
        XCTAssertEqual(context.worker.counts, work)
        assertNoIndexWork(context)
        let access = context.access.snapshot
        context.state.loadMoreResults(sessionID: session, after: 24)
        context.state.loadMoreResults(sessionID: session, after: 0)
        assertCleared(context.state)
        XCTAssertEqual(context.access.snapshot, access)
    }

    func testInitialPageValidationFailurePublishesNeitherSummaryNorSession() async throws {
        for generationChanged in [false, true] {
            let context = await readyContext()
            let summary = context.state.summary
            let ranked = try VectorSearch.search(query: PaginationFixtures.queryVector,
                                                 photos: context.worker.photos, limit: Int.max,
                                                 locationWeight: Float(context.state.locationWeight))
            if generationChanged {
                // The response captures its generation before this deterministic
                // change. Its page IDs are unchanged; the global guard must fail.
                context.worker.advanceGenerationBeforeReturningResponse = true
            } else {
                context.access.rejectPage(containing: try XCTUnwrap(ranked.first?.id))
            }
            await search(context)
            assertCleared(context.state)
            XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
            XCTAssertEqual(context.access.snapshot.pageIDs, [Array(ranked.prefix(12)).map(\.id)])
            XCTAssertNotNil(context.state.errorMessage)
            XCTAssertNotNil(context.state.actionHint)
            assertSummary(context.state.summary, equals: summary)
            XCTAssertEqual(context.state.summary.indexedCount, 7, "Do not publish the failed response's 37")
            XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
            assertNoIndexWork(context)
        }
    }

    func testEmptyResponseIsCompletedAndNeverLoadsAnotherPage() async throws {
        try await assertTerminalResponse(count: 0)
        let context = await readyContext(count: 0)
        let summary = context.state.summary
        context.worker.advanceGenerationBeforeReturningResponse = true
        await search(context)
        assertCleared(context.state)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs, [[]],
                       "An empty first page must still validate the captured global generation")
        XCTAssertNotNil(context.state.errorMessage)
        XCTAssertNotNil(context.state.actionHint)
        assertSummary(context.state.summary, equals: summary)
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
        assertNoIndexWork(context)
    }

    func testFewerThanTwelveResultsAreExhaustedOnFirstPage() async throws {
        try await assertTerminalResponse(count: 7)
    }

    func testExactlyTwelveResultsDoNotAdvertiseOrValidateAnExtraPage() async throws {
        try await assertTerminalResponse(count: 12)
    }

    func testCustomThreeReusesOneResponseWithFixedThreeThreeOnePages() async throws {
        let context = await readyContext(count: 7)
        XCTAssertEqual(context.state.resultLimit, 12)
        context.state.resultLimit = 3
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        let work = context.worker.counts
        assertPrefix(context, hits: hits, count: 3, session: session)
        // Assigning unchanged settings is not a new search/session.
        context.state.resultLimit = 3
        context.state.query = PaginationFixtures.english
        context.state.locationWeight = 0.6
        XCTAssertEqual(context.state.resultSessionID, session)
        context.state.loadMoreResults(sessionID: session, after: 3)
        assertPrefix(context, hits: hits, count: 6, session: session)
        context.state.loadMoreResults(sessionID: session, after: 6)
        assertPrefix(context, hits: hits, count: 7, session: session)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [Array(hits[0..<3]).map(\.id), Array(hits[3..<6]).map(\.id), Array(hits[6..<7]).map(\.id)])
        XCTAssertEqual(context.access.snapshot.pageIDs.map { $0.count }, [3, 3, 1])
        XCTAssertEqual(context.access.snapshot.pageIDs.flatMap { $0 }, hits.map(\.id))
        let access = context.access.snapshot
        context.state.loadMoreResults(sessionID: session, after: 7)
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
        assertNoIndexWork(context)
    }

    func testChineseQueryTranslatesAndEncodesOnlyOnceAcrossAllPages() async throws {
        let context = await readyContext()
        let original = " \t一只小狗和白色的笔\n "
        context.state.query = original
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        let resolution = context.state.completedSearchQuery
        XCTAssertEqual(resolution, SearchQueryResolution(original: original, effective: PaginationFixtures.english,
                                                        translated: true, notice: nil))
        XCTAssertEqual(context.translator.availabilityRequests.count, 1)
        XCTAssertEqual(context.translator.translationRequests, [original])
        XCTAssertEqual(context.translator.translationLanguages, context.translator.availabilityRequests)
        XCTAssertEqual(context.worker.requests.map(\.text), [PaginationFixtures.english])
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
        let work = context.worker.counts
        for (before, after) in [(12, 24), (24, 36), (36, 37)] {
            context.state.loadMoreResults(sessionID: session, after: before)
            assertPrefix(context, hits: hits, count: after, session: session)
            XCTAssertEqual(context.state.query, original)
            XCTAssertEqual(context.state.completedQuery, original)
            XCTAssertEqual(context.state.completedSearchQuery, resolution)
        }
        XCTAssertEqual(context.translator.availabilityRequests.count, 1)
        XCTAssertEqual(context.translator.translationRequests, [original])
        XCTAssertTrue(context.translator.preparationRequests.isEmpty)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(work.queryEncodings, 1)
        XCTAssertEqual(work.rankings, 1)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs,
                       [Array(hits[0..<12]).map(\.id), Array(hits[12..<24]).map(\.id), Array(hits[24..<36]).map(\.id),
                        Array(hits[36..<37]).map(\.id)])
        assertNoIndexWork(context)
    }

    // MARK: Immediate, fully awaited setup; synchronous page assertions

    private func readyContext(count: Int = 37,
                              authorization: PHAuthorizationStatus = .authorized) async -> PaginationContext {
        let context = PaginationContext(count: count, authorization: authorization)
        addTeardownBlock { await context.state.waitUntilIdle() }
        context.state.refresh()
        await context.state.waitUntilIdle()
        context.state.query = PaginationFixtures.english
        XCTAssertEqual(context.state.summary.indexedCount, 7,
                       "Synthetic saved counts keep empty-response searches reachable")
        XCTAssertTrue(context.state.canRead)
        XCTAssertTrue(context.state.modelsReady)
        XCTAssertTrue(context.state.canSearch, "Fail on broken readiness; never wait for a disabled search")
        XCTAssertNil(context.state.appleTranslationService)
        XCTAssertFalse(context.state.allowICloudDownload)
        return context
    }

    private func search(_ context: PaginationContext, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(context.state.canSearch, file: file, line: line)
        let previous = context.worker.counts.searches
        context.state.search()
        await context.state.waitUntilIdle()
        XCTAssertFalse(context.state.isBusy, file: file, line: line)
        XCTAssertEqual(context.worker.counts.searches, previous + 1, file: file, line: line)
        XCTAssertEqual(context.worker.counts.queryEncodings, previous + 1, file: file, line: line)
        XCTAssertEqual(context.worker.counts.rankings, previous + 1, file: file, line: line)
    }

    private func assertPrefix(_ context: PaginationContext, hits: [SearchHit], count: Int, session: UUID,
                              file: StaticString = #filePath, line: UInt = #line) {
        let state = context.state
        let prefix = Array(hits.prefix(count))
        XCTAssertEqual(state.results.count, count, file: file, line: line)
        XCTAssertEqual(state.results.map(\.id), prefix.map(\.id), file: file, line: line)
        XCTAssertEqual(state.results.map { $0.score.bitPattern }, prefix.map { $0.score.bitPattern }, file: file, line: line)
        XCTAssertEqual(state.results.map { $0.photo.imageEmbedding }, prefix.map { $0.photo.imageEmbedding }, file: file, line: line)
        XCTAssertEqual(Set(state.results.map(\.id)).count, count, file: file, line: line)
        XCTAssertEqual(state.resultSessionID, session, file: file, line: line)
        XCTAssertEqual(state.totalResultCount, hits.count, file: file, line: line)
        XCTAssertEqual(state.hasMoreResults, count < hits.count, file: file, line: line)
        XCTAssertFalse(state.isBusy, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertNil(state.actionHint, file: file, line: line)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty,
                      "An explicit page validator must bypass the legacy full-response validator", file: file, line: line)
    }

    private func assertCleared(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.resultSessionID, file: file, line: line)
        XCTAssertEqual(state.totalResultCount, 0, file: file, line: line)
        XCTAssertFalse(state.hasMoreResults, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
    }

    private func assertSummary(_ actual: LibrarySummary, equals expected: LibrarySummary,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.authorizedCount, expected.authorizedCount, file: file, line: line)
        XCTAssertEqual(actual.authorizedCountKnown, expected.authorizedCountKnown, file: file, line: line)
        XCTAssertEqual(actual.indexStatisticsKnown, expected.indexStatisticsKnown, file: file, line: line)
        XCTAssertEqual(actual.indexedCount, expected.indexedCount, file: file, line: line)
        XCTAssertEqual(actual.locatedCount, expected.locatedCount, file: file, line: line)
        XCTAssertEqual(actual.modelVersion, expected.modelVersion, file: file, line: line)
        XCTAssertEqual(actual.modelIssue, expected.modelIssue, file: file, line: line)
        XCTAssertEqual(actual.placesDescription, expected.placesDescription, file: file, line: line)
    }

    private func assertNoIndexWork(_ context: PaginationContext, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context.worker.counts.indexes, 0, file: file, line: line)
        XCTAssertEqual(context.worker.counts.clears, 0, file: file, line: line)
        XCTAssertEqual(context.worker.counts.checks, 0, file: file, line: line)
        XCTAssertTrue(context.translator.preparationRequests.isEmpty, file: file, line: line)
        XCTAssertFalse(context.state.allowICloudDownload, file: file, line: line)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(context.worker.photos),
                           try encoder.encode(PaginationFixtures.photos(count: context.fixtureCount)), file: file, line: line)
        } catch { XCTFail("Cannot compare synthetic index: \(error)", file: file, line: line) }
    }

    private func assertTerminalResponse(count: Int) async throws {
        let context = await readyContext(count: count)
        await search(context)
        let session = try XCTUnwrap(context.state.resultSessionID)
        let hits = context.worker.lastHits
        assertPrefix(context, hits: hits, count: count, session: session)
        XCTAssertEqual(context.state.completedQuery, PaginationFixtures.english)
        XCTAssertEqual(context.state.completedSearchQuery?.effective, PaginationFixtures.english)
        XCTAssertTrue(context.access.snapshot.fullIDs.isEmpty)
        XCTAssertEqual(context.access.snapshot.pageIDs, [hits.map(\.id)],
                       "Even an empty first page is validated once")
        let work = context.worker.counts
        let access = context.access.snapshot
        context.state.loadMoreResults(sessionID: session, after: count)
        context.state.loadMoreResults(sessionID: session, after: count)
        assertPrefix(context, hits: hits, count: count, session: session)
        XCTAssertEqual(context.worker.counts, work)
        XCTAssertEqual(context.worker.requests.map(\.limit), [Int.max])
        XCTAssertEqual(context.access.snapshot, access)
        XCTAssertEqual(access.pageIDs.count, 1, "Exhaustion must not validate another page")
        assertNoIndexWork(context)
    }
}

// MARK: Entirely synthetic, test-local dependencies

private enum PaginationFixtures {
    static let modelVersion = "pagination-test-model"
    static let english = "TEST FIXTURE a dog with a white pen"
    static var queryVector: [Float] { unit(axis: 0) }

    static func unit(axis: Int, sign: Float = 1) -> [Float] {
        var vector = [Float](repeating: 0, count: 768)
        vector[axis] = sign
        return vector
    }

    static func photos(count: Int) -> [IndexedPhoto] {
        var photos: [IndexedPhoto] = []
        for index in 0..<count {
            let place: PlaceEmbedding?
            switch index % 5 {
            case 0, 1: place = PlaceEmbedding(text: "TEST repeated positive place", vector: unit(axis: 0))
            case 2: place = PlaceEmbedding(text: "TEST negative place", vector: unit(axis: 0, sign: -1))
            case 3: place = PlaceEmbedding(text: "TEST orthogonal place", vector: unit(axis: 1))
            default: place = nil
            }
            photos.append(IndexedPhoto(id: String(format: "pagination-%03d", index), modificationTime: Double(index),
                                       modelVersion: modelVersion,
                                       imageEmbedding: unit(axis: index % 3, sign: index.isMultiple(of: 2) ? 1 : -1),
                                       location: place, creationTime: Double(1000 - index)))
        }
        return Array(photos.reversed()) // Real score/UTF-8 tie ordering, not input/date ordering.
    }

    static func summary(count: Int, located: Int = 0) -> LibrarySummary {
        LibrarySummary(authorizedCount: count, authorizedCountKnown: true, indexStatisticsKnown: true,
                       indexedCount: count, locatedCount: located, modelVersion: modelVersion,
                       placesDescription: "TEST synthetic places")
    }
}

/// Every mutable field is protected by the same lock. Validators have the real
/// nonisolated @Sendable synchronous signature, with no actor hop or async Task.
private final class PaginationAccessProbe: @unchecked Sendable {
    struct Snapshot: Equatable {
        var fullIDs: [[String]] = []
        var pageIDs: [[String]] = []
    }

    private let lock = NSLock()
    private var recorded = Snapshot()
    private var currentGeneration = 0
    private var rejectedPageID: String?

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return currentGeneration
    }

    func advanceGeneration() {
        lock.lock(); defer { lock.unlock() }
        currentGeneration += 1
    }

    func rejectPage(containing id: String) {
        lock.lock(); defer { lock.unlock() }
        rejectedPageID = id
    }

    func validate(_ ids: [String], full: Bool, generation: Int) throws {
        lock.lock(); defer { lock.unlock() }
        if full { recorded.fullIDs.append(ids) } else { recorded.pageIDs.append(ids) }
        guard currentGeneration == generation,
              !(rejectedPageID.map { ids.contains($0) } ?? false) else {
            throw AppFailure.photo("TEST pagination access changed")
        }
    }
}

@MainActor
private final class PaginationPermission {
    var status: PHAuthorizationStatus
    init(_ status: PHAuthorizationStatus) { self.status = status }
}

@MainActor
private final class PaginationTranslator: QueryTranslating {
    let isSupported = true
    private(set) var availabilityRequests: [QueryTranslationLanguage] = []
    private(set) var translationRequests: [String] = []
    private(set) var translationLanguages: [QueryTranslationLanguage] = []
    private(set) var preparationRequests: [QueryTranslationLanguage] = []

    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityRequests.append(language)
        return .installed
    }

    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationRequests.append(text)
        translationLanguages.append(language)
        return PaginationFixtures.english
    }

    func prepare(_ language: QueryTranslationLanguage) async throws {
        preparationRequests.append(language)
        XCTFail("Pagination must never prepare a language pack")
    }
}

/// MainActor isolation satisfies Sendable, following the existing state-test
/// worker pattern. Both prepareForLaunch overloads use the protocol's compatible
/// defaults; this test worker never initializes encoders or loads launch models.
@MainActor
private final class PaginationWorker: PhotoWorkServicing {
    struct Request {
        let text: String
        let limit: Int
        let weight: Float
    }

    struct Counts: Equatable {
        var refreshes = 0
        var searches = 0
        var queryEncodings = 0
        var rankings = 0
        var indexes = 0
        var clears = 0
        var checks = 0
    }

    let photos: [IndexedPhoto]
    private let access: PaginationAccessProbe
    private(set) var counts = Counts()
    private(set) var requests: [Request] = []
    private(set) var lastHits: [SearchHit] = []
    var advanceGenerationBeforeReturningResponse = false

    init(count: Int, access: PaginationAccessProbe) {
        photos = PaginationFixtures.photos(count: count)
        self.access = access
    }

    func refresh() async throws -> LibrarySummary {
        counts.refreshes += 1
        // Search readiness must also be reachable for the empty response test.
        // These are stored metadata counts, not the current accessible hit count.
        return PaginationFixtures.summary(count: 7)
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        counts.searches += 1
        requests.append(Request(text: text, limit: limit, weight: locationWeight))
        counts.queryEncodings += 1 // Synthetic stand-in, not a claim of real model inference.
        let query = PaginationFixtures.queryVector
        counts.rankings += 1
        let hits = try VectorSearch.search(query: query, photos: photos, limit: limit, locationWeight: locationWeight)
        lastHits = hits
        let access = self.access
        let generation = access.generation
        let ids = hits.map(\.id)
        let response = SearchResponse(
            summary: PaginationFixtures.summary(count: photos.count, located: photos.filter { $0.location != nil }.count),
            hits: hits,
            validateAccess: { try access.validate(ids, full: true, generation: generation) },
            validatePageAccess: { try access.validate($0, full: false, generation: generation) }
        )
        if advanceGenerationBeforeReturningResponse { access.advanceGeneration() }
        return response
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        counts.indexes += 1
        XCTFail("Pagination must not index photos")
        return PaginationFixtures.summary(count: 7)
    }

    func clear() async throws -> LibrarySummary {
        counts.clears += 1
        XCTFail("Pagination must not clear the saved index")
        return PaginationFixtures.summary(count: 0)
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        counts.checks += 1
        XCTFail("Pagination must not run photo diagnostics or fresh image encoding")
        throw AppFailure.photo("TEST unexpected photo diagnostic")
    }
}

@MainActor
private final class PaginationContext {
    let fixtureCount: Int
    let access: PaginationAccessProbe
    let permission: PaginationPermission
    let translator: PaginationTranslator
    let worker: PaginationWorker
    let state: AppState

    init(count: Int, authorization: PHAuthorizationStatus) {
        fixtureCount = count
        let access = PaginationAccessProbe()
        let permission = PaginationPermission(authorization)
        let translator = PaginationTranslator()
        let worker = PaginationWorker(count: count, access: access)
        self.access = access
        self.permission = permission
        self.translator = translator
        self.worker = worker
        state = AppState(worker: worker, authorizationStatus: { permission.status }, queryTranslator: translator)
    }
}