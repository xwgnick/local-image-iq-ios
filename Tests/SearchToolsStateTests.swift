import Foundation
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Real AppState, injected MainActor services, and 37 synthetic cached rows.
/// No model, SQLite, image fetch, Photos mutation, translation session or network.
/// AppState still constructs its normal library/observer wrapper; its authorization
/// reads/observer registration are not a claim of zero PhotoKit API calls.
/// Held workers intentionally return captured successes after cancellation.
/// ResultPhotoActionsState's separate 14 tests own the mutation/share contracts.
@MainActor
final class SearchToolsStateTests: XCTestCase {
    func testDefaultsAndLegacyWorkerUseDynamicEmptyFilterCompatibilityOnly() async throws {
        let worker = SearchToolsLegacyWorker()
        let translator = SearchToolsTranslator()
        let state = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        addTeardownBlock { await state.waitUntilIdle() }
        XCTAssertEqual(state.searchFilters, PhotoSearchFilters())
        XCTAssertTrue(state.searchFilters.isEmpty)
        XCTAssertEqual(state.resultLimit, 12)
        assertCleared(state)
        state.refresh()
        await state.waitUntilIdle()
        state.query = "  TEST legacy query\n"
        state.locationWeight = 0.37
        state.search()
        await state.waitUntilIdle()

        XCTAssertEqual(worker.requests, [SearchToolsTextRequest(text: state.query, limit: Int.max,
                                                                weight: 0.37, filters: .init())])
        XCTAssertEqual(state.results.map(\.id), Array(worker.hits.prefix(12)).map(\.id))
        XCTAssertEqual(state.totalResultCount, 37)
        XCTAssertEqual(state.completedSearchQuery, SearchQueryResolution(original: state.query,
                                                                         effective: state.query,
                                                                         translated: false, notice: nil))
        XCTAssertEqual(translator.counts, [0, 0, 0])

        // Existing mocks implement ONLY the old requirement. The extension must
        // dynamically forward empty filters, not silently discard nonempty ones.
        let service: any PhotoWorkServicing = worker
        _ = try await service.search(text: "exact", limit: -7, locationWeight: 0.23, filters: .init())
        XCTAssertEqual(worker.requests.last, SearchToolsTextRequest(text: "exact", limit: -7,
                                                                    weight: 0.23, filters: .init()))
        let calls = worker.requests
        do {
            _ = try await service.search(text: "blocked", limit: 12, locationWeight: 0.6,
                                         filters: .init(imageKind: .screenshots))
            XCTFail("A legacy worker must reject unsupported nonempty filters")
        } catch { XCTAssertTrue(error is AppFailure) }
        do {
            _ = try await service.searchSimilar(photoID: worker.hits[0].id, limit: 12, filters: .init())
            XCTFail("A legacy worker must reject unsupported similarity")
        } catch { XCTAssertTrue(error is AppFailure) }
        XCTAssertEqual(worker.requests, calls)
        XCTAssertEqual(worker.mutations, 0)
    }

