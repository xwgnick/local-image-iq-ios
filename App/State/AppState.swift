import Foundation
import SwiftUI
import Photos
import ImageIQCore

@MainActor
final class AppState: ObservableObject {
    enum Activity: Equatable { case refreshing, indexing, searching, clearing, checkingPhoto, preparingTranslation }
    struct Selection: Identifiable { let id: String }

    @Published private(set) var authorization = PhotoLibraryClient.authorization
    @Published private(set) var summary = LibrarySummary()
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var completedQuery: String?
    @Published private(set) var completedSearchQuery: SearchQueryResolution?
    @Published private(set) var translationAvailability: QueryTranslationAvailability = .unchecked
    @Published private(set) var translationPreparationIssue: String?
    @Published var chineseSearchEnabled = true {
        didSet {
            guard oldValue != chineseSearchEnabled else { return }
            translationPreferences?.set(chineseSearchEnabled, forKey: Self.translationPreferenceKey)
            searchSettingsChanged()
        }
    }
    @Published var translationLanguage: QueryTranslationLanguage = .simplified {
        didSet {
            guard oldValue != translationLanguage else { return }
            translationAvailabilityID = UUID()
            translationAvailability = .unchecked
            translationPreparationIssue = nil
            if activity == .preparingTranslation { operationTask?.cancel() }
        }
    }
    @Published private(set) var photoCheckReport: PhotoDiagnosticReport?
    @Published private(set) var photoCheckIssue: String?
    @Published private(set) var progress = IndexProgress()
    @Published private(set) var activity: Activity?
    @Published private(set) var status = "Connect your photos to start."
    @Published private(set) var errorMessage: String?
    @Published private(set) var actionHint: String?
    @Published var query = "" { didSet { if oldValue != query { searchSettingsChanged() } } }
    @Published var locationWeight: Double = 0.6 { didSet { if oldValue != locationWeight { searchSettingsChanged() } } }
    @Published var resultLimit = 3 { didSet { if oldValue != resultLimit { searchSettingsChanged() } } }
    @Published var allowICloudDownload = false
    @Published var selection: Selection?

    let library: PhotoLibraryClient
    let thumbnails: PhotoThumbnailCache
    let appleTranslationService: AppleQueryTranslationService?
    private let queryTranslator: any QueryTranslating
    private let translationPreferences: UserDefaults?
    private static let translationPreferenceKey = "chineseSearchEnabled.v1"
    private let worker: any PhotoWorkServicing
    private let authorizationStatus: () -> PHAuthorizationStatus
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var photoCheckID = UUID()
    private var translationAvailabilityID = UUID()
    private var isForeground = true

    init(library: PhotoLibraryClient = PhotoLibraryClient(), worker: (any PhotoWorkServicing)? = nil,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = { PhotoLibraryClient.authorization },
         queryTranslator: (any QueryTranslating)? = nil, translationPreferences: UserDefaults? = nil) {
        self.library = library
        self.worker = worker ?? PhotoIndexWorker(library: library)
        if let queryTranslator {
            self.queryTranslator = queryTranslator
            appleTranslationService = nil
        } else {
            let service = AppleQueryTranslationService()
            self.queryTranslator = service
            appleTranslationService = service
        }
        self.translationPreferences = translationPreferences
        if let saved = translationPreferences?.object(forKey: Self.translationPreferenceKey) as? Bool {
            chineseSearchEnabled = saved
        }
        self.authorizationStatus = authorizationStatus
        authorization = authorizationStatus()
        thumbnails = PhotoThumbnailCache(library: library)
        library.observe { [weak self] in
            Task { @MainActor [weak self] in self?.libraryChanged() }
        }
    }

    deinit { operationTask?.cancel() }

