import Foundation
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// AppState wiring only: 13 tiny synthetic hits, no scoring benchmark, models,
/// database, pixels or network. The normal PhotoLibraryClient wrapper is retained
/// to observe its cache generation; no permission request or library enumeration.
/// Actor gates deliberately allow cancelled work to return late. No sleeps,
/// polling, private state injection or exact predictions of AppState's clock.
@MainActor
final class SearchAccelerationStateTests: XCTestCase {
    func testDefaultAcceleratedSearchForwardsOriginalEffectiveQueryAndRecorder() async throws {
        let c = await ready(savedTextEnabled: true)
        XCTAssertFalse(c.state.debugToolsEnabled)
        XCTAssertFalse(c.state.referenceSearchEnabled)
        XCTAssertNil(c.state.searchTimingReport)
        c.state.query = AccelerationFixture.original
        c.state.locationWeight = 0.37
        c.state.search()
        await c.state.waitUntilIdle()

        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.count, 1)
        XCTAssertEqual(observed.legacyCalls, 0)
        let request = try XCTUnwrap(observed.requests.first)
        XCTAssertEqual(request.text, AccelerationFixture.effective)
        XCTAssertEqual(request.original, AccelerationFixture.original)
        XCTAssertEqual(request.limit, Int.max)
        XCTAssertEqual(request.weight, 0.37)
        XCTAssertEqual(request.filters, PhotoSearchFilters())
        XCTAssertTrue(request.includeText)
        XCTAssertFalse(request.reference)
        XCTAssertNil(request.seed)
        let recorder = try XCTUnwrap(request.timing)
        let report = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertEqual(report.id, recorder.id)
        XCTAssertEqual(report.mode, "加速")
        XCTAssertEqual(report.cacheSource, "内存驻留")
        XCTAssertEqual(report.candidateCount, 13, "Candidates are not the 12 displayed hits or timing-row count.")
        XCTAssertTrue(report.matrixReused)
        XCTAssertTrue(report.snapshotReused)
        XCTAssertEqual(report.outcome, .ready)
        XCTAssertEqual(report.stages.first?.stage, .queue)
        XCTAssertTrue(report.stages.contains { $0.stage == .translation })
        XCTAssertEqual(report.stages.last?.stage, .publication)
        XCTAssertGreaterThan(report.totalSeconds, 0)
        XCTAssertNil(report.firstImageSeconds)
        XCTAssertEqual(c.state.results.count, 12)
        XCTAssertEqual(c.state.totalResultCount, 13)
        XCTAssertEqual(c.state.completedSearchQuery?.effective, AccelerationFixture.effective)
        XCTAssertEqual(c.translator.translations, [AccelerationFixture.original])
        assertPartition(report)
        assertNoQueryOrPhotoData(report)
    }

    func testReferenceSwitchClearsOldResultsWithoutAutoSearchAndBothModesWork() async throws {
        let c = await ready()
        await search(c)
        let accelerated = try XCTUnwrap(c.state.searchTimingReport)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let visible = try XCTUnwrap(c.state.results.first?.id)
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        c.state.selection = AppState.Selection(id: visible)

        c.state.referenceSearchEnabled = true
        assertCleared(c.state)
        await c.state.waitUntilIdle()
        let beforeExplicitSearch = await c.worker.observations()
        XCTAssertEqual(beforeExplicitSearch.requests.count, 1)
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: accelerated)
        c.state.resultThumbnailLoaded(sessionID: session, photoID: visible)
        XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)

        await search(c)
        let reference = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertNotEqual(reference.id, accelerated.id)
        XCTAssertNotEqual(c.state.resultSessionID, session)
        XCTAssertEqual(reference.mode, "参考基线")
        XCTAssertEqual(reference.cacheSource, "参考基线")
        XCTAssertFalse(reference.matrixReused)
        XCTAssertEqual(reference.outcome, .ready)
        c.state.referenceSearchEnabled = false
        assertCleared(c.state)
        await search(c)
        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.map(\.reference), [false, true, false])
        XCTAssertEqual(observed.legacyCalls, 0)
        XCTAssertEqual(c.state.searchTimingReport?.mode, "加速")
        XCTAssertEqual(c.state.results.map(\.id), AccelerationFixture.hits.prefix(12).map(\.id))
    }

    func testFilterRerunReusesResolvedOrExplicitOriginalQueryWithoutTranslationStage() async throws {
        for useOriginal in [false, true] {
            let c = await ready()
            c.state.query = AccelerationFixture.original
            c.state.search(useOriginal: useOriginal)
            await c.state.waitUntilIdle()
            let first = try XCTUnwrap(c.state.searchTimingReport)
            let resolution = try XCTUnwrap(c.state.completedSearchQuery)
            let translations = c.translator.translations
            let availabilityCalls = c.translator.availabilityCalls
            let filters = PhotoSearchFilters(imageKind: .screenshots)
            c.state.applySearchFilters(filters)
            XCTAssertNil(c.state.searchTimingReport)
            await c.state.waitUntilIdle()

            let observed = await c.worker.observations()
            XCTAssertEqual(observed.requests.count, 2)
            let rerun = try XCTUnwrap(observed.requests.last)
            XCTAssertEqual(rerun.text, resolution.effective)
            XCTAssertEqual(rerun.original, resolution.original)
            XCTAssertEqual(rerun.filters, filters)
            XCTAssertEqual(rerun.limit, Int.max)
            XCTAssertFalse(rerun.reference)
            XCTAssertEqual(c.state.completedSearchQuery, resolution)
            XCTAssertEqual(c.translator.translations, translations)
            XCTAssertEqual(c.translator.availabilityCalls, availabilityCalls)
            let report = try XCTUnwrap(c.state.searchTimingReport)
            XCTAssertNotEqual(report.id, first.id)
            XCTAssertEqual(report.id, rerun.timing?.id)
            XCTAssertEqual(report.outcome, .ready)
            XCTAssertFalse(report.stages.contains { $0.stage == .translation }, "Do not invent a translation interval for a reused resolution.")
            XCTAssertEqual(report.stages.first?.stage, .queue)
            XCTAssertEqual(report.stages.last?.stage, .publication)
            assertPartition(report)
        }
    }

    func testSimilarityAndItsFilterRerunForwardReferenceAndNewTimingWithoutTranslation() async throws {
        let c = await ready()
        c.state.referenceSearchEnabled = true
        await search(c)
        let seed = try XCTUnwrap(c.state.results.first?.id)
        let textReport = try XCTUnwrap(c.state.searchTimingReport)
        let translations = c.translator.translations
        c.state.searchSimilar(to: seed)
        await c.state.waitUntilIdle()
        let similar = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertNotEqual(similar.id, textReport.id)
        XCTAssertEqual(c.state.similarPhotoID, seed)
        XCTAssertFalse(c.state.results.contains { $0.id == seed })
        let filters = PhotoSearchFilters(imageKind: .photos)
        c.state.applySearchFilters(filters)
        await c.state.waitUntilIdle()

        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.count, 3)
        let requests = Array(observed.requests.dropFirst())
        XCTAssertEqual(requests.map(\.seed), [seed, seed])
        XCTAssertEqual(requests.map(\.reference), [true, true])
        XCTAssertEqual(requests.map(\.limit), [Int.max, Int.max])
        XCTAssertEqual(requests.map(\.filters), [PhotoSearchFilters(), filters])
        XCTAssertTrue(requests.allSatisfy { $0.timing != nil && $0.text == nil && $0.original == nil })
        let rerun = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertNotEqual(rerun.id, similar.id)
        XCTAssertEqual(rerun.id, requests.last?.timing?.id)
        for report in [similar, rerun] {
            XCTAssertEqual(report.outcome, .ready)
            XCTAssertEqual(report.mode, "参考基线")
            XCTAssertFalse(report.stages.contains { $0.stage == .translation })
            assertPartition(report)
        }
        XCTAssertEqual(c.translator.translations, translations)
        XCTAssertEqual(c.state.similarPhotoID, seed)
    }

    func testFirstVisibleThumbnailEnrichesReadyReportExactlyOnceWithoutChangingRanking() async throws {
        let c = await ready()
        await search(c)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let report = try XCTUnwrap(c.state.searchTimingReport)
        let visible = try XCTUnwrap(c.state.results.first?.id)
        let hidden = try XCTUnwrap(AccelerationFixture.hits.last?.id)
        c.state.resultThumbnailLoaded(sessionID: UUID(), photoID: visible)
        c.state.resultThumbnailLoaded(sessionID: session, photoID: "unknown-synthetic-id")
        c.state.resultThumbnailLoaded(sessionID: session, photoID: hidden)
        XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)

        c.state.resultThumbnailLoaded(sessionID: session, photoID: visible)
        let enriched = try XCTUnwrap(c.state.searchTimingReport)
        let firstImage = try XCTUnwrap(enriched.firstImageSeconds)
        XCTAssertGreaterThan(firstImage, 0)
        XCTAssertGreaterThanOrEqual(firstImage, report.totalSeconds)
        XCTAssertNil(report.firstImageSeconds, "The original value is an immutable ranking snapshot.")
        assertRanking(enriched, equals: report)
        c.state.resultThumbnailLoaded(sessionID: session, photoID: visible)
        c.state.resultThumbnailLoaded(sessionID: session, photoID: c.state.results[1].id)
        XCTAssertEqual(c.state.searchTimingReport?.firstImageSeconds, firstImage)
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: report)
        XCTAssertEqual(c.state.resultSessionID, session)
        XCTAssertEqual(enriched.outcome, .ready)
        // This callback has no quality/HDR input. A usable Fast fallback counts;
        // nothing here proves HQ, HDR, original pixels or completed screen drawing.
        XCTAssertTrue(SearchTimingContent.imageNote.contains("不代表高清图已返回"))
        assertNoQueryOrPhotoData(enriched)
    }

    func testReplacedSessionAndPermissionInvalidationRejectLateThumbnailCallbacks() async throws {
        let c = await ready()
        await search(c)
        let oldSession = try XCTUnwrap(c.state.resultSessionID)
        let id = try XCTUnwrap(c.state.results.first?.id)
        await search(c) // Same visible IDs, different session and recorder.
        let session = try XCTUnwrap(c.state.resultSessionID)
        let report = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertNotEqual(session, oldSession)
        c.state.resultThumbnailLoaded(sessionID: oldSession, photoID: id)
        XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)

        c.permission.status = .denied
        c.state.libraryChanged()
        assertCleared(c.state)
        c.state.resultThumbnailLoaded(sessionID: session, photoID: id)
        await c.state.waitUntilIdle()
        c.state.resultThumbnailLoaded(sessionID: session, photoID: id)
        XCTAssertFalse(c.state.canRead)
        XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: report)
        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.count, 2, "Invalidation/thumbnail callbacks must not search again.")
    }

    func testWorkerFailurePublicationDenialAndCancellationHaveTypedNonreadyReports() async throws {
        for stop in AccelerationStop.allCases {
            let c = await ready()
            let gate = AccelerationGate()
            await c.worker.holdSearch(gate, stop: stop)
            c.state.search()
            await fulfillment(of: [gate.entered], timeout: 3)
            XCTAssertNil(c.state.searchTimingReport)
            if stop == .permission { c.permission.status = .denied }
            if stop == .cancel { c.state.cancel() }
            await gate.open()
            await c.state.waitUntilIdle()

            let report = try XCTUnwrap(c.state.searchTimingReport)
            XCTAssertEqual(report.outcome, stop == .cancel ? .cancelled : .failed)
            XCTAssertNotEqual(report.outcome, .ready)
            XCTAssertNil(report.firstImageSeconds)
            assertCleared(c.state)
            c.state.resultThumbnailLoaded(sessionID: UUID(), photoID: AccelerationFixture.hits[0].id)
            XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)
            assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: report)
            let observed = await c.worker.observations()
            let recorder = try XCTUnwrap(observed.requests.first?.timing)
            XCTAssertNil(recorder.firstImage())
            assertRanking(recorder.finish(.ready), equals: report)
            XCTAssertEqual(observed.cancelledOnReturn, [stop == .cancel])
            assertPartition(report)
        }
    }

    func testQueryEditFreezesCancelledReportBeforeLateWorkerAndCannotOverwriteNextSearch() async throws {
        let c = await ready()
        let gate = AccelerationGate()
        await c.worker.holdSearch(gate)
        c.state.search()
        await fulfillment(of: [gate.entered], timeout: 3)
        let held = await c.worker.observations()
        let recorder = try XCTUnwrap(held.requests.first?.timing)
        c.state.query = "a different synthetic query"
        let frozen = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertEqual(frozen.id, recorder.id)
        XCTAssertEqual(frozen.outcome, .cancelled)
        XCTAssertFalse(frozen.stages.contains { $0.stage == .scoring })
        XCTAssertEqual(c.state.activity, .searching, "Report freezes before the worker has drained.")
        assertCleared(c.state)
        c.state.refresh() // Replace operation token while the old worker is held.
        await gate.open()
        await c.state.waitUntilIdle()
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: frozen)
        assertRanking(recorder.finish(.ready), equals: frozen)
        XCTAssertNil(recorder.firstImage())
        await search(c)
        let current = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertNotEqual(current.id, frozen.id)
        XCTAssertEqual(current.outcome, .ready)
        recorder.mark(.publication)
        _ = recorder.finish(.failed)
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: current)
        XCTAssertEqual(c.state.completedQuery, "a different synthetic query")
        let observed = await c.worker.observations()
        XCTAssertEqual(observed.cancelledOnReturn, [true, false])
        XCTAssertEqual(observed.requests.count, 2)
    }

    func testBackgroundInvalidatesPhotoKitCacheAndDrainsBeforeReleaseAndForegroundWork() async throws {
        let c = await ready()
        let searchGate = AccelerationGate()
        let releaseGate = AccelerationGate()
        await c.worker.holdSearch(searchGate)
        await c.worker.holdRelease(releaseGate)
        c.state.search()
        await fulfillment(of: [searchGate.entered], timeout: 3)
        let before = try XCTUnwrap(c.state.library.changeGeneration)
        c.state.enterBackground()
        let background = try XCTUnwrap(c.state.library.changeGeneration)
        XCTAssertNotEqual(background, before, "Check the PhotoKit query-cache epoch, not photoLibraryEpoch.")
        let cancelled = try XCTUnwrap(c.state.searchTimingReport)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        assertCleared(c.state)
        var observed = await c.worker.observations()
        XCTAssertEqual(observed.events, ["refresh", "search-enter"])
        c.state.enterForeground()
        XCTAssertNotEqual(c.state.library.changeGeneration, background)
        XCTAssertEqual(c.state.activity, .refreshing)
        observed = await c.worker.observations()
        XCTAssertEqual(observed.events, ["refresh", "search-enter"])

        await searchGate.open()
        await fulfillment(of: [releaseGate.entered], timeout: 3)
        observed = await c.worker.observations()
        XCTAssertEqual(observed.cancelledOnReturn, [true])
        XCTAssertEqual(observed.events, ["refresh", "search-enter", "search-return", "release-enter"])
        XCTAssertEqual(c.state.activity, .refreshing, "Foreground refresh is still waiting on cleanup.")
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: cancelled)
        await releaseGate.open()
        await c.state.waitUntilIdle()
        observed = await c.worker.observations()
        XCTAssertEqual(observed.events, ["refresh", "search-enter", "search-return", "release-enter", "release-return", "refresh"])
        XCTAssertNil(c.state.activity)
        XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)
        await search(c)
        XCTAssertEqual(c.state.searchTimingReport?.outcome, .ready)
        XCTAssertNotEqual(c.state.searchTimingReport?.id, cancelled.id)
    }

    func testForegroundLibraryChangeDrainsAndReleasesOldScopeBeforeRefreshWithoutAnotherQuery() async throws {
        for hasInFlightSearch in [false, true] {
            let c = await ready()
            await search(c) // Leave a resident scope even when the query is then cleared.
            let oldSession = try XCTUnwrap(c.state.resultSessionID)
            let photoID = try XCTUnwrap(c.state.results.first?.id)
            let searchGate = AccelerationGate()
            let releaseGate = AccelerationGate()
            await c.worker.holdRelease(releaseGate)
            if hasInFlightSearch {
                await c.worker.holdSearch(searchGate)
                c.state.search()
                await fulfillment(of: [searchGate.entered], timeout: 3)
            } else {
                c.state.query = ""
                XCTAssertNil(c.state.activity)
            }
            let before = await c.worker.observations()
            XCTAssertTrue(before.hasResidentSearchScope)
            let epoch = c.state.photoLibraryEpoch

            // Stay foreground throughout: neither a new query nor a subsequent
            // foreground transition may be needed to evict withdrawn-scope data.
            c.state.libraryChanged()
            XCTAssertNotEqual(c.state.photoLibraryEpoch, epoch)
            XCTAssertEqual(c.state.activity, .refreshing)
            assertCleared(c.state)
            let frozen = try XCTUnwrap(c.state.searchTimingReport)
            XCTAssertEqual(frozen.outcome, hasInFlightSearch ? .cancelled : .ready)
            if hasInFlightSearch {
                let held = await c.worker.observations()
                XCTAssertEqual(held.events, before.events, "Cleanup must wait for the cancelled search to return.")
                await searchGate.open()
            }
            await fulfillment(of: [releaseGate.entered], timeout: 3)
            let releasing = await c.worker.observations()
            let drainedEvents = before.events + (hasInFlightSearch ? ["search-return"] : [])
            XCTAssertEqual(releasing.events, drainedEvents + ["release-enter"])
            XCTAssertEqual(releasing.cancelledOnReturn, hasInFlightSearch ? [false, true] : [false])
            XCTAssertTrue(releasing.hasResidentSearchScope, "The fake retains its old scope until release completes.")
            XCTAssertEqual(releasing.refreshSawResidentScope, [false], "No refresh may bypass cleanup.")
            XCTAssertEqual(c.state.activity, .refreshing)

            await releaseGate.open()
            await c.state.waitUntilIdle()
            let finished = await c.worker.observations()
            XCTAssertEqual(finished.events, drainedEvents + ["release-enter", "release-return", "refresh"])
            XCTAssertEqual(finished.refreshSawResidentScope, [false, false])
            XCTAssertFalse(finished.hasResidentSearchScope)
            XCTAssertEqual(finished.requests.count, before.requests.count, "Library changes refresh counts, not queries.")
            XCTAssertEqual(c.state.summary.indexedCount, AccelerationFixture.summary.indexedCount)
            XCTAssertTrue(c.state.modelsReady)
            XCTAssertTrue(c.state.canIndex, "The app remained foreground and ready after cleanup.")
            XCTAssertNil(c.state.activity)
            if !hasInFlightSearch { XCTAssertEqual(c.state.query, "") }
            assertCleared(c.state)
            c.state.resultThumbnailLoaded(sessionID: oldSession, photoID: photoID)
            XCTAssertNil(c.state.searchTimingReport?.firstImageSeconds)
            assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: frozen)
        }
    }

    func testHidingDebugToolsResetsReferenceOnlyAndDoesNotAutomaticallySearch() async throws {
        let c = await ready(savedTextEnabled: true)
        c.state.debugToolsEnabled = true
        c.state.referenceSearchEnabled = true
        c.state.query = AccelerationFixture.original
        c.state.locationWeight = 0.23
        c.state.resultLimit = 3
        c.state.searchFilters = PhotoSearchFilters(imageKind: .photos)
        c.state.allowICloudDownload = true
        await search(c)
        let report = try XCTUnwrap(c.state.searchTimingReport)
        c.state.debugToolsEnabled = false
        assertCleared(c.state)
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.referenceSearchEnabled)
        XCTAssertEqual(c.state.query, AccelerationFixture.original)
        XCTAssertEqual(c.state.locationWeight, 0.23)
        XCTAssertEqual(c.state.resultLimit, 3)
        XCTAssertTrue(c.state.textSearchEnabled)
        XCTAssertTrue(c.state.chineseSearchEnabled)
        XCTAssertTrue(c.state.allowICloudDownload)
        XCTAssertEqual(c.state.searchFilters, PhotoSearchFilters(imageKind: .photos))
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: report)
        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.count, 1)
        XCTAssertFalse(observed.events.contains("release-enter"))
        XCTAssertNil(c.state.activity)
    }

    func testHidingDebugToolsWithReferenceAlreadyFalsePreservesOriginalSearchAndResults() async throws {
        let c = await ready()
        c.state.debugToolsEnabled = true
        c.state.query = AccelerationFixture.original
        let gate = AccelerationGate()
        await c.worker.holdSearch(gate)
        c.state.search(useOriginal: true)
        await fulfillment(of: [gate.entered], timeout: 3)
        c.state.debugToolsEnabled = false
        XCTAssertFalse(c.state.referenceSearchEnabled)
        XCTAssertEqual(c.state.activity, .searching)
        XCTAssertNil(c.state.searchTimingReport, "Hiding diagnostics must not finish a normal search.")
        await gate.open()
        await c.state.waitUntilIdle()
        let session = try XCTUnwrap(c.state.resultSessionID)
        let report = try XCTUnwrap(c.state.searchTimingReport)
        let resolution = try XCTUnwrap(c.state.completedSearchQuery)
        c.state.debugToolsEnabled = true
        c.state.debugToolsEnabled = false
        c.state.debugToolsEnabled = false
        XCTAssertEqual(c.state.resultSessionID, session)
        XCTAssertEqual(c.state.results.count, 12)
        XCTAssertEqual(c.state.completedSearchQuery, resolution)
        XCTAssertEqual(resolution.effective, AccelerationFixture.original)
        XCTAssertFalse(resolution.translated)
        XCTAssertTrue(c.translator.translations.isEmpty)
        assertRanking(try XCTUnwrap(c.state.searchTimingReport), equals: report)
        let observed = await c.worker.observations()
        XCTAssertEqual(observed.requests.count, 1)
        XCTAssertEqual(observed.cancelledOnReturn, [false])
        XCTAssertEqual(report.outcome, .ready)
    }

    func testLegacyMocksKeepWorkingThroughDefaultTimingAndMemoryReleaseRequirements() async throws {
        let worker = AccelerationLegacyWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             queryTranslator: AccelerationTranslator())
        addTeardownBlock { await state.waitUntilIdle() }
        state.refresh()
        await state.waitUntilIdle()
        state.query = "synthetic legacy query"
        state.referenceSearchEnabled = true
        state.search()
        await state.waitUntilIdle()
        let textReport = try XCTUnwrap(state.searchTimingReport)
        XCTAssertEqual(textReport.outcome, .ready)
        XCTAssertEqual(textReport.mode, "参考基线")
        let seed = try XCTUnwrap(state.results.first?.id)
        state.searchSimilar(to: seed)
        await state.waitUntilIdle()
        XCTAssertEqual(state.similarPhotoID, seed)
        XCTAssertEqual(state.searchTimingReport?.outcome, .ready)
        XCTAssertNotEqual(state.searchTimingReport?.id, textReport.id)
        state.enterBackground()
        state.enterForeground()
        await state.waitUntilIdle() // Uses the protocol's no-op release default.
        let calls = await worker.calls
        XCTAssertEqual(calls, ["refresh", "synthetic legacy query", "similar", "refresh"])
        XCTAssertTrue(state.modelsReady)
        XCTAssertNil(state.activity)
    }

    private func ready(savedTextEnabled: Bool = false) async -> AccelerationContext {
        let worker = AccelerationWorker()
        let translator = AccelerationTranslator()
        let permission = AccelerationPermission()
        let suite = "SearchAccelerationStateTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(savedTextEnabled, forKey: "photoTextSearchEnabled.v1")
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(worker: worker, authorizationStatus: { permission.status }, queryTranslator: translator,
                     textSearchPreferences: preferences)
        addTeardownBlock {
            await worker.openAllGates()
            await state.waitUntilIdle()
        }
        state.refresh()
        await state.waitUntilIdle()
        state.query = "synthetic landscape query"
        XCTAssertTrue(state.canSearch)
        return AccelerationContext(state: state, worker: worker, translator: translator, permission: permission)
    }

    private func search(_ c: AccelerationContext) async {
        c.state.search()
        await c.state.waitUntilIdle()
    }

    private func assertCleared(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.resultSessionID, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
        XCTAssertFalse(state.isSelectingResults, file: file, line: line)
        XCTAssertTrue(state.selectedResultIDs.isEmpty, file: file, line: line)
    }

    private func assertPartition(_ report: SearchTimingReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(report.totalSeconds.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.totalSeconds, 0, file: file, line: line)
        XCTAssertTrue(report.stages.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }, file: file, line: line)
        XCTAssertEqual(report.stages.reduce(0) { $0 + $1.seconds }, report.totalSeconds, file: file, line: line)
    }

    private func assertRanking(_ actual: SearchTimingReport, equals expected: SearchTimingReport,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.outcome, expected.outcome, file: file, line: line)
        XCTAssertEqual(actual.totalSeconds, expected.totalSeconds, file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.id), expected.stages.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.stage), expected.stages.map(\.stage), file: file, line: line)
        XCTAssertEqual(actual.stages.map(\.seconds), expected.stages.map(\.seconds), file: file, line: line)
        XCTAssertEqual(actual.mode, expected.mode, file: file, line: line)
        XCTAssertEqual(actual.cacheSource, expected.cacheSource, file: file, line: line)
        XCTAssertEqual(actual.candidateCount, expected.candidateCount, file: file, line: line)
        XCTAssertEqual(actual.matrixReused, expected.matrixReused, file: file, line: line)
        XCTAssertEqual(actual.snapshotReused, expected.snapshotReused, file: file, line: line)
    }

    private func assertNoQueryOrPhotoData(_ report: SearchTimingReport, file: StaticString = #filePath, line: UInt = #line) {
        let representation = String(reflecting: report)
        let sentinels = [AccelerationFixture.original.trimmingCharacters(in: .whitespacesAndNewlines), AccelerationFixture.effective,
                         "synthetic landscape query", AccelerationFixture.hits[0].id]
        for sentinel in sentinels {
            XCTAssertFalse(representation.contains(sentinel), file: file, line: line)
        }
    }
}