    func testDateAlbumAndEveryImageKindReachDynamicWorkerAsImmutableValues() async throws {
        for kind in PhotoSearchImageKind.allCases {
            let c = await ready()
            var draft = PhotoSearchFilters(startDate: SearchToolsFixtures.date(3),
                                           endDateExclusive: SearchToolsFixtures.date(31),
                                           albumID: "even", imageKind: kind)
            let captured = draft
            c.state.applySearchFilters(draft)
            c.state.query = SearchToolsFixtures.chinese
            c.state.locationWeight = 0.37
            let gate = hold(c)
            c.translator.nextGate = gate
            c.state.search()
            XCTAssertEqual(c.state.activity, .searching)
            // Both the submitted filters and query settings were captured before
            // translation suspended. Editing the dialog's value is not applying it.
            draft.startDate = SearchToolsFixtures.date(35)
            draft.endDateExclusive = nil
            draft.albumID = "odd"
            draft.imageKind = .photos
            guard await entered(gate) else { return }
            XCTAssertTrue(c.worker.textRequests.isEmpty)
            XCTAssertEqual(c.state.searchFilters, captured)
            gate.open()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.textRequests, [SearchToolsTextRequest(text: SearchToolsFixtures.english,
                                                                          limit: Int.max, weight: 0.37,
                                                                          filters: captured)])
            XCTAssertEqual(c.worker.legacyCalls, 0, "Nonempty filters require the new protocol witness")
            let expected = try c.worker.expectedHits(filters: captured, weight: 0.37)
            assertHits(c.state.results, Array(expected.prefix(12)))
            XCTAssertEqual(c.state.totalResultCount, expected.count)
            XCTAssertFalse(expected.isEmpty, "Every kind must have a real matching synthetic row")
            XCTAssertNil(c.state.errorMessage)
            assertReadOnly(c)
        }
    }

    func testInvalidFilterApplicationPreservesCompletedSessionAndNeverCallsWorker() async throws {
        let c = await ready()
        await search(c)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let hits = c.state.results
        let resolution = c.state.completedSearchQuery
        c.state.setSelectingResults(true)
        c.state.toggleResultSelection(try XCTUnwrap(hits.first?.id))
        let selected = c.state.selectedResultIDs
        let calls = c.worker.counts
        for invalid in invalidFilters {
            c.state.applySearchFilters(invalid)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.searchFilters, PhotoSearchFilters())
            XCTAssertEqual(c.state.resultSessionID, session)
            XCTAssertEqual(c.state.completedSearchQuery, resolution)
            XCTAssertEqual(c.state.selectedResultIDs, selected)
            XCTAssertTrue(c.state.isSelectingResults)
            assertHits(c.state.results, hits)
            XCTAssertNotNil(c.state.errorMessage)
            XCTAssertEqual(c.worker.counts, calls)
        }
        assertReadOnly(c)
    }

    func testApplyingFiltersToCompletedTranslatedTextRerunsMatchingResolution() async throws {
        let c = await ready()
        c.state.query = SearchToolsFixtures.chinese
        await search(c)
        let old = try XCTUnwrap(c.state.resultSessionID)
        let resolution = c.state.completedSearchQuery
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        let filters = PhotoSearchFilters(albumID: "even", imageKind: .screenshots)
        c.state.applySearchFilters(filters)
        assertCleared(c.state)
        XCTAssertEqual(c.state.activity, .searching)
        await c.state.waitUntilIdle()

        XCTAssertNotEqual(c.state.resultSessionID, old)
        XCTAssertEqual(c.state.completedSearchQuery, resolution)
        XCTAssertEqual(c.state.completedQuery, SearchToolsFixtures.chinese)
        XCTAssertEqual(c.state.completedSearchQuery?.effective, SearchToolsFixtures.english)
        XCTAssertEqual(c.worker.textRequests.map(\.text), [SearchToolsFixtures.english, SearchToolsFixtures.english])
        XCTAssertEqual(c.worker.textRequests.map(\.filters), [.init(), filters])
        XCTAssertEqual(c.worker.textRequests.map(\.limit), [Int.max, Int.max])
        XCTAssertEqual(c.worker.refreshCalls, 1)
        XCTAssertTrue(c.worker.similarRequests.isEmpty)
        assertHits(c.state.results, Array(try c.worker.expectedHits(filters: filters).prefix(12)))
        assertReadOnly(c)
    }

    func testApplyingFiltersPreservesExplicitUseOriginalResolution() async throws {
        let c = await ready()
        c.state.query = SearchToolsFixtures.chinese
        c.state.search(useOriginal: true)
        await c.state.waitUntilIdle()
        let originalResolution = try XCTUnwrap(c.state.completedSearchQuery)
        XCTAssertFalse(originalResolution.translated)
        XCTAssertEqual(c.translator.counts, [0, 0, 0])

        c.state.applySearchFilters(.init(albumID: "even"))
        await c.state.waitUntilIdle()
        // Regression contract, NOT an expected failure or an AppState workaround:
        // changing candidate filters must not silently switch an explicit original
        // query back to English. Current applySearchFilters calls search() with its
        // default useOriginal=false and loses this completed-query choice.
        XCTAssertEqual(c.state.completedSearchQuery, originalResolution,
                       "Preserve the effective query chosen by Use Original when applying filters")
        XCTAssertEqual(c.worker.textRequests.map(\.text), [SearchToolsFixtures.chinese, SearchToolsFixtures.chinese])
        XCTAssertEqual(c.translator.counts, [0, 0, 0])
        assertReadOnly(c)
    }

    func testSimilarityFromSelectedVisibleResultUsesCachedSeedWithoutTranslation() async throws {
        let c = await ready()
        c.state.query = SearchToolsFixtures.chinese
        await search(c)
        let source = try XCTUnwrap(c.state.results.dropFirst(3).first)
        let textCalls = c.worker.textRequests
        let translationCalls = c.translator.counts
        c.state.selection = AppState.Selection(id: source.id)
        c.state.setSelectingResults(true)
        c.state.toggleResultSelection(source.id)
        c.state.searchSimilar(to: source.id)
        assertCleared(c.state)
        await c.state.waitUntilIdle()

        XCTAssertEqual(c.worker.similarRequests, [SearchToolsSimilarRequest(id: source.id, limit: Int.max, filters: .init())])
        XCTAssertEqual(c.worker.seedVectors, [source.photo.imageEmbedding])
        XCTAssertEqual(c.worker.textRequests, textCalls)
        XCTAssertEqual(c.translator.counts, translationCalls)
        XCTAssertEqual(c.state.similarPhotoID, source.id)
        XCTAssertEqual(c.state.completedQuery, "相似照片")
        XCTAssertEqual(c.state.completedSearchQuery, SearchQueryResolution(original: "相似照片", effective: "相似照片",
                                                                         translated: false, notice: nil))
        XCTAssertEqual(c.state.query, SearchToolsFixtures.chinese)
        XCTAssertEqual(c.state.totalResultCount, 36)
        XCTAssertFalse(c.worker.lastHits.contains { $0.id == source.id })
        assertHits(c.state.results, Array(try c.worker.expectedHits(seed: source.id).prefix(12)))
        assertReadOnly(c)
    }

    func testSimilarityRejectsHiddenUnknownAndInvalidatedEmptyQuerySources() async throws {
        let c = await ready()
        await search(c)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let source = try XCTUnwrap(c.state.results.first?.id)
        let hidden = c.worker.lastHits[12].id
        let calls = c.worker.counts
        for id in [hidden, "not-a-fixture-id", "", " \n"] {
            c.state.searchSimilar(to: id)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.counts, calls)
            XCTAssertEqual(c.state.resultSessionID, session)
            XCTAssertNil(c.state.similarPhotoID)
        }
        c.state.searchSimilar(to: source)
        await c.state.waitUntilIdle()
        let similarSession = try XCTUnwrap(c.state.resultSessionID)
        let similarCalls = c.worker.counts
        let visible = try XCTUnwrap(c.state.results.first?.id)
        c.state.query = ""
        assertCleared(c.state)
        c.state.searchSimilar(to: visible)
        c.state.loadMoreResults(sessionID: similarSession, after: 12)
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.canSearch)
        XCTAssertEqual(c.worker.counts, similarCalls)
        assertCleared(c.state)
        // API limitation: query.didSet revokes results AND the visual seed. There
        // is no public way to create an empty-query similarity session in this
        // AppState. Do not seed private state/KVC or weaken query invalidation to
        // manufacture the otherwise desirable empty-query paging scenario.
        assertReadOnly(c)
    }

    func testTextSearchResetsSimilaritySeedEvenWithoutEditingQuery() async throws {
        let c = await ready()
        c.state.query = SearchToolsFixtures.chinese
        await search(c)
        c.state.searchSimilar(to: try XCTUnwrap(c.state.results.first?.id))
        await c.state.waitUntilIdle()
        XCTAssertNotNil(c.state.similarPhotoID)
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        let similarCalls = c.worker.similarRequests
        c.state.search()
        assertCleared(c.state)
        await c.state.waitUntilIdle()
        XCTAssertNil(c.state.similarPhotoID)
        XCTAssertEqual(c.worker.similarRequests, similarCalls)
        XCTAssertEqual(c.worker.textRequests.count, 2)
        XCTAssertEqual(c.state.completedQuery, SearchToolsFixtures.chinese)
        XCTAssertEqual(c.state.completedSearchQuery?.effective, SearchToolsFixtures.english)
        XCTAssertFalse(c.state.isSelectingResults)
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
        assertReadOnly(c)
    }

    func testFilterApplicationRepeatsSimilaritySeedExcludedFromPreviousResults() async throws {
        let c = await ready()
        await search(c)
        let source = try XCTUnwrap(c.state.results.first?.id) // Fixture index zero: even, screenshot.
        c.state.searchSimilar(to: source)
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.results.contains { $0.id == source })
        let textCalls = c.worker.textRequests
        let translationCalls = c.translator.counts
        let filters: [PhotoSearchFilters] = [.init(albumID: "odd"), .init(albumID: "empty"), .init(albumID: "even")]
        for filter in filters {
            let old = try XCTUnwrap(c.state.resultSessionID)
            c.state.applySearchFilters(filter)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.similarPhotoID, source)
            XCTAssertNotEqual(c.state.resultSessionID, old)
            XCTAssertEqual(c.state.searchFilters, filter)
            XCTAssertEqual(c.state.completedQuery, "相似照片", "Even zero matches retain the visual-query label")
            XCTAssertEqual(c.worker.similarRequests.last, SearchToolsSimilarRequest(id: source, limit: Int.max, filters: filter))
            XCTAssertFalse(c.state.results.contains { $0.id == source })
            let expected = try c.worker.expectedHits(filters: filter, seed: source)
            XCTAssertEqual(c.state.totalResultCount, expected.count)
            assertHits(c.state.results, Array(expected.prefix(12)))
            XCTAssertNil(c.state.errorMessage)
        }
        XCTAssertEqual(c.worker.similarRequests.count, 4)
        XCTAssertEqual(c.worker.textRequests, textCalls)
        XCTAssertEqual(c.translator.counts, translationCalls)
        assertReadOnly(c)
    }

    func testTextAndSimilarityPagesRetainCapturedRowsAfterWorkerFixtureRemoval() async throws {
        for similar in [false, true] {
            let c = await ready()
            await search(c)
            if similar {
                c.state.searchSimilar(to: try XCTUnwrap(c.state.results.first?.id))
                await c.state.waitUntilIdle()
            }
            let session = try XCTUnwrap(c.state.resultSessionID)
            let hits = c.worker.lastHits
            let resolution = c.state.completedSearchQuery
            let seed = c.state.similarPhotoID
            let calls = c.worker.counts
            let translationCalls = c.translator.counts
            XCTAssertEqual(c.state.resultLimit, 12)
            XCTAssertEqual(hits.count, similar ? 36 : 37)
            assertHits(c.state.results, Array(hits.prefix(12)))
            c.worker.rows.removeAll() // Fake storage disappears; captured response owns every old ID/vector.
            XCTAssertTrue(c.worker.rows.isEmpty)
            var count = 12
            while count < hits.count {
                c.state.loadMoreResults(sessionID: session, after: count)
                let next = min(count + 12, hits.count)
                assertHits(c.state.results, Array(hits.prefix(next)))
                c.state.loadMoreResults(sessionID: session, after: count) // Duplicate boundary is inert.
                XCTAssertEqual(c.state.results.count, next)
                XCTAssertEqual(c.state.resultSessionID, session)
                XCTAssertEqual(c.state.similarPhotoID, seed)
                XCTAssertEqual(c.state.completedSearchQuery, resolution)
                XCTAssertEqual(c.state.completedQuery, similar ? "相似照片" : SearchToolsFixtures.english)
                count = next
            }
            c.state.loadMoreResults(sessionID: session, after: count)
            XCTAssertFalse(c.state.hasMoreResults)
            XCTAssertEqual(c.state.totalResultCount, hits.count)
            XCTAssertEqual(c.worker.counts, calls)
            XCTAssertEqual(c.translator.counts, translationCalls)
            assertReadOnly(c)
        }
    }

    func testSelectionOnlyTogglesVisibleIDsAndNeverCallsAnyWorkerOrTranslator() async throws {
        let c = await ready()
        c.state.setSelectingResults(true)
        XCTAssertFalse(c.state.isSelectingResults)
        await search(c)
        let visible = c.state.results.map(\.id)
        let hidden = c.worker.lastHits[12].id
        let calls = c.worker.counts
        let translationCalls = c.translator.counts
        let session = c.state.resultSessionID
        c.state.toggleResultSelection(visible[0])
        c.state.selectVisibleResults()
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty, "Both APIs require selection mode")
        c.state.setSelectingResults(true)
        for id in [visible[8], visible[1], visible[4], hidden, "arbitrary-id", ""] {
            c.state.toggleResultSelection(id)
        }
        XCTAssertEqual(c.state.selectedResultIDs, Set([visible[8], visible[1], visible[4]]))
        XCTAssertEqual(c.state.orderedSelectedResultIDs, [visible[1], visible[4], visible[8]])
        c.state.toggleResultSelection(visible[4])
        XCTAssertEqual(c.state.orderedSelectedResultIDs, [visible[1], visible[8]])
        c.state.setSelectingResults(true)
        XCTAssertEqual(c.state.selectedResultIDs.count, 2, "Re-entering selection must not toggle existing IDs")
        c.state.setSelectingResults(false)
        XCTAssertFalse(c.state.isSelectingResults)
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
        XCTAssertTrue(c.state.orderedSelectedResultIDs.isEmpty)
        XCTAssertEqual(c.state.resultSessionID, session)
        XCTAssertEqual(c.worker.counts, calls)
        XCTAssertEqual(c.translator.counts, translationCalls)
        assertReadOnly(c)
    }

    func testAppendsPreserveSelectionsAndSelectAllMeansOnlyCurrentlyVisibleRankOrder() async throws {
        let c = await ready()
        await search(c)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let hits = c.worker.lastHits
        let calls = c.worker.counts
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        XCTAssertEqual(c.state.selectedResultIDs, Set(hits.prefix(12).map(\.id)))
        XCTAssertNotEqual(c.state.selectedResultIDs.count, c.state.totalResultCount)
        XCTAssertNotEqual(hits.map(\.id), hits.map(\.id).sorted(), "Rank must differ from lexicographic ID order")
        for (before, after) in [(12, 24), (24, 36), (36, 37)] {
            let selected = c.state.selectedResultIDs
            c.state.loadMoreResults(sessionID: session, after: before)
            XCTAssertTrue(c.state.isSelectingResults)
            XCTAssertEqual(c.state.results.count, after)
            XCTAssertEqual(c.state.selectedResultIDs, selected, "Appending must neither clear nor auto-select")
            c.state.toggleResultSelection(hits[after - 1].id)
            let expected = hits.prefix(after).map(\.id).filter { c.state.selectedResultIDs.contains($0) }
            XCTAssertEqual(c.state.orderedSelectedResultIDs, expected)
            c.state.selectVisibleResults()
            XCTAssertEqual(c.state.selectedResultIDs, Set(hits.prefix(after).map(\.id)))
            XCTAssertEqual(c.state.orderedSelectedResultIDs, hits.prefix(after).map(\.id))
            XCTAssertEqual(c.worker.counts, calls)
        }
        XCTAssertEqual(c.state.selectedResultIDs.count, 37)
        assertReadOnly(c)
    }

    func testQueryFiltersWeightPageSizeBackgroundAndLibraryInvalidateSelectionAndSimilarity() async throws {
        for change in SearchToolsChange.allCases {
            let c = await ready()
            await search(c)
            c.state.searchSimilar(to: try XCTUnwrap(c.state.results.first?.id))
            await c.state.waitUntilIdle()
            let old = try XCTUnwrap(c.state.resultSessionID)
            let source = try XCTUnwrap(c.state.results.first?.id)
            c.state.selection = AppState.Selection(id: source)
            c.state.setSelectingResults(true)
            c.state.toggleResultSelection(source)
            XCTAssertNotNil(c.state.similarPhotoID)
            XCTAssertFalse(c.state.selectedResultIDs.isEmpty)
            let calls = c.worker.counts
            change.apply(to: c.state)
            assertCleared(c.state)
            c.state.loadMoreResults(sessionID: old, after: 12)
            await c.state.waitUntilIdle()
            assertCleared(c.state)
            XCTAssertEqual(c.worker.textRequests.count, calls[1])
            XCTAssertEqual(c.worker.similarRequests.count, calls[2])
            XCTAssertEqual(c.worker.refreshCalls, calls[0] + (change == .library ? 1 : 0))
            if change == .background {
                c.state.enterForeground()
                await c.state.waitUntilIdle()
                assertCleared(c.state)
                XCTAssertEqual(c.worker.refreshCalls, calls[0] + 1)
            }
            assertReadOnly(c)
        }
    }

    func testHeldFilteredResultsAreRejectedAfterEverySearchSettingAndLifecycleChange() async throws {
        try await assertHeldChangeRejection(similar: false)
    }

    func testHeldSimilarityResultsAreRejectedAfterEverySearchSettingAndLifecycleChange() async throws {
        try await assertHeldChangeRejection(similar: true)
        try await assertHeldChangeRejection(similar: true, repeatSimilarity: true)
    }

    func testLateFilteredAndSimilarResponsesAreRejectedOnPermissionOrGenerationRevocation() async throws {
        for similar in [false, true] {
            for revokePermission in [false, true] {
                let c = await ready()
                let gate = try await beginHeldSearch(c, similar: similar)
                guard await entered(gate) else { return }
                let calls = c.worker.counts
                // No libraryChanged()/cancel(): test publication-time validation,
                // not merely rejection because the operation token changed.
                if revokePermission { c.permission.status = .denied }
                else { c.access.revoke() }
                gate.open()
                await c.state.waitUntilIdle()
                assertCleared(c.state)
                XCTAssertNotNil(c.state.errorMessage)
                XCTAssertEqual(c.worker.cancelledReturns, 0)
                XCTAssertEqual(c.worker.counts, calls)
                if revokePermission { XCTAssertFalse(c.state.canRead) }
                assertReadOnly(c)
            }
        }
    }

    func testCancelledHeldFilteredAndSimilarSuccessesNeverPublishAndExplicitRetryWorks() async throws {
        for similar in [false, true] {
            let c = await ready()
            let gate = try await beginHeldSearch(c, similar: similar)
            guard await entered(gate) else { return }
            c.state.cancel()
            assertCleared(c.state)
            gate.open()
            await c.state.waitUntilIdle()
            assertCleared(c.state)
            XCTAssertEqual(c.worker.cancelledReturns, 1, "The fake really returned success while cancelled")
            XCTAssertNil(c.state.errorMessage)
            XCTAssertFalse(c.state.isBusy)
            c.state.query = "TEST replacement after cancellation"
            await search(c)
            XCTAssertEqual(c.state.completedQuery, "TEST replacement after cancellation")
            XCTAssertNil(c.state.similarPhotoID)
            XCTAssertFalse(c.state.results.isEmpty)
            assertReadOnly(c)
        }
    }

    func testInvalidFilterDraftDuringHeldSearchDoesNotCancelOrReplaceCapturedRequest() async throws {
        let c = await ready()
        let gate = try await beginHeldSearch(c, similar: false)
        guard await entered(gate) else { return }
        let filters = c.state.searchFilters
        let request = c.worker.textRequests
        let hits = c.worker.lastHits
        for invalid in invalidFilters {
            c.state.applySearchFilters(invalid)
            XCTAssertEqual(c.state.searchFilters, filters)
            XCTAssertEqual(c.state.activity, .searching)
            XCTAssertEqual(c.worker.textRequests, request)
            XCTAssertNotNil(c.state.errorMessage)
        }
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.cancelledReturns, 0)
        XCTAssertEqual(c.worker.textRequests, request)
        assertHits(c.state.results, Array(hits.prefix(12)))
        XCTAssertEqual(c.state.completedQuery, SearchToolsFixtures.english)
        XCTAssertNotNil(c.state.resultSessionID)
        assertReadOnly(c)
    }

    // MARK: Deterministic entry signals and fully drained, test-owned holds

    private var invalidFilters: [PhotoSearchFilters] {
        [.init(startDate: SearchToolsFixtures.date(5), endDateExclusive: SearchToolsFixtures.date(4)),
         .init(startDate: SearchToolsFixtures.date(5), endDateExclusive: SearchToolsFixtures.date(5)),
         .init(startDate: Date(timeIntervalSinceReferenceDate: .infinity)),
         .init(endDateExclusive: Date(timeIntervalSinceReferenceDate: .nan)),
         .init(albumID: " \n")]
    }

    private func ready() async -> SearchToolsContext {
        let c = SearchToolsContext()
        addTeardownBlock { await c.releaseAndDrain() }
        c.state.refresh()
        await c.state.waitUntilIdle()
        c.state.query = SearchToolsFixtures.english
        XCTAssertEqual(c.worker.rows.count, 37)
        XCTAssertEqual(c.state.summary.indexedCount, 37)
        XCTAssertTrue(c.state.canSearch)
        XCTAssertNil(c.state.appleTranslationService)
        XCTAssertFalse(c.state.allowICloudDownload)
        return c
    }

    private func search(_ c: SearchToolsContext, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(c.state.canSearch, file: file, line: line)
        let count = c.worker.textRequests.count
        c.state.search()
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.isBusy, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
        XCTAssertEqual(c.worker.textRequests.count, count + 1, file: file, line: line)
        XCTAssertEqual(c.worker.legacyCalls, 0, "Use the filtered protocol witness even for empty filters", file: file, line: line)
    }

    private func hold(_ c: SearchToolsContext) -> SearchToolsGate {
        let gate = SearchToolsGate(started: expectation(description: "Injected service reached its held boundary"))
        c.gates.append(gate)
        return gate
    }

    private func entered(_ gate: SearchToolsGate, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(result, .completed, "Held operation never entered", file: file, line: line)
        if result != .completed { gate.open() }
        return result == .completed
    }

    private func beginHeldSearch(_ c: SearchToolsContext, similar: Bool,
                                 repeatSimilarity: Bool = false) async throws -> SearchToolsGate {
        c.state.searchFilters = .init(startDate: SearchToolsFixtures.date(0), albumID: "even")
        if similar { await search(c) }
        let source: String?
        if similar { source = try XCTUnwrap(c.state.results.first?.id) }
        else { source = nil }
        if repeatSimilarity, let source {
            c.state.searchSimilar(to: source)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.similarPhotoID, source)
            XCTAssertFalse(c.state.results.contains { $0.id == source })
        }
        let gate = hold(c)
        c.worker.nextGate = gate
        if repeatSimilarity { c.state.applySearchFilters(.init(albumID: "odd")) }
        else if let source { c.state.searchSimilar(to: source) }
        else { c.state.search() }
        XCTAssertEqual(c.state.activity, .searching)
        c.state.setSelectingResults(true)
        XCTAssertFalse(c.state.isSelectingResults, "No selection may start while results are being replaced")
        return gate
    }

    private func assertHeldChangeRejection(similar: Bool, repeatSimilarity: Bool = false) async throws {
        for change in SearchToolsChange.allCases {
            let c = await ready()
            let gate = try await beginHeldSearch(c, similar: similar, repeatSimilarity: repeatSimilarity)
            guard await entered(gate) else { return }
            let calls = c.worker.counts
            if change == .filters {
                // The dialog action while busy invalidates; it must not schedule
                // an automatic rerun of a query that has not completed yet.
                c.state.applySearchFilters(.init(albumID: "odd", imageKind: .livePhotos))
            } else { change.apply(to: c.state) }
            assertCleared(c.state)
            if change == .library {
                XCTAssertEqual(c.worker.refreshCalls, calls[0], "Refresh must drain the held predecessor first")
            }
            gate.open()
            await c.state.waitUntilIdle()
            assertCleared(c.state)
            XCTAssertFalse(c.state.isBusy)
            XCTAssertNil(c.state.errorMessage)
            XCTAssertEqual(c.worker.cancelledReturns, 1)
            XCTAssertEqual(c.worker.textRequests.count, calls[1])
            XCTAssertEqual(c.worker.similarRequests.count, calls[2])
            XCTAssertEqual(c.worker.refreshCalls, calls[0] + (change == .library ? 1 : 0))
            assertReadOnly(c)
        }
    }

    private func assertCleared(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.resultSessionID, file: file, line: line)
        XCTAssertEqual(state.totalResultCount, 0, file: file, line: line)
        XCTAssertFalse(state.hasMoreResults, file: file, line: line)
        XCTAssertNil(state.similarPhotoID, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
        XCTAssertFalse(state.isSelectingResults, file: file, line: line)
        XCTAssertTrue(state.selectedResultIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(state.orderedSelectedResultIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
    }

    private func assertHits(_ actual: [SearchHit], _ expected: [SearchHit],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern }, file: file, line: line)
        XCTAssertEqual(actual.map { $0.photo.imageEmbedding }, expected.map { $0.photo.imageEmbedding }, file: file, line: line)
        XCTAssertEqual(actual.map { $0.photo.modelVersion }, expected.map { $0.photo.modelVersion }, file: file, line: line)
    }

    private func assertReadOnly(_ c: SearchToolsContext, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.worker.mutationCalls, 0, file: file, line: line)
        XCTAssertEqual(c.worker.diagnosticCalls, 0, file: file, line: line)
        XCTAssertEqual(c.translator.prepareCalls, 0, file: file, line: line)
        XCTAssertFalse(c.state.allowICloudDownload, file: file, line: line)
    }
}

