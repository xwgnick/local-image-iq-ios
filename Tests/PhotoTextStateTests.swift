import Foundation
import XCTest
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Real AppState with synthetic, injected worker/translation services only.
/// No Photos fetch/mutation, Vision, models, SQLite, network or file fixtures.
/// AppState still owns its normal PhotoLibraryClient: authorization reads and
/// observer registration are not a claim of zero PhotoKit API calls.
/// Gates signal entry/cancellation explicitly; no sleeps, polling or timeouts.
@MainActor
final class PhotoTextStateTests: XCTestCase {
    func testDefaultIsOffAndUnavailableToggleDefersOneIntentWithoutWork() async {
        let c = context()
        XCTAssertFalse(c.state.textSearchEnabled)
        XCTAssertFalse(c.state.canIndexText)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
        XCTAssertNil(c.state.textIndexOperationIssue)
        assertNoSearch(c.state)
        XCTAssertNil(c.state.appleTranslationService)

        for enabled in [true, true, false, true] {
            c.state.textSearchEnabled = enabled
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.textSearchEnabled, enabled)
            XCTAssertTrue(c.worker.events.isEmpty)
            XCTAssertEqual(c.state.ocrSync.pending, enabled)
            XCTAssertEqual(c.translator.counts, [0, 0, 0])
        }
        let fresh = context()
        XCTAssertFalse(fresh.state.textSearchEnabled, "No persistence without the optional injected preferences")
        XCTAssertTrue(fresh.worker.events.isEmpty)
    }

    func testIsolatedPreferencesRestoreBothValuesAndPersistOnlyTheToggle() async throws {
        let suite = "PhotoTextStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        // Registered first so LIFO teardown drains every context before cleanup.
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let c = context(preferences: defaults)
        XCTAssertFalse(c.state.textSearchEnabled)
        XCTAssertNil(defaults.object(forKey: PhotoTextStateFixtures.preferenceKey))
        c.state.textSearchEnabled = true
        c.state.refresh()
        await c.state.waitUntilIdle()
        c.state.query = PhotoTextStateFixtures.chinese
        c.state.search()
        await c.state.waitUntilIdle()

        let restored = context(preferences: defaults)
        XCTAssertTrue(restored.state.textSearchEnabled)
        XCTAssertEqual(restored.state.query, "")
        assertNoSearch(restored.state)
        XCTAssertEqual(restored.state.textIndexProgress, TextIndexProgress())
        XCTAssertTrue(restored.worker.events.isEmpty, "Restoring ON must not start OCR")
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Set(domain.keys), Set([PhotoTextStateFixtures.preferenceKey]))
        XCTAssertEqual(domain[PhotoTextStateFixtures.preferenceKey] as? Bool, true)

        restored.state.textSearchEnabled = false
        let disabled = context(preferences: defaults)
        XCTAssertFalse(disabled.state.textSearchEnabled)
        XCTAssertEqual(defaults.object(forKey: PhotoTextStateFixtures.preferenceKey) as? Bool, false)
        assertNoIndexWork(c, textCalls: 1)
    }

    func testEnabledColdStartAndForegroundOnlyPrepareOrRefreshNeverAutoIndex() async {
        let c = context(savedEnabled: true)
        c.state.allowICloudDownload = true
        c.state.start()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.launchPhase, .ready)
        XCTAssertEqual(c.worker.refreshCalls, 1)
        XCTAssertTrue(c.state.canIndexText)
        c.state.start()
        c.state.enterForeground() // Inactive-to-active is not a new background cycle.
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.refreshCalls, 1)

        c.state.enterBackground()
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.canIndexText)
        c.state.enterForeground()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.refreshCalls, 2)
        XCTAssertTrue(c.state.canIndexText)
        XCTAssertTrue(c.worker.searchRequests.isEmpty)
        XCTAssertEqual(c.translator.counts, [0, 0, 0])
        assertNoIndexWork(c)
    }

    func testIndexTextGuardsEnabledAccessModelsCurrentImageCountsAndForeground() async {
        for condition in PhotoTextStateBlockedCondition.allCases {
            let c = context(savedEnabled: condition != .disabled)
            switch condition {
            case .disabled: break
            case .denied: c.permission.status = .denied
            case .restricted: c.permission.status = .restricted
            case .notDetermined: c.permission.status = .notDetermined
            case .noModel: c.worker.refreshSummary.modelVersion = nil
            case .modelIssue: c.worker.refreshSummary.modelIssue = "TEST model unavailable"
            case .noImages: c.worker.refreshSummary.indexedCount = 0
            case .unknownImages: c.worker.refreshSummary.indexStatisticsKnown = false
            case .background: break
            }
            c.state.refresh()
            await c.state.waitUntilIdle()
            if condition == .background { c.state.enterBackground() }
            let imageProgress = c.state.progress
            let known = c.state.summary.textIndexStatisticsKnown
            XCTAssertFalse(c.state.canIndexText, "\(condition)")
            c.state.indexPhotoText()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.state.progress, imageProgress)
            XCTAssertEqual(c.state.summary.textIndexStatisticsKnown, known)
            XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
            XCTAssertNil(c.state.textIndexOperationIssue)
            assertNoIndexWork(c)
        }
        for access in [PHAuthorizationStatus.authorized, .limited] {
            let c = context(savedEnabled: true)
            c.permission.status = access
            c.worker.refreshSummary.authorizedCount = 0
            c.worker.refreshSummary.authorizedCountKnown = false
            c.worker.refreshSummary.textIndexStatisticsKnown = false
            c.state.refresh()
            await c.state.waitUntilIdle()
            XCTAssertTrue(c.state.canIndexText, "Stored current-model image counts, not a live Photos or OCR count, gate the action")
        }
    }

    func testExplicitIndexCapturesNetworkFlagAndBusyCallsCannotStartAnotherJob() async {
        for allowed in [false, true] {
            let c = await ready(enabled: true)
            c.state.allowICloudDownload = allowed
            XCTAssertTrue(c.worker.textNetworkFlags.isEmpty)
            let gate = c.makeGate()
            c.worker.nextTextGate = gate
            c.state.indexPhotoText()
            XCTAssertEqual(c.state.activity, .indexingText)
            XCTAssertFalse(c.state.canIndexText)
            XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
            c.state.allowICloudDownload = !allowed // Before the task reaches its worker.
            c.state.indexPhotoText()
            c.state.index()
            c.state.search()
            await gate.entered.wait()
            XCTAssertEqual(c.worker.textNetworkFlags, [allowed])
            XCTAssertTrue(c.worker.imageNetworkFlags.isEmpty)
            XCTAssertTrue(c.worker.searchRequests.isEmpty)
            gate.open()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.textNetworkFlags, [allowed])
            XCTAssertEqual(c.state.allowICloudDownload, !allowed)
            XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
            XCTAssertNil(c.state.textIndexOperationIssue)
            XCTAssertEqual(c.translator.counts, [0, 0, 0])
        }
    }

    func testTextProgressAndSuccessfulSummaryNeverOverwriteImageProgress() async {
        let c = await ready(enabled: true)
        await seedImageProgress(c)
        let imageProgress = c.state.progress
        let imageSummary = c.state.summary
        let gate = c.makeGate()
        c.worker.nextTextGate = gate
        c.worker.textProgressAfter = PhotoTextStateFixtures.complete
        c.state.indexPhotoText()
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
        XCTAssertEqual(c.state.progress, imageProgress)
        await gate.entered.wait()
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        assertImageSummary(c.state.summary, imageSummary)
        XCTAssertEqual(c.state.progress, imageProgress)
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.complete)
        XCTAssertEqual(c.state.progress, imageProgress)
        assertImageSummary(c.state.summary, imageSummary)
        XCTAssertEqual(c.state.summary.textIndexCounts, c.worker.textSummary.textIndexCounts)
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        XCTAssertNil(c.state.textIndexOperationIssue)
        XCTAssertNil(c.state.errorMessage)
        XCTAssertNil(c.state.actionHint)
        XCTAssertEqual(c.worker.imageNetworkFlags, [false])
    }

    func testPartialCancellationKeepsImageStateAndRequiresExplicitTextRetry() async {
        let c = await ready(enabled: true)
        await seedImageProgress(c)
        let imageProgress = c.state.progress
        let oldSummary = c.state.summary
        let gate = c.makeGate()
        c.worker.nextTextGate = gate
        c.state.indexPhotoText()
        await gate.entered.wait()
        c.state.cancel()
        await gate.cancelled.wait()
        XCTAssertEqual(c.state.activity, .indexingText, "Cancellation is not completion")
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.cancelledTextReturns, 1, "The fake returned a stale success, not a cancellation error")
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertEqual(c.state.summary.textIndexCounts, oldSummary.textIndexCounts)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertNotNil(c.state.textIndexOperationIssue)
        XCTAssertEqual(c.state.progress, imageProgress)
        assertImageSummary(c.state.summary, oldSummary)
        XCTAssertNil(c.state.errorMessage)
        XCTAssertNil(c.state.actionHint)
        XCTAssertTrue(c.state.canIndexText)
        XCTAssertEqual(c.worker.textNetworkFlags.count, 1)

        // State preserves the partial observation; storage durability itself is
        // the worker's contract, not something this in-memory state test proves.
        c.worker.textProgressAfter = PhotoTextStateFixtures.complete
        c.state.indexPhotoText()
        XCTAssertNil(c.state.textIndexOperationIssue)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.textNetworkFlags, [false, false])
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.complete)
        XCTAssertEqual(c.state.progress, imageProgress)
    }

    func testDisablingDuringTextIndexCancelsAndNewOnEventStartsOneFreshIncrementalUpdate() async {
        let c = await ready(enabled: true)
        let gate = c.makeGate()
        c.worker.nextTextGate = gate
        c.state.indexPhotoText()
        await gate.entered.wait()
        c.state.textSearchEnabled = false
        await gate.cancelled.wait()
        XCTAssertFalse(c.state.canIndexText)
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.cancelledTextReturns, 1)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertNotNil(c.state.textIndexOperationIssue)
        XCTAssertNil(c.state.errorMessage)
        c.state.textSearchEnabled = true
        await c.state.waitUntilIdle()
        XCTAssertTrue(c.state.canIndexText)
        XCTAssertEqual(c.worker.textNetworkFlags, [false, false])
        XCTAssertTrue(c.worker.imageNetworkFlags.isEmpty)
    }

    func testSuccessorAwaitsCancelledPredecessorAndRejectsOldProgressAndSummaryTokens() async throws {
        let c = await ready(enabled: true)
        await seedImageProgress(c)
        let imageProgress = c.state.progress
        let originalCounts = c.state.summary.textIndexCounts
        let oldGate = c.makeGate()
        c.worker.nextTextGate = oldGate
        c.worker.textProgressAfter = PhotoTextStateFixtures.complete
        c.state.indexPhotoText()
        await oldGate.entered.wait()
        let callback = try XCTUnwrap(c.worker.textCallbacks.first)
        let refreshGate = c.makeGate()
        c.worker.nextRefreshGate = refreshGate
        c.worker.refreshSummary.textIndexCounts = .init(records: 7, withText: 5, reduced: 2)
        c.state.refresh()
        await oldGate.cancelled.wait()
        XCTAssertEqual(c.state.activity, .refreshing)
        XCTAssertEqual(c.worker.refreshCalls, 1, "No successor worker call before the predecessor drains")
        XCTAssertEqual(c.worker.activeCalls, 1)
        await callback(PhotoTextStateFixtures.complete)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        oldGate.open()
        await refreshGate.entered.wait()
        XCTAssertEqual(c.worker.cancelledTextReturns, 1)
        XCTAssertEqual(c.worker.maximumActiveCalls, 1)
        XCTAssertEqual(Array(c.worker.events.suffix(3)), ["text.begin", "text.end", "refresh.begin"])
        XCTAssertEqual(c.state.activity, .refreshing, "Old catch/success must not mark the successor idle")
        XCTAssertEqual(c.state.summary.textIndexCounts, originalCounts)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertNil(c.state.textIndexOperationIssue, "A superseded cancellation cannot publish into the successor")
        await callback(PhotoTextStateFixtures.complete)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        refreshGate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.summary.textIndexCounts, c.worker.refreshSummary.textIndexCounts)
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        await callback(TextIndexProgress()) // Even after the replacement completed.
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertEqual(c.state.progress, imageProgress)
        XCTAssertNil(c.state.errorMessage)
    }

    func testBackgroundCancelsTextIndexRejectsLateCallbacksAndForegroundDoesNotResumeIt() async throws {
        let c = await ready(enabled: true)
        await seedImageProgress(c)
        let imageProgress = c.state.progress
        let oldSummary = c.state.summary
        let gate = c.makeGate()
        c.worker.nextTextGate = gate
        c.worker.textProgressAfter = PhotoTextStateFixtures.complete
        c.state.indexPhotoText()
        await gate.entered.wait()
        let callback = try XCTUnwrap(c.worker.textCallbacks.first)
        c.state.enterBackground()
        await gate.cancelled.wait()
        await callback(PhotoTextStateFixtures.complete)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertFalse(c.state.canIndexText)
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.cancelledTextReturns, 1)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(c.state.summary.textIndexCounts, oldSummary.textIndexCounts)
        assertImageSummary(c.state.summary, oldSummary)
        XCTAssertEqual(c.state.progress, imageProgress)
        XCTAssertNotNil(c.state.textIndexOperationIssue)
        XCTAssertNil(c.state.errorMessage)
        c.state.indexPhotoText()
        c.state.enterForeground()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.refreshCalls, 2)
        XCTAssertEqual(c.worker.textNetworkFlags, [false])
        XCTAssertEqual(c.worker.imageNetworkFlags, [false])
        XCTAssertEqual(c.state.progress, imageProgress)
    }

    func testTextErrorsAreGenericLocalIssuesAndAbortMarksOnlyTextCountsUnknown() async {
        let errors: [Error] = [PhotoTextStatePrivateError(),
                               AppFailure.photo(PhotoTextStateFixtures.privateDetail), CancellationError()]
        for error in errors {
            let c = await ready(enabled: true)
            await seedImageProgress(c)
            let imageProgress = c.state.progress
            let imageSummary = c.state.summary
            c.worker.textError = error
            c.state.indexPhotoText()
            await c.state.waitUntilIdle()
            let expected = error is CancellationError
                ? "文字索引已暂停，已完成记录保留；手动更新可继续。"
                : "文字索引未完成。请检查照片权限后重试；图片索引没有重新计算。"
            XCTAssertEqual(c.state.textIndexOperationIssue, expected)
            XCTAssertEqual(c.state.status, expected)
            XCTAssertFalse(c.state.status.contains(PhotoTextStateFixtures.privateDetail))
            XCTAssertNil(c.state.errorMessage)
            XCTAssertNil(c.state.actionHint)
            XCTAssertNil(c.state.summary.modelIssue)
            XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
            XCTAssertTrue(c.state.summary.indexStatisticsKnown)
            XCTAssertEqual(c.state.summary.textIndexCounts, imageSummary.textIndexCounts)
            XCTAssertEqual(c.state.progress, imageProgress, "Do not add OCR failures to image failure counters")
            assertImageSummary(c.state.summary, imageSummary)
            XCTAssertTrue(c.state.canSearch)

            c.worker.textError = nil
            c.state.indexPhotoText()
            XCTAssertNil(c.state.textIndexOperationIssue)
            await c.state.waitUntilIdle()
            XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
            XCTAssertNil(c.state.textIndexOperationIssue)
        }
    }

    func testNewSearchOverloadReceivesExactOriginalChineseAlongsideResolvedEnglishOnAndOff() async throws {
        for enabled in [false, true] {
            let c = await ready(enabled: enabled)
            c.state.query = PhotoTextStateFixtures.chinese
            c.state.locationWeight = 0.37
            c.worker.searchResponse = PhotoTextStateFixtures.response(textUsed: enabled)
            c.state.searchFilters = .init(albumID: "text-state-album", imageKind: .screenshots)
            c.state.search()
            await c.state.waitUntilIdle()
            let request = try XCTUnwrap(c.worker.searchRequests.last)
            XCTAssertEqual(Array(request.original.utf8), Array(PhotoTextStateFixtures.chinese.utf8))
            XCTAssertEqual(Array(request.text.utf8), Array(PhotoTextStateFixtures.english.utf8))
            XCTAssertEqual(request.enabled, enabled)
            XCTAssertEqual(request.limit, Int.max)
            XCTAssertEqual(request.weight.bitPattern, Float(0.37).bitPattern)
            XCTAssertEqual(request.filters, c.state.searchFilters)
            XCTAssertEqual(c.translator.texts, [PhotoTextStateFixtures.chinese])
            XCTAssertEqual(c.translator.counts, [1, 1, 0])
            XCTAssertEqual(c.state.completedSearchQuery, SearchQueryResolution(
                original: PhotoTextStateFixtures.chinese, effective: PhotoTextStateFixtures.english,
                translated: true, notice: nil))
            XCTAssertEqual(c.worker.legacyCalls, 0)
            XCTAssertEqual(c.worker.filteredCalls, 0)
            assertHits(c.state.results, c.worker.searchResponse.hits)
            assertNoIndexWork(c)
        }
    }

    func testFilterRerunPreservesCompletedOriginalAndEnglishWithoutRetranslation() async throws {
        let c = await ready(enabled: true)
        c.state.query = PhotoTextStateFixtures.chinese
        await search(c)
        let resolution = try XCTUnwrap(c.state.completedSearchQuery)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let filters = PhotoSearchFilters(startDate: Date(timeIntervalSince1970: 100),
                                         endDateExclusive: Date(timeIntervalSince1970: 200),
                                         albumID: "text-state-album", imageKind: .livePhotos)
        c.state.applySearchFilters(filters)
        assertNoSearch(c.state)
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.completedSearchQuery, resolution)
        XCTAssertNotEqual(c.state.resultSessionID, session)
        XCTAssertEqual(c.worker.searchRequests.map(\.original), [resolution.original, resolution.original])
        XCTAssertEqual(c.worker.searchRequests.map(\.text), [resolution.effective, resolution.effective])
        XCTAssertEqual(c.worker.searchRequests.map(\.filters), [.init(), filters])
        XCTAssertEqual(c.worker.searchRequests.map(\.enabled), [true, true])
        XCTAssertEqual(c.translator.counts, [1, 1, 0])
        assertNoIndexWork(c)
    }

    func testUseOriginalAndItsFilterRerunKeepChineseThenANormalSearchTranslatesAgain() async throws {
        let c = await ready(enabled: true)
        c.state.query = PhotoTextStateFixtures.chinese
        c.state.search(useOriginal: true)
        await c.state.waitUntilIdle()
        let resolution = try XCTUnwrap(c.state.completedSearchQuery)
        XCTAssertFalse(resolution.translated)
        XCTAssertEqual(resolution.original, PhotoTextStateFixtures.chinese)
        XCTAssertEqual(resolution.effective, resolution.original)
        c.state.applySearchFilters(.init(imageKind: .photos))
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.completedSearchQuery, resolution)
        XCTAssertEqual(c.translator.counts, [0, 0, 0])
        XCTAssertEqual(c.worker.searchRequests.map(\.text), [resolution.original, resolution.original])
        XCTAssertEqual(c.worker.searchRequests.map(\.original), [resolution.original, resolution.original])
        XCTAssertEqual(c.worker.searchRequests.map(\.enabled), [true, true])
        XCTAssertTrue(c.state.chineseSearchEnabled)
        await search(c)
        XCTAssertEqual(c.translator.counts, [1, 1, 0])
        XCTAssertEqual(c.worker.searchRequests.last?.original, resolution.original)
        XCTAssertEqual(c.worker.searchRequests.last?.text, PhotoTextStateFixtures.english)
        assertNoIndexWork(c)
    }

    func testSimilarityAndItsFilterRerunNeverInvokeTextSearchOCRorTranslation() async throws {
        let c = await ready(enabled: true)
        c.state.query = PhotoTextStateFixtures.chinese
        c.worker.searchResponse = PhotoTextStateFixtures.response(textUsed: true)
        await search(c)
        XCTAssertTrue(c.state.textSearchUsed)
        let seed = try XCTUnwrap(c.state.results.first?.id)
        let requests = c.worker.searchRequests
        let translations = c.translator.counts
        c.state.searchSimilar(to: seed)
        assertNoSearch(c.state)
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.similarPhotoID, seed)
        XCTAssertFalse(c.state.textSearchUsed)
        XCTAssertTrue(c.state.textMatchedIDs.isEmpty)
        let filters = PhotoSearchFilters(imageKind: .screenshots)
        c.state.applySearchFilters(filters)
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.similarRequests, [
            .init(id: seed, limit: Int.max, filters: .init()),
            .init(id: seed, limit: Int.max, filters: filters)
        ])
        XCTAssertEqual(c.worker.searchRequests, requests)
        XCTAssertEqual(c.translator.counts, translations)
        XCTAssertFalse(c.state.textSearchUsed)
        XCTAssertTrue(c.state.textMatchedIDs.isEmpty)
        XCTAssertFalse(c.state.results.contains { $0.id == seed })
        assertNoIndexWork(c)
    }

    func testEitherToggleInvalidatesCompletedResultsAndCancelsHeldWorkerSearch() async throws {
        for initiallyEnabled in [false, true] {
            let c = await ready(enabled: initiallyEnabled)
            c.worker.searchResponse = PhotoTextStateFixtures.response(textUsed: initiallyEnabled)
            await search(c)
            let session = try XCTUnwrap(c.state.resultSessionID)
            c.state.selection = .init(id: try XCTUnwrap(c.state.results.first?.id))
            c.state.setSelectingResults(true)
            c.state.selectVisibleResults()
            c.state.textSearchEnabled.toggle()
            assertNoSearch(c.state)
            XCTAssertNil(c.state.selection)
            XCTAssertFalse(c.state.isSelectingResults)
            XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
            c.state.loadMoreResults(sessionID: session, after: 12)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.searchRequests.count, 1, "Toggling must not automatically search")

            c.worker.searchResponse = PhotoTextStateFixtures.response(textUsed: !initiallyEnabled)
            let gate = c.makeGate()
            c.worker.nextSearchGate = gate
            c.state.search()
            await gate.entered.wait()
            c.state.textSearchEnabled.toggle()
            assertNoSearch(c.state)
            await gate.cancelled.wait()
            gate.open()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.cancelledSearchReturns, 1)
            XCTAssertEqual(c.worker.searchRequests.map(\.enabled), [initiallyEnabled, !initiallyEnabled])
            XCTAssertNil(c.state.errorMessage)
            assertNoSearch(c.state)
            assertNoIndexWork(c, textCalls: 1)
        }
    }

    func testEitherToggleCancelsHeldTranslationBeforeAnyWorkerSearch() async {
        for enabled in [false, true] {
            let c = await ready(enabled: enabled)
            c.state.query = PhotoTextStateFixtures.chinese
            let gate = c.makeGate()
            c.translator.nextGate = gate
            c.state.search()
            await gate.entered.wait()
            XCTAssertTrue(c.worker.searchRequests.isEmpty)
            c.state.textSearchEnabled.toggle()
            await gate.cancelled.wait()
            gate.open()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.translator.cancelledReturns, 1)
            XCTAssertEqual(c.translator.counts, [1, 1, 0])
            XCTAssertTrue(c.worker.searchRequests.isEmpty)
            XCTAssertNil(c.state.errorMessage)
            assertNoSearch(c.state)
            assertNoIndexWork(c, textCalls: enabled ? 0 : 1)
        }
    }

    func testOffSearchWithUnknownTextStatisticsPreservesPreviousCountsKnowledgeAndIssue() async {
        for known in [false, true] {
            let c = context()
            c.worker.refreshSummary.textIndexStatisticsKnown = known
            c.worker.refreshSummary.textIndexIssue = known ? nil : "TEST previous optional statistics issue"
            c.state.refresh()
            await c.state.waitUntilIdle()
            let previous = c.state.summary
            var responseSummary = PhotoTextStateFixtures.summary
            responseSummary.indexedCount = 9
            responseSummary.locatedCount = 1
            responseSummary.textIndexCounts = TextIndexCounts()
            responseSummary.textIndexStatisticsKnown = false
            responseSummary.textIndexIssue = nil
            c.worker.searchResponse = SearchResponse(summary: responseSummary, hits: PhotoTextStateFixtures.hits)
            c.state.query = "TEST vector only"
            await search(c)
            XCTAssertEqual(c.worker.searchRequests.last?.enabled, false)
            XCTAssertEqual(c.state.summary.textIndexCounts, previous.textIndexCounts)
            XCTAssertEqual(c.state.summary.textIndexStatisticsKnown, known)
            XCTAssertEqual(c.state.summary.textIndexIssue, previous.textIndexIssue)
            XCTAssertEqual(c.state.summary.indexedCount, 9, "Only absent OCR observations are retained")
            XCTAssertEqual(c.state.summary.locatedCount, 1)
            XCTAssertFalse(c.state.textSearchUsed)
            XCTAssertTrue(c.state.textMatchedIDs.isEmpty)
            assertNoIndexWork(c)
        }
    }

    func testEnabledFreshStatisticsReplaceOldCountsAndNewSessionsClearTextBadgesImmediately() async throws {
        let c = await ready(enabled: true)
        c.worker.searchResponse = PhotoTextStateFixtures.response(textUsed: true)
        await search(c)
        let firstSession = try XCTUnwrap(c.state.resultSessionID)
        XCTAssertTrue(c.state.textSearchUsed)
        XCTAssertEqual(c.state.textMatchedIDs, Set([PhotoTextStateFixtures.hits[1].id]))

        var empty = PhotoTextStateFixtures.summary
        empty.textIndexCounts = TextIndexCounts()
        empty.textIndexStatisticsKnown = true // A measured zero, unlike an OFF search.
        c.worker.searchResponse = SearchResponse(summary: empty, hits: PhotoTextStateFixtures.hits)
        let gate = c.makeGate()
        c.worker.nextSearchGate = gate
        c.state.search() // Same query, new session: no query didSet to clear badges for us.
        assertNoSearch(c.state)
        await gate.entered.wait()
        XCTAssertFalse(c.state.textSearchUsed)
        XCTAssertTrue(c.state.textMatchedIDs.isEmpty)
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertNotEqual(c.state.resultSessionID, firstSession)
        XCTAssertEqual(c.state.summary.textIndexCounts, TextIndexCounts())
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        XCTAssertFalse(c.state.textSearchUsed)
        XCTAssertTrue(c.state.textMatchedIDs.isEmpty)

        var updated = empty
        updated.textIndexCounts = .init(records: 8, withText: 6, reduced: 1)
        let matches = Set([PhotoTextStateFixtures.hits[0].id])
        c.worker.searchResponse = SearchResponse(summary: updated, hits: PhotoTextStateFixtures.hits,
                                                 textMatchedIDs: matches, textSearchUsed: true)
        await search(c)
        XCTAssertEqual(c.state.summary.textIndexCounts, updated.textIndexCounts)
        XCTAssertEqual(c.state.textMatchedIDs, matches, "Replace, do not union with a previous session")
        XCTAssertTrue(c.state.textSearchUsed)
        assertHits(c.state.results, c.worker.searchResponse.hits)

        updated.textIndexCounts = TextIndexCounts()
        updated.textIndexStatisticsKnown = false
        updated.textIndexIssue = "TEST newly reported OCR statistics issue"
        c.worker.searchResponse = SearchResponse(summary: updated, hits: PhotoTextStateFixtures.hits)
        await search(c)
        XCTAssertEqual(c.state.summary.textIndexCounts, TextIndexCounts())
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(c.state.summary.textIndexIssue, updated.textIndexIssue)
        XCTAssertFalse(c.state.textSearchUsed)
        XCTAssertTrue(c.state.textMatchedIDs.isEmpty)
        XCTAssertNil(c.state.errorMessage)
        assertNoIndexWork(c)
    }

    func testLegacyProtocolDefaultsRemainCompatibleWhenOffAndAppPreservesScores() async throws {
        let worker = PhotoTextStateLegacyWorker()
        let translator = PhotoTextStateTranslator()
        let state = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        addTeardownBlock { await state.waitUntilIdle() }
        state.refresh()
        await state.waitUntilIdle()
        state.query = "  TEST legacy vector query\n"
        state.locationWeight = 0.37
        state.search()
        await state.waitUntilIdle()
        XCTAssertFalse(state.textSearchEnabled)
        XCTAssertEqual(worker.requests, [.init(text: state.query, original: state.query,
                                               limit: Int.max, weight: 0.37, filters: .init(), enabled: false)])
        XCTAssertEqual(state.completedQuery, state.query)
        assertHits(state.results, PhotoTextStateFixtures.hits)
        XCTAssertEqual(state.summary.textIndexCounts, PhotoTextStateFixtures.summary.textIndexCounts)
        XCTAssertFalse(state.textSearchUsed)
        XCTAssertTrue(state.textMatchedIDs.isEmpty)
        XCTAssertEqual(translator.counts, [0, 0, 0])

        let service: any PhotoWorkServicing = worker
        _ = try await service.search(text: "effective", originalText: "原文", limit: -7,
                                     locationWeight: 0.23, filters: .init(), textSearchEnabled: false)
        XCTAssertEqual(worker.requests.last?.text, "effective")
        XCTAssertEqual(worker.requests.last?.limit, -7)
        XCTAssertEqual(worker.requests.last?.weight.bitPattern, Float(0.23).bitPattern)
        let calls = worker.requests
        do {
            _ = try await service.search(text: "effective", originalText: "原文", limit: 12,
                                         locationWeight: 0.6, filters: .init(), textSearchEnabled: true)
            XCTFail("Default compatibility must not silently drop enabled OCR search")
        } catch { XCTAssertTrue(error is AppFailure) }
        do {
            _ = try await service.indexText(networkAllowed: false) { _ in
                XCTFail("Unsupported default OCR must not emit fabricated progress")
            }
            XCTFail("A legacy-only mock must reject unsupported text indexing")
        } catch { XCTAssertTrue(error is AppFailure) }
        XCTAssertEqual(worker.requests, calls)
        XCTAssertEqual(worker.mutationCalls, 0)
    }

    func testUserOnStartsOnceAndDuplicateTrueRefreshAndReopenDoNotRepeatOCR() async {
        let c = await ready()
        let gate = c.makeGate()
        c.worker.nextTextGate = gate
        c.state.textSearchEnabled = true
        await gate.entered.wait()
        XCTAssertEqual(c.state.ocrSync.phase, .updating)
        XCTAssertTrue(c.state.ocrSync.currentRunning)
        c.state.textSearchEnabled = true
        c.state.indexPhotoText() // Busy manual duplicate must also coalesce.
        XCTAssertEqual(c.worker.textNetworkFlags, [false])
        gate.open()
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.ocrSync.currentRunning)
        c.state.textSearchEnabled = true
        c.state.refresh()
        await c.state.waitUntilIdle()
        c.state.enterBackground()
        await c.state.waitUntilIdle()
        c.state.enterForeground()
        await c.state.waitUntilIdle()
        assertNoIndexWork(c, textCalls: 1)
    }

    func testOnDuringBusyRefreshDefersOnceAndOffCancelsOnlyPendingOCR() async {
        for disable in [false, true] {
            let c = await ready()
            let gate = c.makeGate()
            c.worker.nextRefreshGate = gate
            c.state.refresh()
            await gate.entered.wait()
            c.state.textSearchEnabled = true
            c.state.textSearchEnabled = true
            XCTAssertTrue(c.state.ocrSync.pending)
            XCTAssertFalse(c.state.ocrSync.currentRunning)
            XCTAssertTrue(c.worker.textNetworkFlags.isEmpty)
            if disable { c.state.textSearchEnabled = false }
            XCTAssertEqual(c.state.activity, .refreshing)
            gate.open()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.worker.maximumActiveCalls, 1)
            assertNoIndexWork(c, textCalls: disable ? 0 : 1)
        }
    }

    func testOffOnDuringCancelledWorkerDrainStartsOneNewRunAfterOldReturn() async throws {
        let c = await ready()
        let old = c.makeGate()
        c.worker.nextTextGate = old
        c.state.textSearchEnabled = true
        await old.entered.wait()
        let callback = try XCTUnwrap(c.worker.textCallbacks.first)
        c.state.textSearchEnabled = false
        await old.cancelled.wait()
        let new = c.makeGate()
        c.worker.nextTextGate = new
        c.state.textSearchEnabled = true
        c.state.textSearchEnabled = true
        XCTAssertEqual(c.state.ocrSync.phase, .cancelling)
        XCTAssertTrue(c.state.ocrSync.pending)
        XCTAssertEqual(c.worker.textNetworkFlags.count, 1)
        old.open()
        await new.entered.wait()
        await callback(.init(total: 999, completed: 998))
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextStateFixtures.partial)
        XCTAssertEqual(c.state.ocrSync.progress, PhotoTextStateFixtures.partial)
        XCTAssertEqual(c.worker.maximumActiveCalls, 1)
        new.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.textNetworkFlags, [false, false])
        XCTAssertFalse(c.state.ocrSync.currentRunning)
    }

    func testToggleFailureDoesNotAutoRetryButExplicitRetryUsesLatestCloudChoice() async {
        let c = await ready()
        c.worker.textError = PhotoTextStatePrivateError()
        c.state.textSearchEnabled = true
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.ocrSync.phase, .failed)
        c.state.refresh()
        await c.state.waitUntilIdle()
        c.state.textSearchEnabled = true
        XCTAssertEqual(c.worker.textNetworkFlags, [false])
        c.worker.textError = nil
        c.state.allowICloudDownload = true
        XCTAssertEqual(c.worker.textNetworkFlags, [false])
        c.state.retryOCRSync()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.textNetworkFlags, [false, true])
        XCTAssertNil(c.state.errorMessage)
        XCTAssertFalse(c.state.status.contains(PhotoTextStateFixtures.privateDetail))
    }

    func testPendingToggleInBackgroundWaitsForForegroundReadinessOnce() async {
        let c = await ready()
        c.state.enterBackground()
        await c.state.waitUntilIdle()
        c.state.textSearchEnabled = true
        c.state.textSearchEnabled = true
        XCTAssertTrue(c.state.ocrSync.pending)
        XCTAssertTrue(c.worker.textNetworkFlags.isEmpty)
        c.state.enterForeground()
        await c.state.waitUntilIdle()
        assertNoIndexWork(c, textCalls: 1)
    }

    // MARK: In-memory fixture lifecycle and assertions

    private func context(preferences: UserDefaults? = nil, savedEnabled: Bool = false) -> PhotoTextStateContext {
        var preferences = preferences
        if preferences == nil, savedEnabled {
            let suite = "PhotoTextStateTests.restored.\(UUID().uuidString)"
            let saved = UserDefaults(suiteName: suite)!
            saved.set(true, forKey: PhotoTextStateFixtures.preferenceKey)
            preferences = saved
            addTeardownBlock { saved.removePersistentDomain(forName: suite) }
        }
        let c = PhotoTextStateContext(preferences: preferences)
        addTeardownBlock { await c.releaseAndDrain() }
        return c
    }

    private func ready(enabled: Bool = false) async -> PhotoTextStateContext {
        let c = context(savedEnabled: enabled)
        c.state.refresh()
        await c.state.waitUntilIdle()
        c.state.query = "TEST photo text state"
        XCTAssertTrue(c.state.canSearch)
        XCTAssertEqual(c.state.textSearchEnabled, enabled)
        return c
    }

    private func search(_ c: PhotoTextStateContext, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(c.state.canSearch, file: file, line: line)
        c.state.search()
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.state.isBusy, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
    }

    private func seedImageProgress(_ c: PhotoTextStateContext) async {
        c.state.index()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.progress, PhotoTextStateFixtures.imageProgress)
        XCTAssertGreaterThan(c.state.progress.failed, 0, "Use nonzero image counters so corruption is observable")
    }

    private func assertNoSearch(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.resultSessionID, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.completedSearchQuery, file: file, line: line)
        XCTAssertNil(state.similarPhotoID, file: file, line: line)
        XCTAssertEqual(state.totalResultCount, 0, file: file, line: line)
        XCTAssertFalse(state.textSearchUsed, file: file, line: line)
        XCTAssertTrue(state.textMatchedIDs.isEmpty, file: file, line: line)
    }

    private func assertNoIndexWork(_ c: PhotoTextStateContext, textCalls: Int = 0,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(c.worker.imageNetworkFlags.isEmpty, file: file, line: line)
        XCTAssertEqual(c.worker.textNetworkFlags.count, textCalls, file: file, line: line)
        XCTAssertEqual(c.worker.clearCalls, 0, file: file, line: line)
        XCTAssertEqual(c.worker.diagnosticCalls, 0, file: file, line: line)
        XCTAssertEqual(c.translator.prepareCalls, 0, file: file, line: line)
    }

    private func assertImageSummary(_ actual: LibrarySummary, _ expected: LibrarySummary,
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

    private func assertHits(_ actual: [SearchHit], _ expected: [SearchHit],
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(actual.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern }, file: file, line: line)
        XCTAssertEqual(actual.map { $0.photo.imageEmbedding }, expected.map { $0.photo.imageEmbedding }, file: file, line: line)
        XCTAssertEqual(actual.map { $0.photo.modelVersion }, expected.map { $0.photo.modelVersion }, file: file, line: line)
    }
}

