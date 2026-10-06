import Accelerate
import Foundation
import ImageIQCore

/// Optional metadata-only batch access; legacy injected libraries keep per-ID reads.
protocol PhotoRevisionBatchReading: Sendable {
    func currentRevisions(ids: [String]) throws -> [PhotoRevision]
}

struct SimilarPhotoGroup: Identifiable, Sendable {
    let id: String
    let photos: [IndexedPhoto]
    let minimumSimilarity: Float
}

struct SimilarPhotoGroupingProgress: Sendable, Equatable {
    var total = 0
    var completed = 0
    var groupCount = 0
    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}

struct SimilarPhotoGroupingResult: Sendable {
    let groups: [SimilarPhotoGroup]
    let candidateCount: Int
    let staleCount: Int
    let unindexedCount: Int
    let threshold: Float
    let validateAccess: @Sendable () throws -> Void
    let validatePhotos: @Sendable ([String]) throws -> Void
    let validatePublicationEpoch: @Sendable () throws -> Void

    init(groups: [SimilarPhotoGroup], candidateCount: Int, staleCount: Int,
         unindexedCount: Int, threshold: Float,
         validateAccess: @escaping @Sendable () throws -> Void = {},
         validatePhotos: @escaping @Sendable ([String]) throws -> Void = { _ in },
         validatePublicationEpoch: @escaping @Sendable () throws -> Void = {}) {
        self.groups = groups
        self.candidateCount = candidateCount
        self.staleCount = staleCount
        self.unindexedCount = unindexedCount
        self.threshold = threshold
        self.validateAccess = validateAccess
        self.validatePhotos = validatePhotos
        self.validatePublicationEpoch = validatePublicationEpoch
    }

    /// This non-actor async method runs on Swift 5's generic executor, including
    /// when called from MainActor. The caller must recheck its publication state
    /// and validatePublicationEpoch immediately before publishing, without awaiting.
    func prepareForPublication() async throws {
        try Task.checkCancellation()
        try validateAccess()
        try Task.checkCancellation()
    }
}

protocol SimilarPhotoGrouping: Sendable {
    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult
}

enum SimilarPhotoGroupingPolicy {
    static let defaultThreshold: Float = 0.96
    static let thresholdRange: ClosedRange<Float> = 0.50...0.99
    /// Exact integer ticks; shared by the slider and its boundary tests.
    static let sliderTicks: ClosedRange<Double> = 50...99

    private struct InvalidThreshold: LocalizedError {
        var errorDescription: String? { "相似度设置无效，请重新选择。" }
    }

    /// A cosine threshold, NOT a probability or a percentage of duplicate pixels.
    static func validate(threshold: Float) throws {
        guard threshold.isFinite, thresholdRange.contains(threshold) else {
            throw InvalidThreshold()
        }
    }
}

/// Dedicated semantic cleanup suggestions, not pixel-duplicate detection. Even a
/// high threshold does not guarantee the same subject, event, or interchangeable
/// photos. Nothing here chooses a keeper, deletes photos, or changes search ranks.
enum SimilarPhotoGrouper {
    private static let dimension = 768

    static func group(photos: [IndexedPhoto], threshold: Float,
                      progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void = { _ in }) async throws -> [SimilarPhotoGroup] {
        let groups = try await compute(photos: photos, threshold: threshold, progress: progress, checkAccess: {})
        try Task.checkCancellation()
        return groups
    }