private struct SearchToolsTextRequest: Equatable {
    let text: String
    let limit: Int
    let weight: Float
    let filters: PhotoSearchFilters
}

private struct SearchToolsSimilarRequest: Equatable {
    let id: String
    let limit: Int
    let filters: PhotoSearchFilters
}

private struct SearchToolsRow: Sendable {
    let photo: IndexedPhoto
    let album: String
    let screenshot: Bool
    let live: Bool

    func matches(_ filters: PhotoSearchFilters) -> Bool {
        (filters.albumID == nil || filters.albumID == album)
            && filters.matches(creationDate: photo.creationTime.map { Date(timeIntervalSince1970: $0) },
                               isScreenshot: screenshot, isLivePhoto: live)
    }
}

private enum SearchToolsFixtures {
    static let english = "TEST a white pen beside a dog"
    static let chinese = " 白色的笔和小狗 "
    static let model = "search-tools-synthetic-cache"
    static func date(_ day: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(day) * 86_400) }
    static var queryVector: [Float] {
        var result = [Float](repeating: 0, count: 768)
        result[0] = 1
        return result
    }

    static var rows: [SearchToolsRow] {
        (0..<37).reversed().map { index in
            let angle = Double(index) * .pi / 37
            var vector = [Float](repeating: 0, count: 768)
            vector[0] = Float(cos(angle))
            vector[1] = Float(sin(angle))
            let photo = IndexedPhoto(id: String(format: "tools-%03d", 36 - index), modificationTime: Double(index),
                                     modelVersion: model, imageEmbedding: vector,
                                     creationTime: date(index).timeIntervalSince1970)
            return SearchToolsRow(photo: photo, album: index.isMultiple(of: 2) ? "even" : "odd",
                                  screenshot: index.isMultiple(of: 3), live: index.isMultiple(of: 5))
        }
    }

    static var summary: LibrarySummary {
        LibrarySummary(authorizedCount: 37, authorizedCountKnown: true, indexStatisticsKnown: true,
                       indexedCount: 37, modelVersion: model, placesDescription: "TEST no places")
    }
}

