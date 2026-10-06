import XCTest
import SwiftUI
import UIKit
import Combine
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Native app-host tests, NOT XCUI touch injection or real Photos coverage.
/// Two UIReview captures use synthetic colors in the production sheet; one
/// captures the real grid controller after selection validation, marked TEST.
/// The controller methods tested here are invoked by its real recognizer;
/// async metadata validation itself is covered by the selection-state suite.
@MainActor
final class SimilarPhotoGroupBrowserTests: XCTestCase {
    func testCoverSamplesAreEvenDeterministicIncludeEndpointsAndNeverLimitMembership() {
        XCTAssertEqual(SimilarPhotoGroupGeometry.previewIndices(count: 0), [])
        XCTAssertEqual(SimilarPhotoGroupGeometry.previewIndices(count: 1), [0])
        for count in [2, 9, 29, 30, 31, 300, 3_000] {
            let indices = SimilarPhotoGroupGeometry.previewIndices(count: count)
            XCTAssertEqual(indices.count, min(count, 30))
            XCTAssertEqual(indices.first, 0)
            XCTAssertEqual(indices.last, count - 1)
            XCTAssertEqual(Set(indices).count, indices.count)
            XCTAssertEqual(indices, indices.sorted())
            XCTAssertEqual(indices, SimilarPhotoGroupGeometry.previewIndices(count: count))
            if count <= 30 { XCTAssertEqual(indices, Array(0..<count)) }
            let steps = zip(indices.dropFirst(), indices).map { $0.0 - $0.1 }
            XCTAssertLessThanOrEqual((steps.max() ?? 0) - (steps.min() ?? 0), 1)
        }
        XCTAssertEqual(SimilarPhotoGroupGeometry.previewIndices(count: 300)[17], 175)
    }

    func testCoverHeightStopsAtThreeRowsWhileFiveColumnGridRetainsEveryMember() {
        for width in [CGFloat(264), 320, 393, 430] {
            let compact = SimilarPhotoGroupGeometry.previewHeight(count: 30, width: width)
            XCTAssertEqual(SimilarPhotoGroupGeometry.previewHeight(count: 300, width: width), compact)
            XCTAssertEqual(SimilarPhotoGroupGeometry.previewHeight(count: 3_000, width: width), compact)
            XCTAssertLessThan(compact, width / 3)
            let side = SimilarPhotoGroupGeometry.side(width: width)
            for index in 0..<300 {
                let frame = SimilarPhotoGroupGeometry.frame(index: index, width: width)
                XCTAssertEqual(frame.width, side)
                XCTAssertEqual(frame.height, side)
                XCTAssertGreaterThanOrEqual(frame.minX, 2)
                XCTAssertLessThanOrEqual(frame.maxX, width - 2 + 0.000_001)
                XCTAssertEqual(frame.minY, 2 + CGFloat(index / 5) * (side + 2))
            }
            XCTAssertEqual(SimilarPhotoGroupGeometry.frame(index: 4, width: width).maxX, width - 2, accuracy: 0.000_001)
            XCTAssertEqual(SimilarPhotoGroupGeometry.frame(index: 5, width: width).minX, 2)
            XCTAssertEqual(SimilarPhotoGroupGeometry.height(count: 300, width: width),
                           SimilarPhotoGroupGeometry.frame(index: 299, width: width).maxY + 2)
            XCTAssertGreaterThan(SimilarPhotoGroupGeometry.height(count: 300, width: width),
                                 SimilarPhotoGroupGeometry.height(count: 30, width: width))
        }
    }

    func testActualOverviewTapOpensExactSampleWithMeasuredZoomAndRestoresSameScrollView() async throws {
        let f = try await fixture()
        let host = try await mount(f)
        defer { host.close() }
        let overview = try XCTUnwrap(descendants(host.controller.view, UIScrollView.self).first)
        let originalOffset = overview.contentOffset
        let covers = descendants(host.controller.view, SimilarPhotoPreviewControl.self)
        let firstGroup = covers.filter { $0.photoID.hasPrefix("TEST-browser-0-") }
        XCTAssertEqual(firstGroup.count, 30, "The 300-photo group owns only thirty cover tiles")
        XCTAssertTrue(covers.contains { $0.photoID.hasPrefix("TEST-browser-1-") },
                      "The next group is not below hundreds of expanded photo rows")
        let frames = firstGroup.map { $0.convert($0.bounds, to: host.window) }
        let mosaic = frames.reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(mosaic.height, SimilarPhotoGroupGeometry.previewHeight(count: 300, width: mosaic.width), accuracy: 1)
        XCTAssertLessThan(mosaic.height, 110)
        XCTAssertEqual(f.cleanup.groups.map { $0.photos.count }, [300, 4, 3])
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        attach(try capture(host), name: "UIReview-similar-groups-overview-dark")

        let wanted = f.grouping.groups[0].photos[175].id
        let tile = try XCTUnwrap(firstGroup.first { $0.photoID == wanted })
        let source = tile.convert(tile.bounds, to: host.window)
        // Public UIControl activation uses the production closure, including
        // its snapshot. It is not an assertion about physical finger hit testing.
        tile.sendActions(for: .touchUpInside)
        let route = try XCTUnwrap(f.browser.detailRoute)
        XCTAssertEqual(route.groupID, f.grouping.groups[0].id)
        XCTAssertEqual(route.photoID, wanted)
        XCTAssertEqual(f.browser.zoomFlight?.photoID, wanted)
        XCTAssertEqual(f.browser.zoomFlight?.source, source)
        XCTAssertEqual(f.browser.zoomFlight?.image.size, tile.bounds.size)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty, "Opening a cover is never selection or deletion")
        XCTAssertNil(f.cleanup.pendingDeletion)

