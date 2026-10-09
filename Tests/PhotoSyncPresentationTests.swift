import XCTest
import SwiftUI
import UIKit
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// Native presentation tests. Counters come through PhotoSyncServicing,
/// never private-set assignment or AppState.start(). Gates always drain in
/// teardown. Captures are actual UIKit UIImages, not generated screen artwork.
@MainActor
final class PhotoSyncPresentationTests: XCTestCase {
    func testV5ExactCompactLabelAndRealRingPixelsChangeWithoutMovingViewportOrTextBaseline() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 38,
            completed: 12, encoded: 10, failed: 1, needsNetwork: 1))
        let (state, service) = makeSync([run])
        let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)))
        defer { host.close() }
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).compactTitle, "同步最新照片12/38")
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, Double(12) / 38)
        try assertCardGeometry(host, cancel: true)
        let card = try XCTUnwrap(host.sync[.card])
        let text = try XCTUnwrap(host.sync[.text])
        let reservation = try XCTUnwrap(host.sync[.reservation])
        XCTAssertEqual(card.width, 224, accuracy: host.pixel)
        XCTAssertEqual(card.height, 44, accuracy: host.pixel)
        XCTAssertEqual(reservation.height, 52, accuracy: host.pixel)
        let scroll = try host.overviewScroll()
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        let initialRing = try ringPixels(host)
        try host.attach(to: self, name: "UIReview-sync-capsule-v1")

        await service.report(PhotoSyncProgress(phase: .updating, total: 38,
            completed: 19, encoded: 17, failed: 1, needsNetwork: 1))
        try await host.settle()
        XCTAssertEqual(PhotoSyncToast(state: state).compactTitle, "同步最新照片19/38")
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0.5)
        XCTAssertEqual(host.sync[.card], card)
        XCTAssertEqual(host.sync[.text], text, "Monospaced counts must not move or animate the text baseline")
        XCTAssertEqual(host.sync[.reservation], reservation)
        XCTAssertEqual(scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window), usable)
        XCTAssertNotEqual(try ringPixels(host), initialRing,
                          "Native pixels cropped to the ring, not changed counter text or a fake bar")
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    func testCoveredCapsuleKeepsBlankReservationWithoutControlsAndDoesNotCancelOrRetryFailure() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 38, completed: 12),
                                      outcome: .failure)
        let (state, service) = makeSync([run])
        let visibility = SyncVisibilityControl()
        let host = try ControlsNativeHost(content: AnyView(SyncVisibilityFixture(state: state, visibility: visibility)))
        defer { host.close() }
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        try await host.wait { host.sync[.card] != nil }
        let reservation = try XCTUnwrap(host.sync[.reservation])
        let tab = try XCTUnwrap(host.tabs[.search])
        visibility.isPresented = false
        try await host.wait { host.sync[.card] == nil }
        XCTAssertEqual(host.sync[.reservation], reservation)
        XCTAssertEqual(host.tabs[.search], tab)
        XCTAssertNil(host.sync[.mainAction])
        XCTAssertNil(host.sync[.action])
        XCTAssertNil(host.sync[.text])
        XCTAssertNil(host.sync[.progress])
        XCTAssertTrue(state.canCancel)
        XCTAssertEqual(state.phase, .updating, "Covering the capsule is not cancelling the task")
        run.release.open()
        await state.waitUntilIdle()
        try await host.settle()
        XCTAssertEqual(state.phase, .failed, "A real covered failure is not disguised as user cancellation")
        XCTAssertNil(host.sync[.card])
        visibility.isPresented = true
        try await host.wait { host.sync[.card] != nil }
        try assertCardGeometry(host, cancel: false)
        XCTAssertEqual(host.sync[.reservation], reservation)
        XCTAssertTrue(state.canRestart)
        let calls = await service.calls
        XCTAssertEqual(calls, 1, "Showing details/capsule never automatically retries a failure")
    }

    func testDetailMountAndDismissDoNotStopWorkAndCancellationStillWaitsForDrain() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 38, completed: 12, encoded: 12))
        let (state, service) = makeSync([run])
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        let host = try ControlsNativeHost(content: AnyView(PhotoSyncDetailSheet(state: state)))
        defer { host.close() }
        try await host.wait { !controlsDescendants(host.controller.view, UIScrollView.self).isEmpty }
        host.close() // Actual native detail view unmount, not a worker pause.
        await service.report(PhotoSyncProgress(phase: .updating, total: 38, completed: 13, encoded: 13))
        XCTAssertEqual(state.phase, .updating)
        XCTAssertEqual(state.progress.completed, 13)
        XCTAssertTrue(state.canCancel)
        state.cancel()
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertFalse(state.canCancel)
        XCTAssertFalse(state.canRestart)
        await service.report(PhotoSyncProgress(phase: .updating, total: 38, completed: 14, encoded: 14))
        XCTAssertEqual(state.phase, .cancelling, "A late actual commit cannot report that draining has finished")
        XCTAssertEqual(state.progress.encoded, 14)
        run.release.open()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(state.canRestart)
        XCTAssertEqual(state.progress.encoded, 14)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        // This tests mounted detail lifecycle + real service drain. Actual
        // SwiftUI button taps/sheet gestures remain separate XCUI coverage.
    }

    func testFullSafeFailureDiagnosticRemainsReachableInScrollableMaximumTypeDetail() async throws {
        let diagnostic = PhotoSyncDiagnostic(stage: .encoding, code: .invalidPhotoMetadata,
                                              metadataField: .modificationTime)
        let progress = PhotoSyncProgress(phase: .updating, total: 38, completed: 12,
                                         encoded: 10, removed: 3, failed: 1, needsNetwork: 1)
        let run = PresentationSyncRun(initial: progress, outcome: .diagnostic(diagnostic))
        let (state, service) = makeSync([run])
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        run.release.open()
        await state.waitUntilIdle()
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.progress, progress)
        XCTAssertEqual(state.failureDiagnostic, diagnostic)
        XCTAssertEqual(PhotoSyncToast(state: state).detail, diagnostic.message)
        XCTAssertEqual(PhotoSyncDetailSheet(state: state).summary, diagnostic.message)
        XCTAssertTrue(PhotoSyncToast(state: state).detail.contains("SS-ENCODING-PHOTO-METADATA-MTIME"))
        let host = try ControlsNativeHost(content: AnyView(PhotoSyncDetailSheet(state: state)),
            size: CGSize(width: 320, height: 568), dynamicType: .accessibility5)
        defer { host.close() }
        try await host.wait { !controlsDescendants(host.controller.view, UIScrollView.self).isEmpty }
        _ = try host.capture() // Realize native text before measuring scroll content.
        let scroll = try host.overviewScroll()
        let usableHeight = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
        XCTAssertGreaterThan(scroll.contentSize.height, usableHeight)
        try host.attach(to: self, name: "UIReview-sync-capsule-v1-full-diagnostic-detail-top")
        let before = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: before.x,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await host.settle()
        XCTAssertGreaterThan(scroll.contentOffset.y, before.y)
        XCTAssertEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
                       scroll.contentSize.height, accuracy: host.pixel)
        try host.attach(to: self, name: "UIReview-sync-capsule-v1-full-diagnostic-detail-bottom")
        XCTAssertTrue(state.canRestart)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
    }

    func testSmallWorkingAndCancelledCardObservesSubstateAndReservesBottomSpace() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 8,
            completed: 2, encoded: 2, removed: 3))
        let (state, _) = makeSync([run])
        let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)),
                                         size: CGSize(width: 320, height: 568))
        defer { host.close() }
        try await host.wait { !host.tabs.isEmpty }
        XCTAssertNil(host.sync[.card], "The non-observing parent mounts an initially idle child")
        let idleReservation = try XCTUnwrap(host.sync[.reservation])
        XCTAssertEqual(idleReservation.height, 52, accuracy: host.pixel)
        XCTAssertNil(host.sync[.mainAction])
        XCTAssertNil(host.sync[.action])
        let idleTab = try XCTUnwrap(host.tabs[.search])
        let scroll = try host.overviewScroll()
        let idleUsable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0.25)
        XCTAssertEqual(PhotoSyncToast(state: state).title, "正在同步照片")
        XCTAssertEqual(PhotoSyncToast(state: state).compactTitle, "同步最新照片2/8")
        XCTAssertEqual(state.progress.removed, 3)
        try assertCardGeometry(host, cancel: true)
        XCTAssertEqual(try XCTUnwrap(host.sync[.card]).width, 224, accuracy: host.pixel)
        XCTAssertEqual(try XCTUnwrap(host.sync[.card]).height, 44, accuracy: host.pixel)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
        XCTAssertEqual(host.tabs[.search], idleTab)
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        XCTAssertEqual(usable, idleUsable, "Starting sync must not change the photo viewport")
        XCTAssertLessThanOrEqual(usable.maxY, try XCTUnwrap(host.sync[.card]).minY + host.pixel)
        let start = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: start.x,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await host.settle()
        XCTAssertGreaterThan(scroll.contentOffset.y, start.y)
        XCTAssertEqual(scroll.contentOffset.x, start.x, accuracy: host.pixel)
        XCTAssertEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
                       scroll.contentSize.height, accuracy: host.pixel)
        try host.attach(to: self, name: "UIReview-sync-capsule-v1-working-small")

        state.cancel()
        try await host.wait { host.sync[.progress] == nil }
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertFalse(state.canCancel)
        XCTAssertFalse(state.canRestart, "A held backend is not already stopped")
        run.release.open()
        await state.waitUntilIdle()
        try await host.settle()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertEqual(state.progress.completed, 2)
        XCTAssertEqual(PhotoSyncToast(state: state).title, "同步已取消")
        XCTAssertNil(PhotoSyncToast(state: state).fraction)
        XCTAssertNil(host.sync[.progress])
        XCTAssertTrue(state.canRestart)
        try assertCardGeometry(host, cancel: false)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
        XCTAssertEqual(host.tabs[.search], idleTab)
        try host.attach(to: self, name: "UIReview-sync-capsule-v1-cancelled-small")
    }

    func testUnknownTotalsMaximumTypeAndExplicitRestartUseOnlyBackendProgress() async throws {
        let first = PresentationSyncRun()
        let second = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 4))
        let (state, service) = makeSync([first, second])
        let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)),
            size: CGSize(width: 320, height: 852), dynamicType: .accessibility5)
        defer { host.close() }
        try await host.wait { host.sync[.reservation] != nil }
        let idleReservation = try XCTUnwrap(host.sync[.reservation])
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(first.entered)
        try await host.wait { host.sync[.card] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).title, "正在检查照片")
        XCTAssertNil(host.sync[.progress])
        try assertCardGeometry(host, cancel: true)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
        XCTAssertGreaterThan(try XCTUnwrap(host.sync[.card]).height, 44)
        XCTAssertEqual(try XCTUnwrap(host.sync[.card]).width, 312, accuracy: host.pixel)
        await service.report(PhotoSyncProgress(phase: .updating, total: nil, completed: 0))
        try await host.settle()
        XCTAssertNil(PhotoSyncToast(state: state).fraction)
        XCTAssertNil(host.sync[.progress], "An updating phase alone is not a known denominator")
        await service.report(PhotoSyncProgress(phase: .updating, total: 8, completed: 3, encoded: 3))
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0.375)
        try assertCardGeometry(host, cancel: true)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
        await service.report(PhotoSyncProgress(phase: .updating, total: 38, completed: 12, encoded: 12))
        try await host.settle()
        XCTAssertEqual(PhotoSyncToast(state: state).compactTitle, "同步最新照片12/38")
        try assertCardGeometry(host, cancel: true)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
        state.cancel()
        first.release.open()
        await state.waitUntilIdle()
        state.libraryChanged()
        state.updateAvailability(ready: false, networkAllowed: false)
        try await host.settle()
        XCTAssertFalse(state.canRestart)
        state.updateAvailability(ready: true, networkAllowed: false)
        try await host.settle()
        XCTAssertTrue(state.canRestart, "Readiness publishes independently even when phase stays cancelled")
        XCTAssertEqual(state.phase, .cancelled)
        let before = await service.calls
        XCTAssertEqual(before, 1, "Rendering/ordinary readiness cannot auto-restart user cancellation")
        try assertCardGeometry(host, cancel: false)
        state.restart()
        try await reached(second.entered)
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(state.progress.total, 4)
        XCTAssertEqual(state.progress.completed, 0)
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0)
        XCTAssertEqual(host.sync[.reservation], idleReservation)
    }

    func testCompletedAutoHideAndPartialOrFailedStatesNeverShowFakeFullProgress() async throws {
        let completed = PhotoSyncProgress(phase: .updating, total: 8, completed: 8, encoded: 8, removed: 2)
        let partial = PhotoSyncProgress(phase: .updating, total: 8, completed: 8, encoded: 6, failed: 1, needsNetwork: 1)
        for (outcome, expected) in [(PresentationSyncRun.Outcome.success(completed), PhotoSyncState.Phase.completed),
                                    (.success(partial), .needsAttention), (.failure, .failed)] {
            let run = PresentationSyncRun(outcome: outcome)
            let delay = PresentationSyncGate()
            let delayEntered = XCTestExpectation(description: "Completion visibility delay entered")
            let (state, _) = makeSync([run], delay: delay, delayEntered: delayEntered)
            let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)))
            defer { host.close() }
            try await host.wait { host.sync[.reservation] != nil }
            let idleReservation = try XCTUnwrap(host.sync[.reservation])
            let idleTab = try XCTUnwrap(host.tabs[.search])
            state.updateAvailability(ready: true, networkAllowed: false)
            try await reached(run.entered)
            run.release.open()
            await state.waitUntilIdle()
            try await host.wait { host.sync[.card] != nil }
            XCTAssertEqual(state.phase, expected)
            XCTAssertNil(PhotoSyncToast(state: state).fraction)
            XCTAssertNil(host.sync[.progress])
            XCTAssertEqual(host.sync[.reservation], idleReservation)
            XCTAssertEqual(host.tabs[.search], idleTab)
            XCTAssertNotNil(host.sync[.mainAction], "Completion and failure still open real details")
            if expected == .completed {
                XCTAssertEqual(PhotoSyncToast(state: state).title, "照片已同步")
                XCTAssertEqual(PhotoSyncDetailSheet(state: state).summary, "本次已写入8张照片索引，移除2条失效索引。")
                XCTAssertNil(host.sync[.action])
                try await reached(delayEntered)
                delay.open()
                try await host.wait { !state.visible && host.sync[.card] == nil }
                XCTAssertEqual(host.sync[.reservation], idleReservation)
                XCTAssertEqual(host.tabs[.search], idleTab)
                XCTAssertNil(host.sync[.mainAction])
            } else {
                XCTAssertNil(host.sync[.action], "Retry is explicit inside details, not a capsule tap")
                XCTAssertTrue(state.canRestart)
                XCTAssertTrue(state.visible)
                if expected == .needsAttention {
                    XCTAssertEqual(PhotoSyncToast(state: state).title, "部分照片需要联网")
                    XCTAssertEqual(PhotoSyncDetailSheet(state: state).summary,
                                   "本次已写入6张照片索引，1张需联网，1张处理失败。可手动重新同步。")
                } else {
                    XCTAssertEqual(PhotoSyncToast(state: state).title, "照片同步未完成")
                }
            }
        }
    }

    func testProductionRootSharesOneCardPreservesSearchOnIndexCommitAndExcludesCleanupModalAndKeyboard() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 8, completed: 2, encoded: 2))
        let access = IndexAccessCoordinator()
        let service = PresentationSyncService(runs: [run])
        let f = try await controlsFixture(in: self, sync: service, indexAccess: access)
        addTeardownBlock { @MainActor in
            f.app.photoSync.cancel(); run.release.open()
            await f.app.waitForSync()
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        }
        f.app.query = "TEST retained search"
        let query = f.app.query
        f.app.search()
        await f.app.waitUntilIdle()
        f.app.setSelectingResults(true)
        let selected = try XCTUnwrap(f.app.results.first?.id)
        f.app.toggleResultSelection(selected)
        let searchSession = f.app.resultSessionID
        let photosEpoch = f.app.photoLibraryEpoch
        let results = f.app.results.map(\.id)
        // Seed synthetic browsing before the root can defer cleanup for sync.
        // This uses the same no-Photos service, never a production guard override.
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        XCTAssertTrue(f.cleanup.hasScanned)
        XCTAssertTrue(f.cleanup.canSelect)
        let prepCount = f.grouping.thresholds.count
        XCTAssertEqual(prepCount, 1)
        let groupIDs = f.cleanup.displayGroups.map(\.id)
        let cleanupSession = try XCTUnwrap(f.cleanup.selectionSessionID)
        let cleanupSelected = try XCTUnwrap(f.cleanup.displayGroups.first?.photos.first?.id)
        f.cleanup.toggleSelection(cleanupSelected)
        XCTAssertEqual(f.cleanup.selectedIDs, Set([cleanupSelected]))
        let host = try ControlsNativeHost(content: AnyView(ContentView(state: f.app,
            similarCleanupState: f.cleanup, navigation: f.navigation, cleanupPreferences: nil)))
        defer { host.close() }
        try await host.wait { host.hasRootBottomFrame(.selectionToolbar) }
        let beforeToast = try host.rootSelectionToolbarFrame()
        let beforePreference = host.sync[.selectionToolbar]
        let idleReservation = try host.rootBottomFrame(.syncToast)
        XCTAssertEqual(idleReservation.height, 52, accuracy: host.pixel)
        XCTAssertNil(host.sync[.card])
        XCTAssertNil(host.sync[.mainAction])
        try host.attachRootSyncWindow(to: self, name: "UIReview-sync-capsule-v1-empty-reserved-root")
        // Explicit fake-sync opt-in; refresh alone does not simulate a successful
        // real cold launch or grant the actual Photos client access.
        f.app.photoSync.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        // Wait only for the held backend's public state and mounted native
        // views, NEVER for non-overlap/the asserted coordinates. wait already
        // settles two main-queue layout passes; adding assertion polling would
        // hide a real nested-inset regression rather than diagnose it.
        try await host.wait {
            f.app.photoSync.phase == .updating
                && host.hasRootBottomFrame(.syncToast)
                && host.hasRootBottomFrame(.navigation)
                && host.hasRootBottomFrame(.selectionToolbar)
        }
        // Capture the actual bounded UIWindow BEFORE any geometry assertion,
        // so another failure still exports the selection + toast evidence.
        try host.attachRootSyncWindow(to: self)
        let searchScroll = try primarySearchScrollView(in: host.controller.view)
        let toolbar = try host.rootSelectionToolbarFrame()
        let card = try host.rootBottomFrame(.syncToast)
        let navigation = try host.rootBottomFrame(.navigation)
        let usable = searchScroll.convert(searchScroll.bounds.inset(by: searchScroll.adjustedContentInset), to: host.window)
        let measurements = XCTAttachment(string: """
        Before toast: native toolbar=\(beforeToast); preference=\(String(describing: beforePreference))
        Settled window=\(host.window.bounds); native toolbar=\(toolbar)
        Native toast envelope=\(card); native navigation=\(navigation); native search usable=\(usable)
        SwiftUI preferences (not used for root non-overlap): \(host.sync)
        Toast envelope is the stable 52pt reservation; the 44pt capsule is inset 4pt vertically.
        """)
        measurements.name = "Geometry-sync-capsule-v1-production-root-selection"
        measurements.lifetime = .keepAlways
        add(measurements)
        XCTAssertEqual(card, idleReservation)
        XCTAssertEqual(toolbar, beforeToast, "Working sync must not move the selection toolbar or photos")
        XCTAssertLessThanOrEqual(toolbar.maxY, card.minY + host.pixel,
                                 "The actual selection toolbar must finish above the actual sync card")
        XCTAssertLessThanOrEqual(usable.maxY, toolbar.minY + host.pixel)
        XCTAssertGreaterThanOrEqual(toolbar.minY, host.window.bounds.minY)
        XCTAssertGreaterThanOrEqual(card.minX, host.window.bounds.minX)
        XCTAssertLessThanOrEqual(card.maxX, host.window.bounds.maxX + host.pixel)
        XCTAssertLessThanOrEqual(card.maxY, navigation.minY + host.pixel)
        XCTAssertLessThanOrEqual(navigation.maxY, host.window.bounds.maxY + host.pixel)
        XCTAssertTrue(f.app.photoSync.canCancel)
        try host.assertRootActionRegionsRouteOutsideScroll(in: toolbar, excluding: searchScroll)
        // Keep the existing child text/progress/44-point action checks as well;
        // root non-overlap and scrolling above it now use native window frames.
        try assertCardGeometry(host, cancel: true)
        f.navigation.select(.cleanup)
        try await host.wait { f.cleanup.isPageVisible && f.cleanup.isAutomaticRefreshDeferred }
        await f.cleanup.waitUntilIdle()
        XCTAssertTrue(f.cleanup.hasScanned)
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), groupIDs)
        XCTAssertEqual(f.cleanup.selectionSessionID, cleanupSession)
        XCTAssertEqual(f.cleanup.selectedIDs, Set([cleanupSelected]))
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertFalse(f.cleanup.isGrouping)
        XCTAssertFalse(f.cleanup.isRestoring)
        XCTAssertEqual(f.grouping.thresholds.count, prepCount, "Entering cleanup during sync must not start a new grouping read")
        XCTAssertNotNil(host.sync[.card])
        XCTAssertTrue(host.hasRootBottomFrame(.syncToast))
        XCTAssertFalse(host.hasRootBottomFrame(.selectionToolbar), "Search actions must not leak onto cleanup")
        XCTAssertEqual(f.app.photoSync.phase, .updating)

        // Commit while the fake backend is still held: browsing survives, but
        // old selection authority is revoked and refresh remains coalesced.
        let indexEpoch = f.app.indexSourceEpoch
        try await service.commit(using: access)
        try await host.wait { f.cleanup.needsRegroup }
        XCTAssertEqual(f.app.photoSync.phase, .updating)
        XCTAssertTrue(f.app.photoSync.canCancel)
        XCTAssertNotEqual(f.app.indexSourceEpoch, indexEpoch)
        XCTAssertEqual(f.app.photoLibraryEpoch, photosEpoch, "A source commit is not Photos access invalidation")
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), groupIDs)
        XCTAssertEqual(f.cleanup.selectionSessionID, cleanupSession)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertNil(f.cleanup.pendingDeletion)
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertTrue(f.cleanup.isAutomaticRefreshDeferred)
        XCTAssertFalse(f.cleanup.isGrouping)
        XCTAssertFalse(f.cleanup.isRestoring)
        XCTAssertEqual(f.grouping.thresholds.count, prepCount, "A held sync commit must not compute cleanup")
        XCTAssertEqual(f.app.resultSessionID, searchSession)
        XCTAssertEqual(f.app.results.map(\.id), results)
        XCTAssertEqual(f.app.selectedResultIDs, Set([selected]))
        XCTAssertEqual(f.app.query, query)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === searchScroll)

        // Cancellation drains the backend and lets the real lifecycle observer
        // release cleanup admission. Its card persists without a completion timer.
        f.app.photoSync.cancel()
        XCTAssertEqual(f.app.photoSync.phase, .cancelling)
        XCTAssertTrue(f.cleanup.isAutomaticRefreshDeferred)
        XCTAssertEqual(f.grouping.thresholds.count, prepCount)
        run.release.open()
        await f.app.waitForSync()
        try await host.wait {
            f.cleanup.hasScanned && !f.cleanup.needsRegroup
                && !f.cleanup.isGrouping && !f.cleanup.isRestoring
                && !f.cleanup.isAutomaticRefreshDeferred
                && host.sync[.card] != nil && host.hasRootBottomFrame(.syncToast)
        }
        await f.cleanup.waitUntilIdle()
        XCTAssertEqual(f.grouping.thresholds.count, prepCount + 1, "Exactly one coalesced automatic grouping follows the seed")
        XCTAssertNotEqual(try XCTUnwrap(f.cleanup.selectionSessionID), cleanupSession)
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), groupIDs)
        XCTAssertTrue(f.cleanup.canSelect)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertEqual(f.app.photoSync.phase, .cancelled)
        XCTAssertFalse(f.app.photoSync.canCancel)
        XCTAssertTrue(f.app.photoSync.visible)
        XCTAssertEqual(PhotoSyncToast(state: f.app.photoSync).title, "同步已取消")
        XCTAssertNil(host.sync[.progress])
        try assertCardGeometry(host, cancel: false)
        let navigationBeforeModal = try host.rootBottomFrame(.navigation)
        XCTAssertEqual(Set(host.tabs.keys), Set(PrimaryPage.allCases))

        f.cleanup.prepareDeletion() // Empty-selection alert only; never confirm/delete.
        XCTAssertEqual(f.cleanup.message, PhotoDeletionError.emptySelection.localizedDescription)
        XCTAssertNil(f.cleanup.pendingDeletion)
        try await host.wait {
            host.controller.presentedViewController != nil && host.sync[.card] == nil
                && host.hasRootBottomFrame(.syncToast)
        }
        XCTAssertEqual(try host.rootBottomFrame(.syncToast).height, 52, accuracy: host.pixel)
        XCTAssertNil(host.sync[.mainAction])
        XCTAssertNil(host.sync[.action])
        let anchors = controlsDescendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self)
        XCTAssertTrue(anchors.contains { $0.owningNavigationController?.view.accessibilityElementsHidden == true })
        XCTAssertFalse(host.window.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        // Only mounted Button branches publish tab regions; placeholders have
        // neither those preferences nor identifiers. Strict AX absence remains
        // an external XCUI check, not an in-process AX-tree inference.
        XCTAssertTrue(host.tabs.isEmpty)
        XCTAssertEqual(try host.rootBottomFrame(.navigation).height,
                       navigationBeforeModal.height, accuracy: host.pixel)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === searchScroll)
        f.cleanup.dismissMessage()
        try await host.wait {
            host.controller.presentedViewController == nil && host.sync[.card] != nil
                && host.hasRootBottomFrame(.syncToast)
        }
        XCTAssertEqual(Set(host.tabs.keys), Set(PrimaryPage.allCases))
        XCTAssertEqual(try host.rootBottomFrame(.navigation).height,
                       navigationBeforeModal.height, accuracy: host.pixel)

        f.navigation.select(.search)
        try await host.settle()
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === searchScroll)
        XCTAssertEqual(f.app.query, query)
        XCTAssertEqual(f.app.resultSessionID, searchSession)
        XCTAssertEqual(f.app.results.map(\.id), results)
        XCTAssertEqual(f.app.selectedResultIDs, Set([selected]))
        let returnedToolbar = try host.rootSelectionToolbarFrame()
        XCTAssertLessThanOrEqual(returnedToolbar.maxY, try host.rootBottomFrame(.syncToast).minY + host.pixel)
        try host.assertRootActionRegionsRouteOutsideScroll(in: returnedToolbar, excluding: searchScroll)
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await host.wait { host.sync[.card] == nil && host.hasRootBottomFrame(.syncToast) }
        XCTAssertEqual(try host.rootBottomFrame(.syncToast).height, 52, accuracy: host.pixel)
        XCTAssertNil(host.sync[.mainAction])
        XCTAssertNil(host.sync[.action])
        XCTAssertFalse(host.tabs.isEmpty, "Only hide the card, not the existing keyboard/navigation layout")
        XCTAssertTrue(host.hasRootBottomFrame(.selectionToolbar))
        XCTAssertTrue(host.hasRootBottomFrame(.navigation))
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await host.wait { host.sync[.card] != nil && host.hasRootBottomFrame(.syncToast) }
        XCTAssertLessThanOrEqual(try host.rootSelectionToolbarFrame().maxY,
                     try host.rootBottomFrame(.syncToast).minY + host.pixel)
        XCTAssertEqual(f.app.photoSync.phase, .cancelled)
        XCTAssertFalse(f.app.photoSync.canCancel)
        XCTAssertTrue(f.app.photoSync.visible)
        XCTAssertEqual(f.grouping.thresholds.count, prepCount + 1)
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        // Public notification + native scope evidence, not a real keyboard tap
        // or proof of strict XCUI accessibility identifier absence.
    }

    private func ringPixels(_ host: ControlsNativeHost) throws -> Data {
        let globalFrame = try XCTUnwrap(host.sync[.progress])
        let localFrame = host.controller.view.convert(globalFrame, from: host.window)
        let image = try host.capture()
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        let cropped = UIGraphicsImageRenderer(size: localFrame.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -localFrame.minX, y: -localFrame.minY))
        }
        return try XCTUnwrap(cropped.cgImage?.dataProvider?.data) as Data
    }

    private func makeSync(_ runs: [PresentationSyncRun], delay: PresentationSyncGate = PresentationSyncGate(),
                          delayEntered: XCTestExpectation? = nil) -> (PhotoSyncState, PresentationSyncService) {
        let service = PresentationSyncService(runs: runs)
        let state = PhotoSyncState(service: service, completionDelay: {
            delayEntered?.fulfill()
            await delay.wait()
        })
        addTeardownBlock { @MainActor in
            state.cancel(); state.pause()
            runs.forEach { $0.release.open() }; delay.open()
            await state.waitUntilIdle()
        }
        return (state, service)
    }

    private func reached(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Fake backend did not reach its explicit milestone")
            throw ControlsPresentationFailure.layout
        }
    }

    private func assertCardGeometry(_ host: ControlsNativeHost, cancel: Bool) throws {
        let card = try XCTUnwrap(host.sync[.card])
        let text = try XCTUnwrap(host.sync[.text])
        let main = try XCTUnwrap(host.sync[.mainAction])
        let reservation = try XCTUnwrap(host.sync[.reservation])
        let tab = try XCTUnwrap(host.tabs[.search])
        XCTAssertGreaterThanOrEqual(card.minX, 0)
        XCTAssertLessThanOrEqual(card.maxX, host.window.bounds.width + host.pixel)
        XCTAssertGreaterThanOrEqual(card.minY, 0)
        XCTAssertEqual(reservation.height, card.height + 8, accuracy: host.pixel)
        XCTAssertEqual(card.minY, reservation.minY + 4, accuracy: host.pixel)
        XCTAssertLessThanOrEqual(reservation.maxY, tab.minY + host.pixel)
        XCTAssertGreaterThan(text.width, 0)
        XCTAssertGreaterThanOrEqual(text.minY + host.pixel, card.minY)
        XCTAssertLessThanOrEqual(text.maxX, main.maxX + host.pixel)
        XCTAssertLessThanOrEqual(text.maxY, card.maxY + host.pixel)
        XCTAssertGreaterThanOrEqual(main.width, 44)
        XCTAssertGreaterThanOrEqual(main.height, 44)
        if cancel {
            let action = try XCTUnwrap(host.sync[.action])
            XCTAssertLessThanOrEqual(main.maxX, action.minX + host.pixel)
            XCTAssertLessThanOrEqual(action.maxX, card.maxX + host.pixel)
            XCTAssertGreaterThanOrEqual(action.minY + host.pixel, card.minY)
            XCTAssertLessThanOrEqual(action.maxY, card.maxY + host.pixel)
            XCTAssertEqual(action.width, 44, accuracy: host.pixel)
            XCTAssertEqual(action.height, 44, accuracy: host.pixel)
        } else {
            XCTAssertNil(host.sync[.action], "Stopped/failure main action opens details, never an automatic retry")
        }
        if let progress = host.sync[.progress] {
            XCTAssertEqual(progress.height, 14, accuracy: host.pixel)
            XCTAssertEqual(progress.width, 14, accuracy: host.pixel)
            XCTAssertLessThanOrEqual(progress.maxX, text.minX + host.pixel)
            XCTAssertEqual(progress.midY, card.midY, accuracy: host.pixel)
            let arc = try XCTUnwrap(host.sync[.fill])
            XCTAssertEqual(arc.width, 12, accuracy: host.pixel)
            XCTAssertEqual(arc.height, 12, accuracy: host.pixel)
            XCTAssertEqual(arc.midX, progress.midX, accuracy: host.pixel)
            XCTAssertEqual(arc.midY, progress.midY, accuracy: host.pixel)
        }
    }
}

