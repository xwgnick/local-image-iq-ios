import Foundation
import XCTest

@MainActor
extension XCTestCase {
    func waitForPreparedHome(_ app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        // TEST ONLY: real model cold loading gets its own 90-second wait, not a
        // production deadline or an increase to keyboard/navigation timeouts.
        // Observe either outcome on the running app; a fast launch need not
        // expose the transient spinner to the test before reaching home.
        let homeOrStartupError = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let application = object as? XCUIApplication else { return false }
                return application.buttons["open-settings"].exists
                    || application.buttons["startup-open-home"].exists
            }, object: app)
        guard XCTWaiter.wait(for: [homeOrStartupError], timeout: 90) == .completed else {
            recordLaunchFailure(in: app, message: "Cold startup reached neither home nor a startup error within 90 seconds",
                                file: file, line: line)
            return
        }

        let openHomeAfterError = app.buttons["startup-open-home"]
        if openHomeAfterError.exists {
            let requireModels = ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"]
            guard requireModels == "0" else {
                let message = requireModels == "1"
                    ? "Model-required startup failed; do not retry or bypass model preparation"
                    : "Startup failed and IMAGEIQ_REQUIRE_MODELS is not explicitly 0 (value: \(requireModels ?? "unset")); bypass is forbidden"
                recordLaunchFailure(in: app, message: message, file: file, line: line)
                return
            }

            // Only an explicitly model-free test run may use this real recovery
            // action. Keep evidence of the error; never tap startup-retry.
            attachLaunchDiagnostics(in: app, message: "Explicit model-free run (IMAGEIQ_REQUIRE_MODELS=0): opening home after startup error")
            openHomeAfterError.tap()
        }

        // Retain the existing 10-second home-control wait, including after the
        // model-free recovery action. Error recovery alone is not readiness.
        guard app.buttons["open-settings"].waitForExistence(timeout: 10) else {
            recordLaunchFailure(in: app, message: "Home must appear after startup or explicit model-free recovery",
                                file: file, line: line)
            return
        }
    }

    private func recordLaunchFailure(in app: XCUIApplication, message: String,
                                     file: StaticString, line: UInt) {
        attachLaunchDiagnostics(in: app, message: message)
        XCTFail(message, file: file, line: line)
    }

    private func attachLaunchDiagnostics(in app: XCUIApplication, message: String) {
        let hierarchy = XCTAttachment(string: "\(message)\n\n\(app.debugDescription)")
        hierarchy.name = "Launch-startup-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Launch-startup-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}