@MainActor
private struct AccelerationContext {
    let state: AppState
    let worker: AccelerationWorker
    let translator: AccelerationTranslator
    let permission: AccelerationPermission
}

@MainActor
private final class AccelerationPermission {
    var status: PHAuthorizationStatus = .authorized
}

@MainActor
private final class AccelerationTranslator: QueryTranslating {
    let isSupported = true
    private(set) var availabilityCalls = 0
    private(set) var translations: [String] = []
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityCalls += 1
        return .installed
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translations.append(text)
        return AccelerationFixture.effective
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        throw AccelerationFailure.unexpectedOperation
    }
}

private enum AccelerationFailure: Error { case synthetic, unexpectedOperation }
private enum AccelerationStop: CaseIterable, Equatable, Sendable { case worker, pageAccess, permission, cancel }

private enum AccelerationFixture {
    static let original = "  测试用蓝色杯子\n"
    static let effective = "synthetic blue cup query"
    static var summary: LibrarySummary {
        var value = LibrarySummary()
        value.indexedCount = 13
        value.modelVersion = "synthetic-state-model"
        return value
    }
    static var hits: [SearchHit] {
        var values: [SearchHit] = []
        for index in 0..<13 {
            let photo = TestFixtures.photo(id: "acceleration-fixture-\(index)").photo
            values.append(SearchHit(photo: photo, score: Float(13 - index) / 13))
        }
        return values
    }
}