        let completed = expectation(description: "Measured UIKit zoom completed")
        var didComplete = false
        let subscription = f.browser.$zoomFlight.sink { flight in
            if flight == nil && !didComplete { didComplete = true; completed.fulfill() }
        }
        defer { subscription.cancel() }
        try await settle(host)
        try await require(completed)
        try await settle(host)
        let grid = try XCTUnwrap(controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        XCTAssertEqual(grid.initialScrollPhotoID, wanted)
        XCTAssertEqual(grid.collectionView.numberOfItems(inSection: 0), 300)
        let target = try XCTUnwrap(grid.collectionView.cellForItem(at: IndexPath(item: 175, section: 0)))
        let targetFrame = target.convert(target.bounds, to: host.window)
        let recorded = try XCTUnwrap(f.browser.targetFrame)
        XCTAssertEqual(recorded.minX, targetFrame.minX, accuracy: 1)
        XCTAssertEqual(recorded.minY, targetFrame.minY, accuracy: 1)
        XCTAssertGreaterThan(targetFrame.width, source.width * 2)
        XCTAssertTrue(grid.collectionView.convert(grid.collectionView.bounds, to: host.window).contains(targetFrame))
        XCTAssertFalse(grid.collectionView.isPrefetchingEnabled)
        XCTAssertLessThan(grid.collectionView.visibleCells.count, 300, "Cells, not just requests, are recycled")
        assertFiveColumns(grid.collectionView)
        attach(try capture(host), name: "UIReview-similar-group-five-columns-dark")

        f.browser.closeDetail()
        try await settle(host)
        let returned = descendants(host.controller.view, UIScrollView.self)
        XCTAssertTrue(returned.contains { $0 === overview })
        XCTAssertEqual(overview.contentOffset, originalOffset)
        XCTAssertEqual(f.cleanup.groups.map { $0.photos.count }, [300, 4, 3])
        XCTAssertEqual(f.grouping.scans, 1)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertEqual(f.deletion.calls, 0)
    }