@MainActor
private enum SearchToolsChange: CaseIterable, Equatable {
    case query, filters, weight, pageSize, background, library

    func apply(to state: AppState) {
        switch self {
        case .query: state.query = "TEST edited query"
        case .filters: state.searchFilters = .init(imageKind: .screenshots)
        case .weight: state.locationWeight = 0.19
        case .pageSize: state.resultLimit = 3
        case .background: state.enterBackground()
        case .library: state.libraryChanged()
        }
    }
}

@MainActor
private final class SearchToolsGate {
    let started: XCTestExpectation
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
            started.fulfill()
        }
    }

    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

/// Synchronous Sendable response callbacks must not capture MainActor state.
/// The only mutable value is protected by this lock in every access.
private final class SearchToolsAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    func revoke() {
        lock.lock()
        defer { lock.unlock() }
        revoked = true
    }

    func validate() throws {
        lock.lock()
        defer { lock.unlock() }
        if revoked { throw AppFailure.permission }
    }
}

@MainActor
private final class SearchToolsPermission {
    var status: PHAuthorizationStatus = .limited
}

@MainActor
private final class SearchToolsTranslator: QueryTranslating {
    let isSupported = true
    var nextGate: SearchToolsGate?
    private(set) var availabilityCalls = 0
    private(set) var texts: [String] = []
    private(set) var prepareCalls = 0
    var counts: [Int] { [availabilityCalls, texts.count, prepareCalls] }

    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityCalls += 1
        return .installed
    }

    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        texts.append(text)
        let gate = nextGate
        nextGate = nil
        await gate?.wait()
        return SearchToolsFixtures.english
    }

    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareCalls += 1
        XCTFail("Search tools must not prepare/download language packs")
    }
}

