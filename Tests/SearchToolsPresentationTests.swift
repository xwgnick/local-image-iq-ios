import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Three app-hosted tests, exactly two review attachments. No golden fixtures,
/// Photos images/mutations, Apple translation sessions, models, files or network.
/// Only search readiness is authorized synthetically; the REAL thumbnail client
/// must remain unauthorized. A readable host fails before AppState is constructed.
/// In-process SwiftUI AX traversal has returned an empty tree in this repo.
/// Accessibility labels are reviewed in source; filters/navigation E2E coverage
/// is separate. These tests cover native rendering/layout, not full AX semantics,
/// action activation, or exact toolbar presence/absence through accessibility.
@MainActor
final class SearchToolsPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testRealResultsNormalAndSelectionDarkSnapshotsAreRenderOnly() async throws {
        let c = try await readyContext()
        let session = try XCTUnwrap(c.state.resultSessionID)
        let hosted = try await mount(ContentView(state: c.state, photoActionService: c.actions), size: phone)
        defer { hosted.close() }

        let bounds = hosted.controller.view.bounds
        let normal = try capture(hosted, scale: hosted.window.screen.scale)
        let normalPixels = try pixels(normal, in: bounds)
        attach(normal, name: "UIReview-search-tools-results-normal-dark")
        XCTAssertFalse(c.state.isSelectingResults)
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
        XCTAssertNil(c.state.selection)
        assertReadOnly(c, session: session)

        // Prepare state, not a simulated tap or a direct call to a view closure.
        c.state.setSelectingResults(true)
        for index in [0, 1, 11] { c.state.toggleResultSelection(c.worker.hits[index].id) }
        try await settle(hosted)
        let selecting = try capture(hosted, scale: hosted.window.screen.scale)
        attach(selecting, name: "UIReview-search-tools-results-selection-dark")
        XCTAssertEqual(c.state.orderedSelectedResultIDs, [0, 1, 11].map { c.worker.hits[$0].id })
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertNil(c.state.selection, "Preparing multi-selection must not open the viewer")

        // Exact RGBA comparison at the same native backing-pixel positions.
        // A changed screen plus a normal-mode round trip is rendering evidence,
        // not proof of the individual toolbar controls' semantics or absence.
        XCTAssertNotEqual(normalPixels, try pixels(selecting, in: bounds),
                          "Preparing selection must visibly change the real ContentView")
        assertReadOnly(c, session: session)

