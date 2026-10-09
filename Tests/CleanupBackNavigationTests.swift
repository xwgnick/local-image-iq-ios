import XCTest
import SwiftUI
import UIKit
import ImageIQCore
@testable import LocalImageIQ

/// Native hosts and the recognizer's deterministic transition path. These tests
/// do NOT inject touches. PresentationNavigationTests supplies physical XCUI
/// coordinate drags through the same production sheet with synthetic pixels.
@MainActor
final class CleanupBackNavigationTests: XCTestCase {
    func testLeftEdgeRecognizerAndReleaseDecisionDoNotTreatGeneralHorizontalDragsAsBack() {
        let anchor = CleanupBackNavigationAnchor()
        XCTAssertEqual(anchor.edgePan.edges, .left)
        XCTAssertEqual(anchor.edgePan.maximumNumberOfTouches, 1)
        XCTAssertEqual(anchor.edgePan.name, CleanupBackNavigationAnchor.gestureName)
        XCTAssertTrue(anchor.edgePan.delegate === anchor)
        XCTAssertFalse(anchor.isUserInteractionEnabled, "The passive anchor must not cover grid touches")
        XCTAssertTrue(CleanupBackNavigationAnchor.accepts(CGPoint(x: 200, y: 10)))
        XCTAssertFalse(CleanupBackNavigationAnchor.accepts(CGPoint(x: -200, y: 0)))
        XCTAssertFalse(CleanupBackNavigationAnchor.accepts(CGPoint(x: 10, y: 200)))
        XCTAssertFalse(CleanupBackNavigationAnchor.shouldFinish(progress: 0.2, velocity: 0, width: 393))
        XCTAssertFalse(CleanupBackNavigationAnchor.shouldFinish(progress: 0.8, velocity: -50, width: 393))
        XCTAssertTrue(CleanupBackNavigationAnchor.shouldFinish(progress: 0.6, velocity: 0, width: 393))
        XCTAssertTrue(CleanupBackNavigationAnchor.shouldFinish(progress: 0.3, velocity: 600, width: 393))
        XCTAssertFalse(CleanupBackNavigationAnchor.shouldFinish(progress: 0, velocity: 900, width: 393))
        XCTAssertFalse(CleanupBackNavigationAnchor.shouldFinish(progress: 0.6, velocity: 0, width: 0))
        let range = UIPanGestureRecognizer()
        XCTAssertTrue(anchor.gestureRecognizer(anchor.edgePan, shouldBeRequiredToFailBy: range))
        XCTAssertFalse(anchor.gestureRecognizer(anchor.edgePan, shouldBeRequiredToFailBy: UITapGestureRecognizer()))
    }