@MainActor
private extension ControlsNativeHost {
    func hasRootBottomFrame(_ part: RootBottomLayoutPart) -> Bool {
        controlsDescendants(controller.view, RootBottomLayoutProbeView.self).contains {
            $0.part == part && $0.window === window && $0.windowFrame != nil
        }
    }

    func rootBottomProbe(_ part: RootBottomLayoutPart) throws -> RootBottomLayoutProbeView {
        let probes = controlsDescendants(controller.view, RootBottomLayoutProbeView.self).filter {
            $0.part == part && $0.window === window && $0.windowFrame != nil
        }
        XCTAssertEqual(probes.count, 1, "Exactly one attached native root \(part), not merged preference entries")
        let probe = try XCTUnwrap(probes.count == 1 ? probes.first : nil)
        XCTAssertFalse(probe.isUserInteractionEnabled)
        XCTAssertFalse(probe.isAccessibilityElement)
        XCTAssertTrue(probe.accessibilityElementsHidden)
        return probe
    }

    func rootBottomFrame(_ part: RootBottomLayoutPart) throws -> CGRect {
        try XCTUnwrap(rootBottomProbe(part).windowFrame)
    }

    func rootSelectionToolbarFrame() throws -> CGRect {
        try rootBottomFrame(.selectionToolbar)
    }