        c.state.setSelectingResults(false)
        try await settle(hosted)
        let restored = try capture(hosted, scale: hosted.window.screen.scale)
        XCTAssertEqual(normalPixels, try pixels(restored, in: bounds),
                       "Exiting selection must restore the settled normal screen pixel for pixel")
        XCTAssertFalse(c.state.isSelectingResults)
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
        XCTAssertNil(c.state.selection)
        assertReadOnly(c, session: session)
    }

    func testGridPreparedSelectionChangesOnlyBadgePixelsWithoutCallingOnSelect() async throws {
        let c = try await readyContext()
        let session = try XCTUnwrap(c.state.resultSessionID)
        c.state.setSelectingResults(true)
        var callbacks: [String] = []
        let layout = SearchToolsReviewGridLayout()
        let hosted = try await mount(SearchToolsReviewGrid(state: c.state, layout: layout,
                                                          onSelect: { callbacks.append($0) }),
                                     size: phone, watermark: false)
        defer { hosted.close() }
        let beforeFrames = try visibleTileFrames(layout, in: hosted, selectedIDs: [])
        let beforeMeasurements = layout.frames
        let before = try capture(hosted, scale: hosted.window.screen.scale)
        XCTAssertEqual(layout.frames, beforeMeasurements, "Capture must not use stale layout preferences")
        XCTAssertTrue(c.state.selectedResultIDs.isEmpty)
        assertReadOnly(c, session: session)

        // Select rank 2 and rank 12 through AppState's public API. Rank 12 is
        // below the viewport; do not claim a lazy offscreen tile was rendered.
        for index in [1, 11] { c.state.toggleResultSelection(c.worker.hits[index].id) }
        try await settle(hosted)
        let selectedIDs = [1, 11].map { c.worker.hits[$0].id }
        XCTAssertEqual(c.state.orderedSelectedResultIDs, selectedIDs)
        XCTAssertTrue(c.state.isSelectingResults)
        let afterFrames = try visibleTileFrames(layout, in: hosted, selectedIDs: Set(selectedIDs))
        let afterMeasurements = layout.frames
        let after = try capture(hosted, scale: hosted.window.screen.scale)
        XCTAssertEqual(layout.frames, afterMeasurements, "Capture must not use stale layout preferences")
        XCTAssertEqual(afterFrames, beforeFrames, "Selection must not move or resize any measured visible tile")

        // Compare the SAME real tile at the SAME backing-pixel position before
        // and after state changes, never an offset reference or a 1x reduction.
        // Bounds come from the supplied thumbnail's native GeometryReader;
        // production still owns the button, shape, aspect ratio and badge.
        let selectedID = c.worker.hits[1].id
        let tile = try XCTUnwrap(afterFrames[selectedID])
        XCTAssertNotNil(beforeFrames[selectedID])
        XCTAssertNotNil(afterFrames[c.worker.hits[0].id], "Require a real unselected comparison tile")
        XCTAssertNil(afterFrames[c.worker.hits[11].id], "Rank 12 is state-only, not a visible-pixel assertion")
        XCTAssertTrue(hosted.controller.view.bounds.contains(tile), "The selected comparison tile must be fully visible")
        let badge = CGRect(x: tile.maxX - 48, y: tile.minY, width: 48, height: 48)
        let lower = CGRect(x: tile.minX, y: tile.minY + 48, width: tile.width, height: tile.height - 48)
        let besideBadge = CGRect(x: tile.minX, y: tile.minY, width: tile.width - 48, height: 48)
        XCTAssertGreaterThan(besideBadge.width, 0)
        XCTAssertGreaterThan(lower.height, 0)
        XCTAssertNotEqual(try pixels(before, in: badge), try pixels(after, in: badge), "Selected badge must actually draw")
        XCTAssertEqual(try pixels(before, in: lower), try pixels(after, in: lower), "Selection must preserve thumbnail pixels")
        XCTAssertEqual(try pixels(before, in: besideBadge), try pixels(after, in: besideBadge),
                       "Pixels beside the badge must also remain unchanged")
        for (id, frame) in afterFrames where id != selectedID {
            // Include the visible portion of a clipped row, not lazy offscreen cells.
            let visible = frame.intersection(hosted.controller.view.bounds)
            XCTAssertEqual(try pixels(before, in: visible), try pixels(after, in: visible),
                           "Unselected visible tile must not change: \(id)")
        }
        XCTAssertTrue(callbacks.isEmpty, "Rendering/preparing state must never invoke the grid's button callback")
        XCTAssertNil(c.state.selection)
        assertReadOnly(c, session: session)
    }

    func testMaximumTypeKeepsNativeResultsScrollableWithoutHorizontalOverflow() async throws {
        let c = try await readyContext()
        let session = try XCTUnwrap(c.state.resultSessionID)
        c.state.setSelectingResults(true)
        c.state.selectVisibleResults()
        let selectedIDs = Set(c.worker.hits.prefix(12).map(\.id))
        XCTAssertEqual(c.state.selectedResultIDs, selectedIDs)
        let size = CGSize(width: 320, height: 852)
        let hosted = try await mount(ContentView(state: c.state, photoActionService: c.actions),
                                     size: size, dynamicType: .accessibility5, watermark: false)
        defer { hosted.close() }
        XCTAssertEqual(hosted.window.bounds.size, size)
        XCTAssertEqual(hosted.controller.view.bounds.size, size)
        let scroll = try verticalScroll(in: hosted)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertGreaterThan(scroll.contentSize.width, 0)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        let viewport = scroll.convert(scroll.bounds, to: hosted.controller.view)
        XCTAssertTrue(hosted.controller.view.bounds.contains(viewport), "The native result viewport must fit the host")
        let before = try capture(hosted, scale: hosted.window.screen.scale)
        assertReadOnly(c, session: session)

        // Exercise UIKit scrolling, not a gesture or a fabricated result view.
        // Stay away from the page boundary so this remains a render-only test.
        let initialOffset = scroll.contentOffset
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        let distance = min(scroll.bounds.height / 2, (bottom - initialOffset.y) / 2)
        XCTAssertGreaterThan(distance, 0)
        let target = CGPoint(x: initialOffset.x, y: initialOffset.y + distance)
        scroll.setContentOffset(target, animated: false)
        try await settle(hosted)
        XCTAssertGreaterThan(scroll.contentOffset.y, initialOffset.y)
        XCTAssertEqual(scroll.contentOffset.y, target.y, accuracy: 1 / hosted.window.screen.scale)
        XCTAssertEqual(scroll.contentOffset.x, initialOffset.x)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        let after = try capture(hosted, scale: hosted.window.screen.scale)
        XCTAssertNotEqual(try pixels(before, in: viewport), try pixels(after, in: viewport),
                          "The real scroll viewport must render different content after scrolling")

        // No extra attachment, expected failure, smaller font, or replacement UI.
        // The heading may start below the viewport at accessibility5. The real
        // bottom toolbar is mounted/rendered, but sits OUTSIDE this UIScrollView:
        // scroll width and host size do not prove its controls fit or are accessible,
        // nor do they detect every clipped/overflowing child in the full window.
        XCTAssertTrue(c.state.isSelectingResults)
        XCTAssertEqual(c.state.selectedResultIDs, selectedIDs)
        XCTAssertNil(c.state.selection)
        assertReadOnly(c, session: session)
    }

    // MARK: Real AppState, synthetic services, unauthorized real thumbnail path

    private func readyContext() async throws -> SearchToolsReviewContext {
        let permission = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else { throw SearchToolsReviewFailure.photosAlreadyReadable }
        let worker = SearchToolsReviewWorker()
        let translator = SearchToolsReviewTranslator()
        let service = SearchToolsReviewActions()
        let state = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        let c = SearchToolsReviewContext(state: state, worker: worker, translator: translator,
                                        actions: service, permission: permission)
        addTeardownBlock { @MainActor in
            await state.waitUntilIdle()
            state.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, permission, "No permission prompt/reset is permitted")
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(service.counts, SearchToolsReviewActions.Counts())
        }
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertFalse(state.library.canReadImages)
        XCTAssertNil(state.appleTranslationService)
        state.query = SearchToolsReviewWorker.query
        guard state.canSearch else { throw SearchToolsReviewFailure.searchNotReady }
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.resultLimit, 12)
        XCTAssertFalse(state.isSelectingResults)
        XCTAssertTrue(state.selectedResultIDs.isEmpty)
        for hit in worker.hits { try EmbeddingValidation.validateUnit(hit.photo.imageEmbedding) }
        assertReadOnly(c, session: try XCTUnwrap(state.resultSessionID))

        let photo = try XCTUnwrap(state.results.first?.photo)
        do {
            _ = try await state.thumbnails.image(id: photo.id, revision: photo.modificationTime,
                                                targetSize: CGSize(width: 180, height: 225), networkAllowed: false)
            XCTFail("Synthetic thumbnail unexpectedly resolved")
            throw SearchToolsReviewFailure.thumbnailResolved
        } catch {
            guard let failure = error as? AppFailure, case .permission = failure else { throw error }
            XCTAssertEqual(PhotoPreviewIssue(error: error).caption, "No access")
        }
        return c
    }

    private func assertReadOnly(_ c: SearchToolsReviewContext, session: UUID,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.state.results.map(\.id), c.worker.hits.prefix(12).map(\.id), file: file, line: line)
        XCTAssertEqual(c.state.results.map(\.score), c.worker.hits.prefix(12).map(\.score), file: file, line: line)
        XCTAssertEqual(c.state.totalResultCount, 37, file: file, line: line)
        XCTAssertTrue(c.state.hasMoreResults, file: file, line: line)
        XCTAssertEqual(c.state.resultSessionID, session, file: file, line: line)
        XCTAssertEqual(c.state.completedQuery, SearchToolsReviewWorker.query, file: file, line: line)
        XCTAssertEqual(c.state.completedSearchQuery?.effective, SearchToolsReviewWorker.query, file: file, line: line)
        XCTAssertEqual(c.state.completedSearchQuery?.translated, false, file: file, line: line)
        XCTAssertEqual(c.state.summary.indexedCount, 37, file: file, line: line)
        XCTAssertNil(c.state.activity, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
        XCTAssertNil(c.state.appleTranslationService, file: file, line: line)
        XCTAssertFalse(c.state.allowICloudDownload, file: file, line: line)
        XCTAssertEqual(c.worker.refreshCount, 1, file: file, line: line)
        XCTAssertEqual(c.worker.requests.map { $0.text }, [SearchToolsReviewWorker.query], file: file, line: line)
        XCTAssertEqual(c.worker.requests.map { $0.limit }, [Int.max], file: file, line: line)
        XCTAssertEqual(c.worker.requests.map { $0.weight }, [Float(0.6)], file: file, line: line)
        XCTAssertEqual(c.worker.mutations, 0, file: file, line: line)
        XCTAssertEqual(c.translator.calls, 0, file: file, line: line)
        XCTAssertEqual(c.actions.counts, SearchToolsReviewActions.Counts(),
                       "Rendering must perform zero album reads, writes, shares or action preflights", file: file, line: line)
        XCTAssertEqual(PhotoLibraryClient.authorization, c.permission, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
    }

    // MARK: PresentationTests-style native host, scale-1 review / native-scale pixels

    private func mount<V: View>(_ content: V, size: CGSize, dynamicType: DynamicTypeSize = .large,
                               watermark: Bool = true) async throws -> SearchToolsReviewHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let root = content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if watermark {
                    Text("TEST FIXTURE · Synthetic results / no Photos images")
                        .font(.caption2).foregroundStyle(IQStyle.secondary).padding(6)
                        .frame(maxWidth: .infinity).background(IQStyle.muted)
                }
            }
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicType)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let hosted = SearchToolsReviewHost(scene: scene, root: AnyView(root), size: size)
        var mounted = false
        defer { if !mounted { hosted.close() } }
        let laidOut = XCTestExpectation(description: "Native search tools host laid out at \(size)")
        hosted.controller.onLayout = { [weak controller = hosted.controller] in
            guard let controller, controller.view.window != nil, controller.view.bounds.size == size else { return }
            controller.onLayout = nil
            laidOut.fulfill()
        }
        hosted.window.rootViewController = hosted.controller
        hosted.window.makeKeyAndVisible()
        hosted.layout()
        guard await XCTWaiter.fulfillment(of: [laidOut], timeout: 5) == .completed else {
            XCTFail("Native host did not lay out")
            throw SearchToolsReviewFailure.layout
        }
        try await settle(hosted)
        XCTAssertEqual(hosted.controller.view.bounds.size, size)
        mounted = true
        return hosted
    }

    private func settle(_ hosted: SearchToolsReviewHost) async throws {
        let settled = XCTestExpectation(description: "Pending native state/layout updates completed")
        DispatchQueue.main.async {
            hosted.layout()
            DispatchQueue.main.async { hosted.layout(); settled.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 5) == .completed else {
            XCTFail("Native layout updates did not complete")
            throw SearchToolsReviewFailure.layout
        }
    }

    private func capture(_ hosted: SearchToolsReviewHost, scale: CGFloat) throws -> UIImage {
        let view = hosted.controller.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew else { XCTFail("UIKit did not draw the real hierarchy"); throw SearchToolsReviewFailure.drawing }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, Int((view.bounds.width * scale).rounded()))
        XCTAssertEqual(cg.height, Int((view.bounds.height * scale).rounded()))
        return image
    }

    private func attach(_ image: UIImage, name: String) {
        XCTAssertEqual(image.size, phone)
        // Review only: reduce the SAME native capture to 1x. Pixel assertions
        // always use the original backing-scale image, never this reduction.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let review = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        XCTAssertEqual(review.scale, 1)
        let attachment = XCTAttachment(image: review)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Public UIKit backing scroll geometry, not SwiftUI accessibility traversal.
    private func verticalScroll(in hosted: SearchToolsReviewHost) throws -> UIScrollView {
        func descendants(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants($0) }
        }
        let candidates = descendants(hosted.controller.view).filter {
            !$0.isHidden && $0.alpha > 0 && $0.window === hosted.window &&
                $0.bounds.width > 0 && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height
        }
        XCTAssertEqual(candidates.count, 1, "The real results screen must provide one vertical native scroll view")
        return try XCTUnwrap(candidates.first, "No laid-out vertical results UIScrollView")
    }

    private func visibleTileFrames(_ layout: SearchToolsReviewGridLayout, in hosted: SearchToolsReviewHost,
                                   selectedIDs: Set<String>) throws -> [String: CGRect] {
        let canvas = try XCTUnwrap(layout.frames[.canvas], "The test canvas must emit native geometry")
        XCTAssertEqual(canvas.rect, hosted.controller.view.bounds, "Named coordinates must match the captured host")
        XCTAssertEqual(canvas.selectedIDs, selectedIDs, "Require a preference for the current selection state")
        var frames: [String: CGRect] = [:]
        for (region, measurement) in layout.frames {
            guard case .photo(let id) = region else { continue }
            let rect = measurement.rect
            guard !rect.isEmpty, rect.intersects(canvas.rect) else { continue }
            XCTAssertEqual(measurement.selectedIDs, selectedIDs, "Visible geometry must belong to current inputs")
            frames[id] = rect
        }
        XCTAssertFalse(frames.isEmpty, "An empty geometry preference must not pass pixel assertions")
        return frames
    }

    private func pixels(_ image: UIImage, in rect: CGRect) throws -> Data {
        let source = try XCTUnwrap(image.cgImage)
        let pixelRect = CGRect(x: rect.minX * image.scale, y: rect.minY * image.scale,
                               width: rect.width * image.scale, height: rect.height * image.scale).integral
        guard !pixelRect.isEmpty,
              CGRect(x: 0, y: 0, width: source.width, height: source.height).contains(pixelRect) else {
            XCTFail("Measured tile crop falls outside the native capture: \(pixelRect)")
            throw SearchToolsReviewFailure.drawing
        }
        let crop = try XCTUnwrap(source.cropping(to: pixelRect))
        var data = Data(count: crop.width * crop.height * 4)
        try data.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return data
    }
}

