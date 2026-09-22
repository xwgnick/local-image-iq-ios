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
                    VStack(alignment: .leading, spacing: 22) {
                        if !showingResults { introduction }
                        libraryStatus
                        searchField
                        if !showingResults && !isSearchFocused { suggestions }
                        searchContent
                    }
                    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 28)
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
            .navigationTitle("Image IQ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isSearchFocused {
                        Button("Done") { isSearchFocused = false }
                            .accessibilityLabel("Hide keyboard").accessibilityIdentifier("hide-search-keyboard")
                    } else {
                        Image(systemName: "sparkle").foregroundStyle(IQStyle.accent).accessibilityHidden(true)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearchFocused = false; showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Settings").accessibilityIdentifier("open-settings")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isSearchFocused = false }
                        .accessibilityLabel("Hide keyboard").accessibilityIdentifier("keyboard-done")
                }
            }
            .sheet(isPresented: $showLibrary) { LibrarySheet(state: state) }
            .sheet(isPresented: $showSettings) { SettingsSheet(state: state) }
            .fullScreenCover(item: $state.selection) { selection in
                PhotoResultsViewer(hits: state.results, initialID: selection.id,
                                   library: state.library, networkAllowed: state.allowICloudDownload)
            }
        }.tint(IQStyle.accent)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ONLY YOURS", systemImage: "lock.shield")
                .font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(IQStyle.secondary)
            Text("Find the moment.").font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(.white)
            Text("Describe what you remember.").font(.subheadline).foregroundStyle(IQStyle.secondary)
        }.padding(.vertical, 10)
    }

    private var libraryStatus: some View {
        Button { isSearchFocused = false; showLibrary = true } label: {
            HStack(spacing: 12) {
                Image(systemName: state.canRead ? "photo.stack" : "photo.badge.plus")
                    .font(.body.weight(.medium)).foregroundStyle(IQStyle.accent)
                    .frame(width: 38, height: 38)
                    .background(IQStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(libraryTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(librarySubtitle).font(.caption).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if state.activity == .indexing { ProgressView(value: state.progress.fraction).tint(IQStyle.accent) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(IQStyle.secondary)
            }
            .padding(14).background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("open-library")
    }

    private var libraryTitle: String {
        if state.activity == .indexing { return "Preparing your library" }
        if state.activity == .refreshing { return "Checking your library" }
        if !state.canRead { return "Connect your photos" }
        if !state.modelsReady { return "Your library needs attention" }
        if state.summary.indexedCount == 0 { return "Make your photos searchable" }
        return "\(state.summary.indexedCount.formatted()) photos ready"
    }

    private var librarySubtitle: String {
        if state.activity == .indexing { return "\(state.progress.completed.formatted()) of \(state.progress.total.formatted()) checked · Tap for progress" }
        if state.activity == .refreshing { return "Your photos stay on this device" }
        if !state.canRead { return "Choose the photos you want to search" }
        if !state.modelsReady { return "Open library to see what’s needed" }
        if state.summary.indexedCount < state.summary.authorizedCount {
            return "\(state.summary.indexedCount.formatted()) of \(state.summary.authorizedCount.formatted()) ready · Manage library"
        }
        return state.summary.authorizedCount == 0 ? "No photos selected yet" : "On-device search · Manage library"
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(IQStyle.secondary).accessibilityHidden(true)
            TextField("A moment, a place, a detail…", text: $state.query)
                .focused($isSearchFocused).submitLabel(.search).onSubmit(submitSearch)
                .font(.body).autocorrectionDisabled()
                .accessibilityLabel("Describe a photo").accessibilityIdentifier("photo-query")
            if !state.query.isEmpty {
                Button { state.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(IQStyle.secondary).frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("Clear search").accessibilityIdentifier("clear-query")
            }
            Button(action: submitSearch) {
                Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 44, height: 44)
                    .foregroundStyle(state.canSearch ? IQStyle.background : IQStyle.secondary)
                    .background(state.canSearch ? IQStyle.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!state.canSearch).accessibilityLabel("Search photos").accessibilityIdentifier("search-photos")
        }
        .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(isSearchFocused ? IQStyle.accent.opacity(0.8) : .white.opacity(0.1), lineWidth: 1))
        .id("search-anchor")
    }

    private var suggestions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                suggestion("Beach day", symbol: "sun.max")
                suggestion("Birthday cake", symbol: "birthday.cake")
                suggestion("My dog", symbol: "pawprint")
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
                .background(.white.opacity(0.045), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 1))
        }.buttonStyle(.plain).foregroundStyle(IQStyle.secondary)
    }

    @ViewBuilder private var searchContent: some View {
        if state.activity == .searching {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(IQStyle.accent)
                Text("Finding your moment…").font(.subheadline).foregroundStyle(IQStyle.secondary)
                Button("Cancel") { state.cancel() }.font(.subheadline)
            }.frame(maxWidth: .infinity).padding(.vertical, 54).accessibilityIdentifier("search-loading")
        } else if state.errorMessage != nil {
            emptyCard(symbol: "exclamationmark.circle", title: "Something needs attention",
                      detail: "Your photos are safe. Open your library for details and try again.")
            Button("Open library") { showLibrary = true }.buttonStyle(.bordered)
        } else if !state.results.isEmpty {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your matches").font(.title3.weight(.bold))
                    Text("\(state.results.count) photos · Best matches first").font(.caption).foregroundStyle(IQStyle.secondary)
                }
                Spacer()
                Button { compactGrid.toggle() } label: {
                    Image(systemName: compactGrid ? "rectangle.grid.1x2" : "square.grid.3x3")
                        .frame(width: 44, height: 44).background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                }.accessibilityLabel(compactGrid ? "Show larger photos" : "Show compact grid")
                    .accessibilityIdentifier("toggle-grid-layout")
            }.accessibilityIdentifier("results-heading")
            PhotoResultsGrid(hits: state.results, compact: compactGrid, onSelect: { id in
                isSearchFocused = false
                state.selection = AppState.Selection(id: id)
            }) { photo in
                PhotoThumbnailView(photo: photo, cache: state.thumbnails, networkAllowed: state.allowICloudDownload)
            }
        } else if state.completedQuery != nil {
            emptyCard(symbol: "magnifyingglass", title: "No photos to show",
                      detail: "Try another description or check which photos are ready in your library.")
        } else {
            emptyCard(symbol: state.canRead ? "sparkle.magnifyingglass" : "photo.on.rectangle.angled",
                      title: state.canRead && state.summary.indexedCount > 0 ? "Start with a memory" : "Your photos. A new way to find them.",
                      detail: state.canRead && state.summary.indexedCount > 0
                        ? "The scene, the people, the little detail you remember."
                        : "Connect your library, then describe what you’re looking for.")
            if !state.canRead || state.summary.indexedCount == 0 {
                Button("Set up my library") { isSearchFocused = false; showLibrary = true }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    .background(IQStyle.accent, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(IQStyle.background).buttonStyle(.plain).accessibilityIdentifier("setup-library")
            }
        }
    }

    private func emptyCard(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: symbol).font(.system(size: 36, weight: .light)).foregroundStyle(IQStyle.accent)
                .frame(width: 82, height: 82).background(IQStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 26))
            Text(title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text(detail).font(.subheadline).foregroundStyle(IQStyle.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 32)
    }

    private func submitSearch() { isSearchFocused = false; state.search() }
}