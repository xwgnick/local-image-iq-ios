import SwiftUI
import ImageIQCore

@MainActor
struct ContentView: View {
    @ObservedObject var state: AppState
    @StateObject private var photoActions: ResultPhotoActionsState
    @StateObject private var similarCleanup: SimilarPhotoCleanupState
    @StateObject private var navigation: PrimaryNavigationPresentation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showFilters = false
    @State private var showAlbumAction = false
    @State private var albumActionIDs: [String] = []
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var photoWriteInFlight = false
    @State private var compactGrid = false
    @State private var visiblePageBoundary: ResultPageBoundaryValue?
    @FocusState private var isSearchFocused: Bool
    private var showingResults: Bool { state.completedQuery != nil || state.activity == .searching }

    init(state: AppState, photoActionService: (any PhotoLibraryActions)? = nil,
         similarCleanupState: SimilarPhotoCleanupState? = nil,
         navigation: PrimaryNavigationPresentation? = nil,
         cleanupPreferences: UserDefaults? = .standard) {
        self.state = state
        _navigation = StateObject(wrappedValue: navigation ?? PrimaryNavigationPresentation())
        _photoActions = StateObject(wrappedValue: ResultPhotoActionsState(
            service: photoActionService ?? SystemPhotoLibraryActions(library: state.library)))
        _similarCleanup = StateObject(wrappedValue: similarCleanupState ?? SimilarPhotoCleanupState(
            grouping: SimilarPhotoGroupingService(library: state.library),
            deletion: SystemPhotoDeletionService(library: state.library), preferences: cleanupPreferences))
    }

    var body: some View {
        ZStack {
            searchPage.modifier(RetainedPrimaryPage(active: navigation.page == .search))
            SimilarPhotoCleanupSheet(state: similarCleanup, appState: state,
                                    embedded: true, isPageActive: navigation.page == .cleanup,
                                    openLibrary: openLibrary, openSettings: openSettings)
                .modifier(RetainedPrimaryPage(active: navigation.page == .cleanup))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PrimaryNavigationBar(page: navigation.page, switchingDisabled: switchingDisabled) { page in
                guard !switchingDisabled else { return }
                isSearchFocused = false
                navigation.select(page)
            }
        }
        .onChange(of: navigation.page) { _, _ in isSearchFocused = false }
        .sheet(isPresented: $showLibrary) { LibrarySheet(state: state) }
        .sheet(isPresented: $showSettings) { SettingsSheet(state: state, cleanup: similarCleanup) }
        .sheet(isPresented: $showFilters) {
            SearchFiltersSheet(filters: state.searchFilters, albums: photoActions.albums,
                               albumsLoading: photoActions.albumsLoading, albumIssue: photoActions.albumIssue) {
                state.applySearchFilters($0)
            }
        }
        .sheet(isPresented: $showAlbumAction) {
            AlbumActionSheet(albums: photoActions.albums, isLoading: photoActions.albumsLoading,
                             issue: photoActions.albumIssue) { action in
                performPhotoAction(action, ids: albumActionIDs)
                showAlbumAction = false
            }
        }
        .sheet(item: $photoActions.share) { prepared in
            if photoActions.canPresent(prepared) {
                BatchPhotoShareSheet(share: prepared,
                    validate: { photoActions.beginPresentation(prepared) },
                    finished: { photoActions.dismissShare(id: $0) })
            } else {
                ContentUnavailableView("照片访问权限已更改", systemImage: "lock")
                    .onAppear { photoActions.dismissShare(id: prepared.id) }
            }
        }
        .alert("照片操作", isPresented: Binding(get: { photoActions.message != nil },
                                             set: { if !$0 { photoActions.dismissMessage() } })) {
            Button("好") { photoActions.dismissMessage() }
        } message: { Text(photoActions.message ?? "") }
        .onReceive(photoActions.$isBusy) { busy in
            // Observe every publication, including a write that completes
            // before SwiftUI renders the intermediate busy frame.
            if !busy { photoWriteInFlight = false }
        }
        .onChange(of: state.resultSessionID) { _, _ in
            // A share extension may still own files when background clears results.
            if photoActions.share != nil || photoActions.sharingPresented { photoActions.libraryChanged() }
            else { photoActions.invalidateSelection() }
            showAlbumAction = false
            albumActionIDs = []
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { photoActions.pause() }
            else { photoActions.libraryChanged() }
        }
        // Cleanup owns its access/scene observers, including while hidden. Do
        // not invalidate the same library epoch from both parent and child.
        .fullScreenCover(item: $state.selection) { selection in
            PhotoResultsViewer(hits: state.results, initialID: selection.id,
                               library: state.library, networkAllowed: state.allowICloudDownload, state: state)
        }
        .tint(IQStyle.accent)
        .background {
            if let service = state.appleTranslationService {
                AppleQueryTranslationHost(service: service, purpose: .search)
            }
        }
    }