private enum PhotoTextStateBlockedCondition: CaseIterable {
    case disabled, denied, restricted, notDetermined, noModel, modelIssue, noImages, unknownImages, background
}

private enum PhotoTextStateFixtures {
    static let preferenceKey = "photoTextSearchEnabled.v1"
    static let chinese = " \t收据编号 ABC-123 和中文照片\r\n "
    static let english = " \tTEST receipt ABC-123 and a Chinese photo\n "
    static let privateDetail = "TEST_PRIVATE_OCR_CONTENT_AND_ASSET_IDENTIFIER"
    static let model = "photo-text-state-synthetic-model"

    static var summary: LibrarySummary {
        LibrarySummary(authorizedCount: 14, authorizedCountKnown: true, indexStatisticsKnown: true,
                       indexedCount: 12, locatedCount: 4, modelVersion: model,
                       placesDescription: "TEST stored place metadata",
                       textIndexCounts: .init(records: 3, withText: 2, reduced: 1),
                       textIndexStatisticsKnown: true)
    }

    static var textSummary: LibrarySummary {
        var result = summary
        result.textIndexCounts = .init(records: 10, withText: 8, reduced: 2)
        return result
    }

    static var partial: TextIndexProgress {
        TextIndexProgress(total: 12, completed: 5, recognized: 3, reused: 1,
                          withText: 2, reduced: 1, cloudSkipped: 1)
    }

