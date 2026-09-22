import Foundation
import SwiftUI
import Photos
import ImageIQCore

@MainActor
final class AppState: ObservableObject {
    enum Activity: Equatable { case refreshing, indexing, searching, clearing }
    struct Selection: Identifiable { let id: String }

    @Published private(set) var authorization = PhotoLibraryClient.authorization
    @Published private(set) var summary = LibrarySummary()
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var completedQuery: String?
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
    private let worker: any PhotoWorkServicing
    private let authorizationStatus: () -> PHAuthorizationStatus
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var isForeground = true

    init(library: PhotoLibraryClient = PhotoLibraryClient(), worker: (any PhotoWorkServicing)? = nil,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = { PhotoLibraryClient.authorization }) {
        self.library = library
        self.worker = worker ?? PhotoIndexWorker(library: library)
        self.authorizationStatus = authorizationStatus
        authorization = authorizationStatus()
        thumbnails = PhotoThumbnailCache(library: library)
        library.observe { [weak self] in
            Task { @MainActor [weak self] in self?.libraryChanged() }
        }
    }

    deinit { operationTask?.cancel() }

    var isBusy: Bool { activity != nil }
    var canRead: Bool { authorization == .authorized || authorization == .limited }
    var modelsReady: Bool { summary.modelVersion != nil && summary.modelIssue == nil }
    var canIndex: Bool { canRead && modelsReady && !isBusy }
    var canSearch: Bool {
        canRead && modelsReady && summary.indexedCount > 0 && !isBusy && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        operationTask?.cancel()
        invalidateDisplayedPhotos()
        thumbnails.clear()
        status = "Foreground work paused. Return to the app, then index to resume."
    }

    func enterForeground() {
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
            let message = summary.indexedCount == summary.authorizedCount
                ? "Index complete. \(summary.indexedCount) authorized images are searchable."
                : "Scan finished: \(summary.indexedCount)/\(summary.authorizedCount) indexed. Missing previews are not searchable yet; see need-network and unavailable counts."
            return .summary(summary, message)
        }
    }

    func search() {
        guard canSearch else { return }
        let text = query, limit = resultLimit, weight = Float(locationWeight)
        invalidateDisplayedPhotos()
        schedule(.searching) { [worker] _ in .search(try await worker.search(text: text, limit: limit, locationWeight: weight), text) }
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

    private func invalidateDisplayedPhotos() { results = []; selection = nil; completedQuery = nil }

    private func accept(progress: IndexProgress, token: UUID) {
        guard token == operationID else { return }
        self.progress = progress
    }

    private enum Outcome {
        case summary(LibrarySummary, String)
        case search(SearchResponse, String)
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
                    self.completedQuery = query
                    self.status = "\(response.hits.count) results · exact local scores, not probabilities."
                }
                self.activity = nil
            } catch {
                guard let self, self.operationID == token else { return }
                self.activity = nil
                if error is CancellationError {
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