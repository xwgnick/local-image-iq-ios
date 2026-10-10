import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Native presentation only: real ContentView/embedded cleanup/Settings, with
/// synthetic metadata services and an unreadable real Photos client. No engine,
/// OCR, storage, network, authorization changes or deletion (even fake deletion).
/// Four UIReview captures, not goldens or a physical nonempty-cleanup E2E claim.
/// Geometry uses public SwiftUI preferences/UIKit, never private AX traversal.
@MainActor
final class PrimaryNavigationPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testDefaultSearchAndEqualPrimaryTargetsWithoutBackgroundGrouping() async throws {
        let c = try await context()
        let host = try await mountContent(c)
        defer { host.close() }
        XCTAssertEqual(c.navigation.page, .search)
        XCTAssertFalse(c.state.textSearchEnabled)
        XCTAssertEqual(c.cleanup.threshold, 0.95)
        XCTAssertFalse(c.cleanup.hasScanned)
        XCTAssertTrue(c.grouping.thresholds.isEmpty)
        XCTAssertTrue(c.grouping.restores.isEmpty, "A retained hidden page must not restore on search startup")
        let search = try XCTUnwrap(host.measurements.tabs[.search])
        let cleanup = try XCTUnwrap(host.measurements.tabs[.cleanup])
        let pixel = 1 / host.window.screen.scale
        XCTAssertEqual(search.width, cleanup.width, accuracy: pixel)
        XCTAssertEqual(search.minY, cleanup.minY, accuracy: pixel)
        XCTAssertEqual(search.width + cleanup.width + 8, phone.width - 40, accuracy: pixel)
        XCTAssertEqual(search.height, 44, accuracy: pixel)
        XCTAssertEqual(cleanup.height, 44, accuracy: pixel)
        XCTAssertTrue(host.controller.view.bounds.contains(search))
        XCTAssertTrue(host.controller.view.bounds.contains(cleanup))
        XCTAssertEqual(c.worker.searches, 0)
        try capture(host, name: "main-navigation-search-dark")
        assertNoSideEffects(c)
    }

    func testUnreadableSyntheticBrowsingSourceBlocksGroupingDespiteAppReadiness() async throws {
        let c = try await context()
        c.browsingLibrary.revoke()
        let host = try await mountContent(c)
        defer { host.close() }
        c.navigation.select(.cleanup)
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(c.state.canRead && c.state.modelsReady, "App readiness is not browsing authority")
        XCTAssertEqual(c.cleanup.displayAccessIsReadable, false)
        XCTAssertTrue(c.grouping.restores.isEmpty)
        XCTAssertTrue(c.grouping.thresholds.isEmpty)
        XCTAssertFalse(c.cleanup.hasScanned)
        XCTAssertTrue(c.cleanup.groups.isEmpty)
        XCTAssertFalse(c.cleanup.canBrowse)
        XCTAssertFalse(c.cleanup.canSelect)
        XCTAssertNil(c.cleanup.browsingSessionID)
        XCTAssertNil(c.cleanup.selectionSessionID)
        XCTAssertTrue(c.cleanup.selectedIDs.isEmpty)
        XCTAssertNil(c.cleanup.pendingDeletion)
        assertNoSideEffects(c)
    }

    func testEmbeddedFirstReadyEntryGroupsOnceAndTabReturnReusesSelection() async throws {
        let c = try await context()
        let host = try await mountContent(c)
        defer { host.close() }
        c.navigation.select(.cleanup)
        // Layout delivers the real onChange before joining the controller task;
        // a bare waitUntilIdle immediately after select can race onAppear.
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertEqual(c.grouping.restores, [Float(0.95)])
        XCTAssertEqual(c.grouping.thresholds, [Float(0.95)])
        XCTAssertTrue(c.cleanup.hasScanned)
        XCTAssertEqual(c.cleanup.groups.map { $0.photos.count }, [4, 3])
        XCTAssertFalse(c.cleanup.needsRegroup)
        XCTAssertTrue(descendants(host.controller.view, of: UISlider.self).isEmpty,
                  "Production cleanup starts with its threshold disclosure collapsed")
        try capture(host, name: "main-navigation-cleanup-dark")
        XCTAssertTrue(c.cleanup.canBrowse)
        XCTAssertTrue(c.cleanup.canSelect)
        let browsingSession = try XCTUnwrap(c.cleanup.browsingSessionID)
        let session = try XCTUnwrap(c.cleanup.selectionSessionID)
        let group = try XCTUnwrap(c.cleanup.groups.first)
        let selectedID = try XCTUnwrap(group.photos.first?.id)
        c.cleanup.toggleSelection(selectedID)
        let token = try XCTUnwrap(c.cleanup.beginRangeSelection(groupID: group.id))
        XCTAssertTrue(c.cleanup.isSelecting)
        c.navigation.select(.search)
        try await settle(host)
        XCTAssertFalse(c.cleanup.isSelecting, "Leaving cancels only the provisional drag")
        // A late gesture callback must not commit selection after switching.
        c.cleanup.finishRangeSelection(token: token, selectedInGroup: Set(group.photos.map(\.id)))
        await c.cleanup.waitUntilIdle()
        XCTAssertEqual(c.cleanup.selectedIDs, Set([selectedID]))
        c.navigation.select(.cleanup)
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        XCTAssertEqual(c.cleanup.browsingSessionID, browsingSession)
        XCTAssertEqual(c.cleanup.selectionSessionID, session)
        XCTAssertEqual(c.cleanup.selectedIDs, Set([selectedID]))
        XCTAssertEqual(c.grouping.restores.count, 1)
        XCTAssertEqual(c.grouping.thresholds.count, 1)
        assertNoSideEffects(c)
    }

    func testSearchQueryResultsSelectionAndActualScrollerSurviveRoundTrip() async throws {
        let c = try await context()
        c.state.query = "TEST synthetic coast"
        c.state.search()
        await c.state.waitUntilIdle()
        // Five columns can bring later pages into view on first layout. Load
        // this finite synthetic response before capturing the retention baseline;
        // the separate hidden-boundary test still verifies page admission.
        while c.state.hasMoreResults, let session = c.state.resultSessionID {
            c.state.loadMoreResults(sessionID: session, after: c.state.results.count)
            await c.state.waitUntilIdle()
        }
        c.state.setSelectingResults(true)
        let firstID = try XCTUnwrap(c.state.results.first?.id)
        c.state.toggleResultSelection(firstID)
        let session = try XCTUnwrap(c.state.resultSessionID)
        let ids = c.state.results.map(\.id)
        let scores = c.state.results.map { $0.score.bitPattern }
        let host = try await mountContent(c)
        defer { host.close() }
        let scroll = try searchScroll(host)
        let start = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: start.x, y: start.y + 100), animated: false)
        try await settle(host)
        XCTAssertGreaterThan(scroll.contentOffset.y, start.y)
        let offset = scroll.contentOffset
        c.navigation.select(.cleanup)
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(try searchScroll(host) === scroll, "Resolve the same search owner even while hidden")
        c.navigation.select(.search)
        try await settle(host)
        XCTAssertTrue(try searchScroll(host) === scroll, "Keep the actual UIKit scroller, not a reconstructed page")
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1 / host.window.screen.scale)
        XCTAssertEqual(c.state.query, "TEST synthetic coast")
        XCTAssertEqual(c.state.completedQuery, c.state.query)
        XCTAssertEqual(c.state.resultSessionID, session)
        XCTAssertEqual(c.state.results.map(\.id), ids)
        XCTAssertEqual(c.state.results.map { $0.score.bitPattern }, scores)
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertEqual(c.state.selectedResultIDs, Set([firstID]))
        XCTAssertEqual(c.worker.searches, 1)
        assertNoSideEffects(c)
    }

    func testSwitchDuringSearchWaitsForReadinessAndHiddenBoundaryDoesNotAppend() async throws {
        let c = try await context()
        let host = try await mountContent(c)
        defer { host.close() }
        let gate = NavigationSearchGate()
        c.worker.gate = gate
        c.state.query = "TEST held search"
        c.state.search()
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5) == .completed else {
            throw NavigationReviewFailure.layout
        }
        c.navigation.select(.cleanup)
        try await settle(host)
        XCTAssertEqual(c.navigation.page, .cleanup, "Ordinary search must not lock the bottom tabs")
        XCTAssertTrue(c.grouping.restores.isEmpty)
        XCTAssertTrue(c.grouping.thresholds.isEmpty)
        gate.release()
        await c.state.waitUntilIdle()
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(c.cleanup.hasScanned)
        XCTAssertEqual(c.grouping.thresholds, [Float(0.95)])
        XCTAssertEqual(c.state.results.count, 12)
        let hiddenScroll = try searchScroll(host)
        let previousBoundary = host.measurements.boundary
        let bottom = hiddenScroll.contentSize.height - hiddenScroll.bounds.height + hiddenScroll.adjustedContentInset.bottom
        hiddenScroll.setContentOffset(CGPoint(x: hiddenScroll.contentOffset.x, y: bottom), animated: false)
        try await settle(host)
        try await requireNativeLayout(host, description: "New hidden search boundary preference after scrolling") {
            guard let boundary = host.measurements.boundary else { return false }
            return boundary != previousBoundary && boundary.sessionID == c.state.resultSessionID
                && boundary.visibleCount == 12 && boundary.frame.height > 0
        }
        let boundary = try XCTUnwrap(host.measurements.boundary)
        XCTAssertLessThan(boundary.frame.minY, hiddenScroll.bounds.height,
                          "Move the genuine hidden boundary into its viewport, not just set an unrelated state flag")
        XCTAssertGreaterThan(boundary.frame.maxY, 0)
        XCTAssertEqual(c.state.results.count, 12, "Hidden search cannot paginate from geometry or idle callbacks")
        XCTAssertTrue(c.state.hasMoreResults)
        XCTAssertEqual(c.worker.searches, 1)
        assertNoSideEffects(c)
    }

    func testPhotoTextLabelInfoThenUnscaledSwitchAndOnUpdatesExactlyOnce() async throws {
        let c = try await context()
        c.worker.permitsTextUpdate = true
        let host = try await mountContent(c)
        defer { host.close() }
        try await requireMeasurements(host, text: true)
        let toggle = try XCTUnwrap(host.measurements.text[.toggle])
        let label = try XCTUnwrap(host.measurements.text[.label])
        let info = try XCTUnwrap(host.measurements.text[.info])
        XCTAssertGreaterThanOrEqual(toggle.height, 44, "Native switch retains a 44-point interaction frame")
        XCTAssertLessThanOrEqual(label.maxX, info.minX + pixel(host))
        XCTAssertLessThanOrEqual(info.maxX, toggle.minX + pixel(host))
        XCTAssertEqual(info.width, 44, accuracy: pixel(host))
        XCTAssertEqual(info.height, 44, accuracy: pixel(host))
        XCTAssertLessThanOrEqual(toggle.maxX, phone.width - 20 + pixel(host))
        XCTAssertLessThanOrEqual(label.height, 20, "V5 OCR label fits one line at the default 393-point width")
        let nativeSwitch = try XCTUnwrap(descendants(host.controller.view, of: UISwitch.self).first)
        XCTAssertEqual(nativeSwitch.transform, .identity, "No scaleEffect to fake a smaller touch target")
        XCTAssertGreaterThanOrEqual(nativeSwitch.bounds.width, 51)
        XCTAssertFalse(nativeSwitch.isOn)
        c.state.textSearchEnabled = true
        await c.state.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(nativeSwitch.isOn)
        XCTAssertTrue(c.state.canIndexText)
        XCTAssertEqual(c.worker.textUpdates, 1, "First ON triggers one incremental worker call")
        XCTAssertEqual(c.state.summary.textIndexCounts.records, 0, "Synthetic worker returns zero saved text records")
        XCTAssertNil(c.state.activity)
        c.state.textSearchEnabled = true
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.textUpdates, 1)
        try capture(host, name: "main-navigation-search-text-on-dark")
        c.state.textSearchEnabled = false
        try await settle(host)
        XCTAssertFalse(nativeSwitch.isOn)
        assertNoSideEffects(c)
    }

    func testMaximumFontWrapsOCRLabelBeforeInfoAndSwitchWithoutHorizontalOverflow() async throws {
        let c = try await context()
        let size = CGSize(width: 320, height: 852)
        let host = try await mountContent(c, size: size, dynamicType: .accessibility5)
        defer { host.close() }
        try await requireMeasurements(host, text: true)
        let toggle = try XCTUnwrap(host.measurements.text[.toggle])
        let label = try XCTUnwrap(host.measurements.text[.label])
        let info = try XCTUnwrap(host.measurements.text[.info])
        XCTAssertGreaterThanOrEqual(toggle.height, 44)
        XCTAssertLessThanOrEqual(label.maxX, info.minX + pixel(host))
        XCTAssertLessThanOrEqual(info.maxX, toggle.minX + pixel(host))
        XCTAssertGreaterThan(label.height, 20, "The accessible-size OCR label wraps before its independent controls")
        XCTAssertLessThanOrEqual(toggle.maxX, size.width - 20 + pixel(host))
        let scroll = try searchScroll(host)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let original = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: original.x,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await settle(host)
        XCTAssertGreaterThan(scroll.contentOffset.y, original.y)
        XCTAssertEqual(scroll.contentOffset.x, original.x)
        let search = try XCTUnwrap(host.measurements.tabs[.search])
        let cleanup = try XCTUnwrap(host.measurements.tabs[.cleanup])
        XCTAssertEqual(search.width, cleanup.width, accuracy: 1 / host.window.screen.scale)
        XCTAssertLessThanOrEqual(cleanup.maxX, size.width)
        assertNoSideEffects(c)
    }

    func testSettingsHasNoThresholdControlAndPreservesCleanupSession() async throws {
        let c = try await context()
        c.cleanup.enterPage(ready: true)
        await c.cleanup.waitUntilIdle()
        let session = try XCTUnwrap(c.cleanup.selectionSessionID)
        let groupIDs = c.cleanup.groups.map(\.id)
        let group = try XCTUnwrap(c.cleanup.groups.first)
        let selectedID = try XCTUnwrap(group.photos.first?.id)
        c.cleanup.toggleSelection(selectedID)
        _ = try XCTUnwrap(c.cleanup.beginRangeSelection(groupID: group.id))

        // Settings no longer owns a threshold binding. Its real presentation
        // must neither expose a slider nor disturb the retained cleanup state.
        // Integer/draft control interactions belong to the cleanup control tests.
        let host = try await mount(AnyView(SettingsSheet(state: c.state, cleanup: c.cleanup)))
        defer { host.close() }
        XCTAssertTrue(descendants(host.controller.view, of: UISlider.self).isEmpty)
        try capture(host, name: "main-navigation-settings-dark")
        XCTAssertEqual(c.cleanup.threshold, 0.95)
        XCTAssertEqual(c.cleanup.selectionSessionID, session)
        XCTAssertEqual(c.cleanup.groups.map(\.id), groupIDs)
        XCTAssertEqual(c.cleanup.selectedIDs, Set([selectedID]))
        XCTAssertTrue(c.cleanup.isSelecting)
        c.cleanup.cancelRangeSelection()
        try await settle(host)
        XCTAssertFalse(c.cleanup.needsRegroup)
        XCTAssertTrue(c.cleanup.canSelect)
        XCTAssertEqual(c.grouping.restores, [Float(0.95)])
        XCTAssertEqual(c.grouping.thresholds, [Float(0.95)], "Settings never computes or restores another grouping")
        assertNoSideEffects(c)
    }

    func testRetainedPageModifierExcludesHiddenNativeHitTargetsWithoutRecreation() async throws {
        let navigation = PrimaryNavigationPresentation()
        let controls = NavigationNativeControls()
        let host = try await mount(AnyView(NavigationHitTestRoot(navigation: navigation, controls: controls)))
        defer { host.close() }
        let search = try XCTUnwrap(controls.search)
        let cleanup = try XCTUnwrap(controls.cleanup)
        let point = CGPoint(x: host.window.bounds.midX, y: host.window.bounds.midY)
        func hits(_ control: UIView) -> Bool {
            guard let hit = host.window.hitTest(point, with: nil) else { return false }
            return hit === control || hit.isDescendant(of: control)
        }
        XCTAssertTrue(hits(search))
        XCTAssertFalse(hits(cleanup))
        navigation.select(.cleanup, switchingDisabled: true)
        XCTAssertEqual(navigation.page, .search)
        navigation.select(.cleanup)
        try await settle(host)
        XCTAssertTrue(hits(cleanup))
        XCTAssertFalse(hits(search))
        navigation.select(.search)
        try await settle(host)
        XCTAssertTrue(hits(search))
        XCTAssertTrue(controls.search === search && controls.cleanup === cleanup)
        XCTAssertEqual(controls.created, 2, "Both actual UIControls were created once, not re-mounted per tab")
        // Real-app XCUI tests separately assert hidden accessibility identifiers.
    }

    // MARK: Test-only services; no preferences suite and no production defaults

    private func context() async throws -> NavigationReviewContext {
        let permission = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos host; never reset/request permission in native presentation tests")
            throw NavigationReviewFailure.photosReadable
        }
        let worker = NavigationReviewWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             queryTranslator: NavigationReviewTranslator())
        let grouping = NavigationReviewGrouping(photos: worker.hits.map(\.photo))
        // App readiness must not stand in for Photos display authority. Supply
        // only synthetic full revisions before the real root installs its default.
        let browsingLibrary = RefinementLibrary(grouping.groups.flatMap(\.photos).map {
            PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime)
        })
        let cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: NavigationReviewDeletion(), preferences: nil,
            browsingAccess: SimilarCleanupBrowsingAccess(library: browsingLibrary))
        let c = NavigationReviewContext(state: state, worker: worker, grouping: grouping,
                                        cleanup: cleanup, browsingLibrary: browsingLibrary,
                                        navigation: PrimaryNavigationPresentation())
        addTeardownBlock { @MainActor in
            worker.gate?.release()
            cleanup.leavePage()
            cleanup.pause()
            state.enterBackground()
            await cleanup.waitUntilIdle()
            await state.waitUntilIdle()
            state.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, permission)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(worker.unexpectedCalls, 0)
            XCTAssertEqual(browsingLibrary.unexpectedCalls, 0, "Browsing must not enumerate, request pixels or resolve places")
        }
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady && state.canRead)
        XCTAssertEqual(cleanup.displayAccessIsReadable, true)
        XCTAssertFalse(state.library.canReadImages, "Synthetic readiness never authorizes the real Photos client")
        XCTAssertNil(state.appleTranslationService)
        return c
    }

    private func assertNoSideEffects(_ c: NavigationReviewContext) {
        XCTAssertEqual(c.worker.unexpectedCalls, 0)
        XCTAssertEqual(c.browsingLibrary.unexpectedCalls, 0)
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertFalse(c.state.allowICloudDownload)
        XCTAssertFalse(c.state.library.canReadImages)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
        XCTAssertEqual(c.state.progress, IndexProgress())
        XCTAssertFalse(c.cleanup.isDeleting)
    }

    // MARK: Small public UIKit host, no inherited/private accessibility traversal

    private func mountContent(_ c: NavigationReviewContext, size: CGSize? = nil,
                              dynamicType: DynamicTypeSize = .large) async throws -> NavigationReviewHost {
        let host = try await mount(AnyView(ContentView(state: c.state, photoActionService: NavigationReviewActions(),
            similarCleanupState: c.cleanup, navigation: c.navigation)), size: size, dynamicType: dynamicType)
        do {
            try await requireMeasurements(host, tabs: true)
            return host
        } catch {
            host.close()
            throw error
        }
    }

    private func mount(_ content: AnyView, size: CGSize? = nil,
                       dynamicType: DynamicTypeSize = .large) async throws -> NavigationReviewHost {
        let size = size ?? phone
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let measurements = NavigationMeasurements()
        let root = VStack(spacing: 0) {
            Text("TEST FIXTURE · synthetic counts · no Photos/OCR")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).padding(.vertical, 6)
                .frame(maxWidth: .infinity).background(Color.black)
            content
                .onPreferenceChange(PrimaryNavigationFrames.self) { measurements.tabs = $0 }
                .onPreferenceChange(SearchPhotoTextFrames.self) { measurements.text = $0 }
                .onPreferenceChange(ResultPageBoundaryPreference.self) { measurements.boundary = $0 }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, dynamicType)
        .environment(\.scenePhase, .active)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = NavigationReviewHost(scene: scene, root: AnyView(root), size: size, measurements: measurements)
        var mounted = false
        defer { if !mounted { host.close() } }
        let layout = expectation(description: "Native primary navigation layout")
        host.controller.onLayout = { [weak controller = host.controller] in
            guard let controller, controller.view.window != nil, controller.view.bounds.size == size else { return }
            controller.onLayout = nil
            layout.fulfill()
        }
        host.window.rootViewController = host.controller
        host.window.makeKeyAndVisible()
        host.layout()
        guard await XCTWaiter.fulfillment(of: [layout], timeout: 5) == .completed else {
            throw NavigationReviewFailure.layout
        }
        try await settle(host)
        mounted = true
        return host
    }

    private func settle(_ host: NavigationReviewHost) async throws {
        let layout = expectation(description: "Native layout updates delivered")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); layout.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [layout], timeout: 5) == .completed else {
            throw NavigationReviewFailure.layout
        }
    }

    private func requireMeasurements(_ host: NavigationReviewHost, tabs: Bool = false,
                                     text: Bool = false) async throws {
        func measured(_ frame: CGRect?) -> Bool {
            guard let frame else { return false }
            return frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }
        // Only ContentView hosts request tabs; only caption tests request text.
        // Settings/native hit-test hosts intentionally emit neither preference.
        try await requireNativeLayout(host, description: "Actual control preferences: tabs=\(tabs), text=\(text)") {
            (!tabs || (measured(host.measurements.tabs[.search]) && measured(host.measurements.tabs[.cleanup])))
                && (!text || (measured(host.measurements.text[.toggle]) && measured(host.measurements.text[.label])
                              && measured(host.measurements.text[.info])))
        }
    }

    private func requireNativeLayout(_ host: NavigationReviewHost, description: String,
                                     observed: @escaping @MainActor () -> Bool) async throws {
        let inspect: @MainActor () -> Bool = {
            host.layout()
            return observed()
        }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        ready.expectationDescription = description
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Missing native measurement: \(description)")
            throw NavigationReviewFailure.layout
        }
    }

    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? [])
            + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func searchScroll(_ host: NavigationReviewHost) throws -> UIScrollView {
        try primarySearchScrollView(in: host.controller.view)
    }

    private func pixel(_ host: NavigationReviewHost) -> CGFloat { 1 / host.window.screen.scale }

    private func capture(_ host: NavigationReviewHost, name: String) throws {
        let view = host.controller.view!
        XCTAssertEqual(view.bounds.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew else { XCTFail("Native hierarchy did not draw"); throw NavigationReviewFailure.drawing }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, Int((phone.width * format.scale).rounded()))
        XCTAssertEqual(cg.height, Int((phone.height * format.scale).rounded()))
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum NavigationReviewFailure: Error { case photosReadable, unexpectedWork, layout, drawing }

@MainActor
private struct NavigationReviewContext {
    let state: AppState
    let worker: NavigationReviewWorker
    let grouping: NavigationReviewGrouping
    let cleanup: SimilarPhotoCleanupState
    let browsingLibrary: RefinementLibrary
    let navigation: PrimaryNavigationPresentation
}

@MainActor
private final class NavigationReviewWorker: PhotoWorkServicing {
    let summary = LibrarySummary(indexedCount: 37, modelVersion: "TEST-navigation-only",
                                 textIndexCounts: TextIndexCounts(), textIndexStatisticsKnown: true)
    let hits: [SearchHit]
    private(set) var searches = 0
    private(set) var unexpectedCalls = 0
    private(set) var textUpdates = 0
    var permitsTextUpdate = false
    var gate: NavigationSearchGate?

    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        hits = (0..<37).map { index in
            let photo = IndexedPhoto(id: "TEST-navigation-\(index)", modificationTime: 200,
                modelVersion: "TEST-navigation-only", imageEmbedding: vector, creationTime: 100)
            return SearchHit(photo: photo, score: Float(37 - index) / 37)
        }
    }
    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searches += 1
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        return SearchResponse(summary: summary, hits: hits)
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        if permitsTextUpdate { textUpdates += 1; return summary }
        throw unexpected()
    }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> NavigationReviewFailure {
        unexpectedCalls += 1
        XCTFail("Presentation alone must never index/recognize/clear; only the explicit OCR toggle fixture permits text work")
        return .unexpectedWork
    }
}

