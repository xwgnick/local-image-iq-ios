import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Native, model-free review captures. All hits and drawn scenes live in this test
/// target; nothing is imported into Photos or read from a photo/image file.
/// Attachments are for human review in/export from xcresult, not pixel baselines.
/// Synthetic scenes are not model-quality evidence; no internet/public images
/// or private photos are used. English fixture queries are not app UI copy.
@MainActor
final class PresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let compactPhone = CGSize(width: 375, height: 667)

    func testThreeResultGridSnapshots() async throws {
        let hits = PresentationFixtures.hits(count: 3)
        XCTAssertTrue(hits.allSatisfy { $0.photo.imageEmbedding.count == 768 })
        for hit in hits { try EmbeddingValidation.validateUnit(hit.photo.imageEmbedding) }
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let layout = PresentationGridLayout()
            try await snapshot(PresentationGridReview(hits: hits, compact: false, layout: layout),
                               id: "teal-grid-\(appearance == .dark ? "dark" : "light")",
                               size: phone, appearance: appearance)
            // Measure the actual production grid's supplied thumbnail bounds,
            // not an inferred AX tree or a reconstructed layout. This also
            // checks the hit order: the first two share row one, third starts row two.
            try assertUniformGrid(hits, layout: layout, columns: 2, aspectRatio: 4.0 / 5.0, spacing: 6)
        }
    }

    func testTwelveResultGridSnapshots() async throws {
        let hits = PresentationFixtures.hits(count: 12)
        // A phone-height viewport cannot show all six rows. Capture both ends
        // of the actual scroll view instead of shrinking photos to fit twelve.
        try await snapshot(PresentationGridReview(hits: hits, compact: false),
                           id: "grid-12-top", size: phone, appearance: .light)
        try await snapshot(PresentationGridReview(hits: hits, compact: false, anchor: .bottom),
                           id: "grid-12-bottom", size: phone, appearance: .light)
    }

    func testCompactThreeColumnSnapshot() async throws {
        let hits = PresentationFixtures.hits(count: 12)
        let layout = PresentationGridLayout()
        try await snapshot(PresentationGridReview(hits: hits, compact: true, layout: layout),
                           id: "compact-3-columns", size: compactPhone, appearance: .light)
        try assertUniformGrid(hits, layout: layout, columns: 3, aspectRatio: 1, spacing: 4)
    }

    func testEmptyHomeSnapshot() async throws {
        let state = AppState(worker: FakePhotoWorkServicing(summary: PresentationFixtures.emptySummary),
                             authorizationStatus: { .notDetermined })
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertFalse(state.canRead)
        XCTAssertTrue(state.modelsReady)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertNil(state.completedQuery)
        try await snapshot(ContentView(state: state), id: "teal-home-light", size: phone, appearance: .light)
        try await snapshot(ContentView(state: state), id: "teal-home-dark", size: phone, appearance: .dark)
    }

    func testReadyHomeSnapshot() async throws {
        let state = await readyState()
        XCTAssertEqual(state.summary.indexedCount, 12)
        XCTAssertTrue(state.canIndex)
        XCTAssertFalse(state.canSearch, "An empty query must not enable search")
        XCTAssertNil(state.completedQuery)
        XCTAssertEqual(state.resultLimit, 3)
        XCTAssertEqual(state.locationWeight, 0.6)
        try await snapshot(ContentView(state: state), id: "teal-ready-light", size: phone, appearance: .light)
        try await snapshot(ContentView(state: state), id: "teal-ready-dark", size: phone, appearance: .dark)
    }

    func testLibraryLightAndDarkSnapshots() async throws {
        let state = AppState(worker: FakePhotoWorkServicing(summary: PresentationFixtures.emptySummary),
                             authorizationStatus: { .notDetermined })
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertFalse(state.canRead)
        XCTAssertFalse(state.canIndex)
        XCTAssertFalse(state.debugToolsEnabled)
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertEqual(state.summary.indexedCount, 0)
        XCTAssertNil(state.completedQuery)
        try await snapshot(LibrarySheet(state: state), id: "teal-library-light", size: phone, appearance: .light)
        try await snapshot(LibrarySheet(state: state), id: "teal-library-dark", size: phone, appearance: .dark)
        XCTAssertFalse(state.canRead, "Review must not request Photos permission")
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertNil(state.activity)
        XCTAssertTrue(state.results.isEmpty)
    }

    func testActualResultsUseMissingAssetPlaceholdersSnapshot() async throws {
        let hits = PresentationFixtures.hits(count: 3)
        let state = await readyState(worker: FakePhotoWorkServicing(hits: hits))
        state.query = "TEST FIXTURE mountain lake"
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.completedQuery, state.query)
        XCTAssertEqual(state.results.map(\.id), hits.map(\.id))
        XCTAssertFalse(state.allowICloudDownload)

        // Only the state service is stubbed. The real thumbnail cache/client has
        // no PHAsset for these IDs, so ContentView must use its real placeholder.
        // No authorize(), Photos writes, network fallback or cache injection.
        let photo = try XCTUnwrap(hits.first?.photo)
        do {
            _ = try await state.thumbnails.image(id: photo.id, revision: photo.modificationTime,
                                                  networkAllowed: false)
            XCTFail("A synthetic ID must never resolve to a user's photo")
        } catch {
            XCTAssertEqual(PhotoPreviewIssue(error: error).caption, "Unavailable")
        }
        try await snapshot(ContentView(state: state), id: "results-missing-assets", size: phone)
    }

    func testLargeFontSettingsSnapshot() async throws {
        let state = await readyState()
        try await snapshot(SettingsSheet(state: state), id: "settings-accessibility-large-light",
                           size: compactPhone, dynamicTypeSize: .accessibility1, appearance: .light)
        try await snapshot(SettingsSheet(state: state), id: "settings-accessibility-large-dark",
                           size: compactPhone, dynamicTypeSize: .accessibility1, appearance: .dark)
    }

    func testRefreshPublishesReadySummaryWithoutCompletingAQuery() async {
        let state = await readyState()
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertTrue(state.canRead)
        XCTAssertTrue(state.modelsReady)
        XCTAssertEqual(state.summary.authorizedCount, 12)
        XCTAssertEqual(state.summary.indexedCount, 12)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.completedQuery)
        XCTAssertTrue(state.results.isEmpty)
    }

    func testStoredIndexCopyNeverClaimsCurrentSearchCoverageFromSavedAuthorizationCounts() async {
        // Preserve old synthetic count fixtures: a retained integer alone does
        // not mean a scan happened, nor that indexed rows are still accessible.
        let cases: [(authorized: Int, known: Bool)] = [
            (0, false), (12, false), (24, false),
            (0, true), (3, true), (12, true), (24, true)
        ]
        for entry in cases {
            var summary = PresentationFixtures.readySummary
            summary.authorizedCount = entry.authorized
            summary.authorizedCountKnown = entry.known
            let state = await readyState(worker: FakePhotoWorkServicing(summary: summary))
            let home = ContentView(state: state)
            let library = LibrarySheet(state: state)
            XCTAssertEqual(home.libraryTitle, "已索引 12 张")
            XCTAssertEqual(home.librarySubtitle, "本机保存的索引 · 手动更新")
            XCTAssertEqual(library.storedCountText, home.libraryTitle)
            XCTAssertEqual(library.indexActionTitle, "更新索引")
            XCTAssertEqual(library.coverageDescription, "点「更新索引」处理新增或编辑过的照片，未变化的索引会复用。")
            XCTAssertEqual(library.accessDescription, "允许访问系统照片图库；新增或编辑照片后，请手动更新索引。")
            XCTAssertEqual(library.authorizedCountSnapshotText,
                           entry.known ? "\(entry.authorized.formatted()) 张" : "未扫描")
            XCTAssertNil(state.activity)
            XCTAssertNil(state.completedQuery)
        }
    }

    func testEmptyIndexCopyRequestsManualIndexingNotAClaimOfNoAccessiblePhotos() async {
        for known in [false, true] {
            var summary = PresentationFixtures.emptySummary
            summary.authorizedCountKnown = known
            let state = await readyState(worker: FakePhotoWorkServicing(summary: summary))
            let home = ContentView(state: state)
            let library = LibrarySheet(state: state)
            XCTAssertEqual(home.libraryTitle, "已索引 0 张")
            XCTAssertEqual(home.librarySubtitle, "本机保存的索引 · 手动更新")
            XCTAssertEqual(library.storedCountText, "已索引 0 张")
            XCTAssertEqual(library.indexActionTitle, "建立索引")
            XCTAssertEqual(library.coverageDescription, "点「建立索引」后才能按照片内容搜索；索引由你手动更新。")
            XCTAssertEqual(library.authorizedCountSnapshotText, known ? "0 张" : "未扫描")
            XCTAssertTrue(state.canIndex)
        }
    }

    func testLimitedPermissionCopyDoesNotLookLikeACurrentPhotoCount() async {
        for authorized in [0, 12, 24] {
            var summary = PresentationFixtures.readySummary
            summary.authorizedCount = authorized
            let state = AppState(worker: FakePhotoWorkServicing(summary: summary),
                                 authorizationStatus: { .limited })
            state.refresh()
            await state.waitUntilIdle()
            XCTAssertFalse(state.summary.authorizedCountKnown, "Old synthetic fixtures remain unscanned by default")
            let library = LibrarySheet(state: state)
            XCTAssertEqual(library.accessDescription, "仅能访问你选中的照片；调整选择后，请手动更新索引。")
            XCTAssertEqual(library.authorizedCountSnapshotText, "未扫描")
            XCTAssertEqual(library.indexActionTitle, "更新索引")
            XCTAssertEqual(ContentView(state: state).libraryTitle, "已索引 12 张")
        }
    }

    func testManualIndexExplanationCoversNewEditedDeletedAndInaccessiblePhotos() {
        let explanation = LibrarySheet.manualIndexExplanation
        XCTAssertTrue(explanation.contains("新增照片在更新索引后才能搜索"))
        XCTAssertTrue(explanation.contains("编辑过的照片在更新前仍按旧内容匹配"))
        XCTAssertTrue(explanation.contains("搜索会检查访问权限并排除已删除或不可访问的照片"))
        XCTAssertTrue(explanation.contains("更新或重建时请保持应用在前台"))
    }

    func testSearchPublishesCompletedQueryAndPreservesWorkerOrderAndScores() async {
        let source = PresentationFixtures.hits(count: 3)
        // Intentionally neither ID order nor descending score order: this test
        // checks presentation's pass-through contract, not the search algorithm.
        let hits = [SearchHit(photo: source[2].photo, score: -0.2),
                    SearchHit(photo: source[0].photo, score: 0.8),
                    SearchHit(photo: source[1].photo, score: 0.3)]
        let worker = FakePhotoWorkServicing(hits: hits)
        let state = await readyState(worker: worker)
        let query = "  TEST FIXTURE mountain lake  "
        state.query = query
        XCTAssertTrue(state.canSearch)
        state.search()
        XCTAssertNil(state.completedQuery, "Only a successful response completes a query")
        await state.waitUntilIdle()

        XCTAssertEqual(state.completedQuery, query)
        XCTAssertEqual(state.query, query)
        XCTAssertEqual(state.results.map(\.id), hits.map(\.id))
        XCTAssertEqual(state.results.map(\.score), hits.map(\.score))
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.errorMessage)
        let request = await worker.lastSearch
        XCTAssertEqual(request?.text, query)
        XCTAssertEqual(request?.limit, 3)
        XCTAssertEqual(request?.locationWeight, Float(0.6))
    }

    func testEditingQueryClearsCompletedResultsAndSelection() async throws {
        let state = await readyState()
        await completeSearch(state)
        let first = try XCTUnwrap(state.results.first)
        state.selection = AppState.Selection(id: first.id)
        state.query = "TEST FIXTURE a different memory"
        await state.waitUntilIdle()
        assertNoCompletedResults(state)
        XCTAssertNil(state.errorMessage)
    }

    func testZeroHitsStillCompletesTheQuery() async {
        let state = await readyState(worker: FakePhotoWorkServicing(hits: []))
        state.query = "TEST FIXTURE no matches"
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.completedQuery, "TEST FIXTURE no matches")
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isBusy)
        XCTAssertTrue(state.canSearch)
    }

    func testChangingEitherSearchSettingClearsCompletedResults() async throws {
        for setting in SearchSetting.allCases {
            let state = await readyState()
            await completeSearch(state)
            let first = try XCTUnwrap(state.results.first)
            state.selection = AppState.Selection(id: first.id)
            setting.change(state)
            await state.waitUntilIdle()
            assertNoCompletedResults(state)
            XCTAssertEqual(state.query, "TEST FIXTURE memory")
            XCTAssertNil(state.errorMessage)
        }
    }

    func testFailedSearchDoesNotMasqueradeAsCompletedZeroHits() async {
        let worker = FakePhotoWorkServicing()
        let state = await readyState(worker: worker)
        await completeSearch(state)
        await worker.failNextSearch()
        state.search()
        XCTAssertNil(state.completedQuery)
        await state.waitUntilIdle()
        assertNoCompletedResults(state)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertNotNil(state.actionHint)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.query, "TEST FIXTURE memory")
    }

    func testEditingQueryDiscardsLateCancelledSearchResponse() async {
        await assertLateResponseDiscarded { $0.query = "TEST FIXTURE edited while searching" }
    }

    func testChangingEitherSettingDiscardsLateCancelledSearchResponse() async {
        for setting in SearchSetting.allCases {
            await assertLateResponseDiscarded { setting.change($0) }
        }
    }

    func testExplicitCancellationDoesNotCompleteAQuery() async {
        await assertLateResponseDiscarded { $0.cancel() }
    }

    // MARK: State contracts

    private enum SearchSetting: CaseIterable {
        case resultCount, locationWeight

        @MainActor func change(_ state: AppState) {
            switch self {
            case .resultCount: state.resultLimit = 12
            case .locationWeight: state.locationWeight = 0.25
            }
        }
    }

    private func readyState(worker: FakePhotoWorkServicing = FakePhotoWorkServicing()) async -> AppState {
        let state = AppState(worker: worker, authorizationStatus: { .authorized })
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.errorMessage)
        return state
    }

    private func completeSearch(_ state: AppState) async {
        state.query = "TEST FIXTURE memory"
        state.search()
        await state.waitUntilIdle()
        XCTAssertEqual(state.completedQuery, state.query)
        XCTAssertFalse(state.results.isEmpty)
    }

    private func assertNoCompletedResults(_ state: AppState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.completedQuery, file: file, line: line)
        XCTAssertTrue(state.results.isEmpty, file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
    }

    private func assertLateResponseDiscarded(_ invalidate: (AppState) -> Void) async {
        let started = expectation(description: "Synthetic search reached its suspension point")
        let worker = FakePhotoWorkServicing()
        let state = await readyState(worker: worker)
        await worker.holdNextSearch(started: started)
        state.query = "TEST FIXTURE slow search"
        state.search()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(state.activity, .searching)
        XCTAssertNil(state.completedQuery)
        invalidate(state)
        // Release even if an assertion failed: no sleeping or stranded tasks.
        await worker.releaseSearch()
        await state.waitUntilIdle()
        assertNoCompletedResults(state)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.errorMessage)
        let returned = await worker.returnedSearchCount
        XCTAssertEqual(returned, 1, "The worker returned hits; AppState must reject the cancelled response")
    }

    // MARK: Native rendering

    private func assertUniformGrid(_ hits: [SearchHit], layout: PresentationGridLayout,
                                   columns: Int, aspectRatio: CGFloat, spacing: CGFloat,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(Set(layout.frames.keys), Set(hits.map(\.id)),
                       "Every synthetic thumbnail must report its real layout", file: file, line: line)
        let firstID = try XCTUnwrap(hits.first?.id, file: file, line: line)
        let first = try XCTUnwrap(layout.frames[firstID], file: file, line: line)
        XCTAssertGreaterThan(first.width, 0, file: file, line: line)
        XCTAssertGreaterThan(first.height, 0, file: file, line: line)
        for (index, hit) in hits.enumerated() {
            let frame = try XCTUnwrap(layout.frames[hit.id], file: file, line: line)
            XCTAssertGreaterThan(frame.height, 0, file: file, line: line)
            XCTAssertEqual(frame.width, first.width, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.height, first.height, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.width / frame.height, aspectRatio, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(frame.minX, first.minX + CGFloat(index % columns) * (first.width + spacing),
                           accuracy: 1, "Explicit design spacing and worker hit order", file: file, line: line)
            XCTAssertEqual(frame.minY, first.minY + CGFloat(index / columns) * (first.height + spacing),
                           accuracy: 1, "Explicit design spacing and worker hit order", file: file, line: line)
        }
    }

    private func snapshot<Content: View>(_ content: Content, id: String, size: CGSize,
                                         dynamicTypeSize: DynamicTypeSize = .large,
                                         appearance: UIUserInterfaceStyle = .light) async throws {
        XCTAssertTrue(appearance == .light || appearance == .dark, "Review appearance must be explicit")
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native hosted snapshots require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = appearance
        let background = UIColor(IQStyle.background).resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance))
        window.backgroundColor = background
        let root = content
            .preferredColorScheme(appearance == .dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = PresentationHostingController(rootView: root)
        host.overrideUserInterfaceStyle = appearance
        let laidOut = expectation(description: "\(id): hosted view laid out at the requested phone size")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == size else { return }
            host.onLayout = nil
            laidOut.fulfill()
        }
        defer {
            host.onLayout = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)

        // Yield to the main run loop for SwiftUI updates, tasks and scroll-anchor
        // placement, then lay out again. No Thread.sleep on the UI thread.
        let settled = expectation(description: "\(id): pending native layout updates completed")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(host.view.bounds.size, size)
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, appearance)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Exact 393x852 / 375x667 output, independent of simulator scale.
        format.opaque = true
        format.preferredRange = .standard
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drewHierarchy = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "UIKit must actually draw the hosted hierarchy")
        XCTAssertEqual(image.size, size)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int(size.width))
        XCTAssertEqual(pixels.height, Int(size.height))
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Dimensions are NOT assertions about per-rank bounds, clipping or
        // visual quality. SwiftUI accessibility can flatten the UIKit hierarchy;
        // navigation identifiers are exercised through XCUI, not view-tree guesses.
    }
}

