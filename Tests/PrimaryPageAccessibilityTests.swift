import XCTest
import SwiftUI
import UIKit
import Combine
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Check the real production pages' public UIKit exclusion boundaries, not a
/// recursive SwiftUI AX snapshot (which is not available in an app-host test).
/// The unchanged external XCUI tests remain responsible for strict public
/// button/label existence and identifier absence, including photo-query,
/// photo-text-search-enabled and index-photo-text. Native bar attachment and
/// geometry below do not establish that individual toolbar buttons are visible.
@MainActor
final class PrimaryPageAccessibilityTests: XCTestCase {
    func testActualPagesExcludeInactiveNativeContentAndHeadersWithoutRemovingControls() async throws {
        let c = try await context()
        c.state.query = "TEST retained query"
        c.state.textSearchEnabled = true // Also renders the manual OCR action.
        let host = try await mountContent(c)
        defer { host.close() }
        let scopes = try pageScopes(host)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let field = try XCTUnwrap(descendants(scroll, UITextField.self).first)
        let toggle = try XCTUnwrap(descendants(scroll, UISwitch.self).first)
        XCTAssertEqual(field.text, c.state.query)
        XCTAssertTrue(toggle.isOn)
        XCTAssertFalse(c.state.canIndexText)
        assertScopes(scopes, scroll: scroll, active: .search, host: host)
        assertHeader(scopes.search, active: true)
        assertHeader(scopes.cleanup, active: false)

        for _ in 0..<3 {
            c.navigation.select(.cleanup)
            try await settle(host)
            assertScopes(scopes, scroll: scroll, active: .cleanup, host: host)
            assertHeader(scopes.search, active: false)
            assertHeader(scopes.cleanup, active: true)
            XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
            XCTAssertTrue(field.isDescendant(of: scroll), "Exclude, do not remove the query's native view")
            XCTAssertTrue(toggle.isDescendant(of: scroll), "Exclude, do not rebuild the OCR switch")
            XCTAssertTrue(field.window === host.window && toggle.window === host.window)

            c.navigation.select(.search)
            try await settle(host)
            let returned = try pageScopes(host)
            XCTAssertTrue(returned.search === scopes.search && returned.cleanup === scopes.cleanup)
            assertScopes(returned, scroll: scroll, active: .search, host: host)
            assertHeader(scopes.search, active: true)
            assertHeader(scopes.cleanup, active: false)
            XCTAssertTrue(descendants(scroll, UITextField.self).contains { $0 === field })
            XCTAssertTrue(descendants(scroll, UISwitch.self).contains { $0 === toggle })
            XCTAssertEqual(field.text, "TEST retained query")
            XCTAssertTrue(toggle.isOn && c.state.textSearchEnabled)
        }
        XCTAssertEqual(c.grouping.restores, 0)
        XCTAssertEqual(c.grouping.scans, 0)
        XCTAssertEqual(c.worker.searches, 0)
        XCTAssertNil(c.state.activity)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
    }

