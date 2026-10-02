import Foundation
import ImageIQCore

enum LaunchStage: Sendable, Equatable {
    case checkingLibrary, preparingSearch
}

struct IndexProgress: Sendable, Equatable {
    var total = 0
    var completed = 0
    var encoded = 0
    var reused = 0
    var cloudSkipped = 0
    var failed = 0
    var localPreviews = 0
    var reducedPreviews = 0
    var networkPreviews = 0
    // Last-scan observations, not persisted GPS or a count of place embeddings.
    // A resolved label still counts when that photo's preview/encoding fails.
    var placeChecked = 0
    var gpsCount = 0
    var placeResolved = 0
    var noGPS = 0
    var noPlacePack = 0
    var outsidePlaceCoverage = 0
    var placeUnavailable = 0
    // Committed label changes/removals or geography refreshes of existing rows.
    var placeUpdated = 0
    var lastFailure: String?

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var summary: String {
        "\(completed)/\(total) checked · \(encoded) encoded · \(reused) reused · \(cloudSkipped) need network · \(failed) unavailable · \(localPreviews) local previews · \(reducedPreviews) reduced previews · \(networkPreviews) online-fallback previews"
    }
}

struct LibrarySummary: Sendable {
    var authorizedCount = 0
    /// False for lightweight launch/refresh: no current Photos enumeration was performed.
    var authorizedCountKnown = false
    var indexStatisticsKnown = true
    var indexedCount = 0
    var locatedCount = 0
    var modelVersion: String?
    var modelIssue: String?
    var placesDescription = "Checking optional offline boundaries…"
}

struct SearchResponse: Sendable {
    let summary: LibrarySummary
    let hits: [SearchHit]
    /// Synchronous check at MainActor publication, after the worker's actor hop.
    let validateAccess: @Sendable () throws -> Void

    init(summary: LibrarySummary, hits: [SearchHit],
         validateAccess: @escaping @Sendable () throws -> Void = {}) {
        self.summary = summary
        self.hits = hits
        self.validateAccess = validateAccess
    }
}

protocol PhotoWorkServicing: Sendable {
    func refresh() async throws -> LibrarySummary
    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport
    func clear() async throws -> LibrarySummary
}

extension PhotoWorkServicing {
    /// Keep existing injected services compatible; only production warms models.
    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        try Task.checkCancellation()
        await progress(.checkingLibrary)
        try Task.checkCancellation()
        let summary = try await refresh()
        try Task.checkCancellation()
        return summary
    }

    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        try Task.checkCancellation()
        throw AppFailure.photo("Photo diagnostics are unsupported by this service.")
    }
}

