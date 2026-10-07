import XCTest
import SwiftUI
import UIKit
import ImageIQCore
@testable import LocalImageIQ

/// Hosted production detail + public UIKit bounds, not a height-policy unit
/// test or XCUI gesture test. Four tests cover eight light/dark configurations.
/// All 300 photos and every service are synthetic; no Photos client is created.
@MainActor
final class SimilarPhotoGroupHeaderLayoutTests: XCTestCase {
    func testRegular393By852HasNoUnusedHeaderSpaceAndCentersExactPhotoAmong300InBothThemes() async throws {
        try await checkLayout(width: 393, dynamicType: .large, targetIndex: 175, capped: false)
    }

    func testRegular320By852HasNoUnusedHeaderSpaceAndCentersExactPhotoAmong300InBothThemes() async throws {
        try await checkLayout(width: 320, dynamicType: .large, targetIndex: 175, capped: false)
    }

    func testMaximum393By852ScrollsHeaderWithin45PercentAndKeepsLastOf300VisibleInBothThemes() async throws {
        try await checkLayout(width: 393, dynamicType: .accessibility5, targetIndex: 299, capped: true)
    }

    func testMaximum320By852ScrollsHeaderWithin45PercentAndKeepsLastOf300VisibleInBothThemes() async throws {
        try await checkLayout(width: 320, dynamicType: .accessibility5, targetIndex: 299, capped: true)
    }

