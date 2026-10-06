import Accelerate
import ImageIQCore

/// Immutable, caller-scoped search snapshot. Authorization, library revisions and
/// rebuilding the snapshot remain the caller's responsibility. No result cache,
/// normalization, approximate retrieval, GPU, or change to the Core oracle.
///
/// Retains the original Float32 photos AND one row-major Double image matrix:
/// additional matrix storage is N * D * 8 bytes (46.875 MiB for 8,000 x 768),
/// plus O(N) norms/place indices and O(U) distinct-place metadata. Place vectors
/// share the original Swift Array storage. Each query uses O(N + D + U) scratch;
/// full sorting is O(N log N), including when limit == N (no full-size heap).
struct ResidentSearchIndex: Sendable {
    let photos: [IndexedPhoto]

    private struct Place: Sendable {
        let utf8: [UInt8]
        let vector: [Float]
    }

    private struct Candidate {
        let photoIndex: Int
        let score: Float
    }

    private let dimension: Int?
    private let imageMatrix: [Double]
    private let rowNormUpper: [Double]
    private let places: [Place] // Unique, in ascending UTF-8 byte order.
    private let rowPlaceIndex: [Int] // -1 means missing, not a zero-vector place.
    private let dotErrorFactor: Double
    private let dotUnderflowAllowance: Double

    // Deterministic storage counts; not mutable instrumentation or timing gates.
    var packedImageElementCount: Int { imageMatrix.count }
    var uniquePlaceCount: Int { places.count }

    init(photos: [IndexedPhoto]) throws {
        try Task.checkCancellation()
        let dimension = photos.first?.imageEmbedding.count
        var representatives: [[UInt8]: Int] = [:]
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            try Self.validate(photo.imageEmbedding, dimension: dimension)
            if let location = photo.location {
                try Self.validate(location.vector, dimension: dimension)
                let key = Array(location.text.utf8)
                if let previous = representatives[key] {
                    // Core compares Float values, not bits: +0 and -0 are equal.
                    guard photos[previous].location?.vector == location.vector else {
                        throw VectorSearchError.inconsistentPlaceVector(text: location.text)
                    }
                } else {
                    representatives[key] = index
                }
            }
        }

        let keys = try representatives.keys.sorted {
            try Task.checkCancellation()
            return $0.lexicographicallyPrecedes($1)
        }
        var places: [Place] = []
        var placeIndices: [[UInt8]: Int] = [:]
        places.reserveCapacity(keys.count)
        for key in keys {
            try Task.checkCancellation()
            // These entries were created only from non-nil, validated locations.
            let vector = photos[representatives[key]!].location!.vector
            placeIndices[key] = places.count
            places.append(Place(utf8: key, vector: vector))
        }