    func testActualGridScrollsToLastMemberAndKeepsFiveColumnsAtCompactMaximumFont() async throws {
        let f = try await fixture()
        let group = f.grouping.groups[0]
        f.browser.open(group: group, photoID: group.photos[299].id, sessionID: try XCTUnwrap(f.cleanup.selectionSessionID))
        let host = try await mount(f, size: CGSize(width: 320, height: 852), dynamicType: .accessibility5)
        defer { host.close() }
        let grid = try XCTUnwrap(controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        XCTAssertEqual(grid.initialScrollPhotoID, group.photos[299].id)
        XCTAssertEqual(grid.collectionView.numberOfItems(inSection: 0), 300)
        XCTAssertGreaterThan(grid.collectionView.bounds.height, 0)
        XCTAssertEqual(grid.collectionView.bounds.width, 320, accuracy: 1)
        XCTAssertEqual(grid.collectionView.contentSize.width, grid.collectionView.bounds.width)
        XCTAssertNotNil(grid.collectionView.cellForItem(at: IndexPath(item: 299, section: 0)))
        assertFiveColumns(grid.collectionView)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertNil(f.cleanup.pendingDeletion)
    }

    func testCaptureGuardKeepsTouchAndAccessibilityExactIDRoutingWithoutFlight() async throws {
        let group = browserGroups()[0]
        let wanted = group.photos[175].id
        let browser = SimilarPhotoGroupBrowser()
        let session = UUID()
        let controller = UIViewController()
        let tile = SimilarPhotoPreviewControl(frame: CGRect(x: 20, y: 80, width: 80, height: 80))
        tile.photoID = wanted
        var activations = 0
        tile.open = { capture in
            activations += 1
            browser.open(group: group, photoID: wanted, sessionID: session, capture: capture)
        }
        controller.view.addSubview(tile)
        let host = try await mount(controller)
        defer { host.close() }
        XCTAssertFalse(tile.canCapture, "Unconfigured controls fail closed")
        for placeholder in [AnyView(ProgressView()), AnyView(Text("Preview unavailable"))] {
            tile.configure(content: placeholder, selected: false)
            try await settle(host)
            XCTAssertNil(tile.capture())
            tile.sendActions(for: .touchUpInside)
            XCTAssertEqual(browser.detailRoute?.photoID, wanted)
            XCTAssertEqual(browser.detailRoute?.groupID, group.id)
            XCTAssertEqual(browser.detailRoute?.sessionID, session)
            XCTAssertNil(browser.zoomFlight)
            browser.closeDetail()
            XCTAssertTrue(tile.accessibilityActivate())
            XCTAssertEqual(browser.detailRoute?.photoID, wanted)
            XCTAssertNil(browser.zoomFlight)
        }
        XCTAssertEqual(activations, 4)
        tile.configure(content: AnyView(Color.red), selected: false)
        tile.canCapture = true // Synthetic pixels, as in the injected sheet path.
        try await settle(host)
        XCTAssertNotNil(tile.capture())
        tile.sendActions(for: .touchUpInside)
        XCTAssertEqual(browser.zoomFlight?.photoID, wanted)
        tile.canCapture = false
        XCTAssertNil(tile.capture())
        tile.sendActions(for: .touchUpInside)
        XCTAssertEqual(browser.detailRoute?.photoID, wanted)
        XCTAssertNil(browser.zoomFlight, "Readiness affects animation, not navigation")
        tile.isEnabled = false
        XCTAssertFalse(tile.accessibilityActivate())
        tile.sendActions(for: .touchUpInside)
        XCTAssertEqual(activations, 6)
    }

    func testRealThumbnailReadinessResetsForEveryRequestIdentityWithoutExtraPixelRequests() async throws {
        let f = BrowserPreviewFixture(requestCount: 8)
        addTeardownBlock { @MainActor in for gate in f.gates { await gate.release(false) } }
        let host = try await mount(UIHostingController(rootView: BrowserPreviewRoot(fixture: f)))
        defer { host.close() }
        for step in 0..<8 {
            switch step {
            case 1: f.size = CGSize(width: 96, height: 72) // Rotation/layout changes.
            case 2: f.scale = 3
            case 3: f.networkAllowed = true
            case 4:
                f.photo = IndexedPhoto(id: f.photo.id, modificationTime: f.photo.modificationTime + 100,
                    modelVersion: f.photo.modelVersion, imageEmbedding: f.photo.imageEmbedding,
                    creationTime: f.photo.creationTime)
            case 5: f.photo = f.group.photos[176]
            case 6: f.cache = PhotoThumbnailCache(library: f.provider)
            case 7: f.networkAllowed = false
            default: break
            }
            try await require(f.started[step])
            try await settle(host)
            let loading = try previewControl(host)
            XCTAssertFalse(loading.canCapture, "Generation \(step) must not inherit previous readiness")
            XCTAssertNil(loading.capture())
            loading.sendActions(for: .touchUpInside)
            XCTAssertEqual(f.browser.detailRoute?.photoID, f.photo.id)
            XCTAssertNil(f.browser.zoomFlight)

            await f.gates[step].release(step != 7)
            try await require(f.returned[step])
            if step == 7 {
                try await settle(host)
                let failed = try previewControl(host)
                XCTAssertFalse(failed.canCapture, "An error never reports onLoaded")
                XCTAssertNil(failed.capture())
                XCTAssertTrue(failed.accessibilityActivate())
                XCTAssertEqual(f.browser.detailRoute?.photoID, f.photo.id)
                XCTAssertNil(f.browser.zoomFlight)
            } else {
                let loaded = try await readyPreviewControl(host)
                let snapshot = try XCTUnwrap(loaded.capture())
                XCTAssertEqual(snapshot.photoID, f.photo.id)
                XCTAssertEqual(snapshot.image.size, f.size)
                XCTAssertTrue(hasRedCenter(snapshot.image), "Capture must contain the loaded photo, not a spinner")
                // Selection reconfiguration must retain the loaded child/task.
                f.selected.toggle()
                try await settle(host)
                XCTAssertTrue(try previewControl(host).canCapture)
            }
            XCTAssertEqual(f.provider.plans.count, step + 1, "Only the visible thumbnail requests pixels")
            let plan = try XCTUnwrap(f.provider.plans.last)
            XCTAssertEqual(plan.id, f.photo.id)
            XCTAssertEqual(plan.targetSize, CGSize(width: f.size.width * f.scale, height: f.size.height * f.scale))
            XCTAssertEqual(plan.networkAllowed, f.networkAllowed)
        }
    }

    func testLateOldThumbnailCannotEnableCaptureForReplacementPhoto() async throws {
        let f = BrowserPreviewFixture(requestCount: 2)
        addTeardownBlock { @MainActor in for gate in f.gates { await gate.release(false) } }
        let host = try await mount(UIHostingController(rootView: BrowserPreviewRoot(fixture: f)))
        defer { host.close() }
        try await require(f.started[0])
        f.photo = f.group.photos[176]
        try await require(f.started[1])
        // Deliberately return after cancellation, like a late PhotoKit callback.
        await f.gates[0].release(true)
        try await require(f.returned[0])
        try await settle(host)
        let pending = try previewControl(host)
        XCTAssertEqual(pending.photoID, f.photo.id)
        XCTAssertFalse(pending.canCapture)
        XCTAssertNil(pending.capture())
        pending.sendActions(for: .touchUpInside)
        XCTAssertEqual(f.browser.detailRoute?.photoID, f.photo.id)
        XCTAssertNil(f.browser.zoomFlight)
        await f.gates[1].release(true)
        try await require(f.returned[1])
        let loaded = try await readyPreviewControl(host)
        XCTAssertTrue(hasRedCenter(try XCTUnwrap(loaded.capture()).image))
        loaded.sendActions(for: .touchUpInside)
        XCTAssertEqual(f.browser.zoomFlight?.photoID, f.photo.id)
        XCTAssertEqual(f.provider.plans.map(\.id), [f.group.photos[175].id, f.group.photos[176].id])
    }

    func testRangeRecognizerPathPreviewsContiguousRangeReversalAndOneCommit() async throws {
        let h = BrowserGridHarness()
        let controller = h.controller()
        let host = try await mount(controller)
        defer { controller.shutdown(); host.close() }
        XCTAssertTrue(controller.rangePan.delegate === controller)
        XCTAssertEqual(controller.rangePan.minimumNumberOfTouches, 1)
        XCTAssertEqual(controller.rangePan.maximumNumberOfTouches, 1)
        XCTAssertTrue(controller.beginInteraction(at: 3))
        controller.configure(h.configuration())
        XCTAssertEqual(h.begins, 1)
        XCTAssertTrue(h.selected.isEmpty)
        XCTAssertTrue(controller.hasActiveDisplayLink)
        controller.updateInteraction(at: center(18, in: controller))
        XCTAssertEqual(controller.displayedSelection, Set(h.photos[3...18].map(\.id)))
        controller.updateInteraction(at: center(7, in: controller))
        XCTAssertEqual(controller.displayedSelection, Set(h.photos[3...7].map(\.id)), "Reversal restores the baseline beyond the endpoint")
        controller.updateInteraction(at: center(1, in: controller))
        XCTAssertEqual(controller.displayedSelection, Set(h.photos[1...3].map(\.id)))
        XCTAssertTrue(h.finishes.isEmpty, "Per-cell movement must not validate/commit")
        controller.endInteraction()
        XCTAssertFalse(controller.hasActiveDisplayLink)
        XCTAssertTrue(controller.awaitingValidation)
        XCTAssertEqual(h.finishes.count, 1)
        XCTAssertEqual(h.finishes[0].0, h.token)
        XCTAssertEqual(h.finishes[0].1, Set(h.photos[1...3].map(\.id)))
        XCTAssertTrue(h.selected.isEmpty)
        controller.configure(h.configuration())
        XCTAssertEqual(controller.displayedSelection, h.finishes[0].1, "Pending verification retains provisional checkmarks")
        XCTAssertFalse(controller.rangePan.isEnabled)
        controller.endInteraction() // Repeated ended delivery is inert.
        XCTAssertEqual(h.finishes.count, 1)
        h.selected = h.finishes[0].1
        h.selecting = false
        controller.configure(h.configuration())
        XCTAssertNil(controller.provisionalIDs)
        XCTAssertFalse(controller.awaitingValidation)
        XCTAssertEqual(controller.displayedSelection, h.selected)
        XCTAssertTrue(controller.rangePan.isEnabled)
    }

    func testSelectedAnchorDeselectsAndCancelRestoresBaselineWithoutCommit() async throws {
        let h = BrowserGridHarness()
        h.selected = Set(h.photos[2...15].map(\.id))
        let baseline = h.selected
        let controller = h.controller()
        let host = try await mount(controller)
        defer { controller.shutdown(); host.close() }
        XCTAssertTrue(controller.beginInteraction(at: 4))
        controller.configure(h.configuration())
        controller.updateInteraction(at: center(12, in: controller))
        XCTAssertEqual(controller.displayedSelection, baseline.subtracting(h.photos[4...12].map(\.id)))
        controller.updateInteraction(at: center(6, in: controller))
        XCTAssertEqual(controller.displayedSelection, baseline.subtracting(h.photos[4...6].map(\.id)))
        controller.cancelInteraction()
        XCTAssertEqual(h.cancels, 1)
        XCTAssertEqual(h.selected, baseline)
        XCTAssertEqual(controller.displayedSelection, baseline)
        XCTAssertNil(controller.provisionalIDs)
        XCTAssertFalse(controller.hasActiveDisplayLink)
        controller.endInteraction()
        XCTAssertTrue(h.finishes.isEmpty)
    }

    func testRealStateBridgeValidatesOnceOffMainAfterDragAndPreservesOtherGroup() async throws {
        let f = try await fixture()
        let group = f.grouping.groups[0]
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        let other = f.grouping.groups[1].photos[0].id
        f.cleanup.toggleSelection(other)
        let previousCalls = f.grouping.validation.calls.count
        func configuration() -> SimilarPhotoGroupGrid {
            SimilarPhotoGroupGrid(photos: group.photos, groupNumber: 1, sessionID: session,
                initialPhotoID: group.photos[0].id, selectedIDs: f.cleanup.selectedIDs,
                selectionMode: true, isSelecting: f.cleanup.isSelecting, enabled: true, hiddenPhotoID: nil,
                thumbnail: browserThumbnail, begin: { f.cleanup.beginRangeSelection(groupID: group.id) },
                finish: { f.cleanup.finishRangeSelection(token: $0, selectedInGroup: $1) },
                cancel: { f.cleanup.cancelRangeSelection() }, toggle: { f.cleanup.toggleSelection($0) },
                browse: { _ in XCTFail("Selecting must not open the viewer") }, initialTarget: { _, _ in })
        }
        let controller = SimilarPhotoGroupGridController()
        controller.configure(configuration())
        let host = try await mount(controller)
        defer { controller.shutdown(); host.close() }
        XCTAssertTrue(controller.beginInteraction(at: 3))
        controller.configure(configuration())
        controller.updateInteraction(at: center(18, in: controller))
        controller.updateInteraction(at: center(7, in: controller))
        XCTAssertEqual(f.cleanup.selectedIDs, [other])
        XCTAssertEqual(f.grouping.validation.calls.count, previousCalls)
        XCTAssertTrue(f.cleanup.isSelecting)
        XCTAssertFalse(SimilarPhotoGroupBrowser.canDelete(selectedCount: f.cleanup.selectedCount,
                         isSelecting: f.cleanup.isSelecting, isDeleting: false, isGrouping: false))
        controller.endInteraction()
        XCTAssertTrue(controller.awaitingValidation)
        XCTAssertEqual(f.cleanup.selectedIDs, [other], "No synchronous commit on finger-up")
        await f.cleanup.waitUntilIdle()
        let desired = Set(group.photos[3...7].map(\.id))
        XCTAssertEqual(f.cleanup.selectedIDs, desired.union([other]))
        let calls = Array(f.grouping.validation.calls.dropFirst(previousCalls))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.ids, group.photos[3...7].map(\.id))
        XCTAssertEqual(calls.first?.mainThread, false)
        controller.configure(configuration())
        XCTAssertNil(controller.provisionalIDs)
        XCTAssertFalse(f.cleanup.isSelecting)
        XCTAssertNil(f.cleanup.pendingDeletion)
        XCTAssertEqual(f.deletion.calls, 0)
        try await settle(host)
        attach(selectionReview(try capture(host)), name: "UIReview-similar-group-selection-dark")
    }