@MainActor
private final class PresentationHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

/// Minimal review wrapper, not a replacement app screen. The production grid
/// owns columns, ranks, aspect ratios and clipping; only its thumbnail is supplied.
@MainActor
private struct PresentationGridReview: View {
    let hits: [SearchHit]
    let compact: Bool
    var anchor: UnitPoint = .top
    let layout: PresentationGridLayout?
    private let images: [String: UIImage]

    init(hits: [SearchHit], compact: Bool, anchor: UnitPoint = .top, layout: PresentationGridLayout? = nil) {
        self.hits = hits
        self.compact = compact
        self.anchor = anchor
        self.layout = layout
        images = Dictionary(uniqueKeysWithValues: hits.enumerated().map { offset, hit in
            (hit.id, PresentationFixtures.sceneImage(index: offset))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TEST FIXTURE · DRAWN SCENES").font(.caption.weight(.bold)).foregroundStyle(IQStyle.accent)
                Text("\(hits.count) 张候选照片 · \(compact ? "紧凑网格" : "较大照片")").font(.title3.weight(.semibold))
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            ScrollView {
                PhotoResultsGrid(hits: hits, compact: compact, onSelect: { _ in }) { photo in
                    // The dictionary is constructed from exactly these hits.
                    PresentationThumbnail(image: images[photo.id]!)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: PresentationGridFramesKey.self,
                                                       value: [photo.id: geometry.frame(in: .named("presentation-grid-layout"))])
                            }
                        }
                }
                .coordinateSpace(name: "presentation-grid-layout")
                .onPreferenceChange(PresentationGridFramesKey.self) { frames in
                    // Preserve the last mounted sample when the host is torn
                    // down. No view-tree search or production state mutation.
                    if !frames.isEmpty { layout?.frames = frames }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .defaultScrollAnchor(anchor)
        }
        .foregroundStyle(IQStyle.text)
        .background(IQStyle.background.ignoresSafeArea())
    }
}

