import SwiftUI
import ImageIQCore

/// Production uses embedded mode in a retained primary page. The default
/// standalone host preserves the original manual sheet contract for old tests.
@MainActor
struct SimilarPhotoCleanupSheet: View {
    @ObservedObject var state: SimilarPhotoCleanupState
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var browser: SimilarPhotoGroupBrowser
    private let thumbnailContent: ((IndexedPhoto) -> AnyView)?
    private let comparisonImageSource: SimilarComparisonImageSource?
    let embedded: Bool
    let isPageActive: Bool
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    @State private var previousInput: CleanupPresentationInput?
    @State private var hasRequestedGrouping = false
    @State private var confirmationIntent: SimilarPhotoDeletionIntent?
    @State private var showsConfirmation = false

    init(state: SimilarPhotoCleanupState, appState: AppState,
         browser: SimilarPhotoGroupBrowser? = nil,
         thumbnailContent: ((IndexedPhoto) -> AnyView)? = nil,
         comparisonImageSource: SimilarComparisonImageSource? = nil,
         embedded: Bool = false, isPageActive: Bool = true,
         openLibrary: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {}) {
        self.state = state
        self.appState = appState
        _browser = StateObject(wrappedValue: browser ?? SimilarPhotoGroupBrowser())
        // Native-host tests may supply synthetic pixels. Production always uses
        // the existing revision/network-aware HQ224-fallback thumbnail cache.
        self.thumbnailContent = thumbnailContent
        self.comparisonImageSource = comparisonImageSource
        self.embedded = embedded
        self.isPageActive = isPageActive
        self.openLibrary = openLibrary
        self.openSettings = openSettings
    }

    private var libraryReady: Bool {
        scenePhase != .background && appState.isForeground && appState.canRead && appState.modelsReady
            && appState.summary.indexStatisticsKnown && appState.summary.indexedCount > 0 && !appState.isBusy
    }

    private var canScan: Bool {
        libraryReady && (!embedded || isPageActive)
            && !state.isGrouping && !state.isRestoring && !state.isDeleting && !state.isSelecting
    }

