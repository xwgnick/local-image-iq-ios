import Foundation
import ImageIQCore

/// Immutable, complete canonical input (including unmatched singletons). This
/// is data, NOT source authority. The service must bind it to a fresh full key
/// and keep all Photos/SQLite fences on every invocation before using it.
struct SimilarGroupingPreparedInput: Sendable {
    static let dimension = 768
    let photos: [IndexedPhoto]
    let matrix: [Float]
    let norms: [Double]

    init(photos: [IndexedPhoto]) throws {
        try Task.checkCancellation()
        let ordered = try photos.sorted {
            try Task.checkCancellation()
            return $0.id < $1.id
        }
        var matrix: [Float] = []
        matrix.reserveCapacity(ordered.count * Self.dimension)
        var norms: [Double] = []
        norms.reserveCapacity(ordered.count)
        var previousID: String?
        for photo in ordered {
            try Task.checkCancellation()
            guard !photo.id.isEmpty, photo.id != previousID,
                  photo.modificationTime.isFinite, photo.creationTime?.isFinite != false else {
                throw AppFailure.modelContract("Invalid or duplicate similarity candidate metadata.")
            }
            previousID = photo.id
            try EmbeddingValidation.validateUnit(photo.imageEmbedding, dimension: Self.dimension)
            // Keep the original scalar Double reduction and original Float bits;
            // neither renormalize nor replace this with an Accelerate reduction.
            norms.append(photo.imageEmbedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
            matrix.append(contentsOf: photo.imageEmbedding)
        }
        self.photos = ordered
        self.matrix = matrix
        self.norms = norms
    }
}

/// Reuse the durable full-content identity without making it threshold-dependent.
/// 0.50 is a fixed legal sentinel, NOT the requested/default threshold. Changes
/// to auth, any authorized revision (even unindexed), image bytes, model, input
/// policy or algorithm still change this key. Notification epochs are not keys.
struct SimilarGroupingPreparedKey: Equatable, Sendable {
    private let identity: SimilarGroupingCacheKey

    init(authorized: [String: PhotoRevision], imagePayloadSignature: Data,
         modelVersion: String, authorization: Int?,
         algorithmVersion: String = SimilarPhotoGroupingPolicy.algorithmVersion,
         policyVersion: String = IndexImagePolicy.version) throws {
        identity = try SimilarGroupingCacheKey(authorized: authorized,
            imagePayloadSignature: imagePayloadSignature, modelVersion: modelVersion,
            authorization: authorization, threshold: 0.50,
            algorithmVersion: algorithmVersion, policyVersion: policyVersion)
    }
}

/// Invocation-local counters, no locks/callbacks in the inner loops, no IDs or
/// vectors. Sorting counts include only candidate sorting, not canonical IDs or
/// final group sorting. No N x N scores are retained for metrics or reuse.
struct SimilarGroupingComputationMetrics: Sendable, Equatable {
    var matrixMultiplyCount = 0
    var seedScoreCount = 0
    var memberScoreCount = 0
    var sortCandidateCount = 0
    var sortComparisonCount = 0
}

struct SimilarGroupingComputation: Sendable {
    let groups: [SimilarPhotoGroup]
    let metrics: SimilarGroupingComputationMetrics
}

/// Successful service invocation only. A warm middle snapshot is counted just
/// like the cold hash+decode reader: both check the full durable source content.
struct SimilarGroupingWorkMetrics: Sendable {
    var preparationCount = 0
    var decodedRowCount = 0
    var preparedInputReuseCount = 0
    var sourceSnapshotCount = 0
    var computation = SimilarGroupingComputationMetrics()
}