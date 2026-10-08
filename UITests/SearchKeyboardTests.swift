import XCTest

/// Drives the actual app, with no private photos, test login, fake index or model substitute.
/// These tests validate keyboard interactions even when search is not yet available.
@MainActor
final class SearchKeyboardTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Intentionally use the English system keyboard and fixtures so Apple's
        // Search key keeps its known layout. App copy is hardcoded Chinese by
        // design; this does not claim the app follows the system language.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        app.launch()
        waitForPreparedHome(app)
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

    func testLibraryHeaderDismissesKeyboardAndPreservesQueryOnReturn() {
        let field = focusQuery("TEST FIXTURE library")
        let library = app.buttons["open-library"]
        XCTAssertTrue(library.exists && library.isHittable,
                      "The library header must remain reachable while typing")
        XCTAssertEqual(app.buttons.matching(identifier: "open-library").count, 1)
        XCTAssertTrue(library.label.contains("我的图库"))
        library.tap()
        let done = app.buttons["close-library"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        expectKeyboardHidden()
        done.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(field.value as? String, "TEST FIXTURE library")
        expectKeyboardHidden()
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    func testDraggingScrollViewDismissesKeyboard() throws {
        // 2026-10-08: the user explicitly accepted this one unresolved gesture
        // for builds 33/34; on 2026-10-09 explicitly extended it to build 35's
        // photo-sync repair IPA. Record a SKIP, never a pass. Other builds retain
        // the original assertion; all Search/Done/Library keyboard tests run.
        let build = Bundle(for: SearchKeyboardTests.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String
        try XCTSkipIf(build == "33" || build == "34" || build == "35",
            "User-approved build 33/34/35 release exception: scroll-to-dismiss remains unresolved; use Done. Not a pass.")
        let field = focusQuery()
        let scroll = app.scrollViews["library-scroll"]
        let keyboard = app.keyboards.firstMatch
        let keyboardFrame = keyboard.frame
        XCTAssertFalse(keyboardFrame.isEmpty)
        XCTAssertTrue(app.frame.contains(keyboardFrame))
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.2))
        let startPoint = CGPoint(x: scroll.frame.minX + scroll.frame.width * 0.85,
                                 y: scroll.frame.minY + scroll.frame.height * 0.2)
        XCTAssertTrue(scroll.frame.contains(startPoint))
        XCTAssertFalse(field.frame.contains(startPoint))
        XCTAssertLessThan(startPoint.y, keyboardFrame.minY)
        // Footer now has its own layout space. The scroll view's 95% point
        // stays ABOVE the keyboard, so it no longer completes an interactive
        // dismissal. Continue the same drag through the actual keyboard.
        let endPoint = CGPoint(x: startPoint.x, y: keyboardFrame.maxY - 1)
        XCTAssertTrue(keyboardFrame.contains(endPoint))
        let end = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: endPoint.x - app.frame.minX, dy: endPoint.y - app.frame.minY))
        start.press(forDuration: 0.1, thenDragTo: end)
        expectKeyboardHidden()
        XCTAssertEqual(field.value as? String, "dog eat my apple pen")
    }
}