import Foundation
import UIKit

/// Synchronous metadata checks stay callable from the nonisolated Photos client.
/// Only the cache/UI is MainActor-isolated; test providers need no PhotoKit access.
protocol PhotoThumbnailProviding: Sendable {
    var canReadImages: Bool { get }
    var changeGeneration: UInt64? { get }
    func currentRevision(id: String) -> PhotoRevision?
    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage
}

@MainActor
final class PhotoThumbnailCache {
    private struct Identity: Hashable {
        let id: String
        let storedRevision: Double
        let currentModificationTime: Double
        let currentCreationTime: Double?
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        let networkAllowed: Bool
        let libraryGeneration: UInt64?
    }

    /// Value equality avoids ambiguous concatenated identifiers and revisions.
    private final class Key: NSObject {
        let identity: Identity
        init(_ identity: Identity) { self.identity = identity }
        override var hash: Int { identity.hashValue }
        override func isEqual(_ object: Any?) -> Bool {
            (object as? Key)?.identity == identity
        }
    }

    private let cache = NSCache<Key, UIImage>()
    private var generation = UUID()
    private let library: any PhotoThumbnailProviding

    init(library: any PhotoThumbnailProviding) { self.library = library }

    func clear() {
        generation = UUID()
        cache.removeAllObjects()
    }

    func image(id: String, revision: Double, targetSize: CGSize = CGSize(width: 480, height: 480),
               networkAllowed: Bool) async throws -> UIImage {
        try Task.checkCancellation()
        guard let pixels = DisplayThumbnailLoader.targetSize(points: targetSize, displayScale: 1) else {
            throw AppFailure.photo("Invalid thumbnail size.")
        }
        let token = generation
        let libraryGeneration = library.changeGeneration
        guard library.canReadImages else { throw AppFailure.permission }
        guard let current = library.currentRevision(id: id), current.id == id else {
            throw AppFailure.photo("This photo is no longer accessible.")
        }
        // An old embedding is still searchable after an edit. Cache the CURRENT
        // display revision, without requiring it to equal the stored revision.
        let key = Key(Identity(id: id, storedRevision: revision,
                               currentModificationTime: current.modificationTime,
                               currentCreationTime: current.creationTime,
                               pixelWidth: pixels.width, pixelHeight: pixels.height,
                               networkAllowed: networkAllowed, libraryGeneration: libraryGeneration))
        let cached = cache.object(forKey: key)
        try validate(id: id, revision: current, libraryGeneration: libraryGeneration, token: token)
        if let cached { return cached }
        let image = try await library.thumbnailImage(id: id, targetSize: pixels, networkAllowed: networkAllowed)
        try validate(id: id, revision: current, libraryGeneration: libraryGeneration, token: token)
        cache.setObject(image, forKey: key, cost: Self.decodedCost(image))
        return image
    }

    private func validate(id: String, revision: PhotoRevision, libraryGeneration: UInt64?, token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        guard library.canReadImages else { throw AppFailure.permission }
        guard library.changeGeneration == libraryGeneration,
              library.currentRevision(id: id) == revision else { throw CancellationError() }
        guard library.canReadImages else { throw AppFailure.permission }
        guard token == generation, library.changeGeneration == libraryGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func decodedCost(_ image: UIImage) -> Int {
        guard let pixels = image.cgImage else { return 0 }
        let (cost, overflow) = pixels.bytesPerRow.multipliedReportingOverflow(by: pixels.height)
        // Cost is accounting only, never an allocation/request ceiling.
        return overflow ? 0 : cost
    }
}