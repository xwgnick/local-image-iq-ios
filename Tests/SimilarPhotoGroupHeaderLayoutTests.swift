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
                .background {
                    GeometryReader { viewport in
                        Color.clear.preference(key: HeaderLayoutViewportSizePreference.self,
                                               value: viewport.size)
                    }
                }
                .onPreferenceChange(SimilarPhotoGroupHeaderHeightPreference.self) { measured.naturalHeight = $0 }
                .onPreferenceChange(HeaderLayoutViewportSizePreference.self) { measured.viewportSize = $0 }
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

            // Wait for actual preference delivery and the production one-shot
            // target callback, never a guessed render/animation sleep. The
            // assertions below are deliberately NOT part of this readiness gate.
            let inspect: @MainActor () -> Bool = {
                host.layout()
                return measured.naturalHeight > 0 && measured.viewportSize.height > 0
                    && fixture.browser.targetFrame != nil
            }
            let predicate = NSPredicate { _, _ in
                if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
                return DispatchQueue.main.sync { inspect() }
            }
            let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
            ready.expectationDescription = "Measured header and native target at \(width)x852, \(dynamicType), \(theme)"
            guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
                XCTFail("Missing layout event: \(ready.expectationDescription); natural=\(measured.naturalHeight), viewport=\(measured.viewportSize)")
                throw HeaderLayoutFailure.layout
            }
            host.layout()
            XCTAssertEqual(controller.view.bounds.size, size)
            let grids = controllers(controller).compactMap { $0 as? SimilarPhotoGroupGridController }
            XCTAssertEqual(grids.count, 1)
            let grid = try XCTUnwrap(grids.first)
            let collection = grid.collectionView
            let headers = descendants(controller.view, UIScrollView.self).filter { !($0 is UICollectionView) }
            XCTAssertEqual(headers.count, 1, "One header scroll view, not duplicate fitting/hidden header copies")
            let header = try XCTUnwrap(headers.first)
            let pixel = 1 / host.window.screen.scale
            let natural = measured.naturalHeight
            let cap = measured.viewportSize.height * 0.45
            let allocated = min(natural, cap)
            let headerFrame = header.convert(header.bounds, to: host.window)
            let gridFrame = collection.convert(collection.bounds, to: host.window)
            let context = "\(width)x852 \(dynamicType) \(theme): natural=\(natural), header=\(headerFrame), grid=\(gridFrame)"

            // Compare actual laid-out content, the native scroll viewport, and
            // the native grid. The old maxHeight reservation leaves a large gap
            // here even though the five-column/count/target tests still pass.
            XCTAssertEqual(header.contentSize.height, natural, accuracy: pixel, context)
            XCTAssertEqual(headerFrame.height, allocated, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.minY, headerFrame.maxY, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.minY - headerFrame.minY, allocated, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.maxY - headerFrame.minY, measured.viewportSize.height, accuracy: pixel, context)
            XCTAssertEqual(gridFrame.width, measured.viewportSize.width, accuracy: pixel, context)
            XCTAssertLessThanOrEqual(header.contentSize.width, header.bounds.width + pixel, context)
            XCTAssertGreaterThan(gridFrame.height, 0, context)
            XCTAssertGreaterThanOrEqual(gridFrame.height + pixel, measured.viewportSize.height * 0.55, context)
            XCTAssertEqual(header.isScrollEnabled, capped, context)
            XCTAssertTrue(collection.isScrollEnabled, "Disabling a fitting header must not disable the photo grid")
            if capped {
                XCTAssertGreaterThan(natural, cap, "Maximum-size text must exercise overflowing content, not just the policy")
                XCTAssertEqual(headerFrame.height, cap, accuracy: pixel, context)
            } else {
                XCTAssertLessThan(natural, cap - pixel, "Regular text must exercise the short-header regression")
                XCTAssertEqual(gridFrame.minY, headerFrame.minY + natural, accuracy: pixel,
                               "The grid must start at the measured content bottom, within ONE device pixel; \(context)")
                XCTAssertEqual(headerFrame.height - header.contentSize.height, 0, accuracy: pixel,
                               "No unused space inside the normal header; \(context)")
            }

            XCTAssertEqual(collection.numberOfItems(inSection: 0), 300)
            XCTAssertEqual(grid.initialScrollPhotoID, wanted)
            XCTAssertEqual(fixture.browser.detailRoute?.photoID, wanted)
            assertFiveColumns(collection, pixel: pixel)
            let targetFrame = try assertTarget(grid, index: targetIndex, host: host, browser: fixture.browser, pixel: pixel)
            if !capped {
                XCTAssertEqual(targetFrame.midY, gridFrame.midY, accuracy: pixel,
                    "The middle target must be centered using the measured-header viewport, not the initial zero-height header")
            }

            if capped {
                // Exercise the real header UIScrollView independently. Reaching
                // its content bottom must not move the grid or its exact target.
                let before = header.contentOffset.y
                let bottom = header.contentSize.height - header.bounds.height + header.adjustedContentInset.bottom
                header.setContentOffset(CGPoint(x: header.contentOffset.x, y: bottom), animated: false)
                host.layout()
                XCTAssertGreaterThan(header.contentOffset.y, before)
                XCTAssertEqual(header.contentOffset.y, bottom, accuracy: pixel)
                XCTAssertEqual(header.contentOffset.y + header.bounds.height - header.adjustedContentInset.bottom,
                               natural, accuracy: pixel, "All header content is reachable without expanding its viewport")
                assertRect(collection.convert(collection.bounds, to: host.window), equals: gridFrame, pixel: pixel)
                _ = try assertTarget(grid, index: targetIndex, host: host, browser: fixture.browser, pixel: pixel)
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
                              browser: SimilarPhotoGroupBrowser, pixel: CGFloat) throws -> CGRect {
        let collection = grid.collectionView
        let cell = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: index, section: 0)))
        XCTAssertEqual(cell.accessibilityIdentifier, "similar-cleanup-detail-photo-\(index + 1)")
        let frame = cell.convert(cell.bounds, to: host.window)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(collection.convert(collection.bounds, to: host.window).contains(frame),
                      "The exact routed photo must be entirely inside the final grid viewport")
        assertRect(try XCTUnwrap(browser.targetFrame), equals: frame, pixel: pixel)
        return frame
    }

    private func assertFiveColumns(_ collection: UICollectionView, pixel: CGFloat) {
        var previous: CGRect?
        for index in 0..<5 {
            guard let frame = collection.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else {
                XCTFail("Missing one of the five native column attributes"); return
            }
            XCTAssertEqual(frame.width, frame.height, accuracy: pixel)
            XCTAssertEqual(frame.minY, 2, accuracy: pixel)
            XCTAssertEqual(frame.minX, previous.map { $0.maxX + 2 } ?? 2, accuracy: pixel)
            previous = frame
        }
        XCTAssertEqual(previous?.maxX ?? 0, collection.bounds.width - 2, accuracy: pixel)
        XCTAssertEqual(collection.contentSize.width, collection.bounds.width, accuracy: pixel)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, pixel: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: pixel, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: pixel, file: file, line: line)
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
    var viewportSize: CGSize = .zero
}

private struct HeaderLayoutViewportSizePreference: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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