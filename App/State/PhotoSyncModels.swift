import Foundation

struct PhotoSyncProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable { case checking, updating }
    var phase: Phase = .checking
    var total: Int? = nil
    var completed: Int = 0
    var encoded: Int = 0
    /// Removed index rows, not a claim that a system photo was deleted.
    var removed: Int = 0
    var failed: Int = 0
    var needsNetwork: Int = 0

    var fraction: Double? {
        guard let total else { return nil }
        return total == 0 ? 1 : Double(completed) / Double(total)
    }
}

struct PhotoSyncResult: Sendable {
    let summary: LibrarySummary
    let progress: PhotoSyncProgress
}

protocol PhotoSyncServicing: Sendable {
    /// Stored image-index metadata only, not a Photos enumeration or a new sync.
    /// Nil means this service does not provide incremental summary snapshots.
    func currentSummary() async throws -> LibrarySummary?
    func synchronize(networkAllowed: Bool,
                     progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult
}

extension PhotoSyncServicing {
    func currentSummary() async throws -> LibrarySummary? { nil }
}