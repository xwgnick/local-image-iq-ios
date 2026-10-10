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
            predicate: NSPredicate(format: "value == %@", "authorization-required"),
            object: app.buttons["open-library"])
        XCTAssertEqual(XCTWaiter.wait(for: [libraryReady], timeout: 15), .completed,
                       "Capture the settled unauthorized home, not a transient library refresh")
        attach("home-live")

        app.buttons["open-library"].tap()
        let done = app.buttons["close-library"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertEqual(done.label, "完成")
        assertLibraryPrimary()
        attach("library-live")
        openLibraryPage("library-photo-access", title: "照片访问")
        XCTAssertTrue(app.buttons["authorize-photos"].waitForExistence(timeout: 5),
                  "The library must remain unauthorized; do not tap 选择照片")
        XCTAssertEqual(app.buttons["authorize-photos"].label, "选择照片")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        back(from: "照片访问", to: "我的图库")
        assertLibraryPrimary()
        openLibraryPage("library-maintenance", title: "索引维护")
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
        back(from: "索引维护", to: "我的图库")
        assertLibraryPrimary()
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
            predicate: NSPredicate(format: "value == %@", "authorization-required"), object: library)
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
            XCTAssertTrue(library.label.contains("我的图库"))
            XCTAssertFalse(library.label.contains("正在更新索引"))
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
        }

        library.tap()
        let done = app.buttons["close-library"]
        expectHittable(done)
        // This action exists only for .notDetermined, not denied/authorized.
        // Inspect it without tapping; opening/clearing filters must not prompt.
        assertLibraryPrimary()
        openLibraryPage("library-photo-access", title: "照片访问")
        expectHittable(app.buttons["authorize-photos"])
        back(from: "照片访问", to: "我的图库")
        openLibraryPage("library-maintenance", title: "索引维护")
        let update = app.buttons["index-photos"]
        scrollTo(update, in: try sheetForm(), allowDisabled: true)
        XCTAssertEqual(update.label, "建立索引")
        XCTAssertFalse(update.isEnabled)
        XCTAssertFalse(app.buttons["stop-indexing"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        back(from: "索引维护", to: "我的图库")
        assertLibraryPrimary()
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
        assertSettingsPrimary()
        attach("settings-live")
        openSettingsPage("settings-advanced", title: "高级")
        let form = try sheetForm()
        // debug-advanced identifies the Text label ONLY, not its parent button.
        let advanced = app.buttons["高级设置"]
        let weight = app.sliders["location-weight"]
        for element in settingsDebugElements { expectAbsent(element) }
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
        setDebugTools(true, in: form)
        scrollTo(advanced, in: form)
        expectAbsent(weight)
        tapDisclosure(advanced)
        expectExpandedWeight(weight)
        setDebugTools(false, in: form)
        assertSettingsDebugOff(in: form)
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
        done.tap()
        expectAbsent(done)
        expectHittable(field)
        XCTAssertEqual(field.value as? String, preservedQuery)
        assertHomeControls()

        // Reopening must keep debug OFF and never resurrect the removed batch UI.
        // The internal page size of 12 is checked in the hosted state tests.
        app.buttons["open-settings"].tap()
        expectHittable(done)
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        assertSettingsDebugOff(in: try sheetForm())
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
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
        assertSettingsPrimary()
        XCTAssertFalse(app.sliders["location-weight"].exists)
        attach("settings-live-accessibility-large")
        openSettingsPage("settings-advanced", title: "高级")
        expectHittable(debugToggle)
        expectSwitch(debugToggle, enabled: false)
        for element in settingsDebugElements { expectAbsent(element) }
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
        done.tap()
        expectAbsent(done)
        expectHittable(settings)
    }

    func testOneGlobalDebugToggleStartsOffAndResetsOnRelaunch() throws {
        launch()
        app.buttons["open-library"].tap()
        let libraryDone = app.buttons["close-library"]
        expectHittable(libraryDone)
        try assertUserLibrary()
        libraryDone.tap()
        expectAbsent(libraryDone)

        app.buttons["open-settings"].tap()
        let settingsDone = app.buttons["close-settings"]
        expectHittable(settingsDone)
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        let settingsForm = try sheetForm()
        assertSettingsDebugOff(in: settingsForm)
        setDebugTools(true, in: settingsForm)
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
        settingsDone.tap()
        expectAbsent(settingsDone)

        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        assertLibraryPrimary()
        openLibraryPage("library-photo-access", title: "照片访问")
        XCTAssertTrue(app.buttons["authorize-photos"].waitForExistence(timeout: 5))
        back(from: "照片访问", to: "我的图库")
        openLibraryPage("library-maintenance", title: "索引维护")
        let details = app.buttons["详细信息"]
        scrollTo(details, in: try sheetForm())
        XCTAssertFalse(debugToggle.exists, "Library uses the single Settings toggle, not a second switch")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        back(from: "索引维护", to: "我的图库")
        assertLibraryPrimary()
        libraryDone.tap()
        expectAbsent(libraryDone)

        app.buttons["open-settings"].tap()
        expectHittable(settingsDone)
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
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
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        assertSettingsDebugOff(in: try sheetForm())
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
        settingsDone.tap()
        expectAbsent(settingsDone)

        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        try assertUserLibrary()
        libraryDone.tap()
        expectAbsent(libraryDone)
        assertHomeControls()
    }

    func testChineseTranslationControlsRemainAccessibleWithDebugToolsOff() throws {
        launch()
        app.buttons["open-settings"].tap()
        let done = app.buttons["close-settings"]
        expectHittable(done)
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        assertSettingsDebugOff(in: try sheetForm())
        back(from: "高级", to: "设置")
        openSettingsPage("settings-translation", title: "搜索增强")
        let form = try sheetForm()
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
        for element in settingsDebugElements { expectAbsent(element) }
        XCTAssertFalse(debugToggle.exists, "Translation has no duplicate debug switch")
        back(from: "搜索增强", to: "设置")
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        assertSettingsDebugOff(in: try sheetForm())
        back(from: "高级", to: "设置")
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
        assertSettingsPrimary()
        openSettingsPage("settings-advanced", title: "高级")
        let form = try sheetForm()
        assertSettingsDebugOff(in: form)
        setDebugTools(true, in: form)
        let diagnostics = app.buttons["诊断信息"]
        scrollTo(diagnostics, in: form, swipeUp: false)
        let link = app.buttons["debug-launch-timing"]
        XCTAssertFalse(link.exists, "The link belongs inside the initially collapsed diagnostics group")
        tapDisclosure(diagnostics)
        let reference = app.switches["reference-search-enabled"]
        scrollTo(reference, in: form)
        XCTAssertTrue(reference.isEnabled)
        expectSwitch(reference, enabled: false)
        let searchTiming = app.buttons["debug-search-timing"]
        scrollTo(searchTiming, in: form, swipeUp: false)
        XCTAssertEqual(searchTiming.label, "搜索耗时")
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
        let timingBack = app.navigationBars["启动耗时"].buttons.element(boundBy: 0)
        expectHittable(timingBack)
        timingBack.tap()
        expectAbsent(page)
        XCTAssertTrue(app.navigationBars["高级"].exists)
        assertNoBatchControls()
        scrollTo(reference, in: try sheetForm(), swipeUp: false)
        expectSwitch(reference, enabled: false)
        setDebugTools(false, in: try sheetForm())
        assertSettingsDebugOff(in: try sheetForm())
        back(from: "高级", to: "设置")
        assertSettingsPrimary()
        app.buttons["close-settings"].tap()
        assertHomeControls()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testPhotoTextToggleDefersWithoutPermissionAndHasNoInlineMaintenanceButton() throws {
        if ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"] == "0" {
            throw XCTSkip("Live photo text opt-in requires the real bundled models")
        }
        launch()
        assertHomeControls()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let toggle = app.switches["photo-text-search-enabled"]
        let update = app.buttons["index-photo-text"]
        let done = app.buttons["close-settings"]
        let libraryDone = app.buttons["close-library"]

        func assertNoWorkOrPermissionPrompt() {
            XCTAssertFalse(app.buttons["pause-text-index"].exists)
            XCTAssertFalse(app.buttons["stop-indexing"].exists)
            XCTAssertFalse(app.progressIndicators["文字索引进度"].exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
        }

        func assertHomeOptIn() {
            let library = app.buttons["open-library"]
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "authorization-required"), object: library)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
            assertNoWorkOrPermissionPrompt()
            expectHittable(toggle)
            XCTAssertEqual(app.switches.matching(identifier: "photo-text-search-enabled").count, 1)
            XCTAssertTrue(toggle.isEnabled, "The optional preference must not require Photos permission")
            XCTAssertEqual(toggle.label, "文本（ocr）增强搜索")
            let info = app.buttons["photo-text-search-info"]
            expectHittable(info)
            XCTAssertEqual(info.label, "文本（ocr）增强搜索介绍")
            XCTAssertGreaterThanOrEqual(info.frame.width, 44)
            XCTAssertGreaterThanOrEqual(info.frame.height, 44)
            XCTAssertLessThanOrEqual(info.frame.maxX, toggle.frame.minX,
                                     "The independent information button precedes the native switch")
            XCTAssertTrue(app.frame.contains(info.frame))
            XCTAssertFalse(app.staticTexts["photo-text-search-explanation"].exists)
            XCTAssertFalse(app.staticTexts["用照片里的文字进行搜索"].exists)
            assertNoBatchControls()
        }

        func tapOptIn(_ enabled: Bool) {
            expectHittable(toggle)
            expectSwitch(toggle, enabled: !enabled)
            // The identifier now belongs only to the unscaled native switch,
            // not a Form row containing the label or the explanation.
            toggle.tap()
            expectSwitch(toggle, enabled: enabled)
            assertNoWorkOrPermissionPrompt()
        }

        // Restore the persisted preference through the real home control only.
        defer {
            if app.state == .runningForeground,
               !app.alerts.firstMatch.exists, !springboard.alerts.firstMatch.exists {
                if done.exists && done.isHittable { done.tap(); expectAbsent(done) }
                if libraryDone.exists && libraryDone.isHittable { libraryDone.tap(); expectAbsent(libraryDone) }
                if toggle.exists && toggle.isHittable && toggle.value as? String == "1" { tapOptIn(false) }
            }
        }

        assertHomeOptIn()
        let initialValue = try XCTUnwrap(toggle.value as? String)
        XCTAssertTrue(initialValue == "0" || initialValue == "1", "Read the actual switch before recovering a prior crash")
        if initialValue == "1" { tapOptIn(false) }
        expectSwitch(toggle, enabled: false)
        expectAbsent(update)
        assertNoWorkOrPermissionPrompt()

        app.buttons["photo-text-search-info"].tap()
        let infoDone = app.buttons["close-photo-text-info"]
        expectHittable(infoDone)
        XCTAssertTrue(app.navigationBars["文本（ocr）增强搜索"].exists)
        expectAbsent(toggle)
        expectAbsent(update)
        assertNoBatchControls()
        assertNoWorkOrPermissionPrompt()
        infoDone.tap()
        expectAbsent(infoDone)
        assertHomeOptIn()
        expectSwitch(toggle, enabled: false)

        tapOptIn(true)
        expectAbsent(update)
        XCTAssertFalse(app.progressIndicators["ocr-sync-progress"].exists,
                   "The requested update waits for permission; it cannot invent processing progress")
        assertNoWorkOrPermissionPrompt()

        app.buttons["primary-cleanup-tab"].tap()
        expectAbsent(toggle)
        XCTAssertFalse(update.exists, "Neither primary page exposes an inline OCR maintenance action")
        app.buttons["primary-search-tab"].tap()
        assertHomeOptIn()
        expectSwitch(toggle, enabled: true)
        app.buttons["open-settings"].tap()
        expectHittable(done)
        assertSettingsPrimary()
        XCTAssertFalse(toggle.exists, "Settings must not duplicate the home OCR opt-in")
        XCTAssertFalse(update.exists, "Text index management now belongs to Library, not Settings")
        openSettingsPage("settings-privacy", title: "隐私与关于")
        let localPrivacy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "可选文字搜索使用系统 Vision")).firstMatch
        scrollTo(localPrivacy, in: try sheetForm())
        XCTAssertTrue(localPrivacy.label.contains("关闭增强只停止参与搜索"))
        XCTAssertTrue(localPrivacy.label.contains("清除索引才会一并删除文字记录"))
        assertNoWorkOrPermissionPrompt()
        back(from: "隐私与关于", to: "设置")
        assertSettingsPrimary()
        done.tap()
        expectAbsent(done)

        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        assertLibraryPrimary()
        openLibraryPage("library-text-index", title: "文本索引")
        var form = try sheetForm()
        XCTAssertFalse(toggle.exists, "Management never duplicates the primary opt-in")
        scrollTo(update, in: form, allowDisabled: true)
        XCTAssertFalse(update.isEnabled)
        // Check production privacy text via the real XCUI tree, not in-process
        // SwiftUI AX or a copied presentation fixture. Match stable fragments.
        let privacy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "识别文字仅保存在本机")).firstMatch
        scrollTo(privacy, in: form)
        for fragment in ["不参与备份", "不代表当前有权限搜索", "关闭增强不会删除", "清除索引会一起删除"] {
            XCTAssertTrue(privacy.label.contains(fragment))
        }
        assertNoWorkOrPermissionPrompt()
        back(from: "文本索引", to: "我的图库")
        assertLibraryPrimary()
        libraryDone.tap()
        expectAbsent(libraryDone)

        // ON is a real persisted preference, unlike session-only debug tools.
        // Relaunch through the unchanged full-model readiness/Photos-reset helper.
        app.terminate()
        launch()
        assertHomeControls()
        assertHomeOptIn()
        expectSwitch(toggle, enabled: true)
        expectAbsent(update)
        XCTAssertFalse(app.buttons["ocr-sync-open-details"].exists,
                   "Restoring saved ON is not a new update request")
        assertNoWorkOrPermissionPrompt()
        tapOptIn(false)
        expectAbsent(update)
        assertHomeControls()

        // OFF keeps the saved-count/privacy management and disables its action.
        app.buttons["open-library"].tap()
        expectHittable(libraryDone)
        assertLibraryPrimary()
        openLibraryPage("library-text-index", title: "文本索引")
        form = try sheetForm()
        XCTAssertFalse(toggle.exists)
        scrollTo(update, in: form, allowDisabled: true)
        XCTAssertFalse(update.isEnabled)
        scrollTo(privacy, in: form)
        XCTAssertTrue(privacy.label.contains("关闭增强不会删除"))
        assertNoWorkOrPermissionPrompt()
        back(from: "文本索引", to: "我的图库")
        openLibraryPage("library-photo-access", title: "照片访问")
        // This action is specific to .notDetermined; never tap it.
        expectHittable(app.buttons["authorize-photos"])
        assertNoWorkOrPermissionPrompt()
        back(from: "照片访问", to: "我的图库")
        assertLibraryPrimary()
        libraryDone.tap()
        expectAbsent(libraryDone)
        assertHomeControls()
        expectSwitch(toggle, enabled: false)
        XCTAssertEqual(app.buttons["open-library"].value as? String, "authorization-required")
    }

    func testPrimaryCleanupDraftDisclosureAndSettingsIsolationWithoutPermission() throws {
        // This case explicitly stays unauthorized and asserts NO grouping work.
        // It can validate controls model-free; launch() still forbids recovery
        // bypass in model-required release runs. This is not model readiness.
        launch()
        assertHomeControls()
        let library = app.buttons["open-library"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "authorization-required"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists)

        let field = app.textFields["photo-query"]
        let query = "TEST coast"
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        typeExactly(query, into: field)
        let keyboardDone = app.buttons["keyboard-done"]
        expectHittable(keyboardDone)
        keyboardDone.tap()
        expectAbsent(app.keyboards.firstMatch)
        let entry = app.buttons["primary-cleanup-tab"]
        expectHittable(entry)
        entry.tap()

        XCTAssertTrue(app.navigationBars["相似清理"].waitForExistence(timeout: 5))
        expectAbsent(field)
        XCTAssertFalse(field.isHittable)
        XCTAssertTrue(entry.isSelected)
        XCTAssertFalse(app.buttons["close-similar-cleanup"].exists)
        let threshold = app.sliders["similar-cleanup-threshold"]
        let disclosure = app.buttons["similar-cleanup-threshold-disclosure"]
        let thresholdTitle = app.staticTexts["组内照片相似度"]
        XCTAssertFalse(threshold.exists, "The production cleanup threshold starts collapsed")
        XCTAssertFalse(thresholdTitle.exists)
        expectHittable(disclosure)
        XCTAssertEqual(disclosure.label, "展开清理设置")
        XCTAssertEqual(disclosure.value as? String, "已收起")
        let start = app.buttons["start-similar-grouping"]

        func assertNoWorkOrPrompt() {
            XCTAssertFalse(app.buttons["cancel-similar-grouping"].exists)
            XCTAssertFalse(app.buttons["prepare-similar-deletion"].exists)
            XCTAssertFalse(app.progressIndicators["分组进度"].exists)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "similar-cleanup-restoring").firstMatch.exists)
            XCTAssertFalse(app.buttons["stop-indexing"].exists)
            XCTAssertFalse(app.buttons["pause-text-index"].exists)
            XCTAssertFalse(app.progressIndicators["文字索引进度"].exists)
            XCTAssertFalse(app.alerts.firstMatch.exists)
            XCTAssertFalse(springboard.alerts.firstMatch.exists)
        }

        func assertUnreadyCleanup() {
            XCTAssertFalse(start.exists, "Production cleanup does not require an everyday Update Results button")
            XCTAssertFalse(app.buttons["retry-similar-grouping"].exists)
            XCTAssertTrue(app.staticTexts["similar-cleanup-state"].exists)
            XCTAssertEqual(app.staticTexts["similar-cleanup-state"].label, "请先允许照片访问")
            XCTAssertFalse(field.exists, "The retained search query must stay outside cleanup's AX scope")
            assertNoWorkOrPrompt()
        }

        func expectThreshold(_ expected: Double) {
            // Production supplies a decimal accessibilityValue, not a slider
            // percentage. Accept either .99 or 0.99 without matching private nodes.
            let value = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                guard let slider = object as? XCUIElement, let text = slider.value as? String,
                      let number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return false }
                return abs(number - expected) < 0.0001
            }, object: threshold)
            XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed,
                           "Expected \(expected), got \(threshold.value ?? "nil"); frame=\(threshold.frame)")
        }

        func dragThreshold(from startValue: Double, to endValue: Double) {
            // The native thumb's center stays half its height inside the AX
            // rectangle. The recorded gesture starting at x == frame.maxX
            // left the value at .99; use the inset center instead of that edge.
            let frame = threshold.frame
            let radius = frame.height / 2
            let travel = frame.width - 2 * radius
            let origin = threshold.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            func thumbCenter(_ value: Double) -> XCUICoordinate {
                let fraction = CGFloat((value * 100 - 50) / 49)
                return origin.withOffset(CGVector(dx: radius + fraction * travel,
                                                   dy: frame.height / 2))
            }
            // Once the thumb is captured, end at the track's outside edge so
            // the native touch-to-thumb offset cannot leave it one tick short.
            // An inset-to-inset drag reached .51 rather than the asserted .50.
            let end = endValue == 0.50
                ? origin.withOffset(CGVector(dx: 0, dy: frame.height / 2))
                : endValue == 0.99
                    ? origin.withOffset(CGVector(dx: frame.width, dy: frame.height / 2))
                    : thumbCenter(endValue)
            thumbCenter(startValue).press(forDuration: 0.1, thenDragTo: end)
        }

        XCTAssertTrue(app.staticTexts["清理设置"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["相似度"].exists, "Slider labels belong inside the collapsed settings")
        XCTAssertFalse(app.staticTexts["找出相近的照片，方便挑选和清理。"].exists)
        XCTAssertFalse(app.staticTexts["可手动调节组内照片相似度的严格程度。"].exists)
        assertUnreadyCleanup()
        disclosure.tap()
        expectHittable(threshold)
        expectHittable(thresholdTitle)
        XCTAssertEqual(disclosure.label, "收起清理设置")
        XCTAssertEqual(disclosure.value as? String, "已展开")
        XCTAssertTrue(threshold.isEnabled)
        // Existing valid saved preferences survive an upgrade; don't overwrite
        // them or assume the previous .90 default. New-state .95 is tested natively.
        let appliedText = try XCTUnwrap(threshold.value as? String)
        let appliedThreshold = try XCTUnwrap(Double(appliedText.replacingOccurrences(of: ",", with: ".")))
        XCTAssertTrue((0.50...0.99).contains(appliedThreshold))
        expectThreshold(appliedThreshold)
        dragThreshold(from: appliedThreshold, to: 0.99)
        expectThreshold(0.99)
        assertUnreadyCleanup()
        dragThreshold(from: 0.99, to: 0.50)
        expectThreshold(0.50)
        expectHittable(app.staticTexts["similar-cleanup-broad-threshold-note"])
        assertUnreadyCleanup()
        disclosure.tap()
        expectAbsent(threshold)
        expectAbsent(app.staticTexts["similar-cleanup-broad-threshold-note"])
        assertUnreadyCleanup()
        disclosure.tap()
        expectHittable(threshold)
        expectHittable(app.staticTexts["similar-cleanup-broad-threshold-note"])
        // Reopen and move to the strict endpoint. Interior touch positions are
        // approximate even through XCTest's normalized API (observed .94/.96
        // for requested .95). Exact .95 default and all ticks are separately
        // asserted by native controls/policy tests; this case tests real drag,
        // collapsed warning and retained unauthorized-page behavior.
        dragThreshold(from: 0.50, to: 0.99)
        expectThreshold(0.99)
        expectAbsent(app.staticTexts["similar-cleanup-broad-threshold-note"])
        assertUnreadyCleanup()

        // Release a NON-default target to distinguish retention/queued work
        // from applied preferences. Missing authorization must not admit it.
        let pendingThreshold = appliedThreshold == 0.99 ? 0.50 : 0.99
        dragThreshold(from: 0.99, to: pendingThreshold)
        expectThreshold(pendingThreshold)
        disclosure.tap()
        expectAbsent(threshold)
        expectAbsent(thresholdTitle)
        assertUnreadyCleanup()
        disclosure.tap()
        expectHittable(threshold)
        expectThreshold(pendingThreshold)

        let done = app.buttons["close-settings"]
        let hiddenInSettings = [field, threshold, thresholdTitle, disclosure, start,
            app.buttons["primary-search-tab"], entry,
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "相似度阈值")).firstMatch]
        func assertSettingsExcludesBothPageScopes() throws {
            expectHittable(done)
            assertSettingsPrimary()
            for element in hiddenInSettings { expectAbsent(element) }
            // Check the actual secondary page as well as the primary scope.
            openSettingsPage("settings-advanced", title: "高级")
            scrollTo(debugToggle, in: try sheetForm(), expectingAbsent: hiddenInSettings)
            assertSettingsDebugOff(in: try sheetForm())
            back(from: "高级", to: "设置")
            assertSettingsPrimary()
            for element in hiddenInSettings { expectAbsent(element) }
            assertNoWorkOrPrompt()
        }

        // Cleanup's header presents Settings, but Settings owns no threshold.
        app.buttons["open-settings"].tap()
        try assertSettingsExcludesBothPageScopes()
        done.tap()
        expectAbsent(done)
        expectHittable(threshold)
        expectThreshold(pendingThreshold)
        assertUnreadyCleanup()

        app.buttons["primary-search-tab"].tap()
        expectHittable(field)
        XCTAssertEqual(field.value as? String, query)
        assertHomeControls()
        expectAbsent(disclosure)
        expectAbsent(thresholdTitle)
        expectAbsent(start)
        app.buttons["open-settings"].tap()
        try assertSettingsExcludesBothPageScopes()
        done.tap()
        expectAbsent(done)
        expectHittable(field)
        XCTAssertEqual(field.value as? String, query)
        entry.tap()
        expectHittable(threshold)
        expectThreshold(pendingThreshold)
        assertUnreadyCleanup()

        // A retained tab/sheet preserves the queued target, but a new process
        // restores only the actual applied preference, not the unready target.
        app.terminate()
        launch()
        assertHomeControls()
        let relaunchedReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "authorization-required"), object: library)
        XCTAssertEqual(XCTWaiter.wait(for: [relaunchedReady], timeout: 15), .completed)
        entry.tap()
        XCTAssertTrue(app.navigationBars["相似清理"].waitForExistence(timeout: 5))
        expectAbsent(threshold)
        expectAbsent(thresholdTitle)
        expectHittable(disclosure)
        assertUnreadyCleanup()
        disclosure.tap()
        expectHittable(threshold)
        expectThreshold(appliedThreshold)
        assertUnreadyCleanup()
        app.buttons["primary-search-tab"].tap()
        assertHomeControls()
        XCTAssertEqual(library.value as? String, "authorization-required")
        assertNoWorkOrPrompt()
    }

    func testPhysicalCleanupEdgeReturnCancelsShortDragAndPreservesMidGridRangeSelection() throws {
        app.launchEnvironment["IMAGEIQ_CLEANUP_NAVIGATION_FIXTURE"] = "1"
        defer { app.launchEnvironment.removeValue(forKey: "IMAGEIQ_CLEANUP_NAVIGATION_FIXTURE") }
        launch()
        app.buttons["primary-cleanup-tab"].tap()
        let cover = app.buttons["similar-cleanup-group-1-photo-176"]
        expectHittable(cover)
        cover.tap()
        let grid = app.collectionViews["similar-cleanup-five-column-grid"]
        expectHittable(grid)
        func photo(_ number: Int) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "similar-cleanup-detail-photo-\(number)").firstMatch
        }
        let target = photo(176)
        expectHittable(target)
        XCTAssertTrue(grid.frame.contains(target.frame), "The tapped overview sample must be positioned in the detail")
        XCTAssertFalse(app.buttons["prepare-similar-deletion"].exists, "Opening never selects a photo")
        let mode = app.buttons["similar-cleanup-selection-mode"]
        expectHittable(mode)
        mode.tap()
        let first = photo(177)
        let last = photo(179)
        expectHittable(first)
        expectHittable(last)
        XCTAssertGreaterThan(first.frame.minX, grid.frame.minX + grid.frame.width / 5)
        // Real coordinate touch injection. This is not controller.beginInteraction
        // or an accessibility callback pretending to test gesture arbitration.
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        let status = app.staticTexts["similar-cleanup-selection-status"]
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已选3张"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 5), .completed)
        XCTAssertEqual(photo(177).value as? String, "已勾选待删除")
        XCTAssertEqual(photo(178).value as? String, "已勾选待删除")
        XCTAssertEqual(photo(179).value as? String, "已勾选待删除")
        XCTAssertEqual(target.value as? String, "未勾选")
        XCTAssertTrue(grid.exists, "A horizontal mid-grid range gesture must not dismiss detail")
        let delete = app.buttons["prepare-similar-deletion"]
        expectHittable(delete)
        XCTAssertEqual(delete.label, "删除3张") // Never activate or confirm deletion.
        let root = app.coordinate(withNormalizedOffset: .zero)
        let edge = root.withOffset(CGVector(dx: 1, dy: first.frame.midY))
        let short = root.withOffset(CGVector(dx: 60, dy: first.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: short, withVelocity: .slow, thenHoldForDuration: 0.3)
        expectHittable(grid)
        XCTAssertEqual(delete.label, "删除3张")
        XCTAssertEqual(photo(176).value as? String, "未勾选", "Edge motion must not start a range on the first column")
        let end = root.withOffset(CGVector(dx: app.frame.width * 0.8, dy: first.frame.midY))
        edge.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        expectAbsent(grid)
        expectAbsent(app.buttons["similar-cleanup-all-groups"])
        expectHittable(cover)
        XCTAssertEqual(delete.label, "删除3张", "The same selection footer remains on the overview")
        XCTAssertTrue(app.buttons["primary-cleanup-tab"].isSelected)
        XCTAssertFalse(app.textFields["photo-query"].exists)
        // Root has no fabricated back-to-search destination, even at the edge.
        let rootEdge = root.withOffset(CGVector(dx: 1, dy: app.frame.midY))
        rootEdge.press(forDuration: 0.05,
            thenDragTo: root.withOffset(CGVector(dx: app.frame.width * 0.8, dy: app.frame.midY)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(app.buttons["primary-cleanup-tab"].isSelected)
        XCTAssertFalse(app.textFields["photo-query"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    func testPhysicalCleanupEdgeReturnRestoresScrolledOverviewAndVisibleBackFallback() throws {
        app.launchEnvironment["IMAGEIQ_CLEANUP_NAVIGATION_FIXTURE"] = "1"
        defer { app.launchEnvironment.removeValue(forKey: "IMAGEIQ_CLEANUP_NAVIGATION_FIXTURE") }
        launch()
        app.buttons["primary-cleanup-tab"].tap()
        let overview = app.scrollViews["similar-cleanup-scroll"]
        expectHittable(app.buttons["similar-cleanup-group-1-header"])
        overview.swipeUp()
        // Pick a fully visible real cover at the new nonzero overview offset.
        let covers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "similar-cleanup-group-", "-header")).allElementsBoundByIndex
        let header = try XCTUnwrap(covers.first { $0.isHittable && overview.frame.contains($0.frame) })
        XCTAssertFalse(app.buttons["similar-cleanup-threshold-disclosure"].isHittable)
        let before = header.frame
        header.tap()
        let grid = app.collectionViews["similar-cleanup-five-column-grid"]
        expectHittable(grid)
        let back = app.buttons["similar-cleanup-all-groups"]
        expectHittable(back)
        let root = app.coordinate(withNormalizedOffset: .zero)
        root.withOffset(CGVector(dx: 1, dy: grid.frame.midY)).press(forDuration: 0.05,
            thenDragTo: root.withOffset(CGVector(dx: app.frame.width * 0.8, dy: grid.frame.midY)),
            withVelocity: .slow, thenHoldForDuration: 0.1)
        expectAbsent(grid)
        expectHittable(header)
        XCTAssertEqual(header.frame.minY, before.minY, accuracy: 1)
        XCTAssertEqual(header.frame.minX, before.minX, accuracy: 1)
        header.tap()
        expectHittable(grid)
        expectHittable(back)
        back.tap()
        expectAbsent(grid)
        expectHittable(header)
        XCTAssertEqual(header.frame.minY, before.minY, accuracy: 1)
        XCTAssertTrue(app.buttons["primary-cleanup-tab"].isSelected)
        XCTAssertFalse(app.buttons["prepare-similar-deletion"].exists)
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

    private func assertNoBatchControls(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch.exists,
                       "Page size remains internal; no primary or advanced batch control", file: file, line: line)
        for label in ["每批显示", "3张", "12张"] {
            XCTAssertFalse(app.buttons[label].exists, file: file, line: line)
            XCTAssertFalse(app.staticTexts[label].exists, file: file, line: line)
        }
    }

    private func assertSettingsPrimary() {
        XCTAssertTrue(app.navigationBars["设置"].exists)
        for id in ["settings-translation", "settings-privacy", "settings-advanced"] {
            expectHittable(app.buttons[id])
            XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
        }
        let cloud = app.switches["icloud-download-opt-in"]
        expectHittable(cloud)
        expectSwitch(cloud, enabled: false)
        for element in settingsDebugElements + [debugToggle, app.switches["chinese-search-enabled"],
                app.buttons["prepare-translation"], app.buttons["refresh-library"], app.buttons["clear-index"],
            app.buttons["index-photo-text"], app.buttons["clear-search-history"]] { expectAbsent(element) }
        assertNoBatchControls()
    }

    private func assertLibraryPrimary() {
        XCTAssertTrue(app.navigationBars["我的图库"].exists)
        for id in ["library-photo-access", "library-text-index", "library-maintenance"] {
            expectHittable(app.buttons[id])
            XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
        }
        expectHittable(app.staticTexts["stored-index-count"])
        expectHittable(app.staticTexts["library-auto-sync-status"])
        for id in ["authorize-photos", "index-photos", "rebuild-index", "index-photo-text", "clear-index", "refresh-library"] {
            XCTAssertFalse(app.buttons[id].exists, "Actions belong to the pushed page, not the primary Form")
        }
        XCTAssertFalse(debugToggle.exists)
        XCTAssertFalse(app.switches["icloud-download-opt-in"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "debug-library-details").firstMatch.exists)
        assertNoBatchControls()
    }

    private func openSettingsPage(_ identifier: String, title: String) {
        openPage(identifier, title: title, parent: "设置")
    }

    private func openLibraryPage(_ identifier: String, title: String) {
        openPage(identifier, title: title, parent: "我的图库")
    }

    private func openPage(_ identifier: String, title: String, parent: String) {
        XCTAssertTrue(app.navigationBars[parent].exists)
        let link = app.buttons[identifier]
        expectHittable(link)
        link.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        assertNoBatchControls()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func back(from title: String, to parent: String) {
        // UIKit's native leading back button; never a guessed Text ancestor.
        let button = app.navigationBars[title].buttons.element(boundBy: 0)
        expectHittable(button)
        button.tap()
        XCTAssertTrue(app.navigationBars[parent].waitForExistence(timeout: 5))
        assertNoBatchControls()
        XCTAssertFalse(app.alerts.firstMatch.exists)
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
            assertNoBatchControls(file: file, line: line)
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
        scrollTo(debugToggle, in: form, swipeUp: false)
        XCTAssertEqual(app.switches.matching(identifier: "show-debug-tools").count, 1)
        expectSwitch(debugToggle, enabled: !enabled)
        // The captured iOS AX hierarchy gives the identified SwiftUI switch the
        // FULL row frame, while its actual thumb is a separate 51-point switch
        // at the trailing edge. Tapping the row centre hit only the label and
        // left value=0; tap inside this exact identified row's thumb instead.
        debugToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        // The opt-in is now the first row of the Advanced destination. Return
        // toward the top after inspecting either expanded group below it.
        scrollTo(debugToggle, in: form, swipeUp: false)
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
        XCTAssertTrue(app.navigationBars["高级"].exists)
        assertNoBatchControls()
        scrollTo(debugToggle, in: form, swipeUp: false, expectingAbsent: settingsDebugElements)
        XCTAssertEqual(app.switches.matching(identifier: "show-debug-tools").count, 1)
        expectSwitch(debugToggle, enabled: false)
        form.swipeUp()
        for element in settingsDebugElements { expectAbsent(element) }
        XCTAssertFalse(app.switches["reference-search-enabled"].exists)
        XCTAssertFalse(app.buttons["debug-search-timing"].exists)
        assertNoBatchControls()
    }

    private func assertUserLibrary() throws {
        assertLibraryPrimary()
        let details = app.descendants(matching: .any).matching(identifier: "debug-library-details").firstMatch
        let hidden = [details, app.buttons["详细信息"], debugToggle]
        openLibraryPage("library-photo-access", title: "照片访问")
        scrollTo(app.buttons["authorize-photos"], in: try sheetForm(), expectingAbsent: hidden)
        back(from: "照片访问", to: "我的图库")
        openLibraryPage("library-text-index", title: "文本索引")
        let textUpdate = app.buttons["index-photo-text"]
        scrollTo(textUpdate, in: try sheetForm(), expectingAbsent: hidden, allowDisabled: true)
        XCTAssertFalse(textUpdate.isEnabled)
        back(from: "文本索引", to: "我的图库")
        openLibraryPage("library-maintenance", title: "索引维护")
        let form = try sheetForm()
        for id in ["index-photos", "rebuild-index"] {
            let action = app.buttons[id]
            scrollTo(action, in: form, expectingAbsent: hidden, allowDisabled: true)
            XCTAssertFalse(action.isEnabled)
        }
        let refresh = app.buttons["refresh-library"]
        scrollTo(refresh, in: form, expectingAbsent: hidden)
        XCTAssertEqual(refresh.label, "刷新索引统计")
        scrollTo(app.buttons["clear-index"], in: form, expectingAbsent: hidden)
        form.swipeUp()
        for element in hidden { expectAbsent(element) }
        assertNoBatchControls()
        XCTAssertFalse(app.buttons["confirm-clear-index"].exists)
        XCTAssertFalse(app.buttons["confirm-rebuild-index"].exists)
        back(from: "索引维护", to: "我的图库")
        assertLibraryPrimary()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
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
        XCTAssertEqual(app.buttons.matching(identifier: "open-library").count, 1, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "open-settings").count, 1, file: file, line: line)
        let search = app.buttons["primary-search-tab"]
        let cleanup = app.buttons["primary-cleanup-tab"]
        XCTAssertTrue(search.isHittable && cleanup.isHittable, file: file, line: line)
        XCTAssertTrue(search.isSelected, file: file, line: line)
        XCTAssertEqual(search.label, "照片搜索", file: file, line: line)
        XCTAssertEqual(cleanup.label, "相似清理", file: file, line: line)
        XCTAssertEqual(search.frame.width, cleanup.frame.width, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(search.frame.height, 44, file: file, line: line)
        XCTAssertGreaterThanOrEqual(cleanup.frame.height, 44, file: file, line: line)
        XCTAssertFalse(app.buttons["open-similar-cleanup"].exists, file: file, line: line)
        XCTAssertFalse(app.sliders["similar-cleanup-threshold"].exists, file: file, line: line)
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