import Foundation
import ImageIQCore

/// Scalar-only result: never retains preview pixels, gallery IDs or embeddings.
/// Preview metadata describes this fresh request ONLY. The existing cache never
/// stored input dimensions/source, so historical cached dimensions are unknown.
struct PhotoDiagnosticReport: Sendable {
    let photoID: String
    let query: String
    let locationWeight: Float
    let galleryCount: Int
    /// Ranks are one-based in the complete current, authorized cached gallery.
    var cachedRank: Int? = nil
    var cachedScore: Float? = nil
    var freshRank: Int? = nil
    var freshScore: Float? = nil
    var cachedFreshCosine: Float? = nil
    /// Requested CGSize components rounded to the nearest pixel; nil if unknown.
    /// IndexingImage retains the exact (potentially fractional) requested CGSize.
    var requestedWidth: Int? = nil
    var requestedHeight: Int? = nil
    /// Raw CGImage dimensions, before applying the separately reported orientation.
    var pixelWidth: Int? = nil
    var pixelHeight: Int? = nil
    var orientationRawValue: UInt32? = nil
    /// Raw PhotoKit flag, NOT inferred from source or returned dimensions.
    var degraded: Bool? = nil
    var source: String? = nil
    var freshIssue: String? = nil
    /// Same model + preview-policy cache version as normal search.
    let modelVersion: String
    /// "current", "missing" (no row), or "stale" (wrong revision/model/policy).
    /// Missing/stale targets are never inserted into the comparison gallery:
    /// both ranks/scores and cachedFreshCosine remain nil in those cases.
    let cachedStatus: String
}

/// Pure scalar ranking seam for synthetic tests. Core owns exact scoring,
/// distinct-place centering and UTF-8 ID tie-breaking, just as in normal search.
enum PhotoDiagnosticRanking {
    static func rank(id: String, query: [Float], photos: [IndexedPhoto], locationWeight: Float,
                     replacingImageWith fresh: [Float]? = nil) throws -> (rank: Int?, score: Float?) {
        try EmbeddingValidation.validateUnit(query)
        for photo in photos {
            try EmbeddingValidation.validateUnit(photo.imageEmbedding)
            if let place = photo.location { try EmbeddingValidation.validateUnit(place.vector) }
        }
        var candidates = photos
        if let fresh {
            try EmbeddingValidation.validateUnit(fresh)
            if let index = candidates.firstIndex(where: { $0.id == id }) {
                let old = candidates[index]
                candidates[index] = IndexedPhoto(id: old.id, modificationTime: old.modificationTime,
                                                 modelVersion: old.modelVersion, imageEmbedding: fresh,
                                                 location: old.location, creationTime: old.creationTime)
            }
            // No insertion when the selected photo has no current cached row.
        }
        let hits = try VectorSearch.search(query: query, photos: candidates, limit: photos.count,
                                           locationWeight: locationWeight)
        guard let index = hits.firstIndex(where: { $0.id == id }) else { return (nil, nil) }
        return (index + 1, hits[index].score)
    }
}