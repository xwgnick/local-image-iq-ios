import XCTest
import SwiftUI
import UIKit
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// Four native presentation tests. Counters come through PhotoSyncServicing,
/// never private-set assignment or AppState.start(). Gates always drain in
/// teardown. Captures are actual UIKit UIImages, not generated screen artwork.
@MainActor
final class PhotoSyncPresentationTests: XCTestCase {
    func testSmallWorkingAndCancelledCardObservesSubstateAndReservesBottomSpace() async throws {
        let run = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 8,
            completed: 2, encoded: 2, removed: 3))
        let (state, _) = makeSync([run])
        let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)),
                                         size: CGSize(width: 320, height: 568))
        defer { host.close() }
        try await host.wait { !host.tabs.isEmpty }
        XCTAssertTrue(host.sync.isEmpty, "The non-observing parent mounts an initially idle child")
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0.25)
        XCTAssertEqual(try XCTUnwrap(host.sync[.fill]).width,
                   try XCTUnwrap(host.sync[.progress]).width * 0.25, accuracy: host.pixel)
        XCTAssertEqual(PhotoSyncToast(state: state).title, "正在同步照片")
        XCTAssertEqual(state.progress.removed, 3)
        try assertCardGeometry(host, cancel: true)
        let scroll = try host.overviewScroll()
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        XCTAssertLessThanOrEqual(usable.maxY, try XCTUnwrap(host.sync[.card]).minY + host.pixel)
        let start = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: start.x,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await host.settle()
        XCTAssertGreaterThan(scroll.contentOffset.y, start.y)
        XCTAssertEqual(scroll.contentOffset.x, start.x, accuracy: host.pixel)
        XCTAssertEqual(scroll.contentOffset.y + scroll.bounds.height - scroll.adjustedContentInset.bottom,
                       scroll.contentSize.height, accuracy: host.pixel)
        try host.attach(to: self, name: "UIReview-photo-sync-v2-working-small")

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
        try host.attach(to: self, name: "UIReview-photo-sync-v2-cancelled-small")
    }

    func testUnknownTotalsMaximumTypeAndExplicitRestartUseOnlyBackendProgress() async throws {
        let first = PresentationSyncRun()
        let second = PresentationSyncRun(initial: PhotoSyncProgress(phase: .updating, total: 4))
        let (state, service) = makeSync([first, second])
        let host = try ControlsNativeHost(content: AnyView(SyncCardFixture(state: state)),
            size: CGSize(width: 320, height: 852), dynamicType: .accessibility5)
        defer { host.close() }
        state.updateAvailability(ready: true, networkAllowed: false)
        try await reached(first.entered)
        try await host.wait { host.sync[.card] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).title, "正在检查照片")
        XCTAssertNil(host.sync[.progress])
        try assertCardGeometry(host, cancel: true)
        await service.report(PhotoSyncProgress(phase: .updating, total: nil, completed: 0))
        try await host.settle()
        XCTAssertNil(PhotoSyncToast(state: state).fraction)
        XCTAssertNil(host.sync[.progress], "An updating phase alone is not a known denominator")
        await service.report(PhotoSyncProgress(phase: .updating, total: 8, completed: 3, encoded: 3))
        try await host.wait { host.sync[.progress] != nil }
        XCTAssertEqual(PhotoSyncToast(state: state).fraction, 0.375)
        XCTAssertEqual(try XCTUnwrap(host.sync[.fill]).width,
                   try XCTUnwrap(host.sync[.progress]).width * 0.375, accuracy: host.pixel)
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
            state.updateAvailability(ready: true, networkAllowed: false)
            try await reached(run.entered)
            run.release.open()
            await state.waitUntilIdle()
            try await host.wait { host.sync[.card] != nil }
            XCTAssertEqual(state.phase, expected)
            XCTAssertNil(PhotoSyncToast(state: state).fraction)
            XCTAssertNil(host.sync[.progress])
            if expected == .completed {
                XCTAssertEqual(PhotoSyncToast(state: state).title, "照片已同步")
                XCTAssertNil(host.sync[.action])
                try await reached(delayEntered)
                delay.open()
                try await host.wait { !state.visible && host.sync[.card] == nil }
            } else {
                XCTAssertNotNil(host.sync[.action])
                XCTAssertTrue(state.canRestart)
                XCTAssertTrue(state.visible)
                if expected == .needsAttention {
                    XCTAssertEqual(PhotoSyncToast(state: state).title, "部分照片需要联网")
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
        f.app.search()
        await f.app.waitUntilIdle()
        f.app.setSelectingResults(true)
        let selected = try XCTUnwrap(f.app.results.first?.id)
        f.app.toggleResultSelection(selected)
        let searchSession = f.app.resultSessionID
        let photosEpoch = f.app.photoLibraryEpoch
        let results = f.app.results.map(\.id)
        let host = try ControlsNativeHost(content: AnyView(ContentView(state: f.app,
            similarCleanupState: f.cleanup, navigation: f.navigation, cleanupPreferences: nil)))
        defer { host.close() }
        try await host.wait { host.sync[.selectionToolbar] != nil }
        // Explicit fake-sync opt-in; refresh alone does not simulate a successful
        // real cold launch or grant the actual Photos client access.
        f.app.photoSync.updateAvailability(ready: true, networkAllowed: false)
        try await reached(run.entered)
        try await host.wait { host.sync[.card] != nil }
        let searchScroll = try primarySearchScrollView(in: host.controller.view)
        let toolbar = try XCTUnwrap(host.sync[.selectionToolbar])
        let card = try XCTUnwrap(host.sync[.card])
        XCTAssertLessThanOrEqual(toolbar.maxY, card.minY + host.pixel,
                                 "The selection buttons reserve their own inset above the sync card")
        let usable = searchScroll.convert(searchScroll.bounds.inset(by: searchScroll.adjustedContentInset), to: host.window)
        XCTAssertLessThanOrEqual(usable.maxY, toolbar.minY + host.pixel)
        try assertCardGeometry(host, cancel: true)
        f.navigation.select(.cleanup)
        try await host.wait { f.cleanup.hasScanned }
        await f.cleanup.waitUntilIdle()
        XCTAssertNotNil(host.sync[.card])
        XCTAssertEqual(f.app.photoSync.phase, .updating)
        let groupIDs = f.cleanup.displayGroups.map(\.id)
        let cleanupSession = f.cleanup.selectionSessionID

        f.cleanup.prepareDeletion() // Empty-selection alert only; never confirm/delete.
        try await host.wait { host.controller.presentedViewController != nil && host.sync[.card] == nil }
        let anchors = controlsDescendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self)
        XCTAssertTrue(anchors.contains { $0.owningNavigationController?.view.accessibilityElementsHidden == true })
        XCTAssertFalse(host.window.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        f.cleanup.dismissMessage()
        try await host.wait { host.controller.presentedViewController == nil && host.sync[.card] != nil }

        let indexEpoch = f.app.indexSourceEpoch
        try await service.commit(using: access)
        try await host.wait { f.cleanup.needsRegroup }
        XCTAssertNotEqual(f.app.indexSourceEpoch, indexEpoch)
        XCTAssertEqual(f.app.photoLibraryEpoch, photosEpoch, "A source commit is not Photos access invalidation")
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), groupIDs)
        XCTAssertEqual(f.cleanup.selectionSessionID, cleanupSession)
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertEqual(f.app.resultSessionID, searchSession)
        XCTAssertEqual(f.app.results.map(\.id), results)
        XCTAssertEqual(f.app.selectedResultIDs, Set([selected]))
        f.navigation.select(.search)
        try await host.settle()
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === searchScroll)
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await host.wait { host.sync[.card] == nil }
        XCTAssertFalse(host.tabs.isEmpty, "Only hide the card, not the existing keyboard/navigation layout")
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await host.wait { host.sync[.card] != nil }
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        // Public notification + native scope evidence, not a real keyboard tap
        // or proof of strict XCUI accessibility identifier absence.
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
        let action = try XCTUnwrap(host.sync[.action])
        let tab = try XCTUnwrap(host.tabs[.search])
        XCTAssertGreaterThanOrEqual(card.minX, 0)
        XCTAssertLessThanOrEqual(card.maxX, host.window.bounds.width + host.pixel)
        XCTAssertGreaterThanOrEqual(card.minY, 0)
        XCTAssertLessThanOrEqual(card.maxY + 11, tab.minY + host.pixel)
        XCTAssertGreaterThan(text.width, 0)
        XCTAssertLessThanOrEqual(text.maxX, action.minX)
        XCTAssertLessThanOrEqual(text.maxY, card.maxY + host.pixel)
        XCTAssertLessThanOrEqual(action.maxX, card.maxX + host.pixel)
        XCTAssertGreaterThanOrEqual(action.height, 44)
        XCTAssertGreaterThanOrEqual(action.width, 44)
        if cancel {
            XCTAssertEqual(action.width, 44, accuracy: host.pixel)
            XCTAssertEqual(action.height, 44, accuracy: host.pixel)
        }
        if let progress = host.sync[.progress] {
            XCTAssertEqual(progress.height, 3, accuracy: host.pixel)
            XCTAssertGreaterThanOrEqual(progress.minY + host.pixel, text.maxY)
            XCTAssertLessThanOrEqual(progress.maxX, card.maxX + host.pixel)
        }
    }
}

/// Deliberately NOT @ObservedObject. Only the real PhotoSyncToast subscribes;
/// its changing layout must reach the outer safe-area inset on its own.
@MainActor
private struct SyncCardFixture: View {
    let state: PhotoSyncState
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
                PhotoSyncToast(state: state)
                PrimaryNavigationBar(page: .search, switchingDisabled: false) { _ in }
            }
        }
    }
}

private final class PresentationSyncRun: @unchecked Sendable {
    enum Outcome: Sendable { case success(PhotoSyncProgress), failure }
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