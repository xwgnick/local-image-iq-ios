import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Model-free state contracts and five native review captures, not pixel baselines.
/// The service, 512 candidate hits and 768-dimensional unit vectors are test-only.
/// No Photos authorization, imports, private images, model inference or index writes.
/// A fixture's 64-pixel report is NOT evidence about any real PhotoKit preview.
@MainActor
final class PhotoCheckPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let compactPhone = CGSize(width: 375, height: 667)

    // MARK: State preservation and request contract

    func testSuccessfulCheckPreservesQueryCompletedQueryResultsSelectionAndDefaults() async throws {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let before = GallerySnapshot(state)
        XCTAssertEqual(PhotoCheckFixtures.hits.count, 512)
        XCTAssertTrue(PhotoCheckFixtures.hits.allSatisfy { $0.photo.imageEmbedding.count == 768 })
        for hit in PhotoCheckFixtures.hits { try EmbeddingValidation.validateUnit(hit.photo.imageEmbedding) }
        XCTAssertEqual(state.resultLimit, 12)
        XCTAssertEqual(state.locationWeight, 0.6)
        XCTAssertFalse(state.allowICloudDownload)

        await startHeldCheck(state, worker: worker)
        assertGallery(state, matches: before)
        XCTAssertFalse(state.canSearch)
        XCTAssertFalse(state.canIndex)
        await worker.release(.check)
        await state.waitUntilIdle()

        let report = try XCTUnwrap(state.photoCheckReport)
        XCTAssertEqual(report.photoID, PhotoCheckFixtures.photoID)
        XCTAssertEqual(Array(report.query.utf8), Array(PhotoCheckFixtures.checkQuery.utf8))
        XCTAssertEqual(report.locationWeight, Float(0.6))
        XCTAssertEqual(report.galleryCount, 512)
        XCTAssertEqual(report.cachedRank, 16)
        XCTAssertEqual(report.freshRank, 1)
        assertGallery(state, matches: before)
        XCTAssertTrue(state.canSearch)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.photoCheckIssue)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.actionHint)
        let observed = await worker.observations()
        XCTAssertEqual(observed.checkRequests.count, 1)
        XCTAssertEqual(observed.returnedChecks, 1)
        XCTAssertEqual(observed.indexCalls, 0)
        XCTAssertEqual(observed.clearCalls, 0)
    }

    func testCheckPassesQueryBytesAndSameFloatWeightAsSearch() async throws {
        // UTF-8 comparison catches normalization that Swift String equality would
        // miss. Exercise leading/trailing whitespace, case, composed/decomposed
        // accents, an internal newline, Chinese and an emoji.
        // This tests AppState's API; PhotoCheckSheet also passes its local query
        // unchanged. This test itself does not inject keyboard events.
        let query = " \tTEST FIXTURE É e\u{301} Dog\n白色笔 🖊️\r\n "
        for weight in [0.0, 0.25, 0.6, 1.0] {
            let worker = PhotoCheckTestWorker()
            let state = await readyState(worker: worker)
            state.locationWeight = weight
            await completeSearch(state)
            let before = GallerySnapshot(state)
            state.checkPhoto(id: PhotoCheckFixtures.photoID, query: query)
            await state.waitUntilIdle()

            let observed = await worker.observations()
            let request = try XCTUnwrap(observed.checkRequests.first)
            let search = try XCTUnwrap(observed.searchRequests.last)
            let report = try XCTUnwrap(state.photoCheckReport)
            XCTAssertEqual(observed.checkRequests.count, 1)
            XCTAssertEqual(request.id, PhotoCheckFixtures.photoID)
            XCTAssertEqual(Array(request.query.utf8), Array(query.utf8))
            XCTAssertEqual(Array(report.query.utf8), Array(query.utf8))
            XCTAssertEqual(request.locationWeight.bitPattern, Float(weight).bitPattern)
            XCTAssertEqual(request.locationWeight.bitPattern, search.locationWeight.bitPattern)
            XCTAssertEqual(report.locationWeight.bitPattern, request.locationWeight.bitPattern)
            XCTAssertEqual(search.limit, Int.max)
            assertGallery(state, matches: before)
        }
    }

    // MARK: Cancellation, dismissal and local versus gallery edits

    func testCancelRejectsLateReportWithoutDroppingGallery() async {
        await assertLateCheckDiscarded(by: .cancel)
    }

    func testDismissRejectsLateReportWithoutDroppingGallery() async {
        await assertLateCheckDiscarded(by: .dismiss)
    }

    func testSheetQueryEditMimicsDismissBeforeLateReportAndPreservesGalleryQuery() async {
        await assertLateCheckDiscarded(by: .sheetQueryEdit)
    }

    func testGalleryQueryEditCancelsCheckAndRejectsLateReport() async {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let cancelled = expectation(description: "Gallery edit cancels the checking task")
        await startHeldCheck(state, worker: worker, cancelled: cancelled)
        let edited = "TEST FIXTURE different gallery query"
        state.query = edited
        assertNoGallery(state)
        XCTAssertNil(state.photoCheckReport)
        await fulfillment(of: [cancelled], timeout: 3)
        await worker.release(.check)
        await state.waitUntilIdle()

        XCTAssertEqual(state.query, edited)
        assertNoGallery(state)
        assertNoCheckResultOrError(state)
        XCTAssertFalse(state.isBusy)
        let observed = await worker.observations()
        XCTAssertEqual(observed.returnedChecks, 1)
        XCTAssertEqual(observed.cancelledChecks, 1)
    }

    func testChangingEitherGallerySettingCancelsCheckAndRejectsLateReport() async {
        for changeWeight in [true, false] {
            let worker = PhotoCheckTestWorker()
            let state = await searchedState(worker: worker)
            let cancelled = expectation(description: "Search setting edit cancels the check")
            await startHeldCheck(state, worker: worker, cancelled: cancelled)
            XCTAssertEqual(state.resultLimit, 12)
            if changeWeight { state.locationWeight = 0.25 }
            else { state.resultLimit = 3 }
            assertNoGallery(state)
            await fulfillment(of: [cancelled], timeout: 3)
            await worker.release(.check)
            await state.waitUntilIdle()

            XCTAssertEqual(state.query, PhotoCheckFixtures.galleryQuery)
            XCTAssertEqual(state.locationWeight, changeWeight ? 0.25 : 0.6)
            XCTAssertEqual(state.resultLimit, changeWeight ? 12 : 3)
            XCTAssertFalse(state.allowICloudDownload)
            assertNoGallery(state)
            assertNoCheckResultOrError(state)
            XCTAssertFalse(state.isBusy)
            let observed = await worker.observations()
            XCTAssertEqual(observed.returnedChecks, 1)
            XCTAssertEqual(observed.cancelledChecks, 1)
        }
    }

    func testDismissingCompletedCheckClearsReportButPreservesGallery() async {
        let state = await completedCheckState()
        let before = GallerySnapshot(state)
        XCTAssertNotNil(state.photoCheckReport)
        state.dismissPhotoCheck()
        await state.waitUntilIdle()
        assertNoCheckResultOrError(state)
        assertGallery(state, matches: before)
        XCTAssertFalse(state.isBusy)
    }

    // MARK: Whole-operation serialization, including noninterruptible work

    func testRefreshCancelsAndWaitsForCheckBeforeWorkerRefresh() async {
        await assertRefreshWaitsForCheck(throughBackground: false)
    }

    func testForegroundRefreshWaitsForCancelledBackgroundCheck() async {
        await assertRefreshWaitsForCheck(throughBackground: true)
    }

    func testBackgroundCancelsCheckAndDoesNotStartWorkerRefreshUntilForeground() async {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let cancelled = expectation(description: "Background cancels the checking task")
        await startHeldCheck(state, worker: worker, cancelled: cancelled)
        state.enterBackground()
        state.refresh() // A refresh request while backgrounded must not call the worker.
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: "TEST FIXTURE blocked in background")
        assertNoGallery(state)
        await fulfillment(of: [cancelled], timeout: 3)
        let suspended = await worker.observations()
        XCTAssertEqual(suspended.refreshCount, 1)
        XCTAssertEqual(suspended.checkRequests.count, 1)
        XCTAssertEqual(suspended.finishedChecks, 0)
        await worker.release(.check)
        await state.waitUntilIdle()

        assertNoCheckResultOrError(state)
        XCTAssertFalse(state.isBusy)
        // Verify the foreground guard even after the old operation is no longer busy.
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        await state.waitUntilIdle()
        let background = await worker.observations()
        XCTAssertEqual(background.refreshCount, 1)
        XCTAssertEqual(background.checkRequests.count, 1)
        XCTAssertEqual(background.cancelledChecks, 1)
        XCTAssertEqual(background.returnedChecks, 1)

        state.enterForeground()
        await state.waitUntilIdle()
        let foreground = await worker.observations()
        XCTAssertEqual(foreground.refreshCount, 2)
        XCTAssertEqual(foreground.peakConcurrency, 1)
        XCTAssertEqual(state.query, PhotoCheckFixtures.galleryQuery)
        assertNoGallery(state)
        assertNoCheckResultOrError(state)
    }

    // MARK: Local errors and busy guards

    func testCheckErrorStaysLocalAndDoesNotDropGalleryOrSetGlobalError() async {
        let worker = PhotoCheckTestWorker(outcome: .failure)
        let state = await searchedState(worker: worker)
        let before = GallerySnapshot(state)
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        await state.waitUntilIdle()

        XCTAssertNil(state.photoCheckReport)
        XCTAssertFalse(state.photoCheckIssue?.isEmpty ?? true)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.actionHint)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.canSearch)
        assertGallery(state, matches: before)
        let observed = await worker.observations()
        XCTAssertEqual(observed.finishedChecks, 1)
        XCTAssertEqual(observed.returnedChecks, 0)
        XCTAssertEqual(observed.cancelledChecks, 0)
        state.dismissPhotoCheck()
        assertNoCheckResultOrError(state)
        assertGallery(state, matches: before)
    }

    func testLateCheckErrorAfterCancelDismissOrSheetEditIsNotPublished() async {
        for stop in [CheckStop.cancel, .dismiss, .sheetQueryEdit] {
            await assertLateCheckDiscarded(by: stop, outcome: .failure)
        }
    }

    func testBusyCheckRejectsDuplicateWithoutReplacingOriginalRequest() async throws {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let before = GallerySnapshot(state)
        await startHeldCheck(state, worker: worker)
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        state.checkPhoto(id: "photo-check-test-only-other-missing-id", query: "TEST FIXTURE other check")
        XCTAssertEqual(state.activity, .checkingPhoto)
        let suspended = await worker.observations()
        XCTAssertEqual(suspended.checkRequests.count, 1)
        XCTAssertEqual(suspended.finishedChecks, 0)
        await worker.release(.check)
        await state.waitUntilIdle()

        let observed = await worker.observations()
        let report = try XCTUnwrap(state.photoCheckReport)
        XCTAssertEqual(observed.checkRequests.count, 1)
        XCTAssertEqual(observed.cancelledChecks, 0, "A duplicate must not cancel the original check")
        XCTAssertEqual(observed.returnedChecks, 1)
        XCTAssertEqual(observed.peakConcurrency, 1)
        XCTAssertEqual(report.photoID, PhotoCheckFixtures.photoID)
        XCTAssertEqual(report.query, PhotoCheckFixtures.checkQuery)
        assertGallery(state, matches: before)
        XCTAssertNil(state.photoCheckIssue)
    }

    func testBusyRefreshRejectsCheckWithoutCancellingRefresh() async {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let started = expectation(description: "Replacement refresh is suspended")
        await worker.holdNext(.refresh, started: started)
        state.refresh()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(state.activity, .refreshing)
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: "TEST FIXTURE duplicate while refreshing")
        let suspended = await worker.observations()
        XCTAssertTrue(suspended.checkRequests.isEmpty)
        XCTAssertEqual(state.activity, .refreshing)
        await worker.release(.refresh)
        await state.waitUntilIdle()

        let observed = await worker.observations()
        XCTAssertTrue(observed.checkRequests.isEmpty)
        XCTAssertEqual(observed.refreshCount, 2)
        XCTAssertEqual(observed.cancelledRefreshes, 0)
        XCTAssertEqual(observed.peakConcurrency, 1)
        XCTAssertFalse(state.isBusy)
        assertNoCheckResultOrError(state)
    }

    // MARK: Exactly five screenshots, using production views and controls

    func testPhotoCheckIdleSnapshot() async throws {
        let state = await searchedState()
        let before = GallerySnapshot(state)
        assertNoCheckResultOrError(state)
        try await snapshot(PhotoCheckSheet(state: state, photoID: PhotoCheckFixtures.photoID,
                                          initialQuery: PhotoCheckFixtures.checkQuery),
                           id: "idle", size: phone)
        assertGallery(state, matches: before)
    }

    func testPhotoCheckCompletedDifferentRankAnd64PixelReportSnapshot() async throws {
        let state = await completedCheckState()
        let report = try XCTUnwrap(state.photoCheckReport)
        XCTAssertEqual(report.cachedRank, 16)
        XCTAssertEqual(report.freshRank, 1)
        XCTAssertEqual(report.requestedWidth, 224)
        XCTAssertEqual(report.requestedHeight, 398)
        XCTAssertEqual(report.pixelWidth, 64)
        XCTAssertEqual(report.pixelHeight, 114)
        XCTAssertEqual(report.degraded, true)
        XCTAssertEqual(report.source, "localReducedPreview")
        XCTAssertNil(report.freshIssue)
        try await snapshot(PhotoCheckSheet(state: state, photoID: report.photoID, initialQuery: report.query),
                           id: "completed-fresh-rank-64px", size: phone)
    }

    func testPhotoCheckCompletedUnknownHistoricalInputAndLocalFailureSnapshot() async throws {
        let state = await completedCheckState(outcome: .localPreviewUnavailable)
        let report = try XCTUnwrap(state.photoCheckReport)
        XCTAssertEqual(report.cachedRank, 16)
        XCTAssertNil(report.freshRank)
        XCTAssertNil(report.freshScore)
        XCTAssertNil(report.cachedFreshCosine)
        XCTAssertNil(report.requestedWidth)
        XCTAssertNil(report.requestedHeight)
        XCTAssertNil(report.pixelWidth)
        XCTAssertNil(report.pixelHeight)
        XCTAssertNil(report.degraded)
        XCTAssertNil(report.source)
        XCTAssertNotNil(report.freshIssue)
        XCTAssertNil(state.photoCheckIssue, "A completed report can describe an unavailable fresh preview")
        XCTAssertNil(state.errorMessage)
        // Historical input dimensions are never present in this report contract.
        // Do not invent cached pixel sizes from a fresh failure or from a rank.
        // Advanced details retains its real, initially collapsed disclosure state.
        try await snapshot(PhotoCheckSheet(state: state, photoID: report.photoID, initialQuery: report.query),
                           id: "completed-unknown-history-local-failure", size: phone)
    }

    func testPhotoCheckLargeDynamicTypeSnapshot() async throws {
        let state = await completedCheckState()
        let report = try XCTUnwrap(state.photoCheckReport)
        try await snapshot(PhotoCheckSheet(state: state, photoID: report.photoID, initialQuery: report.query),
                           id: "accessibility-large", size: compactPhone, dynamicTypeSize: .accessibility1)
    }

    func testViewerBottomCheckButtonWithMissingPhotoAndNoPhotosPermissionSnapshot() async throws {
        // Never request/revoke permission or inspect a real asset. With no real
        // read permission, currentRevision short-circuits before any PHAsset fetch.
        try XCTSkipIf(PhotoLibraryClient.canRead, "Use an app test host without Photos read permission; do not change the user's permissions.")
        let authorizationBefore = PhotoLibraryClient.authorization
        let worker = PhotoCheckTestWorker()
        let state = AppState(worker: worker, authorizationStatus: { .notDetermined })
        XCTAssertFalse(state.debugToolsEnabled)
        state.debugToolsEnabled = true // This snapshot explicitly reviews the debug-only viewer control.
        let hit = PhotoCheckFixtures.hits[0]
        XCTAssertFalse(state.canRead)
        XCTAssertNil(state.library.currentRevision(id: hit.id))
        // This captures the real viewer's unavailable-photo state and disabled
        // bottom Check this photo control, NOT a successful preview/check action.
        try await snapshot(PhotoResultsViewer(hits: [hit], initialID: hit.id, library: state.library,
                                              networkAllowed: false, state: state),
                           id: "viewer-bottom-check-missing-asset", size: phone)
        XCTAssertEqual(PhotoLibraryClient.authorization, authorizationBefore)
        let observed = await worker.observations()
        XCTAssertTrue(observed.checkRequests.isEmpty)
        XCTAssertTrue(observed.searchRequests.isEmpty)
        XCTAssertEqual(observed.refreshCount, 0)
        XCTAssertEqual(observed.indexCalls, 0)
        XCTAssertEqual(observed.clearCalls, 0)
    }

    // MARK: State helpers

    private enum CheckStop { case cancel, dismiss, sheetQueryEdit }

    private func readyState(worker: PhotoCheckTestWorker) async -> AppState {
        // Injected authorization only gates AppState. It does not grant PhotoKit access.
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        XCTAssertFalse(state.debugToolsEnabled)
        state.debugToolsEnabled = true // Positive diagnostic contracts opt in; production defaults stay off.
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.summary.indexedCount, 512)
        XCTAssertNil(state.errorMessage)
        return state
    }

    private func searchedState(worker: PhotoCheckTestWorker = PhotoCheckTestWorker()) async -> AppState {
        let state = await readyState(worker: worker)
        await completeSearch(state)
        return state
    }

    private func completeSearch(_ state: AppState) async {
        state.query = PhotoCheckFixtures.galleryQuery
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.completedQuery, PhotoCheckFixtures.galleryQuery)
        XCTAssertEqual(state.results.count, state.resultLimit)
        XCTAssertEqual(state.results.map(\.id), Array(PhotoCheckFixtures.hits.prefix(state.resultLimit)).map(\.id))
        XCTAssertEqual(state.totalResultCount, PhotoCheckFixtures.hits.count,
                       "The initial page must not discard the rest of the worker's ranking")
        XCTAssertTrue(state.hasMoreResults)
        state.selection = state.results.first.map { AppState.Selection(id: $0.id) }
        XCTAssertNotNil(state.selection)
    }

    private func completedCheckState(outcome: PhotoCheckTestWorker.Outcome = .fresh) async -> AppState {
        let state = await searchedState(worker: PhotoCheckTestWorker(outcome: outcome))
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        await state.waitUntilIdle()
        XCTAssertNotNil(state.photoCheckReport)
        XCTAssertFalse(state.isBusy)
        return state
    }

    private func startHeldCheck(_ state: AppState, worker: PhotoCheckTestWorker,
                                cancelled: XCTestExpectation? = nil) async {
        let started = expectation(description: "Check reached its continuation")
        await worker.holdNext(.check, started: started, cancelled: cancelled)
        state.checkPhoto(id: PhotoCheckFixtures.photoID, query: PhotoCheckFixtures.checkQuery)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(state.activity, .checkingPhoto)
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.photoCheckReport)
        XCTAssertNil(state.photoCheckIssue)
    }

    private func assertLateCheckDiscarded(by stop: CheckStop,
                                         outcome: PhotoCheckTestWorker.Outcome = .fresh) async {
        let worker = PhotoCheckTestWorker(outcome: outcome)
        let state = await searchedState(worker: worker)
        let before = GallerySnapshot(state)
        let cancelled = expectation(description: "Check cancellation reached the suspended worker")
        await startHeldCheck(state, worker: worker, cancelled: cancelled)
        switch stop {
        case .cancel:
            state.cancel()
        case .dismiss:
            state.dismissPhotoCheck() // Done, sheet disappearance and viewer close use this API.
        case .sheetQueryEdit:
            // Deliberately mimic PhotoCheckSheet's private @State query/onChange,
            // not AppState.query: a local edit must retain the gallery's search.
            var sheetQuery = PhotoCheckFixtures.checkQuery
            sheetQuery.append(" edited")
            XCTAssertNotEqual(sheetQuery, PhotoCheckFixtures.checkQuery)
            state.dismissPhotoCheck() // Must happen BEFORE releasing the late result.
        }
        await fulfillment(of: [cancelled], timeout: 3)
        assertGallery(state, matches: before)
        assertNoCheckResultOrError(state)
        let suspended = await worker.observations()
        XCTAssertEqual(suspended.finishedChecks, 0)
        // No throwing unwraps between suspension and release: failures must not
        // strand the continuation. The fake intentionally ignores cancellation.
        await worker.release(.check)
        await state.waitUntilIdle()

        assertGallery(state, matches: before)
        assertNoCheckResultOrError(state)
        XCTAssertFalse(state.isBusy)
        let observed = await worker.observations()
        XCTAssertEqual(observed.checkRequests.count, 1)
        XCTAssertEqual(observed.finishedChecks, 1)
        XCTAssertEqual(observed.cancelledChecks, 1)
        XCTAssertEqual(observed.returnedChecks, outcome == .failure ? 0 : 1)
        XCTAssertEqual(observed.refreshCount, 1)
        XCTAssertEqual(observed.peakConcurrency, 1)
    }

    private func assertRefreshWaitsForCheck(throughBackground: Bool) async {
        let worker = PhotoCheckTestWorker()
        let state = await searchedState(worker: worker)
        let cancelled = expectation(description: "Replacement cancels the suspended check")
        await startHeldCheck(state, worker: worker, cancelled: cancelled)
        if throughBackground {
            state.enterBackground()
            assertNoGallery(state)
            state.enterForeground()
        } else {
            state.refresh()
        }
        XCTAssertEqual(state.activity, .refreshing)
        assertNoGallery(state)
        assertNoCheckResultOrError(state)
        await fulfillment(of: [cancelled], timeout: 3)
        let suspended = await worker.observations()
        XCTAssertEqual(suspended.finishedChecks, 0)
        XCTAssertEqual(suspended.refreshCount, 1, "Replacement must wait, not just cancel the check")
        await worker.release(.check)
        await state.waitUntilIdle()

        let observed = await worker.observations()
        XCTAssertEqual(observed.refreshCount, 2)
        XCTAssertEqual(observed.cancelledChecks, 1)
        XCTAssertEqual(observed.returnedChecks, 1)
        XCTAssertEqual(observed.peakConcurrency, 1)
        // A final ordering assertion catches overlap even if a premature worker
        // refresh happened just after the earlier observation, before release.
        XCTAssertEqual(observed.events, ["refresh.begin", "refresh.end", "search.begin", "search.end",
                                         "check.begin", "check.release", "check.end", "refresh.begin", "refresh.end"])
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.query, PhotoCheckFixtures.galleryQuery)
        XCTAssertEqual(state.summary.indexedCount, 512)
        assertNoGallery(state)
        assertNoCheckResultOrError(state)
    }

    @MainActor
    private struct GallerySnapshot {
        let query: [UInt8]
        let completedQuery: [UInt8]?
        let hits: [SearchHit]
        let selectionID: String?
        let summary: LibrarySummary
        let progress: IndexProgress
        let authorization: PHAuthorizationStatus
        let resultLimit: Int
        let locationWeight: Double
        let allowICloudDownload: Bool

        init(_ state: AppState) {
            query = Array(state.query.utf8)
            completedQuery = state.completedQuery.map { Array($0.utf8) }
            hits = state.results
            selectionID = state.selection?.id
            summary = state.summary
            progress = state.progress
            authorization = state.authorization
            resultLimit = state.resultLimit
            locationWeight = state.locationWeight
            allowICloudDownload = state.allowICloudDownload
        }
    }

    private func assertGallery(_ state: AppState, matches before: GallerySnapshot,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(state.query.utf8), before.query, file: file, line: line)
        XCTAssertEqual(state.completedQuery.map { Array($0.utf8) }, before.completedQuery, file: file, line: line)
        XCTAssertEqual(state.selection?.id, before.selectionID, file: file, line: line)
        XCTAssertEqual(state.results.map(\.id), before.hits.map(\.id), file: file, line: line)
        XCTAssertEqual(state.results.map(\.score), before.hits.map(\.score), file: file, line: line)
        XCTAssertEqual(state.results.map(\.photo.imageEmbedding), before.hits.map(\.photo.imageEmbedding), file: file, line: line)
        XCTAssertEqual(state.results.map(\.photo.modificationTime), before.hits.map(\.photo.modificationTime), file: file, line: line)
        XCTAssertEqual(state.results.map(\.photo.creationTime), before.hits.map(\.photo.creationTime), file: file, line: line)
        XCTAssertEqual(state.results.map(\.photo.modelVersion), before.hits.map(\.photo.modelVersion), file: file, line: line)
        XCTAssertEqual(state.results.map { $0.photo.location?.text }, before.hits.map { $0.photo.location?.text }, file: file, line: line)
        XCTAssertEqual(state.results.map { $0.photo.location?.vector }, before.hits.map { $0.photo.location?.vector }, file: file, line: line)
        XCTAssertEqual(state.summary.authorizedCount, before.summary.authorizedCount, file: file, line: line)
        XCTAssertEqual(state.summary.indexedCount, before.summary.indexedCount, file: file, line: line)
        XCTAssertEqual(state.summary.locatedCount, before.summary.locatedCount, file: file, line: line)
        XCTAssertEqual(state.summary.modelVersion, before.summary.modelVersion, file: file, line: line)
        XCTAssertEqual(state.summary.modelIssue, before.summary.modelIssue, file: file, line: line)
        XCTAssertEqual(state.summary.placesDescription, before.summary.placesDescription, file: file, line: line)
        XCTAssertEqual(state.progress, before.progress, file: file, line: line)
        XCTAssertEqual(state.authorization, before.authorization, file: file, line: line)
        XCTAssertEqual(state.resultLimit, before.resultLimit, file: file, line: line)
        XCTAssertEqual(state.locationWeight, before.locationWeight, file: file, line: line)
        XCTAssertEqual(state.allowICloudDownload, before.allowICloudDownload, file: file, line: line)
    }

    private func assertNoGallery(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
    }

    private func assertNoCheckResultOrError(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.photoCheckReport, file: file, line: line)
        XCTAssertNil(state.photoCheckIssue, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertNil(state.actionHint, file: file, line: line)
    }

    // MARK: Native window hosting, matching PresentationTests' lifecycle

    private func snapshot<Content: View>(_ content: Content, id: String, size: CGSize,
                                         dynamicTypeSize: DynamicTypeSize = .large) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native captures require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        let root = content
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = PhotoCheckHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        let laidOut = expectation(description: "\(id): native phone-size layout")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == size else { return }
            host.onLayout = nil
            laidOut.fulfill()
        }
        defer {
            host.onLayout = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)

        let settled = expectation(description: "\(id): pending native layout updates completed")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(host.view.bounds.size, size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drewHierarchy = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "UIKit must draw the actual hosted production view")
        XCTAssertEqual(image.size, size)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int(size.width))
        XCTAssertEqual(pixels.height, Int(size.height))
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-photo-check-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Dimensions do not prove clipping, control hit-testing, scrolling or
        // real-photo behavior. These five native images require human review.
    }
}