    /// One row-major N x 768 copy, O(N) scratch, never an N x N score matrix.
    /// Worst-case similarity work is O(N²D); per-seed ordering additionally costs
    /// O(N² log N) comparisons in the worst case. No device CPU-time claim, date
    /// window, group-size cap, resource ceiling, or elapsed-time progress heuristic.
    fileprivate static func compute(
        photos: [IndexedPhoto], threshold: Float,
        progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void,
        checkAccess: @escaping @Sendable () throws -> Void
    ) async throws -> [SimilarPhotoGroup] {
        try Task.checkCancellation()
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        try checkAccess()
        let ordered = try photos.sorted {
            try Task.checkCancellation()
            return $0.id < $1.id
        }
        var matrix: [Float] = []
        matrix.reserveCapacity(ordered.count * dimension)
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
            try EmbeddingValidation.validateUnit(photo.imageEmbedding, dimension: dimension)
            // Correct the existing unit-validation tolerance in scalar cosine
            // arithmetic, without renormalizing or modifying cached vectors.
            norms.append(photo.imageEmbedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
            matrix.append(contentsOf: photo.imageEmbedding)
        }
        var state = SimilarPhotoGroupingProgress(total: ordered.count)
        try checkAccess()
        try Task.checkCancellation()
        await progress(state)
        try Task.checkCancellation()
        try checkAccess()

        var assigned = [Bool](repeating: false, count: ordered.count)
        var scores = [Float](repeating: 0, count: ordered.count)
        var groups: [SimilarPhotoGroup] = []
        for seed in ordered.indices {
            try Task.checkCancellation()
            guard !assigned[seed] else { continue }
            try checkAccess()
            // vDSP's native-size lengths do not impose a BLAS Int32 row-count
            // ceiling. Multiplying N x D by D x 1 queries every row for this seed.
            matrix.withUnsafeBufferPointer { buffer in
                scores.withUnsafeMutableBufferPointer { output in
                    vDSP_mmul(buffer.baseAddress!, 1,
                              buffer.baseAddress! + seed * dimension, 1,
                              output.baseAddress!, 1,
                              vDSP_Length(ordered.count), 1, vDSP_Length(dimension))
                }
            }
            try Task.checkCancellation()
            var candidates: [Int] = []
            for index in ordered.indices {
                try Task.checkCancellation()
                guard index != seed, !assigned[index] else { continue }
                scores[index] = cosine(dot: scores[index], normProduct: norms[seed] * norms[index])
                candidates.append(index)
            }
            try candidates.sort {
                try Task.checkCancellation()
                return scores[$0] == scores[$1] ? ordered[$0].id < ordered[$1].id : scores[$0] > scores[$1]
            }
            assigned[seed] = true
            state.completed += 1
            var members = [seed]
            var minimum: Float = 1
            for candidate in candidates {
                try Task.checkCancellation()
                var candidateMinimum: Float = 1
                let accepted = try matrix.withUnsafeBufferPointer { buffer -> Bool in
                    for member in members {
                        try Task.checkCancellation()
                        let dot = cblas_sdot(Int32(dimension), buffer.baseAddress! + member * dimension, 1,
                                             buffer.baseAddress! + candidate * dimension, 1)
                        let similarity = cosine(dot: dot, normProduct: norms[member] * norms[candidate])
                        // No epsilon or relaxed threshold. Verify even the seed
                        // with sdot: matrix/vector reduction can round differently.
                        guard similarity >= threshold else { return false }
                        candidateMinimum = min(candidateMinimum, similarity)
                    }
                    return true
                }
                if accepted {
                    members.append(candidate)
                    assigned[candidate] = true
                    state.completed += 1
                    minimum = min(minimum, candidateMinimum)
                }
            }
            if members.count >= 2 {
                groups.append(SimilarPhotoGroup(id: ordered[seed].id,
                                                photos: members.map { ordered[$0] }, minimumSimilarity: minimum))
                state.groupCount += 1
            }
            // Assigned members count immediately, including members skipped as
            // later seeds. Unmatched singletons count as processed candidates too.
            try Task.checkCancellation()
            try checkAccess()
            await progress(state)
            try Task.checkCancellation()
            try checkAccess()
        }
        try groups.sort {
            try Task.checkCancellation()
            return $0.photos.count == $1.photos.count ? $0.id < $1.id : $0.photos.count > $1.photos.count
        }
        try Task.checkCancellation()
        try checkAccess()
        return groups
    }

    private static func cosine(dot: Float, normProduct: Double) -> Float {
        // Only physical [-1, 1] rounding is clamped; never clamp to the threshold.
        min(1, max(-1, Float(Double(dot) / normProduct)))
    }
}

