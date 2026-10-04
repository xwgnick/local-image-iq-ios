import XCTest
import SwiftUI
import UIKit
import Combine
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// App-hosted integration tests, not XCUI or a replacement result grid. Only
/// search/model readiness and translation are faked. ContentView, its default
/// two-column grid, PhotoThumbnailView, cache and Photos client remain real.
/// The system Photos permission MUST be unreadable before creating AppState;
/// an already-authorized host fails without fetching assets or changing access.
/// No Photos seeding, permission requests, model loads, network or storage work.
@MainActor
final class ResultPaginationPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testFirstViewportDoesNotAppendForPrecreatedOffscreenBoundary() async throws {
        let context = try await readyContext()
        let session = try XCTUnwrap(context.state.resultSessionID)
        var counts: [Int] = []
        let subscription = context.state.$results.map { $0.count }.removeDuplicates()
            .sink { counts.append($0) }
        defer { subscription.cancel() }

        let hosted = try await mount(context.state, size: phone)
        defer { hosted.close() }
        let scroll = try verticalScroll(in: hosted)
        try assertOffscreenBoundary(in: hosted, scroll: scroll, session: session)
        assertPage(context, count: 12, session: session)
        XCTAssertEqual(counts, [12], "Creating the real boundary is not permission to load page two")
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        XCTAssertEqual(scroll.contentOffset.y, -scroll.adjustedContentInset.top, accuracy: 1)
    }

    func testScrollingRealContentViewAppendsTwentyFourThirtySixThirtySevenAndStops() async throws {
        let context = try await readyContext()
        let state = context.state
        let session = try XCTUnwrap(state.resultSessionID)
        let resolution = state.completedSearchQuery
        let status = state.status
        var counts: [Int] = []
        let subscription = state.$results.map { $0.count }.removeDuplicates()
            .sink { counts.append($0) }
        defer { subscription.cancel() }

        let hosted = try await mount(state, size: phone)
        defer { hosted.close() }
        let scroll = try verticalScroll(in: hosted)
        try assertOffscreenBoundary(in: hosted, scroll: scroll, session: session)
        assertPage(context, count: 12, session: session)
        XCTAssertEqual(counts, [12])

        for (index, count) in [24, 36, 37].enumerated() {
            // The subscription is installed BEFORE setContentOffset. Never call
            // loadMoreResults here: the production geometry callback must do it.
            try await scrollToNextPage(count, state: state, scroll: scroll, hosted: hosted)
            assertPage(context, count: count, session: session)
            XCTAssertEqual(counts, Array([12, 24, 36, 37].prefix(index + 2)))
            XCTAssertEqual(state.completedSearchQuery, resolution)
            XCTAssertEqual(state.status, status)
            XCTAssertTrue(try verticalScroll(in: hosted) === scroll,
                          "Appending must retain the actual scroll view")
            if count == 24 {
                try attachTwentyFourResultScreenshot(hosted)
                assertPage(context, count: 24, session: session)
            }
        }

        XCTAssertFalse(state.hasMoreResults)
        XCTAssertNil(hosted.boundary.latest, "Exhaustion removes the real boundary preference")
        // Exercise layout and the new physical bottom once more, without any
        // inverted expectation or arbitrary wait for a non-event.
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottomOffset(of: scroll)), animated: false)
        try await waitForContentLayout(hosted, scroll: scroll)
        assertPage(context, count: 37, session: session)
        XCTAssertNil(hosted.boundary.latest, "Layout at exhaustion must not restore a boundary")
        XCTAssertEqual(counts, [12, 24, 36, 37], "No reset, duplicate page or extra publication at exhaustion")
        XCTAssertEqual(state.completedSearchQuery, resolution)
        XCTAssertEqual(state.status, status)
    }

    func testSmallLandscapeViewportDoesNotAutoAppendOrResetCompletedSession() async throws {
        let context = try await readyContext()
        let session = try XCTUnwrap(context.state.resultSessionID)
        let resolution = context.state.completedSearchQuery
        var counts: [Int] = []
        let subscription = context.state.$results.map { $0.count }.removeDuplicates()
            .sink { counts.append($0) }
        defer { subscription.cancel() }

        // A second native viewport, NOT a fake compact-grid mode or a claim of
        // physical device rotation. ContentView's private compactGrid stays false.
        let size = CGSize(width: 667, height: 375)
        let hosted = try await mount(context.state, size: size)
        defer { hosted.close() }
        let scroll = try verticalScroll(in: hosted)
        try assertOffscreenBoundary(in: hosted, scroll: scroll, session: session)
        XCTAssertEqual(hosted.host.view.bounds.size, size)
        XCTAssertGreaterThan(scroll.bounds.width, scroll.bounds.height)
        assertPage(context, count: 12, session: session)
        XCTAssertEqual(context.state.completedSearchQuery, resolution)
        XCTAssertEqual(counts, [12])
    }

    // MARK: Immediate synthetic worker; real unauthorized thumbnails

    private func readyContext() async throws -> ResultPaginationPresentationContext {
        // Check BEFORE AppState.refresh can synchronize a real Photos observer.
        // Never grant, revoke, reset or silently skip a previously granted host.
        let authorization = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            throw ResultPaginationPresentationFailure.photosAlreadyReadable
        }
        let worker = ResultPaginationPresentationWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             queryTranslator: ResultPaginationPresentationTranslator())
        addTeardownBlock {
            await state.waitUntilIdle()
            await MainActor.run {
                state.thumbnails.clear()
                XCTAssertFalse(PhotoLibraryClient.canRead)
                XCTAssertEqual(PhotoLibraryClient.authorization, authorization,
                               "Hosting results must not change system Photos authorization")
            }
        }
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertTrue(state.canRead, "Only AppState's search-readiness permission is injected")
        XCTAssertFalse(state.library.canReadImages, "The real thumbnail client still has no access")
        XCTAssertNil(state.appleTranslationService)
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertEqual(state.resultLimit, 12)
        for hit in worker.hits { try EmbeddingValidation.validateUnit(hit.photo.imageEmbedding) }

        state.query = ResultPaginationPresentationWorker.query
        guard state.canSearch else { throw ResultPaginationPresentationFailure.searchNotReady }
        state.search()
        await state.waitUntilIdle()
        let session = try XCTUnwrap(state.resultSessionID)
        let context = ResultPaginationPresentationContext(state: state, worker: worker)
        assertPage(context, count: 12, session: session)

        // Exercise the NORMAL cache, not an injected thumbnail provider. Its
        // actual canReadImages guard must throw before currentRevision/PHAsset
        // lookup or any image request. The mounted tiles use this same cache.
        let photo = try XCTUnwrap(worker.hits.first?.photo)
        do {
            _ = try await state.thumbnails.image(id: photo.id, revision: photo.modificationTime,
                                                 targetSize: CGSize(width: 180, height: 225), networkAllowed: false)
            throw ResultPaginationPresentationFailure.syntheticThumbnailResolved
        } catch {
            guard let failure = error as? AppFailure, case .permission = failure else {
                XCTFail("Expected the real cache's immediate no-access failure, got \(error)")
                throw error
            }
            XCTAssertEqual(PhotoPreviewIssue(error: error).caption, "No access")
        }
        return context
    }

    private func assertPage(_ context: ResultPaginationPresentationContext, count: Int, session: UUID,
                            file: StaticString = #filePath, line: UInt = #line) {
        let state = context.state
        let expected = Array(context.worker.hits.prefix(count))
        XCTAssertEqual(state.results.count, count, file: file, line: line)
        XCTAssertEqual(state.results.map(\.id), expected.map(\.id), file: file, line: line)
        XCTAssertEqual(state.results.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern }, file: file, line: line)
        XCTAssertEqual(Set(state.results.map(\.id)).count, count, file: file, line: line)
        XCTAssertEqual(state.resultSessionID, session, file: file, line: line)
        XCTAssertEqual(state.totalResultCount, 37, file: file, line: line)
        XCTAssertEqual(state.hasMoreResults, count < 37, file: file, line: line)
        XCTAssertEqual(state.query, ResultPaginationPresentationWorker.query, file: file, line: line)
        XCTAssertEqual(state.completedQuery, state.query, file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery?.effective, state.query, file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery?.translated, false, file: file, line: line)
        XCTAssertEqual(state.summary.indexedCount, 37, file: file, line: line)
        XCTAssertNil(state.activity, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
        XCTAssertFalse(state.allowICloudDownload, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
        XCTAssertEqual(context.worker.refreshCount, 1, file: file, line: line)
        XCTAssertEqual(context.worker.searchCount, 1, "Scrolling must not search again", file: file, line: line)
        XCTAssertEqual(context.worker.requestedTexts, [state.query], file: file, line: line)
        XCTAssertEqual(context.worker.requestedLimits, [Int.max], file: file, line: line)
        XCTAssertEqual(context.worker.requestedWeights, [Float(0.6)], file: file, line: line)
    }

    // MARK: Native hosting and event-driven layout

    private func mount(_ state: AppState, size: CGSize) async throws -> ResultPaginationPresentationHost {
        guard !PhotoLibraryClient.canRead else { throw ResultPaginationPresentationFailure.photosAlreadyReadable }
        let session = try XCTUnwrap(state.resultSessionID)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "These tests require the native iOS application test host")
        let boundary = ResultPaginationPresentationBoundaryProbe()
        let content = VStack(spacing: 0) {
            Text("TEST • synthetic results / no Photos")
                .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                .padding(.vertical, 4).frame(maxWidth: .infinity).background(Color.black)
            ContentView(state: state)
                // A legitimate ancestor preference observer. No replacement
                // sentinel, onAppear hook or mutation of observable view state.
                // ContentView keeps its own preference reader and busy retry.
                .onPreferenceChange(ResultPageBoundaryPreference.self) { boundary.observe($0) }
        }
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, .large)
        let hosted = ResultPaginationPresentationHost(scene: scene, root: AnyView(content), size: size, boundary: boundary)
        var mounted = false
        defer { if !mounted { hosted.close() } }
        let laidOut = expectation(description: "Real ContentView laid out at \(size)")
        let boundaryObserved = expectation(description: "Real initial boundary for session \(session), count 12")
        var didLayout = false
        var didObserveBoundary = false
        boundary.onChange = { value in
            guard !didObserveBoundary, let value,
                  value.sessionID == session, value.visibleCount == 12 else { return }
            didObserveBoundary = true
            boundaryObserved.fulfill()
        }
        defer {
            hosted.host.onLayout = nil
            boundary.onChange = nil
        }
        hosted.host.onLayout = { [weak controller = hosted.host] in
            guard let controller, controller.view.window != nil, controller.view.bounds.size == size else { return }
            controller.onLayout = nil
            didLayout = true
            laidOut.fulfill()
        }
        hosted.window.rootViewController = hosted.host
        hosted.window.makeKeyAndVisible()
        hosted.layout()
        await fulfillment(of: [laidOut, boundaryObserved], timeout: 5)
        guard didLayout else { throw ResultPaginationPresentationFailure.layoutNotDelivered }
        guard didObserveBoundary else { throw ResultPaginationPresentationFailure.boundaryNotObserved(12) }
        let scroll = try verticalScroll(in: hosted)
        try await waitForContentLayout(hosted, scroll: scroll)
        XCTAssertEqual(hosted.host.view.bounds.size, size)
        mounted = true
        return hosted
    }

    private func waitForContentLayout(_ hosted: ResultPaginationPresentationHost, scroll: UIScrollView,
                                      growingFrom previousHeight: CGFloat? = nil) async throws {
        let laidOut = expectation(description: previousHeight == nil
                                  ? "Native layout of the real scroll content"
                                  : "Native layout with a larger content height after append")
        var didLayout = false
        hosted.host.onLayout = {
            let height = scroll.contentSize.height
            guard !didLayout, hosted.host.view.window === hosted.window,
                  scroll.window === hosted.window, scroll.bounds.height > 0,
                  height.isFinite, height > scroll.bounds.height else { return }
            if let previousHeight, height <= previousHeight { return }
            didLayout = true
            laidOut.fulfill()
        }

        // A SwiftUI preference can precede UIKit's contentSize update, and a
        // descendant update need not relayout the hosting controller itself.
        // Size changes only request native layout; ONLY onLayout above can pass.
        let requestLayout: () -> Void = { [weak hosted, weak scroll] in
            DispatchQueue.main.async {
                guard let hosted, let scroll, hosted.host.onLayout != nil else { return }
                scroll.setNeedsLayout()
                scroll.layoutIfNeeded()
                hosted.layout()
            }
        }
        let contentSizeObservation = scroll.observe(\.contentSize, options: [.old, .new]) { _, change in
            guard change.oldValue?.height != change.newValue?.height else { return }
            requestLayout()
        }
        defer {
            contentSizeObservation.invalidate()
            hosted.host.onLayout = nil
        }
        // One native-layout fallback also covers contentSize updated before
        // observation began. A queued turn alone is never completion evidence.
        requestLayout()
        await fulfillment(of: [laidOut], timeout: 5)
        guard didLayout else { throw ResultPaginationPresentationFailure.layoutNotDelivered }
    }

    private func verticalScroll(in hosted: ResultPaginationPresentationHost) throws -> UIScrollView {
        func descendants(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants($0) }
        }
        // SwiftUI may not expose its AX identifier on the backing UIScrollView.
        // Limit the fallback to visible, laid-out VERTICAL scroll descendants.
        let candidates = descendants(hosted.host.view).filter {
            !$0.isHidden && $0.alpha > 0 && $0.window === hosted.window &&
                $0.bounds.width > 0 && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height
        }
        return try XCTUnwrap(candidates.first(where: { $0.accessibilityIdentifier == "library-scroll" }) ??
                             candidates.max(by: { $0.contentSize.height < $1.contentSize.height }),
                             "The real vertical result UIScrollView must exist; no fake scroll fallback")
    }

    private func assertOffscreenBoundary(in hosted: ResultPaginationPresentationHost, scroll: UIScrollView,
                                         session: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let boundary = try XCTUnwrap(hosted.boundary.latest,
                                     "The real offscreen boundary must already emit a parent preference",
                                     file: file, line: line)
        XCTAssertEqual(boundary.sessionID, session, file: file, line: line)
        XCTAssertEqual(boundary.visibleCount, 12, file: file, line: line)
        XCTAssertTrue(boundary.frame.minY.isFinite, file: file, line: line)
        XCTAssertGreaterThan(boundary.frame.height, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(boundary.frame.minY, scroll.bounds.height,
                                    "Precreated is not visible", file: file, line: line)
    }

    private func bottomOffset(of scroll: UIScrollView) -> CGFloat {
        max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }

    private func scrollToNextPage(_ count: Int, state: AppState, scroll: UIScrollView,
                                   hosted: ResultPaginationPresentationHost) async throws {
        let session = try XCTUnwrap(state.resultSessionID)
        let previousHeight = scroll.contentSize.height
        let bottom = bottomOffset(of: scroll)
        guard bottom.isFinite, bottom > scroll.contentOffset.y else {
            throw ResultPaginationPresentationFailure.noNewScrollableBottom
        }
        let appended = expectation(description: "Real geometry publishes exactly \(count) results")
        let boundaryObserved = expectation(description: count < state.totalResultCount
                                           ? "Real boundary for session \(session), new count \(count)"
                                           : "Real boundary emits nil at exhaustion")
        var received = false
        var didObserveBoundary = false
        let subscription = state.$results.filter { $0.count == count }.prefix(1).sink { _ in
            received = true
            appended.fulfill()
        }
        // Install before scrolling: never accept the probe's initial nil or a
        // cached old-page value as evidence of the newly presented page.
        hosted.boundary.onChange = { value in
            guard !didObserveBoundary, state.resultSessionID == session,
                  state.results.count == count else { return }
            if count < state.totalResultCount {
                guard let value, value.sessionID == session, value.visibleCount == count else { return }
            } else {
                guard value == nil else { return }
            }
            didObserveBoundary = true
            boundaryObserved.fulfill()
        }
        defer {
            subscription.cancel()
            hosted.boundary.onChange = nil
        }
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
        hosted.layout()
        await fulfillment(of: [appended, boundaryObserved], timeout: 5)
        // A failed expectation must NOT lead to another page wait or screenshot.
        // Throwing unwinds all subscriptions and the window's defer cleanup.
        guard received else { throw ResultPaginationPresentationFailure.pageNotPublished(count) }
        guard didObserveBoundary else { throw ResultPaginationPresentationFailure.boundaryNotObserved(count) }
        // @Published is a willSet notification, not evidence of rendered rows.
        // Wait for the new preference AND a genuine layout with increased height
        // before a screenshot or computing the next physical scroll bottom.
        try await waitForContentLayout(hosted, scroll: scroll, growingFrom: previousHeight)
        XCTAssertEqual(state.results.count, count, "No cascading automatic append during layout")
        XCTAssertEqual(state.resultSessionID, session)
        if count < state.totalResultCount {
            let boundary = try XCTUnwrap(hosted.boundary.latest)
            XCTAssertEqual(boundary.sessionID, session)
            XCTAssertEqual(boundary.visibleCount, count)
        } else {
            XCTAssertNil(hosted.boundary.latest)
        }
        XCTAssertGreaterThan(scroll.contentSize.height, previousHeight)
        XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1, "Appending must not reset the scroll position")
    }

    private func attachTwentyFourResultScreenshot(_ hosted: ResultPaginationPresentationHost) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(size: phone, format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(origin: .zero, size: phone))
            drew = hosted.host.view.drawHierarchy(in: CGRect(origin: .zero, size: phone), afterScreenUpdates: true)
        }
        guard drew else { throw ResultPaginationPresentationFailure.hierarchyNotDrawn }
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 393)
        XCTAssertEqual(pixels.height, 852)
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-result-pagination-24-real-content-view"
        attachment.lifetime = .keepAlways
        add(attachment) // Exactly one capture; placeholders are NOT photo-quality evidence.
    }
}