@MainActor
private final class PresentationGridLayout {
    var frames: [String: CGRect] = [:]
}

private struct PresentationGridFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private struct PresentationThumbnail: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
    }
}

private enum PresentationFixtures {
    // Only a non-nil version matters to AppState's readiness contract. This is
    // not a ModelManifest, a production cache entry or a model-parity assertion.
    static let modelVersion = "presentation-test-only"
    static var emptySummary: LibrarySummary {
        LibrarySummary(modelVersion: modelVersion, placesDescription: "No offline boundary pack bundled (TEST FIXTURE).")
    }
    static var readySummary: LibrarySummary {
        LibrarySummary(authorizedCount: 12, indexedCount: 12, modelVersion: modelVersion,
                       placesDescription: "No offline boundary pack bundled (TEST FIXTURE).")
    }

    static func hits(count: Int) -> [SearchHit] {
        let vector = TestFixtures.vector()
        return (0..<count).map { index in
            let photo = IndexedPhoto(id: "presentation-test-fixture-\(index + 1)", modificationTime: 123,
                                     modelVersion: modelVersion, imageEmbedding: vector, creationTime: 100)
            return SearchHit(photo: photo, score: Float(count - index) / 20)
        }
    }

    /// Recognizable landscape/portrait scene simulations, not blank swatches or
    /// user images. A central baked-in label survives the grid's aspect-fill crop.
    @MainActor static func sceneImage(index: Int) -> UIImage {
        let size = index.isMultiple(of: 2) ? CGSize(width: 720, height: 480) : CGSize(width: 480, height: 720)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.saveGState()
            context.scaleBy(x: size.width, y: size.height)

            func rectangle(_ rect: CGRect, _ color: UIColor) {
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
            func ellipse(_ rect: CGRect, _ color: UIColor) {
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: rect)
            }
            func polygon(_ points: [CGPoint], _ color: UIColor) {
                guard let first = points.first else { return }
                context.beginPath()
                context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
                context.closePath()
                context.setFillColor(color.cgColor)
                context.fillPath()
            }

            switch index % 3 {
            case 0: // Mountain lake, snow caps, forest and a small cabin.
                rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), UIColor(red: 0.47, green: 0.72, blue: 0.86, alpha: 1))
                ellipse(CGRect(x: 0.67, y: 0.12, width: 0.12, height: 0.15), .systemYellow)
                polygon([CGPoint(x: -0.1, y: 0.59), CGPoint(x: 0.28, y: 0.18), CGPoint(x: 0.65, y: 0.59)], .systemGray)
                polygon([CGPoint(x: 0.3, y: 0.59), CGPoint(x: 0.66, y: 0.23), CGPoint(x: 1.1, y: 0.59)], .darkGray)
                polygon([CGPoint(x: 0.19, y: 0.28), CGPoint(x: 0.28, y: 0.18), CGPoint(x: 0.37, y: 0.28)], .white)
                rectangle(CGRect(x: 0, y: 0.56, width: 1, height: 0.44), .systemTeal)
                polygon([CGPoint(x: 0, y: 0.64), CGPoint(x: 0.56, y: 0.85), CGPoint(x: 1, y: 0.81),
                         CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)], .systemGreen)
                rectangle(CGRect(x: 0.62, y: 0.72, width: 0.16, height: 0.15), .systemBrown)
                polygon([CGPoint(x: 0.59, y: 0.73), CGPoint(x: 0.7, y: 0.61), CGPoint(x: 0.81, y: 0.73)], .systemRed)
                rectangle(CGRect(x: 0.68, y: 0.79, width: 0.04, height: 0.08), .black)
                for x in [CGFloat(0.08), 0.17, 0.86] {
                    rectangle(CGRect(x: x + 0.025, y: 0.67, width: 0.02, height: 0.19), .brown)
                    polygon([CGPoint(x: x - 0.04, y: 0.76), CGPoint(x: x + 0.035, y: 0.48),
                             CGPoint(x: x + 0.11, y: 0.76)], UIColor(red: 0.08, green: 0.32, blue: 0.22, alpha: 1))
                }
            case 1: // Flowers in a vase beside a window, useful for portrait crops.
                rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), UIColor(red: 0.91, green: 0.84, blue: 0.72, alpha: 1))
                rectangle(CGRect(x: 0.08, y: 0.07, width: 0.4, height: 0.43), .white)
                rectangle(CGRect(x: 0.1, y: 0.09, width: 0.36, height: 0.39), .systemTeal)
                rectangle(CGRect(x: 0.265, y: 0.09, width: 0.025, height: 0.39), .white)
                rectangle(CGRect(x: 0.1, y: 0.28, width: 0.36, height: 0.025), .white)
                rectangle(CGRect(x: 0, y: 0.78, width: 1, height: 0.22), .systemBrown)
                for (offset, x) in [CGFloat(0.34), 0.5, 0.66].enumerated() {
                    let y = CGFloat(0.36) + CGFloat(offset % 2) * 0.09
                    rectangle(CGRect(x: x - 0.01, y: y, width: 0.02, height: 0.3), .systemGreen)
                    for delta in [CGPoint(x: -0.05, y: 0), CGPoint(x: 0.05, y: 0),
                                  CGPoint(x: 0, y: -0.05), CGPoint(x: 0, y: 0.05)] {
                        ellipse(CGRect(x: x + delta.x - 0.045, y: y + delta.y - 0.035, width: 0.09, height: 0.07),
                                offset == 1 ? .systemOrange : .systemPink)
                    }
                    ellipse(CGRect(x: x - 0.028, y: y - 0.02, width: 0.056, height: 0.04), .systemYellow)
                }
                polygon([CGPoint(x: 0.33, y: 0.59), CGPoint(x: 0.67, y: 0.59),
                         CGPoint(x: 0.61, y: 0.82), CGPoint(x: 0.39, y: 0.82)], .systemBlue)
            default: // Sunset beach, sailboat, surf and foreground sand.
                rectangle(CGRect(x: 0, y: 0, width: 1, height: 1), UIColor(red: 0.94, green: 0.59, blue: 0.43, alpha: 1))
                ellipse(CGRect(x: 0.4, y: 0.22, width: 0.2, height: 0.2), .systemYellow)
                rectangle(CGRect(x: 0, y: 0.46, width: 1, height: 0.54), .systemTeal)
                polygon([CGPoint(x: 0, y: 0.89), CGPoint(x: 1, y: 0.66), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)],
                        UIColor(red: 0.9, green: 0.79, blue: 0.56, alpha: 1))
                polygon([CGPoint(x: 0.36, y: 0.59), CGPoint(x: 0.67, y: 0.59),
                         CGPoint(x: 0.62, y: 0.64), CGPoint(x: 0.41, y: 0.64)], .systemBrown)
                rectangle(CGRect(x: 0.505, y: 0.31, width: 0.014, height: 0.29), .darkGray)
                polygon([CGPoint(x: 0.53, y: 0.33), CGPoint(x: 0.53, y: 0.56), CGPoint(x: 0.68, y: 0.56)], .white)
                polygon([CGPoint(x: 0.49, y: 0.39), CGPoint(x: 0.38, y: 0.56), CGPoint(x: 0.49, y: 0.56)], .systemOrange)
                for y in [CGFloat(0.68), 0.73, 0.78] {
                    rectangle(CGRect(x: 0.12, y: y, width: 0.2, height: 0.005), .white.withAlphaComponent(0.6))
                }
            }
            context.restoreGState()

            let banner = CGRect(x: size.width / 2 - 118, y: size.height * 0.7, width: 236, height: 34)
            UIColor.black.withAlphaComponent(0.7).setFill()
            UIBezierPath(roundedRect: banner, cornerRadius: 7).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            ("TEST FIXTURE" as NSString).draw(in: banner.insetBy(dx: 4, dy: 3), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 22), .foregroundColor: UIColor.white, .paragraphStyle: paragraph
            ])
        }
    }
}

