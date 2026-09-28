import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

#if targetEnvironment(simulator)
/// Seven hosted-view tests; exactly four single-viewport native review attachments.
/// Not XCUI taps, pixel baselines or evidence of device/Photos behavior. The
/// separate app UI tests exercise the Settings switch through actual user input.
/// All views below are production views, without copied controls or observed
/// wrapper views. Accessibility is read from UIKit containers, including virtual
/// SwiftUI elements, not Mirror, source strings or UIView identifiers alone.
/// Missing native accessibility anchors FAIL the tests, never count as hidden.
///
/// Every state injects .notDetermined. Library intentionally shows its connect
/// state, not fabricated authorized coverage. No authorize/index/search action or
/// asset ID is supplied. Empty viewer IDs short-circuit load/recheckAccess before
/// any currentRevision/displayImage request. AppState still constructs its normal
/// Photos wrapper/default manager and reads authorization; this is not zero
/// PhotoKit API use. Refresh is allowed only in an unreadable simulator library,
/// so the concrete observer cannot register. Settings uses only the fake pack API.
@MainActor
final class DebugToolsPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let settingsDebug: Set<String> = ["debug-advanced", "location-weight", "debug-diagnostics"]
    private let libraryDebug: Set<String> = ["debug-library-details", "debug-indexing-info", "debug-scan-places"]
    private let viewerDebug: Set<String> = ["check-photo-preview", "compare-local-previews"]
    private let settingsControls: Set<String> = [
        "close-settings", "result-limit", "chinese-search-enabled", "translation-language",
        "translation-availability", "prepare-translation", "refresh-library", "clear-index", "show-debug-tools"
    ]
    private let libraryControls: Set<String> = [
        "close-library", "authorize-photos", "index-photos", "icloud-download-opt-in"
    ]

    // MARK: Exactly four captures, with no overlays, axes or stitched scrolls

    func testSettingsDefaultSnapshot() async throws {
        let c = try await context()
        try await withHost(SettingsSheet(state: c.state)) { view in
            let identifiers = try await self.formIdentifiers(in: view)
            self.assertIdentifiers(identifiers, containing: self.settingsControls, excluding: self.settingsDebug)
            XCTAssertEqual(c.state.translationAvailability, .installed)
            XCTAssertEqual(c.translator.availabilityCalls, [.simplified])
            // Scroll the actual Form to its last row. One viewport only; the
            // language/result controls above the fold were checked, not stitched.
            let collection = try self.form(in: view)
            let last = try XCTUnwrap(self.formRows(collection).last, "Settings must expose a switch row")
            collection.scrollToItem(at: last, at: .bottom, animated: false)
            await self.settle(view)
            try self.assertDebugSwitch(in: view, enabled: false, requireVisible: true)
            // The full Form sweep above verifies maintenance remains reachable;
            // unrelated sections need not fit in the switch's single viewport.
            try self.capture(view, named: "settings-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testLibraryDefaultSnapshot() async throws {
        let c = try await context()
        try await withHost(LibrarySheet(state: c.state)) { view in
            let identifiers = try await self.formIdentifiers(in: view)
            self.assertIdentifiers(identifiers, containing: self.libraryControls, excluding: self.libraryDebug)
            let collection = try self.form(in: view)
            collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
            await self.settle(view)
            _ = try self.element("authorize-photos", in: view)
            try self.assertDisabledButton("index-photos", in: view)
            try self.capture(view, named: "library-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testEmptyViewerDefaultSnapshot() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            try self.assertViewer(in: view, debug: false)
            try self.capture(view, named: "viewer-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testEmptyViewerDebugSnapshotAfterObservedTransition() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            try self.assertViewer(in: view, debug: false)
            c.state.debugToolsEnabled = true
            await self.settle(view)
            // Same empty viewer, changed AFTER mounting. Both real debug
            // buttons must appear disabled, not an independently rendered mock.
            try self.assertViewer(in: view, debug: true)
            try self.capture(view, named: "viewer-debug")
            c.state.debugToolsEnabled = false
            await self.settle(view)
            try self.assertViewer(in: view, debug: false)
        }
        assertUnchanged(c, since: c.baseline)
    }

    // MARK: No-capture OFF -> ON -> OFF checks; never replace rootView/host/state

    func testSettingsNativeIdentifiersFollowSameHostOnOff() async throws {
        let c = try await context()
        try await withHost(SettingsSheet(state: c.state)) { view in
            for enabled in [false, true, false] {
                c.state.debugToolsEnabled = enabled
                await self.settle(view)
                let identifiers = try await self.formIdentifiers(in: view)
                self.assertIdentifiers(identifiers, containing: self.settingsControls,
                                       excluding: enabled ? [] : self.settingsDebug)
                if enabled {
                    XCTAssertTrue(identifiers.contains("debug-advanced"))
                    XCTAssertTrue(identifiers.contains("debug-diagnostics"))
                }
                // The Form sweep ends on the real switch, not a remembered node.
                try self.assertDebugSwitch(in: view, enabled: enabled, requireVisible: true)
                self.assertUnchanged(c, since: c.baseline)
            }
            XCTAssertEqual(c.translator.availabilityCalls, [.simplified],
                           "Debug changes must not restart the language-pack task")
            XCTAssertEqual(c.state.translationAvailability, .installed)
        }
    }

    func testLibraryNativeIdentifiersFollowSameHostOnOff() async throws {
        let c = try await context()
        try await withHost(LibrarySheet(state: c.state)) { view in
            for enabled in [false, true, false] {
                c.state.debugToolsEnabled = enabled
                await self.settle(view)
                let identifiers = try await self.formIdentifiers(in: view)
                self.assertIdentifiers(identifiers, containing: self.libraryControls,
                                       excluding: enabled ? [] : self.libraryDebug)
                XCTAssertEqual(identifiers.contains("debug-library-details"), enabled)
                // No authorized scan was started: do not claim that this proves
                // the expanded scan-place counters or indexing-info contents.
                XCTAssertFalse(identifiers.contains("debug-scan-places"))
                self.assertUnchanged(c, since: c.baseline)
            }
            XCTAssertTrue(c.translator.availabilityCalls.isEmpty)
        }
    }

    func testViewerNativeIdentifiersFollowCombineWithoutReconstruction() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            for enabled in [false, true, false] {
                c.state.debugToolsEnabled = enabled
                await self.settle(view)
                try self.assertViewer(in: view, debug: enabled)
                self.assertUnchanged(c, since: c.baseline)
            }
            XCTAssertTrue(c.translator.availabilityCalls.isEmpty)
        }
    }

    // MARK: Fake services and state invariants

    private func context() async throws -> DebugPresentationContext {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native Form review requires iOS 18+ Simulator") }
        guard !PhotoLibraryClient.canRead else {
            throw XCTSkip("Use a simulator without Photos read access; no permission changes are made")
        }
        let c = DebugPresentationContext()
        XCTAssertFalse(c.state.debugToolsEnabled, "Every new state must start in user mode")
        XCTAssertEqual(c.state.authorization, .notDetermined)
        XCTAssertNil(c.state.appleTranslationService, "Never mount Apple's translation host")
        c.state.refresh() // Fake summary only; no authorized Photos observer.
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.calls, ["refresh"])
        XCTAssertTrue(c.state.modelsReady)
        XCTAssertFalse(c.state.canRead)
        XCTAssertTrue(c.state.chineseSearchEnabled)
        XCTAssertEqual(c.state.resultLimit, 3)
        XCTAssertEqual(c.state.locationWeight, 0.6)
        XCTAssertFalse(c.state.allowICloudDownload)
        c.baseline = DebugPresentationSnapshot(c.state)
        addTeardownBlock { @MainActor in
            c.state.cancel()
            await c.state.waitUntilIdle()
        }
        return c
    }

    private func viewer(_ c: DebugPresentationContext) -> PhotoGalleryViewer {
        PhotoGalleryViewer(ids: [], initialID: "", library: c.state.library,
                           networkAllowed: false, state: c.state)
    }

    private func assertUnchanged(_ c: DebugPresentationContext, since before: DebugPresentationSnapshot,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(DebugPresentationSnapshot(c.state), before, file: file, line: line)
        XCTAssertEqual(c.worker.calls, ["refresh"], "No checks, indexing, searches, clears or extra refreshes", file: file, line: line)
        XCTAssertTrue(c.translator.translationCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(c.translator.prepareCalls.isEmpty, file: file, line: line)
        XCTAssertNil(c.state.appleTranslationService, file: file, line: line)
        XCTAssertNil(c.state.photoCheckReport, file: file, line: line)
        XCTAssertNil(c.state.photoCheckIssue, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
        XCTAssertNil(c.state.activity, file: file, line: line)
    }

    // MARK: Read the public, live native accessibility containers

    private func nativeElements(in root: UIView) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        var elements: [NSObject] = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted,
                  !object.accessibilityElementsHidden else { return }
            if let view = object as? UIView, view.isHidden || view.alpha == 0 { return }
            if object.isAccessibilityElement {
                elements.append(object)
                return // Combined/ignored children are not independent AX elements.
            }
            // SwiftUI often exposes UIAccessibilityElements rather than UIViews.
            // Prefer the explicit AX children over their backing UIViews, so a
            // virtual switch and its implementation are not counted twice.
            // Identity dedup also prevents cycles in custom containers.
            if let children = object.accessibilityElements, !children.isEmpty {
                for child in children {
                    if let child = child as? NSObject { visit(child) }
                }
                return
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                }
                return
            }
            if let view = object as? UIView { view.subviews.forEach { visit($0) } }
        }
        visit(root)
        return elements
    }

    private func identifier(_ element: NSObject) -> String? {
        (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

    private func element(_ id: String, in view: UIView) throws -> NSObject {
        let matches = nativeElements(in: view).filter { identifier($0) == id }
        XCTAssertEqual(matches.count, 1, "Expected one live native accessibility element for \(id)")
        return try XCTUnwrap(matches.first, "Host did not expose \(id); an empty tree is not proof of hiding")
    }

    private func isVisible(_ element: NSObject, in view: UIView) -> Bool {
        let viewport = UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
        let frame = element.accessibilityFrame
        return !frame.isEmpty && !frame.isNull && viewport.insetBy(dx: -1, dy: -1).contains(frame)
    }

    private func assertDisabledButton(_ id: String, in view: UIView) throws {
        let button = try element(id, in: view)
        XCTAssertTrue(button.accessibilityTraits.contains(.button), "\(id) must be a native accessible button")
        XCTAssertTrue(button.accessibilityTraits.contains(.notEnabled), "\(id) must expose its actual disabled state")
    }

    private func assertDebugSwitch(in view: UIView, enabled: Bool, requireVisible: Bool) throws {
        let toggle = try element("show-debug-tools", in: view)
        XCTAssertEqual(toggle.accessibilityLabel, "Show debug tools")
        if let control = toggle as? UISwitch {
            XCTAssertEqual(control.isOn, enabled)
        } else {
            XCTAssertTrue((enabled ? ["1", "On"] : ["0", "Off"]).contains(toggle.accessibilityValue ?? ""),
                          "The native SwiftUI switch must expose its current value")
        }
        if requireVisible { XCTAssertTrue(isVisible(toggle, in: view)) }
    }

    private func assertViewer(in view: UIView, debug: Bool) throws {
        let identifiers = Set(nativeElements(in: view).compactMap { identifier($0) })
        assertIdentifiers(identifiers,
                          containing: ["close-photo-preview", "photo-preview-counter", "share-photo-preview"],
                          excluding: debug ? [] : viewerDebug)
        XCTAssertFalse(identifiers.contains("photo-preview-image"))
        XCTAssertFalse(identifiers.contains("retry-photo-preview"), "Empty IDs are not a failed Photos request")
        XCTAssertTrue(nativeElements(in: view).contains {
            ($0.accessibilityLabel ?? "").contains("No photos to preview")
        }, "The real ContentUnavailableView must expose its empty-state text")
        try assertDisabledButton("share-photo-preview", in: view)
        XCTAssertTrue(isVisible(try element("share-photo-preview", in: view), in: view))
        if debug {
            for id in viewerDebug {
                try assertDisabledButton(id, in: view)
                XCTAssertTrue(isVisible(try element(id, in: view), in: view))
            }
        }
    }

    private func assertIdentifiers(_ actual: Set<String>, containing required: Set<String>, excluding hidden: Set<String>) {
        XCTAssertTrue(required.isSubset(of: actual), "Missing native anchors: \(required.subtracting(actual).sorted())")
        XCTAssertTrue(actual.isDisjoint(with: hidden), "Unexpected debug elements: \(actual.intersection(hidden).sorted())")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func form(in view: UIView) throws -> UICollectionView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? UICollectionView }.first,
                      "Expected the production iOS 18 Form collection, not a replacement settings UI")
    }

    private func formRows(_ collection: UICollectionView) -> [IndexPath] {
        (0..<collection.numberOfSections).flatMap { section in
            (0..<collection.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
        }
    }

    /// Inspect every actual collapsed Form row so offscreen laziness cannot be
    /// mistaken for absence. No accessibility IDs are manufactured by this sweep.
    private func formIdentifiers(in view: UIView) async throws -> Set<String> {
        let collection = try form(in: view)
        let rows = formRows(collection)
        XCTAssertFalse(rows.isEmpty, "A Form without native rows cannot prove debug visibility")
        var identifiers = Set(nativeElements(in: view).compactMap { identifier($0) })
        for path in rows {
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            await settle(view)
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(path), "Inspect the actual row, not a stale cache")
            identifiers.formUnion(nativeElements(in: view).compactMap { identifier($0) })
        }
        return identifiers
    }

    // MARK: One immutable native host per test body

    private func settle(_ view: UIView) async {
        let settled = expectation(description: "SwiftUI publication and native layout settled")
        DispatchQueue.main.async {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
    }

    private func withHost<Content: View>(_ content: Content,
                                        body: @MainActor (UIView) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "An iOS app test host is required")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: phone)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        // No @ObservedObject wrapper: viewer must use its own Combine subscription.
        let root = content.preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.scenePhase, .active)
        let host = DebugPresentationHostingController(rootView: root)
        let laidOut = expectation(description: "Native phone viewport mounted")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == self.phone else { return }
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
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)
        let mountedView = host.view!
        await settle(mountedView)
        try await body(mountedView)
        XCTAssertTrue(window.rootViewController === host)
        XCTAssertTrue(host.view === mountedView, "ON/OFF must update the existing native hierarchy")
        XCTAssertTrue(mountedView.window === window)
    }

    private func capture(_ view: UIView, named name: String) throws {
        XCTAssertEqual(view.bounds.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: phone, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: phone))
            drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: phone), afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Capture the actual UIKit-hosted production hierarchy")
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 393)
        XCTAssertEqual(pixels.height, 852)
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-user-mode-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Human comparison of these four native frames is still required. Size
        // and accessibility assertions do not certify visual quality or clipping.
    }
}