    private func checkLayout(width: CGFloat, dynamicType: DynamicTypeSize,
                             targetIndex: Int, capped: Bool) async throws {
        for theme in [ColorScheme.light, .dark] {
            let fixture = HeaderLayoutFixture()
            fixture.state.scan()
            await fixture.state.waitUntilIdle()
            XCTAssertTrue(fixture.state.hasScanned)
            let group = try XCTUnwrap(fixture.state.groups.first)
            XCTAssertEqual(group.photos.count, 300)
            let wanted = group.photos[targetIndex].id
            fixture.browser.open(group: group, photoID: wanted,
                                 sessionID: try XCTUnwrap(fixture.state.selectionSessionID))
            let route = try XCTUnwrap(fixture.browser.detailRoute)
            let measured = HeaderLayoutMeasurements()
            let detail = SimilarPhotoGroupDetail(group: group, number: 1, route: route,
                state: fixture.state, browser: fixture.browser, thumbnail: { photo in
                    AnyView(Color(hue: (photo.creationTime ?? 0).truncatingRemainder(dividingBy: 12) / 12,
                                  saturation: 0.45, brightness: 0.65))
                })
                .overlay {
                    HeaderLayoutViewportProbe(measurements: measured)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onPreferenceChange(SimilarPhotoGroupHeaderHeightPreference.self) { measured.naturalHeight = $0 }
                .environment(\.dynamicTypeSize, dynamicType)
                .environment(\.scenePhase, .active)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.colorScheme, theme)
            let controller = UIHostingController(rootView: detail)
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
            let size = CGSize(width: width, height: 852)
            let host = HeaderLayoutHost(scene: scene, controller: controller, size: size, theme: theme)
            defer {
                host.close()
                fixture.state.pause()
            }
            host.window.makeKeyAndVisible()
            host.layout()

            // Wait for the production natural-height preference, a native
            // viewport layout in this window, and the one-shot target callback.
            // Never use a guessed render/animation sleep. The geometry
            // assertions below are deliberately NOT part of this readiness gate.
            let inspect: @MainActor () -> Bool = {
                host.layout()
                return measured.naturalHeight > 0 && measured.viewportBounds.height > 0
                    && measured.viewportWindow === host.window && measured.viewportFrame != nil
                    && fixture.browser.targetFrame != nil
            }
            let predicate = NSPredicate { _, _ in
                if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
                return DispatchQueue.main.sync { inspect() }
            }
            let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            ready.expectationDescription = "Measured header and native target at \(width)x852, \(dynamicType), \(theme)"
            guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
                XCTFail("Missing layout event: \(ready.expectationDescription); \(layoutDiagnostics(host: host, measured: measured, browser: fixture.browser))")
                throw HeaderLayoutFailure.layout
            }
            host.layout()
            let context = "\(width)x852 \(dynamicType) \(theme): \(layoutDiagnostics(host: host, measured: measured, browser: fixture.browser))"
            XCTAssertEqual(controller.view.bounds.size, size, context)
            let grids = controllers(controller).compactMap { $0 as? SimilarPhotoGroupGridController }
            XCTAssertEqual(grids.count, 1, context)
            let grid = try XCTUnwrap(grids.first, context)
            let collection = grid.collectionView
            let headers = descendants(controller.view, UIScrollView.self).filter { !($0 is UICollectionView) }
            XCTAssertEqual(headers.count, 1, "One header scroll view, not duplicate fitting/hidden header copies; \(context)")
            let header = try XCTUnwrap(headers.first, context)
            let pixel = 1 / host.window.screen.scale
            let natural = measured.naturalHeight
            let viewportSize = measured.viewportBounds.size
            let viewportFrame = try XCTUnwrap(measured.viewportFrame, context)
            let safeAreaFrame = controller.view.convert(controller.view.safeAreaLayoutGuide.layoutFrame, to: host.window)
            let cap = viewportSize.height * 0.45
            let allocated = min(natural, cap)
            let headerInsets = header.adjustedContentInset
            let rawHeaderFrame = header.convert(header.bounds, to: host.window)
            let usableHeaderBounds = header.bounds.inset(by: headerInsets)
            let usableHeaderFrame = header.convert(usableHeaderBounds, to: host.window)
            let gridFrame = collection.convert(collection.bounds, to: host.window)

            // This test hosts the detail directly, without ignoring safe areas.
            // The full-size overlay measures the root GeometryReader's space,
            // not the whole window. All endpoint comparisons use window coords.
            XCTAssertTrue(measured.viewportWindow === host.window, context)
            XCTAssertGreaterThan(viewportSize.width, 0, context)
            XCTAssertGreaterThan(viewportSize.height, 0, context)
            assertRect(viewportFrame, equals: safeAreaFrame, pixel: pixel, context: context)
            XCTAssertEqual(viewportFrame.width, viewportSize.width, accuracy: pixel, context)
            XCTAssertEqual(viewportFrame.height, viewportSize.height, accuracy: pixel, context)
            // UIKit can extend the raw scroll view into the system safe area.
            // Inset its actual bounds (including the content-offset origin)
            // before conversion; that excluded area is not unused header space.
            XCTAssertEqual(rawHeaderFrame.minY + headerInsets.top, viewportFrame.minY, accuracy: pixel, context)
            XCTAssertEqual(rawHeaderFrame.maxY - headerInsets.bottom, usableHeaderFrame.maxY, accuracy: pixel, context)
            XCTAssertEqual(rawHeaderFrame.minX + headerInsets.left, viewportFrame.minX, accuracy: pixel, context)
            XCTAssertEqual(rawHeaderFrame.maxX - headerInsets.right, viewportFrame.maxX, accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.minY, viewportFrame.minY, accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.minX, viewportFrame.minX, accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.width, viewportSize.width, accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.width, rawHeaderFrame.width - headerInsets.left - headerInsets.right,
                           accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.height, rawHeaderFrame.height - headerInsets.top - headerInsets.bottom,
                           accuracy: pixel, context)
            XCTAssertEqual(gridFrame.maxY, viewportFrame.maxY, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.minX, viewportFrame.minX, accuracy: pixel, context)

            // Compare raw laid-out content with the actual usable scroll viewport
            // and native grid, without clamping or inferring the measured frame
            // from the cap. The old maxHeight reservation leaves a large gap here
            // even though the five-column/count/target tests still pass.
            XCTAssertEqual(header.contentSize.height, natural, accuracy: pixel, context)
            XCTAssertEqual(usableHeaderFrame.height, allocated, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.minY, usableHeaderFrame.maxY, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.minY - usableHeaderFrame.minY, allocated, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.maxY - usableHeaderFrame.minY, viewportSize.height, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.width, viewportSize.width, accuracy: pixel, context)
            XCTAssertLessThanOrEqual(header.contentSize.width, usableHeaderBounds.width + pixel, context)
            XCTAssertGreaterThan(gridFrame.height, 0, context)
            XCTAssertGreaterThanOrEqual(gridFrame.height + pixel, viewportSize.height * 0.55, context)
            XCTAssertEqual(header.isScrollEnabled, capped, context)
            XCTAssertTrue(collection.isScrollEnabled, "Disabling a fitting header must not disable the photo grid; \(context)")
            if capped {
                XCTAssertGreaterThan(natural, cap, "Maximum-size text must exercise overflowing content, not just the policy; \(context)")
                XCTAssertEqual(usableHeaderFrame.height, cap, accuracy: pixel, context)
            } else {
                XCTAssertLessThan(natural, cap - pixel, "Regular text must exercise the short-header regression; \(context)")
                XCTAssertEqual(gridFrame.minY, usableHeaderFrame.minY + natural, accuracy: pixel,
                               "The grid must start at the measured content bottom, within ONE device pixel; \(context)")
                XCTAssertEqual(usableHeaderFrame.height - header.contentSize.height, 0, accuracy: pixel,
                               "No unused space inside the normal header; \(context)")
            }

            XCTAssertEqual(collection.numberOfItems(inSection: 0), 300, context)
            XCTAssertEqual(grid.initialScrollPhotoID, wanted, context)
            XCTAssertEqual(fixture.browser.detailRoute?.photoID, wanted, context)
            assertFiveColumns(collection, pixel: pixel, context: context)
            let targetFrame = try assertTarget(grid, index: targetIndex, host: host, browser: fixture.browser,
                                              pixel: pixel, context: context)
            if !capped {
                XCTAssertEqual(targetFrame.midY, gridFrame.midY, accuracy: pixel,
                    "The middle target must be centered using the measured-header viewport, not the initial zero-height header; \(context)")
            }

            if capped {
                // Exercise the real header UIScrollView independently. Reaching
                // its content bottom must not move the grid or its exact target.
                let before = header.contentOffset.y
                let bottom = header.contentSize.height - header.bounds.height + header.adjustedContentInset.bottom
                header.setContentOffset(CGPoint(x: header.contentOffset.x, y: bottom), animated: false)
                host.layout()
                let endContext = "Header end: \(context); after=\(layoutDiagnostics(host: host, measured: measured, browser: fixture.browser))"
                XCTAssertGreaterThan(header.contentOffset.y, before, endContext)
                XCTAssertEqual(header.contentOffset.y, bottom, accuracy: pixel, endContext)
                XCTAssertEqual(header.contentOffset.y + header.bounds.height - header.adjustedContentInset.bottom,
                               natural, accuracy: pixel, "All header content is reachable without expanding its viewport; \(endContext)")
                assertRect(collection.convert(collection.bounds, to: host.window), equals: gridFrame,
                           pixel: pixel, context: endContext)
                _ = try assertTarget(grid, index: targetIndex, host: host, browser: fixture.browser,
                                     pixel: pixel, context: endContext)
            }

            // The real browse callback still carries the exact ID and ALL 300
            // ordered members. It must not select or submit deletion.
            grid.activateItem(at: targetIndex)
            XCTAssertEqual(fixture.browser.viewer?.id, wanted)
            XCTAssertEqual(fixture.browser.viewer?.ids, group.photos.map(\.id))
            XCTAssertEqual(fixture.state.groups.map { $0.photos.count }, [300])
            XCTAssertTrue(fixture.state.selectedIDs.isEmpty)
            XCTAssertNil(fixture.state.pendingDeletion)
            XCTAssertFalse(fixture.state.isSelecting)
            XCTAssertEqual(fixture.grouping.scans, 1)
            XCTAssertEqual(fixture.deletion.calls, 0)
        }
    }

    private func assertTarget(_ grid: SimilarPhotoGroupGridController, index: Int, host: HeaderLayoutHost,
                              browser: SimilarPhotoGroupBrowser, pixel: CGFloat, context: String) throws -> CGRect {
        let collection = grid.collectionView
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)), context)
        XCTAssertEqual(cell.accessibilityIdentifier, "similar-cleanup-detail-photo-\(index + 1)", context)
        let frame = cell.convert(cell.bounds, to: host.window)
        XCTAssertGreaterThan(frame.height, 0, context)
        XCTAssertTrue(collection.convert(collection.bounds, to: host.window).contains(frame),
                      "The exact routed photo must be entirely inside the final grid viewport; \(context)")
        assertRect(try XCTUnwrap(browser.targetFrame, context), equals: frame, pixel: pixel, context: context)
        return frame
    }

    private func assertFiveColumns(_ collection: UICollectionView, pixel: CGFloat, context: String) {
        var previous: CGRect?
        for index in 0..<5 {
            guard let frame = collection.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
                XCTFail("Missing one of the five native column attributes; \(context)"); return
            }
            XCTAssertEqual(frame.width, frame.height, accuracy: pixel, context)
            XCTAssertEqual(frame.minY, 2, accuracy: pixel, context)
            XCTAssertEqual(frame.minX, previous.map { $0.maxX + 2 } ?? 2, accuracy: pixel, context)
            previous = frame
        }
        XCTAssertEqual(previous?.maxX ?? 0, collection.bounds.width - 2, accuracy: pixel, context)
        XCTAssertEqual(collection.contentSize.width, collection.bounds.width, accuracy: pixel, context)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, pixel: CGFloat,
                            context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: pixel, context, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: pixel, context, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: pixel, context, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: pixel, context, file: file, line: line)
    }

    private func layoutDiagnostics(host: HeaderLayoutHost, measured: HeaderLayoutMeasurements,
                                   browser: SimilarPhotoGroupBrowser) -> String {
        let root = host.controller.view!
        let safeArea = root.convert(root.safeAreaLayoutGuide.layoutFrame, to: host.window)
        let headers = descendants(root, UIScrollView.self).filter { !($0 is UICollectionView) }
        let grids = controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }
        func describe(_ scroll: UIScrollView) -> String {
            "bounds=\(scroll.bounds), windowFrame=\(scroll.convert(scroll.bounds, to: host.window)), usableWindowFrame=\(scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)), content=\(scroll.contentSize), offset=\(scroll.contentOffset), inset=\(scroll.adjustedContentInset), scrollEnabled=\(scroll.isScrollEnabled)"
        }
        let headerInfo = headers.map { describe($0) }.joined(separator: "; ")
        let gridInfo = grids.map { describe($0.collectionView) }.joined(separator: "; ")
        return "natural=\(measured.naturalHeight), probe(bounds=\(measured.viewportBounds), windowFrame=\(String(describing: measured.viewportFrame)), layoutCallbacks=\(measured.viewportLayouts), sameWindow=\(measured.viewportWindow === host.window)), host(bounds=\(root.bounds), safeAreaWindowFrame=\(safeArea)), headers[\(headers.count)]=[\(headerInfo)], grids[\(grids.count)]=[\(gridInfo)], targetWindowFrame=\(String(describing: browser.targetFrame))"
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap { controllers($0) }
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }
}

