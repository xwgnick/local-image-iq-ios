import XCTest

/// Drives the actual app, with no private photos, test login, fake index or model substitute.
/// These tests validate keyboard interactions even when search is not yet available.
@MainActor
final class SearchKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    private func focusQuery(_ query: String = "dog eat my apple pen") -> XCUIElement {
        let field = app.textFields["photo-query"]
        let scroll = app.scrollViews["library-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        // Bounded gestures only in a test, not an app indexing/library limit.
        for _ in 0..<12 {
            if field.exists && field.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(field.exists && field.isHittable, "Search input must be reachable")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // Synchronize each injected key with the actual field value. This also
        // distinguishes typing loss from mutation by Search/Done; never repair
        // the query, retry missing keys, or relax the post-dismissal assertion.
        var expected = ""
        for character in query {
            field.typeText(String(character))
            expected.append(character)
            let entered = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", expected), object: field)
            XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 5), .completed,
                           "Input must contain every typed character before dismissal")
        }
        return field
    }

    private func expectKeyboardHidden(file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }

    func testKeyboardSearchSubmitsAndDismissesWithoutClearingQuery() {
        let field = focusQuery()
        let search = app.keyboards.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        expectKeyboardHidden()
        XCTAssertEqual(field.value as? String, "dog eat my apple pen")
        XCTAssertFalse(app.buttons["hide-search-keyboard"].exists)
    }

    func testKeyboardDoneDismissesAndInputCanBeFocusedAgain() {
        let field = focusQuery()
        let done = app.buttons["keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        expectKeyboardHidden()
        XCTAssertEqual(field.value as? String, "dog eat my apple pen")
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["hide-search-keyboard"].tap()
        expectKeyboardHidden()
    }

    func testNavigationDoneDismissesWithoutSearch() {
        let field = focusQuery("query not submitted")
        app.buttons["hide-search-keyboard"].tap()
        expectKeyboardHidden()
        XCTAssertEqual(field.value as? String, "query not submitted")
    }

    func testDraggingScrollViewDismissesKeyboard() {
        _ = focusQuery()
        let scroll = app.scrollViews["library-scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.95))
        start.press(forDuration: 0.1, thenDragTo: end)
        expectKeyboardHidden()
    }
}