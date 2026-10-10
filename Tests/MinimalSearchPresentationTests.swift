import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Real native ContentView at 393/320 points, not an HTML reconstruction.
/// Synthetic AppState authorization only; the existing controls fixture requires
/// the real Photos client to remain unreadable. No models, real image/OCR indexing,
/// permission requests, Apple translation, network, or real photo mutations.
/// The explicit OCR-switch case uses a held, counting synthetic worker only.
/// Snapshots are review attachments, not a claim of physical-phone acceptance.
@MainActor
final class MinimalSearchPresentationTests: XCTestCase {
    func testHome393And320NativeSnapshotsOverviewAndCriticalGeometry() async throws {
        // Parent integration supplies the approved hero revision; do not pin
        // older artwork bytes while V5 is being copied. A missing resource
        // fails rather than silently capturing a generic icon or blank hero.
        let asset = try XCTUnwrap(UIImage(named: "HomeSearchHero", in: Bundle(for: AppState.self), compatibleWith: nil))
        XCTAssertGreaterThan(try XCTUnwrap(asset.cgImage).width, 0)
        var images: [UIImage] = []
        for width in [CGFloat(393), CGFloat(320)] {
            let f = try await controlsFixture(in: self)
            let measured = MinimalMeasurements()
            let host = try mount(f, width: width, measured: measured)
            defer { host.close() }
            try await waitForHome(host, measured)
            // Capture before assertions so layout failures retain useful evidence.
            images.append(try host.capture())
            try host.attach(to: self, name: "UIReview-minimal-search-home-\(Int(width))")
            attachGeometry(host, measured, name: "Geometry-minimal-search-home-\(Int(width))")
            try assertHome(host, measured, width: width)
            XCTAssertEqual(f.app.searchSuggestions.map(\.label), ["身份证", "猫猫追逐逗猫棒", "海边日落"])
            XCTAssertEqual(f.app.searchSuggestions[1].query, "猫猫追逐逗猫棒")
            // Only the lower-left library-status footer is removed. The top
            // subtitle deliberately retains its honest indexed-count message.
            XCTAssertEqual(ContentView(state: f.app).homeSubtitle, "已索引 37 张照片")
            // Compare allocated default label widths with native caption metrics.
            let traits = UITraitCollection(preferredContentSizeCategory: .large)
            let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
            for (index, suggestion) in f.app.searchSuggestions.enumerated() {
                let frame = try XCTUnwrap(measured.frames[.chip(index)])
                let widthNeeded = (suggestion.label as NSString).size(withAttributes: [.font: font]).width + 20
                XCTAssertGreaterThanOrEqual(frame.width + host.pixel, widthNeeded, "Default examples must not ellipsize")
            }
            XCTAssertTrue(f.grouping.thresholds.isEmpty, "A retained hidden cleanup page must not compute")
            assertNoWork(f)
        }
        attachOverview(images)
    }