private enum SearchToolsReviewFailure: Error { case photosAlreadyReadable, searchNotReady, thumbnailResolved, layout, drawing }

@MainActor
private struct SearchToolsReviewContext {
    let state: AppState
    let worker: SearchToolsReviewWorker
    let translator: SearchToolsReviewTranslator
    let actions: SearchToolsReviewActions
    let permission: PHAuthorizationStatus
}

@MainActor
private struct SearchToolsReviewGrid: View {
    @ObservedObject var state: AppState
    let layout: SearchToolsReviewGridLayout
    let onSelect: (String) -> Void
    private static var coordinateSpace: String { "search-tools-review-grid" }

    var body: some View {
        let selectedIDs = state.selectedResultIDs
        // A full-host test canvas gives the named space the same origin/size as
        // the native capture (asserted above), without guessing safe-area offsets.
        GeometryReader { _ in
            ScrollView {
                PhotoResultsGrid(hits: state.results, compact: false, onSelect: onSelect,
                                 selectionMode: state.isSelectingResults, selectedIDs: selectedIDs) { photo in
                    Color(red: 0.12, green: 0.18, blue: 0.24) // Plain test pixels, never a photo/image request.
                        .background(measure(.photo(photo.id), selectedIDs: selectedIDs))
                }
                .padding(20)
            }
        }
        .background(IQStyle.background)
        .background(measure(.canvas, selectedIDs: selectedIDs))
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(SearchToolsReviewFramesKey.self) { layout.frames = $0 }
        .ignoresSafeArea()
    }

