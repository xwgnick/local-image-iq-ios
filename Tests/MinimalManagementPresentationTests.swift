import XCTest
import SwiftUI
import UIKit
import Combine
import Photos
import ImageIQCore
@testable import LocalImageIQ

#if targetEnvironment(simulator)
/// Real native sheets and push destinations, synthetic aggregate state only.
/// Route bindings drive the production NavigationStack: these are NOT XCUI
/// taps, an accessibility-tree audit or an interactive-back gesture test.
/// Native row counts + screenshots establish primary structure; public route
/// identifiers let the parent XCUI suite cover exact control labels/activation.
/// No permission request, Photos fetch, index, model or network call is allowed.
@MainActor
final class MinimalManagementPresentationTests: XCTestCase {
    func testLibraryPrimaryHasOneSummaryAndThreePushRowsWithoutMaintenanceActions() async throws {
        let c = try await context()
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalLibraryRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("我的图库", depth: 1, test: self)
        XCTAssertEqual(try host.rowCounts(), [1, 3], "One summary row, three navigation rows; no primary maintenance buttons")
        XCTAssertEqual(LibrarySheet.Route.allCases.map(\.title), ["照片访问", "文本索引", "索引维护"])
        XCTAssertEqual(Set(LibrarySheet.Route.allCases.map(\.accessibilityIdentifier)).count, 3)
        XCTAssertEqual(LibrarySheet(state: c.state).storedCountText, "已索引 \(8_003.formatted()) 张")
        XCTAssertEqual(LibrarySheet(state: c.state).authorizedCountSnapshotText, "未扫描")
        try host.attach(to: self, name: "UIReview-minimal-library-v1")
        assertNoWork(c)
    }

    func testSettingsPrimaryHasExactlyFourRowsNoResultLimitOrInlineDebugEvenWhenEnabled() async throws {
        let c = try await context()
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalSettingsRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("设置", depth: 1, test: self)
        XCTAssertEqual(try host.rowCounts(), [4], "Three native pushes plus the iCloud opt-in, no page-size row")
        XCTAssertEqual(SettingsSheet.Route.allCases.map(\.title), ["搜索增强", "隐私与关于", "高级"])
        XCTAssertFalse(c.state.allowICloudDownload)
        XCTAssertTrue(c.state.chineseSearchEnabled)
        XCTAssertEqual(c.state.resultLimit, 12)
        XCTAssertEqual(c.state.translationAvailability, .unchecked)
        try host.attach(to: self, name: "UIReview-minimal-settings-v1")
        c.state.debugToolsEnabled = true
        await host.settle(test: self)
        XCTAssertEqual(try host.rowCounts(), [4], "Debug content belongs only to the secondary page")
        c.state.debugToolsEnabled = false
        await host.settle(test: self)
        XCTAssertEqual(try host.rowCounts(), [4])
        assertNoWork(c)
    }

    func testEveryLibrarySecondaryPushesAndReturnsWithoutIndexingOrPermissionChanges() async throws {
        let c = try await context(authorization: .limited)
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalLibraryRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("我的图库", depth: 1, test: self)
        let navigation = try host.navigation()
        for route in LibrarySheet.Route.allCases {
            paths.library = [route]
            try await host.waitForPage(route.title, depth: 2, test: self)
            XCTAssertTrue(try host.navigation() === navigation, "Destinations must push, not create nested stacks/sheets")
            XCTAssertNil(host.controller.presentedViewController)
            XCTAssertGreaterThan(try host.rowCounts().reduce(0, +), 0)
            if route == .access {
                XCTAssertEqual(try host.rowCounts(), [3], "Access explanation, limited picker, system Settings")
            }
            XCTAssertFalse(c.state.textSearchEnabled, "Text management must not opt into OCR on entry")
            assertNoWork(c)
            paths.library = []
            try await host.waitForPage("我的图库", depth: 1, test: self)
            XCTAssertEqual(try host.rowCounts(), [1, 3])
        }
        XCTAssertEqual(c.state.authorization, .limited, "Only the injected status is limited")
        XCTAssertFalse(PhotoLibraryClient.canRead)
        assertNoWork(c)
    }

