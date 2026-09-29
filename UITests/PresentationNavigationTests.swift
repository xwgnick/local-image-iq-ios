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

    func testHomeAndUnauthorizedLibraryNavigation() {
        launch()
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
        done.tap()
        expectAbsent(done)
        expectHittable(app.textFields["photo-query"])
        assertHomeControls()
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
        // Production uses a menu Picker with 前3张 / 前12张, not a segmented
        // control. Check its stable identifier; do not guess private menu nodes.
        expectResultLimit("前3张", picker: picker)
        let form = try sheetForm()
        // debug-advanced identifies the Text label ONLY, not its parent button.
        let advanced = app.buttons["高级设置"]
        let weight = app.sliders["location-weight"]
        for element in settingsDebugElements { expectAbsent(element) }
        attach("settings-live")
        picker.tap()
        let topTwelve = app.buttons["前12张"]
        expectHittable(topTwelve)
        topTwelve.tap()
        expectResultLimit("前12张", picker: picker)

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
        expectResultLimit("前12张", picker: picker)
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
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
    }

    private var debugToggle: XCUIElement { app.switches["show-debug-tools"] }

    private var settingsDebugElements: [XCUIElement] {
        [app.descendants(matching: .any).matching(identifier: "debug-advanced").firstMatch,
         app.descendants(matching: .any).matching(identifier: "debug-diagnostics").firstMatch,
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