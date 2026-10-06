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
    var textIndexCounts = TextIndexCounts()
    var textIndexStatisticsKnown = false
    var textIndexIssue: String? = nil
}

struct SearchResponse: Sendable {
    let summary: LibrarySummary
    let hits: [SearchHit]
    /// Synchronous check at MainActor publication, after the worker's actor hop.
    let validateAccess: @Sendable () throws -> Void
    /// A page uses the same ranked snapshot, but checks the newly exposed IDs.
    /// PhotoKit's synchronous generation rejects any intervening library change.
    let validatePageAccess: @Sendable ([String]) throws -> Void
    let textMatchedIDs: Set<String>
    let textSearchUsed: Bool

    init(summary: LibrarySummary, hits: [SearchHit],
         validateAccess: @escaping @Sendable () throws -> Void = {},
         validatePageAccess: (@Sendable ([String]) throws -> Void)? = nil,
         textMatchedIDs: Set<String> = [], textSearchUsed: Bool = false) {
        self.summary = summary
        self.hits = hits
        self.validateAccess = validateAccess
        self.validatePageAccess = validatePageAccess ?? { _ in try validateAccess() }
        self.textMatchedIDs = textMatchedIDs
        self.textSearchUsed = textSearchUsed
    }
}

protocol PhotoWorkServicing: Sendable {
    func releaseSearchMemory() async
    func refresh() async throws -> LibrarySummary
    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary
    func prepareForLaunch(timing: LaunchTimingRecorder?, progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse
    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse
    func search(text: String, originalText: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters, textSearchEnabled: Bool) async throws -> SearchResponse
    func search(text: String, originalText: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters, textSearchEnabled: Bool, timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse
    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters, timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport
    func clear() async throws -> LibrarySummary
}

extension PhotoWorkServicing {
    func releaseSearchMemory() async { }
    /// Requirements, rather than extension-only overloads, preserve dynamic
    /// dispatch to production while leaving older injected services unchanged.
    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool,
                timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        try await search(text: text, originalText: originalText, limit: limit,
                         locationWeight: locationWeight, filters: filters, textSearchEnabled: textSearchEnabled)
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters,
                       timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        try await searchSimilar(photoID: photoID, limit: limit, filters: filters)
    }

    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        try Task.checkCancellation()
        throw AppFailure.photo("此服务不支持照片文字索引。")
    }

    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool) async throws -> SearchResponse {
        try Task.checkCancellation()
        guard !textSearchEnabled else { throw AppFailure.photo("此服务不支持照片文字搜索。") }
        return try await search(text: text, limit: limit, locationWeight: locationWeight, filters: filters)
    }

    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse {
        try Task.checkCancellation()
        try filters.validate()
        guard filters.isEmpty else { throw AppFailure.photo("此搜索服务不支持筛选。") }
        return try await search(text: text, limit: limit, locationWeight: locationWeight)
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        try Task.checkCancellation()
        throw AppFailure.photo("此搜索服务不支持以图搜图。")
    }

    /// Dynamic protocol requirement preserves existing injected services.
    func prepareForLaunch(timing: LaunchTimingRecorder?, progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        try await prepareForLaunch(progress: progress)
    }

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

    /// AppState calls only after its cancelled predecessor has drained. The
    /// derived disk file survives; source/authorization checks still run on reuse.
    func releaseSearchMemory() async {
        residentSearchIndex = nil
        await searchIndexCache?.invalidate()
    }

    private let library: any PhotoLibraryIndexing
    private let encoders: any PhotoEncoding
    private let textRecognizer: (any PhotoTextRecognizing)?
    private let filtering: (any PhotoSearchFiltering)?
    private let suppliedDirectory: URL?
    private var store: SQLitePhotoStore?
    private var places: OfflinePlaceResolver?
    private var placeMetadata: PlacePackMetadata?
    private let loadPlaceMetadata: @Sendable () -> PlacePackMetadata
    private let loadBoundaries: @Sendable () -> OfflinePlaceResolver
    private var placeVectors: [Data: [Float]] = [:]
    // Created only by an explicit search, never by init/readiness/refresh.
    private var searchIndexCache: SearchIndexCache?
    private var residentSearchIndex: (signature: String, geoVersion: String, index: ResidentSearchIndex)?

    init(library: any PhotoLibraryIndexing, encoders: any PhotoEncoding = CoreMLEncoders(), directory: URL? = nil,
         resolver: OfflinePlaceResolver? = nil,
         metadataLoader: @escaping @Sendable () -> PlacePackMetadata = { PlacePackMetadata.bundled() },
         boundaryLoader: @escaping @Sendable () -> OfflinePlaceResolver = { OfflinePlaceResolver.bundled() },
         filtering: (any PhotoSearchFiltering)? = nil,
         textRecognizer: (any PhotoTextRecognizing)? = nil) {
        self.library = library
        self.encoders = encoders
        if let textRecognizer { self.textRecognizer = textRecognizer }
        else if let realLibrary = library as? PhotoLibraryClient {
            self.textRecognizer = VisionPhotoTextRecognizer(library: realLibrary)
        } else { self.textRecognizer = nil }
        self.filtering = filtering ?? (library as? any PhotoSearchFiltering)
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

    private func searchCache() throws -> SearchIndexCache {
        if let searchIndexCache { return searchIndexCache }
        let directory = try suppliedDirectory ?? SQLitePhotoStore.defaultDirectory(create: false)
        let cache = SearchIndexCache(directory: directory)
        searchIndexCache = cache
        return cache
    }

    /// The optional cache sanitizes its own failures. Keep a source-loader error
    /// separately so a SQLite/model/permission failure retains its original type
    /// and is never treated as an optional-cache miss or retried silently.
    private actor SearchRecordLoad {
        private(set) var failure: Error?

        func read(_ reader: SQLitePhotoStore, modelVersion: String, ids: Set<String>) async throws -> [CachedPhoto] {
            do { return try await reader.searchRecords(modelVersion: modelVersion, accessibleIDs: ids) }
            catch { failure = error; throw error }
        }
    }

    private func searchRecords(modelVersion: String, accessibleIDs: Set<String>) async throws -> SearchIndexCacheResult {
        let readonly = try reader()
        let load = SearchRecordLoad()
        do {
            return try await searchCache().records(modelVersion: modelVersion, accessibleIDs: accessibleIDs) {
                try await load.read(readonly, modelVersion: modelVersion, ids: accessibleIDs)
            }
        } catch {
            try Task.checkCancellation()
            if let sourceError = await load.failure { throw sourceError }
            throw error
        }
    }

    private static func searchPhotos(_ cached: [CachedPhoto], geographyVersion: String) -> [IndexedPhoto] {
        cached.map { item in
            let photo = item.photo
            return IndexedPhoto(id: photo.id, modificationTime: photo.modificationTime,
                                modelVersion: photo.modelVersion, imageEmbedding: photo.imageEmbedding,
                                location: item.geographyVersion == geographyVersion ? photo.location : nil,
                                creationTime: photo.creationTime)
        }
    }

    private func textStorage(readOnly: Bool) throws -> SQLiteTextStore {
        let directory = try suppliedDirectory ?? SQLitePhotoStore.defaultDirectory(create: !readOnly)
        return SQLiteTextStore(directory: directory, readOnly: readOnly)
    }

    /// Optional display statistics must not block image readiness/indexing. Keep
    /// the outcome local, and never turn cancellation into an OCR warning.
    private func storedTextCounts() async throws -> (counts: TextIndexCounts, issue: String?) {
        try Task.checkCancellation()
        var reader: SQLiteTextStore?
        do {
            let storage = try textStorage(readOnly: true)
            reader = storage
            let counts = try await storage.counts()
            await storage.close()
            try Task.checkCancellation()
            return (counts, nil)
        } catch {
            if let reader { await reader.close() }
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
            return (TextIndexCounts(), "文字索引统计暂不可用，请稍后重试。")
        }
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

    func prepareForLaunch(timing: LaunchTimingRecorder?, progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        try await readiness(prepareModels: true, timing: timing, progress: progress)
    }

    private func readiness(prepareModels: Bool,
                           timing: LaunchTimingRecorder? = nil,
                           progress: (@Sendable (LaunchStage) async -> Void)? = nil) async throws -> LibrarySummary {
        try Task.checkCancellation()
        if let progress {
            await progress(.checkingLibrary)
            try Task.checkCancellation()
        }
        timing?.mark(.places)
        let metadata = geography()
        timing?.startupProgress?.complete(.places)
        let manifest: ModelManifest
        do {
            try Task.checkCancellation()
            if prepareModels {
                timing?.mark(.models)
                if let progress { await progress(.preparingSearch) }
                try Task.checkCancellation()
                // Only the primary image/text models and tokenizer, not indexing
                // slots, previews, predictions or translation resources.
                manifest = try await encoders.prepare(timing: timing)
            } else {
                // Warm foreground refresh remains metadata-only; no model loads.
                manifest = try await encoders.inspectResources()
            }
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let textCounts = try await storedTextCounts()
            return LibrarySummary(modelIssue: error.localizedDescription,
                                  placesDescription: metadata.coverageDescription,
                                  textIndexCounts: textCounts.counts,
                                  textIndexStatisticsKnown: textCounts.issue == nil,
                                  textIndexIssue: textCounts.issue)
        }
        try Task.checkCancellation()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        // Stored counts, NOT a current authorized-library count or vector validation.
        // The user decides when to reconcile and update this persisted snapshot.
        timing?.mark(.counts)
        let counts = try await reader().storedCounts(modelVersion: cacheVersion, geographyVersion: metadata.version)
        try Task.checkCancellation()
        let textCounts = try await storedTextCounts()
        try Task.checkCancellation()
        timing?.startupProgress?.complete(.counts)
        timing?.mark(.publish)
        return LibrarySummary(
            indexedCount: counts.indexed, locatedCount: counts.located,
            modelVersion: cacheVersion, placesDescription: metadata.coverageDescription,
            textIndexCounts: textCounts.counts,
            textIndexStatisticsKnown: textCounts.issue == nil,
            textIndexIssue: textCounts.issue)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        try Task.checkCancellation()
        residentSearchIndex = nil
        if let searchIndexCache { await searchIndexCache.invalidate() }
        try Task.checkCancellation()
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

    /// Explicit, independently resumable OCR. AppState drains its serialized
    /// queue before entry; this never updates/reconciles the visual index.
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        try Task.checkCancellation()
        let library = self.library
        guard let textRecognizer else { throw AppFailure.photo("此服务不支持照片文字索引。") }
        guard library.canReadImages else { throw AppFailure.permission }
        let authorization = library.authorizationStatusRawValue
        let generation = library.changeGeneration
        let snapshot = try library.enumerateAuthorizedImages()

        // General storage/metadata boundaries validate the complete captured
        // snapshot. Per-photo boundaries check that photo and synchronous access
        // generation, avoiding another whole-library enumeration per OCR row.
        func validate(_ selected: PhotoRevision? = nil) throws {
            try Task.checkCancellation()
            guard library.canReadImages else { throw AppFailure.permission }
            guard library.authorizationStatusRawValue == authorization,
                  library.changeGeneration == generation else {
                throw AppFailure.photo("照片访问已变化，请重新开始文字索引。")
            }
            let unchanged: Bool
            if let selected { unchanged = library.currentRevision(id: selected.id) == selected }
            else { unchanged = try library.enumerateAuthorizedImages() == snapshot }
            guard library.canReadImages else { throw AppFailure.permission }
            guard unchanged, library.authorizationStatusRawValue == authorization,
                  library.changeGeneration == generation else {
                throw AppFailure.photo("照片已变化，请先更新图片索引，再重试文字索引。")
            }
            try Task.checkCancellation()
        }

        try validate()
        // Startup has already prepared search. Only its model identity is needed.
        let manifest = try await encoders.inspectResources()
        try validate()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        let imageReader = try reader()
        let imageRevisions = try await imageReader.searchRevisions(modelVersion: cacheVersion,
                                                                   accessibleIDs: Set(snapshot.map(\.id)))
        try validate()
        let candidates = snapshot.filter { imageRevisions[$0.id] != nil }
        let eligible = Dictionary(candidates.filter { imageRevisions[$0.id] == $0.modificationTime }
            .map { ($0.id, $0.modificationTime) }, uniquingKeysWith: { _, last in last })
        var state = TextIndexProgress(total: candidates.count)
        try validate()
        await progress(state)
        try validate()
        let textStore = try textStorage(readOnly: false)
        do {
            // Only this explicit operation prunes OCR, against exact eligible
            // active-image revisions. Stale visuals remain untouched/searchable.
            try validate()
            try await textStore.reconcile(revisions: eligible)
            try validate()
            for revision in candidates {
                try validate(revision)
                if eligible[revision.id] == nil {
                    state.staleSkipped += 1
                } else {
                    let old = try await textStore.record(id: revision.id)
                    try validate(revision)
                    if let old, old.revision == revision.modificationTime,
                         old.policy == PhotoTextPolicy.version, !old.isReduced {
                        // Empty text is also a successfully completed full-quality scan.
                        state.reused += 1
                        if !old.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.withText += 1 }
                    } else {
                        let recognized: RecognizedPhotoText
                        try validate(revision)
                        do {
                            recognized = try await textRecognizer.recognize(id: revision.id, networkAllowed: networkAllowed)
                        } catch {
                            // Access/cancellation guards are outside ordinary-error
                            // classification: they must abort, never become a skip.
                            try validate(revision)
                            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
                            if let failure = error as? AppFailure, case .permission = failure { throw failure }
                            let cloudOnly: Bool
                            if let failure = error as? AppFailure, case .cloudOnly = failure { cloudOnly = true }
                            else { cloudOnly = PhotoImageRequestInfo.requiresNetwork(error) }
                            if !networkAllowed && cloudOnly { state.cloudSkipped += 1 }
                            else { state.failed += 1 }
                            // Never persist an error/partial recognition as completion,
                            // nor expose arbitrary provider text, paths or asset IDs.
                            state.completed += 1
                            try validate(revision)
                            await progress(state)
                            try validate(revision)
                            continue
                        }
                        try validate(revision)
                        let record = PhotoTextRecord(id: revision.id, revision: revision.modificationTime,
                                                     policy: PhotoTextPolicy.version, text: recognized.text,
                                                     pixelWidth: recognized.pixelWidth, pixelHeight: recognized.pixelHeight,
                                                     isReduced: recognized.isReduced)
                        // Recheck inside the storage actor, including immediately
                        // before commit, not only before/after the actor hop. Photos
                        // cannot be atomically locked: observed changes abort, but
                        // changes after the final guard do not undo a committed row.
                        try validate(revision)
                        try await textStore.save(record) { [library, revision, authorization, generation] in
                            try Task.checkCancellation()
                            guard library.canReadImages else { throw AppFailure.permission }
                            guard library.authorizationStatusRawValue == authorization,
                                  library.changeGeneration == generation else {
                                throw AppFailure.photo("照片访问已变化，请重新开始文字索引。")
                            }
                            let unchanged = library.currentRevision(id: revision.id) == revision
                            guard library.canReadImages else { throw AppFailure.permission }
                            guard unchanged, library.authorizationStatusRawValue == authorization,
                                  library.changeGeneration == generation else {
                                throw AppFailure.photo("照片已变化，请先更新图片索引，再重试文字索引。")
                            }
                            try Task.checkCancellation()
                        }
                        try validate(revision)
                        state.recognized += 1
                        if !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state.withText += 1 }
                        if record.isReduced { state.reduced += 1 }
                    }
                }
                state.completed += 1
                try validate(revision)
                await progress(state)
                try validate(revision)
            }
            try validate()
            // Reuse startup's already inspected place metadata; do not load a
            // pack, resolve GPS, prepare a model, or decode image vectors here.
            let counts = try await imageReader.storedCounts(modelVersion: cacheVersion,
                                                            geographyVersion: placeMetadata?.version ?? "")
            try validate()
            let textCounts = try await textStore.counts()
            try validate()
            await textStore.close()
            try validate()
            return LibrarySummary(authorizedCount: snapshot.count, authorizedCountKnown: true,
                                  indexedCount: counts.indexed, locatedCount: counts.located,
                                  modelVersion: cacheVersion,
                                  placesDescription: placeMetadata?.coverageDescription ?? "Checking optional offline boundaries…",
                                  textIndexCounts: textCounts, textIndexStatisticsKnown: true)
        } catch {
            // Cleanup also waits for the actor; no unstructured OCR/storage task
            // escapes into a subsequent AppState job. Completed rows can resume.
            await textStore.close()
            throw error
        }
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
        try await search(query: .text(text), limit: limit, locationWeight: locationWeight, filters: PhotoSearchFilters())
    }

    func search(text: String, limit: Int, locationWeight: Float, filters: PhotoSearchFilters) async throws -> SearchResponse {
        try await search(query: .text(text), limit: limit, locationWeight: locationWeight, filters: filters)
    }

    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool) async throws -> SearchResponse {
        try await search(text: text, originalText: originalText, limit: limit, locationWeight: locationWeight,
                         filters: filters, textSearchEnabled: textSearchEnabled, timing: nil, referenceSearch: false)
    }

    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool,
                timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        return try await search(query: .text(text), limit: limit, locationWeight: locationWeight,
                                filters: filters, originalText: textSearchEnabled ? originalText : nil,
                                timing: timing, referenceSearch: referenceSearch)
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters) async throws -> SearchResponse {
        try await searchSimilar(photoID: photoID, limit: limit, filters: filters, timing: nil, referenceSearch: false)
    }

    func searchSimilar(photoID: String, limit: Int, filters: PhotoSearchFilters,
                       timing: SearchTimingRecorder?, referenceSearch: Bool) async throws -> SearchResponse {
        try await search(query: .seed(photoID), limit: limit, locationWeight: 0, filters: filters,
                         timing: timing, referenceSearch: referenceSearch)
    }

    private enum SearchQuery {
        case text(String), seed(String)
    }

    private func search(query source: SearchQuery, limit: Int, locationWeight: Float,
                        filters: PhotoSearchFilters, originalText: String? = nil,
                        timing: SearchTimingRecorder? = nil, referenceSearch: Bool = false) async throws -> SearchResponse {
        try Task.checkCancellation()
        try filters.validate()
        guard filters.isEmpty || filtering != nil else { throw AppFailure.photo("此搜索服务不支持筛选。") }
        guard library.canReadImages else { throw AppFailure.permission }
        timing?.mark(.snapshot)
        // Legacy libraries retain the complete old, disk-read-only path and its
        // three enumerations. Reference mode never touches either derived cache.
        let snapshotting = referenceSearch ? nil : library as? any PhotoSearchSnapshotting
        let initialAuthorization = library.authorizationStatusRawValue
        let initialGeneration = library.changeGeneration
        let searchSnapshot = try snapshotting?.searchSnapshot()
        let snapshot = try searchSnapshot?.revisions ?? library.enumerateAuthorizedImages()
        // Capture may itself synchronize authorization and advance generation.
        // Never bind a newly captured snapshot to the pre-capture epoch.
        let authorization = searchSnapshot == nil ? initialAuthorization : library.authorizationStatusRawValue
        let generation = searchSnapshot == nil ? initialGeneration : library.changeGeneration
        timing?.setSnapshotReused(searchSnapshot?.reused ?? false)
        try Task.checkCancellation()
        try searchSnapshot?.validate()
        let seedRevision: PhotoRevision?
        switch source {
        case .text: seedRevision = nil
        case .seed(let id):
            guard let revision = snapshot.first(where: { $0.id == id }),
                  library.currentRevision(id: id) == revision else {
                throw AppFailure.photo("照片尚无可用索引，请先更新索引")
            }
            seedRevision = revision
        }
        timing?.mark(.models)
        let manifest = try await encoders.prepare()
        if originalText != nil || searchSnapshot != nil { try validateSearchEpoch(authorization: authorization, generation: generation) }
        let metadata = geography()
        let cacheVersion = IndexImagePolicy.cacheVersion(modelVersion: manifest.modelVersion)
        // Filter by current access BEFORE decoding/scoring/location centering.
        // Edited but still accessible photos intentionally retain their last
        // manually indexed content until the user updates the index.
        timing?.mark(.indexRead)
        let cached: [CachedPhoto]
        let photos: [IndexedPhoto]
        let scoringIndex: ResidentSearchIndex?
        if searchSnapshot != nil {
            let records = try await searchRecords(modelVersion: cacheVersion, accessibleIDs: Set(snapshot.map(\.id)))
            try validateSearchEpoch(authorization: authorization, generation: generation)
            try searchSnapshot?.validate()
            cached = records.records
            let reused: Bool
            if let resident = residentSearchIndex, resident.signature == records.signature,
               resident.geoVersion == metadata.version {
                scoringIndex = resident.index
                photos = resident.index.photos
                reused = true
            } else {
                residentSearchIndex = nil
                photos = Self.searchPhotos(cached, geographyVersion: metadata.version)
                // SQLite intentionally accepts legacy dimensions. Unusual active
                // shapes still go through Core at the old scoring boundary, so
                // query/weight/limit and dimension-error precedence is unchanged.
                // Stale geography has already been removed before this test.
                if photos.allSatisfy({ $0.imageEmbedding.count == manifest.dimension &&
                    ($0.location == nil || $0.location?.vector.count == manifest.dimension) }) {
                    let index = try ResidentSearchIndex(photos: photos)
                    residentSearchIndex = (records.signature, metadata.version, index)
                    scoringIndex = index
                } else { scoringIndex = nil }
                reused = false
            }
            timing?.setIndex(source: records.source.rawValue, count: photos.count, matrixReused: reused)
        } else {
            cached = try await reader().searchRecords(modelVersion: cacheVersion, accessibleIDs: Set(snapshot.map(\.id)))
            photos = Self.searchPhotos(cached, geographyVersion: metadata.version)
            scoringIndex = nil
            timing?.setIndex(source: referenceSearch ? "reference" : "sqlite", count: photos.count, matrixReused: false)
        }
        if originalText != nil { try validateSearchEpoch(authorization: authorization, generation: generation) }
        timing?.mark(.queryEncoding)
        let query: [Float]
        switch source {
        case .text(let text): query = try await encoders.text(text)
        case .seed(let id):
            guard let seed = cached.first(where: { $0.photo.id == id }) else {
                throw AppFailure.photo("照片尚无可用索引，请先更新索引")
            }
            // Like text search, an accessible edited photo uses its last manually
            // indexed visual content. Never request pixels or encode a new query.
            query = seed.photo.imageEmbedding
            // SQLite can decode legacy 512-D rows; a current-model seed must
            // satisfy the active manifest even when it is the only cached photo.
            try EmbeddingValidation.validateUnit(query, dimension: manifest.dimension)
        }
        if originalText != nil || searchSnapshot != nil { try validateSearchEpoch(authorization: authorization, generation: generation) }
        // Fetch display-only stored counts before the final access checks so no
        // suspended database operation can invalidate an already checked result.
        timing?.mark(.counts)
        let counts = try await reader().storedCounts(modelVersion: cacheVersion, geographyVersion: metadata.version)
        try Task.checkCancellation()
        timing?.mark(.accessCheck)
        if let searchSnapshot {
            try validateSearchEpoch(authorization: authorization, generation: generation)
            try searchSnapshot.validate()
            try validateSearchEpoch(authorization: authorization, generation: generation)
        } else {
            try validateSearchAccess(snapshot, authorization: authorization, generation: generation)
        }
        // Core owns exact scoring, distinct-place mean, missing-place neutrality
        // and deterministic ties. Metadata must NOT shrink its reference library.
        // Preserve the old bounded top-K path when no output filtering is needed.
        // Pass zero/negative limits through Core, including its vector validation.
        let filterOutput = !filters.isEmpty || seedRevision != nil || originalText != nil
        let rankingLimit = filterOutput && limit > 0 ? Int.max : limit
        timing?.mark(.scoring)
        var ranked: [SearchHit]
        if let scoringIndex {
            ranked = try scoringIndex.search(query: query, limit: rankingLimit, locationWeight: locationWeight)
        } else {
            ranked = try VectorSearch.search(query: query, photos: photos, limit: rankingLimit, locationWeight: locationWeight)
        }
        var textMatchIDs = Set<String>()
        var textCounts = TextIndexCounts()
        if let originalText {
            timing?.mark(.textMatch)
            let currentRevisions = Dictionary(snapshot.map { ($0.id, $0.modificationTime) }, uniquingKeysWith: { _, last in last })
            let eligible = Dictionary(photos.filter { currentRevisions[$0.id] == $0.modificationTime }
                .map { ($0.id, $0.modificationTime) }, uniquingKeysWith: { _, last in last })
            let textReader = try textStorage(readOnly: true)
            do {
                try validateSearchEpoch(authorization: authorization, generation: generation)
                let matches = try await textReader.matches(query: originalText, revisions: eligible)
                try validateSearchEpoch(authorization: authorization, generation: generation)
                timing?.mark(.counts)
                textCounts = try await textReader.counts()
                try validateSearchEpoch(authorization: authorization, generation: generation)
                await textReader.close()
                try validateSearchEpoch(authorization: authorization, generation: generation)
                // Both full rankings use the same authorized active-image universe.
                // Fusion keeps each original visual diagnostic score unchanged.
                timing?.mark(.textMatch)
                ranked = PhotoTextRanking.fuse(visual: ranked, text: matches)
                textMatchIDs = Set(matches.map(\.id))
            } catch {
                await textReader.close()
                throw error // Opt-in storage errors are explicit, never hidden fallback.
            }
        }
        timing?.mark(.filtering)
        let matchingIDs: Set<String>?
        if !filters.isEmpty, let filtering {
            matchingIDs = try filtering.matchingPhotoIDs(filters: filters, snapshot: snapshot)
        } else { matchingIDs = nil }
        try Task.checkCancellation()
        let hits: [SearchHit]
        if filterOutput {
            hits = Array(ranked.lazy.filter { hit in
                hit.id != seedRevision?.id && (matchingIDs?.contains(hit.id) ?? true)
            }.prefix(max(0, limit)))
        } else { hits = ranked }
        try Task.checkCancellation()
        // Also catch edits/access changes whose PhotoKit observer callback has not
        // yet reached MainActor. Never publish scores centered on a stale library.
        timing?.mark(.finalAccess)
        do {
            // ALWAYS a fresh full enumeration, including optimized queries and
            // unreturned rows that contribute to the distinct-place center.
            try validateSearchAccess(snapshot, authorization: authorization, generation: generation)
        } catch {
            snapshotting?.invalidateSearchSnapshot()
            throw error
        }
        let library = self.library
        let returnedIDs = Set(hits.map(\.id))
        // The seed may be outside the filter and is always excluded from hits,
        // but it remains an access dependency on every page (even an empty page).
        let returnedRevisions = Dictionary(snapshot.filter { returnedIDs.contains($0.id) || $0.id == seedRevision?.id }
            .map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let validatePage: @Sendable ([String]) throws -> Void = { ids in
            try Task.checkCancellation()
            guard library.canReadImages else { throw AppFailure.permission }
            let validationIDs = ids + (seedRevision.map { [$0.id] } ?? [])
            guard library.authorizationStatusRawValue == authorization,
                  library.changeGeneration == generation,
                  ids.allSatisfy({ returnedIDs.contains($0) }) else {
                throw AppFailure.photo("Photo access changed before results could be displayed. Search again.")
            }
            if let searchSnapshot {
                // One fresh selected-ID batch, including the similarity seed;
                // never N separate PhotoKit fetches on MainActor publication.
                try searchSnapshot.validatePhotos(validationIDs)
            } else {
                guard validationIDs.allSatisfy({ id in
                      guard let expected = returnedRevisions[id] else { return false }
                      return library.currentRevision(id: id) == expected
                }) else {
                    throw AppFailure.photo("Photo access changed before results could be displayed. Search again.")
                }
            }
            guard library.canReadImages, library.authorizationStatusRawValue == authorization,
                  library.changeGeneration == generation else {
                throw AppFailure.photo("Photo access changed before results could be displayed. Search again.")
            }
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        timing?.mark(.publication)
        return SearchResponse(summary: LibrarySummary(authorizedCount: snapshot.count, authorizedCountKnown: true,
                                                       indexedCount: counts.indexed, locatedCount: counts.located,
                                                       modelVersion: cacheVersion, placesDescription: metadata.coverageDescription,
                                                       textIndexCounts: textCounts,
                                                       textIndexStatisticsKnown: originalText != nil),
                              hits: hits, validateAccess: { try validatePage(Array(returnedIDs)) },
                              validatePageAccess: validatePage,
                              textMatchedIDs: textMatchIDs.intersection(returnedIDs),
                              textSearchUsed: !textMatchIDs.intersection(returnedIDs).isEmpty)
    }

    /// Cheap checks at suspension boundaries. Legacy/reference searches retain
    /// all three full snapshots; snapshot-capable searches still make a fresh
    /// final full comparison, including edits whose notification has not arrived.
    private func validateSearchEpoch(authorization: Int?, generation: UInt64?) throws {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard authorization == library.authorizationStatusRawValue,
              generation == library.changeGeneration else {
            throw AppFailure.photo("照片访问已变化，请重新搜索。")
        }
    }

    private func validateSearchAccess(_ snapshot: [PhotoRevision], authorization: Int?, generation: UInt64?) throws {
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        let current = try library.enumerateAuthorizedImages()
        try Task.checkCancellation()
        guard library.canReadImages else { throw AppFailure.permission }
        guard authorization == library.authorizationStatusRawValue,
              generation == library.changeGeneration, current == snapshot else {
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
        try Task.checkCancellation()
        residentSearchIndex = nil
        // Also remove a previous worker's derived file. A cache-only failure must
        // not prevent the user's image/OCR clear, but cancellation still aborts.
        do { try await searchCache().clear() }
        catch {
            try Task.checkCancellation()
            if PhotoImageRequestInfo.isCancellation(error) { throw CancellationError() }
        }
        try Task.checkCancellation()
        try await storage().clear()
        try Task.checkCancellation()
        let textStore = try textStorage(readOnly: false)
        do {
            try await textStore.clear()
            await textStore.close()
        } catch {
            await textStore.close()
            throw error
        }
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
        var result = makeSummary(snapshot: snapshot, photos: photos, manifest: manifest, resolver: resolver)
        let textCounts = try await storedTextCounts()
        result.textIndexCounts = textCounts.counts
        result.textIndexStatisticsKnown = textCounts.issue == nil
        result.textIndexIssue = textCounts.issue
        return result
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