    func testSettingsSecondaryReachabilityAndOnlyExplicitTranslationPageChecksPacks() async throws {
        let c = try await context()
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalSettingsRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("设置", depth: 1, test: self)
        let navigation = try host.navigation()

        paths.settings = [.advanced]
        try await host.waitForPage("高级", depth: 2, test: self)
        XCTAssertEqual(try host.rowCounts(), [1], "Only the session opt-in is visible while debugging is off")
        c.state.debugToolsEnabled = true
        await host.settle(test: self)
        XCTAssertEqual(try host.rowCounts(), [1, 1, 1], "Opt-in plus collapsed search and diagnostic groups")
        c.state.debugToolsEnabled = false
        await host.settle(test: self)
        XCTAssertEqual(try host.rowCounts(), [1])
        paths.settings = []
        try await host.waitForPage("设置", depth: 1, test: self)

        paths.settings = [.privacy]
        try await host.waitForPage("隐私与关于", depth: 2, test: self)
        XCTAssertEqual(try host.rowCounts().first, 1, "Only clear-history, not saved query strings")
        assertNoWork(c)
        paths.settings = []
        try await host.waitForPage("设置", depth: 1, test: self)

        let checked = expectation(description: "Explicit secondary entry checks a fake pack")
        c.translator.checked = checked
        paths.settings = [.translation]
        try await host.waitForPage("搜索增强", depth: 2, test: self)
        await fulfillment(of: [checked], timeout: 5)
        await host.settle(test: self)
        XCTAssertEqual(try host.rowCounts(), [4])
        XCTAssertTrue(try host.navigation() === navigation)
        XCTAssertEqual(c.state.translationAvailability, .downloadRequired)
        XCTAssertEqual(c.translator.availabilityCalls, [.simplified])
        paths.settings = []
        try await host.waitForPage("设置", depth: 1, test: self)
        assertNoWork(c, availability: [.simplified])
    }

    func testLibraryStatusObservesAutomaticSubstateWithoutAppStatePublicationOrImplicitRestart() async throws {
        let c = try await context(authorization: .authorized)
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalLibraryRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("我的图库", depth: 1, test: self)
        let initial = try host.render().pngData()
        var parentPublications = 0
        let subscription = c.state.objectWillChange.sink { parentPublications += 1 }
        defer { subscription.cancel() }
        let entered = expectation(description: "Explicitly started synthetic sync")
        c.sync.entered = entered
        c.state.photoSync.updateAvailability(ready: true, networkAllowed: false)
        await fulfillment(of: [entered], timeout: 5)
        await c.sync.report(.init(phase: .updating, total: 8, completed: 2, encoded: 2))
        await host.settle(test: self)
        XCTAssertEqual(LibraryAutoSyncStatusView(state: c.state.photoSync, canRead: true, modelsReady: true).title,
                       "同步最新照片 2/8")
        XCTAssertNotEqual(try host.render().pngData(), initial, "The mounted production summary must redraw")
        XCTAssertEqual(parentPublications, 0, "Automatic progress must not depend on AppState forwarding it")
        XCTAssertEqual(c.sync.calls, 1)

        c.state.photoSync.cancel()
        XCTAssertEqual(c.state.photoSync.phase, .cancelling)
        c.sync.release()
        await c.state.photoSync.waitUntilIdle()
        XCTAssertEqual(c.state.photoSync.phase, .cancelled)
        paths.library = [.maintenance]
        try await host.waitForPage("索引维护", depth: 2, test: self)
        paths.library = []
        try await host.waitForPage("我的图库", depth: 1, test: self)
        XCTAssertEqual(c.sync.calls, 1, "Navigation must not resume a cancelled automatic job")
        assertNoWork(c, syncCalls: 1)
    }

    func testUnknownCountAndModelIssueKeepPrimaryMinimalWithRecoveryReachable() async throws {
        let c = try await context(known: false, modelIssue: "Models unavailable: TEST_ONLY")
        XCTAssertEqual(LibrarySheet(state: c.state).storedCountText, "索引统计待刷新")
        XCTAssertFalse(c.state.modelsReady)
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalLibraryRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("我的图库", depth: 1, test: self)
        XCTAssertEqual(try host.rowCounts(), [1, 3])
        paths.library = [.maintenance]
        try await host.waitForPage("索引维护", depth: 2, test: self)
        XCTAssertFalse(c.state.canIndex)
        XCTAssertGreaterThan(try host.rowCounts().reduce(0, +), 3)
        assertNoWork(c)
    }