    static var complete: TextIndexProgress {
        TextIndexProgress(total: 12, completed: 12, recognized: 8, reused: 2,
                          withText: 8, reduced: 2, cloudSkipped: 1, failed: 1)
    }

    static var imageProgress: IndexProgress {
        IndexProgress(total: 14, completed: 14, encoded: 8, reused: 4, failed: 2,
                      localPreviews: 8, reducedPreviews: 2, placeChecked: 14,
                      gpsCount: 4, placeResolved: 4, noGPS: 10, placeUpdated: 1,
                      lastFailure: "TEST existing image-only failure")
    }

    static var hits: [SearchHit] {
        // Nonlexicographic IDs and negative zero expose accidental resorting,
        // score fusion/rounding, or score normalization in the shared AppState.
        let rows: [(String, Float)] = [("text-state-z", 0.8123457), ("text-state-a", -Float.zero),
                                       ("text-state-m", -0.234567)]
        return rows.enumerated().map { offset, row in
            var vector = [Float](repeating: 0, count: 768)
            vector[offset] = 1
            let photo = IndexedPhoto(id: row.0, modificationTime: Double(offset), modelVersion: model,
                                     imageEmbedding: vector, creationTime: Double(100 + offset))
            return SearchHit(photo: photo, score: row.1)
        }
    }

