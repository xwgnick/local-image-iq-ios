import Accelerate
import Foundation
import ImageIQCore

/// The legacy aggregate digest is unchanged. Per-row hashes are process-local
/// evidence for subtracting confirmed deletions, including stale rows and rows
/// outside returned groups. No source JSON or pairwise score cache is retained.
struct SimilarGroupingDeletionSnapshot: Sendable {
    let source: SimilarGroupingInputSnapshot
    let rowDigests: [String: Data]
}

struct SimilarGroupingDeletionBaseline: Sendable {
    let id: UUID
    let key: SimilarGroupingCacheKey
    let authorized: [String: PhotoRevision]
    let rowDigests: [String: Data]
    let groups: [SimilarPhotoGroup]

    enum Match {
        case invalid
        case awaitingDeletion
        case removed(Set<String>)
    }

    /// Absence alone is NEVER evidence of deletion. All missing IDs must have
    /// been explicitly confirmed by the successful app mutation for this result.
    /// Partial/delayed enumeration grants no result/selection authority. While
    /// waiting, confirmed visible IDs must keep their full revision, but their
    /// SQL rows may already be pruned. Every non-deleted full revision AND image
    /// payload (including singletons/stale rows) must match throughout the wait.
    func match(key freshKey: SimilarGroupingCacheKey, authorized fresh: [String: PhotoRevision],
               rowDigests freshRows: [String: Data], confirmed: [String: PhotoRevision]) throws -> Match {
        guard !confirmed.isEmpty,
              key.modelUTF8 == freshKey.modelUTF8, key.policyUTF8 == freshKey.policyUTF8,
              key.algorithmUTF8 == freshKey.algorithmUTF8, key.authorization == freshKey.authorization,
              key.thresholdBits == freshKey.thresholdBits else { return .invalid }
        for (id, revision) in confirmed {
            try Task.checkCancellation()
            guard let old = authorized[id], SimilarGroupingDigest.sameRevision(old, revision) else { return .invalid }
        }
        for (id, revision) in fresh {
            try Task.checkCancellation()
            guard let old = authorized[id], SimilarGroupingDigest.sameRevision(old, revision) else { return .invalid }
            // Sync can prune a confirmed row before Photos enumeration catches
            // up. Only that absence is allowed, never a rewritten/replaced row.
            guard rowDigests[id] == freshRows[id] ||
                (confirmed[id] != nil && freshRows[id] == nil) else { return .invalid }
        }
        // No new indexed rows for unindexed photos, missing rows for remaining
        // photos, or invisible same-revision BLOB rewrites are accepted.
        guard freshRows.keys.allSatisfy({ fresh[$0] != nil }) else { return .invalid }
        let removed = Set(authorized.keys).subtracting(fresh.keys)
        guard removed.isSubset(of: Set(confirmed.keys)) else { return .invalid }
        guard confirmed.keys.allSatisfy({ fresh[$0] == nil }) else { return .awaitingDeletion }
        return .removed(removed)
    }
}

enum SimilarGroupingDeletionMaintenance {
    /// A maintained SUBSET, not the canonical greedy rerun: removing a blocking
    /// member can unlock a new group, but only explicit/full rediscovery finds it.
    /// Unchanged groups keep their exact stored minimum. Changed retained groups
    /// recompute only their own pairwise minimum with the original arithmetic.
    static func maintain(groups: [SimilarPhotoGroup], removing ids: Set<String>, threshold: Float,
                         checkAccess: @Sendable () throws -> Void) throws -> SimilarGroupingComputation {
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        var retained: [SimilarPhotoGroup] = []
        var metrics = SimilarGroupingComputationMetrics()
        for group in groups {
            try Task.checkCancellation()
            try checkAccess()
            var photos = group.photos.filter { !ids.contains($0.id) }
            guard photos.count >= 2 else { continue }
            guard photos.count != group.photos.count else { retained.append(group); continue }
            // v1 cache requires the first member to be the smallest ID. A deleted
            // seed is replaced without changing the existing cache format.
            if let first = photos.indices.min(by: { photos[$0].id < photos[$1].id }), first != 0 {
                let seed = photos.remove(at: first)
                photos.insert(seed, at: 0)
            }
            var norms: [Double] = []
            for photo in photos {
                try Task.checkCancellation()
                try EmbeddingValidation.validateUnit(photo.imageEmbedding, dimension: 768)
                norms.append(photo.imageEmbedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
            }
            var minimum: Float = 1
            for left in photos.indices {
                try Task.checkCancellation()
                try checkAccess()
                for right in photos.indices where right > left {
                    try Task.checkCancellation()
                    let dot = photos[left].imageEmbedding.withUnsafeBufferPointer { lhs in
                        photos[right].imageEmbedding.withUnsafeBufferPointer { rhs in
                            cblas_sdot(768, lhs.baseAddress!, 1, rhs.baseAddress!, 1)
                        }
                    }
                    let similarity = min(1, max(-1, Float(Double(dot) / (norms[left] * norms[right]))))
                    guard similarity.isFinite, similarity >= threshold else { throw SimilarGroupingCacheError.invalid }
                    metrics.memberScoreCount += 1
                    minimum = min(minimum, similarity)
                }
            }
            retained.append(SimilarPhotoGroup(id: photos[0].id, photos: photos, minimumSimilarity: minimum))
        }
        retained.sort { $0.photos.count == $1.photos.count ? $0.id < $1.id : $0.photos.count > $1.photos.count }
        try Task.checkCancellation()
        try checkAccess()
        return SimilarGroupingComputation(groups: retained, metrics: metrics)
    }
}