/// Called by AppState's serialized task chain. Actor isolation alone does NOT
/// serialize whole async jobs: the caller waits for a cancelled predecessor before
/// starting the next job, including time spent awaiting Photos/encoders/storage.
actor PhotoIndexWorker: PhotoWorkServicing {
    static let indexingWorkerCount = 20

    private let library: any PhotoLibraryIndexing
    private let encoders: any PhotoEncoding
    private let suppliedDirectory: URL?
    private var store: SQLitePhotoStore?
    private var places: OfflinePlaceResolver?
    private var placeMetadata: PlacePackMetadata?
    private let loadPlaceMetadata: @Sendable () -> PlacePackMetadata
    private let loadBoundaries: @Sendable () -> OfflinePlaceResolver
    private var placeVectors: [Data: [Float]] = [:]

    init(library: any PhotoLibraryIndexing, encoders: any PhotoEncoding = CoreMLEncoders(), directory: URL? = nil,
         resolver: OfflinePlaceResolver? = nil,
         metadataLoader: @escaping @Sendable () -> PlacePackMetadata = { PlacePackMetadata.bundled() },
         boundaryLoader: @escaping @Sendable () -> OfflinePlaceResolver = { OfflinePlaceResolver.bundled() }) {
        self.library = library
        self.encoders = encoders
        suppliedDirectory = directory
        places = resolver
        placeMetadata = resolver.map { PlacePackMetadata(version: $0.version, coverageDescription: $0.coverageDescription) }
        loadPlaceMetadata = metadataLoader
        loadBoundaries = boundaryLoader
    }

    private func storage() throws -> SQLitePhotoStore {
        if let store { return store }
        let directory = try suppliedDirectory ?? SQLitePhotoStore.defaultDirectory()
        let store = SQLitePhotoStore(directory: directory)
        self.store = store
        return store
    }

    private func boundaries() -> OfflinePlaceResolver {
        if let places { return places }
        let resolver = loadBoundaries()
        places = resolver
        placeMetadata = PlacePackMetadata(version: resolver.version, coverageDescription: resolver.coverageDescription)
        return resolver
    }

    private func geography() -> PlacePackMetadata {
        if let placeMetadata { return placeMetadata }
        let metadata = loadPlaceMetadata()
        placeMetadata = metadata
        return metadata
    }

    /// Automatic paths use a read-only connection; no creation, migration or pruning.
    private func reader() throws -> SQLitePhotoStore {
        let directory = try suppliedDirectory ?? SQLitePhotoStore.defaultDirectory(create: false)
        return SQLitePhotoStore(directory: directory, readOnly: true)
    }

    private func reconcile() async throws -> [PhotoRevision] {
        let snapshot = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        try await storage().reconcile(completeEnumeration: snapshot)
        placeVectors.removeAll() // Discard memory-only labels from an older authorization snapshot.
        return snapshot
    }

    func refresh() async throws -> LibrarySummary {
        try await readiness(prepareModels: false)
    }

    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        try await readiness(prepareModels: true, progress: progress)
    }

    private func readiness(prepareModels: Bool,
                           progress: (@Sendable (LaunchStage) async -> Void)? = nil) async throws -> LibrarySummary {
        try Task.checkCancellation()
        if let progress {
            await progress(.checkingLibrary)
            try Task.checkCancellation()
        }
        let metadata = geography()
        let manifest: ModelManifest
        do {
            try Task.checkCancellation()
            if prepareModels {
                if let progress { await progress(.preparingSearch) }
                try Task.checkCancellation()
                // Only the primary image/text models and tokenizer, not indexing
                // slots, previews, predictions or translation resources.
                manifest = try await encoders.prepare()
            } else {
                // Warm foreground refresh remains metadata-only; no model loads.
                manifest = try await encoders.inspectResources()
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return LibrarySummary(modelIssue: error.localizedDescription,
                                  placesDescription: metadata.coverageDescription)
        }
        try Task.checkCancellation()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        // Stored counts, NOT a current authorized-library count or vector validation.
        // The user decides when to reconcile and update this persisted snapshot.
        let counts = try await reader().storedCounts(modelVersion: cacheVersion, geographyVersion: metadata.version)
        try Task.checkCancellation()
        return LibrarySummary(indexedCount: counts.indexed,
                              locatedCount: counts.located, modelVersion: cacheVersion,
                      placesDescription: metadata.coverageDescription)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        let snapshot = try await reconcile()
        guard library.canReadImages else { throw AppFailure.permission }
        let manifest = try await encoders.prepare()
        try Task.checkCancellation()
        // The factory supplies exactly indexingWorkerCount image slots, scoped to this index
        // call, with extra image models loaded lazily only on cache misses.
        // Location encoding still uses the single parent-owned text encoder.
        let imageEncoders = try await encoders.makeIndexingImageEncoders()
        try Task.checkCancellation()
        guard imageEncoders.count == Self.indexingWorkerCount else {
            throw AppFailure.modelContract("Indexing requires exactly \(Self.indexingWorkerCount) image encoder slots.")
        }
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let resolver = boundaries()
        let store = try storage()
        var state = IndexProgress(total: snapshot.count)
        await progress(state)
        // Up to indexingWorkerCount children read/prepare/encode images; only the parent resolves
        // places, updates the text cache, saves and reports actual outcomes.
        // The sliding window includes finished-but-uncommitted items, so a slow
        // head can stall submission. This is NOT a whole-window batch barrier:
        // each ordered commit immediately frees one slot for its successor.
        // Finished results retain embeddings/errors, never preview pixels.
        try await withThrowingTaskGroup(of: PreparedIndexItem.self) { group in
            // Structured scope exit awaits ALL children, including late success
            // from cancelled PhotoKit requests or CoreML predictions. This covers
            // success, errors and cancellation, even if CoreML finishes late.
            // No Swift child can escape into the next serialized job. PhotoKit's
            // cancel API has no acknowledgement; its late callbacks are ignored
            // by PhotoRequestGate rather than claimed to have already stopped.
            defer { group.cancelAll() }
            let library = self.library
            var nextSubmit = 0
            var nextCommit = 0
            var pending: [Int: PreparedIndexItem] = [:]
            while nextSubmit < min(snapshot.count, Self.indexingWorkerCount) {
                try Task.checkCancellation()
                let snapshotIndex = nextSubmit
                let revision = snapshot[snapshotIndex]
                let imageEncoder = imageEncoders[snapshotIndex % Self.indexingWorkerCount]
                guard group.addTaskUnlessCancelled(operation: {
                    try await Self.prepare(revision, snapshotIndex: snapshotIndex,
                                           imageEncoder: imageEncoder, library: library, store: store,
                                           cacheVersion: cacheVersion, networkAllowed: networkAllowed)
                }) else { throw CancellationError() }
                nextSubmit += 1
            }
            while nextCommit < snapshot.count {
                try Task.checkCancellation()
                guard let item = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                guard library.canReadImages else { throw AppFailure.permission }
                pending[item.snapshotIndex] = item
                while let item = pending.removeValue(forKey: nextCommit) {
                    let outcome = try await indexPrepared(item, resolver: resolver, cacheVersion: cacheVersion,
                                                          store: store, networkAllowed: networkAllowed)
                    // No counters for speculative work or an uncommitted save.
                    state.record(outcome.place)
                    if outcome.reused { state.reused += 1 }
                    if outcome.placeUpdated { state.placeUpdated += 1 }
                    if outcome.cloudSkipped { state.cloudSkipped += 1 }
                    if let failure = outcome.failure {
                        state.failed += 1
                        state.lastFailure = failure
                    }
                    if let source = outcome.source {
                        state.encoded += 1
                        switch source {
                        case .localPreview: state.localPreviews += 1
                        case .localReducedPreview: state.reducedPreviews += 1
                        case .networkPreview: state.networkPreviews += 1
                        }
                    }
                    state.completed += 1
                    nextCommit += 1
                    await progress(state)
                    try Task.checkCancellation()
                    if nextSubmit < snapshot.count, nextSubmit < nextCommit + Self.indexingWorkerCount {
                        let snapshotIndex = nextSubmit
                        let revision = snapshot[snapshotIndex]
                        // A slot is reused only after its previous item's commit;
                        // the count-bounded window prevents overlapping slot owners.
                        let imageEncoder = imageEncoders[snapshotIndex % Self.indexingWorkerCount]
                        guard group.addTaskUnlessCancelled(operation: {
                            try await Self.prepare(revision, snapshotIndex: snapshotIndex,
                                                   imageEncoder: imageEncoder, library: library, store: store,
                                                   cacheVersion: cacheVersion, networkAllowed: networkAllowed)
                        }) else { throw CancellationError() }
                        nextSubmit += 1
                    }
                }
            }
            try Task.checkCancellation()
        }
        let current = try await reconcile()
        return try await summary(snapshot: current, manifest: manifest, resolver: resolver)
    }

    private enum PreparedImage: Sendable {
        case reused([Float])
        case encoded(embedding: [Float], source: IndexingImage.Source)
        case failed(Error)
    }

    private struct PreparedIndexItem: Sendable {
        let snapshotIndex: Int
        let revision: PhotoRevision
        let old: CachedPhoto?
        let image: PreparedImage
    }

    private struct IndexOutcome {
        let place: PhotoPlaceResult
        var reused = false
        var source: IndexingImage.Source?
        var placeUpdated = false
        var cloudSkipped = false
        var failure: String?
    }

    /// Child-only PhotoKit reading, preprocessing and image encoding. Cache hits
    /// bypass both PhotoKit and the image encoder. No location/text work, writes
    /// or progress here; return the exact snapshot position/revision and old row.
    private nonisolated static func prepare(_ revision: PhotoRevision, snapshotIndex: Int,
                                             imageEncoder: any PhotoImageEncoding, library: any PhotoLibraryIndexing,
                                             store: SQLitePhotoStore, cacheVersion: String,
                                             networkAllowed: Bool) async throws -> PreparedIndexItem {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let old = try await store.record(id: revision.id)
        try Task.checkCancellation()
        if let old, old.photo.modificationTime == revision.modificationTime, old.photo.modelVersion == cacheVersion {
            return PreparedIndexItem(snapshotIndex: snapshotIndex, revision: revision, old: old,
                                     image: .reused(old.photo.imageEmbedding))
        }
        guard library.canReadImages else { throw AppFailure.permission }
        let image: PreparedImage
        do {
            try Task.checkCancellation()
            let preview = try await library.indexImage(id: revision.id, networkAllowed: networkAllowed)
            try Task.checkCancellation()
            let embedding = try await imageEncoder.image(preview: preview)
            try Task.checkCancellation()
            image = .encoded(embedding: embedding, source: preview.source)
        } catch {
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
            // Let the parent classify preview/encoder errors in snapshot order,
            // retaining its fatal-versus-skip rules and place observations.
            image = .failed(error)
        }
        try Task.checkCancellation()
        return PreparedIndexItem(snapshotIndex: snapshotIndex, revision: revision, old: old, image: image)
    }

    private func indexPrepared(_ item: PreparedIndexItem, resolver: OfflinePlaceResolver, cacheVersion: String,
                               store: SQLitePhotoStore, networkAllowed: Bool) async throws -> IndexOutcome {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let revision = item.revision
        // Every checked asset, including image-cache hits and failed previews.
        // Passing the resolved label onward avoids a second PHAsset/GPS read.
        let place = library.placeResult(id: revision.id, resolver: resolver)
        var outcome = IndexOutcome(place: place)
        let label: String?
        if case .resolved(let value) = place { label = value } else { label = nil }
        let desiredText = label.map { "Photo taken in \($0)." }
        let placeChanged = item.old?.photo.location?.text != desiredText
            || (item.old != nil && item.old?.geographyVersion != resolver.version)
        let image: [Float]
        let reusable: Bool
        var source: IndexingImage.Source?
        do {
            try Task.checkCancellation()
            switch item.image {
            case .reused(let vector):
                image = vector
                reusable = true
            case .encoded(let embedding, let imageSource):
                image = embedding
                source = imageSource
                reusable = false
            case .failed(let error): throw error
            }
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
            guard library.canReadImages else { throw AppFailure.permission }
            if let failure = error as? AppFailure {
                switch failure {
                case .modelContract, .modelsMissing, .storage, .permission: throw failure
                case .cloudOnly where !networkAllowed:
                    outcome.cloudSkipped = true
                    return outcome
                default: break
                }
            }
            if !networkAllowed, PhotoImageRequestInfo.requiresNetwork(error) { outcome.cloudSkipped = true }
            else { outcome.failure = error.localizedDescription }
            return outcome
        }
        guard library.canReadImages else { throw AppFailure.permission }
        let needsSave = !reusable || placeChanged
        let location: PlaceEmbedding?
        if needsSave {
            location = try await self.location(label: label, cacheVersion: cacheVersion, store: store)
        } else { location = item.old?.photo.location }
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard library.currentRevision(id: revision.id) == revision else {
            outcome.failure = "A photo changed or became inaccessible during indexing; refresh and retry."
            return outcome
        }
        if needsSave {
            let photo = IndexedPhoto(id: revision.id, modificationTime: revision.modificationTime,
                                     modelVersion: cacheVersion, imageEmbedding: image, location: location,
                                     creationTime: revision.creationTime)
            try await store.save(CachedPhoto(photo: photo, geographyVersion: resolver.version))
            outcome.placeUpdated = placeChanged
        }
        outcome.reused = reusable
        outcome.source = source
        return outcome
    }

    private func location(label: String?, cacheVersion: String,
                          store: SQLitePhotoStore) async throws -> PlaceEmbedding? {
        try Task.checkCancellation()
        guard let label else { return nil }
        let text = "Photo taken in \(label)."
        let key = Data((cacheVersion + "\n" + text).utf8)
        if let vector = placeVectors[key] { return PlaceEmbedding(text: text, vector: vector) }
        let vector: [Float]
        if let cached = try await store.place(text: text, modelVersion: cacheVersion) { vector = cached }
        else {
            try Task.checkCancellation()
            vector = try await encoders.text(text)
        }
        try Task.checkCancellation()
        placeVectors[key] = vector
        return PlaceEmbedding(text: text, vector: vector)
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let authorization = library.authorizationStatusRawValue
        let generation = library.changeGeneration
        let snapshot = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        let manifest = try await encoders.prepare()
        let metadata = geography()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        // Filter by current access BEFORE decoding/scoring/location centering.
        // Edited but still accessible photos intentionally retain their last
        // manually indexed content until the user updates the index.
        let cached = try await reader().searchRecords(modelVersion: cacheVersion,
                                                      accessibleIDs: Set(snapshot.map(\.id)))
        let photos = cached.map { item in
            let photo = item.photo
            return IndexedPhoto(id: photo.id, modificationTime: photo.modificationTime,
                                modelVersion: photo.modelVersion, imageEmbedding: photo.imageEmbedding,
                                location: item.geographyVersion == metadata.version ? photo.location : nil,
                                creationTime: photo.creationTime)
        }
        let query = try await encoders.text(text)
        // Fetch display-only stored counts before the final access checks so no
        // suspended database operation can invalidate an already checked result.
        let counts = try await reader().storedCounts(modelVersion: cacheVersion, geographyVersion: metadata.version)
        try Task.checkCancellation()
        try validateSearchAccess(snapshot, authorization: authorization)
        // Core owns exact scoring, distinct-place mean, missing-place neutrality
        // and deterministic ties. There are no date/place predicates or rerankers.
        let hits = try VectorSearch.search(query: query, photos: photos, limit: limit, locationWeight: locationWeight)
        try Task.checkCancellation()
        // Also catch edits/access changes whose PhotoKit observer callback has not
        // yet reached MainActor. Never publish scores centered on a stale library.
        try validateSearchAccess(snapshot, authorization: authorization)
                let library = self.library
                let returnedIDs = Set(hits.map(\.id))
                let returnedRevisions = snapshot.filter { returnedIDs.contains($0.id) }
                return SearchResponse(summary: LibrarySummary(authorizedCount: snapshot.count, authorizedCountKnown: true,
                                                       indexedCount: counts.indexed, locatedCount: counts.located,
                                                       modelVersion: cacheVersion, placesDescription: metadata.coverageDescription),
                                                            hits: hits, validateAccess: {
                        guard library.canReadImages else { throw AppFailure.permission }
                        guard library.authorizationStatusRawValue == authorization,
                                    library.changeGeneration == generation,
                                    returnedRevisions.allSatisfy({ library.currentRevision(id: $0.id) == $0 }) else {
                                throw AppFailure.photo("Photo access changed before results could be displayed. Search again.")
                        }
                })
    }

    private func validateSearchAccess(_ snapshot: [PhotoRevision], authorization: Int?) throws {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let current = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard authorization == library.authorizationStatusRawValue, current == snapshot else {
            throw AppFailure.photo("The authorized library changed during search. Search again; the saved index is unchanged.")
        }
    }

    /// Read-only observation, not a quality fix. Uses the same local preview and
    /// encoders as indexing, but never storage(), reconciliation, place lookup,
    /// progress callbacks, persistent writes or a network/original-data fallback.
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let authorization = library.authorizationStatusRawValue
        let snapshot = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        guard let selected = snapshot.first(where: { $0.id == id }) else {
            throw AppFailure.photo("This photo is no longer in the authorized library.")
        }
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        let manifest = try await encoders.prepare()
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        try manifest.validate()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let metadata = geography()
        let directory = try suppliedDirectory ?? SQLitePhotoStore.defaultDirectory(create: false)
        let reader = SQLitePhotoStore(directory: directory, readOnly: true)
        let cached = try await reader.diagnosticSnapshot(modelVersion: cacheVersion, selectedID: id)
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        // Match normal reconciliation's revision rule, but filter ONLY in memory.
        let revisions = Dictionary(snapshot.map { ($0.id, $0.modificationTime) }, uniquingKeysWith: { _, last in last })
        let photos: [IndexedPhoto] = cached.records.compactMap { record in
            let photo = record.photo
            guard revisions[photo.id] == photo.modificationTime else { return nil }
            return IndexedPhoto(id: photo.id, modificationTime: photo.modificationTime,
                                modelVersion: photo.modelVersion, imageEmbedding: photo.imageEmbedding,
                                location: record.geographyVersion == metadata.version ? photo.location : nil,
                                creationTime: photo.creationTime)
        }
        let currentPhoto = photos.first { $0.id == id }
        let status = currentPhoto != nil ? "current" : (cached.selectedExists ? "stale" : "missing")
        try Task.checkCancellation()
        let queryVector = try await encoders.text(query)
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        let cachedResult = try PhotoDiagnosticRanking.rank(id: id, query: queryVector, photos: photos,
                                                           locationWeight: locationWeight)
        var report = PhotoDiagnosticReport(photoID: id, query: query, locationWeight: locationWeight,
                                           galleryCount: photos.count, cachedRank: cachedResult.rank,
                                           cachedScore: cachedResult.score, modelVersion: cacheVersion,
                                           cachedStatus: status)
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        var preview: IndexingImage?
        do {
            preview = try await library.indexImage(id: id, networkAllowed: false)
        } catch {
            report.freshIssue = try diagnosticFreshIssue(error,
                fallback: "A local preview is unavailable for this photo. No network request was made.")
        }
        // Keep snapshot validation OUTSIDE recoverable-error handlers. Once a
        // change is detected, even a later restored snapshot cannot hide it.
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        if let preview {
            report.requestedWidth = preview.requestedSize.flatMap { Int(exactly: $0.width.rounded()) }
            report.requestedHeight = preview.requestedSize.flatMap { Int(exactly: $0.height.rounded()) }
            report.pixelWidth = preview.cgImage.width
            report.pixelHeight = preview.cgImage.height
            report.orientationRawValue = preview.orientation.rawValue
            report.degraded = preview.photokitDegraded
            report.source = preview.source.rawValue
            var fresh: [Float]?
            do {
                fresh = try await encoders.image(preview: preview)
            } catch {
                report.freshIssue = try diagnosticFreshIssue(error,
                    fallback: "The local preview could not be encoded. The cached ranking is unchanged.")
            }
            try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
            if let fresh {
                try EmbeddingValidation.validateUnit(fresh)
                if let currentPhoto {
                    let result = try PhotoDiagnosticRanking.rank(id: id, query: queryVector, photos: photos,
                                                                 locationWeight: locationWeight, replacingImageWith: fresh)
                    let cosine = try EmbeddingMath.dot(currentPhoto.imageEmbedding, fresh)
                    report.freshRank = result.rank
                    report.freshScore = result.score
                    report.cachedFreshCosine = cosine
                }
            }
        }
        try validateDiagnosticSnapshot(snapshot, selected: selected, authorization: authorization)
        return report
    }

    /// Never expose arbitrary PhotoKit/encoder descriptions, IDs or paths in a
    /// partial report. Cancellation, permission and model contract failures abort.
    private func diagnosticFreshIssue(_ error: Error, fallback: String) throws -> String {
        try Task.checkCancellation()
        if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
        if let failure = error as? AppFailure {
            switch failure {
            case .permission, .modelsMissing, .modelContract: throw failure
            case .cloudOnly:
                return "No local preview is available. This photo needs iCloud access; this check did not download it."
            default: break
            }
        } else if PhotoImageRequestInfo.requiresNetwork(error) {
            return "No local preview is available. This photo needs iCloud access; this check did not download it."
        }
        return fallback
    }

    private func validateDiagnosticSnapshot(_ snapshot: [PhotoRevision], selected: PhotoRevision,
                                            authorization: Int?) throws {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let current = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard library.authorizationStatusRawValue == authorization, current == snapshot,
              library.currentRevision(id: selected.id) == selected else {
            throw AppFailure.photo("The photo or authorized library changed during this check. Please try again.")
        }
        try Task.checkCancellation()
    }

    func clear() async throws -> LibrarySummary {
        try await storage().clear()
        placeVectors.removeAll()
        return try await refresh()
    }

    private func currentPhotos(manifest: ModelManifest, resolver: OfflinePlaceResolver) async throws -> [IndexedPhoto] {
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let records = try await storage().records(modelVersion: cacheVersion)
        return records.map { cached in
            let photo = cached.photo
            return IndexedPhoto(id: photo.id, modificationTime: photo.modificationTime, modelVersion: photo.modelVersion,
                                imageEmbedding: photo.imageEmbedding,
                                location: cached.geographyVersion == resolver.version ? photo.location : nil,
                                creationTime: photo.creationTime)
        }
    }

    private func summary(snapshot: [PhotoRevision], manifest: ModelManifest, resolver: OfflinePlaceResolver) async throws -> LibrarySummary {
        let photos = try await currentPhotos(manifest: manifest, resolver: resolver)
        return makeSummary(snapshot: snapshot, photos: photos, manifest: manifest, resolver: resolver)
    }

    private func makeSummary(snapshot: [PhotoRevision], photos: [IndexedPhoto], manifest: ModelManifest,
                             resolver: OfflinePlaceResolver) -> LibrarySummary {
        LibrarySummary(authorizedCount: snapshot.count, authorizedCountKnown: true, indexedCount: photos.count,
                       locatedCount: photos.filter { $0.location != nil }.count,
                       modelVersion: IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion),
                       placesDescription: resolver.coverageDescription)
    }
}

private extension IndexProgress {
    mutating func record(_ result: PhotoPlaceResult) {
        placeChecked += 1
        switch result {
        case .resolved:
            gpsCount += 1
            placeResolved += 1
        case .noGPS: noGPS += 1
        case .noPack:
            gpsCount += 1
            noPlacePack += 1
        case .outsideCoverage:
            gpsCount += 1
            outsidePlaceCoverage += 1
        case .unavailable: placeUnavailable += 1
        }
    }
}