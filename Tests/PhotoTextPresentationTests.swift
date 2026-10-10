import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Four native hosted tests; exactly two UIReview screenshots, not goldens.
/// The production PhotoTextIndexSection owns every control and privacy sentence.
/// Only its surrounding Form and TOP test watermark belong to the test target.
/// AppState receives aggregate fixtures through refresh/indexPhotoText, never by
/// assigning private published state. No Photos assets, recognition, storage,
/// mutations, models, translation or network work is performed by these services.
/// AppState still constructs its concrete Photos wrapper and reads permission;
/// fail before construction if the real host can read Photos. In-process SwiftUI
/// AX can be empty: use UIKit Form structure here and real XCUI semantics separately.
@MainActor
final class PhotoTextPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testStoredCountsAndPrivacySettingsDarkSnapshotWithoutPhotosAccess() async throws {
        // Restored ON has no queued intent. A real OFF->ON now correctly shows
        // waiting/cancel instead of pretending that this is an idle saved count.
        let c = try await context(authorization: .notDetermined, savedEnabled: true)
        XCTAssertFalse(c.state.canRead)
        XCTAssertFalse(c.state.canIndexText, "Saved counts are not current Photos permission or search coverage")
        XCTAssertFalse(c.state.summary.authorizedCountKnown)
        XCTAssertEqual(c.state.summary.authorizedCount, 0)
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(c.state.summary.textIndexCounts, TextIndexCounts(records: 12, withText: 8, reduced: 3))

