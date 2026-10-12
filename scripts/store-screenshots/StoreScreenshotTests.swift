import XCTest

// Included only by project.store-screenshots.yml on disposable seeded simulators.
@MainActor
final class StoreScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testCaptureRealPhotoWorkflows() throws {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForPreparedHome(app)

        tap("open-library")
        let count = app.staticTexts["stored-index-count"]
        wait(count, predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "12"), timeout: 180)
        tap("close-library")

        search("coffee")
        capture("01-coffee-search")
        search("cat")
        capture("02-cat-search")

        tap("primary-cleanup-tab")
        let header = app.buttons["similar-cleanup-group-1-header"]
        wait(header, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 120)
        XCTAssertTrue(app.buttons["similar-cleanup-group-2-header"].exists,
                      "Both real photo families must form groups before making store screenshots")
        capture("03-cleanup-overview")
        tap("similar-cleanup-overview-selection-mode")
        tap("similar-cleanup-group-1-photo-1")
        wait(app.buttons["prepare-similar-deletion"],
             predicate: NSPredicate(format: "exists == true AND enabled == true"), timeout: 20)
        capture("04-cleanup-selection")
        header.tap()
        XCTAssertTrue(app.collectionViews["similar-cleanup-five-column-grid"].waitForExistence(timeout: 10))
        capture("05-cleanup-detail")

        // Leave cleanup through the real bottom navigation without deleting photos.
        tap("primary-search-tab")
        tap("open-settings")
        tap("settings-privacy")
        XCTAssertTrue(app.navigationBars["隐私与关于"].waitForExistence(timeout: 10))
        capture("06-privacy")
    }

    private func search(_ query: String) {
        let field = app.textFields["photo-query"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        if app.buttons["clear-query"].exists { app.buttons["clear-query"].tap() }
        field.tap()
        field.typeText(query)
        let submit = app.buttons["search-photos"]
        wait(submit, predicate: NSPredicate(format: "exists == true AND enabled == true"), timeout: 30)
        submit.tap()
        wait(app.descendants(matching: .any).matching(identifier: "results-heading").firstMatch,
             predicate: NSPredicate(format: "exists == true"), timeout: 90)
        wait(app.buttons["select-search-results"],
             predicate: NSPredicate(format: "exists == true AND enabled == true"), timeout: 30)
        if app.buttons["keyboard-done"].exists { app.buttons["keyboard-done"].tap() }
        else if app.buttons["hide-search-keyboard"].exists { app.buttons["hide-search-keyboard"].tap() }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        wait(button, predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), timeout: 20)
        button.tap()
    }

    private func wait(_ element: XCUIElement, predicate: NSPredicate, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Expected real UI readiness: \(element)")
    }

    private func capture(_ name: String) {
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Store-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Store-\(name)-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