@MainActor
private final class DebugPresentationHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private struct DebugPresentationSnapshot: Equatable {
    let authorization: PHAuthorizationStatus
    let counts: [Int]
    let summaryText: [String?]
    let progress: IndexProgress
    let query: String
    let completedQuery: String?
    let resolution: SearchQueryResolution?
    let resultIDs: [String]
    let scores: [Float]
    let selection: String?
    let limit: Int
    let weight: Double
    let cloud: Bool
    let chinese: Bool
    let language: QueryTranslationLanguage

    @MainActor init(_ state: AppState) {
        authorization = state.authorization
        counts = [state.summary.authorizedCount, state.summary.indexedCount, state.summary.locatedCount]
        summaryText = [state.summary.modelVersion, state.summary.modelIssue, state.summary.placesDescription]
        progress = state.progress
        query = state.query
        completedQuery = state.completedQuery
        resolution = state.completedSearchQuery
        resultIDs = state.results.map(\.id)
        scores = state.results.map(\.score)
        selection = state.selection?.id
        limit = state.resultLimit
        weight = state.locationWeight
        cloud = state.allowICloudDownload
        chinese = state.chineseSearchEnabled
        language = state.translationLanguage
    }
}

@MainActor
private final class DebugPresentationContext {
    let worker = DebugPresentationWorker()
    let translator = DebugPresentationTranslator()
    let state: AppState
    var baseline: DebugPresentationSnapshot

