import Foundation
import UIKit

@MainActor
final class PhotoThumbnailCache {
    private let cache = NSCache<NSString, UIImage>()
    private var generation = UUID()
    private let library: PhotoLibraryClient

    init(library: PhotoLibraryClient) { self.library = library }

    func clear() {
        generation = UUID()
        cache.removeAllObjects()
    }

    func image(id: String, revision: Double, networkAllowed: Bool) async throws -> UIImage {
        let key = "\(id)|\(revision)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let token = generation
        let image = try await library.displayImage(id: id, targetSize: CGSize(width: 480, height: 480),
                                                   networkAllowed: networkAllowed)
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        cache.setObject(image, forKey: key)
        return image
    }
}