    func testPrivacyClearUsesHistoryOnlyAndLeavingPreparationCancelsOnlyExplicitPrep() async throws {
        let c = try await context()
        c.state.query = "TEST draft retained"
        XCTAssertEqual(c.state.recentSearchQueries.count, 2)
        let paths = MinimalManagementPaths()
        let host = try MinimalManagementHost(MinimalSettingsRoot(state: c.state, paths: paths))
        defer { host.close() }
        try await host.waitForPage("设置", depth: 1, test: self)
        paths.settings = [.privacy]
        try await host.waitForPage("隐私与关于", depth: 2, test: self)
        // Exact confirmed state action, not a pretend tap on the dialog.
        c.state.clearSearchHistory()
        XCTAssertTrue(c.state.recentSearchQueries.isEmpty)
        XCTAssertEqual(c.history.saves, [[]])
        XCTAssertEqual(c.state.query, "TEST draft retained")
        assertNoWork(c)
        paths.settings = []
        try await host.waitForPage("设置", depth: 1, test: self)

        let checked = expectation(description: "Secondary availability")
        c.translator.checked = checked
        paths.settings = [.translation]
        try await host.waitForPage("搜索增强", depth: 2, test: self)
        await fulfillment(of: [checked], timeout: 5)
        let preparing = expectation(description: "Explicit fake preparation")
        c.translator.preparing = preparing
        c.state.prepareTranslation()
        await fulfillment(of: [preparing], timeout: 5)
        XCTAssertEqual(c.state.activity, .preparingTranslation)
        paths.settings = []
        try await host.waitForPage("设置", depth: 1, test: self)
        c.translator.release()
        await c.state.waitUntilIdle()
        XCTAssertNil(c.state.activity)
        XCTAssertTrue(c.translator.preparationWasCancelled)
        XCTAssertEqual(c.translator.preparationCalls, [.simplified])
        XCTAssertEqual(c.worker.calls, ["refresh"])
        XCTAssertEqual(c.sync.calls, 0)
        XCTAssertEqual(c.state.query, "TEST draft retained")
        XCTAssertEqual(c.state.resultLimit, 12)
    }

    private func context(authorization: PHAuthorizationStatus = .notDetermined,
                         known: Bool = true, modelIssue: String? = nil) async throws -> MinimalManagementContext {
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable simulator Photos library; this suite never changes permissions")
            throw MinimalManagementFailure.unexpected
        }
        let c = MinimalManagementContext(authorization: authorization, known: known, modelIssue: modelIssue)
        addTeardownBlock { @MainActor in
            c.state.cancel()
            c.state.photoSync.cancel()
            c.sync.release()
            c.translator.release()
            await c.state.waitUntilIdle()
            await c.state.photoSync.waitUntilIdle()
        }
        c.state.refresh() // Synthetic stored summary only, once before mounting.
        await c.state.waitUntilIdle()
        XCTAssertNil(c.state.appleTranslationService)
        XCTAssertEqual(c.worker.calls, ["refresh"])
        return c
    }

    private func assertNoWork(_ c: MinimalManagementContext,
                              availability: [QueryTranslationLanguage] = [], syncCalls: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.worker.calls, ["refresh"], file: file, line: line)
        XCTAssertEqual(c.translator.availabilityCalls, availability, file: file, line: line)
        XCTAssertTrue(c.translator.preparationCalls.isEmpty, file: file, line: line)
        XCTAssertEqual(c.translator.translationCalls, 0, file: file, line: line)
        XCTAssertEqual(c.sync.calls, syncCalls, file: file, line: line)
        XCTAssertEqual(c.state.resultLimit, 12, file: file, line: line)
        XCTAssertFalse(c.state.allowICloudDownload, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
    }
}

@MainActor
private final class MinimalManagementPaths: ObservableObject {
    @Published var library: [LibrarySheet.Route] = []
    @Published var settings: [SettingsSheet.Route] = []
}

@MainActor
private struct MinimalLibraryRoot: View {
    let state: AppState
    @ObservedObject var paths: MinimalManagementPaths
    var body: some View { LibrarySheet(state: state, path: $paths.library) }
}

@MainActor
private struct MinimalSettingsRoot: View {
    let state: AppState
    @ObservedObject var paths: MinimalManagementPaths
    var body: some View { SettingsSheet(state: state, path: $paths.settings) }
}