    func assertRootActionRegionsRouteOutsideScroll(in toolbar: CGRect, excluding scroll: UIScrollView) throws {
        let card = try rootBottomFrame(.syncToast)
        let navigation = try rootBottomFrame(.navigation)
        for part in [RootBottomLayoutPart.shareAction, .favoriteAction, .albumAction] {
            let probe = try rootBottomProbe(part)
            let frame = try XCTUnwrap(probe.windowFrame)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertGreaterThanOrEqual(frame.minX + pixel, toolbar.minX)
            XCTAssertLessThanOrEqual(frame.maxX, toolbar.maxX + pixel)
            XCTAssertGreaterThanOrEqual(frame.minY + pixel, toolbar.minY)
            XCTAssertLessThanOrEqual(frame.maxY, toolbar.maxY + pixel)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(frame.contains(center) && toolbar.contains(center))
            XCTAssertFalse(card.contains(center) || navigation.contains(center))
            let hit = try XCTUnwrap(window.hitTest(center, with: nil))
            XCTAssertTrue(hit.window === window)
            XCTAssertFalse(hit === window || hit === probe)
            XCTAssertFalse(hit === scroll || hit.isDescendant(of: scroll), "A selection action must not hit the result scroller")
            XCTAssertTrue(hit.convert(hit.bounds, to: window).contains(center))
            var ancestor: UIView? = hit
            while let view = ancestor {
                XCTAssertFalse(view.isHidden)
                XCTAssertTrue(view.isUserInteractionEnabled)
                XCTAssertGreaterThan(view.alpha, 0)
                if let control = view as? UIControl { XCTAssertTrue(control.isEnabled) }
                ancestor = view.superview
            }
            // A passive background probe has no supported ancestry contract
            // with SwiftUI's action host. This checks native routing only, not
            // SwiftUI action dispatch, and never invokes a Photos operation.
        }
    }