/// One-shot gate; open-before-wait is supported, cancellation does not release it.
private actor AccelerationGate {
    nonisolated let entered = XCTestExpectation(description: "Synthetic worker reached gate")
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered.fulfill()
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct AccelerationRequest: Sendable {
    let text: String?
    let original: String?
    let seed: String?
    let limit: Int
    let weight: Float
    let filters: PhotoSearchFilters
    let includeText: Bool
    let timing: SearchTimingRecorder?
    let reference: Bool
}

private struct AccelerationObservations: Sendable {
    var requests: [AccelerationRequest] = []
    var events: [String] = []
    var cancelledOnReturn: [Bool] = []
    var legacyCalls = 0
    // Wiring sentinel only, not a measurement of actual vector memory.
    var hasResidentSearchScope = false
    var refreshSawResidentScope: [Bool] = []
}

private actor AccelerationWorker: PhotoWorkServicing {
    private var recorded = AccelerationObservations()
    private var searchGate: AccelerationGate?
    private var releaseGate: AccelerationGate?
    private var nextStop: AccelerationStop?
    private var gates: [AccelerationGate] = []

    func observations() -> AccelerationObservations { recorded }
    func holdSearch(_ gate: AccelerationGate, stop: AccelerationStop? = nil) {
        searchGate = gate
        nextStop = stop
        gates.append(gate)
    }
    func holdRelease(_ gate: AccelerationGate) {
        releaseGate = gate
        gates.append(gate)
    }
    func openAllGates() async { for gate in gates { await gate.open() } }
    func refresh() async throws -> LibrarySummary {
        recorded.events.append("refresh")
        recorded.refreshSawResidentScope.append(recorded.hasResidentSearchScope)
        return AccelerationFixture.summary
    }
    func releaseSearchMemory() async {
        recorded.events.append("release-enter")
        if let releaseGate { await releaseGate.wait() }
        recorded.hasResidentSearchScope = false
        recorded.events.append("release-return")
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        recorded.legacyCalls += 1
        throw AccelerationFailure.unexpectedOperation
    }
    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool,
                timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        let request = AccelerationRequest(text: text, original: originalText, seed: nil, limit: limit,
            weight: locationWeight, filters: filters, includeText: textSearchEnabled,
            timing: timing, reference: referenceSearch)
        return try await respond(to: request)
    }
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters,
                       timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        let request = AccelerationRequest(text: nil, original: nil, seed: photoID, limit: limit,
            weight: 0, filters: filters, includeText: false, timing: timing, reference: referenceSearch)
        return try await respond(to: request)
    }
    private func respond(to request: AccelerationRequest) async throws -> SearchResponse {
        recorded.requests.append(request)
        recorded.events.append("search-enter")
        let gate = searchGate
        let stop = nextStop
        searchGate = nil
        nextStop = nil
        let hits = AccelerationFixture.hits.filter { $0.id != request.seed }
        request.timing?.mark(.snapshot)
        request.timing?.setIndex(source: request.reference ? "reference" : "resident",
                                 count: hits.count, matrixReused: !request.reference)
        request.timing?.setSnapshotReused(!request.reference)
        if let gate { await gate.wait() }
        // Late cancelled work may repopulate the scope; release must follow drain.
        recorded.hasResidentSearchScope = true
        recorded.cancelledOnReturn.append(Task.isCancelled)
        recorded.events.append("search-return")
        if stop == .worker { throw AccelerationFailure.synthetic }
        // Intentionally ignore cancellation to test AppState's rejection of late work.
        request.timing?.mark(.scoring)
        request.timing?.mark(.finalAccess)
        return SearchResponse(summary: AccelerationFixture.summary, hits: hits,
                              validatePageAccess: { _ in
            if stop == .pageAccess { throw AppFailure.permission }
        })
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw AccelerationFailure.unexpectedOperation
    }
    func clear() async throws -> LibrarySummary { throw AccelerationFailure.unexpectedOperation }
}

/// Deliberately implements neither timed overload nor releaseSearchMemory.
private actor AccelerationLegacyWorker: PhotoWorkServicing {
    private(set) var calls: [String] = []
    func refresh() async throws -> LibrarySummary {
        calls.append("refresh")
        return AccelerationFixture.summary
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        calls.append(text)
        return SearchResponse(summary: AccelerationFixture.summary, hits: AccelerationFixture.hits)
    }
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        calls.append("similar")
        let hits = AccelerationFixture.hits.filter { $0.id != photoID }
        return SearchResponse(summary: AccelerationFixture.summary, hits: hits)
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw AccelerationFailure.unexpectedOperation
    }
    func clear() async throws -> LibrarySummary { throw AccelerationFailure.unexpectedOperation }
}