import SwiftUI
import UIKit
import ImageIQCore

/// Production uses embedded mode in a retained primary page. The default
/// standalone host preserves the original manual sheet contract for old tests.
@MainActor
struct SimilarPhotoCleanupSheet: View {
    @ObservedObject var state: SimilarPhotoCleanupState
    @ObservedObject var appState: AppState
    @ObservedObject private var photoSync: PhotoSyncState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var browser: SimilarPhotoGroupBrowser
    private let thumbnailContent: ((IndexedPhoto) -> AnyView)?
    private let comparisonImageSource: SimilarComparisonImageSource?
    let embedded: Bool
    let isPageActive: Bool
    let accessibilityActive: Bool
    private let openLibrary: () -> Void
    private let openSettings: () -> Void
    private let onPresentedSurfaceChanged: (Bool) -> Void
    @State private var previousInput: CleanupPresentationInput?
    @State private var hasRequestedGrouping = false
    @State private var confirmationIntent: SimilarPhotoDeletionIntent?
    @State private var showsConfirmation = false
    @State private var backTranslation: CGFloat = 0

    init(state: SimilarPhotoCleanupState, appState: AppState,
         browser: SimilarPhotoGroupBrowser? = nil,
         thumbnailContent: ((IndexedPhoto) -> AnyView)? = nil,
         comparisonImageSource: SimilarComparisonImageSource? = nil,
         embedded: Bool = false, isPageActive: Bool = true,
         accessibilityActive: Bool = true,
         openLibrary: @escaping () -> Void = {}, openSettings: @escaping () -> Void = {},
         onPresentedSurfaceChanged: @escaping (Bool) -> Void = { _ in }) {
        self.state = state
        self.appState = appState
        _photoSync = ObservedObject(wrappedValue: appState.photoSync)
        _browser = StateObject(wrappedValue: browser ?? SimilarPhotoGroupBrowser())
        // Native-host tests may supply synthetic pixels. Production always uses
        // the existing revision/network-aware HQ224-fallback thumbnail cache.
        self.thumbnailContent = thumbnailContent
        self.comparisonImageSource = comparisonImageSource
        self.embedded = embedded
        self.isPageActive = isPageActive
        self.accessibilityActive = accessibilityActive
        self.openLibrary = openLibrary
        self.openSettings = openSettings
        self.onPresentedSurfaceChanged = onPresentedSurfaceChanged
    }

    private var libraryReady: Bool {
        scenePhase != .background && appState.isForeground && appState.canRead && appState.modelsReady
            && appState.summary.indexStatisticsKnown && appState.summary.indexedCount > 0 && !appState.isBusy
    }

    private var canScan: Bool {
        libraryReady && (!embedded || isPageActive)
            && !state.isGrouping && !state.isRestoring && !state.isDeleting && !state.isSelecting
    }

    // Gate only the base NavigationStack. Its separately presented surfaces
    // remain accessible; none of these flags participates in updateLifecycle.
    private var hasPresentedSurface: Bool {
        browser.comparisonGroup != nil || browser.viewer != nil || showsConfirmation || state.message != nil
    }