    func attachRootSyncWindow(to test: XCTestCase,
                              name: String = "UIReview-sync-capsule-v1-production-root-selection-working") throws {
        layout()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(window.bounds)
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard drawn else { XCTFail("Root UIWindow capture failed"); throw ControlsPresentationFailure.drawing }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

/// Deliberately NOT @ObservedObject. Only the real PhotoSyncToast subscribes;
/// its publications update the capsule without changing the reserved viewport.
@MainActor
private struct SyncCardFixture: View {
    let state: PhotoSyncState
    var isPresented = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("TEST · synthetic sync, no Photos").font(.caption)
                ForEach(0..<20) { index in
                    Text("Sample \(index + 1)").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }.padding(16)
        }
        .background(IQStyle.background).foregroundStyle(IQStyle.text)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                PhotoSyncToast(state: state, isPresented: isPresented)
                PrimaryNavigationBar(page: .search, switchingDisabled: false) { _ in }
            }
        }
    }
}

@MainActor
private final class SyncVisibilityControl: ObservableObject {
    @Published var isPresented = true
}

@MainActor
private struct SyncVisibilityFixture: View {
    let state: PhotoSyncState
    @ObservedObject var visibility: SyncVisibilityControl
    var body: some View { SyncCardFixture(state: state, isPresented: visibility.isPresented) }
}