@MainActor
private final class NavigationReviewGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    private(set) var thresholds: [Float] = []
    private(set) var restores: [Float] = []
    init(photos: [IndexedPhoto]) {
        groups = [SimilarPhotoGroup(id: photos[0].id, photos: Array(photos[0..<4]), minimumSimilarity: 1),
                  SimilarPhotoGroup(id: photos[4].id, photos: Array(photos[4..<7]), minimumSimilarity: 1)]
    }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        restores.append(threshold)
        return .missing
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        thresholds.append(threshold)
        await progress(SimilarPhotoGroupingProgress(total: 37, completed: 37, groupCount: groups.count))
        // The result must use the requested policy threshold, not the legacy
        // fixture's old constant. No production grouping algorithm is replaced.
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: 37,
            staleCount: 0, unindexedCount: 0, threshold: threshold)
    }
}

private struct NavigationReviewDeletion: PhotoDeleting {
    func delete(revisions: [PhotoRevision]) async throws {
        XCTFail("Presentation never submits even fake deletion")
        throw NavigationReviewFailure.unexpectedWork
    }
}

private struct NavigationReviewActions: PhotoLibraryActions {
    func albums() async throws -> [PhotoAlbum] { throw unexpected() }
    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws { throw unexpected() }
    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare { throw unexpected() }
    func validateAccess(ids: [String]) throws { throw unexpected() }
    private func unexpected() -> NavigationReviewFailure {
        XCTFail("Presentation must not read albums, share or mutate Photos")
        return .unexpectedWork
    }
}

