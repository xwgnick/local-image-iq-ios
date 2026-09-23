import Foundation
import ImageIQCore

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
    var lastFailure: String?

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var summary: String {
        "\(completed)/\(total) checked · \(encoded) encoded · \(reused) reused · \(cloudSkipped) need network · \(failed) unavailable · \(localPreviews) local previews · \(reducedPreviews) reduced previews · \(networkPreviews) online-fallback previews"
    }
}

struct LibrarySummary: Sendable {
    var authorizedCount = 0
    var indexedCount = 0
    var locatedCount = 0
    var modelVersion: String?
    var modelIssue: String?
    var placesDescription = "Checking optional offline boundaries…"
}

struct SearchResponse: Sendable {
    let summary: LibrarySummary
    let hits: [SearchHit]
}

protocol PhotoWorkServicing: Sendable {
    func refresh() async throws -> LibrarySummary
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport
    func clear() async throws -> LibrarySummary
}

extension PhotoWorkServicing {
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        try Task.checkCancellation()
        throw AppFailure.photo("Photo diagnostics are unsupported by this service.")
    }
}

/// Called by AppState's serialized task chain. Actor isolation alone does NOT
/// serialize whole async jobs: the caller waits for a cancelled predecessor before
/// starting the next job, including time spent awaiting Photos/encoders/storage.
actor PhotoIndexWorker: PhotoWorkServicing {
    private let library: any PhotoLibraryIndexing
    private let encoders: any PhotoEncoding
    private let suppliedDirectory: URL?
    private var store: SQLitePhotoStore?
    private var places: OfflinePlaceResolver?
    private var placeVectors: [Data: [Float]] = [:]

    init(library: any PhotoLibraryIndexing, encoders: any PhotoEncoding = CoreMLEncoders(), directory: URL? = nil,
         resolver: OfflinePlaceResolver? = nil) {
        self.library = library
        self.encoders = encoders
        suppliedDirectory = directory
        places = resolver
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
        let resolver = OfflinePlaceResolver.bundled()
        places = resolver
        return resolver
    }

    private func reconcile() async throws -> [PhotoRevision] {
        let snapshot = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        try await storage().reconcile(completeEnumeration: snapshot)
        placeVectors.removeAll() // Discard memory-only labels from an older authorization snapshot.
        return snapshot
    }

    func refresh() async throws -> LibrarySummary {
        let snapshot = try await reconcile()
        let resolver = boundaries()
        let manifest: ModelManifest
        do { manifest = try await encoders.prepare() }
        catch is CancellationError { throw CancellationError() }
        catch {
            return LibrarySummary(authorizedCount: snapshot.count, modelIssue: error.localizedDescription,
                                  placesDescription: resolver.coverageDescription)
        }
        return try await summary(snapshot: snapshot, manifest: manifest, resolver: resolver)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        let snapshot = try await reconcile()
        guard library.canReadImages else { throw AppFailure.permission }
        let manifest = try await encoders.prepare()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let resolver = boundaries()
        let store = try storage()
        var state = IndexProgress(total: snapshot.count)
        await progress(state)
        for revision in snapshot {
            try Task.checkCancellation()
            let old = try await store.record(id: revision.id)
            let reusable = old?.photo.modificationTime == revision.modificationTime && old?.photo.modelVersion == cacheVersion
            if reusable, old?.geographyVersion == resolver.version {
                state.reused += 1
            } else {
                let image: [Float]
                var source: IndexingImage.Source? = nil
                if reusable, let old { image = old.photo.imageEmbedding }
                else {
                    do {
                        // Preview pixels live for ONE asset only; no original-data fallback.
                        let encoded = try await encodeImage(id: revision.id, networkAllowed: networkAllowed)
                        image = encoded.embedding
                        source = encoded.source
                    } catch is CancellationError { throw CancellationError() }
                    catch AppFailure.cloudOnly where !networkAllowed {
                        try Task.checkCancellation()
                        state.cloudSkipped += 1
                        state.completed += 1
                        await progress(state)
                        continue
                    } catch let error as AppFailure {
                        try Task.checkCancellation()
                        if case .modelContract = error { throw error }
                        if case .modelsMissing = error { throw error }
                        state.failed += 1
                        state.lastFailure = error.localizedDescription
                        state.completed += 1
                        await progress(state)
                        continue
                    } catch {
                        try Task.checkCancellation()
                        // Also classify raw PhotoKit errors from an injected library.
                        if !networkAllowed, PhotoImageRequestInfo.requiresNetwork(error) {
                            state.cloudSkipped += 1
                        } else {
                            state.failed += 1
                            state.lastFailure = error.localizedDescription
                        }
                        state.completed += 1
                        await progress(state)
                        continue
                    }
                }
                let location = try await location(id: revision.id, resolver: resolver, cacheVersion: cacheVersion, store: store)
                try Task.checkCancellation()
                guard library.currentRevision(id: revision.id) == revision else {
                    state.failed += 1
                    state.lastFailure = "A photo changed or became inaccessible during indexing; refresh and retry."
                    state.completed += 1
                    await progress(state)
                    continue
                }
                let photo = IndexedPhoto(id: revision.id, modificationTime: revision.modificationTime,
                                         modelVersion: cacheVersion, imageEmbedding: image, location: location,
                                         creationTime: revision.creationTime)
                try await store.save(CachedPhoto(photo: photo, geographyVersion: resolver.version))
                if reusable { state.reused += 1 } else { state.encoded += 1 }
                // Only committed, newly encoded records contribute source counts.
                if let source {
                    switch source {
                    case .localPreview: state.localPreviews += 1
                    case .localReducedPreview: state.reducedPreviews += 1
                    case .networkPreview: state.networkPreviews += 1
                    }
                }
            }
            state.completed += 1
            await progress(state)
        }
        let current = try await reconcile()
        return try await summary(snapshot: current, manifest: manifest, resolver: resolver)
    }

    private func encodeImage(id: String, networkAllowed: Bool) async throws -> (embedding: [Float], source: IndexingImage.Source) {
        let preview = try await library.indexImage(id: id, networkAllowed: networkAllowed)
        let source = preview.source
        try Task.checkCancellation()
        let embedding = try await encoders.image(preview: preview)
        try Task.checkCancellation()
        return (embedding, source)
    }

    private func location(id: String, resolver: OfflinePlaceResolver, cacheVersion: String,
                          store: SQLitePhotoStore) async throws -> PlaceEmbedding? {
        guard let label = library.placeLabel(id: id, resolver: resolver) else { return nil }
        let text = "Photo taken in \(label)."
        let key = Data((cacheVersion + "\n" + text).utf8)
        if let vector = placeVectors[key] { return PlaceEmbedding(text: text, vector: vector) }
        let vector: [Float]
        if let cached = try await store.place(text: text, modelVersion: cacheVersion) { vector = cached }
        else { vector = try await encoders.text(text) }
        placeVectors[key] = vector
        return PlaceEmbedding(text: text, vector: vector)
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        let snapshot = try await reconcile()
        guard library.canReadImages else { throw AppFailure.permission }
        let manifest = try await encoders.prepare()
        let resolver = boundaries()
        let photos = try await currentPhotos(manifest: manifest, resolver: resolver)
        let query = try await encoders.text(text)
        try Task.checkCancellation()
        // Core owns exact scoring, distinct-place mean, missing-place neutrality
        // and deterministic ties. There are no date/place predicates or rerankers.
        let hits = try VectorSearch.search(query: query, photos: photos, limit: limit, locationWeight: locationWeight)
        try Task.checkCancellation()
        // Also catch edits/access changes whose PhotoKit observer callback has not
        // yet reached MainActor. Never publish scores centered on a stale library.
        let current = try library.enumerateAuthorizedImages()
        guard current == snapshot else {
            try await storage().reconcile(completeEnumeration: current)
            throw AppFailure.photo("The authorized library changed during search. Refresh and search again.")
        }
        return SearchResponse(summary: makeSummary(snapshot: snapshot, photos: photos, manifest: manifest, resolver: resolver), hits: hits)
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
        let resolver = boundaries()
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
                                location: record.geographyVersion == resolver.version ? photo.location : nil,
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
        LibrarySummary(authorizedCount: snapshot.count, indexedCount: photos.count,
                       locatedCount: photos.filter { $0.location != nil }.count,
                       modelVersion: IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion),
                       placesDescription: resolver.coverageDescription)
    }
}