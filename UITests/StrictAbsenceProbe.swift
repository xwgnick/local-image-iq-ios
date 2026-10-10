import XCTest

/// Query first; only an actually present element needs a disappearance wait.
/// A slow negative AX snapshot is not evidence that a view existed for five
/// seconds. Keep the existing wait duration for a positive first observation.
@MainActor
struct StrictAbsenceProbe {
    let initiallyExists: Bool
    let finallyExists: Bool
    let waitResult: XCTWaiter.Result?
    let initialQuerySeconds: TimeInterval
    let waitSeconds: TimeInterval
    let finalQuerySeconds: TimeInterval

    var passed: Bool {
        !finallyExists && (!initiallyExists || waitResult == .completed)
    }

    static func observe(_ element: XCUIElement) -> StrictAbsenceProbe {
        let clock = ProcessInfo.processInfo
        let queryStart = clock.systemUptime
        let initiallyExists = element.exists
        let querySeconds = clock.systemUptime - queryStart
        guard initiallyExists else {
            return StrictAbsenceProbe(initiallyExists: false, finallyExists: false, waitResult: nil,
                initialQuerySeconds: querySeconds, waitSeconds: 0, finalQuerySeconds: 0)
        }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        let waitStart = clock.systemUptime
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        let elapsed = clock.systemUptime - waitStart
        let finalStart = clock.systemUptime
        let finallyExists = element.exists
        return StrictAbsenceProbe(initiallyExists: initiallyExists, finallyExists: finallyExists,
            waitResult: result, initialQuerySeconds: querySeconds, waitSeconds: elapsed,
            finalQuerySeconds: clock.systemUptime - finalStart)
    }

    var description: String {
        "initialExists=\(initiallyExists), initialQuerySeconds=\(initialQuerySeconds), waitResult=\(String(describing: waitResult)), waitSeconds=\(waitSeconds), finalExists=\(finallyExists), finalQuerySeconds=\(finalQuerySeconds)"
    }
}