@MainActor
private final class NavigationReviewTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("English fixture must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Presentation must not prepare a language pack"); throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class NavigationSearchGate {
    let entered = XCTestExpectation(description: "Synthetic search held")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }
    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class NavigationMeasurements {
    var tabs: [PrimaryPage: CGRect] = [:]
    var text: [SearchPhotoTextElement: CGRect] = [:]
    var boundary: ResultPageBoundaryValue?
}

@MainActor
private final class NavigationReviewController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
}

@MainActor
private final class NavigationReviewHost {
    let window: UIWindow
    let controller: NavigationReviewController
    let measurements: NavigationMeasurements
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, root: AnyView, size: CGSize, measurements: NavigationMeasurements) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.measurements = measurements
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = NavigationReviewController(rootView: root)
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    func close() {
        controller.onLayout = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
private final class NavigationNativeControls {
    var search: UIButton?
    var cleanup: UIButton?
    var created = 0
}

@MainActor
private struct NavigationHitTestRoot: View {
    @ObservedObject var navigation: PrimaryNavigationPresentation
    let controls: NavigationNativeControls
    var body: some View {
        ZStack {
            NavigationNativeButton(page: .search, controls: controls)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(RetainedPrimaryPage(active: navigation.page == .search))
            NavigationNativeButton(page: .cleanup, controls: controls)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(RetainedPrimaryPage(active: navigation.page == .cleanup))
        }
    }
}

@MainActor
private struct NavigationNativeButton: UIViewRepresentable {
    let page: PrimaryPage
    let controls: NavigationNativeControls
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(page.title, for: .normal)
        button.backgroundColor = .darkGray
        if page == .search { controls.search = button } else { controls.cleanup = button }
        controls.created += 1
        return button
    }
    func updateUIView(_ uiView: UIButton, context: Context) { }
}