    func testEdgeTicksActuallyScrollBothDirectionsBoundedByNativeRowsAndStopAtEnd() async throws {
        let h = BrowserGridHarness()
        let controller = h.controller()
        let host = try await mount(controller, size: CGSize(width: 393, height: 400))
        defer { controller.shutdown(); host.close() }
        XCTAssertTrue(controller.beginInteraction(at: 0))
        controller.configure(h.configuration())
        let collection = controller.collectionView
        controller.updateInteraction(at: CGPoint(x: collection.bounds.maxX - 3, y: collection.bounds.maxY - 1))
        let before = collection.contentOffset.y
        controller.advanceAutoScroll(elapsed: 1.0 / 60)
        XCTAssertGreaterThan(collection.contentOffset.y, before)
        XCTAssertGreaterThan(controller.displayedSelection.count, 20)
        let once = collection.contentOffset.y
        controller.advanceAutoScroll(elapsed: 100) // A suspended frame cannot jump pages.
        let stride = SimilarPhotoGroupGeometry.side(width: collection.bounds.width) + 2
        XCTAssertLessThanOrEqual(collection.contentOffset.y - once, stride + 0.000_001)
        controller.updateInteraction(at: CGPoint(x: 3, y: collection.bounds.minY + 1))
        let downward = collection.contentOffset.y
        controller.advanceAutoScroll(elapsed: 1.0 / 60)
        XCTAssertLessThan(collection.contentOffset.y, downward)
        controller.endInteraction()
        let stopped = collection.contentOffset
        controller.advanceAutoScroll(elapsed: 1)
        XCTAssertEqual(collection.contentOffset, stopped)
        XCTAssertFalse(controller.hasActiveDisplayLink)
        XCTAssertEqual(h.finishes.count, 1)
    }