private final class PresentationSyncRun: @unchecked Sendable {
    enum Outcome: Sendable { case success(PhotoSyncProgress), failure, diagnostic(PhotoSyncDiagnostic) }
    let initial: PhotoSyncProgress
    let outcome: Outcome
    let entered = XCTestExpectation(description: "Fake sync reported progress and is held")
    let release = PresentationSyncGate()
    init(initial: PhotoSyncProgress = PhotoSyncProgress(),
         outcome: Outcome = .success(PhotoSyncProgress(phase: .updating, total: 0))) {
        self.initial = initial
        self.outcome = outcome
    }
}

private actor PresentationSyncService: PhotoSyncServicing {
    let runs: [PresentationSyncRun]
    private(set) var calls = 0
    private var progressCallback: (@Sendable (PhotoSyncProgress) async -> Void)?
    private var commitCallback: (@Sendable () async -> Void)?
    init(runs: [PresentationSyncRun]) { self.runs = runs }
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        guard calls < runs.count else {
            XCTFail("Unexpected automatic sync restart")
            throw ControlsPresentationFailure.unexpectedWork
        }
        let run = runs[calls]
        calls += 1
        progressCallback = progress
        commitCallback = committed
        await progress(run.initial)
        run.entered.fulfill()
        await run.release.wait() // Simulates an in-flight prediction that must drain.
        try Task.checkCancellation()
        switch run.outcome {
        case .success(let value):
            return PhotoSyncResult(summary: LibrarySummary(indexedCount: value.encoded, modelVersion: "TEST-controls"), progress: value)
        case .failure: throw ControlsPresentationFailure.unexpectedWork
        case .diagnostic(let diagnostic): throw diagnostic
        }
    }
    func report(_ value: PhotoSyncProgress) async { await progressCallback?(value) }
    func commit(using access: IndexAccessCoordinator) async throws {
        let lease = try await access.acquireWrite()
        lease.release() // Real coordinator revision, no database or Photos write.
        await commitCallback?()
    }
}

private final class PresentationSyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0.resume() }
    }
}