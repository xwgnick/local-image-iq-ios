import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Native app-host tests, not XCUI snapshots. The search host deliberately uses
/// the real SearchPhotoTextTools/SettingsSheet/anchor in a minimal SwiftUI sheet
/// harness: it does NOT claim to drive ContentView's private presentation state.
/// Cleanup tests mount the actual production page and its own presentations.
/// Public UIKit ancestry proves exclusion/independent modal scopes; strict
/// identifier existence (including shared tabs/Done) remains external XCUI work.
@MainActor
final class PrimaryModalAccessibilityTests: XCTestCase {
    func testSettingsExcludesRetainedSearchControlsAndRestoresSameSwitchAndQuery() async throws {
        let f = try await fixture(ready: false)
        f.app.query = "TEST retained modal query"
        let host = try await mount(AnyView(PrimaryModalSearchHost(fixture: f)))
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimarySearchScrollAnchorView.self).first)
        let scroll = try XCTUnwrap(anchor.owningScrollView)
        let base = try navigation(containing: anchor, in: host.controller)
        let field = try XCTUnwrap(descendants(scroll, UITextField.self).first)
        let toggle = try XCTUnwrap(descendants(scroll, UISwitch.self).first)
        XCTAssertFalse(toggle.isOn)
        // Exercise the real production binding, not a synthetic test button.
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await settle(host)
        XCTAssertTrue(f.app.textSearchEnabled)
        XCTAssertFalse(f.app.canIndexText)
        XCTAssertFalse(excluded(toggle))

        for _ in 0..<2 {
            f.settingsPresented = true
            let presented = try await waitForPresentation(host)
            let modal = try assertIndependentModal(presented, base: base, host: host)
            XCTAssertTrue(base.view.accessibilityElementsHidden)
            XCTAssertTrue(scroll.accessibilityElementsHidden)
            XCTAssertTrue(excluded(field) && excluded(toggle))
            XCTAssertTrue(field.window === host.window && toggle.window === host.window,
                          "A sheet excludes the retained controls rather than destroying them")
            let settingsToggle = try XCTUnwrap(descendants(modal.view, UISwitch.self).first)
            XCTAssertFalse(settingsToggle === toggle)
            XCTAssertFalse(toggle.isDescendant(of: modal.view), "Settings does not own the primary OCR switch")
            XCTAssertFalse(excluded(settingsToggle), "Do not hide the presented Settings controls")
            XCTAssertFalse(descendants(modal.view, UIScrollView.self).isEmpty, "Mount the real Settings Form")
            XCTAssertEqual(field.text, "TEST retained modal query")
            XCTAssertTrue(toggle.isOn && f.app.textSearchEnabled)

            f.settingsPresented = false
            try await waitForDismissal(host)
            XCTAssertTrue(anchor.owningNavigationController === base)
            XCTAssertTrue(anchor.owningScrollView === scroll)
            XCTAssertTrue(descendants(scroll, UITextField.self).contains { $0 === field })
            XCTAssertTrue(descendants(scroll, UISwitch.self).contains { $0 === toggle })
            XCTAssertFalse(base.view.accessibilityElementsHidden)
            XCTAssertFalse(scroll.accessibilityElementsHidden)
            XCTAssertFalse(excluded(field) || excluded(toggle))
            XCTAssertEqual(field.text, f.app.query)
            XCTAssertTrue(toggle.isOn && f.app.textSearchEnabled)
        }
        XCTAssertEqual(f.grouping.restores, 0)
        XCTAssertEqual(f.grouping.scans, 0)
        XCTAssertFalse(f.app.modelsReady, "Presentation must not manufacture readiness")
        assertNoWork(f)
    }

    func testParentSettingsOnlyExcludesCleanupAXWithoutLeavingPageOrLosingDetailSelection() async throws {
        let f = try await fixture()
        let host = try await mountCleanup(f)
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let base = try navigation(containing: anchor, in: host.controller)
        let group = try XCTUnwrap(f.cleanup.groups.first)
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        f.cleanup.toggleSelection(group.photos[1].id)
        let selected = f.cleanup.selectedIDs
        f.browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        try await requireLayout(host) {
            !self.controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.isEmpty
        }
        let grid = try XCTUnwrap(controllers(host.controller).compactMap { $0 as? SimilarPhotoGroupGridController }.first)
        let route = try XCTUnwrap(f.browser.detailRoute)
        let offset = grid.collectionView.contentOffset
        XCTAssertFalse(excluded(grid.collectionView))

        for _ in 0..<2 {
            f.settingsPresented = true
            let presented = try await waitForPresentation(host)
            let modal = try assertIndependentModal(presented, base: base, host: host)
            XCTAssertTrue(descendants(modal.view, UISlider.self).isEmpty,
                          "Threshold controls belong only to cleanup, not Settings")
            let settingsToggle = try XCTUnwrap(descendants(modal.view, UISwitch.self).first)
            XCTAssertFalse(excluded(settingsToggle), "The real Settings controls stay accessible")
            XCTAssertTrue(base.view.accessibilityElementsHidden)
            XCTAssertTrue(excluded(grid.collectionView))
            XCTAssertTrue(grid.collectionView.window === host.window)
            assertCleanup(f, session: session, selected: selected)
            XCTAssertTrue(f.cleanup.isPageVisible && f.cleanup.canSelect,
                          "Parent AX inactivity must not become a tab leave/readiness change")
            XCTAssertEqual(f.browser.detailRoute, route)

            f.settingsPresented = false
            try await waitForDismissal(host)
            XCTAssertTrue(anchor.owningNavigationController === base)
            XCTAssertTrue(controllers(host.controller).contains { $0 === grid })
            XCTAssertFalse(base.view.accessibilityElementsHidden)
            XCTAssertFalse(excluded(grid.collectionView))
            XCTAssertEqual(grid.collectionView.contentOffset, offset)
            XCTAssertEqual(f.browser.detailRoute, route)
            assertCleanup(f, session: session, selected: selected)
        }
        XCTAssertEqual(f.grouping.restores, 1)
        XCTAssertEqual(f.grouping.scans, 1)
        assertNoWork(f)
    }

    func testCleanupOwnComparisonAndFullScreenViewerHaveIndependentAccessibleScopes() async throws {
        let f = try await fixture()
        // Standalone ignores logical isPageActive=false, but still must exclude
        // its base scope while its own comparison or gallery is above it.
        f.cleanup.scan()
        await f.cleanup.waitUntilIdle()
        let host = try await mountCleanup(f, embedded: false)
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let base = try navigation(containing: anchor, in: host.controller)
        let group = try XCTUnwrap(f.cleanup.groups.first)
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        f.cleanup.toggleSelection(group.photos[0].id)
        let selected = f.cleanup.selectedIDs
        f.browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        try await settle(host)
        let route = try XCTUnwrap(f.browser.detailRoute)

        f.browser.comparisonGroup = group
        let comparison = try await waitForPresentation(host)
        _ = try assertIndependentModal(comparison, base: base, host: host)
        XCTAssertTrue(base.view.accessibilityElementsHidden)
        XCTAssertTrue(excluded(base.navigationBar))
        assertCleanup(f, session: session, selected: selected)
        f.browser.comparisonGroup = nil
        try await waitForDismissal(host)
        XCTAssertFalse(excluded(base.navigationBar))

        f.browser.viewPhoto(group.photos[1].id, in: group)
        let viewer = try await waitForPresentation(host)
        // PhotoGalleryViewer uses its own SwiftUI top/bottom bars, not a
        // NavigationStack. Test its actual presented root rather than inventing
        // a native navigation controller or counting synthetic buttons.
        assertIndependentSurface(viewer, base: base, host: host)
        // UIKit may detach the presenter for a full-screen cover. Detached views
        // are not AX targets; an attached presenter must have a hidden ancestor.
        XCTAssertTrue(excluded(base.navigationBar))
        XCTAssertEqual(f.browser.viewer?.id, group.photos[1].id)
        assertCleanup(f, session: session, selected: selected)
        f.browser.viewer = nil
        try await waitForDismissal(host)
        XCTAssertTrue(anchor.owningNavigationController === base)
        XCTAssertFalse(excluded(base.navigationBar))
        XCTAssertEqual(f.browser.detailRoute, route)
        assertCleanup(f, session: session, selected: selected)
        XCTAssertEqual(f.grouping.restores, 0)
        XCTAssertEqual(f.grouping.scans, 1)
        assertNoWork(f)
    }

    func testCleanupOwnAlertExcludesOnlyBaseAndDismissalRetainsCompletedGroups() async throws {
        let f = try await fixture()
        let host = try await mountCleanup(f)
        defer { host.close() }
        let anchor = try XCTUnwrap(descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).first)
        let base = try navigation(containing: anchor, in: host.controller)
        let session = try XCTUnwrap(f.cleanup.selectionSessionID)
        XCTAssertTrue(f.cleanup.selectedIDs.isEmpty)
        f.cleanup.prepareDeletion() // Empty-selection notice, never a deletion.
        XCTAssertNotNil(f.cleanup.message)
        let presented = try await waitForPresentation(host)
        let alert = try XCTUnwrap(controllers(presented).compactMap { $0 as? UIAlertController }.first)
        XCTAssertTrue(base.view.accessibilityElementsHidden)
        XCTAssertTrue(excluded(base.navigationBar))
        XCTAssertFalse(alert.view.isDescendant(of: base.view))
        XCTAssertTrue(alert.view.window === host.window)
        XCTAssertFalse(excluded(alert.view))
        XCTAssertFalse(alert.actions.isEmpty)
        assertSharedRootVisible(host)
        assertCleanup(f, session: session, selected: [])
        XCTAssertTrue(f.cleanup.isPageVisible && f.cleanup.canSelect)

        f.cleanup.dismissMessage()
        try await waitForDismissal(host)
        XCTAssertNil(f.cleanup.message)
        XCTAssertFalse(excluded(base.navigationBar))
        assertCleanup(f, session: session, selected: [])
        XCTAssertEqual(f.grouping.restores, 1)
        XCTAssertEqual(f.grouping.scans, 1)
        assertNoWork(f)
    }

    // MARK: Public native scope checks (no private SwiftUI AX traversal)

    private func assertIndependentModal(_ presented: UIViewController, base: UINavigationController,
                                        host: PrimaryModalHost) throws -> UINavigationController {
        assertIndependentSurface(presented, base: base, host: host)
        let navigations = controllers(presented).compactMap { $0 as? UINavigationController }
        XCTAssertEqual(navigations.count, 1)
        let modal = try XCTUnwrap(navigations.count == 1 ? navigations.first : nil)
        XCTAssertFalse(modal === base)
        XCTAssertFalse(modal.view.isDescendant(of: base.view), "The AX gate must not be an ancestor of the sheet")
        XCTAssertFalse(base.view.isDescendant(of: modal.view))
        XCTAssertTrue(modal.view.window === host.window)
        XCTAssertTrue(modal.navigationBar.isDescendant(of: modal.view))
        XCTAssertFalse(excluded(modal.view))
        XCTAssertFalse(excluded(modal.navigationBar))
        assertSharedRootVisible(host)
        return modal
    }

    private func assertIndependentSurface(_ presented: UIViewController, base: UINavigationController,
                                          host: PrimaryModalHost,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(presented.presentingViewController, file: file, line: line)
        XCTAssertFalse(presented.view.isDescendant(of: base.view), file: file, line: line)
        XCTAssertTrue(presented.view.window === host.window, file: file, line: line)
        XCTAssertFalse(presented.view.bounds.isEmpty, file: file, line: line)
        XCTAssertFalse(excluded(presented.view), file: file, line: line)
        assertSharedRootVisible(host, file: file, line: line)
    }

    private func assertSharedRootVisible(_ host: PrimaryModalHost,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden, file: file, line: line)
        XCTAssertFalse(host.window.accessibilityElementsHidden, file: file, line: line)
    }

    private func excluded(_ view: UIView) -> Bool {
        guard view.window != nil else { return true }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.accessibilityElementsHidden { return true }
            ancestor = current.superview
        }
        return false
    }

    private func navigation(containing view: UIView, in root: UIViewController) throws -> UINavigationController {
        // Independent of the anchor's responder resolver.
        let matches = controllers(root).compactMap { $0 as? UINavigationController }
            .filter { view.isDescendant(of: $0.view) }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.count == 1 ? matches.first : nil)
    }

    private func assertCleanup(_ f: PrimaryModalFixture, session: UUID, selected: Set<String>,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.cleanup.selectionSessionID, session, file: file, line: line)
        XCTAssertEqual(f.cleanup.groups.map(\.id), f.grouping.groups.map(\.id), file: file, line: line)
        XCTAssertEqual(f.cleanup.selectedIDs, selected, file: file, line: line)
        XCTAssertFalse(f.cleanup.isGrouping || f.cleanup.isRestoring || f.cleanup.needsRegroup, file: file, line: line)
        XCTAssertTrue(f.app.modelsReady && f.app.isForeground && f.app.summary.indexStatisticsKnown, file: file, line: line)
    }

    private func assertNoWork(_ f: PrimaryModalFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(f.app.activity, file: file, line: line)
        XCTAssertEqual(f.app.progress, IndexProgress(), file: file, line: line)
        XCTAssertEqual(f.app.textIndexProgress, TextIndexProgress(), file: file, line: line)
        XCTAssertTrue(f.app.results.isEmpty, file: file, line: line)
        XCTAssertFalse(f.app.allowICloudDownload, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
    }

    private func fixture(ready: Bool = true) async throws -> PrimaryModalFixture {
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos host; never request/reset permission")
            throw PrimaryModalFailure.photosReadable
        }
        let authorization = PhotoLibraryClient.authorization
        let f = PrimaryModalFixture(ready: ready)
        addTeardownBlock { @MainActor in
            f.cleanup.leavePage(); f.cleanup.pause(); f.app.enterBackground()
            await f.cleanup.waitUntilIdle(); await f.app.waitUntilIdle()
            f.app.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, authorization)
            XCTAssertFalse(PhotoLibraryClient.canRead)
        }
        if ready {
            f.app.refresh()
            await f.app.waitUntilIdle()
            XCTAssertTrue(f.app.modelsReady)
        }
        return f
    }

    private func mountCleanup(_ f: PrimaryModalFixture, embedded: Bool = true) async throws -> PrimaryModalHost {
        let host = try await mount(AnyView(PrimaryModalCleanupHost(fixture: f, embedded: embedded)))
        do {
            await f.cleanup.waitUntilIdle()
            try await requireLayout(host) { f.cleanup.hasScanned && !f.cleanup.groups.isEmpty }
            return host
        } catch { host.close(); throw error }
    }

    private func mount(_ content: AnyView) async throws -> PrimaryModalHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let root = content.environment(\.scenePhase, .active).environment(\.dynamicTypeSize, .large)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = PrimaryModalHost(scene: scene, controller: UIHostingController(rootView: root))
        do {
            try await requireLayout(host) {
                !self.descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).isEmpty
                    && !self.controllers(host.controller).compactMap { $0 as? UINavigationController }.isEmpty
            }
            try await settle(host)
            return host
        } catch { host.close(); throw error }
    }

    private func waitForPresentation(_ host: PrimaryModalHost) async throws -> UIViewController {
        try await requireLayout(host) {
            guard let presented = host.controller.presentedViewController else { return false }
            return presented.viewIfLoaded?.window != nil && !presented.isBeingPresented
        }
        try await settle(host)
        return try XCTUnwrap(host.controller.presentedViewController)
    }

    private func waitForDismissal(_ host: PrimaryModalHost) async throws {
        try await requireLayout(host) { host.controller.presentedViewController == nil }
        try await settle(host)
    }

    private func settle(_ host: PrimaryModalHost) async throws {
        let delivered = expectation(description: "Native modal transaction delivered")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); delivered.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [delivered], timeout: 5) == .completed else {
            XCTFail("Missing native modal layout")
            throw PrimaryModalFailure.layout
        }
    }

    private func requireLayout(_ host: PrimaryModalHost, observed: @escaping @MainActor () -> Bool) async throws {
        let inspect: @MainActor () -> Bool = { host.layout(); return observed() }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Missing actual native modal/page scope")
            throw PrimaryModalFailure.layout
        }
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func controllers(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllers($0) }
    }
}