    func testNativeAXSwitchPreservesActualScrollerResultsAndBothSelections() async throws {
        let c = try await context(ready: true)
        c.state.query = "TEST coast"
        c.state.search()
        await c.state.waitUntilIdle()
        let searchSession = try XCTUnwrap(c.state.resultSessionID)
        let resolution = c.state.completedSearchQuery
        let status = c.state.status
        var pages: [[SearchHit]] = []
        let subscription = c.state.$results.sink { pages.append($0) }
        defer { subscription.cancel() }
        let first = try XCTUnwrap(c.state.results.first?.id)
        c.state.setSelectingResults(true)
        c.state.toggleResultSelection(first)
        let boundary = PrimaryAXBoundaryProbe()
        let host = try await mountContent(c, boundary: boundary)
        defer { host.close() }
        let scopes = try pageScopes(host)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        try await settleVisibleResults(c, host: host, scroll: scroll, boundary: boundary)
        let original = scroll.contentOffset
        let bottom = max(-scroll.adjustedContentInset.top,
                         scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        XCTAssertGreaterThan(bottom, original.y, "Exercise actual scrolling, not an out-of-content offset")
        scroll.setContentOffset(CGPoint(x: original.x, y: min(original.y + 100, bottom)), animated: false)
        try await settleVisibleResults(c, host: host, scroll: scroll, boundary: boundary)
        XCTAssertGreaterThan(scroll.contentOffset.y, original.y)
        // Native five-column layout can auto-fill multiple pages both at mount
        // and after scrolling. Capture retention ONLY after those real events.
        let offset = scroll.contentOffset
        let ids = c.state.results.map(\.id)
        let scores = c.state.results.map { $0.score.bitPattern }
        let visiblePageCounts = pages.map(\.count)
        assertSearchPageTrace(pages, context: c, session: searchSession)
        attachSearchGeometry(c, host: host, scroll: scroll, boundary: boundary, phase: "before-tab")
        c.navigation.select(.cleanup)
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        assertScopes(scopes, scroll: scroll, active: .cleanup, host: host)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(scroll.contentOffset.x, offset.x)
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1 / host.window.screen.scale)
        XCTAssertEqual(c.state.resultSessionID, searchSession)
        XCTAssertEqual(c.state.results.map(\.id), ids, "Hidden layout must not append or reset search pages")
        XCTAssertEqual(c.state.results.map { $0.score.bitPattern }, scores)
        XCTAssertEqual(pages.map(\.count), visiblePageCounts, "No publication while search is hidden")
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertEqual(c.state.selectedResultIDs, Set([first]))
        attachSearchGeometry(c, host: host, scroll: scroll, boundary: boundary, phase: "hidden")
        let cleanupSession = try XCTUnwrap(c.cleanup.selectionSessionID)
        let photo = try XCTUnwrap(c.cleanup.groups.first?.photos.first)
        c.cleanup.toggleSelection(photo.id)
        XCTAssertEqual(c.cleanup.selectedIDs, Set([photo.id]))

        c.navigation.select(.search)
        try await settleVisibleResults(c, host: host, scroll: scroll, boundary: boundary)
        assertScopes(scopes, scroll: scroll, active: .search, host: host)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(scroll.contentOffset.x, offset.x)
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1 / host.window.screen.scale)
        XCTAssertEqual(c.state.query, "TEST coast")
        XCTAssertEqual(c.state.completedQuery, c.state.query)
        XCTAssertEqual(c.state.completedSearchQuery, resolution)
        XCTAssertEqual(c.state.status, status)
        XCTAssertEqual(c.state.resultSessionID, searchSession)
        XCTAssertGreaterThanOrEqual(c.state.results.count, ids.count)
        XCTAssertEqual(Array(c.state.results.prefix(ids.count)).map(\.id), ids)
        XCTAssertEqual(Array(c.state.results.prefix(ids.count)).map { $0.score.bitPattern }, scores)
        assertSearchPageTrace(pages, context: c, session: searchSession)
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertEqual(c.state.selectedResultIDs, Set([first]))
        attachSearchGeometry(c, host: host, scroll: scroll, boundary: boundary, phase: "returned")
        let returnedIDs = c.state.results.map(\.id)
        let returnedScores = c.state.results.map { $0.score.bitPattern }
        let returnedPageCounts = pages.map(\.count)
        c.navigation.select(.cleanup)
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        assertScopes(scopes, scroll: scroll, active: .cleanup, host: host)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(scroll.contentOffset.x, offset.x)
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1 / host.window.screen.scale)
        XCTAssertEqual(c.state.resultSessionID, searchSession)
        XCTAssertEqual(c.state.results.map(\.id), returnedIDs)
        XCTAssertEqual(c.state.results.map { $0.score.bitPattern }, returnedScores)
        XCTAssertEqual(pages.map(\.count), returnedPageCounts)
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertEqual(c.state.selectedResultIDs, Set([first]))
        XCTAssertEqual(c.cleanup.selectionSessionID, cleanupSession)
        XCTAssertEqual(c.cleanup.selectedIDs, Set([photo.id]))
        attachSearchGeometry(c, host: host, scroll: scroll, boundary: boundary, phase: "hidden-again")
        XCTAssertEqual(c.grouping.restores, 1)
        XCTAssertEqual(c.grouping.scans, 1)
        XCTAssertEqual(c.worker.searches, 1)
    }

    func testEmbeddedCleanupBoundaryCoversRetainedNativeDetailAndReopensIt() async throws {
        let c = try await context(ready: true)
        c.cleanup.scan()
        await c.cleanup.waitUntilIdle()
        let browser = SimilarPhotoGroupBrowser()
        c.navigation.select(.cleanup)
        let root = PrimaryAXCleanupRoot(context: c, browser: browser)
        let host = try await mount(AnyView(root))
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let nav = try navigation(containing: anchor, in: host)
        let group = try XCTUnwrap(c.cleanup.groups.first)
        let session = try XCTUnwrap(c.cleanup.selectionSessionID)
        browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        try await requireLayout(host) {
            !self.controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.isEmpty
        }
        let grid = try XCTUnwrap(controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        let route = try XCTUnwrap(browser.detailRoute)
        XCTAssertTrue(grid.collectionView.isDescendant(of: nav.view))
        XCTAssertFalse(nav.view.accessibilityElementsHidden)
        c.navigation.select(.search)
        try await settle(host)
        XCTAssertTrue(nav.view.accessibilityElementsHidden, "Cover native detail children, not only the overview ScrollView")
        assertHeader(nav, active: false)
        XCTAssertEqual(browser.detailRoute, route)
        XCTAssertTrue(grid.collectionView.window === host.window)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        c.navigation.select(.cleanup)
        try await settle(host)
        XCTAssertFalse(nav.view.accessibilityElementsHidden)
        XCTAssertTrue(controllers(host.controller).contains { $0 === grid })
        XCTAssertEqual(browser.detailRoute, route)
        XCTAssertEqual(c.cleanup.selectionSessionID, session)
        XCTAssertEqual(c.grouping.scans, 1)
    }

    func testStandaloneCleanupRemainsAccessibleWithoutPrimaryPageActivity() async throws {
        let c = try await context()
        let host = try await mount(AnyView(SimilarPhotoCleanupSheet(
            state: c.cleanup, appState: c.state, embedded: false, isPageActive: false)))
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let nav = try navigation(containing: anchor, in: host)
        XCTAssertFalse(nav.view.accessibilityElementsHidden)
        XCTAssertTrue(descendants(nav.view, UISlider.self).isEmpty, "V3 starts collapsed in standalone hosts too")
        let disclosure = try XCTUnwrap(descendants(nav.view, UIButton.self).first {
            $0.accessibilityIdentifier == "similar-cleanup-threshold-disclosure"
        })
        XCTAssertEqual(disclosure.accessibilityValue, "已收起")
        XCTAssertTrue(disclosure.isEnabled && disclosure.window === host.window)
        assertHeader(nav, active: true)
        XCTAssertEqual(c.grouping.scans, 0)
    }

    func testAnchorReparentAndDismantleRestoreOnlyBorrowedNativeScopes() async throws {
        let root = UIViewController()
        let left = UINavigationController(rootViewController: UIViewController())
        let right = UINavigationController(rootViewController: UIViewController())
        root.loadViewIfNeeded()
        for (index, nav) in [left, right].enumerated() {
            root.addChild(nav)
            root.view.addSubview(nav.view)
            nav.view.frame = CGRect(x: CGFloat(index) * 190, y: 0, width: 190, height: 700)
            nav.didMove(toParent: root)
        }
        let leftContent = try XCTUnwrap(left.topViewController?.view)
        let rightContent = try XCTUnwrap(right.topViewController?.view)
        let leftScroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 190, height: 600))
        let rightScroll = UIScrollView(frame: leftScroll.frame)
        leftContent.addSubview(leftScroll)
        rightContent.addSubview(rightScroll)
        let anchor = PrimarySearchScrollAnchorView(frame: .zero)
        anchor.setPageActive(false) // Before attachment, like initial hidden cleanup.
        leftScroll.addSubview(anchor)
        let host = try await mountController(root)
        defer { host.close() }
        XCTAssertTrue(leftScroll.accessibilityElementsHidden)
        XCTAssertTrue(left.view.accessibilityElementsHidden)
        XCTAssertFalse(rightScroll.accessibilityElementsHidden)
        XCTAssertFalse(right.view.accessibilityElementsHidden)
        XCTAssertFalse(root.view.accessibilityElementsHidden)

        anchor.removeFromSuperview()
        rightScroll.addSubview(anchor)
        try await settle(host)
        XCTAssertFalse(leftScroll.accessibilityElementsHidden)
        XCTAssertFalse(left.view.accessibilityElementsHidden)
        XCTAssertTrue(rightScroll.accessibilityElementsHidden)
        XCTAssertTrue(right.view.accessibilityElementsHidden)
        anchor.setPageActive(true)
        anchor.setPageActive(false)
        anchor.setPageActive(true)
        try await settle(host)
        XCTAssertFalse(rightScroll.accessibilityElementsHidden, "Deferred attachment work uses the latest value")
        XCTAssertFalse(right.view.accessibilityElementsHidden)

        anchor.setPageActive(false)
        PrimarySearchScrollAnchor.dismantleUIView(anchor, coordinator: ())
        try await settle(host)
        XCTAssertFalse(rightScroll.accessibilityElementsHidden)
        XCTAssertFalse(right.view.accessibilityElementsHidden, "A queued update cannot re-hide a dismantled scope")
        XCTAssertFalse(host.window.accessibilityElementsHidden)
    }

    func testAnchorWithoutNavigationNeverHidesSharedHostingRoot() async throws {
        let host = try await mount(AnyView(ScrollView {
            Text("TEST content").background {
                PrimarySearchScrollAnchor(active: false).frame(height: 0)
            }
        }))
        defer { host.close() }
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let anchor = try XCTUnwrap(descendants(scroll, PrimarySearchScrollAnchorView.self).first)
        XCTAssertNil(anchor.owningNavigationController)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        XCTAssertFalse(host.window.accessibilityElementsHidden)
    }

    // MARK: Actual production hosts and public UIKit containment only

    private func attachSearchGeometry(_ c: PrimaryAXContext, host: PrimaryAXHost, scroll: UIScrollView,
                                      boundary: PrimaryAXBoundaryProbe, phase: String) {
        let attachment = XCTAttachment(string: """
        phase=\(phase) page=\(c.navigation.page) count=\(c.state.results.count)
        window=\(host.window.bounds) viewport=\(scroll.bounds) insets=\(scroll.adjustedContentInset)
        content=\(scroll.contentSize) offset=\(scroll.contentOffset)
        boundary=\(String(describing: boundary.latest)) session=\(String(describing: c.state.resultSessionID))
        """)
        attachment.name = "primary-AX-search-geometry-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settleVisibleResults(_ c: PrimaryAXContext, host: PrimaryAXHost,
                                      scroll: UIScrollView, boundary: PrimaryAXBoundaryProbe,
                                      file: StaticString = #filePath, line: UInt = #line) async throws {
        try await settle(host)
        try await requireLayout(host, file: file, line: line) {
            guard c.navigation.page == .search, !c.state.isBusy, scroll.window === host.window,
                  scroll.bounds.height > 0, !c.state.results.isEmpty else { return false }
            if !c.state.hasMoreResults { return boundary.latest == nil }
            guard let value = boundary.latest, value.sessionID == c.state.resultSessionID,
                  value.visibleCount == c.state.results.count,
                  value.frame.minY.isFinite, value.frame.width > 0, value.frame.height > 0 else { return false }
            return value.frame.minY >= scroll.bounds.height || value.frame.maxY <= 0
        }
    }

    private func assertSearchPageTrace(_ pages: [[SearchHit]], context c: PrimaryAXContext, session: UUID,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pages.map(\.count), [12, 24, 36, 37].filter { $0 <= c.state.results.count },
                       "Returning may append only the next full ordered prefix, not replace/replay a page",
                       file: file, line: line)
        for page in pages {
            let expected = Array(c.worker.hits.prefix(page.count))
            XCTAssertEqual(page.map(\.id), expected.map(\.id), file: file, line: line)
            XCTAssertEqual(page.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern }, file: file, line: line)
        }
        XCTAssertEqual(c.state.resultSessionID, session, file: file, line: line)
        XCTAssertEqual(c.state.totalResultCount, c.worker.hits.count, file: file, line: line)
        XCTAssertEqual(c.state.hasMoreResults, c.state.results.count < c.worker.hits.count, file: file, line: line)
        XCTAssertNil(c.state.activity, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
        XCTAssertEqual(c.worker.searches, 1, file: file, line: line)
    }

    private func pageScopes(_ host: PrimaryAXHost) throws -> (search: UINavigationController, cleanup: UINavigationController) {
        let anchors = descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self)
        XCTAssertEqual(anchors.count, 2)
        let search = try XCTUnwrap(anchors.first { $0 is PrimarySearchScrollAnchorView })
        let cleanup = try XCTUnwrap(anchors.first { !($0 is PrimarySearchScrollAnchorView) })
        let searchNav = try navigation(containing: search, in: host)
        let cleanupNav = try navigation(containing: cleanup, in: host)
        XCTAssertFalse(searchNav === cleanupNav, "Each retained page must own a different native navigation scope")
        return (searchNav, cleanupNav)
    }

    private func navigation(containing view: UIView, in host: PrimaryAXHost) throws -> UINavigationController {
        // Independent of the production responder resolver: enumerate public
        // child controllers and require exactly one enclosing navigation view.
        let candidates = controllers(host.controller).compactMap { $0 as? UINavigationController }
            .filter { view.isDescendant(of: $0.view) }
        XCTAssertEqual(candidates.count, 1)
        return try XCTUnwrap(candidates.count == 1 ? candidates.first : nil)
    }

    private func assertScopes(_ scopes: (search: UINavigationController, cleanup: UINavigationController),
                              scroll: UIScrollView, active: PrimaryPage, host: PrimaryAXHost,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(scroll.accessibilityElementsHidden, active != .search, file: file, line: line)
        XCTAssertEqual(scopes.search.view.accessibilityElementsHidden, active != .search, file: file, line: line)
        XCTAssertEqual(scopes.cleanup.view.accessibilityElementsHidden, active != .cleanup, file: file, line: line)
        XCTAssertTrue(scroll.isDescendant(of: scopes.search.view), file: file, line: line)
        for nav in [scopes.search, scopes.cleanup] {
            XCTAssertTrue(nav.navigationBar.isDescendant(of: nav.view), file: file, line: line)
            XCTAssertFalse(host.controller.view.isDescendant(of: nav.view), file: file, line: line)
            XCTAssertTrue(nav.view.window === host.window, file: file, line: line)
        }
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden, "Do not hide shared tabs/root", file: file, line: line)
        XCTAssertFalse(host.window.accessibilityElementsHidden, file: file, line: line)
    }

    private func assertHeader(_ nav: UINavigationController, active: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        // NavigationStack toolbars need not populate UINavigationItem's button
        // arrays. Check the public native bar and its enclosing AX scope only;
        // exact buttons/labels, rendering and interaction remain external XCUI
        // responsibilities, not inferred from these in-process measurements.
        let bar = nav.navigationBar
        XCTAssertTrue(bar.isDescendant(of: nav.view), file: file, line: line)
        XCTAssertEqual(nav.view.accessibilityElementsHidden, !active, file: file, line: line)
        var ancestry: [UIView] = []
        var ancestor: UIView? = bar
        while let view = ancestor {
            ancestry.append(view)
            ancestor = view.superview
        }
        XCTAssertEqual(ancestry.contains { $0.accessibilityElementsHidden }, !active,
                       "The active bar must not be AX-excluded; the inactive bar must be excluded by its page scope",
                       file: file, line: line)
        if active {
            guard let window = bar.window else {
                XCTFail("The active native navigation bar must remain attached to a window", file: file, line: line)
                return
            }
            XCTAssertTrue(window === nav.view.window, file: file, line: line)
            // Geometric visibility only, not a SwiftUI toolbar snapshot or an
            // assumption about the hidden state of internal hosting wrappers.
            var visibleBounds = bar.convert(bar.bounds, to: window).intersection(window.bounds)
            for view in ancestry.dropFirst() where view.clipsToBounds {
                visibleBounds = visibleBounds.intersection(view.convert(view.bounds, to: window))
            }
            XCTAssertGreaterThan(visibleBounds.width, 0, file: file, line: line)
            XCTAssertGreaterThan(visibleBounds.height, 0, file: file, line: line)
        }
    }

    private func mountContent(_ c: PrimaryAXContext, boundary: PrimaryAXBoundaryProbe? = nil) async throws -> PrimaryAXHost {
        let host = try await mount(AnyView(ContentView(state: c.state, photoActionService: PrimaryAXNoPhotos(),
            similarCleanupState: c.cleanup, navigation: c.navigation,
            onPageBoundaryMeasured: { boundary?.latest = $0 })))
        do {
            try await requireLayout(host) {
                self.descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).count == 2
                    && self.controllers(host.controller).filter { $0 is UINavigationController }.count == 2
            }
            return host
        } catch { host.close(); throw error }
    }

    private func mount(_ content: AnyView) async throws -> PrimaryAXHost {
        let root = content.environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .large)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        return try await mountController(UIHostingController(rootView: root))
    }

    private func mountController(_ controller: UIViewController) async throws -> PrimaryAXHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let host = PrimaryAXHost(scene: scene, controller: controller)
        do {
            try await requireLayout(host) { controller.view.window === host.window && controller.view.bounds.width > 0 }
            try await settle(host)
            return host
        } catch { host.close(); throw error }
    }

    private func settle(_ host: PrimaryAXHost) async throws {
        let delivered = expectation(description: "Native page transaction delivered")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); delivered.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [delivered], timeout: 5) == .completed else { throw PrimaryAXFailure.layout }
    }

    private func requireLayout(_ host: PrimaryAXHost,
                               file: StaticString = #filePath, line: UInt = #line,
                               observed: @escaping @MainActor () -> Bool) async throws {
        let inspect: @MainActor () -> Bool = { host.layout(); return observed() }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Missing actual native page boundary/layout", file: file, line: line)
            throw PrimaryAXFailure.layout
        }
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func controllers(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllers($0) }
    }

    private func context(ready: Bool = false) async throws -> PrimaryAXContext {
        let authorization = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos test host; do not change/request permission")
            throw PrimaryAXFailure.photosReadable
        }
        let worker = PrimaryAXWorker()
        let state = AppState(worker: worker, authorizationStatus: { ready ? .authorized : .notDetermined },
                             queryTranslator: PrimaryAXTranslator())
        let grouping = PrimaryAXGrouping(photos: worker.hits.map(\.photo))
        let cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: PrimaryAXNoPhotos(), preferences: nil)
        addTeardownBlock { @MainActor in
            cleanup.leavePage(); cleanup.pause(); state.enterBackground()
            await cleanup.waitUntilIdle(); await state.waitUntilIdle()
            state.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, authorization)
            XCTAssertFalse(PhotoLibraryClient.canRead)
        }
        if ready { state.refresh(); await state.waitUntilIdle(); XCTAssertTrue(state.modelsReady) }
        return PrimaryAXContext(state: state, worker: worker, grouping: grouping,
                                cleanup: cleanup, navigation: PrimaryNavigationPresentation())
    }
}