private enum ResultPaginationPresentationFailure: Error {
    case photosAlreadyReadable, searchNotReady, syntheticThumbnailResolved
    case layoutNotDelivered, noNewScrollableBottom, hierarchyNotDrawn
    case pageNotPublished(Int)
    case boundaryNotObserved(Int)
}

@MainActor
private struct ResultPaginationPresentationContext {
    let state: AppState
    let worker: ResultPaginationPresentationWorker
}

@MainActor
private final class ResultPaginationPresentationBoundaryProbe {
    private(set) var latest: ResultPageBoundaryValue?
    var onChange: ((ResultPageBoundaryValue?) -> Void)?

    func observe(_ value: ResultPageBoundaryValue?) {
        latest = value
        onChange?(value)
    }
}

@MainActor
private final class ResultPaginationPresentationController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

@MainActor
private final class ResultPaginationPresentationHost {
    let window: UIWindow
    let host: ResultPaginationPresentationController
    let boundary: ResultPaginationPresentationBoundaryProbe
    private weak var previousKeyWindow: UIWindow?
    private var closed = false

    init(scene: UIWindowScene, root: AnyView, size: CGSize, boundary: ResultPaginationPresentationBoundaryProbe) {
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        host = ResultPaginationPresentationController(rootView: root)
        self.boundary = boundary
    }