    static func response(textUsed: Bool = false) -> SearchResponse {
        let visual = hits
        // Simulate a worker-owned lexical rank change while keeping every visual
        // score intact. AppState must neither recompute nor sort by those scores.
        let ordered = textUsed ? [visual[1], visual[0], visual[2]] : visual
        return SearchResponse(summary: textUsed ? textSummary : summary, hits: ordered,
                              textMatchedIDs: textUsed ? Set([visual[1].id]) : [], textSearchUsed: textUsed)
    }
}

private struct PhotoTextStatePrivateError: LocalizedError {
    var errorDescription: String? { PhotoTextStateFixtures.privateDetail }
}

private struct PhotoTextStateSearchRequest: Equatable {
    let text: String
    let original: String
    let limit: Int
    let weight: Float
    let filters: PhotoSearchFilters
    let enabled: Bool
}

private struct PhotoTextStateSimilarRequest: Equatable {
    let id: String
    let limit: Int
    let filters: PhotoSearchFilters
}

/// A latched event also handles signals that happen before the test starts waiting.
@MainActor
private final class PhotoTextStateSignal {
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// Deliberately noncooperative: cancellation is observed but only open() drains it.
@MainActor
private final class PhotoTextStateGate {
    let entered = PhotoTextStateSignal()
    let cancelled = PhotoTextStateSignal()
    private let released = PhotoTextStateSignal()