    private var thresholdBinding: Binding<Double> {
        // Integer slider ticks avoid Float-to-Double roundoff at decimal steps.
        Binding(get: { (Double(state.threshold) * 100).rounded() }, set: { value in
            guard !state.isDeleting, !state.isSelecting else { return }
            // The controller cancels/invalidates the old read; never regroup here.
            state.threshold = Float(value.rounded()) / 100
        })
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 16))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Keep this exact ScrollView alive and at its original offset
                // under the detail overlay, including comparison/gallery covers.
                overview
                    .opacity(browser.detailRoute == nil ? 1 : 0)
                    .allowsHitTesting(browser.detailRoute == nil)
                    .accessibilityHidden(browser.detailRoute != nil)
                if let route = browser.detailRoute,
                   route.sessionID == state.selectionSessionID,
                   let index = state.groups.firstIndex(where: { $0.id == route.groupID }) {
                    SimilarPhotoGroupDetail(group: state.groups[index], number: index + 1,
                                            route: route, state: state, browser: browser, thumbnail: thumbnail)
                        .id(route.id)
                }
                SimilarPhotoZoomOverlay(flight: browser.zoomFlight, reduceMotion: reduceMotion,
                                        completion: browser.finishZoom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background(IQStyle.background.ignoresSafeArea())
            .navigationTitle(embedded ? "相似清理" : "相似照片清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if embedded {
                    ToolbarItem(placement: .topBarLeading) {
                        PrimaryLibraryButton(canRead: appState.canRead, action: openLibrary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        PrimarySettingsButton(action: openSettings)
                    }
                }
                if browser.detailRoute != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("所有分组", systemImage: "chevron.left") {
                            state.cancelRangeSelection()
                            browser.closeDetail()
                        }
                        .disabled(state.isDeleting)
                        .accessibilityIdentifier("similar-cleanup-all-groups")
                    }
                }
                if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .disabled(state.isDeleting)
                            .accessibilityIdentifier("close-similar-cleanup")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.isDeleting {
                    HStack(spacing: 12) {
                        ProgressView().tint(IQStyle.accent)
                        Text("正在等待系统删除结果")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(IQStyle.surface)
                    .accessibilityElement(children: .combine)
                } else if state.selectedCount > 0 || state.isSelecting {
                    selectionToolbar
                }
            }
        }
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .interactiveDismissDisabled(state.isDeleting)
        .sheet(item: $browser.comparisonGroup) { group in
            SimilarPhotoComparisonSheet(group: group, cleanup: state, appState: appState,
                                        imageSource: comparisonImageSource)
        }
        .fullScreenCover(item: $browser.viewer) { selection in
            // ID-based normal viewer: no synthetic SearchHit, no search action,
            // and only its current page requests the full photo.
            PhotoGalleryViewer(ids: selection.ids, initialID: selection.id, library: appState.library,
                               networkAllowed: appState.allowICloudDownload)
        }
        .confirmationDialog(
            "删除选中的\(confirmationIntent?.count ?? 0)张照片？",
            isPresented: $showsConfirmation, titleVisibility: .visible,
            presenting: confirmationIntent
        ) { intent in
            Button("删除\(intent.count)张", role: .destructive) {
                // Use this immutable presenting value, not a binding SwiftUI may
                // already have dismissed. Only the controller validates/submits.
                state.confirmDeletion(intent)
            }
            .disabled(state.isDeleting || state.isSelecting || state.pendingDeletion?.id != intent.id)
            Button("取消", role: .cancel) {
                state.cancelDeletionConfirmation()
            }
        } message: { intent in
            Text(deletionWarning(intent))
        }
        .alert("相似照片清理", isPresented: Binding(
            get: { state.message != nil },
            set: { if !$0 { state.dismissMessage() } }
        ), presenting: state.message) { _ in
            Button("知道了", role: .cancel) { state.dismissMessage() }
        } message: { message in
            Text(message)
        }
        .onChange(of: state.pendingDeletion?.id) { _, id in
            if id == nil { showsConfirmation = false }
        }
        .onChange(of: state.groups.map(\.id)) { _, ids in
            if let comparisonGroup = browser.comparisonGroup, !ids.contains(comparisonGroup.id) {
                browser.comparisonGroup = nil
            }
            if let route = browser.detailRoute, !ids.contains(route.groupID) { browser.closeDetail() }
        }
        .onChange(of: state.selectionSessionID) { _, session in browser.invalidate(sessionID: session) }
        .onChange(of: presentationInput, initial: true) { _, input in updateLifecycle(input) }
        // Do not pause onDisappear: a gallery/comparison cover can disappear
        // this root without leaving cleanup. The tab input owns page activity;
        // only an actual background transition pauses the controller.
    }

    private var presentationInput: CleanupPresentationInput {
        CleanupPresentationInput(epoch: appState.photoLibraryEpoch, authorization: appState.authorization.rawValue,
                                 ready: libraryReady, pageActive: isPageActive, phase: scenePhase)
    }

    private func updateLifecycle(_ input: CleanupPresentationInput) {
        let old = previousInput
        previousInput = input
        let accessChanged = old.map { $0.epoch != input.epoch || $0.authorization != input.authorization } ?? false
        if embedded, old?.pageActive == true, !input.pageActive {
            showsConfirmation = false
            state.cancelRangeSelection()
            state.leavePage()
        }
        if input.phase == .background, old?.phase != .background {
            browser.closeDetail()
            showsConfirmation = false
            state.cancelRangeSelection()
            state.pause()
        }
        // Suppress automatic entry until this same update's readiness has been
        // applied. Never start a restore using the previous authorization/busy
        // value only to cancel it in a second observer for the same publication.
        if accessChanged {
            if embedded { state.availabilityChanged(ready: false) }
            invalidateAccess()
        }
        if embedded {
            if input.pageActive, old?.pageActive != true {
                state.enterPage(ready: input.ready)
            } else {
                state.availabilityChanged(ready: input.ready && input.pageActive)
            }
        }
        if input.phase == .active, old?.phase != .active { state.resume() }
        // Inactive (e.g. a PhotoKit confirmation) is not background and must not
        // cancel the live grouping/selection session.
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                controls
                if state.isRestoring {
                    ProgressView("正在恢复分组…").tint(IQStyle.accent)
                        .accessibilityIdentifier("similar-cleanup-restoring")
                }
                if state.isGrouping { groupingProgress }
                if state.hasScanned { summary }
                if scenePhase != .background {
                    ForEach(Array(state.groups.enumerated()), id: \.element.id) { index, group in
                        groupCard(group, number: index + 1)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("similar-cleanup-scroll")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if embedded {
                Text("相似清理").font(.system(.largeTitle, design: .rounded, weight: .bold))
            }
            Text("全组每两张均达阈值。只是建议，删除前请核对。")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !embedded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("阈值\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(state.threshold)))（越高越严格）")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    Slider(value: thresholdBinding, in: SimilarPhotoGroupingPolicy.sliderTicks, step: 1)
                        .disabled(state.isDeleting || state.isSelecting)
                        .accessibilityLabel("相似度阈值，越高越严格")
                        .accessibilityValue(String(format: "%.2f", Double(state.threshold)))
                        .accessibilityIdentifier("similar-cleanup-threshold")
                }
                if state.threshold < 0.90 {
                    Text("已放宽相似范围，可能包含仅场景相近的照片。请逐张核对后再勾选删除。")
                        .font(.footnote).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("similar-cleanup-broad-threshold-note")
                }
            }
            if state.needsRegroup {
                Text("照片有变化，重新分组")
                    .font(.subheadline).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("similar-cleanup-needs-regroup")
            }
            Button(hasRequestedGrouping || state.hasScanned || state.needsRegroup ? "重新分组" : "开始分组") {
                guard canScan else { return }
                hasRequestedGrouping = true
                state.scan()
            }
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
            .buttonStyle(.bordered)
            .disabled(!canScan)
            .accessibilityIdentifier("start-similar-grouping")
            if let readinessHint {
                Text(readinessHint)
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if embedded, !appState.canRead {
                Button("选择照片", action: openLibrary)
                    .frame(minHeight: 44).accessibilityIdentifier("cleanup-choose-photos")
            }
            if let issue = state.persistenceIssue {
                Text(issue).font(.footnote).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("similar-cleanup-persistence-issue")
            }
        }
    }

    private var readinessHint: String? {
        if !appState.canRead { return "请先在“我的图库”中允许照片访问。" }
        if !appState.modelsReady { return "搜索模型尚未就绪。" }
        if !appState.summary.indexStatisticsKnown { return "索引统计待确认，请先刷新本机统计。" }
        if appState.summary.indexedCount == 0 { return "请先手动更新图片索引。" }
        if appState.isBusy { return "请等待当前任务完成后开始分组。" }
        if state.hasScanned || state.isGrouping || state.isRestoring { return nil }
        return embedded ? "首次进入就绪后自动分组，仅使用已有图片索引。" : "仅使用已有图片索引，不会自动更新。"
    }

    private var groupingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.isValidating || (state.progress.total > 0 && state.progress.completed == state.progress.total) {
                Text("分组计算已完成，正在核验照片访问…")
                    .font(.subheadline).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("similar-cleanup-validating")
            }
            // total==0 is not a completed scan while metadata is being read.
            ProgressView(value: state.progress.total > 0 ? state.progress.fraction : 0, total: 1)
                .tint(IQStyle.accent)
                .accessibilityLabel("分组进度")
            actionLayout {
                Text("已处理\(state.progress.completed) / \(state.progress.total)张")
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("取消") {
                    state.pause()
                    // Re-enable an explicit future scan; this never starts one.
                    if scenePhase == .active { state.resume() }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("cancel-similar-grouping")
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("共\(state.groups.count)组 · 参与分组\(state.candidateCount)张")
                .font(.headline)
            Text("未索引\(state.unindexedCount)张 · 已变化\(state.staleCount)张")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
            Text("新照片或已变化的照片，请手动更新图片索引后重新分组。")
                .font(.footnote)
                .foregroundStyle(IQStyle.secondary)
            if state.groups.isEmpty {
                Text(embedded ? "当前阈值下没有相似照片组。可在设置中调低阈值后点“重新分组”。"
                     : "当前阈值下没有相似照片组。可调低阈值后点“重新分组”。")
                    .font(.subheadline)
                    .padding(.top, 4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: SimilarPhotoGroup, number: Int) -> some View {
        let indices = SimilarPhotoGroupGeometry.previewIndices(count: group.photos.count)
        let selected = group.photos.filter { state.selectedIDs.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if let first = group.photos.first { open(group, photoID: first.id) }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("第\(number)组 · \(group.photos.count)张").font(.headline)
                        Text("最低相似度 \(String(format: "%.3f", Double(group.minimumSimilarity)))")
                            .font(.caption).monospacedDigit().foregroundStyle(IQStyle.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").foregroundStyle(IQStyle.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isGrouping || state.isDeleting || state.isSelecting)
            .accessibilityIdentifier("similar-cleanup-group-\(number)-header")
            .accessibilityHint("打开本组全部照片，定位第一张，不改变选择")
            SimilarPhotoMosaicLayout {
                ForEach(indices, id: \.self) { index in
                    let photo = group.photos[index]
                    previewTile(photo, in: group, number: number, index: index)
                }
            }
            .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text("预览\(indices.count)张，查看全部\(group.photos.count)张")
                    .font(.subheadline)
                Text("已选\(selected)张 · 未选\(group.photos.count - selected)张")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IQStyle.line, lineWidth: 1))
    }

    @ViewBuilder
    private func previewTile(_ photo: IndexedPhoto, in group: SimilarPhotoGroup, number: Int, index: Int) -> some View {
        let label = "第\(number)组，照片\(index + 1)"
        let identifier = "similar-cleanup-group-\(number)-photo-\(index + 1)"
        let selected = state.selectedIDs.contains(photo.id)
        let enabled = !state.isGrouping && !state.isDeleting && !state.isSelecting
        if let thumbnailContent {
            SimilarPhotoPreviewTile(photoID: photo.id, label: label, identifier: identifier,
                selected: selected, enabled: enabled, content: thumbnailContent(photo),
                open: { capture in open(group, photoID: photo.id, capture: capture) })
        } else {
            SimilarPhotoLoadedPreviewTile(photo: photo, cache: appState.thumbnails,
                networkAllowed: appState.allowICloudDownload, label: label, identifier: identifier,
                selected: selected, enabled: enabled,
                open: { capture in open(group, photoID: photo.id, capture: capture) })
        }
    }

    private func thumbnail(_ photo: IndexedPhoto) -> AnyView {
        thumbnailContent?(photo) ?? AnyView(PhotoThumbnailView(photo: photo, cache: appState.thumbnails,
                                                              networkAllowed: appState.allowICloudDownload))
    }

    private func open(_ group: SimilarPhotoGroup, photoID: String, capture: SimilarPhotoThumbnailCapture? = nil) {
        guard !state.isDeleting, !state.isGrouping, !state.isSelecting,
              let session = state.selectionSessionID else { return }
        browser.open(group: group, photoID: photoID, sessionID: session, capture: capture)
    }

    private var selectionToolbar: some View {
        actionLayout {
            Text(state.isValidatingSelection ? "正在核验选择…" : state.isSelecting ? "正在选择…" : "已选\(state.selectedCount)张")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("similar-cleanup-selection-status")
            Button("清空") { state.cancelRangeSelection(); state.clearSelection() }
                .frame(minHeight: 44)
            Button("删除\(state.selectedCount)张", role: .destructive) {
                guard canDelete else { return }
                state.prepareDeletion()
                guard let intent = state.pendingDeletion else { return }
                confirmationIntent = intent
                showsConfirmation = true
            }
            .frame(minHeight: 44)
            .disabled(!canDelete)
            .accessibilityIdentifier("prepare-similar-deletion")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(IQStyle.surface)
        .overlay(alignment: .top) { Rectangle().fill(IQStyle.line).frame(height: 1) }
        // SwiftUI/outside dismissal changes only showsConfirmation, never the
        // controller's pending intent. Cancel/next prepare/invalidation owns it.
    }

    private func deletionWarning(_ intent: SimilarPhotoDeletionIntent) -> String {
        PhotoDeletionRecoveryNotice.warning(emptiedGroupCount: intent.emptiedGroupCount)
    }

    private var canDelete: Bool {
        SimilarPhotoGroupBrowser.canDelete(selectedCount: state.selectedCount, isSelecting: state.isSelecting,
                                          isDeleting: state.isDeleting, isGrouping: state.isGrouping)
    }

    private func invalidateAccess() {
        browser.closeDetail()
        showsConfirmation = false
        state.cancelRangeSelection()
        state.invalidateAccess()
    }
}

private struct CleanupPresentationInput: Equatable {
    let epoch: UUID
    let authorization: Int
    let ready: Bool
    let pageActive: Bool
    let phase: ScenePhase
}