private enum PrimaryModalFailure: Error { case layout, photosReadable, unexpectedWork, syntheticUnavailable }

@MainActor
private final class PrimaryModalFixture: ObservableObject {
    @Published var settingsPresented = false
    let app: AppState
    let cleanup: SimilarPhotoCleanupState
    let grouping = PrimaryModalGrouping()
    let browser = SimilarPhotoGroupBrowser()

    init(ready: Bool) {
        app = AppState(worker: PrimaryModalWorker(), authorizationStatus: { ready ? .authorized : .notDetermined },
                       queryTranslator: PrimaryModalTranslator())
        cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: PrimaryModalNoDeletion(), preferences: nil)
    }
}

@MainActor
private struct PrimaryModalSearchHost: View {
    @ObservedObject var fixture: PrimaryModalFixture
    @ObservedObject private var app: AppState
    init(fixture: PrimaryModalFixture) {
        self.fixture = fixture
        _app = ObservedObject(wrappedValue: fixture.app)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    TextField("TEST query", text: $app.query)
                    SearchPhotoTextTools(state: app, openFilters: {})
                }
                .padding()
                .background {
                    PrimarySearchScrollAnchor(active: !fixture.settingsPresented)
                        .frame(height: 0).accessibilityHidden(true)
                }
                .accessibilityHidden(fixture.settingsPresented)
            }
            .navigationTitle("TEST search")
        }
        .safeAreaInset(edge: .bottom) {
            PrimaryNavigationBar(page: .search, switchingDisabled: false, select: { _ in })
                .accessibilityHidden(fixture.settingsPresented)
        }
        .sheet(isPresented: $fixture.settingsPresented) {
            SettingsSheet(state: app, cleanup: fixture.cleanup)
        }
    }
}