    func wait() async {
        await withTaskCancellationHandler {
            entered.fire()
            await released.wait()
        } onCancel: {
            Task { @MainActor [self] in cancelled.fire() }
        }
    }

    func open() { released.fire() }
}

@MainActor
private final class PhotoTextStatePermission {
    var status: PHAuthorizationStatus = .limited
}

@MainActor
private final class PhotoTextStateTranslator: QueryTranslating {
    let isSupported = true
    var nextGate: PhotoTextStateGate?
    private(set) var availabilityCalls = 0
    private(set) var texts: [String] = []
    private(set) var prepareCalls = 0
    private(set) var cancelledReturns = 0
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
        if Task.isCancelled { cancelledReturns += 1 }
        return PhotoTextStateFixtures.english
    }

    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareCalls += 1
        XCTFail("State tests must not prepare/download translation packs")
    }
}

@MainActor
private final class PhotoTextStateWorker: PhotoWorkServicing {
    var refreshSummary = PhotoTextStateFixtures.summary
    var textSummary = PhotoTextStateFixtures.textSummary
    var searchResponse = PhotoTextStateFixtures.response()
    var textError: Error?
    var textProgressAfter: TextIndexProgress?
    var nextTextGate: PhotoTextStateGate?
    var nextRefreshGate: PhotoTextStateGate?
    var nextSearchGate: PhotoTextStateGate?
    private(set) var textCallbacks: [@Sendable (TextIndexProgress) async -> Void] = []
    private(set) var textNetworkFlags: [Bool] = []
    private(set) var imageNetworkFlags: [Bool] = []
    private(set) var searchRequests: [PhotoTextStateSearchRequest] = []
    private(set) var similarRequests: [PhotoTextStateSimilarRequest] = []
    private(set) var refreshCalls = 0
    private(set) var clearCalls = 0
    private(set) var diagnosticCalls = 0
    private(set) var legacyCalls = 0
    private(set) var filteredCalls = 0
    private(set) var cancelledTextReturns = 0
    private(set) var cancelledSearchReturns = 0
    private(set) var events: [String] = []
    private(set) var activeCalls = 0
    private(set) var maximumActiveCalls = 0

