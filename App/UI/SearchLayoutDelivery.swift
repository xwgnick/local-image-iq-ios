import Combine
import Foundation

/// Exit SwiftUI's preference/layout callback before any observable writes.
/// Newer measurements (including nil) replace pending ones, without inventing
/// geometry, counts or a timer. AppState still validates the captured session
/// and count before accepting a page. No objectWillChange is emitted here.
@MainActor
final class SearchLayoutDelivery: ObservableObject {
    private var boundaryToken = UUID()
    private var headerToken = UUID()

    func deliverBoundary(_ action: @escaping @MainActor () -> Void) {
        let token = UUID()
        boundaryToken = token
        DispatchQueue.main.async { [weak self] in
            guard self?.boundaryToken == token else { return }
            action()
        }
    }

    func deliverHeader(_ action: @escaping @MainActor () -> Void) {
        let token = UUID()
        headerToken = token
        DispatchQueue.main.async { [weak self] in
            guard self?.headerToken == token else { return }
            action()
        }
    }
}