    private var searchPage: some View {
        NavigationStack {
            GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !showingResults { introduction }
                        searchField
                        filterControl
                        translationSummary
                        if !showingResults && !isSearchFocused { suggestions }
                        searchContent
                        if state.hasMoreResults, let session = state.resultSessionID {
                            ResultPageBoundary(sessionID: session, visibleCount: state.results.count)
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 800).frame(maxWidth: .infinity)
                    .background {
                        // Inside the content, so native ownership resolves to
                        // this ScrollView even while its retained page is hidden.
                        PrimarySearchScrollAnchor()
                            .frame(height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .coordinateSpace(name: ResultPageBoundary.coordinateSpace)
                .onPreferenceChange(ResultPageBoundaryPreference.self) { boundary in
                    visiblePageBoundary = boundary
                    requestVisiblePage(boundary, viewportHeight: viewport.size.height)
                }
                .onChange(of: state.isBusy) { _, busy in
                    if !busy { requestVisiblePage(visiblePageBoundary, viewportHeight: viewport.size.height) }
                }
                .onChange(of: navigation.page) { _, page in
                    if page == .search { requestVisiblePage(visiblePageBoundary, viewportHeight: viewport.size.height) }
                }
                .accessibilityIdentifier("library-scroll")
                .onChange(of: state.completedQuery) { _, query in
                    guard query != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("search-anchor", anchor: .top) }
                }
            }
            }
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.isSelectingResults { selectionToolbar }
                else {
                    libraryStatus
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(IQStyle.background)
                }
            }
            .navigationTitle(showingResults ? "照片搜索" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PrimaryLibraryButton(canRead: state.canRead, action: openLibrary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PrimarySettingsButton(action: openSettings)
                }
                if isSearchFocused {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isSearchFocused = false }
                            .accessibilityLabel("收起键盘").accessibilityIdentifier("hide-search-keyboard")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isSearchFocused = false }
                        .accessibilityLabel("收起键盘").accessibilityIdentifier("keyboard-done")
                }
            }
        }
    }

    private var filterControl: some View {
        SearchPhotoTextTools(state: state, filtersDisabled: photoActions.isBusy) {
            isSearchFocused = false
            photoActions.loadAlbums()
            showFilters = true
        }
    }

    private var switchingDisabled: Bool { similarCleanup.isDeleting || (photoWriteInFlight && photoActions.isBusy) }
    private func openLibrary() { isSearchFocused = false; showLibrary = true }
    private func openSettings() { isSearchFocused = false; showSettings = true }

    private func performPhotoAction(_ action: PhotoBatchAction, ids: [String]) {
        guard !photoActions.isBusy else { return }
        photoActions.perform(action, ids: ids)
        // Only an accepted write locks navigation, not searching/album reads or
        // share preparation. The controller still owns the uncancellable write.
        photoWriteInFlight = photoActions.isBusy
    }

    private var selectionToolbar: some View {
        VStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack {
                Text("已选 \(state.selectedResultIDs.count) 张").font(.subheadline)
                Spacer()
                Button("全选已显示") { state.selectVisibleResults() }
                    .accessibilityIdentifier("select-visible-results")
                }
                VStack(alignment: .leading) {
                    Text("已选 \(state.selectedResultIDs.count) 张").font(.subheadline)
                    Button("全选已显示") { state.selectVisibleResults() }
                        .accessibilityIdentifier("select-visible-results")
                }
            }
            selectionActionLayout {
                Button { photoActions.prepareShare(ids: state.orderedSelectedResultIDs,
                                                    networkAllowed: state.allowICloudDownload) } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-selected-photos")
                .frame(minWidth: 44, minHeight: 44)
                Menu {
                    Button("加入收藏") { performPhotoAction(.favorite(true), ids: state.orderedSelectedResultIDs) }
                    Button("取消收藏") { performPhotoAction(.favorite(false), ids: state.orderedSelectedResultIDs) }
                } label: { Label("收藏", systemImage: "heart") }
                .accessibilityIdentifier("favorite-selected-photos")
                .frame(minWidth: 44, minHeight: 44)
                Button {
                    albumActionIDs = state.orderedSelectedResultIDs
                    photoActions.loadAlbums()
                    showAlbumAction = true
                } label: { Label("相册", systemImage: "folder.badge.plus") }
                .accessibilityIdentifier("album-selected-photos")
                .frame(minWidth: 44, minHeight: 44)
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .disabled(state.selectedResultIDs.isEmpty || photoActions.isBusy || state.isBusy)
            if photoActions.isBusy { ProgressView("正在处理照片…").font(.caption) }
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .foregroundStyle(IQStyle.text).tint(IQStyle.accent).background(IQStyle.background)
    }

    private var selectionActionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 18))
    }

    @ViewBuilder private var translationSummary: some View {
        if state.similarPhotoID == nil, let resolution = state.completedSearchQuery {
            if resolution.translated {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已用英文搜索：\(resolution.effective)")
                        .font(.caption).foregroundStyle(IQStyle.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("effective-search-query")
                    Button("使用原文") { isSearchFocused = false; state.search(useOriginal: true) }
                        .frame(minHeight: 44).disabled(!state.canSearch)
                        .accessibilityIdentifier("search-original")
                }
                .tint(IQStyle.accent)
            } else if let notice = resolution.notice {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice).font(.caption).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("translation-fallback-notice")
                    Button("中文搜索设置") { isSearchFocused = false; showSettings = true }
                        .frame(minHeight: 44)
                }
            } else if state.chineseSearchEnabled, ChineseQueryRouter.sourceLanguage(for: resolution.original) != nil {
                HStack {
                    Text("本次使用原文").font(.caption).foregroundStyle(IQStyle.secondary)
                    Button("使用英文翻译") { submitSearch() }.disabled(!state.canSearch).frame(minHeight: 44)
                        .accessibilityIdentifier("search-translated")
                }
            }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("照片搜索")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(IQStyle.text)
            Text("用一句话，找到你记得的照片。")
                .font(.subheadline).foregroundStyle(IQStyle.secondary)
        }.padding(.vertical, 8)
    }

    private var libraryStatus: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(libraryTitle).font(.caption).foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.activity == .indexing { ProgressView(value: state.progress.fraction).tint(IQStyle.accent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("library-status")
    }

    var libraryTitle: String {
        if state.activity == .indexing { return "正在更新索引" }
        if state.activity == .refreshing { return "正在刷新索引统计" }
        if !state.canRead { return "选择照片" }
        if !state.modelsReady { return "图库需要处理" }
        if !state.summary.indexStatisticsKnown { return "索引统计待刷新" }
        return "已索引 \(state.summary.indexedCount.formatted()) 张"
    }

    var librarySubtitle: String {
        if state.activity == .indexing { return "已检查 \(state.progress.completed.formatted()) 张 · 查看索引进度" }
        if state.activity == .refreshing { return "只读取本机统计，不扫描照片" }
        if !state.canRead { return "可以只选部分照片，之后随时调整" }
        if !state.modelsReady { return "查看原因与下一步" }
        return "本机保存的索引 · 手动更新"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(IQStyle.secondary).accessibilityHidden(true)
            TextField("描述你记得的画面", text: $state.query)
                .focused($isSearchFocused).submitLabel(.search).onSubmit(submitSearch)
                .font(.body).autocorrectionDisabled()
                .accessibilityLabel("描述想找的照片").accessibilityIdentifier("photo-query")
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IQStyle.secondary).frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("清空搜索").accessibilityIdentifier("clear-query")
            }
            Button(action: submitSearch) {
                Image(systemName: "arrow.right").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                    .foregroundStyle(state.canSearch ? IQStyle.onAccent : IQStyle.secondary)
                    .background(state.canSearch ? IQStyle.accent : IQStyle.muted, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!state.canSearch).accessibilityLabel("搜索照片").accessibilityIdentifier("search-photos")
        }
        .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(isSearchFocused ? IQStyle.accent : IQStyle.line, lineWidth: 1))
        .id("search-anchor")
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("试试这样描述").font(.caption).foregroundStyle(IQStyle.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    suggestion("海边的日落", symbol: "sun.max")
                    suggestion("云雾里的山", symbol: "mountain.2")
                }
            }
        }
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        Button {
            state.query = text
            if state.canSearch { submitSearch() } else { isSearchFocused = true }
        } label: {
            Label(text, systemImage: symbol).font(.caption.weight(.medium))
                .padding(.horizontal, 13).frame(minHeight: 44)
                .background(IQStyle.surface, in: Capsule())
                .overlay(Capsule().stroke(IQStyle.line, lineWidth: 1))
            }.buttonStyle(.plain).foregroundStyle(IQStyle.text)
    }

    @ViewBuilder private var searchContent: some View {
        if state.activity == .searching {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(IQStyle.accent)
                Text("正在查找照片…").font(.subheadline).foregroundStyle(IQStyle.secondary)
                Button("取消搜索") { state.cancel() }.font(.subheadline).frame(minHeight: 44)
            }.frame(maxWidth: .infinity).padding(.vertical, 54).accessibilityIdentifier("search-loading")
        } else if state.errorMessage != nil {
            emptyCard(symbol: "exclamationmark.circle", title: "搜索或统计暂未就绪",
                      detail: state.canRead ? "查看图库状态后重试；此提示不代表收藏或相册操作失败。" : "请先检查照片访问权限，再重试。")
            Button("查看图库") { showLibrary = true }.buttonStyle(.bordered).frame(minHeight: 44)
        } else if !state.results.isEmpty {
            resultsHeadingLayout {
                VStack(alignment: .leading, spacing: 4) {
                    Text("已显示 \(state.results.count) 张候选照片").font(.headline)
                    Text(state.textSearchUsed ? "已结合照片文字" : "最相近的在前")
                        .font(.caption).foregroundStyle(IQStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                Button(state.isSelectingResults ? "完成" : "选择") {
                    isSearchFocused = false
                    state.setSelectingResults(!state.isSelectingResults)
                }
                .disabled(photoActions.isBusy)
                .frame(minHeight: 44)
                .accessibilityIdentifier("select-search-results")
                Button { compactGrid.toggle() } label: {
                    Image(systemName: compactGrid ? "rectangle.grid.1x2" : "square.grid.3x3")
                        .frame(width: 44, height: 44).background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel(compactGrid ? "显示较大照片" : "显示紧凑网格")
                    .accessibilityIdentifier("toggle-grid-layout")
                }
            }.accessibilityIdentifier("results-heading")
            PhotoResultsGrid(hits: state.results, compact: compactGrid, onSelect: { id in
                isSearchFocused = false
                if state.isSelectingResults { state.toggleResultSelection(id) }
                else { state.selection = AppState.Selection(id: id) }
            }, selectionMode: state.isSelectingResults, selectedIDs: state.selectedResultIDs) { photo in
                let sessionID = state.resultSessionID
                PhotoThumbnailView(photo: photo, cache: state.thumbnails, networkAllowed: state.allowICloudDownload,
                                   showDiagnostics: state.debugToolsEnabled, onLoaded: {
                    if let sessionID { state.resultThumbnailLoaded(sessionID: sessionID, photoID: photo.id) }
                })
                .id(sessionID)
            }
        } else if state.completedQuery != nil {
            emptyCard(symbol: "magnifyingglass", title: "暂时没有可显示的照片",
                      detail: "换一种描述，或检查照片权限并手动更新索引。")
        } else {
            if state.canRead && state.summary.indexedCount > 0 && !isSearchFocused {
                emptyCard(symbol: "photo.on.rectangle.angled", title: "不必从头翻起",
                          detail: "颜色、场景，或一个小细节。")
            } else if !state.canRead || state.summary.indexedCount == 0 {
                Text("先选择照片并手动建立索引。搜索在本机进行，不会上传照片或查询到应用服务器。")
                    .font(.subheadline).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(state.canRead ? "建立索引" : "选择可搜索的照片") { isSearchFocused = false; showLibrary = true }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    .background(IQStyle.accent, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(IQStyle.onAccent).buttonStyle(.plain).accessibilityIdentifier("setup-library")
            }
        }
    }

    private var resultsHeadingLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    private func emptyCard(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(IQStyle.accent)
                .frame(width: 76, height: 76).background(IQStyle.accentSoft, in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(IQStyle.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 32)
    }

    private func submitSearch() { isSearchFocused = false; state.search() }

    private func requestVisiblePage(_ boundary: ResultPageBoundaryValue?, viewportHeight: CGFloat) {
          guard navigation.page == .search,
              let boundary, boundary.frame.minY < viewportHeight, boundary.frame.maxY > 0 else { return }
        state.loadMoreResults(sessionID: boundary.sessionID, after: boundary.visibleCount)
    }
}