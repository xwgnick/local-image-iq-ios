import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Real sheet/Settings/detail hosts, public UIKit controls and layout geometry.
/// No private SwiftUI AX traversal; external XCUI still owns strict identifier
/// absence and SwiftUI button hittability. All metadata and pixels are synthetic.
@MainActor
final class SimilarCleanupControlsPresentationTests: XCTestCase {
    func testDefaultCollapsedArrowAloneExpandsAndDraftKeepsResultWithThreeNativeCaptures() async throws {
        let f = try await controlsFixture(in: self)
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        XCTAssertEqual(f.cleanup.draftThreshold, 0.90)
        XCTAssertTrue(controlsDescendants(host.controller.view, UISlider.self).isEmpty)
        XCTAssertNil(host.controls[.slider])
        XCTAssertNil(host.controls[.introduction], "The folded header has no purpose paragraph")
        XCTAssertNil(host.controls[.warning])
        let arrow = try host.disclosure()
        XCTAssertEqual(arrow.accessibilityIdentifier, "similar-cleanup-threshold-disclosure")
        XCTAssertEqual(arrow.accessibilityValue, "已收起")
        XCTAssertEqual(arrow.bounds.width, 44, accuracy: host.pixel)
        XCTAssertEqual(arrow.bounds.height, 44, accuracy: host.pixel)
        let arrowFrame = arrow.convert(arrow.bounds, to: host.window)
        let instruction = try XCTUnwrap(host.controls[.instruction])
        XCTAssertLessThanOrEqual(instruction.maxX, arrowFrame.minX)
        let instructionPoint = CGPoint(x: instruction.midX, y: instruction.midY)
        let hit = host.window.hitTest(instructionPoint, with: nil)
        XCTAssertFalse(hit === arrow || hit?.isDescendant(of: arrow) == true,
                       "The short label must not become part of the disclosure hit target")
        try host.attach(to: self, name: "UIReview-cleanup-v3-collapsed-090")

        arrow.sendActions(for: .touchUpInside)
        try await host.wait { host.controls[.value] != nil }
        XCTAssertEqual(arrow.accessibilityValue, "已展开")
        let slider = try XCTUnwrap(controlsDescendants(host.controller.view, UISlider.self).first)
        // SwiftUI normalizes the native UISlider; displayed ticks remain 50...99.
        let initialNativeValue = Float(40) / 49 // (90 - 50) / (99 - 50)
        XCTAssertEqual(slider.minimumValue, 0)
        XCTAssertEqual(slider.maximumValue, 1)
        XCTAssertEqual(slider.value, initialNativeValue, accuracy: 4 * initialNativeValue.ulp)
        try assertCenteredValue(host)
        try host.attach(to: self, name: "UIReview-cleanup-v3-expanded-090")

        let session = f.cleanup.selectionSessionID
        let groups = f.cleanup.displayGroups.map(\.id)
        slider.setValue(Float(35) / 49, animated: false) // (85 - 50) / (99 - 50)
        slider.sendActions(for: .valueChanged)
        try await host.wait { f.cleanup.draftThreshold == 0.85 && host.controls[.pending] != nil }
        XCTAssertNotNil(host.controls[.warning])
        XCTAssertEqual(f.cleanup.threshold, 0.90)
        XCTAssertEqual(f.cleanup.resultThreshold, 0.90)
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), groups)
        XCTAssertEqual(f.grouping.thresholds, [0.90], "Dragging never starts a read")
        XCTAssertTrue(f.cleanup.canUpdateResults)
        XCTAssertFalse(f.cleanup.canSelect)
        try assertCenteredValue(host)
        try host.attach(to: self, name: "UIReview-cleanup-v3-pending-085")
        arrow.sendActions(for: .touchUpInside)
        try await host.wait { host.controls[.slider] == nil && host.controls[.value] == nil }
        XCTAssertTrue(controlsDescendants(host.controller.view, UISlider.self).isEmpty)
        XCTAssertNil(host.controls[.warning], "A loose value does not add warning text to the folded header")
        XCTAssertEqual(f.cleanup.draftThreshold, 0.85, "Collapsing does not discard the draft")
        XCTAssertEqual(f.grouping.thresholds, [0.90])
    }

    func testMaximumType320KeepsTextAndValueInsideScrollableViewport() async throws {
        let f = try await controlsFixture(in: self, sizes: Array(repeating: 3, count: 12))
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let host = try ControlsNativeHost(content: AnyView(f.sheet()),
                                         size: CGSize(width: 320, height: 852), dynamicType: .accessibility5)
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        try host.disclosure().sendActions(for: .touchUpInside)
        try await host.wait { host.controls[.slider] != nil && host.controls[.value] != nil }
        try assertCenteredValue(host)
        XCTAssertNil(host.controls[.introduction])
        for (part, text) in [(SimilarCleanupControlPart.instruction, "相似度")] {
            let frame = try XCTUnwrap(host.controls[part])
            let font = UIFont.preferredFont(forTextStyle: .subheadline,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
            let required = (text as NSString).boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            XCTAssertGreaterThanOrEqual(frame.height + host.pixel, required.height,
                                       "Measure the real header, not just ScrollView.isHidden")
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, host.window.bounds.width + host.pixel)
        }
        let scroll = try host.overviewScroll()
        _ = try host.capture() // Realize the native lazy hierarchy before scrolling.
        try await host.settle()
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + host.pixel)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let start = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: start.x,
            y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom), animated: false)
        try await host.settle()
        XCTAssertGreaterThan(scroll.contentOffset.y, start.y)
        XCTAssertEqual(scroll.contentOffset.x, start.x, accuracy: host.pixel)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + host.pixel)
        XCTAssertEqual(f.grouping.thresholds.count, 1)
    }

    func testSettingsNeverContainsCleanupSliderWithOrWithoutController() async throws {
        let f = try await controlsFixture(in: self)
        for cleanup in [nil, f.cleanup] as [SimilarPhotoCleanupState?] {
            let host = try ControlsNativeHost(content: AnyView(SettingsSheet(state: f.app, cleanup: cleanup)))
            defer { host.close() }
            try await host.wait { !controlsDescendants(host.controller.view, UIScrollView.self).isEmpty }
            // Both normal and debug modes retain their own unrelated settings.
            // Advanced location weight stays collapsed; no cleanup control is created.
            for debug in [false, true] {
                f.app.debugToolsEnabled = debug
                try await host.settle()
                let form = try XCTUnwrap(controlsDescendants(host.controller.view, UIScrollView.self).first)
                for fraction in [CGFloat(0), 0.5, 1] {
                    let top = -form.adjustedContentInset.top
                    let bottom = max(top, form.contentSize.height - form.bounds.height + form.adjustedContentInset.bottom)
                    form.setContentOffset(CGPoint(x: 0, y: top + (bottom - top) * fraction), animated: false)
                    try await host.settle()
                    XCTAssertTrue(controlsDescendants(host.controller.view, UISlider.self).isEmpty)
                    XCTAssertTrue(controlsDescendants(host.controller.view, UIButton.self).filter {
                        $0.accessibilityIdentifier == "similar-cleanup-threshold-disclosure"
                    }.isEmpty)
                }
            }
        }
        XCTAssertTrue(f.grouping.thresholds.isEmpty)
        XCTAssertEqual(f.cleanup.draftThreshold, 0.90)
    }

    func testEmbeddedSliderCommitsOnReleaseNotValuePreviewAndHasNoEverydayUpdateButton() async throws {
        let f = try await controlsFixture(in: self)
        let host = try ControlsNativeHost(content: AnyView(f.sheet(embedded: true)))
        defer { host.close() }
        try await host.wait { f.cleanup.hasScanned && host.controls[.disclosure] != nil }
        XCTAssertNil(host.controls[.action])
        XCTAssertNil(host.controls[.pending], "A ready completed page needs no startup hint")
        try host.disclosure().sendActions(for: .touchUpInside)
        try await host.wait { host.controls[.slider] != nil }
        let slider = try XCTUnwrap(controlsDescendants(host.controller.view, UISlider.self).first)
        slider.sendActions(for: .touchDown)
        slider.setValue(Float(35) / 49, animated: false)
        slider.sendActions(for: .valueChanged)
        try await host.wait { f.cleanup.hasPendingThresholdChange }
        XCTAssertEqual(f.grouping.thresholds, [0.90])
        XCTAssertEqual(f.cleanup.resultThreshold, 0.90)
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertNil(host.controls[.action])
        slider.sendActions(for: .touchUpInside)
        try await host.wait { f.cleanup.resultThreshold == 0.85 && !f.cleanup.isGrouping }
        XCTAssertEqual(f.grouping.thresholds, [0.90, 0.85])
        XCTAssertNil(host.controls[.pending])
        XCTAssertNil(host.controls[.action])
        XCTAssertTrue(f.cleanup.canSelect)
        // Public UISlider event dispatch verifies wiring, not a physical drag.
    }

    func testInitialSyncDeferralAndChildOnlySettlementDriveEmbeddedLifecycle() async throws {
        let sync = ControlsSyncGate()
        let f = try await controlsFixture(in: self, sync: sync)
        f.app.photoSync.updateAvailability(ready: true, networkAllowed: false)
        XCTAssertEqual(f.app.photoSync.phase, .checking)
        let host = try ControlsNativeHost(content: AnyView(f.sheet(embedded: true)))
        defer { host.close() }
        addTeardownBlock { @MainActor in
            sync.release()
            await f.app.photoSync.waitUntilIdle()
        }
        try await host.wait { f.cleanup.isPageVisible && sync.started }
        XCTAssertTrue(f.grouping.thresholds.isEmpty, "Initial deferral precedes enterPage(ready: true)")
        XCTAssertFalse(f.cleanup.isGrouping)
        XCTAssertFalse(f.cleanup.isRestoring)
        XCTAssertNotNil(host.controls[.pending])
        XCTAssertNil(host.controls[.action])
        // Deliberately isolate child publications: no AppState callback/summary
        // update can accidentally cause this view to observe settlement.
        f.app.photoSync.onCompleted = { _ in }
        f.app.photoSync.onSettled = {}
        f.app.photoSync.cancel()
        try await host.wait { f.app.photoSync.phase == .cancelling }
        XCTAssertTrue(f.grouping.thresholds.isEmpty)
        sync.release()
        try await host.wait { f.app.photoSync.phase == .cancelled && f.cleanup.hasScanned }
        XCTAssertEqual(f.grouping.thresholds, [0.90])
        XCTAssertNil(host.controls[.pending])
        XCTAssertNil(host.controls[.action])
    }

    func testPresentationInputDefersOnlyUnsettledSyncPhases() {
        for phase in [PhotoSyncState.Phase.idle, .checking, .updating, .cancelling,
                      .cancelled, .completed, .needsAttention, .failed] {
            let input = CleanupPresentationInput(epoch: UUID(), authorization: 3, ready: true,
                pageActive: true, phase: .active, syncPhase: phase)
            XCTAssertEqual(input.defersAutomaticRefresh, [.checking, .updating, .cancelling].contains(phase))
        }
    }

    func testCompletedZeroGroupsShowsSinglePendingStateForStandaloneDraft() async throws {
        let f = try await controlsFixture(in: self, sizes: [])
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let host = try ControlsNativeHost(content: AnyView(f.sheet()))
        defer { host.close() }
        try await host.wait { host.controls[.disclosure] != nil }
        f.cleanup.setDraftThreshold(0.85)
        try await host.wait { host.controls[.pending] != nil }
        XCTAssertTrue(f.cleanup.hasScanned)
        XCTAssertTrue(f.cleanup.displayGroups.isEmpty)
        XCTAssertEqual(f.cleanup.resultThreshold, 0.90)
        XCTAssertTrue(f.cleanup.canUpdateResults)
        f.cleanup.updateResults()
        f.cleanup.updateResults()
        await f.cleanup.waitUntilIdle()
        try await host.wait { host.controls[.pending] == nil }
        XCTAssertEqual(f.grouping.thresholds, [0.90, 0.85])
        XCTAssertEqual(f.cleanup.resultThreshold, 0.85)
        XCTAssertFalse(f.cleanup.canUpdateResults, "An unchanged completed result cannot queue another update")
    }

    func testDisplayOrderAndPendingOrSourceChangedDetailRetainNativeBrowseNotSelection() async throws {
        let f = try await controlsFixture(in: self)
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let originalIDs = f.cleanup.groups.map(\.id)
        XCTAssertEqual(f.cleanup.displayGroups.map(\.id), originalIDs.reversed().map { $0 })
        let group = try XCTUnwrap(f.cleanup.displayGroups.first)
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        f.browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        let route = try XCTUnwrap(f.browser.detailRoute)
        // Host the actual production detail directly, so its browse callback
        // is observable without opening a real PhotoGallery/Photos request.
        let host = try ControlsNativeHost(content: AnyView(SimilarPhotoGroupDetail(group: group,
            number: try XCTUnwrap(f.cleanup.displayNumber(for: group.id)), route: route,
            state: f.cleanup, browser: f.browser, thumbnail: { _ in AnyView(Color.orange) })))
        defer { host.close() }
        try await host.wait { !controlsControllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.isEmpty }
        let grid = try XCTUnwrap(controlsControllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        f.cleanup.setDraftThreshold(0.85)
        try await host.settle()
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertFalse(grid.rangePan.isEnabled)
        XCTAssertFalse(grid.beginInteraction(at: 0))
        grid.activateItem(at: 0)
        XCTAssertEqual(f.browser.viewer?.id, group.photos[0].id)
        XCTAssertEqual(f.browser.viewer?.ids, group.photos.map(\.id))
        f.browser.viewer = nil
        f.cleanup.setDraftThreshold(0.90)
        f.cleanup.indexSourceChanged()
        try await host.settle()
        XCTAssertTrue(f.cleanup.needsRegroup)
        XCTAssertFalse(f.cleanup.canSelect)
        XCTAssertEqual(f.cleanup.selectionSessionID, session)
        XCTAssertEqual(f.cleanup.groups.map(\.id), originalIDs)
        XCTAssertTrue(controlsControllers(host.controller).contains { $0 === grid })
        grid.activateItem(at: 1)
        XCTAssertEqual(f.browser.viewer?.id, group.photos[1].id)
        let cell = try XCTUnwrap(grid.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        XCTAssertEqual(cell.accessibilityLabel, "第1组，照片1")
        XCTAssertEqual(cell.accessibilityHint, "查看完整照片")
        XCTAssertEqual(cell.accessibilityIdentifier, "similar-cleanup-detail-photo-1")
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        XCTAssertEqual(f.grouping.thresholds, [0.90])
    }

    private func assertCenteredValue(_ host: ControlsNativeHost) throws {
        let slider = try XCTUnwrap(host.controls[.slider])
        let value = try XCTUnwrap(host.controls[.value])
        let native = try XCTUnwrap(controlsDescendants(host.controller.view, UISlider.self).first)
        let nativeFrame = native.convert(native.bounds, to: host.window)
        XCTAssertEqual(value.midX, slider.midX, accuracy: host.pixel)
        XCTAssertEqual(value.midX, nativeFrame.midX, accuracy: host.pixel)
        XCTAssertGreaterThanOrEqual(value.minY + host.pixel, slider.maxY)
        XCTAssertGreaterThan(value.width, 0)
        XCTAssertEqual(value.height, UIFont.systemFont(ofSize: 11).lineHeight, accuracy: host.pixel)
        XCTAssertLessThanOrEqual(value.maxX, host.window.bounds.width + host.pixel)
    }
}

// Shared only by the two new presentation suites. Reuses the established
// UIHostingController/window, main-queue layout and native screenshot pattern.
enum ControlsPresentationFailure: Error { case readablePhotos, layout, drawing, unexpectedWork }

@MainActor
final class ControlsNativeHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private let measurements = ControlsMeasurements()
    private weak var previousKey: UIWindow?
    var controls: [SimilarCleanupControlPart: CGRect] { measurements.controls }
    var sync: [PhotoSyncFramePart: CGRect] { measurements.sync }
    var tabs: [PrimaryPage: CGRect] { measurements.tabs }
    var pixel: CGFloat { 1 / window.screen.scale }

    init(content: AnyView, size: CGSize = CGSize(width: 393, height: 852), dynamicType: DynamicTypeSize = .large) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let measured = measurements
        let root = content
            .onPreferenceChange(SimilarCleanupControlFrames.self) { measured.controls = $0 }
            .onPreferenceChange(PhotoSyncFrames.self) { measured.sync = $0 }
            .onPreferenceChange(PrimaryNavigationFrames.self) { measured.tabs = $0 }
            .environment(\.scenePhase, .active).environment(\.dynamicTypeSize, dynamicType)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight).preferredColorScheme(.dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        controller = UIHostingController(rootView: AnyView(root))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }

    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    func wait(file: StaticString = #filePath, line: UInt = #line,
              _ observed: @escaping @MainActor () -> Bool) async throws {
        let inspect: @MainActor () -> Bool = { self.layout(); return observed() }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Missing native layout/publication milestone", file: file, line: line)
            throw ControlsPresentationFailure.layout
        }
        try await settle()
    }

    func settle() async throws {
        let settled = XCTestExpectation(description: "Native presentation transaction delivered")
        DispatchQueue.main.async {
            self.layout()
            DispatchQueue.main.async { self.layout(); settled.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 5) == .completed else {
            throw ControlsPresentationFailure.layout
        }
    }

    func disclosure() throws -> UIButton {
        let buttons = controlsDescendants(controller.view, UIButton.self).filter {
            $0.accessibilityIdentifier == "similar-cleanup-threshold-disclosure"
        }
        XCTAssertEqual(buttons.count, 1)
        return try XCTUnwrap(buttons.first)
    }

    func overviewScroll() throws -> UIScrollView {
        let views = controlsDescendants(controller.view, UIScrollView.self).filter { !($0 is UICollectionView) }
        XCTAssertEqual(views.count, 1)
        return try XCTUnwrap(views.first)
    }

    func capture() throws -> UIImage {
        layout()
        let view = controller.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(view.bounds)
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drawn else { XCTFail("UIKit capture failed"); throw ControlsPresentationFailure.drawing }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, Int((view.bounds.width * format.scale).rounded()))
        XCTAssertEqual(cg.height, Int((view.bounds.height * format.scale).rounded()))
        return image
    }

    func attach(to test: XCTestCase, name: String) throws {
        let attachment = XCTAttachment(image: try capture())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
private final class ControlsMeasurements {
    var controls: [SimilarCleanupControlPart: CGRect] = [:]
    var sync: [PhotoSyncFramePart: CGRect] = [:]
    var tabs: [PrimaryPage: CGRect] = [:]
}

@MainActor
func controlsDescendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { controlsDescendants($0, type) }
}