    func layout() {
        guard !closed else { return }
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
    }

    func close() {
        guard !closed else { return }
        closed = true
        host.onLayout = nil
        boundary.onChange = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

/// Entire response is returned once, irrespective of the requested limit.
/// Int.max is asserted above; no reranking, encoding or artificial page service.
@MainActor
private final class ResultPaginationPresentationWorker: PhotoWorkServicing {
    static let query = "TEST synthetic sunset by the sea"
    let hits: [SearchHit]
    private let summary = LibrarySummary(indexedCount: 37, modelVersion: "pagination-presentation-only",
                                         placesDescription: "TEST: no boundary pack or Photos scan")
    private(set) var refreshCount = 0
    private(set) var searchCount = 0
    private(set) var requestedTexts: [String] = []
    private(set) var requestedLimits: [Int] = []
    private(set) var requestedWeights: [Float] = []

    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        let namespace = UUID().uuidString
        hits = (0..<37).map { rank in
            // Deliberately non-lexical ID order; neither AppState nor the view
            // may sort these again. IDs never identify an actual Photos asset.
            let photo = IndexedPhoto(id: "pagination-presentation-missing-\(namespace)-\((rank * 11) % 37)",
                                     modificationTime: 123, modelVersion: "pagination-presentation-only",
                                     imageEmbedding: vector, creationTime: 100)
            return SearchHit(photo: photo, score: Float(37 - rank) / 37)
        }
    }

    func refresh() async throws -> LibrarySummary {
        refreshCount += 1
        return summary
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searchCount += 1
        requestedTexts.append(text)
        requestedLimits.append(limit)
        requestedWeights.append(locationWeight)
        return SearchResponse(summary: summary, hits: hits)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        XCTFail("Presentation must never start indexing")
        throw AppFailure.storage("TEST: unexpected indexing")
    }

    func clear() async throws -> LibrarySummary {
        XCTFail("Presentation must never clear storage")
        throw AppFailure.storage("TEST: unexpected clear")
    }
}

@MainActor
private final class ResultPaginationPresentationTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        XCTFail("An English fixture must not check language packs")
        return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("An English fixture must not be translated")
        throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Presentation must never prepare language packs")
        throw QueryTranslationFailure.unsupported
    }
}