/// Deliberately returns a held response even after cancellation, like work that
/// cannot be interrupted mid-prediction. AppState must discard that late result.
private actor FakePhotoWorkServicing: PhotoWorkServicing {
    struct SearchRequest: Sendable {
        let text: String
        let limit: Int
        let locationWeight: Float
    }

    private let summary: LibrarySummary
    private let hits: [SearchHit]
    private var nextSearchFails = false
    private var started: XCTestExpectation?
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var lastSearch: SearchRequest?
    private(set) var returnedSearchCount = 0

    init(summary: LibrarySummary = PresentationFixtures.readySummary,
         hits: [SearchHit] = PresentationFixtures.hits(count: 3)) {
        self.summary = summary
        self.hits = hits
    }

    func refresh() async throws -> LibrarySummary { summary }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw AppFailure.storage("TEST FIXTURE: presentation tests must not start indexing")
    }

    func clear() async throws -> LibrarySummary {
        throw AppFailure.storage("TEST FIXTURE: presentation tests must not clear storage")
    }

    func failNextSearch() { nextSearchFails = true }

    func holdNextSearch(started: XCTestExpectation) {
        self.started = started
        released = false
    }

    func releaseSearch() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        lastSearch = SearchRequest(text: text, limit: limit, locationWeight: locationWeight)
        if let started {
            self.started = nil
            started.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        if nextSearchFails {
            nextSearchFails = false
            throw AppFailure.storage("TEST FIXTURE search failure")
        }
        returnedSearchCount += 1
        return SearchResponse(summary: summary, hits: hits)
    }
}