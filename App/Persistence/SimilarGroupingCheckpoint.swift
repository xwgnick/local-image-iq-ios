import Foundation
import ImageIQCore

enum SimilarGroupingCheckpointRead: Sendable {
    case missing, stale
    case restored(SimilarGroupingCheckpointState)
}

struct SimilarGroupingCheckpointEnvelope: Codable {
    let magic: String
    let schema: Int
    let payload: Data
    let sha256: Data
}

struct SimilarGroupingCheckpointPayload: Codable {
    let key: SimilarGroupingCacheKey
    let state: SimilarGroupingCheckpointState
}

/// Only whole greedy seeds are committed; in-flight candidate work is never published.
struct SimilarGroupingCheckpointState: Codable, Sendable {
    struct Group: Codable, Sendable {
        let members: [Int]
        let minimumBits: UInt32
    }
    let nextSeed: Int
    let assigned: [Bool]
    let groups: [Group]

    var completed: Int { assigned.filter { $0 }.count }

    func validate(count: Int, threshold: Float) throws {
        guard assigned.count == count, (0...count).contains(nextSeed),
              assigned.prefix(nextSeed).allSatisfy({ $0 }) else {
            throw SimilarGroupingCacheError.invalid
        }
        var seen = Set<Int>()
        var previousSeed = -1
        for group in groups {
            let minimum = Float(bitPattern: group.minimumBits)
            guard group.members.count >= 2, let seed = group.members.first,
                  seed > previousSeed, seed < nextSeed, minimum.isFinite, minimum >= threshold, minimum <= 1 else {
                throw SimilarGroupingCacheError.invalid
            }
            previousSeed = seed
            for member in group.members {
                guard assigned.indices.contains(member), assigned[member], seen.insert(member).inserted else {
                    throw SimilarGroupingCacheError.invalid
                }
            }
            guard group.members.dropFirst().allSatisfy({ $0 > seed }) else {
                throw SimilarGroupingCacheError.invalid
            }
        }
        guard (nextSeed..<count).allSatisfy({ !assigned[$0] || seen.contains($0) }) else {
            throw SimilarGroupingCacheError.invalid
        }
    }
}

actor SimilarGroupingCheckpointWriter {
    private let cache: SimilarGroupingCache
    private let key: SimilarGroupingCacheKey
    private(set) var persistenceIssue: String?

    init(cache: SimilarGroupingCache, key: SimilarGroupingCacheKey) {
        self.cache = cache
        self.key = key
    }

    func save(_ state: SimilarGroupingCheckpointState, validate: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        try validate()
        guard persistenceIssue == nil else { return }
        do {
            try cache.saveCheckpoint(state, key: key, validate: validate)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let diagnostic = error as? SimilarCleanupDiagnostic,
               diagnostic.code != .cacheUnwritable { throw diagnostic }
            try validate()
            persistenceIssue = "SG-CHECKPOINT-WRITE\n未能保存分组断点；本次可继续计算，若中断可能需要重新计算。"
        }
    }
}