/// One host per test, never replaced to simulate navigation or cancel work.
@MainActor
private final class MinimalManagementHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private let previousKeyWindow: UIWindow?
    private let size = CGSize(width: 393, height: 852)

    init<Content: View>(_ content: Content) throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let root = content.preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        controller = UIHostingController(rootView: AnyView(root))
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    private func controllers(_ root: UIViewController) -> [UIViewController] {
        [root] + root.children.flatMap { controllers($0) }
    }

    func navigation() throws -> UINavigationController {
        try XCTUnwrap(controllers(controller).compactMap { $0 as? UINavigationController }.first)
    }

    func waitForPage(_ title: String, depth: Int, test: XCTestCase) async throws {
        let inspect: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            self.window.layoutIfNeeded()
            self.controller.view.layoutIfNeeded()
            // Probing an unmounted hierarchy must not call XCTUnwrap: absence
            // before the milestone is expected, not an assertion failure.
            guard let nav = self.controllers(self.controller)
                .compactMap({ $0 as? UINavigationController }).first else { return false }
            return nav.viewControllers.count == depth && nav.navigationBar.topItem?.title == title
                && nav.topViewController?.view.window === self.window
        }
        // Match the existing native-host helper's actor-safe predicate bridge.
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let reached = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard await XCTWaiter.fulfillment(of: [reached], timeout: 5) == .completed else {
            XCTFail("Native management push/pop did not reach its title and stack depth")
            throw MinimalManagementFailure.unexpected
        }
        await settle(test: test)
        let nav = try navigation()
        XCTAssertEqual(nav.viewControllers.count, depth)
        XCTAssertEqual(nav.navigationBar.topItem?.title, title)
        XCTAssertTrue(nav.topViewController?.view.window === window)
    }

    func settle(test: XCTestCase) async {
        let settled = XCTestExpectation(description: "Native management layout")
        DispatchQueue.main.async {
            self.controller.view.setNeedsLayout()
            self.controller.view.layoutIfNeeded()
            DispatchQueue.main.async {
                self.controller.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await test.fulfillment(of: [settled], timeout: 5)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    func rowCounts() throws -> [Int] {
        let top = try XCTUnwrap(try navigation().topViewController)
        let collection = try XCTUnwrap(descendants(top.view).compactMap { $0 as? UICollectionView }.first)
        return (0..<collection.numberOfSections).map { collection.numberOfItems(inSection: $0) }
    }

    func render() throws -> UIImage {
        XCTAssertTrue(controller.view.window === window)
        XCTAssertEqual(controller.view.bounds.size, size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawn = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int((size.width * format.scale).rounded()))
        XCTAssertEqual(pixels.height, Int((size.height * format.scale).rounded()))
        return image
    }

    func attach(to test: XCTestCase, name: String) throws {
        let attachment = XCTAttachment(image: try render())
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

private enum MinimalManagementFailure: Error { case unexpected }

@MainActor
private final class MinimalManagementWorker: PhotoWorkServicing {
    let summary: LibrarySummary
    var calls: [String] = []
    init(known: Bool, modelIssue: String?) {
        summary = LibrarySummary(indexStatisticsKnown: known, indexedCount: 8_003,
            modelVersion: "TEST-only-no-model", modelIssue: modelIssue,
            placesDescription: "TEST-only-no-places")
    }
    func refresh() async throws -> LibrarySummary { calls.append("refresh"); return summary }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        calls.append("index"); XCTFail("Navigation must not index"); throw MinimalManagementFailure.unexpected
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        calls.append("text"); XCTFail("Navigation must not recognize text"); throw MinimalManagementFailure.unexpected
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        calls.append("search"); XCTFail("Management must not search"); throw MinimalManagementFailure.unexpected
    }
    func clear() async throws -> LibrarySummary {
        calls.append("clear"); XCTFail("Navigation/history clearing must not clear indexes"); throw MinimalManagementFailure.unexpected
    }
}

@MainActor
private final class MinimalManagementTranslator: QueryTranslating {
    let isSupported = true
    var availabilityCalls: [QueryTranslationLanguage] = []
    var preparationCalls: [QueryTranslationLanguage] = []
    var translationCalls = 0
    var checked: XCTestExpectation?
    var preparing: XCTestExpectation?
    var preparationWasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityCalls.append(language)
        checked?.fulfill(); checked = nil
        return .downloadRequired
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationCalls += 1
        XCTFail("Management must not translate a query")
        throw MinimalManagementFailure.unexpected
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        preparationCalls.append(language)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            preparing?.fulfill(); preparing = nil
        }
        preparationWasCancelled = Task.isCancelled
        try Task.checkCancellation()
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class MinimalManagementSync: PhotoSyncServicing {
    var calls = 0
    var entered: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var receiver: (@Sendable (PhotoSyncProgress) async -> Void)?
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        calls += 1
        XCTAssertFalse(networkAllowed)
        receiver = progress
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.fulfill(); entered = nil
        }
        try Task.checkCancellation()
        throw MinimalManagementFailure.unexpected
    }
    func report(_ progress: PhotoSyncProgress) async { await receiver?(progress) }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class MinimalManagementHistory: QueryHistoryStoring {
    var saves: [[String]] = []
    func load() throws -> [String] { ["TEST synthetic history one", "TEST synthetic history two"] }
    func save(_ queries: [String]) throws { saves.append(queries) }
}

@MainActor
private final class MinimalManagementContext {
    let worker: MinimalManagementWorker
    let translator = MinimalManagementTranslator()
    let sync = MinimalManagementSync()
    let history = MinimalManagementHistory()
    let state: AppState
    init(authorization: PHAuthorizationStatus, known: Bool, modelIssue: String?) {
        worker = MinimalManagementWorker(known: known, modelIssue: modelIssue)
        state = AppState(worker: worker, authorizationStatus: { authorization }, queryTranslator: translator,
                         syncService: sync, queryHistoryStore: history)
    }
}
#endif