    private func measure(_ region: SearchToolsReviewRegion, selectedIDs: Set<String>) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SearchToolsReviewFramesKey.self, value: [region:
                SearchToolsReviewMeasurement(rect: geometry.frame(in: .named(Self.coordinateSpace)),
                                             selectedIDs: selectedIDs)])
        }
    }
}

private enum SearchToolsReviewRegion: Hashable { case canvas, photo(String) }

private struct SearchToolsReviewMeasurement: Equatable {
    let rect: CGRect
    // Selection can change without moving a tile. Carry current parent inputs
    // so stale geometry cannot masquerade as a post-update preference.
    let selectedIDs: Set<String>
}

private struct SearchToolsReviewFramesKey: PreferenceKey {
    static let defaultValue: [SearchToolsReviewRegion: SearchToolsReviewMeasurement] = [:]

    static func reduce(value: inout [SearchToolsReviewRegion: SearchToolsReviewMeasurement],
                       nextValue: () -> [SearchToolsReviewRegion: SearchToolsReviewMeasurement]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private final class SearchToolsReviewGridLayout {
    var frames: [SearchToolsReviewRegion: SearchToolsReviewMeasurement] = [:]
}

@MainActor
private final class SearchToolsReviewController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
}

@MainActor
private final class SearchToolsReviewHost {
    let window: UIWindow
    let controller: SearchToolsReviewController
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, root: AnyView, size: CGSize) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = SearchToolsReviewController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
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
private final class SearchToolsReviewWorker: PhotoWorkServicing {
    static let query = "TEST sunset by the sea"
    let hits: [SearchHit]
    private let summary = LibrarySummary(indexedCount: 37, modelVersion: "search-tools-review-only")
    private(set) var refreshCount = 0
    private(set) var mutations = 0
    private(set) var requests: [(text: String, limit: Int, weight: Float)] = []

    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        hits = (0..<37).map { rank in
            SearchHit(photo: IndexedPhoto(id: "TEST-search-tools-missing-\((rank * 11) % 37)", modificationTime: 123,
                modelVersion: "search-tools-review-only", imageEmbedding: vector, creationTime: 100),
                score: Float(37 - rank) / 37)
        }
    }