private enum PrimaryAXFailure: Error { case layout, photosReadable, unexpectedWork }

@MainActor
private final class PrimaryAXBoundaryProbe {
    var latest: ResultPageBoundaryValue?
}

@MainActor
private struct PrimaryAXContext {
    let state: AppState
    let worker: PrimaryAXWorker
    let grouping: PrimaryAXGrouping
    let cleanup: SimilarPhotoCleanupState
    let navigation: PrimaryNavigationPresentation
}

@MainActor
private struct PrimaryAXCleanupRoot: View {
    let context: PrimaryAXContext
    let browser: SimilarPhotoGroupBrowser
    @ObservedObject private var navigation: PrimaryNavigationPresentation
    init(context: PrimaryAXContext, browser: SimilarPhotoGroupBrowser) {
        self.context = context
        self.browser = browser
        _navigation = ObservedObject(wrappedValue: context.navigation)
    }
    var body: some View {
        SimilarPhotoCleanupSheet(state: context.cleanup, appState: context.state, browser: browser,
            thumbnailContent: { _ in AnyView(Color.gray) }, embedded: true, isPageActive: navigation.page == .cleanup)
            .modifier(RetainedPrimaryPage(active: navigation.page == .cleanup))
    }
}

@MainActor
private final class PrimaryAXHost {
    let window: UIWindow
    let controller: UIViewController
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, controller: UIViewController) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
private final class PrimaryAXWorker: PhotoWorkServicing {
    let summary = LibrarySummary(indexedCount: 37, modelVersion: "TEST-primary-AX")
    let hits: [SearchHit]
    private(set) var searches = 0
    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        hits = (0..<37).map { index in
            let photo = IndexedPhoto(id: "TEST-primary-AX-\(index)", modificationTime: 200,
                modelVersion: "TEST-primary-AX", imageEmbedding: vector, creationTime: 100)
            return SearchHit(photo: photo, score: Float(37 - index) / 37)
        }
    }
    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searches += 1
        return SearchResponse(summary: summary, hits: hits)
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        XCTFail("AX navigation must not index"); throw PrimaryAXFailure.unexpectedWork
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        XCTFail("AX navigation must not run OCR"); throw PrimaryAXFailure.unexpectedWork
    }
    func clear() async throws -> LibrarySummary {
        XCTFail("AX navigation must not clear storage"); throw PrimaryAXFailure.unexpectedWork
    }
}

@MainActor
private final class PrimaryAXGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    private(set) var restores = 0
    private(set) var scans = 0
    init(photos: [IndexedPhoto]) {
        groups = [SimilarPhotoGroup(id: photos[0].id, photos: Array(photos.prefix(4)), minimumSimilarity: 1)]
    }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore { restores += 1; return .missing }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        scans += 1
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: 37, staleCount: 0,
                                           unindexedCount: 0, threshold: threshold)
    }
}

private struct PrimaryAXNoPhotos: PhotoLibraryActions, PhotoDeleting {
    func albums() async throws -> [PhotoAlbum] { throw unexpected() }
    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws { throw unexpected() }
    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare { throw unexpected() }
    func validateAccess(ids: [String]) throws { throw unexpected() }
    func delete(revisions: [PhotoRevision]) async throws { throw unexpected() }
    private func unexpected() -> PrimaryAXFailure {
        XCTFail("AX tests must not authorize, share, delete or mutate Photos")
        return .unexpectedWork
    }
}

@MainActor
private final class PrimaryAXTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("AX fixture must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("AX fixture must not prepare a language pack"); throw QueryTranslationFailure.unsupported
    }
}