    private func begin(_ name: String) {
        activeCalls += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCalls)
        events.append(name + ".begin")
    }

    private func end(_ name: String) {
        events.append(name + ".end")
        activeCalls -= 1
    }

    func refresh() async throws -> LibrarySummary {
        begin("refresh")
        defer { end("refresh") }
        refreshCalls += 1
        let captured = refreshSummary
        let gate = nextRefreshGate
        nextRefreshGate = nil
        await gate?.wait()
        return captured
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        begin("image")
        defer { end("image") }
        imageNetworkFlags.append(networkAllowed)
        await progress(PhotoTextStateFixtures.imageProgress)
        return refreshSummary
    }

    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        begin("text")
        defer { end("text") }
        textNetworkFlags.append(networkAllowed)
        textCallbacks.append(progress)
        let captured = textSummary
        let error = textError
        let after = textProgressAfter
        let gate = nextTextGate
        nextTextGate = nil
        await progress(PhotoTextStateFixtures.partial)
        await gate?.wait()
        if let after { await progress(after) }
        if let error { throw error }
        if Task.isCancelled { cancelledTextReturns += 1 }
        return captured // Intentional late success; AppState must reject it.
    }

    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool) async throws -> SearchResponse {
        begin("search")
        defer { end("search") }
        searchRequests.append(.init(text: text, original: originalText, limit: limit, weight: locationWeight,
                                    filters: filters, enabled: textSearchEnabled))
        let captured = searchResponse
        let gate = nextSearchGate
        nextSearchGate = nil
        await gate?.wait()
        if Task.isCancelled { cancelledSearchReturns += 1 }
        return captured
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        legacyCalls += 1
        XCTFail("Use the original/effective query protocol witness, not the legacy overload")
        return searchResponse
    }

    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse {
        filteredCalls += 1
        XCTFail("The original query and OCR flag must reach the new protocol witness")
        return searchResponse
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        begin("similar")
        defer { end("similar") }
        similarRequests.append(.init(id: photoID, limit: limit, filters: filters))
        var summary = refreshSummary
        summary.textIndexCounts = TextIndexCounts()
        summary.textIndexStatisticsKnown = false
        return SearchResponse(summary: summary, hits: PhotoTextStateFixtures.hits.filter { $0.id != photoID })
    }

    func clear() async throws -> LibrarySummary {
        clearCalls += 1
        XCTFail("Photo text state actions must not clear image storage")
        return refreshSummary
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        diagnosticCalls += 1
        XCTFail("Neither OCR search nor similarity may trigger a diagnostic pixel read")
        throw AppFailure.photo("TEST unexpected diagnostic")
    }
}