    func testCancelledFailedAndStaleRouteTransitionsCannotReturnOrCommitTwice() async throws {
        let anchor = CleanupBackNavigationAnchor()
        let route = UUID()
        var allowed = true
        var returns = 0
        var cancels = 0
        var distances: [CGFloat] = []
        func configuration(_ id: UUID?) -> CleanupBackNavigation {
            CleanupBackNavigation(routeID: id, enabled: true, canReturn: { allowed }, began: {},
                changed: { distances.append($0) }, cancelled: { cancels += 1 }, returned: { returns += 1 })
        }
        anchor.update(configuration(nil))
        XCTAssertFalse(anchor.beginInteraction(), "The cleanup root has no parent destination")
        anchor.update(configuration(route))
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 80, width: 400)
        XCTAssertEqual(anchor.progress, 0.2)
        XCTAssertEqual(distances, [80])
        anchor.endInteraction(velocity: 0, width: 400)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(returns, 0)
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 300, width: 400)
        anchor.cancelInteraction() // Actual .cancelled/.failed recognizer path.
        XCTAssertEqual(cancels, 2)
        XCTAssertEqual(anchor.progress, 0)
        anchor.endInteraction(velocity: 1_000, width: 400)
        XCTAssertEqual(returns, 0)
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 300, width: 400)
        allowed = false // Covers deletion or a newly presented modal before render.
        anchor.endInteraction(velocity: 1_000, width: 400)
        XCTAssertEqual(returns, 0)
        XCTAssertFalse(anchor.beginInteraction())
        allowed = true
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 300, width: 400)
        anchor.update(configuration(UUID())) // A replacement session is not this drag's route.
        anchor.endInteraction(velocity: 1_000, width: 400)
        XCTAssertEqual(returns, 0)
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 300, width: 400)
        anchor.endInteraction(velocity: 0, width: 400)
        anchor.endInteraction(velocity: 0, width: 400)
        XCTAssertEqual(returns, 1)
        anchor.detach()
        XCTAssertFalse(anchor.edgePan.isEnabled)
        XCTAssertNil(anchor.edgePan.view)
        XCTAssertFalse(anchor.beginInteraction())
    }

    func testRealSheetRetainsScrolledOverviewExactPhotoAndCommittedSelectionAcrossInteractiveReturn() async throws {
        let f = try await controlsFixture(in: self, sizes: Array(repeating: 35, count: 12))
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        let overview = try host.overviewScroll()
        _ = try host.capture()
        try await host.settle()
        overview.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
        try await host.settle()
        let offset = overview.contentOffset
        XCTAssertGreaterThan(offset.y, 0)
        let group = try XCTUnwrap(f.cleanup.displayGroups.first)
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        let photo = group.photos[17]
        f.cleanup.toggleSelection(group.photos[2].id)
        let selected = f.cleanup.selectedIDs
        f.browser.open(group: group, photoID: photo.id, sessionID: session)
        try await host.wait { !controlsControllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.isEmpty }
        let grid = try XCTUnwrap(controlsControllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        XCTAssertEqual(grid.initialScrollPhotoID, photo.id)
        let anchor = try backAnchor(host)
        try await host.wait { anchor.edgePan.isEnabled && anchor.gestureView != nil }
        XCTAssertFalse(anchor.gestureView === host.window)
        XCTAssertTrue(grid.view.isDescendant(of: try XCTUnwrap(anchor.gestureView)))
        let detailFrame = grid.collectionView.convert(grid.collectionView.bounds, to: host.window)
        let token = try XCTUnwrap(f.cleanup.beginRangeSelection(groupID: group.id))
        XCTAssertTrue(f.cleanup.isSelecting)
        XCTAssertTrue(anchor.beginInteraction())
        XCTAssertFalse(f.cleanup.isSelecting, "Return cancels provisional selection before moving the detail")
        anchor.updateInteraction(translation: 70, width: 393)
        XCTAssertGreaterThan(anchor.progress, 0)
        try await host.wait {
            abs(grid.collectionView.convert(grid.collectionView.bounds, to: host.window).minX
                - detailFrame.minX - 70) <= host.pixel
        }
        let route = f.browser.detailRoute
        anchor.endInteraction(velocity: 0, width: 393)
        try await host.wait {
            abs(grid.collectionView.convert(grid.collectionView.bounds, to: host.window).minX
                - detailFrame.minX) <= host.pixel
        }
        XCTAssertEqual(f.browser.detailRoute, route, "A short drag retains the route")
        XCTAssertEqual(f.cleanup.selectedIDs, selected)
        XCTAssertTrue(anchor.beginInteraction())
        anchor.updateInteraction(translation: 300, width: 393)
        anchor.endInteraction(velocity: 0, width: 393)
        try await host.wait { f.browser.detailRoute == nil && !anchor.edgePan.isEnabled }
        f.cleanup.finishRangeSelection(token: token, selectedInGroup: Set(group.photos.map(\.id)))
        await f.cleanup.waitUntilIdle()
        XCTAssertEqual(f.cleanup.selectedIDs, selected, "A late selection completion cannot commit after return")
        XCTAssertTrue(try host.overviewScroll() === overview)
        XCTAssertEqual(overview.contentOffset, offset)
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.grouping.thresholds, [0.95])
        XCTAssertNil(f.cleanup.pendingDeletion)
        XCTAssertFalse(anchor.beginInteraction(), "Root edge swipes must not navigate to Search")
        let gesture = anchor.edgePan
        host.close()
        try await host.settle()
        XCTAssertNil(gesture.view, "Dismantling must remove the borrowed navigation gesture")
    }

    func testOwnAlertDisablesEdgeAndExcludesBaseAXWithoutLosingDetail() async throws {
        let f = try await controlsFixture(in: self)
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let group = try XCTUnwrap(f.cleanup.groups.first)
        f.browser.open(group: group, photoID: group.photos[0].id,
                       sessionID: try XCTUnwrap(f.cleanup.selectionSessionID))
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { controlsDescendants(host.controller.view, CleanupBackNavigationAnchor.self).first?.edgePan.isEnabled == true }
        let anchor = try backAnchor(host)
        let scope = try XCTUnwrap(controlsDescendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let navigation = try XCTUnwrap(scope.owningNavigationController)
        let route = f.browser.detailRoute
        f.cleanup.prepareDeletion() // Empty-selection alert, not a deletion or Photos request.
        XCTAssertNotNil(f.cleanup.message)
        XCTAssertFalse(anchor.beginInteraction(), "Live modal state is checked before the next render")
        try await host.wait {
            guard let presented = host.controller.presentedViewController else { return false }
            return !anchor.edgePan.isEnabled && navigation.view.accessibilityElementsHidden
                && presented.viewIfLoaded?.window != nil && !presented.isBeingPresented
        }
        XCTAssertEqual(f.browser.detailRoute, route)
        var presenter: UIViewController? = host.controller
        while let next = presenter?.presentedViewController { presenter = next }
        let alert = try XCTUnwrap(presenter as? UIAlertController)
        XCTAssertTrue(alert.view.window === host.window)
        XCTAssertFalse(alert.view.isDescendant(of: navigation.view))
        XCTAssertFalse(alert.view.accessibilityElementsHidden)
        f.cleanup.dismissMessage()
        try await host.wait {
            host.controller.presentedViewController == nil && anchor.edgePan.isEnabled
                && !navigation.view.accessibilityElementsHidden
        }
        XCTAssertEqual(f.browser.detailRoute, route)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertEqual(f.grouping.thresholds, [0.95])
    }

    func testActualDeletingStateRejectsEdgeReturnUntilSyntheticDeletionDrains() async throws {
        let f = try await controlsFixture(in: self)
        let deletion = BackNavigationDeletionGate()
        let cleanup = SimilarPhotoCleanupState(grouping: f.grouping, deletion: deletion)
        cleanup.scan()
        await cleanup.waitUntilIdle()
        let group = try XCTUnwrap(cleanup.groups.first)
        f.browser.open(group: group, photoID: group.photos[0].id,
                       sessionID: try XCTUnwrap(cleanup.selectionSessionID))
        let host = try ControlsNativeHost(content: AnyView(SimilarPhotoCleanupSheet(
            state: cleanup, appState: f.app, browser: f.browser, thumbnailContent: { _ in AnyView(Color.orange) })))
        defer { host.close() }
        addTeardownBlock { @MainActor in
            deletion.release()
            await cleanup.waitUntilIdle()
        }
        try await host.wait { controlsDescendants(host.controller.view, CleanupBackNavigationAnchor.self).first?.edgePan.isEnabled == true }
        let anchor = try backAnchor(host)
        cleanup.toggleSelection(group.photos[0].id)
        cleanup.prepareDeletion()
        let intent = try XCTUnwrap(cleanup.pendingDeletion)
        cleanup.confirmDeletion(intent)
        XCTAssertTrue(cleanup.isDeleting)
        XCTAssertFalse(anchor.beginInteraction(), "The live closure guards even before SwiftUI reconfigures the adapter")
        try await host.wait { !anchor.edgePan.isEnabled && deletion.started }
        XCTAssertNotNil(f.browser.detailRoute)
        XCTAssertFalse(anchor.beginInteraction())
        deletion.release()
        await cleanup.waitUntilIdle()
        XCTAssertFalse(cleanup.isDeleting)
    }

    private func backAnchor(_ host: ControlsNativeHost) throws -> CleanupBackNavigationAnchor {
        let anchors = controlsDescendants(host.controller.view, CleanupBackNavigationAnchor.self)
        XCTAssertEqual(anchors.count, 1)
        return try XCTUnwrap(anchors.first)
    }
}

@MainActor
private final class BackNavigationDeletionGate: PhotoDeleting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    func delete(revisions: [PhotoRevision]) async throws {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        throw CancellationError()
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}