import Foundation
import SwiftUI
import Photos
import ImageIQCore

@MainActor
final class AppState: ObservableObject {
    enum Activity: Equatable { case starting, refreshing, indexing, indexingText, searching, clearing, checkingPhoto, preparingTranslation }
    enum LaunchPhase: Equatable { case pending, checkingLibrary, preparingSearch, failed, ready }
    struct Selection: Identifiable { let id: String }

    @Published private(set) var launchPhase: LaunchPhase = .pending
    @Published private(set) var launchIssue: String?
    private var launchWasRequested = false
    @Published private(set) var launchTimings: [LaunchTimingReport] = []
    private var launchTiming: LaunchTimingRecorder?
    @Published private(set) var startupProgress = StartupProgressSnapshot(completed: [])
    @Published private(set) var startupProgressVisible = false
    private var startupObserver: UUID?
    private var startupVisibilityTask: Task<Void, Never>?
    private var startupAttemptContext: StartupContext?
    private let startupHistory: (any StartupHistoryStoring)?
    private let startupContext: () -> StartupContext?
    private let startupVisibilityDelay: @Sendable (Double) async throws -> Void

    var startupProgressFraction: Double? {
        guard startupProgressVisible, isForeground,
              launchPhase == .checkingLibrary || launchPhase == .preparingSearch else { return nil }
        return startupProgress.fraction
    }

    /// Session-only presentation preference: each app launch starts in user mode.
    /// Hiding tools must never reset search settings or cancel normal work.
    @Published var debugToolsEnabled = false {
        didSet {
            guard oldValue != debugToolsEnabled, !debugToolsEnabled else { return }
            referenceSearchEnabled = false
            dismissPhotoCheck()
            debugPreviewState?.cancelAndClear()
            debugPreviewState = nil
        }
    }
    private weak var debugPreviewState: LocalPreviewComparisonState?

    /// Diagnostic A/B mode only; default accelerated on every process launch.
    @Published var referenceSearchEnabled = false {
        didSet { if oldValue != referenceSearchEnabled { searchSettingsChanged() } }
    }
    @Published private(set) var searchTimingReport: SearchTimingReport?
    private var searchTiming: SearchTimingRecorder?

    @Published private(set) var authorization = PhotoLibraryClient.authorization
    /// Sheet-local read sessions observe Photos changes even if a search result
    /// session was already nil. This is not a request to rescan or index.
    @Published private(set) var photoLibraryEpoch = UUID()
    /// Automatic index revision changes invalidate cleanup authority, including
    /// rolled-back writes, not Photos access or the current search session.
    @Published private(set) var indexSourceEpoch = UUID()
    private var lastNotifiedIndexRevision: UInt64?
    @Published private(set) var summary = LibrarySummary()
    @Published private(set) var results: [SearchHit] = []
    private struct ResultPages {
        let id = UUID()
        let response: SearchResponse
        let pageSize: Int
    }
    private var resultPages: ResultPages?
    var resultSessionID: UUID? { resultPages?.id }
    var totalResultCount: Int { resultPages?.response.hits.count ?? results.count }
    var hasMoreResults: Bool { results.count < totalResultCount }
    @Published private(set) var completedQuery: String?
    @Published private(set) var similarPhotoID: String?
    @Published var searchFilters = PhotoSearchFilters() {
        didSet { if oldValue != searchFilters { searchSettingsChanged() } }
    }
    @Published private(set) var isSelectingResults = false
    @Published private(set) var selectedResultIDs: Set<String> = []
    var orderedSelectedResultIDs: [String] { results.map(\.id).filter { selectedResultIDs.contains($0) } }
    @Published private(set) var completedSearchQuery: SearchQueryResolution?
    @Published var textSearchEnabled = false {
        didSet {
            guard oldValue != textSearchEnabled else { return }
            textSearchPreferences?.set(textSearchEnabled, forKey: Self.textSearchPreferenceKey)
            searchSettingsChanged()
            if !textSearchEnabled, activity == .indexingText { operationTask?.cancel() }
        }
    }
    @Published private(set) var textIndexProgress = TextIndexProgress()
    @Published private(set) var textIndexOperationIssue: String?
    @Published private(set) var textSearchUsed = false
    @Published private(set) var textMatchedIDs: Set<String> = []
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
    @Published private(set) var recentSearchQueries: [String] = []
    @Published private(set) var searchHistoryIssue: String?
    private let queryHistoryStore: (any QueryHistoryStoring)?
    var searchSuggestions: [SearchQuerySuggestion] {
        RecentSearchQueries.suggestions(for: recentSearchQueries)
    }
    @Published var locationWeight: Double = 0.6 { didSet { if oldValue != locationWeight { searchSettingsChanged() } } }
    /// Page size, not a global Top-K cutoff. Existing preference changes still invalidate a search.
    @Published var resultLimit = 12 { didSet { if oldValue != resultLimit { searchSettingsChanged() } } }
    @Published var allowICloudDownload = false {
        didSet { if oldValue != allowICloudDownload { refreshSyncAvailability() } }
    }
    @Published var selection: Selection?