    private var isPageAccessible: Bool {
        (!embedded || isPageActive) && accessibilityActive && !hasPresentedSurface
    }

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 16))
    }

    var body: some View {
        #if DEBUG
        if embedded, ProcessInfo.processInfo.environment["IMAGEIQ_CLEANUP_NAVIGATION_FIXTURE"] == "1" {
            CleanupNavigationUITestHost(appState: appState, isPageActive: isPageActive,
                accessibilityActive: accessibilityActive, onPresentedSurfaceChanged: onPresentedSurfaceChanged)
        } else {
            cleanupBody
        }
        #else
        cleanupBody
        #endif
    }

    private var canReturnFromDetail: Bool {
        browser.detailRoute != nil && !state.isDeleting && isPageAccessible
            && scenePhase != .background && browser.zoomFlight == nil
    }

    private func returnToOverview() {
        guard canReturnFromDetail else { return }
        state.cancelRangeSelection()
        browser.closeDetail()
        backTranslation = 0
    }

    private var cleanupBody: some View {
        NavigationStack {
            ZStack {
                // Keep this exact ScrollView alive and at its original offset
                // under the detail overlay, including comparison/gallery covers.
                overview
                    .opacity(browser.detailRoute == nil || backTranslation > 0 ? 1 : 0)
                    .allowsHitTesting(browser.detailRoute == nil)
                    .accessibilityHidden(!isPageAccessible || browser.detailRoute != nil)
                if let route = browser.detailRoute,
                   route.sessionID == state.selectionSessionID,
                   let group = state.displayGroups.first(where: { $0.id == route.groupID }),
                   let number = state.displayNumber(for: group.id) {
                    SimilarPhotoGroupDetail(group: group, number: number,
                                            route: route, state: state, browser: browser, thumbnail: thumbnail)
                        .id(route.id)
                        .offset(x: backTranslation)
                }
                SimilarPhotoZoomOverlay(flight: browser.zoomFlight, reduceMotion: reduceMotion,
                                        completion: browser.finishZoom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .clipped()
            .background {
                CleanupBackNavigation(routeID: browser.detailRoute?.id, enabled: canReturnFromDetail,
                    canReturn: { canReturnFromDetail }, began: { state.cancelRangeSelection() },
                    changed: { backTranslation = $0 }, cancelled: {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { backTranslation = 0 }
                    }, returned: returnToOverview)
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .background {
                // Inside this page's NavigationStack; the native scope also
                // covers the retained detail UICollectionView and header.
                PrimaryPageAccessibilityAnchor(active: isPageAccessible)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .background(IQStyle.background.ignoresSafeArea())
            .navigationTitle("相似清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if embedded && isPageAccessible && browser.detailRoute == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        PrimaryLibraryButton(canRead: appState.canRead, action: openLibrary)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        PrimarySettingsButton(action: openSettings)
                    }
                }
                if isPageAccessible && browser.detailRoute != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("所有分组", systemImage: "chevron.left") {
                            returnToOverview()
                        }
                        .disabled(state.isDeleting)
                        .accessibilityIdentifier("similar-cleanup-all-groups")
                    }
                }
                if !embedded && isPageAccessible {
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
            .accessibilityHidden(!isPageAccessible)
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
            .disabled(!state.canSelect || state.pendingDeletion?.id != intent.id)
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
        .onChange(of: browser.detailRoute?.id) { _, _ in
            backTranslation = 0
            state.cancelRangeSelection()
        }
        .onChange(of: hasPresentedSurface, initial: true) { _, presented in
            onPresentedSurfaceChanged(presented)
        }
        .onChange(of: presentationInput, initial: true) { _, input in updateLifecycle(input) }
        // Do not pause onDisappear: a gallery/comparison cover can disappear
        // this root without leaving cleanup. The tab input owns page activity;
        // only an actual background transition pauses the controller.
    }

    private var presentationInput: CleanupPresentationInput {
        CleanupPresentationInput(epoch: appState.photoLibraryEpoch, authorization: appState.authorization.rawValue,
                                 ready: libraryReady, pageActive: isPageActive, phase: scenePhase,
                                 syncPhase: photoSync.phase)
    }

    private func updateLifecycle(_ input: CleanupPresentationInput) {
        let old = previousInput
        previousInput = input
        let accessChanged = old.map { $0.epoch != input.epoch || $0.authorization != input.authorization } ?? false
        // AppState does not forward child objectWillChange. Observe PhotoSync
        // directly and set its deferral BEFORE any initial entry/ready event.
        // If readiness is dropping too, hold admission until that new value is
        // installed; releasing sync must not briefly reuse yesterday's ready.
        if embedded {
            state.setAutomaticRefreshDeferred(input.defersAutomaticRefresh || accessChanged
                || !input.ready || !input.pageActive)
        }
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
        if embedded { state.setAutomaticRefreshDeferred(input.defersAutomaticRefresh) }
        // Inactive (e.g. a PhotoKit confirmation) is not background and must not
        // cancel the live grouping/selection session.
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                controls
                if state.hasScanned { summary }
                if scenePhase != .background {
                    ForEach(state.displayGroups) { group in
                        if let number = state.displayNumber(for: group.id) {
                            groupCard(group, number: number)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(!isPageAccessible || browser.detailRoute != nil)
        }
        .accessibilityIdentifier("similar-cleanup-scroll")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            SimilarCleanupThresholdControls(state: state, automaticallyCommits: embedded)
            if state.isRestoring {
                HStack {
                    ProgressView("正在更新分组…").tint(IQStyle.accent)
                        .accessibilityIdentifier("similar-cleanup-restoring")
                    Spacer()
                    cancelGroupingButton
                }
            } else if state.isGrouping {
                groupingProgress
            } else if let statusLine {
                Text(statusLine)
                    .font(.footnote).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("similar-cleanup-state")
                    .cleanupControlFrame(.pending)
            }
            if !embedded {
                Button(state.hasPendingThresholdChange ? "更新结果"
                       : hasRequestedGrouping || state.hasScanned || state.needsRegroup ? "重新分组" : "开始分组") {
                    guard canScan && state.canUpdateResults else { return }
                    hasRequestedGrouping = true
                    state.updateResults()
                }
                .font(.body.weight(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.bordered)
                .disabled(!canScan || !state.canUpdateResults)
                .accessibilityIdentifier("start-similar-grouping")
                .cleanupControlFrame(.action)
            } else if state.canRetryAutomaticRefresh {
                Button(state.failureDiagnostic == nil ? "继续" : "重试") { state.retryAutomaticRefresh() }
                    .frame(minHeight: 44).buttonStyle(.bordered)
                    .disabled(!canScan || presentationInput.defersAutomaticRefresh)
                    .accessibilityIdentifier("retry-similar-grouping")
            }
            if embedded, !appState.canRead {
                Button("选择照片", action: openLibrary)
                    .frame(minHeight: 44).accessibilityIdentifier("cleanup-choose-photos")
            }
        }
    }

    private var statusLine: String? {
        // Pending, readiness and persistence are mutually exclusive here: never
        // stack several instructions above the same result. Deletion warnings
        // remain in their existing confirmation/result surfaces.
        if !appState.canRead { return "请先允许照片访问" }
        if !appState.modelsReady { return "暂未就绪" }
        if !appState.summary.indexStatisticsKnown { return "照片信息待确认" }
        if embedded && presentationInput.defersAutomaticRefresh { return "照片同步后自动更新" }
        if appState.summary.indexedCount == 0 { return "等待照片同步" }
        if embedded && state.canRetryAutomaticRefresh {
            return state.failureDiagnostic == nil ? "分组已暂停" : "分组更新失败"
        }
        if appState.isBusy { return "等待当前任务完成" }
        if state.hasPendingThresholdChange || state.needsRegroup { return "分组待更新" }
        return state.persistenceIssue
    }

    private var groupingProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            // total==0 is not a completed scan while metadata is being read.
            ProgressView(value: state.progress.total > 0 ? state.progress.fraction : 0, total: 1)
                .tint(IQStyle.accent)
                .accessibilityLabel("分组进度")
            actionLayout {
                Text(state.isValidating ? "正在核验照片…" : "正在更新 \(state.progress.completed)/\(state.progress.total)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                cancelGroupingButton
            }
        }
    }

    private var cancelGroupingButton: some View {
        Button("取消") {
            if embedded { state.cancelAutomaticRefresh() }
            else {
                state.pause()
                if scenePhase == .active { state.resume() }
            }
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("cancel-similar-grouping")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("共\(state.displayGroups.count)组 · 参与分组\(state.candidateCount)张")
                .font(.headline)
            if state.unindexedCount > 0 || state.staleCount > 0 {
                DisclosureGroup {
                    if state.unindexedCount > 0 { Text("未索引\(state.unindexedCount)张") }
                    if state.staleCount > 0 { Text("已变化\(state.staleCount)张") }
                } label: {
                    Text("部分照片尚未参与分组").accessibilityIdentifier("similar-cleanup-source-counts")
                }
                .font(.footnote).foregroundStyle(IQStyle.secondary)
            }
            if state.groups.isEmpty {
                Text("暂无相似照片，可展开调节相似度。")
                    .font(.subheadline)
                    .padding(.top, 4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func groupCard(_ group: SimilarPhotoGroup, number: Int) -> some View {
        let indices = SimilarPhotoGroupGeometry.previewIndices(count: group.photos.count)
        let selected = group.photos.filter { state.selectedIDs.contains($0.id) }.count
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if let first = group.photos.first { open(group, photoID: first.id) }
            } label: {
                HStack(alignment: .top) {
                    Text("第\(number)组 · \(group.photos.count)张").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
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
            if group.photos.count > 30 || selected > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if group.photos.count > 30 {
                        Button("查看全部\(group.photos.count)张") {
                            if let first = group.photos.first { open(group, photoID: first.id) }
                        }
                        .font(.subheadline).frame(minHeight: 44)
                        .disabled(state.isGrouping || state.isDeleting || state.isSelecting)
                        .accessibilityIdentifier("similar-cleanup-group-\(number)-view-all")
                    }
                    if selected > 0 {
                        Text("已选\(selected)张").font(.caption).foregroundStyle(IQStyle.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
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
                .disabled(!state.canSelect)
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
        state.canSelect && SimilarPhotoGroupBrowser.canDelete(selectedCount: state.selectedCount, isSelecting: state.isSelecting,
                                          isDeleting: state.isDeleting, isGrouping: state.isGrouping)
    }

    private func invalidateAccess() {
        browser.closeDetail()
        showsConfirmation = false
        state.cancelRangeSelection()
        state.invalidateAccess()
    }
}

/// Public layout preferences describe the real controls, not a second fitting
/// copy. Native-host tests can measure the same text/slider frames.
enum SimilarCleanupControlPart: Hashable {
    case introduction, instruction, disclosure, labels, slider, value, action, pending, warning
}

struct SimilarCleanupControlFrames: PreferenceKey {
    static var defaultValue: [SimilarCleanupControlPart: CGRect] { [:] }
    static func reduce(value: inout [SimilarCleanupControlPart: CGRect],
                       nextValue: () -> [SimilarCleanupControlPart: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func cleanupControlFrame(_ part: SimilarCleanupControlPart) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: SimilarCleanupControlFrames.self,
                                       value: [part: geometry.frame(in: .global)])
            }
        }
    }
}

@MainActor
struct SimilarCleanupThresholdControls: View {
    @ObservedObject var state: SimilarPhotoCleanupState
    var automaticallyCommits = false
    @State private var expanded = false

    static func value(_ threshold: Float) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(threshold))
    }

    private var thresholdBinding: Binding<Double> {
        Binding(get: { (Double(state.draftThreshold) * 100).rounded() }, set: {
            state.setDraftThreshold(Float($0.rounded()) / 100)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("相似度")
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cleanupControlFrame(.instruction)
                // Only this 44x44 target toggles disclosure; the short label
                // is ordinary text and does not steal taps/scrolling.
                SimilarCleanupDisclosureButton(expanded: $expanded)
                    .frame(width: 44, height: 44)
                    .cleanupControlFrame(.disclosure)
            }
            if expanded {
                VStack(spacing: 6) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("宽松").frame(maxWidth: .infinity, alignment: .leading)
                        Text("组内照片相似度").multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        Text("严格").frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                    .cleanupControlFrame(.labels)
                    Slider(value: thresholdBinding, in: SimilarPhotoGroupingPolicy.sliderTicks, step: 1,
                           onEditingChanged: { editing in
                               if !editing && automaticallyCommits { state.commitDraftThreshold() }
                           })
                        .disabled(!state.canChangeThreshold)
                        .accessibilityLabel("组内照片相似度，越高越严格")
                        .accessibilityValue(Self.value(state.draftThreshold))
                        .accessibilityIdentifier("similar-cleanup-threshold")
                        .accessibilityAdjustableAction { direction in
                            guard state.canChangeThreshold else { return }
                            let tick = (Double(state.draftThreshold) * 100).rounded()
                            let next: Double
                            switch direction {
                            case .increment: next = min(SimilarPhotoGroupingPolicy.sliderTicks.upperBound, tick + 1)
                            case .decrement: next = max(SimilarPhotoGroupingPolicy.sliderTicks.lowerBound, tick - 1)
                            @unknown default: return
                            }
                            state.setDraftThreshold(Float(next) / 100)
                            if automaticallyCommits { state.commitDraftThreshold() }
                        }
                        .cleanupControlFrame(.slider)
                    Text(Self.value(state.draftThreshold))
                        .font(.system(size: 11, weight: .regular)).monospacedDigit()
                        .cleanupControlFrame(.value)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("similar-cleanup-threshold-value")
                }
            }
            if expanded && state.draftThreshold < 0.90 {
                Text("范围较宽，可能包含仅场景相近的照片。")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("similar-cleanup-broad-threshold-note")
                    .cleanupControlFrame(.warning)
            }
        }
        .foregroundStyle(IQStyle.secondary)
    }
}

/// A native button gives the disclosure an explicit, stable 44-point hit/AX
/// target without making the entire explanatory paragraph actionable.
@MainActor
private struct SimilarCleanupDisclosureButton: UIViewRepresentable {
    @Binding var expanded: Bool

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addAction(UIAction { _ in expanded.toggle() }, for: .touchUpInside)
        button.accessibilityIdentifier = "similar-cleanup-threshold-disclosure"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        button.setImage(UIImage(systemName: expanded ? "chevron.up" : "chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        button.tintColor = UIColor(IQStyle.secondary)
        button.accessibilityLabel = expanded ? "收起相似度调节" : "展开相似度调节"
        button.accessibilityValue = expanded ? "已展开" : "已收起"
    }
}

struct CleanupPresentationInput: Equatable {
    let epoch: UUID
    let authorization: Int
    let ready: Bool
    let pageActive: Bool
    let phase: ScenePhase
    let syncPhase: PhotoSyncState.Phase

    var defersAutomaticRefresh: Bool {
        switch syncPhase {
        case .checking, .updating, .cancelling: return true
        default: return false
        }
    }
}