        let host = try await mount(c.state)
        defer { host.close() }
        let form = try collection(in: host, rows: 5)
        // Source-owned rows: counts, reduced-preview warning, manual
        // update, unchanged-photo scope, on-device/no-backup/saved-count privacy.
        // Capture the initial top; long scope/privacy copy may be below the fold.
        // Visibility + screenshot is review evidence, NOT an AX text assertion.
        try assertVisibleRow(0, in: form)
        try attachReview(host, name: "UIReview-photo-text-settings-dark")
        form.scrollToItem(at: IndexPath(item: 4, section: 0), at: .bottom, animated: false)
        try await settle(host)
        try assertVisibleRow(4, in: form)
        assertServices(c, textCalls: 0)
        form.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        try await settle(host)
        try assertVisibleRow(0, in: form)
        attachEvidence(c, name: "Photo text settings fixture evidence")
        assertServices(c, textCalls: 0)
        XCTAssertNil(c.state.activity)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
    }

    func testExplicitIndexPublishesHeldProgressDarkSnapshot() async throws {
        let published = expectation(description: "Explicit text index callback accepted before capture")
        let c = try await context(authorization: .authorized, progressPublished: published, savedEnabled: true)
        XCTAssertTrue(c.state.canIndexText, "Only injected authorization is readable; real Photos stays unreadable")
        c.state.indexPhotoText()
        XCTAssertEqual(c.state.activity, .indexingText)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        guard await XCTWaiter.fulfillment(of: [published], timeout: 5) == .completed else {
            XCTFail("The real AppState indexPhotoText action did not publish the held worker callback")
            throw PhotoTextReviewFailure.progress
        }
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextReviewWorker.progressFixture)
        XCTAssertEqual(c.state.textIndexProgress.fraction, 0.5)
        XCTAssertEqual(c.state.textIndexProgress.summary,
                       "已检查 12/24 · 已识别 8 · 已复用 1 · 含文字 6 · 降低分辨率 3 · 需云端 1 · 失败 1 · 已变化跳过 1")
        XCTAssertFalse(c.state.canIndexText, "A second update must not start while the worker is held")

        let host = try await mount(c.state)
        defer { host.close() }
        let form = try collection(in: host, rows: 5)
        // Live child status/progress, cancel, aggregate progress, scope, privacy.
        // Capture before scrolling; five existing rows need not fit one viewport.
        try assertVisibleRow(0, in: form)
        try attachReview(host, name: "UIReview-photo-text-progress-dark")
        form.scrollToItem(at: IndexPath(item: 4, section: 0), at: .bottom, animated: false)
        try await settle(host)
        try assertVisibleRow(4, in: form)
        assertServices(c, textCalls: 1) // Only the explicit held index call; no work from scrolling.
        form.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        try await settle(host)
        try assertVisibleRow(0, in: form)
        attachEvidence(c, name: "Photo text progress fixture evidence")
        XCTAssertEqual(c.state.activity, .indexingText, "Capture occurs before release, not after a completed fake job")
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown, "Old counts must not masquerade as fresh progress")
        assertServices(c, textCalls: 1)

        // Exercise the production pause action's state method, not a fabricated
        // SwiftUI tap. Release and drain even the deliberately held fake worker.
        PhotoTextIndexContent(state: c.state).cancelUpdate()
        c.worker.release()
        await c.state.waitUntilIdle()
        try await settle(host)
        XCTAssertNil(c.state.activity)
        XCTAssertFalse(c.state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(c.state.textIndexProgress, PhotoTextReviewWorker.progressFixture)
        XCTAssertTrue(c.state.textIndexOperationIssue?.contains("已暂停") == true)
        assertServices(c, textCalls: 1)
    }

    func testRenderingAndDuplicateTrueDoNotIndexButEachOffOnUpdatesOnce() async throws {
        let c = try await context(authorization: .authorized)
        c.worker.permitsUnheldUpdate = true
        XCTAssertFalse(c.state.textSearchEnabled, "No persisted defaults are injected into hosted fixtures")
        let host = try await mount(c.state)
        defer { host.close() }
        _ = try collection(in: host, rows: 6)
        assertServices(c, textCalls: 0)

        // State bindings only; actual switch-thumb activation is covered by the
        // separate live UI test. Require the real Form to respond on each change.
        for (enabled, calls) in [(true, 1), (true, 1), (false, 1), (true, 2), (false, 2)] {
            c.state.textSearchEnabled = enabled
            try await settle(host)
            await c.state.waitUntilIdle()
            _ = try collection(in: host, rows: enabled ? 5 : 6)
            XCTAssertEqual(c.state.textSearchEnabled, enabled)
            XCTAssertEqual(c.state.canIndexText, enabled, "The idle ON case must be genuinely eligible for manual indexing")
            XCTAssertNil(c.state.activity)
            XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
            XCTAssertEqual(c.state.summary.textIndexCounts, c.worker.metadata.textIndexCounts,
                           "Turning OFF preserves stored text counts; it does not clear the index")
            XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
            assertServices(c, textCalls: calls)
        }
    }

    func testMaximumDynamicTypeCanScrollToPrivacyAndBackWithoutHorizontalContentOverflow() async throws {
        let c = try await context(authorization: .authorized, savedEnabled: true)
        let host = try await mount(c.state, size: CGSize(width: 320, height: 568), dynamicType: .accessibility5)
        defer { host.close() }
        let form = try collection(in: host, rows: 5)
        XCTAssertTrue(form.isScrollEnabled)
        XCTAssertGreaterThan(form.contentSize.height, form.bounds.height)
        XCTAssertGreaterThan(form.contentSize.width, 0)
        XCTAssertLessThanOrEqual(form.contentSize.width, form.bounds.width)
        let originalOffset = form.contentOffset
        let privacy = IndexPath(item: 4, section: 0)
        form.scrollToItem(at: privacy, at: .bottom, animated: false)
        try await settle(host)
        try assertVisibleRow(4, in: form)
        XCTAssertGreaterThan(form.contentOffset.y, originalOffset.y)
        XCTAssertEqual(form.contentOffset.x, originalOffset.x)
        XCTAssertLessThanOrEqual(form.contentSize.width, form.bounds.width)
        let bottomOffset = form.contentOffset.y
        form.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
        try await settle(host)
        try assertVisibleRow(0, in: form)
        XCTAssertLessThan(form.contentOffset.y, bottomOffset)
        XCTAssertLessThanOrEqual(form.contentSize.width, form.bounds.width)
        assertServices(c, textCalls: 0)
        XCTAssertNil(c.state.activity)
        // No third screenshot, smaller font, whole-host containment requirement
        // or comparison between differently positioned glyphs. A long privacy
        // row may itself exceed the viewport: this proves scrolling/structure,
        // not every character's visibility or VoiceOver behavior.
    }

    // MARK: Public state APIs, aggregate-only injected services

    private func context(authorization: PHAuthorizationStatus,
                         progressPublished: XCTestExpectation? = nil,
                         savedEnabled: Bool = false) async throws -> PhotoTextReviewContext {
        let permission = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos test host; these tests never reset or request permission")
            throw PhotoTextReviewFailure.readablePhotos
        }
        let worker = PhotoTextReviewWorker(progressPublished: progressPublished)
        let translator = PhotoTextReviewTranslator()
        let suite = "PhotoTextPresentationTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.set(savedEnabled, forKey: "photoTextSearchEnabled.v1")
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        let state = AppState(worker: worker, authorizationStatus: { authorization }, queryTranslator: translator,
                     textSearchPreferences: preferences)
        let c = PhotoTextReviewContext(state: state, worker: worker, translator: translator, permission: permission)
        addTeardownBlock { @MainActor in
            state.enterBackground()
            worker.release()
            await state.waitUntilIdle()
            XCTAssertEqual(PhotoLibraryClient.authorization, permission)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(worker.unexpectedCalls, 0)
            XCTAssertEqual(translator.calls, 0)
        }
        XCTAssertEqual(state.summary.textIndexCounts, TextIndexCounts())
        XCTAssertFalse(state.summary.textIndexStatisticsKnown)
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertTrue(state.modelsReady)
        XCTAssertTrue(state.summary.textIndexStatisticsKnown)
        XCTAssertEqual(state.summary.textIndexCounts, worker.metadata.textIndexCounts)
        assertServices(c, textCalls: 0)
        return c
    }

    private func assertServices(_ c: PhotoTextReviewContext, textCalls: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.worker.refreshCount, 1, file: file, line: line)
        XCTAssertEqual(c.worker.textNetworkFlags, Array(repeating: false, count: textCalls), file: file, line: line)
        XCTAssertEqual(c.worker.unexpectedCalls, 0, file: file, line: line)
        XCTAssertEqual(c.translator.calls, 0, file: file, line: line)
        XCTAssertNil(c.state.appleTranslationService, file: file, line: line)
        XCTAssertFalse(c.state.allowICloudDownload, file: file, line: line)
        XCTAssertFalse(c.state.library.canReadImages, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
        XCTAssertEqual(PhotoLibraryClient.authorization, c.permission, file: file, line: line)
        XCTAssertEqual(c.state.summary.indexedCount, 12, file: file, line: line)
        XCTAssertEqual(c.state.progress, IndexProgress(), file: file, line: line)
        XCTAssertTrue(c.state.results.isEmpty, file: file, line: line)
        XCTAssertNil(c.state.completedQuery, file: file, line: line)
        XCTAssertNil(c.state.selection, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
    }

    private func attachEvidence(_ c: PhotoTextReviewContext, name: String) {
        let counts = c.state.summary.textIndexCounts
        let evidence = XCTAttachment(string: """
            TEST FIXTURE: production PhotoTextIndexSection inside a native Form.
            optIn=\(c.state.textSearchEnabled); activity=\(String(describing: c.state.activity))
            refreshCalls=\(c.worker.refreshCount); explicitTextCalls=\(c.worker.textNetworkFlags.count)
            savedCountsKnown=\(c.state.summary.textIndexStatisticsKnown)
            savedRecords=\(counts.records); withText=\(counts.withText); reduced=\(counts.reduced)
            progress=\(c.state.textIndexProgress.summary); fraction=\(c.state.textIndexProgress.fraction)
            realPhotosReadable=\(PhotoLibraryClient.canRead); iCloudAllowed=\(c.state.allowICloudDownload)
            Only aggregate values were supplied: no asset IDs, recognized strings or photo pixels.
            Scope/privacy sentences are rendered from production, not copied into a fake view.
            Review saved-count/permission distinction, explicit OFF->ON/manual requests, local/no-backup storage,
            retained records when OFF, clear-index deletion, and the conditional iCloud explanation.
            Rendering is not proof of storage protection, actual OCR quality, or device performance.
            """)
        evidence.name = name
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    // MARK: File-private adaptation of the existing native presentation hosts

    private func mount(_ state: AppState, size: CGSize? = nil,
                       dynamicType: DynamicTypeSize = .large) async throws -> PhotoTextReviewHost {
        let size = size ?? phone
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let root = VStack(spacing: 0) {
            Text("TEST FIXTURE · synthetic counts · no Photos/OCR")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).padding(.vertical, 6)
                .frame(maxWidth: .infinity).background(Color.black)
            NavigationStack {
                Form { PhotoTextIndexSection(state: state) }
                    .scrollContentBackground(.hidden)
                    .background(IQStyle.background)
                    .foregroundStyle(IQStyle.text)
                    .tint(IQStyle.accent)
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(IQStyle.background, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, dynamicType)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = PhotoTextReviewHost(scene: scene, root: AnyView(root), size: size)
        var mounted = false
        defer { if !mounted { host.close() } }
        let laidOut = expectation(description: "Native photo text host laid out at \(size)")
        host.controller.onLayout = { [weak controller = host.controller] in
            guard let controller, controller.view.window != nil, controller.view.bounds.size == size else { return }
            controller.onLayout = nil
            laidOut.fulfill()
        }
        host.window.rootViewController = host.controller
        host.window.makeKeyAndVisible()
        host.layout()
        guard await XCTWaiter.fulfillment(of: [laidOut], timeout: 5) == .completed else {
            XCTFail("Native photo text host did not lay out")
            throw PhotoTextReviewFailure.layout
        }
        try await settle(host)
        XCTAssertEqual(host.controller.view.bounds.size, size)
        mounted = true
        return host
    }

    private func settle(_ host: PhotoTextReviewHost) async throws {
        let settled = expectation(description: "Pending native photo text layout updates completed")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); settled.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 5) == .completed else {
            XCTFail("Photo text layout did not settle")
            throw PhotoTextReviewFailure.layout
        }
    }

    private func collection(in host: PhotoTextReviewHost, rows: Int) throws -> UICollectionView {
        func descendants(_ view: UIView) -> [UICollectionView] {
            let own = (view as? UICollectionView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants($0) }
        }
        let forms = descendants(host.controller.view).filter {
            !$0.isHidden && $0.alpha > 0 && $0.window === host.window && !$0.bounds.isEmpty
        }
        XCTAssertEqual(forms.count, 1, "Like existing Form tests, require the real iOS collection backing")
        let form = try XCTUnwrap(forms.first)
        XCTAssertEqual(form.numberOfSections, 1, "This host includes only the unmodified production text section")
        guard form.numberOfSections == 1 else { throw PhotoTextReviewFailure.layout }
        XCTAssertEqual(form.numberOfItems(inSection: 0), rows)
        guard form.numberOfItems(inSection: 0) == rows else { throw PhotoTextReviewFailure.layout }
        return form
    }

    private func assertVisibleRow(_ row: Int, in form: UICollectionView) throws {
        let index = IndexPath(item: row, section: 0)
        XCTAssertTrue(form.indexPathsForVisibleItems.contains(index))
        let attributes = try XCTUnwrap(form.layoutAttributesForItem(at: index))
        let visible = attributes.frame.intersection(form.bounds.inset(by: form.adjustedContentInset))
        XCTAssertFalse(visible.isNull)
        XCTAssertGreaterThan(visible.width, 0)
        XCTAssertGreaterThan(visible.height, 0)
        // Do not require host.contains(viewport): a custom-width native Form
        // can extend one backing pixel past its hosting view without overflow.
    }

    private func attachReview(_ host: PhotoTextReviewHost, name: String) throws {
        let view = host.controller.view!
        XCTAssertEqual(view.bounds.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let native = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew else { XCTFail("UIKit did not draw the native Form"); throw PhotoTextReviewFailure.drawing }
        let cg = try XCTUnwrap(native.cgImage)
        XCTAssertEqual(cg.width, Int((phone.width * format.scale).rounded()))
        XCTAssertEqual(cg.height, Int((phone.height * format.scale).rounded()))
        format.scale = 1
        let review = UIGraphicsImageRenderer(size: phone, format: format).image { _ in
            native.draw(in: CGRect(origin: .zero, size: phone))
        }
        XCTAssertEqual(review.size, phone)
        let attachment = XCTAttachment(image: review)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum PhotoTextReviewFailure: Error { case readablePhotos, progress, layout, drawing, unexpectedWork }

@MainActor
private struct PhotoTextReviewContext {
    let state: AppState
    let worker: PhotoTextReviewWorker
    let translator: PhotoTextReviewTranslator
    let permission: PHAuthorizationStatus
}

@MainActor
private final class PhotoTextReviewWorker: PhotoWorkServicing {
    let metadata = LibrarySummary(indexedCount: 12, modelVersion: "TEST-photo-text-presentation",
                                  textIndexCounts: TextIndexCounts(records: 12, withText: 8, reduced: 3),
                                  textIndexStatisticsKnown: true)
    static let progressFixture = TextIndexProgress(total: 24, completed: 12, recognized: 8, reused: 1,
                                                   withText: 6, reduced: 3, cloudSkipped: 1, failed: 1, staleSkipped: 1)
    private(set) var refreshCount = 0
    private(set) var textNetworkFlags: [Bool] = []
    private(set) var unexpectedCalls = 0
    var permitsUnheldUpdate = false
    private let progressPublished: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(progressPublished: XCTestExpectation?) { self.progressPublished = progressPublished }

    func refresh() async throws -> LibrarySummary { refreshCount += 1; return metadata }

    func indexText(networkAllowed: Bool,
                   progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        textNetworkFlags.append(networkAllowed)
        // No progress callback means an unknown total, not a fabricated count.
        // This branch tests event/rendering ownership, not OCR data correctness.
        if permitsUnheldUpdate { return metadata }
        guard let progressPublished else { throw unexpected("Automatic text indexing") }
        try Task.checkCancellation()
        await progress(Self.progressFixture)
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                progressPublished.fulfill() // Callback accepted AND hold installed before the test proceeds.
            }
        }
        try Task.checkCancellation()
        return metadata
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func index(networkAllowed: Bool,
               progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected("Image indexing")
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        throw unexpected("Searching")
    }
    func clear() async throws -> LibrarySummary { throw unexpected("Clearing storage") }

    private func unexpected(_ operation: String) -> PhotoTextReviewFailure {
        unexpectedCalls += 1
        XCTFail("\(operation) must not be triggered by presenting/toggling the text section")
        return .unexpectedWork
    }
}

@MainActor
private final class PhotoTextReviewTranslator: QueryTranslating {
    let isSupported = false
    private(set) var calls = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        calls += 1; XCTFail("The text section must not check translation availability"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        calls += 1; XCTFail("The text section must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        calls += 1; XCTFail("The text section must not prepare translation"); throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class PhotoTextReviewController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
}

@MainActor
private final class PhotoTextReviewHost {
    let window: UIWindow
    let controller: PhotoTextReviewController
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, root: AnyView, size: CGSize) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = PhotoTextReviewController(rootView: root)
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