private enum HeaderLayoutFailure: Error { case layout, unexpectedDeletion }

@MainActor
private final class HeaderLayoutMeasurements {
    var naturalHeight: CGFloat = 0
    var viewportBounds: CGRect = .zero
    var viewportFrame: CGRect?
    weak var viewportWindow: UIWindow?
    var viewportLayouts = 0
}

/// A transparent overlay takes the detail's finite size proposal but records
/// only the UIView's actual layout. No viewport preference or state publisher.
@MainActor
private struct HeaderLayoutViewportProbe: UIViewRepresentable {
    let measurements: HeaderLayoutMeasurements

    func makeUIView(context: Context) -> HeaderLayoutViewportView {
        HeaderLayoutViewportView(measurements: measurements)
    }

    func updateUIView(_ view: HeaderLayoutViewportView, context: Context) {
        view.measurements = measurements
        view.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HeaderLayoutViewportView,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }
}

@MainActor
private final class HeaderLayoutViewportView: UIView {
    var measurements: HeaderLayoutMeasurements

    init(measurements: HeaderLayoutMeasurements) {
        self.measurements = measurements
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        measurements.viewportLayouts += 1
        measurements.viewportBounds = bounds
        measurements.viewportWindow = window
        measurements.viewportFrame = window.map { convert(bounds, to: $0) }
    }
}