/// Async witnesses plus MainActor isolation satisfy PhotoWorkServicing: Sendable;
/// no unchecked actor sharing and no inherited/default filtered-search witness.
@MainActor
private final class SearchToolsWorker: PhotoWorkServicing {
    var rows = SearchToolsFixtures.rows
    var nextGate: SearchToolsGate?
    private let access: SearchToolsAccess
    private(set) var textRequests: [SearchToolsTextRequest] = []
    private(set) var similarRequests: [SearchToolsSimilarRequest] = []
    private(set) var seedVectors: [[Float]] = []
    private(set) var lastHits: [SearchHit] = []
    private(set) var refreshCalls = 0
    private(set) var legacyCalls = 0
    private(set) var mutationCalls = 0
    private(set) var diagnosticCalls = 0
    private(set) var cancelledReturns = 0
    var counts: [Int] { [refreshCalls, textRequests.count, similarRequests.count, legacyCalls, mutationCalls, diagnosticCalls] }

    init(access: SearchToolsAccess) { self.access = access }

    func refresh() async throws -> LibrarySummary {
        refreshCalls += 1
        return SearchToolsFixtures.summary
    }

    func expectedHits(filters: PhotoSearchFilters = .init(), seed: String? = nil,
                      weight: Float = 0.6) throws -> [SearchHit] {
        let vector: [Float]
        if let seed {
            guard let row = rows.first(where: { $0.photo.id == seed }) else {
                throw AppFailure.photo("TEST missing cached seed")
            }
            vector = row.photo.imageEmbedding
        } else { vector = SearchToolsFixtures.queryVector }
        // Like production: rank once against the complete cached snapshot, then
        // filter output. No page-local ranking or fixture-order result shortcut.
        let ranked = try VectorSearch.search(query: vector, photos: rows.map(\.photo), limit: Int.max,
                                              locationWeight: seed == nil ? weight : 0)
        let ids = Set(rows.filter { $0.matches(filters) }.map { $0.photo.id })
        return ranked.filter { $0.id != seed && ids.contains($0.id) }
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        legacyCalls += 1
        XCTFail("AppState must dispatch to this worker's filtered protocol requirement")
        return try await response(hits: expectedHits(weight: locationWeight))
    }

    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse {
        textRequests.append(SearchToolsTextRequest(text: text, limit: limit, weight: locationWeight, filters: filters))
        try filters.validate()
        let hits = Array(try expectedHits(filters: filters, weight: locationWeight).prefix(max(0, limit)))
        return await response(hits: hits)
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        similarRequests.append(SearchToolsSimilarRequest(id: photoID, limit: limit, filters: filters))
        try filters.validate()
        guard let source = rows.first(where: { $0.photo.id == photoID }) else {
            throw AppFailure.photo("TEST missing cached seed")
        }
        seedVectors.append(source.photo.imageEmbedding)
        let hits = Array(try expectedHits(filters: filters, seed: photoID).prefix(max(0, limit)))
        return await response(hits: hits)
    }

