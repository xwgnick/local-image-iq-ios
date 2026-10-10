import XCTest

/// External AX evidence for the real app. Use the existing disposable-simulator
/// Photos-reset/startup contract; never authorize, import, search or index photos.
/// No fixtures, launch-time service replacement, or production test hooks.
@MainActor
final class SearchRootAccessibilityIntegrationTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRemovedLowerLeftFooterStaysAbsentWhileSubtitleNavigationAndModalAXRemainCorrect() throws {
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.resetAuthorizationStatus(for: .photos)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        waitForPreparedHome(app)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "authorization-required"),
            object: app.buttons["open-library"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        assertSearchRoot()
        assertRemovedFooter()
        let navigation = app.buttons["primary-search-tab"].frame
        XCTAssertGreaterThanOrEqual(navigation.height, 44)

        app.buttons["primary-cleanup-tab"].tap()
        expectAbsent(element("photo-query"))
        expectAbsent(element("photo-text-search-enabled"))
        XCTAssertTrue(app.buttons["primary-cleanup-tab"].isSelected)
        XCTAssertTrue(app.buttons["primary-search-tab"].isHittable)
        assertRemovedFooter()
        app.buttons["primary-search-tab"].tap()
        assertSearchRoot()
        XCTAssertEqual(app.buttons["primary-search-tab"].frame, navigation)

        app.buttons["photo-text-search-info"].tap()
        let closeInfo = app.buttons["close-photo-text-info"]
        XCTAssertTrue(closeInfo.waitForExistence(timeout: 5))
        XCTAssertTrue(closeInfo.isHittable)
        XCTAssertTrue(app.navigationBars["文本（ocr）增强搜索"].exists)
        assertCoveredRoot()
        closeInfo.tap()
        expectAbsent(closeInfo)
        assertSearchRoot()

        app.buttons["open-settings"].tap()
        let closeSettings = app.buttons["close-settings"]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 5))
        XCTAssertTrue(closeSettings.isHittable)
        XCTAssertTrue(app.navigationBars["设置"].exists)
        assertCoveredRoot()
        closeSettings.tap()
        expectAbsent(closeSettings)
        assertSearchRoot()
        XCTAssertEqual(app.buttons["primary-search-tab"].frame, navigation)
        assertRemovedFooter()
        XCTAssertEqual(app.buttons["open-library"].value as? String, "authorization-required")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    private func assertSearchRoot(file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["photo-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(field.isHittable, file: file, line: line)
        let subtitle = app.staticTexts["search-home-subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(subtitle.label, "选择照片，开始在本机搜索", file: file, line: line)
        XCTAssertEqual(app.staticTexts.matching(identifier: "search-home-subtitle").count, 1, file: file, line: line)
        XCTAssertTrue(app.buttons["photo-text-search-info"].isHittable, file: file, line: line)
        XCTAssertTrue(app.switches["photo-text-search-enabled"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["primary-search-tab"].isSelected, file: file, line: line)
        XCTAssertTrue(app.buttons["primary-cleanup-tab"].isHittable, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "primary-search-tab").count, 1, file: file, line: line)
        XCTAssertEqual(app.buttons.matching(identifier: "primary-cleanup-tab").count, 1, file: file, line: line)
        // Without a completed query the magnifier is decorative, not an empty
        // menu or an ellipsis control competing with text selection.
        let menu = element("search-query-menu")
        let menuExists = menu.exists
        if menuExists {
            attachAccessibilityFailure("Search root exposes search-query-menu before a completed query", element: menu)
        }
        XCTAssertFalse(menuExists, "The decorative icon must not expose a query-menu AX element", file: file, line: line)
    }

    private func assertCoveredRoot(file: StaticString = #filePath, line: UInt = #line) {
        for id in ["photo-query", "photo-text-search-enabled", "photo-text-search-info",
                   "search-query-menu", "primary-search-tab", "primary-cleanup-tab"] {
            expectAbsent(element(id), file: file, line: line)
        }
        assertRemovedFooter(file: file, line: line)
    }

    private func assertRemovedFooter(file: StaticString = #filePath, line: UInt = #line) {
        // Strict exists/count checks, not merely offscreen or not hittable.
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "library-status").count, 0,
                       "Only the obsolete lower-left status footer is removed", file: file, line: line)
        XCTAssertFalse(app.staticTexts["已选 0 张"].exists, file: file, line: line)
        for id in ["select-visible-results", "cancel-ocr-sync", "ocr-sync-open-details"] {
            XCTAssertFalse(element(id).exists, file: file, line: line)
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func expectAbsent(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        let result = XCTWaiter.wait(for: [gone], timeout: 5)
        if result != .completed {
            attachAccessibilityFailure("Expected root element to leave the AX tree", element: element)
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func attachAccessibilityFailure(_ message: String, element: XCUIElement) {
        // Keep the exact matched element and complete tree: a sheet's same-label
        // text must not be mistaken for the underlying root without evidence.
        let hierarchy = XCTAttachment(string: "\(message)\n\nMatched query:\n\(element.debugDescription)\n\nApplication:\n\(app.debugDescription)")
        hierarchy.name = "Search-root-accessibility-failure"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Search-root-accessibility-failure-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}