    func refresh() async throws -> LibrarySummary { refreshCount += 1; return summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        requests.append((text, limit, locationWeight))
        return SearchResponse(summary: summary, hits: hits)
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        mutations += 1
        XCTFail("Rendering must not index photos")
        throw AppFailure.storage("TEST unexpected indexing")
    }
    func clear() async throws -> LibrarySummary {
        mutations += 1
        XCTFail("Rendering must not clear storage")
        throw AppFailure.storage("TEST unexpected clear")
    }
}

@MainActor
private final class SearchToolsReviewTranslator: QueryTranslating {
    let isSupported = false
    private(set) var calls = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        calls += 1; XCTFail("English review query must not request language availability"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        calls += 1; XCTFail("Rendering must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        calls += 1; XCTFail("Rendering must not prepare translation"); throw QueryTranslationFailure.unsupported
    }
}

/// Protocol-complete recorder; even an accidental button action cannot reach
/// Photos or create share files. Albums/apply are meaningful only if explicitly
/// requested; all three tests require every count to stay zero during rendering.
private final class SearchToolsReviewActions: PhotoLibraryActions, @unchecked Sendable {
    struct Counts: Equatable { var albumReads = 0; var writes = 0; var shares = 0; var validations = 0 }
    private let lock = NSLock()
    private var recorded = Counts()
    var counts: Counts { locked { recorded } }

    func albums() async throws -> [PhotoAlbum] {
        locked { recorded.albumReads += 1 }
        return [PhotoAlbum(id: "TEST-album", title: "TEST 相册", canAdd: true)]
    }
    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws { locked { recorded.writes += 1 } }
    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare {
        locked { recorded.shares += 1 }
        throw PhotoLibraryActionError.sharePreparationFailed
    }
    func validateAccess(ids: [String]) throws { locked { recorded.validations += 1 } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}