        try Task.checkCancellation() // Before allocating/building the matrix.
        var matrix: [Double] = []
        matrix.reserveCapacity(photos.count * (dimension ?? 0))
        var norms: [Double] = []
        var rowPlaces: [Int] = []
        norms.reserveCapacity(photos.count)
        rowPlaces.reserveCapacity(photos.count)
        for photo in photos {
            try Task.checkCancellation()
            norms.append(try Self.appendWideRow(photo.imageEmbedding, to: &matrix))
            if let location = photo.location {
                rowPlaces.append(placeIndices[Array(location.text.utf8)]!)
            } else {
                rowPlaces.append(-1)
            }
        }
        try Task.checkCancellation()
        let error = Self.errorConstants(dimension: dimension ?? 0)
        self.photos = photos
        self.dimension = dimension
        self.imageMatrix = matrix
        self.rowNormUpper = norms
        self.places = places
        self.rowPlaceIndex = rowPlaces
        self.dotErrorFactor = error.factor
        self.dotUnderflowAllowance = error.underflow
    }

    func search(query: [Float], limit: Int, locationWeight: Float) throws -> [SearchHit] {
        try searchMeasured(query: query, limit: limit, locationWeight: locationWeight).hits
    }

    /// Counts only rows requiring the original sequential image dot product.
    /// A nonempty result request always performs one native matrix-vector batch
    /// over ALL N rows, even for limit=1 or weight=1. Native work cannot be
    /// interrupted: cancellation is checked immediately before and after it.
    func searchMeasured(
        query: [Float], limit: Int, locationWeight: Float
    ) throws -> (hits: [SearchHit], fallbacks: Int) {
        try Task.checkCancellation()
        guard locationWeight.isFinite, (0...1).contains(locationWeight) else {
            throw VectorSearchError.invalidLocationWeight
        }
        guard limit >= 0 else { throw VectorSearchError.negativeLimit }
        // Core validates the query first, then validates each photo AGAINST
        // query.count. Preserve both error precedence and expected/actual fields.
        try Self.validate(query)
        if let dimension, dimension != query.count {
            throw EmbeddingError.dimensionMismatch(expected: query.count, actual: dimension)
        }

        // Deliberately scalar, left-to-right, just like Core. In particular, do
        // not batch these dots, divide each term, or frequency-weight the mean.
        var placeScores: [Double] = []
        placeScores.reserveCapacity(places.count)
        var centerScore: Double = 0
        for place in places {
            try Task.checkCancellation()
            let score = try Self.scalarDot(query, place.vector)
            placeScores.append(score)
            centerScore += score
        }
        if !places.isEmpty { centerScore /= Double(places.count) }

        let capacity = min(limit, photos.count)
        try Task.checkCancellation()
        guard capacity > 0 else { return ([], 0) }

        var wideQuery: [Double] = []
        wideQuery.reserveCapacity(query.count)
        let queryNormUpper = try Self.appendWideRow(query, to: &wideQuery)
        var imageScores = [Double](repeating: 0, count: photos.count)
        try Task.checkCancellation()
        imageMatrix.withUnsafeBufferPointer { matrix in
            wideQuery.withUnsafeBufferPointer { vector in
                imageScores.withUnsafeMutableBufferPointer { output in
                    // Native-size UInt lengths: no cblas Int32 dimension cap.
                    vDSP_mmulD(matrix.baseAddress!, 1, vector.baseAddress!, 1,
                               output.baseAddress!, 1,
                               vDSP_Length(photos.count), 1, vDSP_Length(query.count))
                }
            }
        }
        try Task.checkCancellation()

        let weight = Double(locationWeight)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(photos.count)
        var fallbacks = 0
        for index in photos.indices {
            try Task.checkCancellation()
            let placeIndex = rowPlaceIndex[index]
            let residual = placeIndex < 0 ? 0 : placeScores[placeIndex] - centerScore
            let score: Float
            if let certified = certifiedScore(
                imageScore: imageScores[index], row: index,
                queryNormUpper: queryNormUpper, weight: weight, residual: residual
            ) {
                score = certified
            } else {
                fallbacks += 1
                let exact = try Self.scalarDot(query, photos[index].imageEmbedding)
                score = try Self.checkedFloat(Self.fused(exact, weight: weight, residual: residual))
            }
            candidates.append(Candidate(photoIndex: index, score: score))
        }

        try candidates.sort { left, right in
            try Task.checkCancellation()
            if left.score != right.score { return left.score > right.score }
            let leftID = photos[left.photoIndex].id.utf8
            let rightID = photos[right.photoIndex].id.utf8
            if !leftID.elementsEqual(rightID) { return leftID.lexicographicallyPrecedes(rightID) }
            return left.photoIndex < right.photoIndex
        }
        var hits: [SearchHit] = []
        hits.reserveCapacity(capacity)
        for candidate in candidates.prefix(capacity) {
            try Task.checkCancellation()
            hits.append(SearchHit(photo: photos[candidate.photoIndex], score: candidate.score))
        }
        try Task.checkCancellation()
        return (hits, fallbacks)
    }

    /// Numerical certificate, NOT a quality tolerance:
    /// u = 2^-53, gamma(k) = k*u/(1-k*u), A = sum(abs(q[j]*row[j])).
    /// Float -> Double and each Float x Float product are exact in Double
    /// (at most 48 significant bits, exponents within Double's normal range).
    /// Each ordinary mul/add or FMA reduction has error <= gamma(D)*A.
    /// Comparing native and sequential reductions therefore needs
    /// 2*gamma(D)*A <= gamma(2D)*A, not just one reduction's error bound.
    /// Cauchy-Schwarz gives A <= ||q||2 * ||row||2. Both norms are upper bounds
    /// from outward-rounded square sums and sqrt, not nominal computed norms.
    ///
    /// Every positive bound operation rounds outward with nextUp; the denominator
    /// rounds downward. Add 2D*eta/(1-2D*u), eta = Double.leastNonzeroMagnitude,
    /// for gradual-underflow absolute errors (conservative even though these
    /// Float products cannot underflow Double). Dot and fusion interval steps
    /// also round outward. There is no empirical epsilon or score clamping.
    private func certifiedScore(
        imageScore: Double, row: Int, queryNormUpper: Double, weight: Double, residual: Double
    ) -> Float? {
        let normProduct = (queryNormUpper * rowNormUpper[row]).nextUp
        let error = ((dotErrorFactor * normProduct).nextUp + dotUnderflowAllowance).nextUp
        guard imageScore.isFinite, error.isFinite, residual.isFinite else { return nil }
        let lowerDot = (imageScore - error).nextDown
        let upperDot = (imageScore + error).nextUp
        guard lowerDot.isFinite, upperDot.isFinite else { return nil }

        // Same rounded coefficients/location term as Core. Since 1-w >= 0,
        // outward multiplication and addition enclose its final Double score.
        let imageWeight = 1 - weight
        let locationTerm = weight * residual
        let lower = ((imageWeight * lowerDot).nextDown + locationTerm).nextDown
        let upper = ((imageWeight * upperDot).nextUp + locationTerm).nextUp
        guard lower.isFinite, upper.isFinite else { return nil }
        let lowFloat = Float(lower)
        let highFloat = Float(upper)
        let computed = Self.fused(imageScore, weight: weight, residual: residual)
        let result = Float(computed)
        // Bit equality, not ==: opposite signed zeros must take the scalar path.
        // An infinite bound/result is never accepted or used to mask Core's error.
        guard lowFloat.isFinite, highFloat.isFinite, computed.isFinite, result.isFinite,
              lowFloat.bitPattern == highFloat.bitPattern,
              result.bitPattern == lowFloat.bitPattern else { return nil }
        return result
    }

    private static func errorConstants(dimension: Int) -> (factor: Double, underflow: Double) {
        // Construct 2D in Double, not Int (no integer multiplication overflow).
        let operations = (2 * Double(dimension).nextUp).nextUp
        let scaledU = (operations * (Double.ulpOfOne / 2)).nextUp
        let denominator = (1 - scaledU).nextDown
        guard denominator > 0 else {
            // A vacuous numerical bound selects exact work, never rejects a size.
            return (.infinity, .infinity)
        }
        let factor = (scaledU / denominator).nextUp
        let underflow = ((operations * Double.leastNonzeroMagnitude).nextUp / denominator).nextUp
        return (factor, underflow)
    }

    /// Packs once; exact Float squares plus upward rounding at every addition
    /// and at sqrt make this an upper bound even for nonunit/extreme vectors.
    private static func appendWideRow(_ values: [Float], to output: inout [Double]) throws -> Double {
        var squares: Double = 0
        for index in values.indices {
            // Cooperative cadence, not a dimension/resource limit.
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let value = Double(values[index])
            output.append(value)
            if value != 0 { squares = (squares + value * value).nextUp }
        }
        return squares == 0 ? 0 : squares.squareRoot().nextUp
    }

    // Core's helpers are module-internal. Mirror their exact validation/errors
    // and arithmetic here rather than changing/exporting the reference oracle.
    private static func validate(_ vector: [Float], dimension: Int? = nil) throws {
        try Task.checkCancellation()
        guard !vector.isEmpty else { throw EmbeddingError.emptyVector }
        if let dimension, vector.count != dimension {
            throw EmbeddingError.dimensionMismatch(expected: dimension, actual: vector.count)
        }
        for index in vector.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard vector[index].isFinite else { throw EmbeddingError.nonFiniteValue(index: index) }
        }
    }

    private static func scalarDot(_ lhs: [Float], _ rhs: [Float]) throws -> Double {
        var result: Double = 0
        for index in lhs.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            result += Double(lhs[index]) * Double(rhs[index])
        }
        return result
    }

    private static func fused(_ image: Double, weight: Double, residual: Double) -> Double {
        (1 - weight) * image + weight * residual
    }

    private static func checkedFloat(_ value: Double) throws -> Float {
        let result = Float(value)
        guard value.isFinite, result.isFinite else { throw EmbeddingError.nonFiniteResult }
        return result
    }
}