/// Independent conformance: do not inherit the new overloads from the full fake.
@MainActor
private final class PhotoTextStateLegacyWorker: PhotoWorkServicing {
    private(set) var requests: [PhotoTextStateSearchRequest] = []
    private(set) var mutationCalls = 0

    func refresh() async throws -> LibrarySummary { PhotoTextStateFixtures.summary }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        requests.append(.init(text: text, original: text, limit: limit, weight: locationWeight,
                              filters: .init(), enabled: false))
        var summary = PhotoTextStateFixtures.summary
        summary.textIndexCounts = TextIndexCounts()
        summary.textIndexStatisticsKnown = false
        return SearchResponse(summary: summary, hits: PhotoTextStateFixtures.hits)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        mutationCalls += 1
        XCTFail("Legacy compatibility must not index images")
        return PhotoTextStateFixtures.summary
    }

    func clear() async throws -> LibrarySummary {
        mutationCalls += 1
        XCTFail("Legacy compatibility must not clear images")
        return PhotoTextStateFixtures.summary
    }
}

@MainActor
private final class PhotoTextStateContext {
    let permission: PhotoTextStatePermission
    let translator: PhotoTextStateTranslator
    let worker: PhotoTextStateWorker
    let state: AppState
    private var gates: [PhotoTextStateGate] = []

    init(preferences: UserDefaults?) {
        let permission = PhotoTextStatePermission()
        let translator = PhotoTextStateTranslator()
        let worker = PhotoTextStateWorker()
        self.permission = permission
        self.translator = translator
        self.worker = worker
        state = AppState(worker: worker, authorizationStatus: { permission.status },
                         queryTranslator: translator, startupVisibilityDelay: { _ in },
                         textSearchPreferences: preferences)
    }

    func makeGate() -> PhotoTextStateGate {
        let gate = PhotoTextStateGate()
        gates.append(gate)
        return gate
    }

    func releaseAndDrain() async {
        state.cancel()
        for gate in gates { gate.open() }
        await state.waitUntilIdle()
        XCTAssertEqual(worker.activeCalls, 0)
        XCTAssertLessThanOrEqual(worker.maximumActiveCalls, 1)
        XCTAssertEqual(worker.clearCalls, 0)
        XCTAssertEqual(worker.diagnosticCalls, 0)
        XCTAssertEqual(worker.legacyCalls, 0)
        XCTAssertEqual(worker.filteredCalls, 0)
        XCTAssertEqual(translator.prepareCalls, 0)
    }
}