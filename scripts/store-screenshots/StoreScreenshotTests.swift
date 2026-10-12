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
        try prepareLicensedLibrary()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForPreparedHome(app)

        tap("open-library")
        tap("library-photo-access")
        tap("authorize-photos")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        wait(allow, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 20)
        allow.tap()
        XCTAssertTrue(app.staticTexts["可访问全部照片"].waitForExistence(timeout: 20))
        let back = app.navigationBars["照片访问"].buttons.element(boundBy: 0)
        wait(back, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 20)
        back.tap()
        let count = app.staticTexts["stored-index-count"]
        wait(count, predicate: NSPredicate(format: "exists == true AND label == %@", "已索引 12 张"), timeout: 180)
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

    private func prepareLicensedLibrary() throws {
        let device = try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
        let helper = XCUIApplication(bundleIdentifier: "com.example.localimageiq.store-preparation")
        helper.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                                  "--disposable-store-simulator", device]
        helper.launch()
        defer {
            let evidence = XCTAttachment(string: helper.debugDescription)
            evidence.name = "Store-photo-library-preparation"
            evidence.lifetime = .keepAlways
            add(evidence)
            helper.terminate()
        }
        let prepare = helper.buttons["prepare-store-library"]
        wait(prepare, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 20)
        prepare.tap()
        let status = helper.staticTexts["store-preparation-status"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Full Access"]
        let deletion = springboard.alerts.buttons.matching(
            NSPredicate(format: "label MATCHES %@", "^Delete( [0-9]+ Photos?)?$")).firstMatch
        let permissionOrProgress = NSPredicate { _, _ in
            allow.exists || deletion.exists
                || (status.exists && (status.label == "Prepared 12 licensed photos"
                                      || status.label.hasPrefix("Failed:")))
        }
        wait(status, predicate: permissionOrProgress, timeout: 30)
        if allow.exists { allow.tap() }
        let readyOrConsent = NSPredicate { _, _ in
            deletion.exists || (status.exists && (status.label == "Prepared 12 licensed photos"
                                                  || status.label.hasPrefix("Failed:")))
        }
        wait(status, predicate: readyOrConsent, timeout: 30)
        if deletion.exists { deletion.tap() }
        let finished = NSPredicate(format: "exists == true AND (label == %@ OR label BEGINSWITH %@)",
                                   "Prepared 12 licensed photos", "Failed:")
        wait(status, predicate: finished, timeout: 60)
        let audit = XCTAttachment(string: helper.debugDescription)
        audit.name = "Store-photo-library-preparation-result"
        audit.lifetime = .keepAlways
        add(audit)
        XCTAssertEqual(status.label, "Prepared 12 licensed photos")
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
        if app.buttons["keyboard-done"].exists { app.buttons["keyboard-done"].tap() }
        else if app.buttons["hide-search-keyboard"].exists { app.buttons["hide-search-keyboard"].tap() }
        for rank in [1, 6] {
            let tile = app.descendants(matching: .any).matching(identifier: "result-tile-\(rank)").firstMatch
            wait(tile,
                 predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), timeout: 30)
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        wait(button, predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), timeout: 20)
        button.tap()
    }

    private func wait(_ element: XCUIElement, predicate: NSPredicate, timeout: TimeInterval) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Store-failed-readiness-screen"
            screen.lifetime = .keepAlways
            add(screen)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Store-failed-readiness-accessibility"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertEqual(result, .completed,
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