/// Explicit invocation only. Initialization does not inspect models, enumerate
/// Photos, open/create a database, index, request pixels, or schedule any work.
actor SimilarPhotoGroupingService: SimilarPhotoGrouping {
    private let library: any PhotoLibraryIndexing
    private let directory: URL?
    private let encoders: any PhotoEncoding

    init(library: any PhotoLibraryIndexing, directory: URL? = nil,
         encoders: any PhotoEncoding = CoreMLEncoders()) {
        self.library = library
        self.directory = directory
        self.encoders = encoders
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        try Task.checkCancellation()
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        guard library.canReadImages else { throw AppFailure.permission }
        let access = SimilarGroupingAccess(library: library, authorization: library.authorizationStatusRawValue,
                                           generation: library.changeGeneration)
        let initial = try access.snapshot() // Full snapshot 1: access and revisions.
        let manifest = try await encoders.inspectResources() // Metadata only, not prepare/inference.
        try access.validateEpoch()
        try manifest.validate()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let reader = SQLitePhotoStore(directory: try directory ?? SQLitePhotoStore.defaultDirectory(create: false), readOnly: true)
        let indexed = try await reader.searchPhotoRevisions(modelVersion: cacheVersion, accessibleIDs: Set(initial.keys))
        try access.validateEpoch()
        var eligible = Set<String>()
        for (id, revision) in initial {
            try Task.checkCancellation()
            if indexed[id] == revision { eligible.insert(id) }
        }
        // Exclude STALE modification OR creation times before any vector decoding.
        // Old models and inaccessible rows likewise cannot cause a vector error here.
        let records = try await reader.searchRecords(modelVersion: cacheVersion, accessibleIDs: eligible)
        try access.validateEpoch()
        guard records.count == eligible.count else { throw AppFailure.storage("The image index changed during grouping. Try again.") }
        for record in records {
            try Task.checkCancellation()
            let cachedRevision = PhotoRevision(id: record.photo.id, modificationTime: record.photo.modificationTime,
                                               creationTime: record.photo.creationTime)
            guard let revision = initial[record.photo.id], eligible.contains(record.photo.id),
                  cachedRevision == revision else {
                throw AppFailure.storage("The image index changed during grouping. Try again.")
            }
        }
        guard try access.snapshot() == initial else { throw SimilarGroupingAccess.changed() } // Full snapshot 2: pre-compute.
        let groups = try await SimilarPhotoGrouper.compute(photos: records.map(\.photo), threshold: threshold,
                                                         progress: progress, checkAccess: { try access.validateEpoch() })
        try access.validateEpoch()
        guard try access.snapshot() == initial else { throw SimilarGroupingAccess.changed() } // Full snapshot 3: final.
        var returned: [String: PhotoRevision] = [:]
        for group in groups {
            for photo in group.photos {
                try Task.checkCancellation()
                returned[photo.id] = initial[photo.id]
            }
        }
        let returnedRevisions = returned
        let returnedIDs = returned.keys.sorted()
        let validatePhotos: @Sendable ([String]) throws -> Void = { ids in
            try access.validateEpoch()
            var requestedIDs: [String] = []
            var requested = Set<String>()
            for id in ids {
                try Task.checkCancellation()
                guard !id.isEmpty, returnedRevisions[id] != nil else {
                    throw SimilarGroupingAccess.changed()
                }
                if requested.insert(id).inserted { requestedIDs.append(id) }
            }
            if !requestedIDs.isEmpty {
                if let batch = access.library as? any PhotoRevisionBatchReading {
                    let revisions = try batch.currentRevisions(ids: requestedIDs)
                    try access.validateEpoch()
                    guard revisions.count == requestedIDs.count else { throw SimilarGroupingAccess.changed() }
                    var remaining = requested
                    for revision in revisions {
                        try Task.checkCancellation()
                        guard remaining.remove(revision.id) != nil,
                              returnedRevisions[revision.id] == revision else {
                            throw SimilarGroupingAccess.changed()
                        }
                    }
                    guard remaining.isEmpty else { throw SimilarGroupingAccess.changed() }
                } else {
                    for id in ids {
                        try Task.checkCancellation()
                        guard access.library.currentRevision(id: id) == returnedRevisions[id] else {
                            throw SimilarGroupingAccess.changed()
                        }
                    }
                }
            }
            // PhotoKit notifications may change the epoch during synchronous
            // metadata reads. Nil generations still check actual full revisions.
            try access.validateEpoch()
        }
        try access.validateEpoch()
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: eligible.count,
                                          staleCount: indexed.count - eligible.count,
                                          unindexedCount: initial.count - indexed.count, threshold: threshold,
                                          validateAccess: { try validatePhotos(returnedIDs) }, validatePhotos: validatePhotos,
                                          validatePublicationEpoch: { try access.validateEpoch() })
    }
}

private struct SimilarGroupingAccess: Sendable {
    let library: any PhotoLibraryIndexing
    let authorization: Int?
    let generation: UInt64?

    static func changed() -> AppFailure {
        .photo("Photo access or revisions changed. Run similarity grouping again; the saved index is unchanged.")
    }

    func validateEpoch() throws {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard library.authorizationStatusRawValue == authorization, library.changeGeneration == generation else {
            throw Self.changed()
        }
    }

    func snapshot() throws -> [String: PhotoRevision] {
        try validateEpoch()
        let revisions = try library.enumerateAuthorizedImages()
        try validateEpoch()
        var result: [String: PhotoRevision] = [:]
        for revision in revisions {
            try Task.checkCancellation()
            guard !revision.id.isEmpty, revision.modificationTime.isFinite,
                  revision.creationTime?.isFinite != false, result[revision.id] == nil else {
                throw AppFailure.photo("Invalid or duplicate authorized photo metadata.")
            }
            result[revision.id] = revision
        }
        try validateEpoch()
        return result
    }
}