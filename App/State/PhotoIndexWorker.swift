import Foundation
import ImageIQCore

struct IndexProgress: Sendable, Equatable {
    var total = 0
    var completed = 0
    var encoded = 0
    var reused = 0
    var cloudSkipped = 0
    var failed = 0
    var lastFailure: String?

    var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var summary: String {
        "\(completed)/\(total) checked · \(encoded) encoded · \(reused) reused · \(cloudSkipped) iCloud skipped · \(failed) unavailable"
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
    func clear() async throws -> LibrarySummary
}

/// Called by AppState's serialized task chain. Actor isolation alone does NOT
/// serialize whole async jobs: the caller waits for a cancelled predecessor before
/// starting the next job, including time spent awaiting Photos/encoders/storage.
actor PhotoIndexWorker: PhotoWorkServicing {
    private let library: PhotoLibraryClient
    private let encoders: any PhotoEncoding
    private let suppliedDirectory: URL?
    private var store: SQLitePhotoStore?
    private var places: OfflinePlaceResolver?
    private var placeVectors: [Data: [Float]] = [:]

    init(library: PhotoLibraryClient, encoders: any PhotoEncoding = CoreMLEncoders(), directory: URL? = nil) {
        self.library = library
        self.encoders = encoders
        suppliedDirectory = directory
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
        guard PhotoLibraryClient.canRead else { throw AppFailure.permission }
        let manifest = try await encoders.prepare()
        let resolver = boundaries()
        let store = try storage()
        var state = IndexProgress(total: snapshot.count)
        await progress(state)
        for revision in snapshot {
            try Task.checkCancellation()
            let old = try await store.record(id: revision.id)
            let reusable = old?.photo.modificationTime == revision.modificationTime && old?.photo.modelVersion == manifest.modelVersion
            if reusable, old?.geographyVersion == resolver.version {
                state.reused += 1
            } else {
                let image: [Float]
                if reusable, let old { image = old.photo.imageEmbedding }
                else {
                    do {
                        // The data and decoded pixels live for ONE asset only.
                        image = try await encodeImage(id: revision.id, networkAllowed: networkAllowed)
                    } catch is CancellationError { throw CancellationError() }
                    catch AppFailure.cloudOnly {
                        state.cloudSkipped += 1
                        state.completed += 1
                        await progress(state)
                        continue
                    } catch let error as AppFailure {
                        if case .modelContract = error { throw error }
                        if case .modelsMissing = error { throw error }
                        state.failed += 1
                        state.lastFailure = error.localizedDescription
                        state.completed += 1
                        await progress(state)
                        continue
                    } catch {
                        state.failed += 1
                        state.lastFailure = error.localizedDescription
                        state.completed += 1
                        await progress(state)
                        continue
                    }
                }
                let location = try await location(id: revision.id, resolver: resolver, manifest: manifest, store: store)
                try Task.checkCancellation()
                guard library.currentRevision(id: revision.id) == revision else {
                    state.failed += 1
                    state.lastFailure = "A photo changed or became inaccessible during indexing; refresh and retry."
                    state.completed += 1
                    await progress(state)
                    continue
                }
                let photo = IndexedPhoto(id: revision.id, modificationTime: revision.modificationTime,
                                         modelVersion: manifest.modelVersion, imageEmbedding: image, location: location,
                                         creationTime: revision.creationTime)
                try await store.save(CachedPhoto(photo: photo, geographyVersion: resolver.version))
                if reusable { state.reused += 1 } else { state.encoded += 1 }
            }
            state.completed += 1
            await progress(state)
        }
        let current = try await reconcile()
        return try await summary(snapshot: current, manifest: manifest, resolver: resolver)
    }

    private func encodeImage(id: String, networkAllowed: Bool) async throws -> [Float] {
        let image = try await library.imageData(id: id, networkAllowed: networkAllowed)
        return try await encoders.image(data: image.data, orientation: image.orientation)
    }

    private func location(id: String, resolver: OfflinePlaceResolver, manifest: ModelManifest,
                          store: SQLitePhotoStore) async throws -> PlaceEmbedding? {
        guard let label = library.placeLabel(id: id, resolver: resolver) else { return nil }
        let text = "Photo taken in \(label)."
        let key = Data((manifest.modelVersion + "\n" + text).utf8)
        if let vector = placeVectors[key] { return PlaceEmbedding(text: text, vector: vector) }
        let vector: [Float]
        if let cached = try await store.place(text: text, modelVersion: manifest.modelVersion) { vector = cached }
        else { vector = try await encoders.text(text) }
        placeVectors[key] = vector
        return PlaceEmbedding(text: text, vector: vector)
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        let snapshot = try await reconcile()
        guard PhotoLibraryClient.canRead else { throw AppFailure.permission }
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

    func clear() async throws -> LibrarySummary {
        try await storage().clear()
        placeVectors.removeAll()
        return try await refresh()
    }

    private func currentPhotos(manifest: ModelManifest, resolver: OfflinePlaceResolver) async throws -> [IndexedPhoto] {
        let records = try await storage().records(modelVersion: manifest.modelVersion)
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
                       modelVersion: manifest.modelVersion, placesDescription: resolver.coverageDescription)
    }
}