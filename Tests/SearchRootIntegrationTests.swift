import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Actual ContentView/UIButton/native page scopes. Fake workers have explicit
/// drain gates; no Photos access, model loading, OCR recognition or pack download.
/// Strict SwiftUI AX identifier absence is covered by the separate XCUI suite.
@MainActor
final class SearchRootIntegrationTests: XCTestCase {
    func testCurrentMenuRejectsStaleDraftBeforeNativeUpdateWithoutTakingFieldDelegateOrFocus() async throws {
        let f = try await controlsFixture(in: self)
        let worker = SearchRootTestWorker()
        let translator = SearchRootTranslator()
        let app = await makeSearchRootTestApp(in: self, worker: worker, translator: translator)
        app.query = "身份证"
        app.submitSearchQuery()
        await app.waitUntilIdle()
        let host = try mount(f, app: app)
        defer { host.window.endEditing(true); host.close() }
        try await host.wait { self.menuButton(host)?.menu != nil && host.tabs.count == 2 }
        let button = try XCTUnwrap(menuButton(host))
        let nativeMenu = try XCTUnwrap(button.menu)
        let actions = nativeMenu.children.compactMap { $0 as? UIAction }
        let axActions = try XCTUnwrap(button.accessibilityCustomActions)
        XCTAssertEqual(actions.map { $0.identifier.rawValue }, ["effective-search-query", "search-original"])
        XCTAssertEqual(axActions.map(\.name), ["显示译文", "使用原文"])
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let field = try XCTUnwrap(controlsDescendants(scroll, UITextField.self).first)
        let delegate = try XCTUnwrap(field.delegate)
        let correction = field.autocorrectionType
        XCTAssertTrue(field.becomeFirstResponder())
        try await host.wait { field.isFirstResponder }
        let searches = worker.searches
        let history = app.recentSearchQueries
        // FocusState can legitimately rebuild the menu before this edit. Hold
        // the settled current instance, not the one captured before focusing.
        let installedMenuBeforeEdit = try XCTUnwrap(button.menu)

        // No await/layout between editing and dispatch: exercise ContentView's
        // live guard while UIKit still owns the previously installed actions.
        app.query = "new unsubmitted draft"
        XCTAssertTrue(button.menu === installedMenuBeforeEdit)
        actions.forEach { UIControl().sendAction($0) }
        axActions.forEach { _ = $0.actionHandler?($0) }
        XCTAssertNil(app.activity)
        XCTAssertEqual(app.query, "new unsubmitted draft")
        XCTAssertEqual(worker.searches, searches)
        try await host.wait { button.menu == nil && field.text == app.query }
        XCTAssertNil(host.controller.presentedViewController, "Stale show-translation must not present an alert")
        XCTAssertNil(button.accessibilityCustomActions)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(field.delegate === delegate)
        XCTAssertEqual(field.autocorrectionType, correction)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertTrue(controlsDescendants(scroll, UITextField.self).first === field)
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.insertText("!")
        try await host.wait { app.query == field.text && app.query.hasSuffix("!") }
        actions.forEach { UIControl().sendAction($0) }
        for action in axActions { XCTAssertEqual(action.actionHandler?(action), false) }
        XCTAssertEqual(worker.searches, searches)
        XCTAssertEqual(app.recentSearchQueries, history)
        XCTAssertEqual(translator.translations, ["身份证"])
        XCTAssertEqual(worker.ocrCalls, 0)
    }