@MainActor
private final class HeaderLayoutFixture {
    let grouping = HeaderLayoutGrouping()
    let deletion = HeaderLayoutDeletion()
    let browser = SimilarPhotoGroupBrowser()
    let state: SimilarPhotoCleanupState

    init() { state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion) }
}

@MainActor
private final class HeaderLayoutGrouping: SimilarPhotoGrouping {
    let group: SimilarPhotoGroup
    private(set) var scans = 0

    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        var photos: [IndexedPhoto] = []
        for index in 0..<300 {
            photos.append(IndexedPhoto(id: "TEST-header-layout-\(index)", modificationTime: Double(index + 1),
                modelVersion: "TEST-header-layout", imageEmbedding: vector, creationTime: Double(index)))
        }
        group = SimilarPhotoGroup(id: "TEST-header-layout-group", photos: photos, minimumSimilarity: 0.98)
    }

    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        scans += 1
        return SimilarPhotoGroupingResult(groups: [group], candidateCount: 300, staleCount: 0,
                                          unindexedCount: 0, threshold: threshold)
    }
}

@MainActor
private final class HeaderLayoutDeletion: PhotoDeleting {
    private(set) var calls = 0
    func delete(revisions: [PhotoRevision]) async throws {
        calls += 1
        XCTFail("Header layout must never submit a deletion, even to a synthetic service")
        throw HeaderLayoutFailure.unexpectedDeletion
    }
}

@MainActor
private final class HeaderLayoutHost {
    let window: UIWindow
    let controller: UIViewController
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, controller: UIViewController, size: CGSize, theme: ColorScheme) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = theme == .dark ? .dark : .light
        window.rootViewController = controller
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