    init() {
        let state = AppState(worker: worker, authorizationStatus: { .notDetermined },
                             queryTranslator: translator, translationPreferences: nil)
        self.state = state
        baseline = DebugPresentationSnapshot(state)
    }
}

private enum DebugPresentationFailure: Error { case unexpectedWork }

@MainActor
private final class DebugPresentationWorker: PhotoWorkServicing {
    private(set) var calls: [String] = []
    func refresh() async throws -> LibrarySummary {
        calls.append("refresh")
        return LibrarySummary(modelVersion: "TEST-user-mode-no-model",
                              placesDescription: "TEST FIXTURE: no photo or place data")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        calls.append("index")
        XCTFail("Rendering or toggling must not index")
        throw DebugPresentationFailure.unexpectedWork
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        calls.append("search")
        XCTFail("Rendering or toggling must not search")
        throw DebugPresentationFailure.unexpectedWork
    }
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        calls.append("check")
        XCTFail("An empty viewer must not request a photo check")
        throw DebugPresentationFailure.unexpectedWork
    }
    func clear() async throws -> LibrarySummary {
        calls.append("clear")
        XCTFail("Rendering or toggling must not clear the index")
        throw DebugPresentationFailure.unexpectedWork
    }
}

@MainActor
private final class DebugPresentationTranslator: QueryTranslating {
    let isSupported = true
    private(set) var availabilityCalls: [QueryTranslationLanguage] = []
    private(set) var translationCalls: [String] = []
    private(set) var prepareCalls: [QueryTranslationLanguage] = []
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityCalls.append(language)
        return .installed
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationCalls.append(text)
        XCTFail("Presentation must not request translation; Chinese routing has separate state tests")
        throw DebugPresentationFailure.unexpectedWork
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareCalls.append(language)
        XCTFail("Presentation must not prepare/download a language pack")
        throw DebugPresentationFailure.unexpectedWork
    }
}
#endif