    func testBrowseVerticalStartCancellationBackgroundAndNewSessionCannotCommitOldPreview() async throws {
        XCTAssertTrue(SimilarPhotoGroupGridController.acceptsHorizontalStart(CGPoint(x: -100, y: 20)))
        XCTAssertFalse(SimilarPhotoGroupGridController.acceptsHorizontalStart(CGPoint(x: 20, y: -100)))
        XCTAssertFalse(SimilarPhotoGroupGridController.acceptsHorizontalStart(CGPoint(x: 30, y: 30)))
        let h = BrowserGridHarness()
        h.selectionMode = false
        let controller = h.controller()
        let host = try await mount(controller)
        defer { controller.shutdown(); host.close() }
        XCTAssertFalse(controller.rangePan.isEnabled)
        XCTAssertFalse(controller.beginInteraction(at: 0))
        controller.activateItem(at: 137)
        XCTAssertEqual(h.browsed, [h.photos[137].id])
        XCTAssertTrue(h.toggled.isEmpty)
        h.selectionMode = true
        controller.configure(h.configuration())
        controller.activateItem(at: 137)
        XCTAssertEqual(h.toggled, [h.photos[137].id])
        XCTAssertTrue(controller.beginInteraction(at: 0))
        controller.configure(h.configuration())
        XCTAssertFalse(controller.gestureRecognizer(controller.rangePan,
                         shouldRecognizeSimultaneouslyWith: controller.collectionView.panGestureRecognizer))
        controller.suspendInteraction() // Exact production background handler.
        XCTAssertFalse(controller.hasActiveDisplayLink)
        XCTAssertFalse(controller.rangePan.isEnabled)
        XCTAssertNil(controller.provisionalIDs)
        XCTAssertTrue(h.finishes.isEmpty)
        controller.configure(h.configuration())
        XCTAssertTrue(controller.beginInteraction(at: 1))
        controller.configure(h.configuration())
        controller.endInteraction()
        XCTAssertTrue(controller.awaitingValidation)
        h.session = UUID()
        h.selected = [h.photos[290].id]
        h.selecting = false
        controller.configure(h.configuration())
        XCTAssertNil(controller.provisionalIDs)
        XCTAssertFalse(controller.hasActiveDisplayLink)
        XCTAssertEqual(controller.displayedSelection, h.selected)
        let commits = h.finishes.count
        controller.updateInteraction(at: center(20, in: controller))
        controller.endInteraction()
        XCTAssertEqual(h.finishes.count, commits)
        controller.shutdown()
        XCTAssertFalse(controller.collectionView.gestureRecognizers?.contains(controller.rangePan) ?? true)
        XCTAssertFalse(controller.beginInteraction(at: 1))
    }

    func testRouteRejectsWrongPhotoAndStaleTargetAndDeleteGateBlocksSelectionValidation() throws {
        let group = browserGroups()[0]
        let browser = SimilarPhotoGroupBrowser()
        let session = UUID()
        browser.open(group: group, photoID: "not-a-member", sessionID: session)
        XCTAssertNil(browser.detailRoute)
        browser.open(group: group, photoID: group.photos[299].id, sessionID: session)
        let old = try XCTUnwrap(browser.detailRoute)
        browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        browser.didLayoutTarget(routeID: old.id, photoID: old.photoID, frame: CGRect(x: 2, y: 2, width: 70, height: 70))
        XCTAssertNil(browser.targetFrame)
        browser.viewPhoto(group.photos[137].id, in: group)
        XCTAssertEqual(browser.viewer?.id, group.photos[137].id)
        XCTAssertEqual(browser.viewer?.ids, group.photos.map(\.id))
        browser.invalidate(sessionID: UUID())
        XCTAssertNil(browser.detailRoute)
        XCTAssertNil(browser.viewer)
        XCTAssertNil(browser.zoomFlight)
        XCTAssertFalse(SimilarPhotoGroupBrowser.canDelete(selectedCount: 20, isSelecting: true, isDeleting: false, isGrouping: false))
        XCTAssertTrue(SimilarPhotoGroupBrowser.canDelete(selectedCount: 20, isSelecting: false, isDeleting: false, isGrouping: false))
        XCTAssertFalse(SimilarPhotoGroupBrowser.canDelete(selectedCount: 0, isSelecting: false, isDeleting: false, isGrouping: false))
        XCTAssertFalse(SimilarPhotoGroupBrowser.canDelete(selectedCount: 20, isSelecting: false, isDeleting: true, isGrouping: false))
        XCTAssertFalse(SimilarPhotoGroupBrowser.canDelete(selectedCount: 20, isSelecting: false, isDeleting: false, isGrouping: true))
    }

