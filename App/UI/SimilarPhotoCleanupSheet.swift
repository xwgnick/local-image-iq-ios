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
    @State private var protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    @State private var showsSettingsInfo = false

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
        scenePhase != .background && protectedDataAvailable && appState.isForeground && appState.canRead && appState.modelsReady
            && appState.summary.indexStatisticsKnown && appState.summary.indexedCount > 0 && !appState.isBusy
    }

    private var canScan: Bool {
        libraryReady && (!embedded || isPageActive)
            && !state.isGrouping && !state.isRestoring && !state.isDeleting && !state.isSelecting
    }

    // Gate only the base NavigationStack. Its separately presented surfaces
    // remain accessible; none of these flags participates in updateLifecycle.
    private var hasPresentedSurface: Bool {
        browser.comparisonGroup != nil || browser.viewer != nil || showsConfirmation || state.message != nil || showsSettingsInfo
    }

    private var isPageAccessible: Bool {
        (!embedded || isPageActive) && accessibilityActive && !hasPresentedSurface
            && scenePhase == .active && state.displayActive && protectedDataAvailable && appState.isForeground
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
            && scenePhase == .active && state.canBrowse && browser.zoomFlight == nil
    }

    private var contentVisible: Bool {
        scenePhase == .active && state.displayActive && protectedDataAvailable && appState.isForeground
            && (state.canBrowse || state.groups.isEmpty)
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
                   route.sessionID == state.browsingSessionID,
                   let group = state.displayGroups.first(where: { $0.id == route.groupID }),
                   let number = state.displayNumber(for: group.id) {
                    SimilarPhotoGroupDetail(group: group, number: number,
                                            route: route, state: state, browser: browser, thumbnail: thumbnail)
                        .id(route.id)
                        .offset(x: backTranslation)
                }
                SimilarPhotoZoomOverlay(flight: contentVisible ? browser.zoomFlight : nil, reduceMotion: reduceMotion,
                                        completion: browser.finishZoom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .opacity(contentVisible ? 1 : 0)
            .allowsHitTesting(contentVisible)
            .accessibilityHidden(!contentVisible)
            .overlay {
                if !contentVisible {
                    IQStyle.background.overlay {
                        Label("照片核验后恢复浏览", systemImage: "lock")
                            .font(.footnote).foregroundStyle(IQStyle.secondary)
                    }
                    .accessibilityIdentifier("similar-cleanup-privacy-cover")
                }
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
                } else if contentVisible && (state.selectedCount > 0 || state.isSelecting) {
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
        .onChange(of: state.groups.map { $0.photos.map(\.id) }) { _, _ in
            browser.reconcile(groups: state.groups, sessionID: state.browsingSessionID)
        }
        .onChange(of: state.browsingSessionID) { _, session in browser.invalidate(sessionID: session) }
        .onChange(of: state.selectionSessionID) { _, _ in
            browser.reconcile(groups: state.groups, sessionID: state.browsingSessionID)
        }
        .onChange(of: state.canBrowse) { _, allowed in
            if !allowed { browser.hidePrivateSurfaces(); showsConfirmation = false }
        }
        .onChange(of: browser.detailRoute?.id) { _, _ in
            backTranslation = 0
            state.cancelRangeSelection()
        }
        .onChange(of: hasPresentedSurface, initial: true) { _, presented in
            onPresentedSurfaceChanged(presented)
        }
        .onChange(of: presentationInput, initial: true) { _, input in updateLifecycle(input) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            browser.hidePrivateSurfaces()
            showsConfirmation = false
            state.setDisplayEnvironment(foreground: appState.isForeground, protectedDataAvailable: protectedDataAvailable,
                                        canRead: presentationInput.displayCanRead, active: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // SwiftUI may coalesce a brief inactive/active round trip. Reapply
            // the actual input even if its Equatable value did not change.
            updateLifecycle(presentationInput)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            protectedDataAvailable = false
            browser.hidePrivateSurfaces()
            showsConfirmation = false
            state.setDisplayEnvironment(foreground: appState.isForeground, protectedDataAvailable: false,
                                        canRead: presentationInput.displayCanRead, active: scenePhase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            browser.hidePrivateSurfaces()
            showsConfirmation = false
            state.pause()
        }
        // Do not pause onDisappear: a gallery/comparison cover can disappear
        // this root without leaving cleanup. The tab input owns page activity;
        // only an actual background transition pauses the controller.
    }

    private var presentationInput: CleanupPresentationInput {
        CleanupPresentationInput(epoch: appState.photoLibraryEpoch, authorization: appState.authorization.rawValue,
                                 ready: libraryReady, pageActive: isPageActive, phase: scenePhase,
                                 syncPhase: photoSync.phase, protectedDataAvailable: protectedDataAvailable,
                                 foreground: appState.isForeground,
                                            displayCanRead: state.displayAccessIsReadable
                                                ?? (thumbnailContent != nil ? true : PhotoLibraryClient.canRead))
    }

    private func updateLifecycle(_ input: CleanupPresentationInput) {
        let old = previousInput
        previousInput = input
        let accessChanged = old.map { $0.epoch != input.epoch || $0.authorization != input.authorization } ?? false
        if thumbnailContent == nil {
            state.configureBrowsingAccess(SimilarCleanupBrowsingAccess(library: appState.library))
        }
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
            browser.hidePrivateSurfaces()
            showsConfirmation = false
            state.cancelRangeSelection()
            state.pause()
        }
        if input.phase != .active {
            browser.hidePrivateSurfaces()
            showsConfirmation = false
        }
        // Suppress automatic entry until this same update's readiness has been
        // applied. Never start a restore using the previous authorization/busy
        // value only to cancel it in a second observer for the same publication.
        if accessChanged {
            if embedded { state.availabilityChanged(ready: false) }
            showsConfirmation = false
            browser.hidePrivateSurfaces()
            if old?.authorization != input.authorization || !input.displayCanRead {
                invalidateAccess()
            } else {
                state.photosChanged()
            }
        }
        state.setDisplayEnvironment(foreground: input.foreground && input.phase != .background,
                                    protectedDataAvailable: input.protectedDataAvailable, canRead: input.displayCanRead,
                                    active: input.phase == .active)
        if embedded {
            if input.pageActive, old?.pageActive != true {
                state.enterPage(ready: input.ready)
            } else {
                state.availabilityChanged(ready: input.ready && input.pageActive)
            }
        }
        if input.phase == .active, input.foreground, input.protectedDataAvailable,
           old?.phase != .active { state.resume() }
        if embedded { state.setAutomaticRefreshDeferred(input.defersAutomaticRefresh) }
        // Inactive hides pixels and revokes hidden gestures/confirmations, but
        // does not cancel a read session or an already submitted Photos mutation.
    }

    private var overview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                controls
                if state.hasScanned { summary }
                // Keep group geometry alive behind the privacy cover so the
                // ScrollView's offset survives; previewTile releases its pixels.
                ForEach(state.visibleGroups) { group in
                    if let number = state.displayNumber(for: group.id) {
                        groupCard(group, number: number)
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
            SimilarCleanupThresholdControls(state: state, automaticallyCommits: embedded,
                                            onPresentedSurfaceChanged: { showsSettingsInfo = $0 })
            if let notice = state.statusNotice {
                HStack(spacing: 8) {
                    Text(notice).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if notice.hasPrefix("已删除") {
                        Button("恢复说明") { state.showDeletionRecovery() }.font(.footnote).frame(minHeight: 44)
                    }
                    Button { state.dismissStatusNotice() } label: { Image(systemName: "xmark") }
                        .frame(width: 44, height: 44).accessibilityLabel("关闭状态提示")
                }
                .foregroundStyle(IQStyle.secondary)
                .accessibilityIdentifier("similar-cleanup-status-notice")
            }
            if state.isRestoring {
                HStack {
                    ProgressView("正在恢复已有分组…").tint(IQStyle.accent)
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
            Text("显示\(state.visibleGroups.count)/\(state.displayGroups.count)组 · 参与分组\(state.candidateCount)张")
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
            } else if state.visibleGroups.isEmpty {
                Text("当前张数筛选下暂无分组，已有选择仍保留。")
                    .font(.subheadline)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func groupCard(_ group: SimilarPhotoGroup, number: Int) -> some View {
        let indices = SimilarPhotoGroupGeometry.previewIndices(count: group.photos.count)
        let selection = SimilarGroupPresentation.selection(in: group, selectedIDs: state.selectedIDs)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { state.toggleGroupSelection(group.id) } label: {
                    Image(systemName: selection == .all ? "checkmark.circle.fill" : selection == .partial ? "minus.circle.fill" : "circle")
                        .font(.system(size: 22)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).disabled(!state.canSelect)
                .accessibilityLabel("第\(number)组选择")
                .accessibilityValue(selection == .all ? "全部选中" : selection == .partial ? "部分选中" : "未选中")
                .accessibilityHint(selection == .all ? "取消本组全部勾选，不删除照片" : "选择本组全部照片，不自动留一张")
                .accessibilityIdentifier("similar-cleanup-group-\(number)-checkbox")
                Button {
                    if let first = group.photos.first { open(group, photoID: first.id) }
                } label: {
                    HStack {
                        Text("第\(number)组 · \(group.photos.count)张").font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").foregroundStyle(IQStyle.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!state.canBrowse || state.isDeleting || state.isSelecting)
                .accessibilityIdentifier("similar-cleanup-group-\(number)-header")
                .accessibilityHint("打开本组全部照片，定位第一张，不改变选择")
            }
            SimilarPhotoMosaicLayout {
                ForEach(indices, id: \.self) { index in
                    let photo = group.photos[index]
                    previewTile(photo, in: group, number: number, index: index)
                        .overlay {
                            if index == 4, group.photos.count > 5 {
                                ZStack {
                                    Color.black.opacity(0.5)
                                    Text("+\(SimilarPhotoGroupGeometry.overflowCount(count: group.photos.count))")
                                        .font(.headline).foregroundStyle(.white)
                                }.allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                }
            }
            .clipped()
            Rectangle().fill(IQStyle.line).frame(height: 0.5).padding(.top, 12)
        }
    }

    @ViewBuilder
    private func previewTile(_ photo: IndexedPhoto, in group: SimilarPhotoGroup, number: Int, index: Int) -> some View {
        let label = index == 4 && group.photos.count > 5
            ? "第\(number)组，另有\(group.photos.count - 4)张，查看全部\(group.photos.count)张"
            : "第\(number)组，照片\(index + 1)"
        let identifier = "similar-cleanup-group-\(number)-photo-\(index + 1)"
        let selected = state.selectedIDs.contains(photo.id)
        let enabled = state.canBrowse && !state.isDeleting && !state.isSelecting
        if scenePhase != .active || !protectedDataAvailable || !state.canBrowse {
            Color.clear
        } else if let thumbnailContent {
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
        guard scenePhase == .active, protectedDataAvailable, state.canBrowse else { return AnyView(Color.clear) }
        return thumbnailContent?(photo) ?? AnyView(PhotoThumbnailView(photo: photo, cache: appState.thumbnails,
                                                              networkAllowed: appState.allowICloudDownload))
    }

    private func open(_ group: SimilarPhotoGroup, photoID: String, capture: SimilarPhotoThumbnailCapture? = nil) {
        guard scenePhase == .active, protectedDataAvailable, state.canBrowse, !state.isDeleting, !state.isSelecting,
              let session = state.browsingSessionID else { return }
        browser.open(group: group, photoID: photoID, sessionID: session, capture: capture)
    }

    private var selectionToolbar: some View {
        actionLayout {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.isValidatingSelection ? "正在核验选择…" : state.isSelecting ? "正在选择…" : "已选\(state.selectionSummary.groupCount)组 · \(state.selectedCount)张")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("similar-cleanup-selection-status")
                if state.selectionSummary.hiddenPhotoCount > 0 {
                    Text("其中\(state.selectionSummary.hiddenGroupCount)组 · \(state.selectionSummary.hiddenPhotoCount)张被筛选隐藏")
                        .font(.caption).foregroundStyle(IQStyle.secondary)
                        .accessibilityIdentifier("similar-cleanup-hidden-selection")
                }
            }.fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            Button("清空全部选择") { state.cancelRangeSelection(); state.clearSelection() }
                .frame(minHeight: 44)
                .font(.footnote).foregroundStyle(IQStyle.secondary)
                .disabled(state.isDeleting)
                .accessibilityIdentifier("similar-cleanup-clear-all")
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
        PhotoDeletionRecoveryNotice.warning(emptiedGroupCount: intent.emptiedGroupCount,
                            hiddenGroupCount: intent.hiddenGroupCount, hiddenPhotoCount: intent.hiddenPhotoCount)
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
    case introduction, instruction, disclosure, labels, slider, minimumCountSlider, value, action, pending, warning
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
    var onPresentedSurfaceChanged: (Bool) -> Void = { _ in }
    @State private var expanded = false
    @State private var information: Information?

    private enum Information: String, Identifiable {
        case similarity, minimumCount
        var id: String { rawValue }
        var title: String { self == .similarity ? "相似度" : "每组最少张数" }
        var message: String {
            switch self {
            case .similarity:
                return "范围0.50—0.99，默认0.95；保留你已保存的设置。越高越严格，但不保证照片可以互相替代。调整后会重新分组并清除原选择，不自动保留任何一张照片。"
            case .minimumCount:
                return "只筛选显示，不重新计算分组，也不清空已选照片。上限是当前最大组的实际张数。隐藏的选择仍计入总数和删除确认。"
            }
        }
    }

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
                Text("清理设置")
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
                    HStack {
                        Text("相似度").font(.subheadline)
                        Spacer()
                        infoButton(.similarity)
                    }
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
                    HStack {
                        Text("每组至少\(state.minimumGroupCount)张").font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        infoButton(.minimumCount)
                    }
                    SimilarCleanupMinimumCountSlider(value: state.minimumGroupCount,
                        maximum: max(2, state.largestGroupCount), changed: state.setMinimumGroupCount)
                        .frame(height: 44)
                        .cleanupControlFrame(.minimumCountSlider)
                    Text(state.groups.isEmpty ? "暂无可筛选分组" : "\(state.minimumGroupCount)张 · 当前最大组\(state.largestGroupCount)张")
                        .font(.system(size: 11)).monospacedDigit()
                        .accessibilityIdentifier("similar-cleanup-minimum-count-value")
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
        .alert(information?.title ?? "清理设置", isPresented: Binding(
            get: { information != nil }, set: { if !$0 { information = nil } }
        ), presenting: information) { _ in
            Button("知道了", role: .cancel) { information = nil }
        } message: { info in Text(info.message) }
        .onChange(of: information?.id) { _, id in onPresentedSurfaceChanged(id != nil) }
        .onDisappear { onPresentedSurfaceChanged(false) }
    }

    private func infoButton(_ info: Information) -> some View {
        SimilarCleanupInfoButton(label: "\(info.title)说明", identifier: "similar-cleanup-info-\(info.rawValue)",
                                 action: { information = info })
            .frame(width: 44, height: 44)
    }
}

@MainActor
private struct SimilarCleanupInfoButton: UIViewRepresentable {
    let label: String
    let identifier: String
    let action: () -> Void
    final class Coordinator {
        var action: () -> Void = {}
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "info.circle"), for: .normal)
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.action() }, for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.tintColor = UIColor(IQStyle.secondary)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
    }
}

/// Native slider supports the real degenerate range 2...2 without inventing a
/// larger bound. Integer edits have no grouping-service side effects.
@MainActor
private struct SimilarCleanupMinimumCountSlider: UIViewRepresentable {
    let value: Int
    let maximum: Int
    let changed: (Int) -> Void

    func makeUIView(context: Context) -> UISlider {
        let slider = SimilarCleanupIntegerSlider()
        slider.accessibilityIdentifier = "similar-cleanup-minimum-count"
        slider.accessibilityLabel = "每组最少张数，仅筛选显示"
        slider.addAction(UIAction { [weak slider] _ in
            guard let slider else { return }
            let count = Int(slider.value.rounded())
            slider.value = Float(count)
            changed(count)
        }, for: .valueChanged)
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        slider.minimumValue = 2
        slider.maximumValue = Float(maximum)
        slider.value = Float(value)
        slider.isEnabled = maximum > 2
        slider.tintColor = UIColor(IQStyle.accent)
        slider.accessibilityValue = "\(value)张"
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 44)
    }
}

@MainActor
private final class SimilarCleanupIntegerSlider: UISlider {
    // UISlider's native alignment rectangle can inset a 31pt drawing surface
    // inside SwiftUI's outer frame. Own the full promised touch rectangle rather
    // than relying on passive padding (which routed to the scroll view on iOS).
    override var intrinsicContentSize: CGSize {
        CGSize(width: super.intrinsicContentSize.width, height: 44)
    }
    override var alignmentRectInsets: UIEdgeInsets { .zero }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.contains(point)
    }
    override func accessibilityIncrement() { adjust(by: 1) }
    override func accessibilityDecrement() { adjust(by: -1) }
    private func adjust(by amount: Float) {
        guard isEnabled else { return }
        value = min(maximumValue, max(minimumValue, value.rounded() + amount))
        sendActions(for: .valueChanged)
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
        button.accessibilityLabel = expanded ? "收起清理设置" : "展开清理设置"
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
    var protectedDataAvailable = true
    var foreground = true
    var displayCanRead = true

    var defersAutomaticRefresh: Bool {
        switch syncPhase {
        case .checking, .updating, .cancelling: return true
        default: return false
        }
    }
}