@MainActor
func controlsControllers(_ root: UIViewController) -> [UIViewController] {
    [root] + root.children.flatMap { controlsControllers($0) }
}

@MainActor
final class ControlsFixture {
    let app: AppState
    let cleanup: SimilarPhotoCleanupState
    let grouping: ControlsGrouping
    let worker = ControlsWorker()
    let browser = SimilarPhotoGroupBrowser()
    let navigation = PrimaryNavigationPresentation()

    init(sizes: [Int], sync: (any PhotoSyncServicing)?, indexAccess: IndexAccessCoordinator?) {
        app = AppState(worker: worker, authorizationStatus: { .authorized },
                       queryTranslator: ControlsTranslator(), syncService: sync, indexAccess: indexAccess)
        grouping = ControlsGrouping(sizes: sizes)
        cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: ControlsDeletion(),
                                           indexAccess: indexAccess)
    }

    func sheet(embedded: Bool = false) -> some View {
        SimilarPhotoCleanupSheet(state: cleanup, appState: app, browser: browser,
                                 thumbnailContent: { _ in AnyView(Color.orange.opacity(0.6)) }, embedded: embedded)
    }
}

@MainActor
func controlsFixture(in test: XCTestCase, sizes: [Int] = [4, 31, 3],
                     sync: (any PhotoSyncServicing)? = nil,
                     indexAccess: IndexAccessCoordinator? = nil) async throws -> ControlsFixture {
    guard !PhotoLibraryClient.canRead else {
        XCTFail("Use an unreadable Photos host; never request/reset authorization")
        throw ControlsPresentationFailure.readablePhotos
    }
    let authorization = PhotoLibraryClient.authorization
    let fixture = ControlsFixture(sizes: sizes, sync: sync, indexAccess: indexAccess)
    test.addTeardownBlock { @MainActor in
        fixture.cleanup.pause(); fixture.app.enterBackground()
        await fixture.cleanup.waitUntilIdle(); await fixture.app.waitUntilIdle()
        fixture.app.thumbnails.clear()
        XCTAssertEqual(PhotoLibraryClient.authorization, authorization)
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertEqual(fixture.worker.unexpectedCalls, 0)
    }
    // Read synthetic summary only; NEVER AppState.start() or a real worker.
    fixture.app.refresh()
    await fixture.app.waitUntilIdle()
    XCTAssertTrue(fixture.app.modelsReady)
    XCTAssertFalse(fixture.app.library.canReadImages)
    XCTAssertFalse(fixture.app.photoSync.visible)
    return fixture
}