    func testMaximumAccessibilityFontKeepsOneChipRowAnd44PointTabs() async throws {
        let f = try await controlsFixture(in: self)
        let measured = MinimalMeasurements()
        let host = try mount(f, width: 320, dynamicType: .accessibility5, measured: measured)
        defer { host.close() }
        try await waitForHome(host, measured)
        try host.attach(to: self, name: "UIReview-minimal-search-home-320-accessibility")
        try assertChips(host, measured, width: 320)
        try assertOCR(host, measured, width: 320)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + host.pixel)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height,
                             "Oversized content stays reachable by vertical scrolling, never wrapping the chip row")
        for page in PrimaryPage.allCases {
            XCTAssertEqual(try XCTUnwrap(host.tabs[page]).height, 44, accuracy: host.pixel)
        }
        XCTAssertEqual(f.app.searchSuggestions[1].query, "猫猫追逐逗猫棒")
        assertNoWork(f)
    }

    func testHistoryReplacesDefaultsNewestFirstAndLongQueriesStayOneRow() async throws {
        let f = try await controlsFixture(in: self)
        let first = ("TEST first history " + String(repeating: "very long unabridged query ", count: 8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let second = "TEST second full history"
        let third = "TEST third newest history"
        for query in [first, second, third] {
            f.app.query = query
            f.app.submitSearchQuery()
            await f.app.waitUntilIdle()
            XCTAssertEqual(f.app.searchSuggestions.first?.query, query)
            XCTAssertEqual(f.app.searchSuggestions.count, 3)
        }
        let expected = [third, second, first]
        XCTAssertEqual(f.app.searchSuggestions.map(\.query), expected)
        f.app.query = "" // Draft editing returns home; it is not a submission.
        XCTAssertEqual(f.app.searchSuggestions.map(\.query), expected)
        for width in [CGFloat(393), CGFloat(320)] {
            let measured = MinimalMeasurements()
            let host = try mount(f, width: width, measured: measured)
            defer { host.close() }
            try await waitForHome(host, measured)
            try assertChips(host, measured, width: width)
            try host.attach(to: self, name: "UIReview-minimal-search-history-\(Int(width))")
            XCTAssertEqual(f.app.searchSuggestions.map(\.query), expected)
        }
        assertNoWork(f)
    }

    func testChipActionSubmitsStoredQueryNotItsAbbreviatedLabelOrEllipsis() async throws {
        let f = try await controlsFixture(in: self)
        let full = "TEST full stored query " + String(repeating: "海边日落和猫猫追逐逗猫棒 ", count: 12) + "END"
        let suggestion = SearchQuerySuggestion(label: "短标签…", query: full)
        var received: String?
        let chips = SearchQueryChips(suggestions: [suggestion]) { query in
            received = query
            f.app.query = query
            f.app.submitSearchQuery()
        }
        // Invoke the same production action closure; not a fabricated XCUI tap.
        chips.choose(suggestion)
        await f.app.waitUntilIdle()
        XCTAssertEqual(received, full)
        XCTAssertEqual(f.app.query, full)
        XCTAssertEqual(f.app.completedSearchQuery?.original, full)
        XCTAssertEqual(f.app.searchSuggestions.first?.query, full)
        let history = f.app.recentSearchQueries
        f.app.search(useOriginal: true)
        await f.app.waitUntilIdle()
        XCTAssertEqual(f.app.recentSearchQueries, history, "Execution-only replay must not reorder or add history")
        XCTAssertEqual(f.app.completedSearchQuery?.effective, full)
        assertNoWork(f)
    }

    func testOCRIntroductionExcludesRootFooterAXAndRestoresSameNativeSearchControls() async throws {
        let f = try await controlsFixture(in: self)
        f.app.query = "TEST preserved draft"
        let presentation = SearchPhotoTextPresentation()
        let measured = MinimalMeasurements()
        let host = try mount(f, width: 393, measured: measured, presentation: presentation)
        defer { host.close() }
        try await waitForHome(host, measured)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let anchor = try XCTUnwrap(controlsDescendants(scroll, PrimarySearchScrollAnchorView.self).first)
        let navigation = try XCTUnwrap(anchor.owningNavigationController)
        let field = try XCTUnwrap(controlsDescendants(scroll, UITextField.self).first)
        let toggle = try XCTUnwrap(controlsDescendants(scroll, UISwitch.self).first)
        let navFrame = try bottomFrame(host, .navigation)
        let band = try bottomFrame(host, .syncToast)
        XCTAssertFalse(toggle.isOn)
        presentation.showingIntroduction = true
        try await host.wait { host.controller.presentedViewController != nil && host.tabs.isEmpty }
        let modal = try XCTUnwrap(host.controller.presentedViewController)
        XCTAssertTrue(navigation.view.accessibilityElementsHidden)
        XCTAssertTrue(scroll.accessibilityElementsHidden)
        XCTAssertFalse(host.window.accessibilityElementsHidden)
        XCTAssertFalse(host.controller.view.accessibilityElementsHidden)
        XCTAssertFalse(modal.view.accessibilityElementsHidden)
        XCTAssertFalse(modal.view.isDescendant(of: navigation.view))
        XCTAssertTrue(field.window === host.window && toggle.window === host.window)
        XCTAssertEqual(try bottomFrame(host, .navigation).height, navFrame.height, accuracy: host.pixel)
        XCTAssertEqual(try bottomFrame(host, .syncToast).height, band.height, accuracy: host.pixel)
        XCTAssertFalse(f.app.textSearchEnabled, "Reading the introduction is not OCR opt-in")
        XCTAssertEqual(f.app.query, "TEST preserved draft")
        try host.attach(to: self, name: "UIReview-minimal-search-ocr-introduction")
        presentation.showingIntroduction = false
        try await host.wait { host.controller.presentedViewController == nil && host.tabs.count == 2 }
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertTrue(controlsDescendants(scroll, UISwitch.self).contains { $0 === toggle })
        XCTAssertTrue(controlsDescendants(scroll, UITextField.self).contains { $0 === field })
        XCTAssertFalse(navigation.view.accessibilityElementsHidden)
        XCTAssertFalse(scroll.accessibilityElementsHidden)
        XCTAssertFalse(toggle.isOn)
        assertNoWork(f)
    }

    func testNativeOCRSwitchStartsOneIncrementalUpdateAndPreservesIndependent44PointTargets() async throws {
        let f = try await controlsFixture(in: self)
        let worker = SearchRootTestWorker()
        let app = await makeSearchRootTestApp(in: self, worker: worker, translator: MinimalNoTranslation())
        let measured = MinimalMeasurements()
        let host = try mount(f, width: 320, measured: measured, app: app)
        defer { host.close() }
        try await waitForHome(host, measured)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let toggle = try XCTUnwrap(controlsDescendants(scroll, UISwitch.self).first)
        XCTAssertEqual(toggle.transform, .identity)
        XCTAssertEqual(worker.ocrCalls, 0, "Rendering is not opt-in")
        XCTAssertEqual(app.summary.textIndexCounts.records, 2)
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await host.wait { worker.ocrCalls == 1 && app.ocrSync.phase == .updating }
        XCTAssertTrue(app.textSearchEnabled)
        XCTAssertFalse(app.canIndexText, "A running update cannot admit another manual job")
        XCTAssertEqual(app.activity, .indexingText)
        XCTAssertFalse(app.summary.textIndexStatisticsKnown)
        XCTAssertEqual(worker.ocrNetworkRequests, [false])
        XCTAssertNil(host.controller.presentedViewController)
        try assertOCR(host, measured, width: 320)
        app.indexPhotoText() // Duplicate admission while running is suppressed.
        XCTAssertEqual(worker.ocrCalls, 1)
        worker.ocrGate.open()
        await app.waitUntilIdle()
        try await host.wait { app.ocrSync.phase == .completed }
        XCTAssertNil(app.activity)
        XCTAssertTrue(app.canIndexText)
        XCTAssertTrue(app.summary.textIndexStatisticsKnown)
        XCTAssertEqual(app.summary.textIndexCounts, TextIndexCounts(records: 3, withText: 3, reduced: 0))
        XCTAssertEqual(app.textIndexProgress, SearchRootTestWorker.finishedOCR)
        toggle.setOn(false, animated: false)
        toggle.sendActions(for: .valueChanged)
        try await host.wait { !app.textSearchEnabled }
        await app.waitUntilIdle()
        XCTAssertEqual(worker.ocrCalls, 1)
        XCTAssertEqual(app.summary.textIndexCounts.records, 3, "OFF does not erase completed records")
        XCTAssertFalse(app.library.canReadImages)
        XCTAssertFalse(app.allowICloudDownload)
        XCTAssertEqual(worker.unexpectedCalls, 0)
        assertNoWork(f)
    }

    func testUnknownStatisticsAndDeniedPermissionKeepHonestMinimalHomeActions() async throws {
        let f = try await controlsFixture(in: self)
        let worker = MinimalSummaryWorker(summary: LibrarySummary(indexStatisticsKnown: false,
                                                                  modelVersion: "TEST-unknown"))
        let unknown = AppState(worker: worker, authorizationStatus: { .authorized },
                               queryTranslator: MinimalNoTranslation())
        addTeardownBlock { @MainActor in unknown.enterBackground(); await unknown.waitUntilIdle() }
        unknown.refresh()
        await unknown.waitUntilIdle()
        XCTAssertFalse(unknown.summary.indexStatisticsKnown)
        XCTAssertEqual(ContentView(state: unknown).homeSubtitle, "索引统计待刷新")
        XCTAssertFalse(unknown.canSearch)
        let denied = AppState(worker: worker, authorizationStatus: { .denied },
                              queryTranslator: MinimalNoTranslation())
        addTeardownBlock { @MainActor in denied.enterBackground(); await denied.waitUntilIdle() }
        denied.refresh()
        await denied.waitUntilIdle()
        XCTAssertFalse(denied.canRead)
        XCTAssertEqual(ContentView(state: denied).homeSubtitle, "选择照片，开始在本机搜索")
        for (name, state) in [("unknown", unknown), ("permission", denied)] {
            let measured = MinimalMeasurements()
            let host = try mount(f, width: 320, measured: measured, app: state)
            defer { host.close() }
            try await waitForHome(host, measured)
            try host.attach(to: self, name: "UIReview-minimal-search-\(name)-320")
            XCTAssertFalse(state.library.canReadImages)
        }
        XCTAssertEqual(worker.unexpectedCalls, 0)
        assertNoWork(f)
    }

    func testResultsRemainCompactAndRetainQuerySelectionScrollerAndSelectionFooter() async throws {
        let f = try await controlsFixture(in: self)
        f.app.query = "TEST retained compact result query"
        f.app.submitSearchQuery()
        await f.app.waitUntilIdle()
        // Fill the finite fake response before retention assertions. Five columns
        // legitimately expose the next-page boundary earlier than two columns.
        while f.app.hasMoreResults, let session = f.app.resultSessionID {
            f.app.loadMoreResults(sessionID: session, after: f.app.results.count)
            await f.app.waitUntilIdle()
        }
        let session = try XCTUnwrap(f.app.resultSessionID)
        let ids = f.app.results.map(\.id)
        let history = f.app.recentSearchQueries
        f.app.setSelectingResults(true)
        f.app.toggleResultSelection(try XCTUnwrap(ids.first))
        let selection = f.app.selectedResultIDs
        let measured = MinimalMeasurements()
        let host = try mount(f, width: 393, measured: measured)
        defer { host.close() }
        try await host.wait { measured.frames[.resultsHeading] != nil && host.tabs.count == 2 }
        XCTAssertNil(measured.frames[.chips], "Current approved results layout does not duplicate the home blocks")
        XCTAssertNil(measured.frames[.hero])
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let toolbar = try bottomFrame(host, .selectionToolbar)
        let band = try bottomFrame(host, .syncToast)
        let nav = try bottomFrame(host, .navigation)
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        XCTAssertLessThanOrEqual(usable.maxY, toolbar.minY + host.pixel)
        XCTAssertLessThanOrEqual(toolbar.maxY, band.minY + host.pixel)
        XCTAssertLessThanOrEqual(band.maxY, nav.minY + host.pixel)
        try host.attach(to: self, name: "UIReview-minimal-search-results-393")
        f.navigation.select(.cleanup)
        try await host.settle()
        await f.cleanup.waitUntilIdle()
        f.navigation.select(.search)
        try await host.settle()
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(f.app.resultSessionID, session)
        XCTAssertEqual(f.app.results.map(\.id), ids)
        XCTAssertEqual(f.app.selectedResultIDs, selection)
        XCTAssertEqual(f.app.recentSearchQueries, history)
        XCTAssertEqual(f.app.query, "TEST retained compact result query")
        f.navigation.select(.cleanup, switchingDisabled: true)
        XCTAssertEqual(f.navigation.page, .search, "The existing write admission gate is not bypassed")
        assertNoWork(f)
    }

    func testTranslationAndMissingPackRowsStayCompactWithoutRecordingReplayOrPreparingPacks() async throws {
        let f = try await controlsFixture(in: self)
        for installed in [true, false] {
            let translator = MinimalFakeTranslation(installed: installed)
            let app = AppState(worker: f.worker, authorizationStatus: { .authorized }, queryTranslator: translator)
            addTeardownBlock { @MainActor in app.enterBackground(); await app.waitUntilIdle() }
            app.refresh()
            await app.waitUntilIdle()
            let original = "  身份证  "
            app.query = original
            app.submitSearchQuery()
            await app.waitUntilIdle()
            let resolution = try XCTUnwrap(app.completedSearchQuery)
            XCTAssertEqual(resolution.original, original)
            XCTAssertEqual(resolution.translated, installed)
            XCTAssertEqual(resolution.effective, installed ? "identity card" : original)
            XCTAssertEqual(translator.translations, installed ? [original] : [])
            let history = app.recentSearchQueries
            let measured = MinimalMeasurements()
            let host = try mount(f, width: 320, measured: measured, app: app)
            defer { host.close() }
            try await host.wait {
                host.tabs.count == 2 && controlsDescendants(host.controller.view, SearchQueryEditMenuButton.self)
                    .first?.menu != nil && (installed || measured.frames[.translation] != nil)
            }
            let buttons = controlsDescendants(host.controller.view, SearchQueryEditMenuButton.self)
            XCTAssertEqual(buttons.count, 1, "One leading icon menu, not a result-row ellipsis")
            let button = try XCTUnwrap(buttons.first)
            let field = try XCTUnwrap(controlsDescendants(host.controller.view, UITextField.self).first)
            let iconFrame = button.convert(button.bounds, to: host.window)
            let fieldFrame = field.convert(field.bounds, to: host.window)
            XCTAssertEqual(iconFrame.width, 44, accuracy: host.pixel)
            XCTAssertEqual(iconFrame.height, 44, accuracy: host.pixel)
            XCTAssertLessThanOrEqual(iconFrame.maxX, fieldFrame.minX + host.pixel)
            let actions = try XCTUnwrap(button.menu).children.compactMap { $0 as? UIAction }
            XCTAssertEqual(actions.map { $0.identifier.rawValue }, installed
                ? ["effective-search-query", "search-original"] : ["search-translated"])
            XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), installed
                ? ["显示译文", "使用原文"] : ["使用英文翻译"])
            if installed {
                XCTAssertNil(measured.frames[.translation], "A successful translation has no standalone row")
            } else {
                let row = try XCTUnwrap(measured.frames[.translation])
                XCTAssertEqual(row.height, 44, accuracy: host.pixel)
                XCTAssertGreaterThanOrEqual(row.minX + host.pixel, 20)
                XCTAssertLessThanOrEqual(row.maxX, 300 + host.pixel)
            }
            try host.attach(to: self, name: installed
                ? "UIReview-minimal-search-translation-menu-320"
                : "UIReview-minimal-search-original-fallback-320")
            // Dispatch the actual mounted UIKit menu action, not a substitute
            // direct AppState call and not a claim of an XCUI popup-menu tap.
            let replay = try XCTUnwrap(actions.first { $0.identifier.rawValue == (installed ? "search-original" : "search-translated") })
            XCTAssertFalse(replay.attributes.contains(.disabled))
            UIControl().sendAction(replay)
            await app.waitUntilIdle()
            XCTAssertEqual(app.completedSearchQuery?.original, original)
            XCTAssertEqual(app.completedSearchQuery?.effective, original)
            XCTAssertEqual(app.recentSearchQueries, history)
            XCTAssertTrue(app.chineseSearchEnabled, "One-shot replay is not a persistent preference toggle")
            XCTAssertEqual(translator.translations, installed ? [original] : [])
            XCTAssertEqual(translator.preparations, 0)
            XCTAssertNil(app.appleTranslationService)
        }
        assertNoWork(f)
    }

    func testSearchingUsesCompactInlineRowAndKeepsNativeFieldScrollerAndFooterGeometry() async throws {
        let f = try await controlsFixture(in: self)
        let worker = SearchRootTestWorker()
        let gate = SearchRootTestGate()
        worker.searchGate = gate
        let app = await makeSearchRootTestApp(in: self, worker: worker, translator: MinimalNoTranslation())
        let measured = MinimalMeasurements()
        let host = try mount(f, width: 320, measured: measured, app: app)
        defer { host.close() }
        try await waitForHome(host, measured)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let field = try XCTUnwrap(controlsDescendants(scroll, UITextField.self).first)
        let delegate = try XCTUnwrap(field.delegate)
        let band = try bottomFrame(host, .syncToast)
        let nav = try bottomFrame(host, .navigation)
        app.query = "TEST held first search"
        app.submitSearchQuery()
        try await host.wait {
            worker.searches.count == 1 && app.activity == .searching
                && measured.frames[.hero] == nil && measured.frames[.heading] == nil
                && measured.frames[.tools] != nil
        }
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertTrue(controlsDescendants(scroll, UITextField.self).first === field)
        XCTAssertTrue(field.delegate === delegate)
        XCTAssertTrue(field.isEnabled && field.isUserInteractionEnabled)
        XCTAssertEqual(field.text, "TEST held first search")
        XCTAssertFalse(scroll.accessibilityElementsHidden)
        XCTAssertNil(host.controller.presentedViewController)
        XCTAssertNil(measured.frames[.resultsHeading])
        XCTAssertNil(measured.frames[.translation])
        XCTAssertEqual(try bottomFrame(host, .syncToast), band)
        XCTAssertEqual(try bottomFrame(host, .navigation), nav)
        let tools = try XCTUnwrap(measured.frames[.tools])
        let bottom = scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: host.window).y
        // 18pt content gap + a 44pt action with 12pt vertical padding + 24pt
        // content bottom padding. No full-page spinner or old empty-card space.
        XCTAssertEqual(bottom - tools.maxY, 18 + 44 + 24 + 24, accuracy: host.pixel)
        try host.attach(to: self, name: "UIReview-minimal-search-compact-loading-320")
        gate.open()
        await app.waitUntilIdle()
        try await host.wait { measured.frames[.resultsHeading] != nil }
        XCTAssertEqual(worker.searches, ["TEST held first search"])
        XCTAssertEqual(app.totalResultCount, 37)
        XCTAssertTrue(try primarySearchScrollView(in: host.controller.view) === scroll)
        XCTAssertEqual(worker.ocrCalls, 0)
        assertNoWork(f)
    }

    // MARK: Same production controls, passive public geometry, no AX-tree guess

    private func mount(_ f: ControlsFixture, width: CGFloat, dynamicType: DynamicTypeSize = .large,
                       measured: MinimalMeasurements, presentation: SearchPhotoTextPresentation? = nil,
                       app: AppState? = nil) throws -> ControlsNativeHost {
        let content = ContentView(state: app ?? f.app, photoActionService: MinimalNoPhotoActions(),
            similarCleanupState: f.cleanup, navigation: f.navigation, cleanupPreferences: nil,
            photoTextPresentation: presentation)
            .onPreferenceChange(MinimalSearchFrames.self) { measured.frames = $0 }
            .onPreferenceChange(SearchPhotoTextFrames.self) { measured.ocr = $0 }
        return try ControlsNativeHost(content: AnyView(content), size: CGSize(width: width, height: 852),
                                      dynamicType: dynamicType)
    }

    private func waitForHome(_ host: ControlsNativeHost, _ measured: MinimalMeasurements) async throws {
        try await host.wait {
            measured.frames[.hero] != nil && measured.frames[.heroArea] != nil
                && measured.frames[.chip(2)] != nil && measured.ocr[.toggle] != nil
                && host.tabs.count == 2
        }
    }

    private func assertHome(_ host: ControlsNativeHost, _ measured: MinimalMeasurements, width: CGFloat) throws {
        let heading = try XCTUnwrap(measured.frames[.heading])
        let field = try XCTUnwrap(measured.frames[.field])
        let chips = try XCTUnwrap(measured.frames[.chips])
        let tools = try XCTUnwrap(measured.frames[.tools])
        let area = try XCTUnwrap(measured.frames[.heroArea])
        let hero = try XCTUnwrap(measured.frames[.hero])
        XCTAssertLessThan(heading.maxY, field.minY)
        XCTAssertLessThanOrEqual(field.maxY, chips.minY + host.pixel)
        XCTAssertLessThanOrEqual(chips.maxY, tools.minY + host.pixel)
        XCTAssertLessThanOrEqual(tools.maxY, area.minY + host.pixel)
        XCTAssertEqual(hero.width, 160, accuracy: host.pixel)
        XCTAssertEqual(hero.height, 160, accuracy: host.pixel)
        XCTAssertEqual(hero.midX, area.midX, accuracy: host.pixel)
        XCTAssertEqual(hero.midY, area.midY, accuracy: host.pixel)
        XCTAssertEqual(hero.midX, width / 2, accuracy: host.pixel)
        let scroll = try primarySearchScrollView(in: host.controller.view)
        let usable = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.window)
        XCTAssertGreaterThanOrEqual(hero.minY, usable.minY - host.pixel)
        XCTAssertLessThanOrEqual(area.maxY, usable.maxY + host.pixel)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + host.pixel)
        let band = try bottomFrame(host, .syncToast)
        let nav = try bottomFrame(host, .navigation)
        XCTAssertEqual(band.height, 52, accuracy: host.pixel, "Sync agent owns the stable idle band")
        XCTAssertEqual(usable.maxY, band.minY, accuracy: host.pixel,
                   "No indexed-count footer between home content and the reserved sync band")
        XCTAssertLessThanOrEqual(band.maxY, nav.minY + host.pixel)
        XCTAssertEqual(nav.height, 44, accuracy: host.pixel)
        for page in PrimaryPage.allCases {
            XCTAssertEqual(try XCTUnwrap(host.tabs[page]).height, 44, accuracy: host.pixel)
        }
        try assertChips(host, measured, width: width)
        try assertOCR(host, measured, width: width)
        let anchor = try XCTUnwrap(controlsDescendants(scroll, PrimarySearchScrollAnchorView.self).first)
        let navigation = try XCTUnwrap(anchor.owningNavigationController)
        XCTAssertEqual(navigation.navigationBar.topItem?.title, "照片搜索")
        XCTAssertFalse(navigation.view.accessibilityElementsHidden)
        XCTAssertNotNil(controlsDescendants(scroll, UITextField.self).first)
    }

    private func assertChips(_ host: ControlsNativeHost, _ measured: MinimalMeasurements, width: CGFloat) throws {
        let row = try XCTUnwrap(measured.frames[.chips])
        XCTAssertEqual(row.height, 44, accuracy: host.pixel)
        var right = row.minX
        for index in 0..<3 {
            let chip = try XCTUnwrap(measured.frames[.chip(index)])
            XCTAssertGreaterThanOrEqual(chip.width + host.pixel, 44)
            XCTAssertEqual(chip.height, 44, accuracy: host.pixel)
            XCTAssertEqual(chip.minY, row.minY, accuracy: host.pixel)
            XCTAssertEqual(chip.minX, right + (index == 0 ? 0 : 6), accuracy: host.pixel)
            XCTAssertGreaterThanOrEqual(chip.minX + host.pixel, 20)
            XCTAssertLessThanOrEqual(chip.maxX, width - 20 + host.pixel)
            right = chip.maxX
        }
    }

    private func assertOCR(_ host: ControlsNativeHost, _ measured: MinimalMeasurements, width: CGFloat) throws {
        let filter = try XCTUnwrap(measured.ocr[.filters])
        let label = try XCTUnwrap(measured.ocr[.label])
        let info = try XCTUnwrap(measured.ocr[.info])
        let toggle = try XCTUnwrap(measured.ocr[.toggle])
        XCTAssertGreaterThanOrEqual(filter.width + host.pixel, 44)
        XCTAssertGreaterThanOrEqual(filter.height + host.pixel, 44)
        XCTAssertLessThanOrEqual(label.maxX, info.minX + host.pixel)
        XCTAssertLessThanOrEqual(info.maxX, toggle.minX + host.pixel)
        XCTAssertEqual(info.width, 44, accuracy: host.pixel)
        XCTAssertEqual(info.height, 44, accuracy: host.pixel)
        XCTAssertGreaterThanOrEqual(toggle.width + host.pixel, 51)
        XCTAssertGreaterThanOrEqual(toggle.height + host.pixel, 44)
        XCTAssertLessThanOrEqual(toggle.maxX, width - 20 + host.pixel)
        XCTAssertLessThanOrEqual(info.intersection(toggle).width, host.pixel,
                    "Info and switch must have independent non-overlapping targets")
    }

    private func bottomFrame(_ host: ControlsNativeHost, _ part: RootBottomLayoutPart) throws -> CGRect {
        let probes = controlsDescendants(host.controller.view, RootBottomLayoutProbeView.self).filter {
            $0.part == part && $0.window === host.window && $0.windowFrame != nil
        }
        XCTAssertEqual(probes.count, 1)
        return try XCTUnwrap(probes.first?.windowFrame)
    }

    private func assertNoWork(_ f: ControlsFixture) {
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertFalse(f.app.library.canReadImages)
        XCTAssertFalse(f.app.allowICloudDownload)
        XCTAssertNil(f.app.appleTranslationService)
        XCTAssertNil(f.app.activity)
        XCTAssertEqual(f.worker.unexpectedCalls, 0)
        XCTAssertEqual(f.app.progress, IndexProgress())
        XCTAssertEqual(f.app.textIndexProgress, TextIndexProgress())
        XCTAssertFalse(f.cleanup.isDeleting)
    }

    private func attachGeometry(_ host: ControlsNativeHost, _ measured: MinimalMeasurements, name: String) {
        let attachment = XCTAttachment(string: """
        Synthetic native host, not private Photos. Window: \(host.window.bounds)
        Critical markers: heading / subtitle / field / three chips / OCR filters-label-info-toggle / hero160 / root sync band / navigation44
        Search: \(measured.frames)
        OCR: \(measured.ocr)
        Tabs: \(host.tabs)
        """)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attachOverview(_ images: [UIImage]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 745, height: 892), format: format)
        let image = renderer.image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 745, height: 892))
            ("NATIVE TEST FIXTURE · 393pt / 320pt · no Photos" as NSString).draw(
                at: CGPoint(x: 12, y: 8), withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.white])
            images[0].draw(in: CGRect(x: 8, y: 32, width: 393, height: 852))
            images[1].draw(in: CGRect(x: 417, y: 32, width: 320, height: 852))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-minimal-search-home-overview"
        attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
