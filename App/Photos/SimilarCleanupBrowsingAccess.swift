import Foundation

/// Fresh metadata-only permission to DISPLAY retained cleanup groups. This is
/// never an index/source validator or a selection/deletion grant. It bypasses
/// the search snapshot cache, requests no pixels, and never writes to Photos.
struct SimilarCleanupBrowsingAccess: Sendable {
    let library: any PhotoLibraryIndexing

    struct Proof: Sendable {
        let validate: @Sendable () throws -> Void
    }

    func check(_ expected: [PhotoRevision]) async throws -> Proof {
        let library = self.library
        try Task.checkCancellation()
        guard library.canReadImages else { throw PhotoDeletionError.permissionDenied }
        let authorization = library.authorizationStatusRawValue
        let generation = library.changeGeneration
        let ids = expected.map(\.id)
        guard Set(ids).count == ids.count else { throw PhotoDeletionError.invalidSelection }
        let current: [PhotoRevision]
        if let batch = library as? any PhotoRevisionBatchReading {
            current = try batch.currentRevisions(ids: ids)
        } else {
            current = ids.compactMap { library.currentRevision(id: $0) }
        }
        // Check both count and full revision, including creationTime. Dictionary
        // construction must not trap on a malformed/duplicate injected result.
        var revisions: [String: PhotoRevision] = [:]
        for revision in current {
            guard revisions.updateValue(revision, forKey: revision.id) == nil else {
                throw PhotoDeletionError.accessChanged
            }
        }
        guard current.count == expected.count,
              expected.allSatisfy({ revisions[$0.id] == $0 }) else { throw PhotoDeletionError.accessChanged }
        try Task.checkCancellation()
        let proof = Proof {
            func validateEpoch() throws {
                guard library.canReadImages else { throw PhotoDeletionError.permissionDenied }
                guard library.authorizationStatusRawValue == authorization,
                      library.changeGeneration == generation else { throw PhotoDeletionError.accessChanged }
            }
            try validateEpoch()
            // Legacy libraries without an observer epoch cannot use an unchanged
            // nil as evidence. Production uses its non-nil synchronous epoch.
            if generation == nil {
                guard expected.allSatisfy({ library.currentRevision(id: $0.id) == $0 }) else {
                    throw PhotoDeletionError.accessChanged
                }
                // A getter can return its captured revision while authorization
                // changes during that read. Fence the END of the legacy walk too.
                try validateEpoch()
            }
        }
        try proof.validate()
        return proof
    }
}