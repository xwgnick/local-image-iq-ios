import Foundation

public enum VectorSearchError: Error, Equatable, Sendable {
    case invalidLocationWeight
    case negativeLimit
    case inconsistentPlaceVector(text: String)
}

public enum VectorSearch {
    private struct PlaceProjection {
        let photoIndex: Int
        let score: Double
    }

    private struct Candidate {
        let photoIndex: Int
        let score: Float
    }

    /// q · ((1-w)I + w(L-mu)), with a zero residual for missing locations.
    /// Inputs are already normalized encoder outputs; this function does not
    /// normalize them, the distinct-place mean, the residual, or the result.
    /// Only the supplied photos define the reference library (including limit=0).
    public static func search(
        query: [Float],
        photos: [IndexedPhoto],
        limit: Int,
        locationWeight: Float
    ) throws -> [SearchHit] {
        guard locationWeight.isFinite, (0...1).contains(locationWeight) else {
            throw VectorSearchError.invalidLocationWeight
        }
        guard limit >= 0 else { throw VectorSearchError.negativeLimit }
        try EmbeddingMath.validate(query)

        // Byte keys preserve exact text identity (Swift String equality otherwise
        // treats canonically equivalent, differently encoded strings as equal).
        // Store indices and scalar projections, never a copied embedding matrix.
        var places: [[UInt8]: PlaceProjection] = [:]
        for (index, photo) in photos.enumerated() {
            try EmbeddingMath.validate(photo.imageEmbedding, dimension: query.count)
            if let location = photo.location {
                try EmbeddingMath.validate(location.vector, dimension: query.count)
                let key = Array(location.text.utf8)
                if let previous = places[key] {
                    // The representative always has a location: it was inserted
                    // through this same branch. Compare components, not scores.
                    guard photos[previous.photoIndex].location?.vector == location.vector else {
                        throw VectorSearchError.inconsistentPlaceVector(text: location.text)
                    }
                } else {
                    places[key] = PlaceProjection(
                        photoIndex: index,
                        score: EmbeddingMath.dotValidated(query, location.vector)
                    )
                }
            }
        }

        // Linearity: q·mean(L) == mean(q·L). No U×D center matrix is needed.
        // Sorted byte keys make accumulation independent of photo enumeration.
        var centerScore: Double = 0
        for key in places.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            if let place = places[key] { centerScore += place.score }
        }
        if !places.isEmpty { centerScore /= Double(places.count) }

        let capacity = min(limit, photos.count)
        guard capacity > 0 else { return [] }
        let weight = Double(locationWeight)
        var heap: [Candidate] = []
        heap.reserveCapacity(capacity)

        for (index, photo) in photos.enumerated() {
            let imageScore = EmbeddingMath.dotValidated(query, photo.imageEmbedding)
            var residual: Double = 0
            if let location = photo.location, let place = places[Array(location.text.utf8)] {
                residual = place.score - centerScore
            }
            let score = try EmbeddingMath.checkedFloat(
                (1 - weight) * imageScore + weight * residual
            )
            let candidate = Candidate(photoIndex: index, score: score)
            if heap.count < capacity {
                heap.append(candidate)
                siftUp(&heap, photos: photos)
            } else if better(candidate, than: heap[0], photos: photos) {
                heap[0] = candidate
                siftDown(&heap, photos: photos)
            }
        }

        return heap.sorted { better($0, than: $1, photos: photos) }.map {
            SearchHit(photo: photos[$0.photoIndex], score: $0.score)
        }
    }

    /// Asset ID is the tie breaker, with locale-independent UTF-8 ordering.
    private static func better(_ lhs: Candidate, than rhs: Candidate, photos: [IndexedPhoto]) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let leftID = photos[lhs.photoIndex].id.utf8
        let rightID = photos[rhs.photoIndex].id.utf8
        if !leftID.elementsEqual(rightID) { return leftID.lexicographicallyPrecedes(rightID) }
        // PhotoKit IDs are unique; if a caller supplies duplicates, keep a stable
        // input-order fallback rather than silently dropping a photo.
        return lhs.photoIndex < rhs.photoIndex
    }

    // The worst retained candidate is the root of this bounded top-K heap.
    private static func siftUp(_ heap: inout [Candidate], photos: [IndexedPhoto]) {
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard better(heap[parent], than: heap[child], photos: photos) else { break }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private static func siftDown(_ heap: inout [Candidate], photos: [IndexedPhoto]) {
        var parent = 0
        while parent < heap.count / 2 {
            let left = parent * 2 + 1
            let right = left + 1
            var worst = left
            if right < heap.count, better(heap[left], than: heap[right], photos: photos) {
                worst = right
            }
            guard better(heap[parent], than: heap[worst], photos: photos) else { break }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}