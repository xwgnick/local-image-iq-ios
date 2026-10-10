import SwiftUI
import UIKit
import XCTest
@testable import LocalImageIQ

/// Native-host geometry/identity tests using only synthetic colors/metadata.
/// No actual gestures, personal images, PhotoKit mutations or timing claims.
@MainActor
final class SimilarCleanupRefinementPresentationTests: XCTestCase {
    func testTwoSlidersUseSavedSimilarityAndActualGroupBoundWithoutRecompute() async throws {
        let f = try await controlsFixture(in: self, sizes: [6, 4])
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        f.cleanup.selectGroup(f.grouping.groups[0].id)
        f.cleanup.selectGroup(f.grouping.groups[1].id)
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        try host.disclosure().sendActions(for: .touchUpInside)
        try await host.wait {
            controlsDescendants(host.controller.view, UISlider.self).count == 2
                && host.controls[.minimumCountSlider] != nil
        }
        let sliders = controlsDescendants(host.controller.view, UISlider.self)
        let minimum = try XCTUnwrap(sliders.first { $0.accessibilityIdentifier == "similar-cleanup-minimum-count" })
        let similarity = try XCTUnwrap(sliders.first { $0 !== minimum })
        XCTAssertEqual(minimum.minimumValue, 2)
        XCTAssertEqual(minimum.maximumValue, 6)
        XCTAssertEqual(minimum.value, 2)
        try assertMinimumCountHitArea(minimum, in: host)
        XCTAssertEqual(similarity.value, Float(45) / 49, accuracy: 0.000_001)
        minimum.setValue(5, animated: false)
        minimum.sendActions(for: .valueChanged)
        try await host.wait { f.cleanup.minimumGroupCount == 5 }
        XCTAssertEqual(f.cleanup.selectedCount, 10)
        XCTAssertEqual(f.cleanup.selectionSummary.hiddenPhotoCount, 4)
        XCTAssertEqual(f.cleanup.visibleGroups.count, 1)
        XCTAssertEqual(f.grouping.thresholds, [0.95])
        minimum.accessibilityIncrement()
        try await host.wait { f.cleanup.minimumGroupCount == 6 }
        minimum.accessibilityDecrement()
        try await host.wait { f.cleanup.minimumGroupCount == 5 }
        XCTAssertEqual(f.cleanup.selectedCount, 10)
        XCTAssertEqual(f.grouping.thresholds, [0.95])
        try host.attach(to: self, name: "UIReview-cleanup-refinement-hidden-selection")
    }

