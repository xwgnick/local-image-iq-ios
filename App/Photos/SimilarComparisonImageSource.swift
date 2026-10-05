import Foundation
import CoreGraphics

/// Pixels and synchronous access checks for the actual comparison panes. Tests
/// may inject synthetic pixels; the production initializer only captures closures
/// and performs no immediate work, permission request or PhotoKit write.
struct SimilarComparisonImageSource: Sendable {
    /// Arguments: asset ID, target pixel size, captured network opt-in.
    let load: @Sendable (String, CGSize, Bool) async throws -> DisplayThumbnailResult
    /// Arguments: exact expected revisions, authorization raw value, generation.
    let validate: @Sendable ([PhotoRevision], Int, UInt64?) throws -> Void

    init(load: @escaping @Sendable (String, CGSize, Bool) async throws -> DisplayThumbnailResult,
         validate: @escaping @Sendable ([PhotoRevision], Int, UInt64?) throws -> Void) {
        self.load = load
        self.validate = validate
    }

    init(library: PhotoLibraryClient) {
        self.init(load: { id, targetSize, networkAllowed in
            try await library.comparisonResult(id: id, targetSize: targetSize, networkAllowed: networkAllowed)
        }, validate: { revisions, authorization, generation in
            try Task.checkCancellation()
            let before = PhotoLibraryClient.authorization
            guard before == .authorized || before == .limited else { throw AppFailure.permission }
            guard before.rawValue == authorization, library.changeGeneration == generation else {
                throw CancellationError()
            }
            for revision in revisions {
                guard library.currentRevision(id: revision.id) == revision else { throw CancellationError() }
            }
            // Permission and PhotoKit notifications can race metadata reads.
            let after = PhotoLibraryClient.authorization
            guard after == .authorized || after == .limited else { throw AppFailure.permission }
            guard after.rawValue == authorization, library.changeGeneration == generation else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        })
    }
}