    private func response(hits: [SearchHit]) async -> SearchResponse {
        lastHits = hits
        let access = self.access
        let captured = SearchResponse(summary: SearchToolsFixtures.summary, hits: hits,
                                      validateAccess: { try access.validate() },
                                      validatePageAccess: { _ in try access.validate() })
        let gate = nextGate
        nextGate = nil
        await gate?.wait()
        if Task.isCancelled { cancelledReturns += 1 }
        return captured // Deliberately noncooperative: AppState must reject stale success.
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        mutationCalls += 1
        XCTFail("Search tools must never auto-index or download Photos")
        return SearchToolsFixtures.summary
    }

    func clear() async throws -> LibrarySummary {
        mutationCalls += 1
        XCTFail("Search tools must never clear the saved index")
        return SearchToolsFixtures.summary
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        diagnosticCalls += 1
        XCTFail("Similarity must use a cached vector, not a fresh diagnostic/image read")
        throw AppFailure.photo("TEST unexpected diagnostic")
    }
}

/// Separate conformance is intentional: inheriting from the new worker would
/// inherit its filtered witness and fail to exercise existing legacy-only mocks.
@MainActor
private final class SearchToolsLegacyWorker: PhotoWorkServicing {
    let hits = SearchToolsFixtures.rows.enumerated().map {
        SearchHit(photo: $0.element.photo, score: Float(37 - $0.offset) / 37)
    }
    private(set) var requests: [SearchToolsTextRequest] = []
    private(set) var mutations = 0

