import SwiftUI
import ImageIQCore

@MainActor
struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var showLibrary = false
    @State private var showSettings = false
    @State private var compactGrid = false
    @FocusState private var isSearchFocused: Bool
    private var showingResults: Bool { state.completedQuery != nil || state.activity == .searching }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !showingResults { introduction }
                        searchField
                        translationSummary
                        if !showingResults && !isSearchFocused { suggestions }
                        searchContent
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                    .frame(maxWidth: 800).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("library-scroll")
                .onChange(of: state.completedQuery) { _, query in
                    guard query != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("search-anchor", anchor: .top) }
                }
            }
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                libraryStatus
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(IQStyle.background)
            }
            .navigationTitle("Image IQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSearchFocused {
                        Button("完成") { isSearchFocused = false }
                            .accessibilityLabel("收起键盘").accessibilityIdentifier("hide-search-keyboard")
                    } else {
                        Image(systemName: "magnifyingglass").foregroundStyle(IQStyle.accent).accessibilityHidden(true)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearchFocused = false; showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("设置").accessibilityIdentifier("open-settings")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { isSearchFocused = false }
                        .accessibilityLabel("收起键盘").accessibilityIdentifier("keyboard-done")
                }
            }
            .sheet(isPresented: $showLibrary) { LibrarySheet(state: state) }
            .sheet(isPresented: $showSettings) { SettingsSheet(state: state) }
            .fullScreenCover(item: $state.selection) { selection in
                PhotoResultsViewer(hits: state.results, initialID: selection.id,
                                   library: state.library, networkAllowed: state.allowICloudDownload, state: state)
            }
        }.tint(IQStyle.accent)
        .background {
            if let service = state.appleTranslationService {
                AppleQueryTranslationHost(service: service, purpose: .search)
            }
        }
    }

    @ViewBuilder private var translationSummary: some View {
        if let resolution = state.completedSearchQuery {
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
            Text("找回那一刻。")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(IQStyle.text)
            Text("不用记住日期，记得画面就好。")
                .font(.subheadline).foregroundStyle(IQStyle.secondary)
        }.padding(.vertical, 8)
    }

    private var libraryStatus: some View {
        Button { isSearchFocused = false; showLibrary = true } label: {
            HStack(spacing: 10) {
                Image(systemName: state.canRead ? "photo.stack" : "photo.badge.plus")
                    .font(.body.weight(.medium)).foregroundStyle(IQStyle.accent)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(libraryTitle).font(.subheadline.weight(.medium)).foregroundStyle(IQStyle.text)
                    Text(librarySubtitle).font(.caption).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.activity == .indexing { ProgressView(value: state.progress.fraction).tint(IQStyle.accent) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(IQStyle.secondary)
            }
            .frame(minHeight: 44)
            .padding(.top, 10)
            .overlay(alignment: .top) { Rectangle().fill(IQStyle.line).frame(height: 1) }
        }.buttonStyle(.plain).accessibilityIdentifier("open-library")
            .accessibilityValue(!state.canRead ? "authorization-required" : "library-accessible")
    }

    private var libraryTitle: String {
        if state.activity == .indexing { return "正在准备照片" }
        if state.activity == .refreshing { return "正在检查图库" }
        if !state.canRead { return "选择照片" }
        if !state.modelsReady { return "图库需要处理" }
        if state.summary.indexedCount == 0 { return "准备可搜索的照片" }
        return "\(state.summary.indexedCount.formatted()) 张照片可搜索"
    }

    private var librarySubtitle: String {
        if state.activity == .indexing { return "已检查 \(state.progress.completed.formatted()) / \(state.progress.total.formatted()) 张 · 查看进度" }
        if state.activity == .refreshing { return "照片仍保留在系统相册" }
        if !state.canRead { return "可以只选部分照片，之后随时调整" }
        if !state.modelsReady { return "查看原因与下一步" }
        if state.summary.indexedCount < state.summary.authorizedCount {
            return "已授权 \(state.summary.authorizedCount.formatted()) 张 · 部分尚不可搜索"
        }
        return state.summary.authorizedCount == 0 ? "当前没有可访问的照片" : "本机搜索 · 管理图库"
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
            emptyCard(symbol: "exclamationmark.circle", title: "这次操作没有完成",
                      detail: state.canRead ? "查看图库状态后重试，原始照片没有改变。" : "请先检查照片访问权限，再重试。")
            Button("查看图库") { showLibrary = true }.buttonStyle(.bordered).frame(minHeight: 44)
        } else if !state.results.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(state.results.count) 张候选照片").font(.headline)
                    Text("最相近的在前").font(.caption).foregroundStyle(IQStyle.secondary)
                }
                Spacer()
                Button { compactGrid.toggle() } label: {
                    Image(systemName: compactGrid ? "rectangle.grid.1x2" : "square.grid.3x3")
                        .frame(width: 44, height: 44).background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel(compactGrid ? "显示较大照片" : "显示紧凑网格")
                    .accessibilityIdentifier("toggle-grid-layout")
            }.accessibilityIdentifier("results-heading")
            PhotoResultsGrid(hits: state.results, compact: compactGrid, onSelect: { id in
                isSearchFocused = false
                state.selection = AppState.Selection(id: id)
            }) { photo in
                PhotoThumbnailView(photo: photo, cache: state.thumbnails, networkAllowed: state.allowICloudDownload)
            }
        } else if state.completedQuery != nil {
            emptyCard(symbol: "magnifyingglass", title: "暂时没有可显示的照片",
                      detail: "换一种描述，或检查图库中哪些照片已可搜索。")
        } else {
            if state.canRead && state.summary.indexedCount > 0 && !isSearchFocused {
                emptyCard(symbol: "photo.on.rectangle.angled", title: "不必从头翻起",
                          detail: "颜色、场景，或一个小细节。")
            } else if !state.canRead || state.summary.indexedCount == 0 {
                Text("先选择照片并完成准备。搜索在本机进行，不会上传照片或查询到应用服务器。")
                    .font(.subheadline).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(state.canRead ? "准备照片" : "选择可搜索的照片") { isSearchFocused = false; showLibrary = true }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    .background(IQStyle.accent, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(IQStyle.onAccent).buttonStyle(.plain).accessibilityIdentifier("setup-library")
            }
        }
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
}