    var isBusy: Bool { activity != nil }
    var translationSupported: Bool { queryTranslator.isSupported }
    var photoCheckInitialQuery: String { completedSearchQuery?.effective ?? completedQuery ?? query }
    var canRead: Bool { authorization == .authorized || authorization == .limited }
    var modelsReady: Bool { summary.modelVersion != nil && summary.modelIssue == nil }
    var canIndex: Bool { canRead && modelsReady && !isBusy }
    var canSearch: Bool {
        isForeground && canRead && modelsReady && summary.indexedCount > 0 && !isBusy && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func authorize() {
        // Deliberately independent of model availability and index state.
        Task { @MainActor [weak self] in
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            self?.libraryChanged()
        }
    }

    func refresh() {
        authorization = authorizationStatus()
        library.synchronizeObservation()
        invalidateDisplayedPhotos()
        guard isForeground else { operationTask?.cancel(); return }
        schedule(.refreshing) { [worker] _ in .summary(try await worker.refresh(), "Library refreshed. Unchanged completed records can be reused.") }
    }

    func libraryChanged() {
        // Immediately invalidate visible/search state before waiting for an old job.
        thumbnails.clear()
        refresh()
    }

    func enterBackground() {
        isForeground = false
        translationAvailabilityID = UUID()
        operationTask?.cancel()
        invalidateDisplayedPhotos()
        thumbnails.clear()
        status = "Foreground work paused. Return to the app, then index to resume."
    }

    func enterForeground() {
        // Translation download consent can make the scene inactive, then active,
        // without backgrounding. Do not cancel preparation on that transition.
        guard !isForeground else { return }
        isForeground = true
        refresh()
    }

    func index() {
        guard canIndex else { return }
        invalidateDisplayedPhotos()
        progress = IndexProgress()
        let networkAllowed = allowICloudDownload
        schedule(.indexing) { [weak self, worker] token in
            let summary = try await worker.index(networkAllowed: networkAllowed) { [weak self] progress in
                await self?.accept(progress: progress, token: token)
            }
            var message = summary.indexedCount == summary.authorizedCount
                ? "Index complete. \(summary.indexedCount.formatted()) authorized images are searchable."
                : "Scan finished: \(summary.indexedCount.formatted())/\(summary.authorizedCount.formatted()) indexed. Open Library for missing previews and read errors."
            if let self, self.operationID == token {
                if self.progress.reused > 0 {
                    message += " Images reused: \(self.progress.reused.formatted())."
                }
                if self.progress.placeUpdated > 0 {
                    message += " Saved place updates: \(self.progress.placeUpdated.formatted())."
                }
            }
            return .summary(summary, message)
        }
    }

    func search(useOriginal: Bool = false) {
        guard canSearch else { return }
        let text = query, limit = resultLimit, weight = Float(locationWeight)
        let translate = chineseSearchEnabled && !useOriginal
        invalidateDisplayedPhotos()
        schedule(.searching) { [worker, queryTranslator] _ in
            let resolved = try await Self.resolve(text, translate: translate, using: queryTranslator)
            try Task.checkCancellation()
            let response = try await worker.search(text: resolved.effective, limit: limit, locationWeight: weight)
            try Task.checkCancellation()
            return .search(response, resolved)
        }
    }

    private static func resolve(_ text: String, translate: Bool,
                                using translator: any QueryTranslating) async throws -> SearchQueryResolution {
        try Task.checkCancellation()
        guard translate, let language = ChineseQueryRouter.sourceLanguage(for: text) else {
            return SearchQueryResolution(original: text, effective: text, translated: false, notice: nil)
        }
        do {
            guard translator.isSupported else { throw QueryTranslationFailure.unsupported }
            let available = await translator.availability(for: language)
            try Task.checkCancellation()
            switch available {
            case .installed: break
            case .downloadRequired: throw QueryTranslationFailure.notInstalled
            case .unsupported: throw QueryTranslationFailure.unsupported
            case .unchecked, .unavailable: throw QueryTranslationFailure.unavailable
            }
            let english = try await translator.translate(text, from: language)
            try Task.checkCancellation()
            guard !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QueryTranslationFailure.emptyResult
            }
            return SearchQueryResolution(original: text, effective: english, translated: true, notice: nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let failure = (error as? QueryTranslationFailure) ?? .unavailable
            return SearchQueryResolution(original: text, effective: text, translated: false,
                                         notice: failure.fallbackMessage)
        }
    }

    func checkTranslationAvailability() async {
        let token = UUID()
        translationAvailabilityID = token
        let language = translationLanguage
        let value = await queryTranslator.availability(for: language)
        guard !Task.isCancelled, isForeground, translationLanguage == language,
              translationAvailabilityID == token else { return }
        translationAvailability = value
    }

    func prepareTranslation() {
        guard isForeground, !isBusy, translationSupported else { return }
        translationAvailabilityID = UUID()
        let language = translationLanguage
        translationPreparationIssue = nil
        schedule(.preparingTranslation) { [queryTranslator] _ in
            // This is the ONLY user action allowed to ask for language downloads.
            try await queryTranslator.prepare(language)
            try Task.checkCancellation()
            let value = await queryTranslator.availability(for: language)
            try Task.checkCancellation()
            return .translationPrepared(language, value)
        }
    }

    func dismissTranslationPreparation() {
        if activity == .preparingTranslation { operationTask?.cancel() }
    }

    /// Uses the same serialized task chain without clearing the visible results.
    /// The worker reads a separate read-only SQLite snapshot and never saves the
    /// new vector. Closing/editing the sheet invalidates even late completions.
    func checkPhoto(id: String, query: String) {
        guard isForeground, canRead, !isBusy,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = UUID()
        photoCheckID = token
        photoCheckReport = nil
        photoCheckIssue = nil
        let weight = Float(locationWeight)
        schedule(.checkingPhoto) { [worker] _ in
            .photoCheck(try await worker.checkPhoto(id: id, query: query, locationWeight: weight), token)
        }
    }

    func dismissPhotoCheck() {
        photoCheckID = UUID()
        photoCheckReport = nil
        photoCheckIssue = nil
        if activity == .checkingPhoto { operationTask?.cancel() }
    }

    func cancel() {
        operationTask?.cancel()
        status = "Cancelling… completed index records are kept."
    }

    func clearIndex() {
        invalidateDisplayedPhotos()
        thumbnails.clear()
        schedule(.clearing) { [worker] _ in .summary(try await worker.clear(), "Local index deleted. Your Photos library was not changed.") }
    }

    func dismissError() { errorMessage = nil; actionHint = nil }

    private func searchSettingsChanged() {
        invalidateDisplayedPhotos()
        if activity == .searching { cancel() }
    }

    private func invalidateDisplayedPhotos() {
        dismissPhotoCheck()
        results = []; selection = nil; completedQuery = nil; completedSearchQuery = nil
    }

    private func accept(progress: IndexProgress, token: UUID) {
        guard token == operationID else { return }
        self.progress = progress
    }

    private enum Outcome {
        case summary(LibrarySummary, String)
        case search(SearchResponse, SearchQueryResolution)
        case photoCheck(PhotoDiagnosticReport, UUID)
        case translationPrepared(QueryTranslationLanguage, QueryTranslationAvailability)
    }

    private func schedule(_ activity: Activity, operation: @escaping @MainActor (UUID) async throws -> Outcome) {
        let predecessor = operationTask
        predecessor?.cancel()
        let token = UUID()
        operationID = token
        self.activity = activity
        errorMessage = nil
        actionHint = nil
        status = activity == .indexing ? "Indexing on this device…" : "Working locally…"
        operationTask = Task { @MainActor [weak self] in
            // Critical: await completion, not merely cancellation, before a new job.
            await predecessor?.value
            do {
                try Task.checkCancellation()
                let outcome = try await operation(token)
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                switch outcome {
                case .summary(let summary, let message): self.summary = summary; self.status = message
                case .search(let response, let query):
                    self.summary = response.summary
                    self.results = response.hits
                    self.completedSearchQuery = query
                    self.completedQuery = query.original
                    self.status = "\(response.hits.count) results · exact local scores, not probabilities."
                case .translationPrepared(let language, let availability):
                    if self.translationLanguage == language {
                        self.translationAvailability = availability
                        self.translationPreparationIssue = availability == .installed ? nil : "语言包尚未就绪，请稍后检查。"
                        self.status = availability.message
                    }
                case .photoCheck(let report, let checkID):
                    if self.photoCheckID == checkID {
                        self.photoCheckReport = report
                        self.status = "Photo check complete. Your index is unchanged."
                    }
                }
                self.activity = nil
            } catch {
                guard let self, self.operationID == token else { return }
                self.activity = nil
                if activity == .preparingTranslation {
                    self.translationPreparationIssue = (error is CancellationError || Task.isCancelled)
                        ? "语言包准备已取消。原文搜索仍然可用。"
                        : "语言包准备未完成。请检查网络和设备空间后重试；原文搜索仍然可用。"
                    self.status = "Translation preparation stopped. Photo downloads remain unchanged."
                } else if activity == .checkingPhoto {
                    if !(error is CancellationError), !Task.isCancelled {
                        self.photoCheckIssue = "Could not finish this check. Keep the app open and confirm this photo is still accessible, then try again."
                    }
                    self.status = "Photo check stopped. Your index is unchanged."
                } else if error is CancellationError {
                    self.status = "Cancelled. Completed records are saved; refresh or index again to resume."
                } else {
                    self.errorMessage = error.localizedDescription
                    self.actionHint = "Check Photos access and the model notice. Retry; for cache errors, clear the local index and rebuild."
                    self.status = "Could not complete this operation."
                }
            }
        }
    }

    /// Awaitable completion boundary also used by model-free state tests.
    func waitUntilIdle() async { await operationTask?.value }
}