    func testRetainedMenuUsesCurrentResolutionAndTranslationAlertExcludesRoot() async throws {
        let f = try await controlsFixture(in: self)
        let worker = SearchRootTestWorker()
        let translator = SearchRootTranslator()
        let app = await makeSearchRootTestApp(in: self, worker: worker, translator: translator)
        app.query = "身份证"
        app.submitSearchQuery()
        await app.waitUntilIdle()
        let host = try mount(f, app: app)
        defer { host.close() }
        try await host.wait { self.menuButton(host)?.menu != nil && host.tabs.count == 2 }
        let button = try XCTUnwrap(menuButton(host))
        let retainedOriginal = try action(button, id: "search-original")
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let anchor = try XCTUnwrap(controlsDescendants(scroll, PrimarySearchScrollAnchorView.self).first)
        let nav = try XCTUnwrap(anchor.owningNavigationController)
        let field = try XCTUnwrap(controlsDescendants(scroll, UITextField.self).first)
        let delegate = try XCTUnwrap(field.delegate)
        let band = try rootFrame(host, .syncToast)
        let navigation = try rootFrame(host, .navigation)

        app.query = "海边日落"
        app.submitSearchQuery()
        await app.waitUntilIdle()
        try await host.wait { field.text == "海边日落" && button.menu != nil }
        let history = app.recentSearchQueries
        let searches = worker.searches
        UIControl().sendAction(retainedOriginal)
        await app.waitUntilIdle()
        XCTAssertEqual(app.completedSearchQuery?.original, "海边日落")
        XCTAssertEqual(app.completedSearchQuery?.effective, "海边日落")
        XCTAssertEqual(worker.searches, searches + ["海边日落"], "Use the current query, never the first captured query")
        XCTAssertEqual(app.recentSearchQueries, history)
        XCTAssertEqual(translator.translations, ["身份证", "海边日落"])
        XCTAssertTrue(app.chineseSearchEnabled)
        try await host.wait { button.menu?.children.first?.title == "使用英文翻译" }

        let retry = try action(button, id: "search-translated")
        f.navigation.select(.cleanup)
        UIControl().sendAction(retry) // Live tab guard before the next native update.
        try await host.wait { scroll.accessibilityElementsHidden && button.menu == nil }
        XCTAssertEqual(worker.searches, searches + ["海边日落"])
        XCTAssertNil(app.activity)
        f.navigation.select(.search)
        try await host.wait { !scroll.accessibilityElementsHidden && button.menu != nil }
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertTrue(controlsDescendants(scroll, UITextField.self).first === field)
        XCTAssertTrue(field.delegate === delegate)
        XCTAssertTrue(menuButton(host) === button)
        UIControl().sendAction(retry)
        await app.waitUntilIdle()
        try await host.wait { button.menu?.children.first?.title == "显示译文" }
        XCTAssertEqual(app.completedSearchQuery?.effective, "translated:海边日落")
        XCTAssertEqual(app.recentSearchQueries, history)
        let beforeModal = worker.searches
        let show = try XCTUnwrap(button.accessibilityCustomActions?.first { $0.name == "显示译文" })
        XCTAssertEqual(show.actionHandler?(show), true)
        try await host.wait { host.controller.presentedViewController is UIAlertController && host.tabs.isEmpty }
        let alert = try XCTUnwrap(host.controller.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "本次搜索的译文")
        XCTAssertEqual(alert.message, "translated:海边日落")
        XCTAssertTrue(nav.view.accessibilityElementsHidden)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(alert.view.accessibilityElementsHidden)
        XCTAssertFalse(host.window.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        XCTAssertNil(button.menu)
        UIControl().sendAction(retainedOriginal)
        XCTAssertEqual(worker.searches, beforeModal, "A menu retained under a modal cannot start a replay")
        XCTAssertNil(app.activity)
        XCTAssertEqual(try rootFrame(host, .syncToast), band)
        XCTAssertEqual(try rootFrame(host, .navigation), navigation)
        XCTAssertEqual(app.recentSearchQueries, history)
        // Do not privately invoke UIAlertAction handlers or bypass the SwiftUI
        // alert binding. The next test exercises supported modal restoration.
    }

    func testLivePhotoToOCRHandoffUsesOneRootRegionAndSurvivesModalKeyboardAndTabs() async throws {
        let f = try await controlsFixture(in: self)
        let worker = SearchRootTestWorker()
        let photo = SearchRootPhotoSync()
        let app = await makeSearchRootTestApp(in: self, worker: worker,
                                            translator: SearchRootTranslator(), sync: photo)
        addTeardownBlock { @MainActor in
            app.photoSync.cancel(); photo.gate.open()
            await app.waitForSync()
        }
        let presentation = SearchPhotoTextPresentation()
        app.query = "TEST retained OCR draft"
        let host = try mount(f, app: app, presentation: presentation)
        defer { host.close() }
        try await host.wait { host.tabs.count == 2 && self.hasRootFrame(host, .syncToast) }
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let anchor = try XCTUnwrap(controlsDescendants(scroll, PrimarySearchScrollAnchorView.self).first)
        let nav = try XCTUnwrap(anchor.owningNavigationController)
        let toggle = try XCTUnwrap(controlsDescendants(scroll, UISwitch.self).first)
        let band = try rootFrame(host, .syncToast)
        let navigation = try rootFrame(host, .navigation)
        XCTAssertEqual(band.height, 52, accuracy: host.pixel)
        XCTAssertEqual(navigation.height, 44, accuracy: host.pixel)
        try assertNoLibraryFooterGap(host, scroll: scroll, band: band)
        let idlePixels = try bandPixels(host, frame: band)
        app.photoSync.updateAvailability(ready: true, networkAllowed: false)
        try await host.wait { photo.calls == 1 && app.photoSync.phase == .updating && host.sync[.card] != nil }
        XCTAssertFalse(IndexSyncFooter(state: app).showsOCR)
        let photoPixels = try bandPixels(host, frame: band)
        XCTAssertNotEqual(photoPixels, idlePixels, "A real photo capsule is rendered before handoff")
        try host.attach(to: self, name: "UIReview-root-photo-before-ocr-handoff")

        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await host.wait { app.ocrSync.pending }
        XCTAssertEqual(app.ocrSync.phase, .waiting)
        XCTAssertEqual(app.photoSync.phase, .updating)
        XCTAssertEqual(worker.ocrCalls, 0, "OCR waits for the live photo worker to drain")
        XCTAssertFalse(IndexSyncFooter(state: app).showsOCR)
        XCTAssertEqual(try rootFrame(host, .syncToast), band)
        photo.gate.open()
        await app.waitForSync()
        try await host.wait {
            worker.ocrCalls == 1 && app.ocrSync.phase == .updating
                && host.sync[.card] == nil && self.attachedPhotoCards(host).isEmpty
        }
        XCTAssertTrue(IndexSyncFooter(state: app).showsOCR)
        XCTAssertEqual(app.activity, .indexingText)
        XCTAssertEqual(worker.ocrNetworkRequests, [false])
        XCTAssertEqual(app.ocrSync.fraction, 1.0 / 3.0)
        XCTAssertEqual(try rootFrame(host, .syncToast), band, "Do not stack a second reserved footer")
        XCTAssertEqual(try rootFrame(host, .navigation), navigation)
        XCTAssertTrue(attachedPhotoCards(host).isEmpty, "No retained photo capsule under OCR")
        let ocrPixels = try bandPixels(host, frame: band)
        XCTAssertNotEqual(ocrPixels, idlePixels, "The handoff must render OCR, not a blank reservation")
        XCTAssertNotEqual(ocrPixels, photoPixels)
        try host.attach(to: self, name: "UIReview-root-ocr-after-photo-handoff")

        f.navigation.select(.cleanup)
        try await host.wait { scroll.accessibilityElementsHidden && f.cleanup.isPageVisible }
        XCTAssertEqual(try rootFrame(host, .syncToast), band)
        XCTAssertEqual(try bandPixels(host, frame: band), ocrPixels, "Both root pages share the same capsule")
        f.navigation.select(.search)
        try await host.wait { !scroll.accessibilityElementsHidden }
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(app.query, "TEST retained OCR draft")
        presentation.showingIntroduction = true
        try await host.wait { host.controller.presentedViewController != nil && host.tabs.isEmpty }
        let modal = try XCTUnwrap(host.controller.presentedViewController)
        XCTAssertTrue(nav.view.accessibilityElementsHidden)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(modal.view.accessibilityElementsHidden)
        XCTAssertFalse(modal.view.isDescendant(of: nav.view))
        XCTAssertFalse(host.window.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        // The system sheet can reposition the presenting surface; its reserved
        // heights must survive. Require the original full frames on return.
        XCTAssertEqual(try rootFrame(host, .syncToast).height, band.height, accuracy: host.pixel)
        XCTAssertEqual(try rootFrame(host, .navigation).height, navigation.height, accuracy: host.pixel)
        XCTAssertEqual(worker.ocrCalls, 1)
        XCTAssertTrue(app.ocrSync.currentRunning)
        presentation.showingIntroduction = false
        try await host.wait { host.controller.presentedViewController == nil && host.tabs.count == 2 }
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertTrue(controlsDescendants(scroll, UISwitch.self).first === toggle)
        XCTAssertEqual(try rootFrame(host, .syncToast), band)
        XCTAssertEqual(try rootFrame(host, .navigation), navigation)
        XCTAssertEqual(try bandPixels(host, frame: band), ocrPixels)

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        try await host.settle()
        XCTAssertEqual(try rootFrame(host, .syncToast), band)
        XCTAssertEqual(try bandPixels(host, frame: band), idlePixels, "Keyboard hides the capsule, not the reservation")
        XCTAssertEqual(host.tabs.count, 2)
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        try await host.settle()
        XCTAssertEqual(try bandPixels(host, frame: band), ocrPixels)
        XCTAssertEqual(worker.ocrCalls, 1, "Modal, keyboard and tabs cannot reschedule OCR")
        worker.ocrGate.open()
        await app.waitUntilIdle()
        try await host.wait { app.ocrSync.phase == .completed }
        XCTAssertEqual(app.summary.textIndexCounts.records, 3)
        XCTAssertEqual(app.textIndexProgress, SearchRootTestWorker.finishedOCR)
        XCTAssertEqual(photo.calls, 1)
        XCTAssertEqual(photo.networkRequests, [false])
        XCTAssertFalse(app.allowICloudDownload)
        XCTAssertFalse(app.library.canReadImages)
        try assertNoLibraryFooterGap(host, scroll: scroll, band: band)
    }

    private func mount(_ f: ControlsFixture, app: AppState,
                       presentation: SearchPhotoTextPresentation? = nil) throws -> ControlsNativeHost {
        try ControlsNativeHost(content: AnyView(ContentView(state: app,
            similarCleanupState: f.cleanup, navigation: f.navigation, cleanupPreferences: nil,
            photoTextPresentation: presentation)))
    }

    private func menuButton(_ host: ControlsNativeHost) -> SearchQueryEditMenuButton? {
        controlsDescendants(host.controller.view, SearchQueryEditMenuButton.self).first
    }

    private func action(_ button: SearchQueryEditMenuButton, id: String) throws -> UIAction {
        try XCTUnwrap(button.menu?.children.compactMap { $0 as? UIAction }.first { $0.identifier.rawValue == id })
    }

    private func hasRootFrame(_ host: ControlsNativeHost, _ part: RootBottomLayoutPart) -> Bool {
        controlsDescendants(host.controller.view, RootBottomLayoutProbeView.self)
            .contains { $0.part == part && $0.window === host.window && $0.windowFrame != nil }
    }

    private func rootFrame(_ host: ControlsNativeHost, _ part: RootBottomLayoutPart) throws -> CGRect {
        let probes = controlsDescendants(host.controller.view, RootBottomLayoutProbeView.self)
            .filter { $0.part == part && $0.window === host.window }
        XCTAssertEqual(probes.count, 1, "Exactly one actual mounted root region")
        return try XCTUnwrap(probes.first?.windowFrame)
    }

    private func attachedPhotoCards(_ host: ControlsNativeHost) -> [PhotoSyncLayoutProbeView] {
        controlsDescendants(host.controller.view, PhotoSyncLayoutProbeView.self)
            .filter { $0.window === host.window && $0.part == .card }
    }

    private func assertNoLibraryFooterGap(_ host: ControlsNativeHost, scroll: UIScrollView, band: CGRect) throws {
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        XCTAssertEqual(usable.maxY, band.minY, accuracy: host.pixel, "No lower-left count footer or vacant footer row")
        XCTAssertEqual(band.maxY, try rootFrame(host, .navigation).minY, accuracy: host.pixel)
        XCTAssertFalse(hasRootFrame(host, .selectionToolbar), "No zero-selection footer in ordinary home")
    }

    private func bandPixels(_ host: ControlsNativeHost, frame: CGRect) throws -> Data {
        let image = try host.capture()
        let local = host.controller.view.convert(frame, from: host.window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        format.preferredRange = .standard
        // Redraw into a region-owned bitmap. A cropped CGImage can retain its
        // source row stride/provider, inadvertently comparing outside pixels.
        let crop = UIGraphicsImageRenderer(size: local.size, format: format).image { _ in
            image.draw(at: CGPoint(x: -local.minX, y: -local.minY))
        }
        let cg = try XCTUnwrap(crop.cgImage)
        XCTAssertEqual(cg.width, Int((local.width * image.scale).rounded()))
        XCTAssertEqual(cg.height, Int((local.height * image.scale).rounded()))
        return try XCTUnwrap(cg.dataProvider?.data) as Data
    }
}

// Shared with the owned MinimalSearchPresentationTests only. Counts stand for
// synthetic stored rows, not recognition results from any real photo library.
@MainActor
final class SearchRootTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

@MainActor
final class SearchRootTestWorker: PhotoWorkServicing {
    static let finishedOCR = TextIndexProgress(total: 3, completed: 3, recognized: 1, reused: 2, withText: 3)
    let ocrGate = SearchRootTestGate()
    var searchGate: SearchRootTestGate?
    private(set) var searches: [String] = []
    private(set) var ocrCalls = 0
    private(set) var ocrNetworkRequests: [Bool] = []
    private(set) var unexpectedCalls = 0
    private var summary = LibrarySummary(indexedCount: 37, modelVersion: "TEST-root",
        textIndexCounts: TextIndexCounts(records: 2, withText: 2), textIndexStatisticsKnown: true)

    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searches.append(text)
        if let searchGate { await searchGate.wait() }
        try Task.checkCancellation()
        let hits = (0..<37).map {
            SearchHit(photo: TestFixtures.photo(id: "TEST-root-\($0)").photo, score: Float(37 - $0) / 37)
        }
        return SearchResponse(summary: summary, hits: hits)
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        ocrCalls += 1
        ocrNetworkRequests.append(networkAllowed)
        await progress(TextIndexProgress(total: 3, completed: 1, reused: 1, withText: 1))
        await ocrGate.wait() // Cancellation must drain, not fake an immediate stop.
        try Task.checkCancellation()
        await progress(Self.finishedOCR)
        summary.textIndexCounts = TextIndexCounts(records: 3, withText: 3)
        return summary
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> ControlsPresentationFailure {
        unexpectedCalls += 1
        XCTFail("Root presentation must never index images or clear data")
        return .unexpectedWork
    }
}

@MainActor
func makeSearchRootTestApp(in test: XCTestCase, worker: SearchRootTestWorker,
                          translator: any QueryTranslating, sync: (any PhotoSyncServicing)? = nil) async -> AppState {
    let authorization = PhotoLibraryClient.authorization
    XCTAssertFalse(PhotoLibraryClient.canRead)
    let app = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator, syncService: sync)
    test.addTeardownBlock { @MainActor in
        app.enterBackground(); worker.ocrGate.open(); worker.searchGate?.open()
        await app.waitUntilIdle()
        app.thumbnails.clear()
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        XCTAssertEqual(PhotoLibraryClient.authorization, authorization)
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertFalse(app.library.canReadImages)
        XCTAssertNil(app.appleTranslationService)
        XCTAssertEqual(worker.unexpectedCalls, 0)
    }
    app.refresh()
    await app.waitUntilIdle()
    return app
}

@MainActor
private final class SearchRootTranslator: QueryTranslating {
    let isSupported = true
    private(set) var translations: [String] = []
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .installed }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translations.append(text)
        return "translated:" + text
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Root tests must not prepare language packs")
        throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class SearchRootPhotoSync: PhotoSyncServicing {
    let gate = SearchRootTestGate()
    private(set) var calls = 0
    private(set) var networkRequests: [Bool] = []
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        calls += 1
        networkRequests.append(networkAllowed)
        await progress(PhotoSyncProgress(phase: .updating, total: 4, completed: 1, encoded: 1))
        await gate.wait()
        try Task.checkCancellation()
        return PhotoSyncResult(summary: LibrarySummary(indexedCount: 37, modelVersion: "TEST-root",
            textIndexCounts: TextIndexCounts(records: 2, withText: 2), textIndexStatisticsKnown: true),
            progress: PhotoSyncProgress(phase: .updating, total: 4, completed: 4, encoded: 4))
    }
}