@MainActor
private final class PhotoCheckHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private enum PhotoCheckFixtures {
    static let modelVersion = "photo-check-test-only|synthetic-preview-policy"
    static let galleryQuery = "TEST FIXTURE gallery memory"
    static let checkQuery = "TEST FIXTURE missed photo"
    static let photoID = "photo-check-test-only-never-a-PHAsset-0"
    static let summary = LibrarySummary(authorizedCount: 512, indexedCount: 512, modelVersion: modelVersion,
                                        placesDescription: "TEST FIXTURE: no offline places")

    static let hits: [SearchHit] = (0..<512).map { index in
        let vector = TestFixtures.vector(axis: index)
        let photo = IndexedPhoto(id: "photo-check-test-only-never-a-PHAsset-\(index)", modificationTime: 123,
                                 modelVersion: modelVersion, imageEmbedding: vector, creationTime: 100)
        return SearchHit(photo: photo, score: Float(512 - index) / 1024)
    }

    static func report(id: String, query: String, weight: Float, freshUnavailable: Bool) -> PhotoDiagnosticReport {
        var report = PhotoDiagnosticReport(photoID: id, query: query, locationWeight: weight, galleryCount: hits.count,
                                           modelVersion: modelVersion, cachedStatus: "current")
        // Presentation scalars, not a ranking-algorithm test. Gallery and check
        // queries intentionally differ, so the selected search hit can check #16.
        report.cachedRank = 16
        report.cachedScore = 0.098
        if freshUnavailable {
            report.freshIssue = "No local preview is available. iCloud download is off."
        } else {
            report.freshRank = 1
            report.freshScore = 0.127
            report.cachedFreshCosine = 0.81
            report.requestedWidth = 224
            report.requestedHeight = 398
            report.pixelWidth = 64
            report.pixelHeight = 114
            report.orientationRawValue = 1
            report.degraded = true
            report.source = "localReducedPreview"
        }
        return report
    }
}