    func testNativeZoomUsesWindowGeometryAndCompletesBothSpringAndReducedMotionPaths() async throws {
        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let host = try await mount(controller)
        defer { host.close() }
        let zoom = SimilarPhotoZoomView(frame: CGRect(x: 0, y: 80, width: 393, height: 650))
        controller.view.addSubview(zoom)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 30)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        for reduced in [false, true] {
            let source = CGRect(x: 20, y: 350, width: 30, height: 30)
            let destination = CGRect(x: 80, y: 220, width: 76, height: 76)
            let flight = SimilarPhotoZoomFlight(routeID: UUID(), photoID: "TEST-zoom", image: image,
                                               source: source, destination: destination)
            let finished = expectation(description: reduced ? "Reduced-motion fade completed" : "Geometry spring completed")
            zoom.update(flight: flight, reduceMotion: reduced) { id in
                XCTAssertEqual(id, flight.id)
                finished.fulfill()
            }
            zoom.layoutIfNeeded()
            XCTAssertEqual(zoom.sourceFrame, zoom.convert(source, from: host.window))
            XCTAssertEqual(zoom.destinationFrame, zoom.convert(destination, from: host.window))
            let rendered = try XCTUnwrap(zoom.subviews.compactMap { $0 as? UIImageView }.first)
            XCTAssertTrue(rendered.image === image, "Animate a fixed snapshot, not a resizing thumbnail request")
            try await require(finished)
            XCTAssertEqual(rendered.frame, zoom.convert(destination, from: host.window))
            XCTAssertEqual(rendered.alpha, reduced ? 0 : 1)
            zoom.clear()
            XCTAssertNil(rendered.image)
        }
        // Passing the production reduceMotion input is not a claim that this
        // test changes the OS accessibility preference or measures smooth FPS.
    }

    func testActualComparisonCoverAndGalleryReturnDoNotPauseCleanupButBackgroundDoes() async throws {
        let f = try await fixture()
        let group = f.grouping.groups[0]
        f.cleanup.toggleSelection(group.photos[2].id)
        let selected = f.cleanup.selectedIDs
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        f.browser.open(group: group, photoID: group.photos[175].id, sessionID: session)
        let host = try await mount(f)
        defer { host.close() }
        let detail = try XCTUnwrap(controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        let offset = detail.collectionView.contentOffset
        f.browser.comparisonGroup = group
        try await waitForCover(host, present: true)
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.cleanup.groups.map(\.id), f.grouping.groups.map(\.id))
        XCTAssertEqual(f.cleanup.selectedIDs, selected)
        f.browser.comparisonGroup = nil
        try await waitForCover(host, present: false)
        try await settle(host)
        XCTAssertEqual(detail.collectionView.contentOffset, offset)
        XCTAssertEqual(f.cleanup.selectedIDs, selected)
        detail.activateItem(at: 175)
        XCTAssertEqual(f.browser.viewer?.id, group.photos[175].id)
        try await waitForCover(host, present: true)
        // The genuine viewer shows unauthorized placeholders in this host. This
        // verifies lifecycle/ID routing, not full-photo quality or PhotoKit reads.
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.cleanup.selectedIDs, selected)
        f.browser.viewer = nil
        try await waitForCover(host, present: false)
        try await settle(host)
        XCTAssertEqual(detail.collectionView.contentOffset, offset)
        XCTAssertEqual(f.cleanup.selectedIDs, selected)
        XCTAssertEqual(f.grouping.scans, 1)
        f.phase = .inactive
        try await settle(host)
        XCTAssertEqual(f.cleanup.selectionSessionID, session, "System confirmation inactivity is not background")
        f.phase = .background
        try await settle(host)
        XCTAssertNil(f.browser.detailRoute)
        XCTAssertNil(f.cleanup.selectionSessionID)
        XCTAssertTrue(f.cleanup.groups.isEmpty)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertFalse(detail.hasActiveDisplayLink)
        XCTAssertTrue(detail.isShutdown)
        f.phase = .active
        try await settle(host)
        XCTAssertEqual(f.grouping.scans, 1, "Resume does not scan")
        XCTAssertEqual(f.deletion.calls, 0)
    }

    // MARK: Public native geometry and fixtures

    private func previewControl(_ host: BrowserHost) throws -> SimilarPhotoPreviewControl {
        try XCTUnwrap(descendants(host.controller.view, SimilarPhotoPreviewControl.self).first)
    }

    private func readyPreviewControl(_ host: BrowserHost) async throws -> SimilarPhotoPreviewControl {
        let inspect: @MainActor () -> Bool = {
            self.descendants(host.controller.view, SimilarPhotoPreviewControl.self).first?.canCapture == true
        }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        try await require(XCTNSPredicateExpectation(predicate: predicate, object: nil))
        // Do not pre-capture/warm the image: the caller's first capture must
        // include the pending draw after the real onLoaded callback.
        return try previewControl(host)
    }

    private func hasRedCenter(_ image: UIImage) -> Bool {
        guard let pixel = image.cgImage?.cropping(to: CGRect(
            x: floor(image.size.width * image.scale / 2), y: floor(image.size.height * image.scale / 2),
            width: 1, height: 1)), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var rgba = [UInt8](repeating: 0, count: 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: info) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return decoded && rgba == [255, 0, 0, 255]
    }

    private func selectionReview(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let size = CGSize(width: image.size.width, height: image.size.height + 24)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ("TEST FIXTURE - synthetic colors - committed selection" as NSString).draw(
                at: CGPoint(x: 8, y: 6), withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: UIColor.white
                ])
            image.draw(at: CGPoint(x: 0, y: 24))
        }
    }

    private func center(_ index: Int, in controller: SimilarPhotoGroupGridController) -> CGPoint {
        let frame = SimilarPhotoGroupGeometry.frame(index: index, width: controller.collectionView.bounds.width)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func assertFiveColumns(_ collection: UICollectionView, file: StaticString = #filePath, line: UInt = #line) {
        let width = collection.bounds.width
        var previous: CGRect?
        for index in 0..<5 {
            guard let frame = collection.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
                XCTFail("Missing native cell attributes", file: file, line: line); return
            }
            XCTAssertEqual(frame.width, frame.height, file: file, line: line)
            XCTAssertEqual(frame.minY, 2, file: file, line: line)
            if let previous { XCTAssertEqual(frame.minX - previous.maxX, 2, accuracy: 0.000_001, file: file, line: line) }
            else { XCTAssertEqual(frame.minX, 2, file: file, line: line) }
            previous = frame
        }
        XCTAssertEqual(previous?.maxX ?? 0, width - 2, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(collection.contentSize.width, width, file: file, line: line)
    }

    private func fixture() async throws -> BrowserFixture {
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unauthorized native host; never reset or request Photos permission")
            throw BrowserTestFailure.readablePhotos
        }
        let fixture = BrowserFixture()
        let permission = PhotoLibraryClient.authorization
        addTeardownBlock { @MainActor in
            fixture.cleanup.pause()
            fixture.app.enterBackground()
            await fixture.cleanup.waitUntilIdle()
            await fixture.app.waitUntilIdle()
            fixture.app.thumbnails.clear()
            XCTAssertEqual(fixture.deletion.calls, 0)
            XCTAssertEqual(fixture.worker.unexpected, 0)
            XCTAssertEqual(fixture.translator.calls, 0)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(PhotoLibraryClient.authorization, permission)
            XCTAssertFalse(fixture.app.allowICloudDownload)
            XCTAssertTrue(fixture.app.results.isEmpty)
        }
        fixture.app.refresh()
        await fixture.app.waitUntilIdle()
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        XCTAssertTrue(fixture.cleanup.hasScanned)
        XCTAssertEqual(fixture.grouping.scans, 1)
        XCTAssertEqual(fixture.cleanup.threshold, 0.96)
        return fixture
    }

    private func mount(_ fixture: BrowserFixture, size: CGSize = CGSize(width: 393, height: 852),
                       dynamicType: DynamicTypeSize = .large) async throws -> BrowserHost {
        let root = BrowserFixtureRoot(fixture: fixture)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .preferredColorScheme(.dark)
        return try await mount(UIHostingController(rootView: root), size: size)
    }

    private func mount(_ controller: UIViewController, size: CGSize = CGSize(width: 393, height: 852)) async throws -> BrowserHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let host = BrowserHost(scene: scene, controller: controller, size: size)
        host.window.makeKeyAndVisible()
        try await settle(host)
        XCTAssertEqual(controller.view.bounds.size, size)
        return host
    }

    private func settle(_ host: BrowserHost) async throws {
        let laidOut = expectation(description: "Native browser layout completed")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); laidOut.fulfill() }
        }
        try await require(laidOut)
    }

    private func require(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Missing native event: \(expectation.expectationDescription)")
            throw BrowserTestFailure.layout
        }
    }

    private func waitForCover(_ host: BrowserHost, present: Bool) async throws {
        let inspect: @MainActor () -> Bool = {
            if present {
                guard let child = host.controller.presentedViewController else { return false }
                return child.viewIfLoaded?.window != nil && !child.isBeingPresented
            }
            return host.controller.presentedViewController == nil
        }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        try await require(XCTNSPredicateExpectation(predicate: predicate, object: nil))
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { controllers($0) }
    }

    private func capture(_ host: BrowserHost) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        var drew = false
        let image = UIGraphicsImageRenderer(size: host.controller.view.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(host.controller.view.bounds)
            drew = host.controller.view.drawHierarchy(in: host.controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drew)
        XCTAssertNotNil(image.cgImage)
        return image
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum BrowserTestFailure: Error { case readablePhotos, layout, syntheticUnavailable, unexpected }

/// Real PhotoThumbnailView/cache requests, but no PhotoKit or network access.
@MainActor
private final class BrowserPreviewFixture: ObservableObject {
    let group: SimilarPhotoGroup
    let browser = SimilarPhotoGroupBrowser()
    let session = UUID()
    let gates: [BrowserPreviewGate]
    let started: [XCTestExpectation]
    let returned: [XCTestExpectation]
    let provider: BrowserPreviewProvider
    @Published var photo: IndexedPhoto
    @Published var cache: PhotoThumbnailCache
    @Published var networkAllowed = false
    @Published var size = CGSize(width: 80, height: 80)
    @Published var scale: CGFloat = 2
    @Published var selected = false

    init(requestCount: Int) {
        let group = browserGroups()[0]
        let gates = (0..<requestCount).map { _ in BrowserPreviewGate() }
        let started = (0..<requestCount).map { XCTestExpectation(description: "Thumbnail request \($0) started") }
        let returned = (0..<requestCount).map { XCTestExpectation(description: "Thumbnail request \($0) returned") }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        let provider = BrowserPreviewProvider(image: image) { index in
            guard gates.indices.contains(index) else { return false }
            let success = await gates[index].wait { started[index].fulfill() }
            returned[index].fulfill()
            return success
        }
        self.group = group
        self.gates = gates
        self.started = started
        self.returned = returned
        self.provider = provider
        photo = group.photos[175]
        cache = PhotoThumbnailCache(library: provider)
    }
}

@MainActor
private struct BrowserPreviewRoot: View {
    @ObservedObject var fixture: BrowserPreviewFixture
    var body: some View {
        let photo = fixture.photo
        SimilarPhotoLoadedPreviewTile(photo: photo, cache: fixture.cache, networkAllowed: fixture.networkAllowed,
            label: "TEST preview", identifier: "TEST-preview", selected: fixture.selected, enabled: true,
            open: { fixture.browser.open(group: fixture.group, photoID: photo.id, sessionID: fixture.session, capture: $0) })
            .frame(width: fixture.size.width, height: fixture.size.height)
            .environment(\.displayScale, fixture.scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }
}

private actor BrowserPreviewGate {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?
    func wait(installed: @Sendable () -> Void) async -> Bool {
        if let result { return result }
        return await withCheckedContinuation {
            continuation = $0
            installed()
        }
    }
    func release(_ success: Bool) {
        guard result == nil else { return }
        result = success
        let pending = continuation
        continuation = nil
        pending?.resume(returning: success)
    }
}

private final class BrowserPreviewProvider: PhotoThumbnailProviding, @unchecked Sendable {
    struct Plan { let id: String; let targetSize: CGSize; let networkAllowed: Bool }
    let canReadImages = true
    let changeGeneration: UInt64? = 0
    private let image: UIImage
    private let load: @Sendable (Int) async -> Bool
    private let lock = NSLock()
    private var recorded: [Plan] = []
    init(image: UIImage, load: @escaping @Sendable (Int) async -> Bool) { self.image = image; self.load = load }
    var plans: [Plan] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ plan: Plan) -> Int {
        lock.lock(); defer { lock.unlock() }
        recorded.append(plan)
        return recorded.count - 1
    }
    func currentRevision(id: String) -> PhotoRevision? { PhotoRevision(id: id, modificationTime: 1) }
    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        throw BrowserTestFailure.unexpected
    }
    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        let index = record(Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed))
        guard await load(index) else { throw BrowserTestFailure.syntheticUnavailable }
        // Non-reusable on purpose: a duplicate loader cannot hide behind a hit.
        return .unverified(image: image, targetSize: targetSize)
    }
}