@MainActor
final class ControlsGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    private(set) var thresholds: [Float] = []
    init(sizes: [Int]) {
        var groups: [SimilarPhotoGroup] = []
        for (ordinal, count) in sizes.enumerated() {
            var photos: [IndexedPhoto] = []
            for index in 0..<count {
                photos.append(IndexedPhoto(id: "TEST-controls-\(ordinal)-\(index)", modificationTime: 200,
                    modelVersion: "TEST-controls", imageEmbedding: TestFixtures.vector(), creationTime: Double(ordinal * 100 + index)))
            }
            groups.append(SimilarPhotoGroup(id: "TEST-group-\(ordinal)", photos: photos, minimumSimilarity: 1))
        }
        self.groups = groups
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        thresholds.append(threshold)
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: groups.reduce(0) { $0 + $1.photos.count },
                                           staleCount: 0, unindexedCount: 0, threshold: threshold)
    }
}

@MainActor
final class ControlsWorker: PhotoWorkServicing {
    let summary = LibrarySummary(indexedCount: 37, modelVersion: "TEST-controls")
    private(set) var unexpectedCalls = 0
    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        let hits = (0..<37).map { SearchHit(photo: TestFixtures.photo(id: "TEST-controls-search-\($0)").photo, score: Float(37 - $0) / 37) }
        return SearchResponse(summary: summary, hits: hits)
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> ControlsPresentationFailure {
        unexpectedCalls += 1; XCTFail("Presentation must not index/OCR/clear"); return .unexpectedWork
    }
}

private struct ControlsDeletion: PhotoDeleting {
    func delete(revisions: [PhotoRevision]) async throws {
        XCTFail("Presentation must never submit even fake deletion")
        throw ControlsPresentationFailure.unexpectedWork
    }
}

@MainActor
private final class ControlsTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("Presentation must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Presentation must not download language packs"); throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class ControlsSyncGate: PhotoSyncServicing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var started = false
    func synchronize(networkAllowed: Bool,
                     progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        try Task.checkCancellation()
        return PhotoSyncResult(summary: LibrarySummary(indexedCount: 37, modelVersion: "TEST-controls"),
                               progress: PhotoSyncProgress())
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}