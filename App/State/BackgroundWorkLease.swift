import UIKit

@MainActor
protocol BackgroundWorkLeasing: AnyObject {
    func begin(expiration: @escaping @MainActor () -> Void) -> Bool
    func end()
}

/// A finite UIKit grace period, not a promise of scheduled or unlimited execution.
@MainActor
final class BackgroundWorkLease: BackgroundWorkLeasing {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin(expiration: @escaping @MainActor () -> Void) -> Bool {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save local indexing progress") {
            Task { @MainActor in expiration() }
        }
        return identifier != .invalid
    }

    func end() {
        guard identifier != .invalid else { return }
        let value = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(value)
    }
}