private func browserGroups() -> [SimilarPhotoGroup] {
    var groups: [SimilarPhotoGroup] = []
    var vector = [Float](repeating: 0, count: 768)
    vector[0] = 1
    for (group, count) in [300, 4, 3].enumerated() {
        var photos: [IndexedPhoto] = []
        for index in 0..<count {
            photos.append(IndexedPhoto(id: "TEST-browser-\(group)-\(index)", modificationTime: Double(index + 1),
                modelVersion: "TEST-browser", imageEmbedding: vector, creationTime: Double(index)))
        }
        groups.append(SimilarPhotoGroup(id: "TEST-browser-group-\(group)", photos: photos, minimumSimilarity: 0.98))
    }
    return groups
}

@MainActor
private func browserThumbnail(_ photo: IndexedPhoto) -> AnyView {
    let index = Int(photo.creationTime ?? 0)
    return AnyView(ZStack {
        Color(hue: Double(index % 12) / 12, saturation: 0.45, brightness: 0.65)
        Image(systemName: ["mountain.2.fill", "leaf.fill", "sun.max.fill"][index % 3])
            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
        VStack { Spacer(); HStack { Text("\(index + 1)").font(.system(size: 9, weight: .bold)); Spacer() } }
            .padding(2).foregroundStyle(.white)
    })
}

