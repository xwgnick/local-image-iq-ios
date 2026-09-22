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
            predicate: NSPredicate(format: "label CONTAINS %@", "Connect your photos"),
            object: app.buttons["open-library"])
        XCTAssertEqual(XCTWaiter.wait(for: [libraryReady], timeout: 15), .completed,
                       "Capture the settled unauthorized home, not a transient library refresh")
        attach("home-live")

        app.buttons["open-library"].tap()
        let done = app.buttons["close-library"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        XCTAssertTrue(app.navigationBars["Library"].exists)
        XCTAssertTrue(app.buttons["authorize-photos"].waitForExistence(timeout: 5),
                      "The library must remain unauthorized; do not tap Choose photos")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        attach("library-live")
        done.tap()
        expectAbsent(done)
        expectHittable(app.textFields["photo-query"])
        assertHomeControls()
    }

    func testClearQueryKeepsKeyboardAndSettingsAdvancedStartsCollapsed() {
        launch()
        assertHomeControls()
        let field = app.textFields["photo-query"]
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText("TEST FIXTURE coast")
        let clear = app.buttons["clear-query"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        expectAbsent(clear)
        // UITextField exposes its placeholder as value when empty on some iOS
        // versions. Do not mistake that accessibility representation for a query.
        let value = field.value as? String
        XCTAssertTrue(value == "" || value == field.placeholderValue)
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Clear must retain search focus")
        let keyboardDone = app.buttons["keyboard-done"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 5))
        keyboardDone.tap()
        expectAbsent(app.keyboards.firstMatch)
        XCTAssertFalse(app.buttons["hide-search-keyboard"].exists)

        app.buttons["open-settings"].tap()
        let done = app.buttons["close-settings"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        let picker = app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        // Production uses a menu Picker with Top 3 / Top 12, not a segmented
        // control. Check its stable identifier; do not guess private menu nodes.
        let advanced = app.buttons["Advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 5))
        let weight = app.sliders["location-weight"]
        XCTAssertFalse(weight.exists, "Advanced must start collapsed")
        attach("settings-live")
        advanced.tap()
        XCTAssertTrue(weight.waitForExistence(timeout: 5), "Expanding Advanced reveals the actual slider")
        advanced.tap()
        expectAbsent(weight)
        done.tap()
        expectAbsent(done)
        expectHittable(field)
        assertHomeControls()
    }

    func testLargeFontSettingsCanBeDismissed() {
        launch(largeText: true)
        let settings = app.buttons["open-settings"]
        expectHittable(settings)
        settings.tap()
        let done = app.buttons["close-settings"]
        expectHittable(done)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "result-limit").firstMatch
            .waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["location-weight"].exists)
        attach("settings-live-accessibility-large")
        done.tap()
        expectAbsent(done)
        expectHittable(settings)
    }

    private func launch(largeText: Bool = false) {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName",
                               largeText ? "UICTContentSizeCategoryAccessibilityL" : "UICTContentSizeCategoryL"]
        app.resetAuthorizationStatus(for: .photos)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
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