    func refresh() async throws -> LibrarySummary { SearchToolsFixtures.summary }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        requests.append(SearchToolsTextRequest(text: text, limit: limit, weight: locationWeight, filters: .init()))
        return SearchResponse(summary: SearchToolsFixtures.summary, hits: hits)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        mutations += 1
        XCTFail("Legacy search compatibility must not index")
        return SearchToolsFixtures.summary
    }

    func clear() async throws -> LibrarySummary {
        mutations += 1
        XCTFail("Legacy search compatibility must not clear")
        return SearchToolsFixtures.summary
    }
}

@MainActor
private final class SearchToolsContext {
    let access: SearchToolsAccess
    let permission: SearchToolsPermission
    let translator: SearchToolsTranslator
    let worker: SearchToolsWorker
    let state: AppState
    var gates: [SearchToolsGate] = []

    init() {
        let access = SearchToolsAccess()
        let permission = SearchToolsPermission()
        let translator = SearchToolsTranslator()
        let worker = SearchToolsWorker(access: access)
        self.access = access
        self.permission = permission
        self.translator = translator
        self.worker = worker
        state = AppState(worker: worker, authorizationStatus: { permission.status }, queryTranslator: translator)
    }

    func releaseAndDrain() async {
        state.cancel()
        for gate in gates { gate.open() }
        await state.waitUntilIdle()
        XCTAssertEqual(worker.mutationCalls, 0)
        XCTAssertEqual(worker.diagnosticCalls, 0)
        XCTAssertEqual(translator.prepareCalls, 0)
    }
}