@MainActor
private final class BrowserGridHarness {
    let photos = browserGroups()[0].photos
    var session = UUID()
    let token = UUID()
    var selected: Set<String> = []
    var selecting = false
    var selectionMode = true
    var begins = 0
    var cancels = 0
    var finishes: [(UUID, Set<String>)] = []
    var browsed: [String] = []
    var toggled: [String] = []
    func configuration() -> SimilarPhotoGroupGrid {
        SimilarPhotoGroupGrid(photos: photos, groupNumber: 1, sessionID: session, initialPhotoID: photos[0].id,
            selectedIDs: selected, selectionMode: selectionMode, isSelecting: selecting, enabled: true,
            hiddenPhotoID: nil, thumbnail: browserThumbnail,
            begin: { self.begins += 1; self.selecting = true; return self.token },
            finish: { self.finishes.append(($0, $1)) },
            cancel: { self.cancels += 1; self.selecting = false },
            toggle: { self.toggled.append($0) }, browse: { self.browsed.append($0) }, initialTarget: { _, _ in })
    }
    func controller() -> SimilarPhotoGroupGridController {
        let controller = SimilarPhotoGroupGridController()
        controller.configure(configuration())
        return controller
    }
}

@MainActor
private final class BrowserFixture: ObservableObject {
    @Published var phase: ScenePhase = .active
    let browser = SimilarPhotoGroupBrowser()
    let grouping: BrowserGrouping
    let deletion: BrowserDeletion
    let worker: BrowserWorker
    let translator: BrowserTranslator
    let app: AppState
    let cleanup: SimilarPhotoCleanupState
    init() {
        let grouping = BrowserGrouping()
        let deletion = BrowserDeletion()
        let worker = BrowserWorker()
        let translator = BrowserTranslator()
        self.grouping = grouping
        self.deletion = deletion
        self.worker = worker
        self.translator = translator
        app = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
    }
}

@MainActor
private struct BrowserFixtureRoot: View {
    @ObservedObject var fixture: BrowserFixture
    var body: some View {
        VStack(spacing: 0) {
            Text("TEST FIXTURE · synthetic colors · no Photos")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).padding(.vertical, 6)
                .frame(maxWidth: .infinity).background(Color.black)
            SimilarPhotoCleanupSheet(state: fixture.cleanup, appState: fixture.app, browser: fixture.browser,
                thumbnailContent: browserThumbnail,
                comparisonImageSource: SimilarComparisonImageSource(
                    load: { _, _, _ in throw BrowserTestFailure.syntheticUnavailable },
                    validate: { _, _, _ in }))
        }
        .environment(\.scenePhase, fixture.phase)
    }
}

@MainActor
private final class BrowserGrouping: SimilarPhotoGrouping {
    let groups = browserGroups()
    let validation = BrowserValidationTrace()
    private(set) var scans = 0
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        scans += 1
        let ids = Set(groups.flatMap(\.photos).map(\.id))
        let validation = validation
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: ids.count, staleCount: 0,
            unindexedCount: 0, threshold: threshold, validatePhotos: { requested in
                guard Set(requested).isSubset(of: ids) else { throw PhotoDeletionError.accessChanged }
                validation.record(requested)
            })
    }
}

private final class BrowserValidationTrace: @unchecked Sendable {
    struct Call { let ids: [String]; let mainThread: Bool }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(Call(ids: ids, mainThread: Thread.isMainThread))
    }
}

@MainActor
private final class BrowserDeletion: PhotoDeleting {
    private(set) var calls = 0
    func delete(revisions: [PhotoRevision]) async throws {
        calls += 1
        XCTFail("Browser tests must not submit even a synthetic deletion")
        throw BrowserTestFailure.unexpected
    }
}

@MainActor
private final class BrowserWorker: PhotoWorkServicing {
    private(set) var unexpected = 0
    func refresh() async throws -> LibrarySummary { LibrarySummary(indexedCount: 307, modelVersion: "TEST-browser") }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw failure() }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary { throw failure() }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw failure() }
    func clear() async throws -> LibrarySummary { throw failure() }
    private func failure() -> BrowserTestFailure { unexpected += 1; XCTFail("Unexpected model/index/search work"); return .unexpected }
}

@MainActor
private final class BrowserTranslator: QueryTranslating {
    let isSupported = false
    private(set) var calls = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        calls += 1; XCTFail("Unexpected translation availability request"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        calls += 1; XCTFail("Unexpected translation"); throw BrowserTestFailure.unexpected
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        calls += 1; XCTFail("Unexpected translation preparation"); throw BrowserTestFailure.unexpected
    }
}

@MainActor
private final class BrowserHost {
    let window: UIWindow
    let controller: UIViewController
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, controller: UIViewController, size: CGSize) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        window.rootViewController = controller
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    func close() {
        controller.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}