    func testInformationButtonsAreSeparate44PointActionsAndDoNotEditOrSelect() async throws {
        let f = try await controlsFixture(in: self)
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        try host.disclosure().sendActions(for: .touchUpInside)
        try await host.wait {
            controlsDescendants(host.controller.view, UIButton.self).filter {
                $0.accessibilityIdentifier?.hasPrefix("similar-cleanup-info-") == true
            }.count == 2
        }
        let buttons = controlsDescendants(host.controller.view, UIButton.self).filter {
            $0.accessibilityIdentifier?.hasPrefix("similar-cleanup-info-") == true
        }
        for button in buttons {
            XCTAssertEqual(button.bounds.width, 44, accuracy: host.pixel)
            XCTAssertEqual(button.bounds.height, 44, accuracy: host.pixel)
        }
        XCTAssertNotEqual(buttons[0].convert(buttons[0].bounds, to: host.window),
                          buttons[1].convert(buttons[1].bounds, to: host.window))
        let minimumInfo = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "similar-cleanup-info-minimumCount" })
        minimumInfo.sendActions(for: .touchUpInside)
        try await host.wait { self.alert(in: host.controller) != nil }
        let alert = try XCTUnwrap(alert(in: host.controller))
        XCTAssertEqual(alert.title, "每组最少张数")
        XCTAssertTrue(alert.message?.contains("不重新计算分组") == true)
        XCTAssertTrue(alert.message?.contains("不清空已选照片") == true)
        XCTAssertEqual(f.cleanup.minimumGroupCount, 2)
        XCTAssertEqual(f.cleanup.draftThreshold, 0.95)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertTrue(f.grouping.thresholds.isEmpty)
    }

    func testPrivacyHidesNativeGridPixelsButPreservesSameDetailAndViewportOnFreshReturn() async throws {
        let f = try await controlsFixture(in: self, sizes: [300, 4])
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let group = f.cleanup.groups[0]
        let revisions = f.cleanup.groups.flatMap(\.photos).map {
            PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime)
        }
        let library = RefinementLibrary(revisions)
        f.cleanup.configureBrowsingAccess(SimilarCleanupBrowsingAccess(library: library))
        f.browser.open(group: group, photoID: group.photos[175].id,
                       sessionID: try XCTUnwrap(f.cleanup.browsingSessionID))
        let route = try XCTUnwrap(f.browser.detailRoute)
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { self.grid(in: host.controller)?.initialScrollPhotoID == route.photoID }
        let grid = try XCTUnwrap(grid(in: host.controller))
        let offset = grid.collectionView.contentOffset
        f.cleanup.setAutomaticRefreshDeferred(true)
        f.cleanup.pause()
        try await host.wait { grid.collectionView.isHidden }
        XCTAssertEqual(f.browser.detailRoute?.id, route.id)
        XCTAssertTrue(self.grid(in: host.controller) === grid)
        XCTAssertFalse(grid.isShutdown)
        XCTAssertTrue(grid.collectionView.visibleCells.allSatisfy { $0.contentConfiguration == nil })
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertNil(f.cleanup.pendingDeletion)
        f.cleanup.resume()
        await f.cleanup.waitUntilIdle()
        try await host.wait { !grid.collectionView.isHidden }
        XCTAssertTrue(self.grid(in: host.controller) === grid)
        XCTAssertEqual(grid.collectionView.contentOffset, offset)
        XCTAssertEqual(f.browser.detailRoute?.id, route.id)
        XCTAssertFalse(f.cleanup.canSelect, "Fresh display proof still cannot authorize selection")
        XCTAssertEqual(f.grouping.thresholds, [0.95])
        library.revoke()
        f.cleanup.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: false)
        try await host.wait { f.browser.detailRoute == nil }
        XCTAssertTrue(f.cleanup.groups.isEmpty)
        XCTAssertFalse(f.cleanup.canBrowse)
    }

    func testFreshSourcePublicationRetainsNativeDetailWhileRotatingSelectionAuthority() async throws {
        let f = try await controlsFixture(in: self, sizes: [300, 4])
        let host = try ControlsNativeHost(content: AnyView(f.sheet(embedded: true)))
        defer { host.close() }
        try await host.wait { f.cleanup.canSelect }
        let group = f.cleanup.groups[0]
        f.browser.open(group: group, photoID: group.photos[175].id,
                       sessionID: try XCTUnwrap(f.cleanup.browsingSessionID))
        let route = try XCTUnwrap(f.browser.detailRoute)
        try await host.wait { self.grid(in: host.controller)?.initialScrollPhotoID == route.photoID }
        let grid = try XCTUnwrap(grid(in: host.controller))
        let offset = grid.collectionView.contentOffset
        let session = f.cleanup.selectionSessionID
        f.cleanup.setAutomaticRefreshDeferred(true)
        f.cleanup.indexSourceChanged()
        XCTAssertFalse(f.cleanup.canSelect)
        f.cleanup.setAutomaticRefreshDeferred(false)
        await f.cleanup.waitUntilIdle()
        try await host.settle()
        XCTAssertNotEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.browser.detailRoute?.id, route.id)
        XCTAssertTrue(self.grid(in: host.controller) === grid)
        XCTAssertEqual(grid.collectionView.contentOffset, offset)
        XCTAssertTrue(f.cleanup.canSelect)
    }

    func testInactiveSceneReleasesNativePixelsAndKeepsDetailOffsetWithoutGrantingAnOldConfirmation() async throws {
        let f = try await controlsFixture(in: self, sizes: [300, 4])
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let group = f.cleanup.groups[0]
        f.cleanup.toggleSelection(group.photos[175].id)
        f.cleanup.prepareDeletion()
        let intent = try XCTUnwrap(f.cleanup.pendingDeletion)
        let session = f.cleanup.selectionSessionID
        f.browser.open(group: group, photoID: group.photos[175].id,
                       sessionID: try XCTUnwrap(f.cleanup.browsingSessionID))
        let route = try XCTUnwrap(f.browser.detailRoute)
        let scene = RefinementSceneControl()
        let host = try ControlsNativeHost(content: AnyView(RefinementSceneFixture(fixture: f, scene: scene)))
        defer { host.close() }
        try await host.wait { self.grid(in: host.controller)?.initialScrollPhotoID == route.photoID }
        let grid = try XCTUnwrap(grid(in: host.controller))
        let offset = grid.collectionView.contentOffset
        XCTAssertFalse(grid.collectionView.visibleCells.isEmpty)
        XCTAssertTrue(grid.collectionView.visibleCells.allSatisfy { $0.contentConfiguration != nil })
        scene.phase = .inactive
        try await host.wait { grid.collectionView.isHidden && !f.cleanup.displayActive }
        XCTAssertTrue(grid.collectionView.accessibilityElementsHidden)
        XCTAssertTrue(grid.collectionView.visibleCells.allSatisfy { $0.contentConfiguration == nil })
        XCTAssertFalse(grid.rangePan.isEnabled)
        XCTAssertFalse(grid.beginInteraction(at: 175))
        grid.activateItem(at: 175)
        XCTAssertNil(f.browser.viewer)
        XCTAssertNil(f.browser.comparisonGroup)
        XCTAssertNil(f.browser.zoomFlight)
        XCTAssertNil(f.cleanup.pendingDeletion)
        XCTAssertEqual(f.cleanup.selectedIDs, Set(intent.revisions.map(\.id)))
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.browser.detailRoute?.id, route.id)
        XCTAssertTrue(self.grid(in: host.controller) === grid)
        XCTAssertFalse(grid.isShutdown)
        f.cleanup.confirmDeletion(intent)
        scene.phase = .active
        try await host.wait { !grid.collectionView.isHidden && f.cleanup.canSelect }
        XCTAssertEqual(grid.collectionView.contentOffset, offset)
        XCTAssertEqual(f.browser.detailRoute?.id, route.id)
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertTrue(grid.collectionView.visibleCells.allSatisfy { $0.contentConfiguration != nil })
        f.cleanup.prepareDeletion()
        let fresh = try XCTUnwrap(f.cleanup.pendingDeletion)
        f.cleanup.confirmDeletion(intent)
        XCTAssertEqual(f.cleanup.pendingDeletion?.id, fresh.id)
        XCTAssertEqual(f.grouping.thresholds, [0.95], "A transient inactive scene does not recompute groups")
    }

    private func assertMinimumCountHitArea(_ slider: UISlider, in host: ControlsNativeHost,
                                           file: StaticString = #filePath, line: UInt = #line) throws {
        // Measure the actual outer .frame(height: 44), not UISlider's intrinsic
        // drawing height (31 points on the failing simulator). Padding alone is
        // not a hit-target proof: also check window routing in both outer bands.
        let target = try XCTUnwrap(host.controls[.minimumCountSlider], file: file, line: line)
        let native = slider.convert(slider.bounds, to: host.window)
        let points = [CGPoint(x: target.midX, y: target.minY + host.pixel),
                      CGPoint(x: target.midX, y: target.maxY - host.pixel)]
        let hits = points.map { host.window.hitTest($0, with: nil) }
        var evidence = ["target=\(target)", "native=\(native)"]
        for (point, hit) in zip(points, hits) {
            if let hit {
                evidence.append("point=\(point) hit=\(String(reflecting: type(of: hit))) frame=\(hit.convert(hit.bounds, to: host.window))")
            } else { evidence.append("point=\(point) hit=nil") }
        }
        let attachment = XCTAttachment(string: evidence.joined(separator: "\n"))
        attachment.name = "Cleanup-minimum-slider-native-hit-geometry"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(target.height, 44, accuracy: host.pixel, file: file, line: line)
        XCTAssertGreaterThan(native.height, 0, file: file, line: line)
        XCTAssertEqual(native.midX, target.midX, accuracy: host.pixel, file: file, line: line)
        XCTAssertEqual(native.midY, target.midY, accuracy: host.pixel, file: file, line: line)
        XCTAssertGreaterThanOrEqual(native.minY + host.pixel, target.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(native.maxY, target.maxY + host.pixel, file: file, line: line)
        XCTAssertEqual(native.width, target.width, accuracy: host.pixel, file: file, line: line)
        for hit in hits {
            let hit = try XCTUnwrap(hit, "The 44-point slider target must receive touches", file: file, line: line)
            if hit === slider || hit.isDescendant(of: slider) { continue }
            // SwiftUI may own a touch wrapper. Accept only the slider's own
            // tightly bounded wrapper, never an arbitrary scroll/root ancestor.
            XCTAssertTrue(slider.isDescendant(of: hit), "Hit must belong to this slider", file: file, line: line)
            let frame = hit.convert(hit.bounds, to: host.window)
            XCTAssertEqual(frame.minX, target.minX, accuracy: host.pixel, file: file, line: line)
            XCTAssertEqual(frame.minY, target.minY, accuracy: host.pixel, file: file, line: line)
            XCTAssertEqual(frame.width, target.width, accuracy: host.pixel, file: file, line: line)
            XCTAssertEqual(frame.height, target.height, accuracy: host.pixel, file: file, line: line)
        }
        // This is native hit routing, not a claim of a delivered physical drag.
    }

    private func grid(in controller: UIViewController) -> SimilarPhotoGroupGridController? {
        controlsControllers(controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first
    }
    private func alert(in controller: UIViewController) -> UIAlertController? {
        if let alert = controller as? UIAlertController { return alert }
        if let presented = controller.presentedViewController, let alert = alert(in: presented) { return alert }
        for child in controller.children { if let alert = alert(in: child) { return alert } }
        return nil
    }
}

@MainActor
private final class RefinementSceneControl: ObservableObject {
    @Published var phase: ScenePhase = .active
}

@MainActor
private struct RefinementSceneFixture: View {
    let fixture: ControlsFixture
    @ObservedObject var scene: RefinementSceneControl
    var body: some View { fixture.sheet().environment(\.scenePhase, scene.phase) }
}