@MainActor
private struct PrimaryModalCleanupHost: View {
    @ObservedObject var fixture: PrimaryModalFixture
    let embedded: Bool
    var body: some View {
        SimilarPhotoCleanupSheet(state: fixture.cleanup, appState: fixture.app, browser: fixture.browser,
            thumbnailContent: { _ in AnyView(Color.gray) },
            comparisonImageSource: SimilarComparisonImageSource(
                load: { _, _, _ in throw PrimaryModalFailure.syntheticUnavailable }, validate: { _, _, _ in }),
            embedded: embedded, isPageActive: embedded, accessibilityActive: !fixture.settingsPresented)
            .sheet(isPresented: $fixture.settingsPresented) {
                SettingsSheet(state: fixture.app, cleanup: fixture.cleanup)
            }
    }
}

@MainActor
private final class PrimaryModalHost {
    let window: UIWindow
    let controller: UIViewController
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, controller: UIViewController) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        if let presented = controller.presentedViewController {
            presented.view.setNeedsLayout(); presented.view.layoutIfNeeded()
        }
    }
    func close() {
        controller.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
private final class PrimaryModalGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    private(set) var scans = 0
    private(set) var restores = 0
    init() {
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        var photos: [IndexedPhoto] = []
        for index in 0..<4 {
            photos.append(IndexedPhoto(id: "TEST-modal-\(index)", modificationTime: 200,
                modelVersion: "TEST-modal", imageEmbedding: vector, creationTime: Double(index)))
        }
        groups = [SimilarPhotoGroup(id: "TEST-modal-group", photos: photos, minimumSimilarity: 1)]
    }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        restores += 1
        return .missing
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        scans += 1
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: 4, staleCount: 0,
                                           unindexedCount: 0, threshold: threshold)
    }
}

@MainActor
private final class PrimaryModalWorker: PhotoWorkServicing {
    func refresh() async throws -> LibrarySummary { LibrarySummary(indexedCount: 4, modelVersion: "TEST-modal") }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw unexpected() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> PrimaryModalFailure {
        XCTFail("AX presentations must not search, index, run OCR or clear storage")
        return .unexpectedWork
    }
}

private struct PrimaryModalNoDeletion: PhotoDeleting {
    func delete(revisions: [PhotoRevision]) async throws {
        XCTFail("AX presentation must never submit a Photos deletion")
        throw PrimaryModalFailure.unexpectedWork
    }
}

@MainActor
private final class PrimaryModalTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("AX presentation must not translate"); throw PrimaryModalFailure.unexpectedWork
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("AX presentation must not prepare language packs"); throw PrimaryModalFailure.unexpectedWork
    }
}