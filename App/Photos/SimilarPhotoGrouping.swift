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
    /// Valid fresh groups can still be used when optional persistence fails.
    /// Nil means no persistence failure was reported, not an unconditional claim
    /// that a synthetic/legacy result was written to disk.
    let persistenceIssue: String?

    init(groups: [SimilarPhotoGroup], candidateCount: Int, staleCount: Int,
         unindexedCount: Int, threshold: Float,
         validateAccess: @escaping @Sendable () throws -> Void = {},
         validatePhotos: @escaping @Sendable ([String]) throws -> Void = { _ in },
         validatePublicationEpoch: @escaping @Sendable () throws -> Void = {},
         persistenceIssue: String? = nil) {
        self.groups = groups
        self.candidateCount = candidateCount
        self.staleCount = staleCount
        self.unindexedCount = unindexedCount
        self.threshold = threshold
        self.validateAccess = validateAccess
        self.validatePhotos = validatePhotos
        self.validatePublicationEpoch = validatePublicationEpoch
        self.persistenceIssue = persistenceIssue
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

enum SimilarPhotoGroupingRestore: Sendable {
    case missing
    case restored(SimilarPhotoGroupingResult)
    case stale
}

protocol SimilarPhotoGrouping: Sendable {
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore
    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult
}

extension SimilarPhotoGrouping {
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore { .missing }
}

enum SimilarPhotoGroupingPolicy {
    static let defaultThreshold: Float = 0.90
    static let algorithmVersion = "greedy-disjoint-pairwise-cosine-v1"
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
    private static let dimension = SimilarGroupingPreparedInput.dimension

    static func group(photos: [IndexedPhoto], threshold: Float,
                      progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void = { _ in }) async throws -> [SimilarPhotoGroup] {
        try Task.checkCancellation()
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        let prepared = try SimilarGroupingPreparedInput(photos: photos)
        let result = try await compute(prepared: prepared, threshold: threshold, progress: progress, checkAccess: {})
        try Task.checkCancellation()
        return result.groups
    }

    /// One row-major N x 768 copy, O(N) scratch, never an N x N score matrix.
    /// Worst-case similarity work is O(N²D); per-seed ordering additionally costs
    /// O(N² log N) comparisons in the dense worst case. Seed-ineligible rows no
    /// longer enter the sort; mmul ranking and exact complete-link tests are
    /// unchanged. No approximation, device-time claim or incremental-score cache.
    static func compute(
        prepared: SimilarGroupingPreparedInput, threshold: Float,
        progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void = { _ in },
        checkAccess: @escaping @Sendable () throws -> Void = {}
    ) async throws -> SimilarGroupingComputation {
        try Task.checkCancellation()
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        try checkAccess()
        let ordered = prepared.photos
        let matrix = prepared.matrix
        let norms = prepared.norms
        var metrics = SimilarGroupingComputationMetrics()
        var state = SimilarPhotoGroupingProgress(total: ordered.count)
        try checkAccess()
        try Task.checkCancellation()
        await progress(state)
        try Task.checkCancellation()
        try checkAccess()

        var assigned = [Bool](repeating: false, count: ordered.count)
        var scores = [Float](repeating: 0, count: ordered.count)
        var seedScores = [Float](repeating: 0, count: ordered.count)
        var candidates: [Int] = []
        candidates.reserveCapacity(ordered.count)
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
            metrics.matrixMultiplyCount += 1
            try Task.checkCancellation()
            candidates.removeAll(keepingCapacity: true)
            try matrix.withUnsafeBufferPointer { buffer in
                for index in ordered.indices {
                    try Task.checkCancellation()
                    guard index != seed, !assigned[index] else { continue }
                    let dot = cblas_sdot(Int32(dimension), buffer.baseAddress! + seed * dimension, 1,
                                         buffer.baseAddress! + index * dimension, 1)
                    let similarity = cosine(dot: dot, normProduct: norms[seed] * norms[index])
                    metrics.seedScoreCount += 1
                    // mmul and sdot can round differently. ONLY the original
                    // exact seed test can exclude a row, never its ranking score.
                    guard similarity >= threshold else { continue }
                    seedScores[index] = similarity
                    scores[index] = cosine(dot: scores[index], normProduct: norms[seed] * norms[index])
                    candidates.append(index)
                }
            }
            metrics.sortCandidateCount += candidates.count
            try candidates.sort {
                try Task.checkCancellation()
                metrics.sortComparisonCount += 1
                return scores[$0] == scores[$1] ? ordered[$0].id < ordered[$1].id : scores[$0] > scores[$1]
            }
            assigned[seed] = true
            state.completed += 1
            var members = [seed]
            var minimum: Float = 1
            for candidate in candidates {
                try Task.checkCancellation()
                var candidateMinimum = min(Float(1), seedScores[candidate])
                let accepted = try matrix.withUnsafeBufferPointer { buffer -> Bool in
                    // The seed was checked once above, in the same operand
                    // order. All remaining checks retain original member order.
                    for member in members.dropFirst() {
                        try Task.checkCancellation()
                        let dot = cblas_sdot(Int32(dimension), buffer.baseAddress! + member * dimension, 1,
                                             buffer.baseAddress! + candidate * dimension, 1)
                        let similarity = cosine(dot: dot, normProduct: norms[member] * norms[candidate])
                        metrics.memberScoreCount += 1
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
        return SimilarGroupingComputation(groups: groups, metrics: metrics)
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
    private let suppliedCache: SimilarGroupingCache?
    private let defaultLocation: @Sendable () throws -> SimilarGroupingLocation
    private var operationID = UUID()
    /// Completed data only: no old Photos scope, live monitor or validation
    /// closures. Pausing UI need not discard valid work after a disk-write error.
    private var resident: (payload: SimilarGroupingCachePayload, persistenceIssue: String?)?
    /// Complete inputs, not just returned group members. No live scopes, monitors
    /// or closures survive here. Restore cannot reconstruct missing singletons.
    private var preparedResident: (key: SimilarGroupingPreparedKey, input: SimilarGroupingPreparedInput)?
    private let reportMetrics: (@Sendable (SimilarGroupingWorkMetrics) -> Void)?

    init(library: any PhotoLibraryIndexing, directory: URL? = nil,
         encoders: any PhotoEncoding = CoreMLEncoders(), cache: SimilarGroupingCache? = nil,
         reportMetrics: (@Sendable (SimilarGroupingWorkMetrics) -> Void)? = nil,
         defaultLocation: @escaping @Sendable () throws -> SimilarGroupingLocation = { try SimilarGroupingLocation.system() }) {
        self.library = library
        self.directory = directory
        self.encoders = encoders
        self.suppliedCache = cache
        self.defaultLocation = defaultLocation
        self.reportMetrics = reportMetrics
    }

    /// Cold reuse reads metadata and opaque SQLite image BLOBs twice for durable
    /// identity. It never decodes source JSON, computes similarities, prepares a
    /// model, requests pixels, indexes, performs OCR, repairs or writes a cache.
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        // Invocation-local: this actor can reenter while resource/SQLite reads await.
        var phase: SimilarCleanupPhase = .photos
        do {
            try Task.checkCancellation()
            try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
            guard library.canReadImages else { throw AppFailure.permission }
            let ticket = UUID()
            operationID = ticket
            let access = SimilarGroupingAccess(library: library, authorization: library.authorizationStatusRawValue,
                                               generation: library.changeGeneration)
            let initial = try access.snapshot()
            phase = .resources
            let manifest = try await encoders.inspectResources()
            phase = .sourceCheck
            try check(ticket, access: access)
            phase = .resources
            try manifest.validate()
            let model = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
            phase = .indexLocation
            let location = try directory.map { SimilarGroupingLocation(directory: $0) } ?? defaultLocation()
            phase = .sourceOpen
            let authority = try SimilarGroupingSourceAuthority(location: location)
            let cache = suppliedCache ?? SimilarGroupingCache(directory: location.directory)
            let reader = SQLitePhotoStore(directory: location.directory, readOnly: true)
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            let source = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: Set(initial.keys), authority: authority)
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .cacheRead
            let preparedKey = try SimilarGroupingPreparedKey(authorized: initial,
                imagePayloadSignature: source.imagePayloadSignature, modelVersion: model, authorization: access.authorization)
            if preparedResident?.key != preparedKey { preparedResident = nil }
            let key = try SimilarGroupingCacheKey(authorized: initial, imagePayloadSignature: source.imagePayloadSignature,
                                                 modelVersion: model, authorization: access.authorization, threshold: threshold)
            let saved: SimilarGroupingCacheRead
            let persistenceIssue: String?
            if let resident, resident.payload.key == key {
                saved = .restored(try resident.payload.validated(authorized: initial, indexed: source.revisions))
                persistenceIssue = resident.persistenceIssue
            } else {
                saved = try cache.read(key: key, authorized: initial, indexed: source.revisions)
                persistenceIssue = nil
            }
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .photos
            try access.requireSnapshot(initial)
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            let finalSource = try await reader.groupingInputSnapshot(modelVersion: model, accessibleIDs: Set(initial.keys), authority: authority)
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            guard finalSource == source else { throw Self.indexChanged() }
            switch saved {
            // A previous in-memory completion with a different key is stale, not a
            // cold first entry, even if that completion could not be written to disk.
            case .missing: return resident == nil ? .missing : .stale
            case .stale: return .stale
            case .restored(let value):
                phase = .sourceCheck
                let result = try makeResult(groups: value.groups, candidateCount: value.candidateCount,
                                            staleCount: value.staleCount, unindexedCount: value.unindexedCount,
                                            threshold: value.threshold, initial: initial, access: access,
                                            authority: authority, persistenceIssue: persistenceIssue)
                phase = .cacheRead
                let payload = try SimilarGroupingCachePayload(groups: value.groups, candidateCount: value.candidateCount,
                    staleCount: value.staleCount, unindexedCount: value.unindexedCount, key: key)
                phase = .sourceCheck
                try check(ticket, access: access, authority: authority)
                resident = (payload, persistenceIssue)
                return .restored(result)
            }
        } catch {
            preparedResident = nil
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SimilarCleanupDiagnostic.classify(error, phase: phase)
        }
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        var phase: SimilarCleanupPhase = .photos
        var metrics = SimilarGroupingWorkMetrics()
        do {
            try Task.checkCancellation()
            try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
            guard library.canReadImages else { throw AppFailure.permission }
            let ticket = UUID()
            operationID = ticket
            let access = SimilarGroupingAccess(library: library, authorization: library.authorizationStatusRawValue,
                                               generation: library.changeGeneration)
            let initial = try access.snapshot() // Full snapshot 1: access and revisions.
            phase = .resources
            let manifest = try await encoders.inspectResources() // Metadata only, not prepare/inference.
            phase = .sourceCheck
            try check(ticket, access: access)
            phase = .resources
            try manifest.validate()
            let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
            phase = .indexLocation
            let location = try directory.map { SimilarGroupingLocation(directory: $0) } ?? defaultLocation()
            phase = .sourceOpen
            let authority = try SimilarGroupingSourceAuthority(location: location)
            let reader = SQLitePhotoStore(directory: location.directory, readOnly: true)
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            let source = try await reader.groupingInputSnapshot(modelVersion: cacheVersion, accessibleIDs: Set(initial.keys), authority: authority)
            metrics.sourceSnapshotCount += 1
            let indexed = source.revisions
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            let preparedKey = try SimilarGroupingPreparedKey(authorized: initial,
                imagePayloadSignature: source.imagePayloadSignature, modelVersion: cacheVersion, authorization: access.authorization)
            if preparedResident?.key != preparedKey { preparedResident = nil }
            // Capture immutable data before the next await (actor reentrancy).
            let reusable = preparedResident?.input
            var eligible = Set<String>()
            for (id, revision) in initial {
                try Task.checkCancellation()
                if let stored = indexed[id], SimilarGroupingDigest.sameRevision(stored, revision) { eligible.insert(id) }
            }
            // Exclude STALE modification OR creation times before any vector decoding.
            // Old models and inaccessible rows likewise cannot cause a vector error here.
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            let records: [IndexedPhoto]
            if let reusable {
                // Do NOT remove the middle durable read on a hit. Hash all
                // authorized active-model BLOBs again, without JSON decoding.
                let middle = try await reader.groupingInputSnapshot(modelVersion: cacheVersion,
                    accessibleIDs: Set(initial.keys), authority: authority)
                metrics.sourceSnapshotCount += 1
                phase = .sourceCheck
                try check(ticket, access: access, authority: authority)
                phase = .indexRead
                guard middle == source else { throw Self.indexChanged() }
                records = reusable.photos
                metrics.preparedInputReuseCount = 1
            } else {
                records = try await reader.groupingImageRecords(modelVersion: cacheVersion, accessibleIDs: Set(initial.keys),
                            eligibleIDs: eligible, expectedSnapshot: source, authority: authority)
                metrics.sourceSnapshotCount += 1
                metrics.decodedRowCount = records.count
            }
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            guard records.count == eligible.count else { throw Self.indexChanged() }
            for record in records {
                try Task.checkCancellation()
                let cachedRevision = PhotoRevision(id: record.id, modificationTime: record.modificationTime,
                                                   creationTime: record.creationTime)
                guard let revision = initial[record.id], eligible.contains(record.id),
                      SimilarGroupingDigest.sameRevision(cachedRevision, revision) else {
                    throw Self.indexChanged()
                }
            }
            phase = .photos
            try access.requireSnapshot(initial) // Full snapshot 2: pre-compute.
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .compute
            let validateComputeAccess: @Sendable () throws -> Void = {
                do {
                    try access.validateEpoch()
                    try authority.validate()
                    try access.validateEpoch()
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    throw SimilarCleanupDiagnostic.classify(error, phase: .sourceCheck)
                }
            }
            // Preserve the pre-preparation authority fence as well as the
            // compute entry/progress fences, including on the cold path.
            try validateComputeAccess()
            let prepared: SimilarGroupingPreparedInput
            if let reusable { prepared = reusable }
            else {
                prepared = try SimilarGroupingPreparedInput(photos: records)
                metrics.preparationCount = 1
            }
            let computation = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: threshold,
                progress: progress, checkAccess: validateComputeAccess)
            let groups = computation.groups
            metrics.computation = computation.metrics
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .photos
            try access.requireSnapshot(initial) // Full snapshot 3: final.
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            let finalSource = try await reader.groupingInputSnapshot(modelVersion: cacheVersion, accessibleIDs: Set(initial.keys), authority: authority)
            metrics.sourceSnapshotCount += 1
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            phase = .indexRead
            guard finalSource == source else { throw Self.indexChanged() }
            phase = .cacheWrite
            let key = try SimilarGroupingCacheKey(authorized: initial, imagePayloadSignature: source.imagePayloadSignature,
                                                 modelVersion: cacheVersion, authorization: access.authorization, threshold: threshold)
            let payload = try SimilarGroupingCachePayload(groups: groups, candidateCount: eligible.count,
                staleCount: indexed.count - eligible.count, unindexedCount: initial.count - indexed.count, key: key)
            _ = try payload.validated(authorized: initial, indexed: indexed)
            let cache = suppliedCache ?? SimilarGroupingCache(directory: location.directory)
            var persistenceIssue: String?
            do {
                try cache.save(groups: groups, candidateCount: eligible.count, staleCount: indexed.count - eligible.count,
                               unindexedCount: initial.count - indexed.count, key: key,
                               authorized: initial, indexed: indexed,
                               validate: {
                                   do {
                                       try access.validateEpoch()
                                       try authority.validate()
                                       try access.validateEpoch()
                                   } catch {
                                       if error is CancellationError || Task.isCancelled { throw CancellationError() }
                                       throw SimilarCleanupDiagnostic.classify(error, phase: .sourceCheck)
                                   }
                               })
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                     // A typed authority failure is already fatal: preserve its first
                     // cause rather than replacing it with a later Photos/source error.
                     // This path cannot publish groups or turn the failure into a warning.
                     if let diagnostic = error as? SimilarCleanupDiagnostic,
                         diagnostic.code != .cacheUnwritable { throw diagnostic }
                // Optional cache I/O may fail, but a changed source is NOT a warning
                // authorizing stale groups. Recheck BOTH authorities before recovery.
                phase = .sourceCheck
                try check(ticket, access: access, authority: authority)
                persistenceIssue = "SG-CACHE-WRITE\n本次分组可正常使用，但未能保存；下次打开可能需要重新分组。"
            }
            phase = .sourceCheck
            try check(ticket, access: access, authority: authority)
            let result = try makeResult(groups: groups, candidateCount: eligible.count, staleCount: indexed.count - eligible.count,
                                  unindexedCount: initial.count - indexed.count, threshold: threshold,
                                  initial: initial, access: access, authority: authority, persistenceIssue: persistenceIssue)
            try check(ticket, access: access, authority: authority)
            resident = (payload, persistenceIssue)
            // Install only after the final source/publication/save fences. A
            // failed/superseded operation never installs partially prepared data.
            preparedResident = (preparedKey, prepared)
            reportMetrics?(metrics)
            return result
        } catch {
            preparedResident = nil
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw SimilarCleanupDiagnostic.classify(error, phase: phase)
        }
    }

    private static func indexChanged() -> SimilarCleanupDiagnostic {
        SimilarCleanupDiagnostic(phase: .indexRead, code: .indexSnapshotChanged)
    }

    private func check(_ ticket: UUID, access: SimilarGroupingAccess,
                       authority: SimilarGroupingSourceAuthority? = nil) throws {
        try access.validateEpoch()
        try authority?.validate()
        try access.validateEpoch()
        guard ticket == operationID else { throw CancellationError() }
    }

    /// Identical fresh closures for computed and restored results. Never persist
    /// closures or reuse an old generation. prepareForPublication stays off-main.
    private func makeResult(groups: [SimilarPhotoGroup], candidateCount: Int, staleCount: Int,
                            unindexedCount: Int, threshold: Float, initial: [String: PhotoRevision],
                            access: SimilarGroupingAccess, authority: SimilarGroupingSourceAuthority,
                            persistenceIssue: String? = nil) throws -> SimilarPhotoGroupingResult {
        var returned: [String: PhotoRevision] = [:]
        for group in groups {
            for photo in group.photos {
                try Task.checkCancellation()
                returned[photo.id] = initial[photo.id]
            }
        }
        let returnedRevisions = returned
        let returnedIDs = returned.keys.sorted()
        let validateLive: @Sendable () throws -> Void = {
            try access.validateEpoch()
            try authority.validate()
            // Preserve the existing final Photos epoch read even if a Photos
            // notification arrives during the cheap SQLite checks.
            try access.validateEpoch()
        }
        let validatePhotos: @Sendable ([String]) throws -> Void = { ids in
            try validateLive()
            var requestedIDs: [String] = []
            var requested = Set<String>()
            for id in ids {
                try Task.checkCancellation()
                    guard !id.isEmpty, let expected = returnedRevisions[id],
                        Data(id.utf8) == Data(expected.id.utf8) else {
                    throw SimilarGroupingAccess.changed()
                }
                if requested.insert(id).inserted { requestedIDs.append(id) }
            }
            if !requestedIDs.isEmpty {
                if let batch = access.library as? any PhotoRevisionBatchReading {
                    let revisions = try batch.currentRevisions(ids: requestedIDs)
                    try validateLive()
                    guard revisions.count == requestedIDs.count else { throw SimilarGroupingAccess.changed() }
                    var remaining = requested
                    for revision in revisions {
                        try Task.checkCancellation()
                        guard remaining.remove(revision.id) != nil,
                            let expected = returnedRevisions[revision.id],
                            SimilarGroupingDigest.sameRevision(expected, revision) else {
                            throw SimilarGroupingAccess.changed()
                        }
                    }
                    guard remaining.isEmpty else { throw SimilarGroupingAccess.changed() }
                } else {
                    for id in requestedIDs {
                        try Task.checkCancellation()
                        guard let current = access.library.currentRevision(id: id), let expected = returnedRevisions[id],
                              SimilarGroupingDigest.sameRevision(current, expected) else {
                            throw SimilarGroupingAccess.changed()
                        }
                    }
                }
            }
            // PhotoKit notifications may change the epoch during synchronous
            // metadata reads. Nil generations still check actual full revisions.
            try validateLive()
        }
        try validateLive()
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: candidateCount,
                          staleCount: staleCount,
                          unindexedCount: unindexedCount, threshold: threshold,
                          validateAccess: {
                              try validatePhotos(returnedIDs)
                              // No notification generation means member-only reads
                              // cannot protect singleton/unindexed/zero-group counts.
                              // prepareForPublication performs this OFF MainActor.
                              if access.generation == nil { try access.requireSnapshot(initial) }
                              try validateLive()
                          }, validatePhotos: validatePhotos,
                          validatePublicationEpoch: validateLive,
                          persistenceIssue: persistenceIssue)
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

    func requireSnapshot(_ expected: [String: PhotoRevision]) throws {
        let current = try snapshot()
        guard current.count == expected.count else { throw Self.changed() }
        for (id, revision) in current {
            try Task.checkCancellation()
            guard let original = expected[id], SimilarGroupingDigest.sameRevision(original, revision) else {
                throw Self.changed()
            }
        }
        try validateEpoch()
    }
}