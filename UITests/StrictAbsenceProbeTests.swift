import XCTest

@MainActor
final class StrictAbsenceProbeTests: XCTestCase {
    func testRealAbsentPresentAndDismissedControlsKeepStrictExistenceMeaning() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.resetAuthorizationStatus(for: .photos)
        app.launch()
        waitForPreparedHome(app)
        app.buttons["open-settings"].tap()
        let done = app.buttons["close-settings"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        let missing = app.descendants(matching: .any).matching(identifier: "strict-absence-never-a-production-control").firstMatch
        let absent = StrictAbsenceProbe.observe(missing)
        XCTAssertTrue(absent.passed, absent.description)
        XCTAssertFalse(absent.initiallyExists)
        XCTAssertNil(absent.waitResult)
        // A genuinely present control MUST be rejected after the unchanged
        // five-second disappearance wait. This is a passing negative control,
        // not XCTExpectFailure, a skip, a waiver or a real failed assertion.
        let present = StrictAbsenceProbe.observe(done)
        XCTAssertFalse(present.passed, present.description)
        XCTAssertTrue(present.initiallyExists)
        XCTAssertTrue(present.finallyExists)
        XCTAssertEqual(present.waitResult, .timedOut)
        done.tap()
        let dismissed = StrictAbsenceProbe.observe(done)
        XCTAssertTrue(dismissed.passed, dismissed.description)
        XCTAssertFalse(dismissed.finallyExists)
        let report = XCTAttachment(string: "ABSENT: \(absent.description)\nPRESENT: \(present.description)\nDISMISSED: \(dismissed.description)")
        report.name = "Strict-absence-native-query-control"
        report.lifetime = .keepAlways
        add(report)
    }
}