private final class MinimalMeasurements {
    var frames: [MinimalSearchPart: CGRect] = [:]
    var ocr: [SearchPhotoTextElement: CGRect] = [:]
}

private struct MinimalNoPhotoActions: PhotoLibraryActions {
    func albums() async throws -> [PhotoAlbum] { throw unexpected() }
    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws { throw unexpected() }
    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare { throw unexpected() }
    func validateAccess(ids: [String]) throws { throw unexpected() }
    private func unexpected() -> ControlsPresentationFailure {
        XCTFail("Minimal presentation must not read albums, share or mutate Photos")
        return .unexpectedWork
    }
}

@MainActor
private final class MinimalSummaryWorker: PhotoWorkServicing {
    let summary: LibrarySummary
    private(set) var unexpectedCalls = 0
    init(summary: LibrarySummary) { self.summary = summary }
    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw unexpected() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> ControlsPresentationFailure {
        unexpectedCalls += 1; XCTFail("Unknown-summary rendering must not start work"); return .unexpectedWork
    }
}

@MainActor
private final class MinimalNoTranslation: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("No system translation in native presentation tests"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("No language-pack download in native presentation tests"); throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class MinimalFakeTranslation: QueryTranslating {
    let isSupported = true
    let installed: Bool
    private(set) var translations: [String] = []
    private(set) var preparations = 0
    init(installed: Bool) { self.installed = installed }
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        installed ? .installed : .downloadRequired
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translations.append(text)
        return "identity card"
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        preparations += 1
        XCTFail("Viewing a translation menu/fallback must never prepare a pack")
        throw QueryTranslationFailure.unsupported
    }
}