/// Actor reentrancy permits overlap while held. Peak activity and event order
/// therefore test AppState serialization, not accidental serialization by a fake.
/// Cancellation is observed but deliberately does not resume the continuation:
/// the test must release noninterruptible work, which still returns/throws late.
private actor PhotoCheckTestWorker: PhotoWorkServicing {
    enum Operation: String, Hashable, Sendable { case check, refresh, search }
    enum Outcome: Equatable, Sendable { case fresh, localPreviewUnavailable, failure }

    struct CheckRequest: Sendable {
        let id: String
        let query: String
        let locationWeight: Float
    }

    struct SearchRequest: Sendable {
        let text: String
        let limit: Int
        let locationWeight: Float
    }

    struct Observations: Sendable {
        var checkRequests: [CheckRequest] = []
        var searchRequests: [SearchRequest] = []
        var refreshCount = 0
        var returnedChecks = 0
        var finishedChecks = 0
        var cancelledChecks = 0
        var cancelledRefreshes = 0
        var peakConcurrency = 0
        var indexCalls = 0
        var clearCalls = 0
        var events: [String] = []
    }

    private struct Hold: Sendable {
        let started: XCTestExpectation
        let cancelled: XCTestExpectation?
    }

    private let outcome: Outcome
    private var observed = Observations()
    private var active = 0
    private var holds: [Operation: Hold] = [:]
    private var continuations: [Operation: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Operation> = []

    init(outcome: Outcome = .fresh) { self.outcome = outcome }

    func observations() -> Observations { observed }

    func holdNext(_ operation: Operation, started: XCTestExpectation, cancelled: XCTestExpectation? = nil) {
        holds[operation] = Hold(started: started, cancelled: cancelled)
        released.remove(operation)
    }

    func release(_ operation: Operation) {
        observed.events.append("\(operation.rawValue).release")
        released.insert(operation)
        let pending = continuations.removeValue(forKey: operation)
        pending?.resume()
    }

    private func waitIfHeld(_ operation: Operation) async {
        guard let hold = holds.removeValue(forKey: operation) else { return }
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if released.contains(operation) { continuation.resume() }
                else { continuations[operation] = continuation }
                hold.started.fulfill()
            }
        }, onCancel: {
            hold.cancelled?.fulfill()
        })
    }

    private func begin(_ operation: Operation) {
        active += 1
        observed.peakConcurrency = max(observed.peakConcurrency, active)
        observed.events.append("\(operation.rawValue).begin")
    }

    private func finish(_ operation: Operation) {
        observed.events.append("\(operation.rawValue).end")
        active -= 1
    }

    func refresh() async throws -> LibrarySummary {
        begin(.refresh)
        defer { finish(.refresh) }
        observed.refreshCount += 1
        await waitIfHeld(.refresh)
        if Task.isCancelled { observed.cancelledRefreshes += 1 }
        return PhotoCheckFixtures.summary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        begin(.search)
        defer { finish(.search) }
        observed.searchRequests.append(SearchRequest(text: text, limit: limit, locationWeight: locationWeight))
        // Honor the worker request: AppState must ask for all 512 candidates
        // with Int.max, then expose only its initial display-page prefix.
        return SearchResponse(summary: PhotoCheckFixtures.summary, hits: Array(PhotoCheckFixtures.hits.prefix(limit)))
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        begin(.check)
        defer { observed.finishedChecks += 1; finish(.check) }
        observed.checkRequests.append(CheckRequest(id: id, query: query, locationWeight: locationWeight))
        await waitIfHeld(.check)
        if Task.isCancelled { observed.cancelledChecks += 1 }
        if outcome == .failure { throw AppFailure.photo("TEST FIXTURE check failure") }
        let report = PhotoCheckFixtures.report(id: id, query: query, weight: locationWeight,
                                               freshUnavailable: outcome == .localPreviewUnavailable)
        observed.returnedChecks += 1
        return report
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        observed.indexCalls += 1
        XCTFail("Photo check presentation tests must never start indexing")
        throw AppFailure.storage("TEST FIXTURE: indexing is not supported")
    }

    func clear() async throws -> LibrarySummary {
        observed.clearCalls += 1
        XCTFail("Photo check presentation tests must never clear the index")
        throw AppFailure.storage("TEST FIXTURE: clearing is not supported")
    }
}