    let library: PhotoLibraryClient
    let thumbnails: PhotoThumbnailCache
    let indexAccess: IndexAccessCoordinator?
    let groupingEncoders: any PhotoEncoding
    let photoSync: PhotoSyncState
    private var syncLaunchSucceeded = false
    private var syncReadinessConfirmed = false
    private let syncService: (any PhotoSyncServicing)?
    // Separate from both foreground work and the cancellable whole-sync task.
    // Keep a cancelled read as the drain tail; never overlap metadata requests.
    private var syncSummaryTask: Task<Void, Never>?
    private var syncSummaryGeneration = UUID()
    private var syncSummaryPending = false
    let appleTranslationService: AppleQueryTranslationService?
    private let queryTranslator: any QueryTranslating
    private let translationPreferences: UserDefaults?
    private static let translationPreferenceKey = "chineseSearchEnabled.v1"
    private let textSearchPreferences: UserDefaults?
    private static let textSearchPreferenceKey = "photoTextSearchEnabled.v1"
    private let worker: any PhotoWorkServicing
    private let authorizationStatus: () -> PHAuthorizationStatus
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var photoCheckID = UUID()
    private var translationAvailabilityID = UUID()
    @Published private(set) var isForeground = true

    init(library: PhotoLibraryClient = PhotoLibraryClient(), worker: (any PhotoWorkServicing)? = nil,
         authorizationStatus: @escaping () -> PHAuthorizationStatus = { PhotoLibraryClient.authorization },
         queryTranslator: (any QueryTranslating)? = nil, translationPreferences: UserDefaults? = nil,
         startupHistory: (any StartupHistoryStoring)? = nil,
         startupContext: @escaping () -> StartupContext? = { nil },
         startupVisibilityDelay: @escaping @Sendable (Double) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }, textSearchPreferences: UserDefaults? = nil,
         syncService: (any PhotoSyncServicing)? = nil,
         indexAccess: IndexAccessCoordinator? = nil,
         queryHistoryStore: (any QueryHistoryStoring)? = nil) {
        self.library = library
        // Default/test instances are memory-only. Only the production app root
        // opts into query persistence; ordinary preferences never hold queries.
        self.queryHistoryStore = queryHistoryStore
        // One paired encoder owns the primary image model, text model and
        // tokenizer. The two independent workers never own simultaneous index
        // pools: manual jobs first suspend and drain the automatic worker.
        let encoders = CoreMLEncoders()
        groupingEncoders = encoders
        let access = indexAccess ?? (worker == nil || syncService != nil ? IndexAccessCoordinator() : nil)
        self.indexAccess = access
        lastNotifiedIndexRevision = access?.revision
        self.worker = worker ?? PhotoIndexWorker(library: library, encoders: encoders, indexAccess: access)
        let automatic: (any PhotoSyncServicing)?
        if let syncService { automatic = syncService }
        else if worker == nil {
            automatic = PhotoIndexWorker(library: library, encoders: encoders, indexAccess: access)
        } else {
            // A fake foreground worker/authorization provider is NOT permission
            // to touch real PhotoKit. Tests must explicitly opt into fake sync.
            automatic = nil
        }
        self.syncService = automatic
        photoSync = PhotoSyncState(service: automatic)
        self.startupHistory = startupHistory
        self.startupContext = startupContext
        self.startupVisibilityDelay = startupVisibilityDelay
        if let queryTranslator {
            self.queryTranslator = queryTranslator
            appleTranslationService = nil
        } else {
            let service = AppleQueryTranslationService()
            self.queryTranslator = service
            appleTranslationService = service
        }
        self.translationPreferences = translationPreferences
        self.textSearchPreferences = textSearchPreferences
        if let saved = textSearchPreferences?.object(forKey: Self.textSearchPreferenceKey) as? Bool {
            textSearchEnabled = saved
        }
        if let saved = translationPreferences?.object(forKey: Self.translationPreferenceKey) as? Bool {
            chineseSearchEnabled = saved
        }
        self.authorizationStatus = authorizationStatus
        authorization = authorizationStatus()
        thumbnails = PhotoThumbnailCache(library: library)
        photoSync.onCommitted = { [weak self] in
            self?.indexAccessChangedIfNeeded()
            self?.requestSyncSummaryRefresh()
        }
        photoSync.onSettled = { [weak self] in
            // A final rolled-back writer also changes source authority. Refresh
            // only that previously unreported revision, not every successful end.
            if self?.indexAccessChangedIfNeeded() == true { self?.requestSyncSummaryRefresh() }
        }
        photoSync.onCompleted = { [weak self] summary in
            self?.invalidateSyncSummaryRefresh()
            self?.acceptSyncSummary(summary)
        }
        library.observe { [weak self] in
            Task { @MainActor [weak self] in self?.libraryChanged() }
        }
        if let queryHistoryStore {
            do { recentSearchQueries = RecentSearchQueries.normalized(try queryHistoryStore.load()) }
            catch { searchHistoryIssue = "无法读取本机搜索记录。请解锁设备后重新打开应用。" }
        }
    }

    deinit {
        operationTask?.cancel()
        startupVisibilityTask?.cancel()
        syncSummaryTask?.cancel()
    }

    var isBusy: Bool { activity != nil }
    var translationSupported: Bool { queryTranslator.isSupported }
    var photoCheckInitialQuery: String { completedSearchQuery?.effective ?? completedQuery ?? query }
    var canRead: Bool { authorization == .authorized || authorization == .limited }
    var modelsReady: Bool { summary.modelVersion != nil && summary.modelIssue == nil }
    var canIndex: Bool { isForeground && canRead && modelsReady && !isBusy }
    var canIndexText: Bool {
        textSearchEnabled && canIndex && summary.indexStatisticsKnown && summary.indexedCount > 0
    }
    var canSearch: Bool {
        isForeground && canRead && modelsReady && summary.indexStatisticsKnown && summary.indexedCount > 0 && !isBusy && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Root-view task is idempotent. Only a cold launch (or explicitly retried
    /// interrupted launch) uses the gate; ordinary foreground refresh stays light.
    func start() {
        guard launchPhase == .pending else { return }
        launchWasRequested = true
        guard isForeground else { return }
        beginLaunch(kind: .cold)
    }

    func retryLaunch() {
        guard launchWasRequested, launchPhase == .failed, isForeground else { return }
        beginLaunch(kind: .retry)
    }

    func openHomeAfterLaunchFailure() {
        guard launchPhase == .failed, !isBusy, isForeground else { return }
        // Keep the real failure and existing readiness guards. This exposes
        // permission/settings/recovery, not permission to use unvalidated data.
        launchPhase = .ready
    }

    private func beginLaunch(kind: LaunchTimingKind) {
        finishLaunchTiming(launchTiming, outcome: .interrupted)
        let steps = StartupProgressRecorder()
        let timing = LaunchTimingRecorder(kind: kind, startupProgress: steps)
        launchTiming = timing
        startupProgress = steps.snapshot
        startupAttemptContext = startupContext()
        startupProgressVisible = StartupDisplayPolicy.predictsSlow(context: startupAttemptContext, history: startupHistory)
        let attempt = timing.id
        startupObserver = steps.observe { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.accept(startupSnapshot: snapshot, attempt: attempt) }
        }
        launchWasRequested = true
        launchIssue = nil
        launchPhase = .checkingLibrary
        authorization = authorizationStatus()
        library.synchronizeObservation()
        invalidateDisplayedPhotos()
        steps.complete(.entry)
        startupProgress = steps.snapshot
        if !startupProgressVisible {
            let delay = startupVisibilityDelay
            let attempt = timing.id
            startupVisibilityTask = Task { @MainActor [weak self] in
                do { try await delay(StartupDisplayPolicy.fallbackDelaySeconds) }
                catch { return }
                guard !Task.isCancelled, let self, self.launchTiming?.id == attempt,
                      self.isForeground, self.activity == .starting else { return }
                self.startupProgressVisible = true
            }
        }
        schedule(.starting, timing: timing) { [weak self, worker] token in
            timing.mark(.worker)
            let summary = try await worker.prepareForLaunch(timing: timing) { [weak self] stage in
                await self?.accept(launchStage: stage, token: token)
            }
            timing.mark(.publish)
            return .launched(summary)
        }
    }

    private func finishLaunchTiming(_ timing: LaunchTimingRecorder?, outcome: LaunchTimingOutcome) {
        guard let timing, let report = timing.finish(outcome) else { return }
        launchTimings.append(report)
        // Only this attempt owns its display task and success-history write.
        guard launchTiming?.id == timing.id else { return }
        startupVisibilityTask?.cancel()
        startupVisibilityTask = nil
        if let steps = timing.startupProgress {
            if outcome == .ready { steps.complete(.ready) }
            if let startupObserver { steps.removeObserver(startupObserver) }
            startupProgress = steps.freeze()
        }
        startupObserver = nil
        startupProgressVisible = false
        if outcome == .ready, startupProgress.completed == Set(StartupStep.allCases),
           let context = startupAttemptContext {
            startupHistory?.recordSuccessfulPreparation(for: context)
        }
        startupAttemptContext = nil
    }

    private func accept(startupSnapshot: StartupProgressSnapshot, attempt: UUID) {
        guard launchTiming?.id == attempt, isForeground, activity == .starting,
              launchPhase == .checkingLibrary || launchPhase == .preparingSearch else { return }
        // Concurrent branches can enqueue notifications in a different order.
        // Completion sets only grow, never replace a newer snapshot with an older one.
        let combined = StartupProgressSnapshot(completed: startupProgress.completed.union(startupSnapshot.completed))
        if combined != startupProgress { startupProgress = combined }
    }

    private func accept(launchStage: LaunchStage, token: UUID) {
        guard operationID == token, activity == .starting, isForeground,
              launchPhase != .ready, launchPhase != .failed else { return }
        launchPhase = launchStage == .checkingLibrary ? .checkingLibrary : .preparingSearch
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
        if launchWasRequested, launchPhase != .ready {
            // Preparation now loads models + stored metadata, not a Photos
            // snapshot. Permission changes do not restart model initialization.
            // Pending foreground recovery is handled by enterForeground().
            return
        }
        schedule(.refreshing) { [worker] _ in .summary(try await worker.refresh(), "Saved index statistics refreshed.") }
    }

    func libraryChanged() {
        // Immediately invalidate visible/search state before waiting for an old job.
        photoLibraryEpoch = UUID()
        thumbnails.clear()
        // Startup has no resident vectors yet and must not be restarted merely
        // because authorization changes during model preparation.
        if activity != .starting { drainAndReleaseSearchMemory() }
        refresh()
        // Refresh first withdraws readiness; no fresh sync may slip in before
        // that foreground metadata operation has been scheduled.
        photoSync.libraryChanged()
    }

    func enterBackground() {
        isForeground = false
        syncReadinessConfirmed = false
        refreshSyncAvailability()
        library.invalidateSearchSnapshot()
        translationAvailabilityID = UUID()
        if launchWasRequested, activity == .starting {
            finishLaunchTiming(launchTiming, outcome: .interrupted)
            launchPhase = .pending
        }
        drainAndReleaseSearchMemory()
        invalidateDisplayedPhotos()
        thumbnails.clear()
        status = "Foreground work paused. Return to the app, then index to resume."
    }

    private func drainAndReleaseSearchMemory() {
        let predecessor = operationTask
        predecessor?.cancel()
        // New reads join this tail; cancellation of the tail does not skip the
        // cleanup. No withdrawn-scope resident vectors survive an idle refresh.
        operationTask = Task { [worker] in
            await predecessor?.value
            await worker.releaseSearchMemory()
        }
    }

    func enterForeground() {
        // Translation download consent can make the scene inactive, then active,
        // without backgrounding. Do not cancel preparation on that transition.
        guard !isForeground else { return }
        isForeground = true
        photoSync.pause()
        library.invalidateSearchSnapshot()
        if launchWasRequested, launchPhase != .ready {
            if launchPhase == .pending { beginLaunch(kind: .foreground) }
            return
        }
        refresh()
    }

    func index() {
        beginManualIndex(rebuild: false)
    }

    /// Called only after the user's explicit destructive-local-cache confirmation.
    func rebuildIndex() {
        beginManualIndex(rebuild: true)
    }

    private func beginManualIndex(rebuild: Bool) {
        guard canIndex else { return }
        photoLibraryEpoch = UUID()
        invalidateDisplayedPhotos()
        progress = IndexProgress()
        let networkAllowed = allowICloudDownload
        // Clear may finish even if the user cancels while awaiting its result.
        // Do not keep presenting old counts as known until fresh metadata arrives.
        if rebuild { summary.indexStatisticsKnown = false }
        schedule(.indexing) { [weak self, worker] token in
            if rebuild {
                let cleared = try await worker.clear()
                try Task.checkCancellation()
                if let self, self.operationID == token { self.summary = cleared }
            }
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

    func indexPhotoText() {
        guard canIndexText else { return }
        invalidateDisplayedPhotos()
        textIndexProgress = TextIndexProgress()
        textIndexOperationIssue = nil
        // Partial progress is durable, but the previous counts cease to be
        // authoritative as soon as this explicit update may start changing rows.
        summary.textIndexStatisticsKnown = false
        let networkAllowed = allowICloudDownload
        schedule(.indexingText) { [weak self, worker] token in
            let summary = try await worker.indexText(networkAllowed: networkAllowed) { [weak self] progress in
                await self?.accept(textProgress: progress, token: token)
            }
            return .summary(summary, "文字索引扫描结束；已完成记录可复用，未完成项可手动重试。")
        }
    }

    /// User submission only. Record before execution so a failed/cancelled
    /// search still counts, but drafts and disabled submissions never do.
    func submitSearchQuery() {
        guard canSearch else { return }
        recentSearchQueries = RecentSearchQueries.recording(query, in: recentSearchQueries)
        persistSearchHistory()
        search()
    }

    /// Independent of Photos deletion and image/OCR index maintenance. Clearing
    /// does not cancel a search or modify its query, results or selection.
    func clearSearchHistory() {
        recentSearchQueries = []
        do {
            try queryHistoryStore?.save([])
            searchHistoryIssue = nil
        } catch {
            searchHistoryIssue = "未能清除已保存的搜索记录。请解锁设备后重试；重新打开应用时旧记录可能仍会出现。"
        }
    }

    private func persistSearchHistory() {
        do {
            try queryHistoryStore?.save(recentSearchQueries)
            searchHistoryIssue = nil
        } catch {
            // Never stringify a persistence error: it may embed private text or
            // paths. In-memory history and the actual search remain usable.
            searchHistoryIssue = "搜索记录暂未保存到本机。请解锁设备后重试；本次搜索不受影响。"
        }
    }

    /// Execution-only API for original/translated reruns; never records history.
    func search(useOriginal: Bool = false) {
        guard canSearch else { return }
        let text = query, weight = Float(locationWeight)
        let filters = searchFilters
        let translate = chineseSearchEnabled && !useOriginal
        let includeText = textSearchEnabled
        invalidateDisplayedPhotos()
        let reference = referenceSearchEnabled
        let measurement = beginSearchTiming(reference: reference)
        schedule(.searching, searchMeasurement: measurement) { [worker, queryTranslator] _ in
            measurement.mark(.translation)
            let resolved = try await Self.resolve(text, translate: translate, using: queryTranslator)
            try Task.checkCancellation()
            // Rank the complete accessible snapshot once. Subsequent pages only
            // expose a prefix; they never rerun translation, encoding or centering.
            let response = try await worker.search(text: resolved.effective, originalText: resolved.original,
                                                  limit: Int.max, locationWeight: weight, filters: filters,
                                                  textSearchEnabled: includeText, timing: measurement,
                                                  referenceSearch: reference)
            try Task.checkCancellation()
            return .search(response, resolved, nil)
        }
    }

    func searchSimilar(to photoID: String) {
        guard isForeground, canRead, modelsReady, !isBusy,
              results.contains(where: { $0.id == photoID }) else { return }
        let filters = searchFilters
        invalidateDisplayedPhotos()
        let reference = referenceSearchEnabled
        let measurement = beginSearchTiming(reference: reference)
        schedule(.searching, searchMeasurement: measurement) { [worker] _ in
            let response = try await worker.searchSimilar(photoID: photoID, limit: Int.max, filters: filters,
                                                          timing: measurement, referenceSearch: reference)
            try Task.checkCancellation()
            let description = SearchQueryResolution(original: "相似照片", effective: "相似照片",
                                                    translated: false, notice: nil)
            return .search(response, description, photoID)
        }
    }

    func applySearchFilters(_ filters: PhotoSearchFilters) {
        do { try filters.validate() }
        catch { errorMessage = "请选择有效的筛选条件。"; return }
        let seed = similarPhotoID
        let resolution = completedSearchQuery
        let canRepeat = completedQuery != nil && !isBusy
        // Changing filters invalidates the old continuation. A similar seed is
        // captured first so filter application can repeat that same visual query.
        searchFilters = filters
        if canRepeat, let seed, isForeground, canRead, modelsReady {
            invalidateDisplayedPhotos()
            let reference = referenceSearchEnabled
            let measurement = beginSearchTiming(reference: reference)
            schedule(.searching, searchMeasurement: measurement) { [worker] _ in
                let response = try await worker.searchSimilar(photoID: seed, limit: Int.max, filters: filters,
                                                              timing: measurement, referenceSearch: reference)
                return .search(response, SearchQueryResolution(original: "相似照片", effective: "相似照片",
                                                               translated: false, notice: nil), seed)
            }
        } else if canRepeat, let resolution, isForeground, canRead, modelsReady {
            let weight = Float(locationWeight)
            let includeText = textSearchEnabled
            invalidateDisplayedPhotos()
            let reference = referenceSearchEnabled
            let measurement = beginSearchTiming(reference: reference)
            schedule(.searching, searchMeasurement: measurement) { [worker] _ in
                let response = try await worker.search(text: resolution.effective, originalText: resolution.original,
                                                       limit: Int.max, locationWeight: weight, filters: filters,
                                                       textSearchEnabled: includeText, timing: measurement,
                                                       referenceSearch: reference)
                return .search(response, resolution, nil)
            }
        }
    }

    func setSelectingResults(_ enabled: Bool) {
        guard !enabled || (!isBusy && !results.isEmpty) else { return }
        isSelectingResults = enabled
        if !enabled { selectedResultIDs.removeAll() }
    }

    func toggleResultSelection(_ id: String) {
        guard isSelectingResults, results.contains(where: { $0.id == id }) else { return }
        if !selectedResultIDs.insert(id).inserted { selectedResultIDs.remove(id) }
    }

    func selectVisibleResults() {
        guard isSelectingResults else { return }
        selectedResultIDs = Set(results.map(\.id))
    }

    /// Idempotent for a particular visible-page boundary. Old scroll callbacks
    /// cannot append to a newer search, even when its visible count is identical.
    func loadMoreResults(sessionID: UUID, after visibleCount: Int) {
        guard isForeground, !isBusy, let pages = resultPages, pages.id == sessionID,
              completedQuery != nil, results.count == visibleCount, hasMoreResults else { return }
        do {
            authorization = authorizationStatus()
            guard canRead else { throw AppFailure.permission }
            let remaining = pages.response.hits.count - visibleCount
            let end = visibleCount + min(pages.pageSize, remaining)
            let page = Array(pages.response.hits[visibleCount..<end])
            try pages.response.validatePageAccess(page.map(\.id))
            results.append(contentsOf: page)
        } catch {
            invalidateDisplayedPhotos()
            thumbnails.clear()
            errorMessage = "照片访问权限或图库内容已更改，请重新搜索。"
            actionHint = "Check Photos access and search again. Your saved index is unchanged."
            status = "Search pages invalidated after an access change."
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
        guard debugToolsEnabled, isForeground, canRead, !isBusy,
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

    /// The viewer owns the sheet; this weak registration also clears its pixels
    /// immediately when the global switch is turned off, before a UI update.
    func registerDebugPreview(_ preview: LocalPreviewComparisonState) -> Bool {
        guard debugToolsEnabled else { preview.cancelAndClear(); return false }
        if debugPreviewState !== preview { debugPreviewState?.cancelAndClear() }
        debugPreviewState = preview
        return true
    }

    func unregisterDebugPreview(_ preview: LocalPreviewComparisonState) {
        preview.cancelAndClear()
        if debugPreviewState === preview { debugPreviewState = nil }
    }

    func cancel() {
        operationTask?.cancel()
        // Search cancellation revokes its continuation. Cancelling an unrelated
        // diagnostic/translation task must preserve the gallery underneath it.
        if resultPages != nil, activity == nil || activity == .searching { invalidateDisplayedPhotos() }
        status = "Cancelling… completed index records are kept."
    }

    func clearIndex() {
        photoLibraryEpoch = UUID()
        invalidateDisplayedPhotos()
        thumbnails.clear()
        summary.indexStatisticsKnown = false
        summary.textIndexStatisticsKnown = false
        textIndexProgress = TextIndexProgress()
        textIndexOperationIssue = nil
        schedule(.clearing) { [worker] _ in .summary(try await worker.clear(), "Local index deleted. Your Photos library was not changed.") }
    }

    func dismissError() { errorMessage = nil; actionHint = nil }

    private func searchSettingsChanged() {
        invalidateDisplayedPhotos()
        if activity == .searching { cancel() }
    }

    private func invalidateDisplayedPhotos() {
        if let searchTiming {
            searchTimingReport = searchTiming.finish(.cancelled)
            self.searchTiming = nil
        }
        dismissPhotoCheck()
        textSearchUsed = false
        textMatchedIDs.removeAll()
        resultPages = nil
        similarPhotoID = nil
        isSelectingResults = false
        selectedResultIDs.removeAll()
        results = []; selection = nil; completedQuery = nil; completedSearchQuery = nil
    }

    private func accept(progress: IndexProgress, token: UUID) {
        guard token == operationID else { return }
        self.progress = progress
    }

    private func accept(textProgress: TextIndexProgress, token: UUID) {
        guard token == operationID, activity == .indexingText, isForeground else { return }
        self.textIndexProgress = textProgress
    }

    private var syncSummaryReady: Bool {
        let blocksSync = activity == .starting || activity == .refreshing
            || activity == .indexing || activity == .clearing
        return syncLaunchSucceeded && syncReadinessConfirmed && launchPhase == .ready
            && isForeground && canRead && modelsReady && !blocksSync
    }

    private func refreshSyncAvailability() {
        let ready = syncSummaryReady
        if !ready { invalidateSyncSummaryRefresh() }
        photoSync.updateAvailability(
            ready: ready,
            networkAllowed: allowICloudDownload)
    }

    @discardableResult
    private func indexAccessChangedIfNeeded() -> Bool {
        guard let revision = indexAccess?.revision, revision != lastNotifiedIndexRevision else { return false }
        lastNotifiedIndexRevision = revision
        indexSourceEpoch = UUID()
        // No count inference, search invalidation or readiness update here.
        // Settlement is not permission to retry a cancelled/failed sync.
        return true
    }

    private func invalidateSyncSummaryRefresh() {
        syncSummaryGeneration = UUID()
        syncSummaryPending = false
        syncSummaryTask?.cancel()
    }

    private func requestSyncSummaryRefresh() {
        guard syncService != nil, syncSummaryReady else { return }
        syncSummaryGeneration = UUID()
        syncSummaryPending = true
        startSyncSummaryRefreshIfNeeded()
    }

    private func startSyncSummaryRefreshIfNeeded() {
        guard let syncService, syncSummaryReady, syncSummaryPending, syncSummaryTask == nil else { return }
        syncSummaryPending = false
        let token = syncSummaryGeneration
        syncSummaryTask = Task { @MainActor [weak self, indexAccess, library, authorizationStatus] in
            // Conservatively reject if any writer was granted between request
            // and publication, even if it rolled back or its callback is pending.
            let revision = indexAccess?.revision
            let authorization = authorizationStatus()
            let libraryGeneration = library.changeGeneration
            do {
                try Task.checkCancellation()
                let value = try await syncService.currentSummary()
                try Task.checkCancellation()
                if let value {
                    self?.publishSyncSummary(value, token: token, revision: revision,
                                             authorization: authorization, libraryGeneration: libraryGeneration)
                }
            } catch {
                // No fallback zero, private error rendering, or full refresh.
                // Only another queued commit/source event may request work.
            }
            self?.syncSummaryTask = nil
            self?.startSyncSummaryRefreshIfNeeded()
        }
    }

    private func publishSyncSummary(_ value: LibrarySummary, token: UUID, revision: UInt64?,
                                    authorization expectedAuthorization: PHAuthorizationStatus,
                                    libraryGeneration: UInt64?) {
        guard token == syncSummaryGeneration, syncSummaryReady else { return }
        authorization = authorizationStatus()
        guard canRead, authorization == expectedAuthorization,
              library.changeGeneration == libraryGeneration else { return }
        // The service releases its short read lease on return. Close that actor
        // hop with a nonblocking lease through MainActor publication. Never
        // acquire nested async leases around currentSummary (queued-writer deadlock).
        let lease = indexAccess?.tryRead()
        defer { lease?.release() }
        if let indexAccess, lease == nil || indexAccess.revision != revision {
            requestSyncSummaryRefresh()
            return
        }
        acceptSyncSummary(value)
    }

    private func acceptSyncSummary(_ value: LibrarySummary) {
        authorization = authorizationStatus()
        guard syncSummaryReady, value.indexStatisticsKnown, value.modelIssue == nil,
              value.modelVersion == summary.modelVersion else { return }
        // Merge image statistics only; both partial metadata and final sync
        // summaries preserve foreground OCR state, search results and selection.
        var merged = summary
        merged.authorizedCount = value.authorizedCount
        merged.authorizedCountKnown = value.authorizedCountKnown
        merged.indexStatisticsKnown = value.indexStatisticsKnown
        merged.indexedCount = value.indexedCount
        merged.locatedCount = value.locatedCount
        merged.placesDescription = value.placesDescription
        summary = merged
    }

    private enum Outcome {
        case launched(LibrarySummary)
        case summary(LibrarySummary, String)
        case search(SearchResponse, SearchQueryResolution, String?)
        case photoCheck(PhotoDiagnosticReport, UUID)
        case translationPrepared(QueryTranslationLanguage, QueryTranslationAvailability)
    }

    private func beginSearchTiming(reference: Bool) -> SearchTimingRecorder {
        let recorder = SearchTimingRecorder(mode: reference ? "reference" : "accelerated")
        searchTiming = recorder
        searchTimingReport = nil
        return recorder
    }

    /// First usable result thumbnail, not a promise of original/HQ quality or
    /// exact display scan-out time. A stale cell cannot enrich another search.
    func resultThumbnailLoaded(sessionID: UUID, photoID: String) {
        guard isForeground, resultSessionID == sessionID,
              results.contains(where: { $0.id == photoID }), let searchTiming,
              let report = searchTiming.firstImage() else { return }
        searchTimingReport = report
    }

    private func schedule(_ activity: Activity, timing: LaunchTimingRecorder? = nil,
                          searchMeasurement: SearchTimingRecorder? = nil,
                          operation: @escaping @MainActor (UUID) async throws -> Outcome) {
        let predecessor = operationTask
        predecessor?.cancel()
        let token = UUID()
        operationID = token
        self.activity = activity
        if activity == .starting || activity == .refreshing { syncReadinessConfirmed = false }
        refreshSyncAvailability()
        errorMessage = nil
        actionHint = nil
        status = activity == .indexing ? "Indexing on this device…" : "Working locally…"
        timing?.mark(.queue)
        operationTask = Task { @MainActor [weak self, weak photoSync = photoSync, indexAccess] in
            // Critical: await completion, not merely cancellation, before a new job.
            await predecessor?.value
            var lease: IndexAccessCoordinator.Lease?
            // Includes final MainActor validation, summary/results publication
            // and failure handling. Releasing before the switch exposes a race.
            defer { lease?.release() }
            do {
                try Task.checkCancellation()
                switch activity {
                case .indexing, .clearing:
                    // Drain BEFORE queuing the writer: sync might itself be
                    // waiting for a commit lease, so reversing this deadlocks.
                    await photoSync?.suspendAndWait()
                    try Task.checkCancellation()
                    lease = try await indexAccess?.acquireWrite()
                case .starting, .refreshing, .searching, .indexingText, .checkingPhoto:
                    lease = try await indexAccess?.acquireRead()
                case .preparingTranslation:
                    break
                }
                try Task.checkCancellation()
                let outcome = try await operation(token)
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                switch outcome {
                case .launched(let summary):
                    self.authorization = self.authorizationStatus()
                    self.summary = summary
                    if let issue = summary.modelIssue {
                        self.syncLaunchSucceeded = false
                        self.errorMessage = issue
                        self.launchIssue = "本机搜索暂未准备好。可以重试，或先进入应用检查设置。"
                        self.launchPhase = .failed
                    } else {
                        self.syncLaunchSucceeded = true
                        self.syncReadinessConfirmed = true
                        self.launchIssue = nil
                        self.launchPhase = .ready
                    }
                    self.status = summary.modelIssue == nil ? "Launch preparation complete." : "Launch preparation needs attention."
                    self.finishLaunchTiming(timing, outcome: summary.modelIssue == nil ? .ready : .failed)
                case .summary(let summary, let message):
                    self.summary = summary
                    self.status = message
                    if activity == .refreshing { self.syncReadinessConfirmed = true }
                case .search(let response, let query, let seed):
                    searchMeasurement?.mark(.publication)
                    self.authorization = self.authorizationStatus()
                    guard self.canRead else { throw AppFailure.permission }
                    let pageSize = max(1, self.resultLimit)
                    let firstPage = Array(response.hits.prefix(pageSize))
                    // Worker already validated the complete scoring snapshot.
                    // On MainActor recheck its generation and only exposed IDs,
                    // not thousands of offscreen assets before showing page one.
                    try response.validatePageAccess(firstPage.map(\.id))
                    var searchSummary = response.summary
                    // Vector-only search deliberately does not open optional OCR
                    // storage. Absence of a read is not a newly measured zero.
                    if !searchSummary.textIndexStatisticsKnown, searchSummary.textIndexIssue == nil {
                        searchSummary.textIndexCounts = self.summary.textIndexCounts
                        searchSummary.textIndexStatisticsKnown = self.summary.textIndexStatisticsKnown
                        searchSummary.textIndexIssue = self.summary.textIndexIssue
                    }
                    self.summary = searchSummary
                    self.resultPages = ResultPages(response: response, pageSize: pageSize)
                    self.results = firstPage
                    self.similarPhotoID = seed
                    self.completedSearchQuery = query
                    self.completedQuery = query.original
                    self.textSearchUsed = response.textSearchUsed
                    self.textMatchedIDs = response.textMatchedIDs
                    self.status = response.textSearchUsed
                        ? "\(response.hits.count) results · visual and OCR ranks combined; displayed scores remain visual only."
                        : "\(response.hits.count) results · exact local scores, not probabilities."
                    if self.searchTiming?.id == searchMeasurement?.id, let searchMeasurement {
                        self.searchTimingReport = searchMeasurement.finish(.ready)
                    }
                case .translationPrepared(let language, let availability):
                    if self.translationLanguage == language {
                        self.translationAvailability = availability
                        self.translationPreparationIssue = availability == .installed ? nil : "语言包尚未就绪，请稍后检查。"
                        self.status = availability.message
                    }
                case .photoCheck(let report, let checkID):
                    if self.debugToolsEnabled, self.photoCheckID == checkID {
                        self.photoCheckReport = report
                        self.status = "Photo check complete. Your index is unchanged."
                    }
                }
                self.activity = nil
                self.refreshSyncAvailability()
            } catch {
                let searchReport = searchMeasurement?.finish(
                    error is CancellationError || Task.isCancelled ? .cancelled : .failed)
                guard let self, self.operationID == token else { return }
                if self.searchTiming?.id == searchMeasurement?.id, let searchReport {
                    self.searchTimingReport = searchReport
                }
                self.activity = nil
                if activity == .starting || activity == .refreshing {
                    self.syncReadinessConfirmed = false
                }
                if activity == .indexing || activity == .clearing {
                    // No implicit retry after failed manual work, but the user
                    // can explicitly request a fresh sync without another refresh.
                    self.photoSync.requireExplicitRestart()
                }
                defer { self.refreshSyncAvailability() }
                if activity == .starting {
                    self.syncLaunchSucceeded = false
                    self.finishLaunchTiming(timing, outcome: !self.isForeground || error is CancellationError || Task.isCancelled ? .interrupted : .failed)
                    if !self.isForeground {
                        self.launchPhase = .pending
                        self.launchIssue = nil
                    } else {
                        self.launchPhase = .failed
                        self.launchIssue = error is CancellationError || Task.isCancelled
                            ? "准备已暂停。可以重试，或先进入应用。"
                            : "启动准备未完成。可以重试，或先进入应用检查图库与设置。"
                        if !(error is CancellationError), !Task.isCancelled {
                            self.errorMessage = error.localizedDescription
                            self.actionHint = "Check Photos access and retry from Library."
                        }
                    }
                    self.status = "Launch preparation stopped. Your original photos are unchanged."
                } else if activity == .indexingText {
                    self.summary.textIndexStatisticsKnown = false
                    self.textIndexOperationIssue = error is CancellationError || Task.isCancelled
                        ? "文字索引已暂停，已完成记录保留；手动更新可继续。"
                        : "文字索引未完成。请检查照片权限后重试；图片索引没有重新计算。"
                    self.status = self.textIndexOperationIssue ?? "文字索引已停止。"
                } else if activity == .preparingTranslation {
                    self.translationPreparationIssue = (error is CancellationError || Task.isCancelled)
                        ? "语言包准备已取消。原文搜索仍然可用。"
                        : "语言包准备未完成。请检查网络和设备空间后重试；原文搜索仍然可用。"
                    self.status = "Translation preparation stopped. Photo downloads remain unchanged."
                } else if activity == .checkingPhoto {
                    if self.debugToolsEnabled, !(error is CancellationError), !Task.isCancelled {
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

    /// Separate from foreground completion; never make existing callers await
    /// the entire automatic library scan (or the completion-card display time).
    func waitForSync() async { await photoSync.waitUntilIdle() }

    /// Independent drain boundary; callers need not wait for the whole sync.
    func waitForSyncSummary() async {
        while let current = syncSummaryTask { await current.value }
    }
}