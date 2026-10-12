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
        try launchIndexedLibrary(count: 12)

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

        tap("primary-search-tab")
        tap("open-settings")
        tap("settings-privacy")
        XCTAssertTrue(app.navigationBars["隐私与关于"].waitForExistence(timeout: 10))
        capture("06-privacy")
    }

    func testCaptureThreePriorityScenes() throws {
        try launchIndexedLibrary(count: 11)
        search("傍晚的海边，粉紫色和橙色的天空，两个人站在水边，身后有一座长长的栈桥", minimumResults: 1)
        capture("pilot-01-memory-query")
        search("身份证", minimumResults: 1)
        capture("pilot-02-document-query")
        search("梧桐街南门", minimumResults: 1)
        capture("pilot-ocr-before")
        let alternatives = ["北门值班室", "松桥路东口", "河畔图书馆"]
        for (index, query) in alternatives.enumerated() {
            search(query, minimumResults: 1)
            capture("pilot-ocr-before-\(index + 2)")
        }
        let ocr = app.switches["photo-text-search-enabled"].firstMatch
        wait(ocr, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 20)
        XCTAssertEqual(ocr.value as? String, "0")
        ocr.tap()
        tap("open-library")
        tap("library-text-index")
        let status = app.staticTexts["text-index-status"]
        wait(status, predicate: NSPredicate(format: "exists == true AND label == %@", "文字索引已更新"), timeout: 180)
        let counts = app.staticTexts["text-index-counts"]
        wait(counts, predicate: NSPredicate(format: "exists == true AND label BEGINSWITH %@", "已识别 11 张"), timeout: 30)
        capture("pilot-ocr-index-evidence")
        let back = app.navigationBars["文本索引"].buttons.element(boundBy: 0)
        wait(back, predicate: NSPredicate(format: "exists == true AND hittable == true"), timeout: 20)
        back.tap()
        tap("close-library")
        if app.buttons["dismiss-ocr-sync"].exists {
            tap("dismiss-ocr-sync")
        }
        wait(app.buttons["ocr-sync-open-details"],
             predicate: NSPredicate(format: "exists == false"), timeout: 20)
        search("梧桐街南门", minimumResults: 1)
        capture("pilot-03-ocr-query")
        for (index, query) in alternatives.enumerated() {
            search(query, minimumResults: 1)
            capture("pilot-ocr-after-\(index + 2)")
        }
    }

    private func launchIndexedLibrary(count expected: Int) throws {
        XCUIDevice.shared.orientation = .portrait
        try prepareLicensedLibrary(count: expected)
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
        let expectedLabel = expected == 12 ? "已索引 12 张" : "已索引 11 张"
        wait(count, predicate: NSPredicate(format: "exists == true AND label == %@", expectedLabel), timeout: 180)
        tap("close-library")
    }

    private func prepareLicensedLibrary(count expected: Int) throws {
        let success = expected == 12 ? "Prepared 12 licensed photos" : "Prepared 11 licensed photos"
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
                || (status.exists && (status.label == success
                                      || status.label.hasPrefix("Failed:")))
        }
        wait(status, predicate: permissionOrProgress, timeout: 30)
        if allow.exists { allow.tap() }
        let readyOrConsent = NSPredicate { _, _ in
            deletion.exists || (status.exists && (status.label == success
                                                  || status.label.hasPrefix("Failed:")))
        }
        wait(status, predicate: readyOrConsent, timeout: 30)
        if deletion.exists { deletion.tap() }
        let finished = NSPredicate(format: "exists == true AND (label == %@ OR label BEGINSWITH %@)",
                                   success, "Failed:")
        wait(status, predicate: finished, timeout: 60)
        let audit = XCTAttachment(string: helper.debugDescription)
        audit.name = "Store-photo-library-preparation-result"
        audit.lifetime = .keepAlways
        add(audit)
        XCTAssertEqual(status.label, success)
    }

    private func search(_ query: String, minimumResults: Int = 6) {
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
        for rank in Set([1, minimumResults]) {
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
