import XCTest

/// Real-app navigation only. Use a disposable simulator: each launch resets this
/// app's Photos permission to undetermined, but never requests/grants access,
/// imports assets, indexes photos, or substitutes models/services in the app.
/// UIReview attachments are native screenshots for later xcresult export/review.
@MainActor
final class PresentationNavigationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testHomeAndUnauthorizedLibraryNavigation() throws {
        launch()
        // Verify the real launch's settled outcome, not whether a possibly
        // brief startup icon happened to be sampled by accessibility.
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-icon").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-recovery-icon").firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        assertHomeControls()
        let libraryReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "选择照片"),
            object: app.buttons["open-library"])
        XCTAssertEqual(XCTWaiter.wait(for: [libraryReady], timeout: 15), .completed,
                       "Capture the settled unauthorized home, not a transient library refresh")
        attach("home-live")

        app.buttons["open-library"].tap()
        let done = app.buttons["close-library"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(done.label, "完成")
        XCTAssertTrue(app.navigationBars["我的图库"].exists)
        XCTAssertTrue(app.buttons["authorize-photos"].waitForExistence(timeout: 5),
                  "The library must remain unauthorized; do not tap 选择照片")
        XCTAssertEqual(app.buttons["authorize-photos"].label, "选择照片")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach("library-live")
        let form = try sheetForm()
        let update = app.buttons["index-photos"]
        scrollTo(update, in: form, allowDisabled: true)
        XCTAssertEqual(update.label, "建立索引")
        XCTAssertFalse(update.isEnabled)
        let rebuild = app.buttons["rebuild-index"]
        scrollTo(rebuild, in: form, allowDisabled: true)
        XCTAssertEqual(rebuild.label, "全部重建索引")
        XCTAssertFalse(rebuild.isEnabled, "Rebuild is visible without debug tools, but requires index readiness")
        XCTAssertFalse(app.buttons["confirm-rebuild-index"].exists,
                   "Merely opening Library must not expose the destructive confirmation action")
        done.tap()
        expectAbsent(done)
        expectHittable(app.textFields["photo-query"])
        assertHomeControls()
    }

    func testSearchFiltersApplyAndClearWithoutPhotosPermission() throws {
        if ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"] == "0" {
            throw XCTSkip("Live search filters require the real bundled models")
        }
        // Reuse the real-model startup gate and reset Photos to .notDetermined;
        // never authorize, seed photos, replace state/services, or start indexing.
        launch()
        assertHomeControls()
        let library = app.buttons["open-library"]
        let libraryReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ AND value == %@",
                                   "选择照片", "authorization-required"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [libraryReady], timeout: 15), .completed)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        let filters = app.buttons["open-search-filters"]
        expectHittable(filters)
        XCTAssertEqual(filters.label, "筛选")
        let caption = app.staticTexts["日期 · 截屏"]
        XCTAssertFalse(caption.exists)

        let apply = app.buttons["apply-search-filters"]
        let issue = app.staticTexts["search-filter-album-issue"]
        for clearing in [false, true] {
            filters.tap()
            expectHittable(apply)
            XCTAssertTrue(app.navigationBars["筛选照片"].exists)
            let form = try sheetForm()
            // This is the real album service's permission failure, not a fixture.
            // Reopening saved dates exposes custom controls above this lazy row.
            scrollTo(issue, in: form)
            XCTAssertEqual(issue.label, "请先允许访问照片。")
            expectAbsent(app.descendants(matching: .any)
                .matching(identifier: "search-filter-albums-loading").firstMatch)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)

            if clearing {
                let clear = app.buttons["clear-search-filters"]
                scrollTo(clear, in: form)
                XCTAssertEqual(clear.label, "清除筛选")
                clear.tap()
            } else {
                let datePreset = app.descendants(matching: .any)
                    .matching(identifier: "search-filter-date-preset").firstMatch
                scrollTo(datePreset, in: form, swipeUp: false)
                XCTAssertTrue(datePreset.label.contains("日期范围"))
                datePreset.tap()
                let lastYear = app.buttons["去年"]
                expectHittable(lastYear)
                lastYear.tap()
                let selectedDate = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "去年", "去年"),
                    object: datePreset)
                XCTAssertEqual(XCTWaiter.wait(for: [selectedDate], timeout: 5), .completed)

                let imageKind = app.descendants(matching: .any)
                    .matching(identifier: "search-filter-image-kind").firstMatch
                scrollTo(imageKind, in: form)
                imageKind.tap()
                let screenshots = app.buttons["截屏"]
                expectHittable(screenshots)
                screenshots.tap()
                let selectedKind = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "截屏", "截屏"),
                    object: imageKind)
                XCTAssertEqual(XCTWaiter.wait(for: [selectedKind], timeout: 5), .completed)
            }

            expectHittable(apply)
            XCTAssertTrue(apply.isEnabled, "An album permission error must not block date/type filters or clearing")
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
            apply.tap()
            expectAbsent(apply)
            expectHittable(filters)
            XCTAssertEqual(filters.label, clearing ? "筛选" : "已筛选")
            if clearing { expectAbsent(caption) }
            else { expectHittable(caption) }
            assertHomeControls()
            XCTAssertEqual(library.value as? String, "authorization-required")
            XCTAssertTrue(library.label.contains("选择照片"))
            XCTAssertFalse(library.label.contains("正在更新索引"))
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
        }

        library.tap()
        let done = app.buttons["close-library"]
        expectHittable(done)
        // This action exists only for .notDetermined, not denied/authorized.
        // Inspect it without tapping; opening/clearing filters must not prompt.
        expectHittable(app.buttons["authorize-photos"])
        let update = app.buttons["index-photos"]
        scrollTo(update, in: try sheetForm(), allowDisabled: true)
        XCTAssertEqual(update.label, "建立索引")
        XCTAssertFalse(update.isEnabled)
        XCTAssertFalse(app.buttons["stop-indexing"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        done.tap()
        expectAbsent(done)
        assertHomeControls()
        XCTAssertEqual(filters.label, "筛选")
        expectAbsent(caption)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
    }

    func testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed() throws {
        launch()
        assertHomeControls()
        let field = app.textFields["photo-query"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        typeExactly("TEST FIXTURE coast", into: field)
        let clear = app.buttons["clear-query"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        expectAbsent(clear)
        // UITextField exposes its placeholder as value when empty on some iOS
        // versions. Do not mistake that accessibility representation for a query.
        let value = field.value as? String
        XCTAssertTrue(value == "" || value == field.placeholderValue)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clear must retain search focus")
        let preservedQuery = "TEST FIXTURE coast"
        typeExactly(preservedQuery, into: field)
        let keyboardDone = app.buttons["keyboard-done"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 5))
        keyboardDone.tap()
        expectAbsent(app.keyboards.firstMatch)
        XCTAssertFalse(app.buttons["hide-search-keyboard"].exists)
        XCTAssertEqual(field.value as? String, preservedQuery)

        app.buttons["open-settings"].tap()
        let done = app.buttons["close-settings"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertEqual(done.label, "完成")
        XCTAssertTrue(app.navigationBars["设置"].exists)
        let picker = app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        // Production uses a page-size menu Picker with 3张 / 12张, not a segmented
        // control. Check its stable identifier; do not guess private menu nodes.
        XCTAssertTrue(picker.label.contains("每批显示"))
        expectResultLimit("12张", picker: picker)
        let form = try sheetForm()
        // debug-advanced identifies the Text label ONLY, not its parent button.
        let advanced = app.buttons["高级设置"]
        let weight = app.sliders["location-weight"]
        for element in settingsDebugElements { expectAbsent(element) }
        attach("settings-live")
        picker.tap()
        let pageOfThree = app.buttons["3张"]
        expectHittable(pageOfThree)
        pageOfThree.tap()
        expectResultLimit("3张", picker: picker)

        assertSettingsDebugOff(in: form)
        setDebugTools(true, in: form)
        scrollTo(advanced, in: form, swipeUp: false)
        XCTAssertFalse(weight.exists, "Advanced must start collapsed after opting in")
        tapDisclosure(advanced)
        expectExpandedWeight(weight)
        XCTAssertEqual(weight.value as? String, "60%", "The actual location-weight slider keeps its default")
        scrollTo(advanced, in: form, swipeUp: false)
        tapDisclosure(advanced)
        expectAbsent(weight)
        scrollTo(advanced, in: form, swipeUp: false)
        tapDisclosure(advanced)
        expectExpandedWeight(weight)
        scrollTo(app.buttons["诊断信息"], in: form)
        // Advanced is expanded: hiding tools must remove it, not merely collapse it.
        setDebugTools(false, in: form)
        assertSettingsDebugOff(in: form)
        scrollTo(picker, in: form, swipeUp: false)
        expectResultLimit("3张", picker: picker)
        done.tap()
        expectAbsent(done)
        expectHittable(field)
        XCTAssertEqual(field.value as? String, preservedQuery)
        assertHomeControls()

        // Returning to Settings must retain the chosen page size in this session.
        app.buttons["open-settings"].tap()
        expectHittable(done)
        expectResultLimit("3张", picker: picker)
        done.tap()
        expectAbsent(done)
        expectHittable(field)
        XCTAssertEqual(field.value as? String, preservedQuery)
        assertHomeControls()
    }

    func testLargeFontSettingsCanBeDismissed() {
        launch(largeText: true)
        let settings = app.buttons["open-settings"]
        expectHittable(settings)
        settings.tap()
        let done = app.buttons["close-settings"]
        expectHittable(done)
        XCTAssertEqual(done.label, "完成")
        XCTAssertTrue(app.navigationBars["设置"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["location-weight"].exists)
        attach("settings-live-accessibility-large")
        done.tap()
        expectAbsent(done)
        expectHittable(settings)
    }

    func testOneGlobalDebugToggleStartsOffAndResetsOnRelaunch() throws {
        launch()
        app.buttons["open-library"].tap()
        let libraryDone = app.buttons["close-library"]
        expectHittable(libraryDone)
        assertUserLibrary(in: try sheetForm())
        libraryDone.tap()
        expectAbsent(libraryDone)

        app.buttons["open-settings"].tap()
        let settingsDone = app.buttons["close-settings"]
        expectHittable(settingsDone)
        let settingsForm = try sheetForm()
        assertSettingsDebugOff(in: settingsForm)
        setDebugTools(true, in: settingsForm)
        settingsDone.tap()
        expectAbsent(settingsDone)

        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        XCTAssertTrue(app.buttons["authorize-photos"].waitForExistence(timeout: 5))
        let details = app.buttons["详细信息"]
        scrollTo(details, in: try sheetForm())
        XCTAssertFalse(debugToggle.exists, "Library uses the single Settings toggle, not a second switch")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        libraryDone.tap()
        expectAbsent(libraryDone)

        app.buttons["open-settings"].tap()
        expectHittable(settingsDone)
        scrollTo(debugToggle, in: try sheetForm())
        expectSwitch(debugToggle, enabled: true)
        // Terminate while ON: turning it off first would not test session-only reset.
        app.terminate()
        launch()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-icon").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-recovery-icon").firstMatch.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["open-settings"].tap()
        expectHittable(settingsDone)
        assertSettingsDebugOff(in: try sheetForm())
        settingsDone.tap()
        expectAbsent(settingsDone)

        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        assertUserLibrary(in: try sheetForm())
        libraryDone.tap()
        expectAbsent(libraryDone)
        assertHomeControls()
    }

    func testChineseTranslationControlsRemainAccessibleWithDebugToolsOff() throws {
        launch()
        app.buttons["open-settings"].tap()
        let done = app.buttons["close-settings"]
        expectHittable(done)
        let form = try sheetForm()
        assertSettingsDebugOff(in: form)
        let chineseSearch = app.switches["chinese-search-enabled"]
        scrollTo(chineseSearch, in: form, swipeUp: false, expectingAbsent: settingsDebugElements)
        XCTAssertTrue(chineseSearch.isEnabled)
        let language = app.descendants(matching: .any).matching(identifier: "translation-language").firstMatch
        scrollTo(language, in: form, expectingAbsent: settingsDebugElements)
        XCTAssertTrue(language.isEnabled)
        let availability = app.staticTexts["translation-availability"]
        scrollTo(availability, in: form, expectingAbsent: settingsDebugElements)
        XCTAssertFalse(availability.label.isEmpty)
        let prepare = app.buttons["prepare-translation"]
        scrollTo(prepare, in: form, expectingAbsent: settingsDebugElements, allowDisabled: true)
        // The real simulator may report unsupported and disable preparation.
        // Reachability is required; do not download a pack or fake support.
        if availability.label == "需要 iOS 18+ 真机；仍可原文搜索" {
            XCTAssertFalse(prepare.isEnabled)
        }
        assertSettingsDebugOff(in: form)
        done.tap()
        expectAbsent(done)
        assertHomeControls()
    }

    func testLaunchTimingShowsRealReadyReportAndReturnsWithNativeBack() throws {
        // Model-free runs cannot supply a real ready report. Never use the
        // launch helper's model-free recovery route as evidence of readiness.
        if ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"] == "0" {
            throw XCTSkip("Live launch timing requires the real bundled models")
        }
        launch()
        assertHomeControls()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-icon").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "startup-recovery-icon").firstMatch.exists)
        app.buttons["open-settings"].tap()
        expectHittable(app.buttons["close-settings"])
        let form = try sheetForm()
        assertSettingsDebugOff(in: form)
        setDebugTools(true, in: form)
        let diagnostics = app.buttons["诊断信息"]
        scrollTo(diagnostics, in: form, swipeUp: false)
        let link = app.buttons["debug-launch-timing"]
        XCTAssertFalse(link.exists, "The link belongs inside the initially collapsed diagnostics group")
        tapDisclosure(diagnostics)
        scrollTo(link, in: form)
        XCTAssertEqual(link.label, "启动耗时")
        link.tap()

        let page = app.scrollViews["startup-timing-page"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["启动耗时"].exists)
        let total = app.staticTexts["launch-timing-total"]
        expectHittable(total)
        XCTAssertNotNil(total.label.range(of: #"^[0-9]+\.[0-9]{3} 秒$"#, options: .regularExpression))
        let seconds = try XCTUnwrap(Double(total.label.replacingOccurrences(of: " 秒", with: "")))
        XCTAssertGreaterThan(seconds, 0, "Read the actual timed preparation, not a fixture or placeholder")
        XCTAssertTrue(app.staticTexts["本进程首次启动 · 准备完成"].exists)
        XCTAssertTrue(app.staticTexts["从 App 开始准备到发布首页就绪；不含 iOS 启动进程及首帧绘制"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opening diagnostics must not request Photos access")
        attach("launch-timing-live")

        let counts = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "读取已存索引统计，")).firstMatch
        scrollTo(counts, in: page)
        XCTAssertTrue(counts.exists, "The real preparation must expose its production counts stage")
        for title in ["加载分词器", "加载图像模型", "加载文本模型"] {
            let component = app.descendants(matching: .any)
                .matching(identifier: "launch-timing-component-\(title)").firstMatch
            scrollTo(component, in: page)
            XCTAssertTrue(component.label.contains("完成"))
            XCTAssertTrue(component.label.contains("启动后 +"))
            XCTAssertNotNil(component.label.range(of: #"[0-9]+\.[0-9]{3} 秒"#, options: .regularExpression))
        }
        attach("launch-timing-parallel-live")
        let back = app.navigationBars["启动耗时"].buttons.element(boundBy: 0)
        expectHittable(back)
        back.tap()
        expectAbsent(page)
        XCTAssertTrue(app.navigationBars["设置"].exists)
        setDebugTools(false, in: try sheetForm())
        assertSettingsDebugOff(in: try sheetForm())
        app.buttons["close-settings"].tap()
        assertHomeControls()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testPhotoTextOptInDoesNotIndexOrAskPhotosPermission() throws {
        if ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"] == "0" {
            throw XCTSkip("Live photo text opt-in requires the real bundled models")
        }
        launch()
        assertHomeControls()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toggle = app.switches["photo-text-search-enabled"]
        let update = app.buttons["index-photo-text"]
        let done = app.buttons["close-settings"]

        func assertNoWorkOrPermissionPrompt() {
            XCTAssertFalse(app.buttons["pause-text-index"].exists)
            XCTAssertFalse(app.buttons["stop-indexing"].exists)
            XCTAssertFalse(app.progressIndicators["文字索引进度"].exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
        }

        func openTextSettings() throws -> XCUIElement {
            let library = app.buttons["open-library"]
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label CONTAINS %@ AND value == %@",
                                       "选择照片", "authorization-required"), object: library)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            assertNoWorkOrPermissionPrompt()
            app.buttons["open-settings"].tap()
            expectHittable(done)
            let form = try sheetForm()
            scrollTo(toggle, in: form)
            XCTAssertEqual(app.switches.matching(identifier: "photo-text-search-enabled").count, 1)
            XCTAssertTrue(toggle.isEnabled, "The optional preference must not require Photos permission")
            return form
        }

        func tapOptIn(_ enabled: Bool, in form: XCUIElement) {
            scrollTo(toggle, in: form, swipeUp: false)
            expectSwitch(toggle, enabled: !enabled)
            // Same native SwiftUI Form Toggle and full-row AX frame as the
            // captured show-debug-tools case above: tap its trailing thumb.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            scrollTo(toggle, in: form, swipeUp: false)
            expectSwitch(toggle, enabled: enabled)
            assertNoWorkOrPermissionPrompt()
        }

        // Best-effort cleanup if an assertion exits while Settings is still
        // open. Only a captured ON value authorizes a tap; never write defaults
        // or inject a production launch flag, and never interact with OS alerts.
        defer {
            if app.state == .runningForeground, done.exists,
               !app.alerts.firstMatch.exists, !springboard.alerts.firstMatch.exists,
               let form = try? sheetForm() {
                scrollTo(toggle, in: form, swipeUp: false)
                if toggle.value as? String == "1" { tapOptIn(false, in: form) }
            }
        }

        var form = try openTextSettings()
        let initialValue = try XCTUnwrap(toggle.value as? String)
        XCTAssertTrue(initialValue == "0" || initialValue == "1", "Read the actual switch before recovering a prior crash")
        if initialValue == "1" { tapOptIn(false, in: form) }
        expectSwitch(toggle, enabled: false)
        expectAbsent(update)
        assertNoWorkOrPermissionPrompt()

        tapOptIn(true, in: form)
        scrollTo(update, in: form, allowDisabled: true)
        XCTAssertTrue(update.exists)
        XCTAssertTrue(update.label.contains("文字索引"))
        XCTAssertFalse(update.isEnabled, "Opt-in alone cannot authorize Photos or start indexing")
        assertNoWorkOrPermissionPrompt()

        // Check production privacy text via the real XCUI tree, not in-process
        // SwiftUI AX or a copied presentation fixture. Match stable fragments.
        let privacy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "识别文字仅保存在本机")).firstMatch
        scrollTo(privacy, in: form)
        for fragment in ["不参与备份", "不代表当前有权限搜索", "关闭增强不会删除", "清除索引会一起删除"] {
            XCTAssertTrue(privacy.label.contains(fragment))
        }
        assertNoWorkOrPermissionPrompt()
        done.tap()
        expectAbsent(done)

        // ON is a real persisted preference, unlike session-only debug tools.
        // Relaunch through the unchanged full-model readiness/Photos-reset helper.
        app.terminate()
        launch()
        assertHomeControls()
        form = try openTextSettings()
        expectSwitch(toggle, enabled: true)
        scrollTo(update, in: form, allowDisabled: true)
        XCTAssertTrue(update.exists)
        XCTAssertFalse(update.isEnabled)
        assertNoWorkOrPermissionPrompt()
        tapOptIn(false, in: form)
        expectAbsent(update)
        done.tap()
        expectAbsent(done)
        assertHomeControls()

        // Leave OFF, including after sheet reconstruction, for every later test.
        form = try openTextSettings()
        expectSwitch(toggle, enabled: false)
        expectAbsent(update)
        assertNoWorkOrPermissionPrompt()
        done.tap()
        expectAbsent(done)
        app.buttons["open-library"].tap()
        let libraryDone = app.buttons["close-library"]
        expectHittable(libraryDone)
        // This action is specific to .notDetermined; never tap it.
        expectHittable(app.buttons["authorize-photos"])
        assertNoWorkOrPermissionPrompt()
        libraryDone.tap()
        expectAbsent(libraryDone)
        assertHomeControls()
        XCTAssertEqual(app.buttons["open-library"].value as? String, "authorization-required")
    }

    private func launch(largeText: Bool = false) {
        // Intentionally keep the system keyboard/locale English for exact-key
        // fixtures and Apple's Search return key. The app's approved Chinese
        // copy is independent; this is not a claim of system-language localization.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName",
                               largeText ? "UICTContentSizeCategoryAccessibilityL" : "UICTContentSizeCategoryL"]
        app.resetAuthorizationStatus(for: .photos)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        waitForPreparedHome(app)
    }

    private var debugToggle: XCUIElement { app.switches["show-debug-tools"] }

    private var settingsDebugElements: [XCUIElement] {
        [app.descendants(matching: .any).matching(identifier: "debug-advanced").firstMatch,
         app.descendants(matching: .any).matching(identifier: "debug-diagnostics").firstMatch,
            app.descendants(matching: .any).matching(identifier: "debug-launch-timing").firstMatch,
         app.buttons["高级设置"], app.buttons["诊断信息"], app.sliders["location-weight"]]
    }

    private func sheetForm() throws -> XCUIElement {
        // SwiftUI Form is backed by a collection/table/scroll view depending on
        // iOS. Only use a hittable sheet container, never the home library-scroll.
        let candidates = app.collectionViews.allElementsBoundByIndex
            + app.tables.allElementsBoundByIndex
            + app.scrollViews.matching(NSPredicate(format: "identifier != %@", "library-scroll")).allElementsBoundByIndex
        return try XCTUnwrap(candidates.first(where: { $0.exists && $0.isHittable }),
                             "The presented sheet must expose its real scrollable Form")
    }

    private func scrollTo(_ element: XCUIElement, in form: XCUIElement, swipeUp: Bool = true,
                          expectingAbsent hidden: [XCUIElement] = [],
                          allowDisabled: Bool = false,
                          file: StaticString = #filePath, line: UInt = #line) {
        // At most eight real Form gestures per lookup, TEST ONLY. Check each
        // viewport so lazy off-screen rows cannot alone prove debug UI is absent.
        for attempt in 0...8 {
            for candidate in hidden {
                XCTAssertFalse(candidate.exists, "Debug controls must be absent, not just off screen",
                               file: file, line: line)
            }
            if element.exists && element.isHittable { return }
            // Unsupported translation can expose a disabled button without a
            // hit point. Still require its complete, nonempty frame on screen.
            if allowDisabled, element.exists, !element.isEnabled, !element.frame.isEmpty,
               form.frame.contains(element.frame), app.frame.contains(element.frame) { return }
            if attempt < 8 {
                if swipeUp { form.swipeUp() } else { form.swipeDown() }
            }
        }
        XCTFail("Control was not reachable within eight sheet Form swipes: \(element)", file: file, line: line)
    }

    private func expectSwitch(_ element: XCUIElement, enabled: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, file: file, line: line)
    }

    private func setDebugTools(_ enabled: Bool, in form: XCUIElement) {
        scrollTo(debugToggle, in: form)
        XCTAssertEqual(app.switches.matching(identifier: "show-debug-tools").count, 1)
        expectSwitch(debugToggle, enabled: !enabled)
        // The captured iOS AX hierarchy gives the identified SwiftUI switch the
        // FULL row frame, while its actual thumb is a separate 51-point switch
        // at the trailing edge. Tapping the row centre hit only the label and
        // left value=0; tap inside this exact identified row's thumb instead.
        debugToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // Inserting Advanced/Diagnostics above the bottom switch can move it
        // out of the Form's realized viewport. Reacquire it after layout changes.
        scrollTo(debugToggle, in: form)
        expectSwitch(debugToggle, enabled: enabled)
    }

    private func tapDisclosure(_ element: XCUIElement) {
        expectHittable(element)
        // Use the semantic button, not coordinates derived from a label frame.
        // The previous recording proved expansion succeeded; lookup was failing.
        element.tap()
    }

    private func expectExpandedWeight(_ weight: XCUIElement) {
        // In this flow the disclosure header is onscreen. The recording shows
        // the slider appears directly below it. Never blindly swipe away from
        // it when an identifier/type lookup is the actual failure.
        let appeared = weight.waitForExistence(timeout: 5)
        let unique = app.sliders.matching(identifier: "location-weight").count == 1
        let inherited = app.sliders.matching(identifier: "debug-advanced").count
        let correctValue = appeared && (weight.value as? String) == "60%"
        if !appeared || !unique || inherited != 0 || !weight.isHittable || !correctValue {
            let sliders = app.sliders.allElementsBoundByIndex.map {
                "identifier=\($0.identifier), label=\($0.label), value=\(String(describing: $0.value)), frame=\($0.frame)"
            }.joined(separator: "\n")
            let evidence = XCTAttachment(string: "SLIDERS\n\(sliders)\nTREE\n\(app.debugDescription)")
            evidence.name = "Advanced-slider-accessibility-before-scroll"
            evidence.lifetime = .keepAlways
            add(evidence)
            attach("advanced-slider-lookup-failure")
        }
        XCTAssertTrue(appeared, "Expanded slider must be discoverable before any swipe")
        XCTAssertTrue(unique, "One location-weight slider must retain its own accessibility identifier")
        XCTAssertEqual(inherited, 0, "The disclosure identifier must not replace its child slider identifier")
        XCTAssertTrue(weight.isHittable, "The expanded slider must remain reachable without blind scrolling")
        XCTAssertTrue(correctValue, "Both expansions must preserve the actual 60% location weight")
    }

    private func assertSettingsDebugOff(in form: XCUIElement) {
        let picker = app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch
        scrollTo(picker, in: form, swipeUp: false, expectingAbsent: settingsDebugElements)
        let refresh = app.buttons["refresh-library"]
        scrollTo(refresh, in: form, expectingAbsent: settingsDebugElements)
        XCTAssertEqual(refresh.label, "刷新索引统计")
        scrollTo(debugToggle, in: form, expectingAbsent: settingsDebugElements)
        XCTAssertEqual(app.switches.matching(identifier: "show-debug-tools").count, 1)
        expectSwitch(debugToggle, enabled: false)
    }

    private func assertUserLibrary(in form: XCUIElement) {
        XCTAssertTrue(app.navigationBars["我的图库"].exists)
        let details = app.descendants(matching: .any).matching(identifier: "debug-library-details").firstMatch
        let hidden = [details, app.buttons["详细信息"], debugToggle]
        scrollTo(app.buttons["authorize-photos"], in: form, swipeUp: false, expectingAbsent: hidden)
        let cloud = app.switches["icloud-download-opt-in"]
        scrollTo(cloud, in: form, expectingAbsent: hidden)
        expectSwitch(cloud, enabled: false)
        // Details would follow the iCloud footer; inspect that lower viewport too.
        form.swipeUp()
        for element in hidden { expectAbsent(element) }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func expectResultLimit(_ title: String, picker: XCUIElement) {
        // SwiftUI menu Picker exposes the selected title as its label or value.
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title), object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    private func typeExactly(_ text: String, into field: XCUIElement) {
        // Match SearchKeyboardTests: synchronize every key, never repair lost input.
        var expected = ""
        for character in text {
            field.typeText(String(character))
            expected.append(character)
            let entered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed)
        }
    }

    private func assertHomeControls(file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["photo-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        // No preparatory scroll gestures: the redesign must expose search at launch.
        XCTAssertTrue(field.isHittable, "Search must be visible without swiping", file: file, line: line)
        XCTAssertTrue(app.scrollViews["library-scroll"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["open-library"].isHittable, file: file, line: line)
        XCTAssertTrue(app.buttons["open-settings"].isHittable, file: file, line: line)
        XCTAssertFalse(app.sliders["location-weight"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["index-photos"].exists, file: file, line: line)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch.exists,
                       file: file, line: line)
        XCTAssertFalse(app.alerts.firstMatch.exists, file: file, line: line)
    }

    private func expectAbsent(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed, file: file, line: line)
    }

    private func expectHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed, file: file, line: line)
    }

    private func attach(_ id: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "UIReview-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}