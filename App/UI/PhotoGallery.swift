import SwiftUI
import Combine
import Photos
import UIKit
import ImageIQCore

/// Intrinsic-height content for the parent's ScrollView; never nests a scroll
/// view or measures an unbounded scroll axis. The supplied thumbnail is not a button.
@MainActor
struct PhotoResultsGrid<Thumbnail: View>: View {
    let hits: [SearchHit]
    let compact: Bool
    let onSelect: (String) -> Void
    var selectionMode: Bool = false
    var selectedIDs: Set<String> = []
    @ViewBuilder let thumbnail: (IndexedPhoto) -> Thumbnail

    init(hits: [SearchHit], compact: Bool = true, onSelect: @escaping (String) -> Void,
         selectionMode: Bool = false, selectedIDs: Set<String> = [],
         @ViewBuilder thumbnail: @escaping (IndexedPhoto) -> Thumbnail) {
        self.hits = hits
        self.compact = compact
        self.onSelect = onSelect
        self.selectionMode = selectionMode
        self.selectedIDs = selectedIDs
        self.thumbnail = thumbnail
    }

    private var spacing: CGFloat { compact ? 3 : 6 }

    var body: some View {
        LazyVGrid(columns: columns(count: compact ? 5 : 2), spacing: spacing) {
            ForEach(Array(hits.enumerated()), id: \.element.id) { offset, hit in
                tile(hit, rank: offset + 1, aspectRatio: compact ? 1 : 4.0 / 5.0)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func columns(count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing), count: count)
    }

    private func tile(_ hit: SearchHit, rank: Int, aspectRatio: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 6 : 8, style: .continuous)
        return Button {
            onSelect(hit.photo.id)
        } label: {
            // An aspect-constrained base gives even GeometryReader thumbnails
            // a finite height. Overlays cannot enlarge the tile's layout bounds.
            shape.fill(IQStyle.muted)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    thumbnail(hit.photo)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(IQStyle.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if selectionMode {
                        Image(systemName: selectedIDs.contains(hit.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(selectedIDs.contains(hit.id) ? IQStyle.accent : .white)
                            .background(.black.opacity(0.6), in: Circle())
                            .frame(width: 44, height: 44)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selectionMode ? "选择第\(rank)张照片" : "查看第\(rank)张照片")
        .accessibilityValue(selectionMode ? (selectedIDs.contains(hit.id) ? "已选择" : "未选择") : "")
        .accessibilityIdentifier("result-tile-\(rank)")
    }
}

/// Present from the parent's selection-driven fullScreenCover. The input order
/// is the search order; no sorting, score transformation or synthetic hits.
@MainActor
struct PhotoResultsViewer: View {
    let hits: [SearchHit]
    let initialID: String
    let library: PhotoLibraryClient
    let networkAllowed: Bool
    let state: AppState?

    init(hits: [SearchHit], initialID: String, library: PhotoLibraryClient,
         networkAllowed: Bool, state: AppState? = nil) {
        self.hits = hits
        self.initialID = initialID
        self.library = library
        self.networkAllowed = networkAllowed
        self.state = state
    }

    var body: some View {
        PhotoGalleryViewer(ids: hits.map(\.id), initialID: initialID,
                           library: library, networkAllowed: networkAllowed, state: state)
    }
}

/// Also backs the single-photo compatibility wrapper without manufacturing an
/// IndexedPhoto. Only the selected page owns the progressive display requests.
@MainActor
struct PhotoGalleryViewer: View {
    let ids: [String]
    let library: PhotoLibraryClient
    let networkAllowed: Bool
    let state: AppState?
    @StateObject private var hd: PhotoViewerHDState

    private struct Request: Hashable {
        let id: String
        let networkAllowed: Bool
        let attempt: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id.utf8.elementsEqual(rhs.id.utf8) && lhs.networkAllowed == rhs.networkAllowed && lhs.attempt == rhs.attempt
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(Array(id.utf8)); hasher.combine(networkAllowed); hasher.combine(attempt)
        }
    }

    private struct PhotoCheckSelection: Identifiable {
        let id: String
        let initialQuery: String
    }

    private struct PreviewComparisonSelection: Identifiable {
        let id: String
        let state: LocalPreviewComparisonState
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedID: String
    @State private var attempt = 0
    @State private var shareItem: PhotoViewerShareRendition?
    @State private var debugToolsEnabled = false
    @State private var photoCheckSelection: PhotoCheckSelection?
    @State private var previewComparisonSelection: PreviewComparisonSelection?

    init(ids: [String], initialID: String, library: PhotoLibraryClient,
         networkAllowed: Bool, state: AppState? = nil, imageSource: PhotoViewerImageSource? = nil) {
        self.ids = ids
        self.library = library
        self.networkAllowed = networkAllowed
        self.state = state
        _hd = StateObject(wrappedValue: PhotoViewerHDState(source: imageSource ?? PhotoViewerImageSource(library: library)))
        _selectedID = State(initialValue: ids.contains(initialID) ? initialID : (ids.first ?? ""))
    }

    private var request: Request {
        Request(id: selectedID, networkAllowed: networkAllowed, attempt: attempt)
    }

    // Interactive dismissal must unregister the actual comparison before the
    // sheet binding releases it, just like paging or turning debug tools off.
    private var previewComparisonBinding: Binding<PreviewComparisonSelection?> {
        Binding(get: { previewComparisonSelection }, set: { selection in
            if let previous = previewComparisonSelection, previous.state !== selection?.state {
                state?.unregisterDebugPreview(previous.state)
            }
            previewComparisonSelection = selection
        })
    }

    // A page change invalidates sharing immediately, even before the new task
    // starts or the previous PhotoKit callback observes its cancellation.
    private var hasCurrentDisplaySelection: Bool {
        ids.contains(where: { $0.utf8.elementsEqual(selectedID.utf8) })
            && hd.selectedID.utf8.elementsEqual(selectedID.utf8)
    }

    private var currentImage: UIImage? {
        guard hasCurrentDisplaySelection else { return nil }
        return hd.photo?.result.image
    }

    var body: some View {
        ZStack {
            IQStyle.viewerBackground
            if ids.isEmpty {
                ContentUnavailableView("暂无可预览的照片", systemImage: "photo.on.rectangle",
                                       description: Text("请关闭预览后尝试其他搜索。"))
            } else {
                TabView(selection: $selectedID) {
                    ForEach(ids, id: \.self) { id in
                        page(id: id)
                            .tag(id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(IQStyle.viewerBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(IQStyle.accent)
        .statusBarHidden()
        .task(id: request) { startLoad(request) }
        .onReceive(state?.$debugToolsEnabled.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()) { enabled in
            // A rebuilt subscription can replay the same value. Do not clear
            // AppState's published diagnostics again on a replay of user mode.
            guard enabled != debugToolsEnabled else { return }
            debugToolsEnabled = enabled
            if !enabled { clearPhotoCheck() }
        }
        .onChange(of: selectedID) { _, _ in
            if !hd.selectedID.utf8.elementsEqual(selectedID.utf8) { hd.stop() }
            shareItem = nil
            clearPhotoCheck()
        }
        .onChange(of: ids) { _, updated in
            if !updated.contains(selectedID) {
                selectedID = updated.first ?? ""
                shareItem = nil
                clearPhotoCheck()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recheckAccess()
                if hd.photo == nil, hd.issue == nil, !hd.isWorking { attempt += 1 }
            } else {
                clearPhotoCheck()
                if phase == .background { cancelDisplay() }
            }
        }
        .onReceive(state?.$photoLibraryEpoch.eraseToAnyPublisher() ?? Empty<UUID, Never>().eraseToAnyPublisher()) { _ in
            recheckAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryClient.viewerDidChangeNotification, object: library)
            .receive(on: RunLoop.main)) { _ in recheckAccess() }
        .onChange(of: hd.phase) { _, phase in
            if phase == .access { shareItem = nil; clearPhotoCheck() }
        }
        .onDisappear { cancelDisplay(clearShare: false); clearPhotoCheck() }
        .confirmationDialog("加载高清", isPresented: Binding(
            get: { hd.consent != nil },
            set: { if !$0 { hd.dismissCloudConfirmation() } }),
            titleVisibility: .visible, presenting: hd.consent) { approval in
                Button("加载这一张") {
                    guard scenePhase == .active, hasCurrentDisplaySelection,
                          approval.asset.snapshot.revision.id.utf8.elementsEqual(selectedID.utf8) else {
                        hd.dismissCloudConfirmation()
                        return
                    }
                    hd.confirmCloud(approval)
                }
                Button("取消", role: .cancel) { hd.dismissCloudConfirmation() }
        } message: { _ in
            Text("允许从 iCloud 下载这一张照片的高清版本，仅用于本次查看请求。不会更改全局 iCloud 或索引设置；可能使用移动数据。")
        }
        .sheet(item: $shareItem) { item in
            // The sheet uses an immutable snapshot, never whichever UIImage
            // happens to finish loading after the Share button was pressed.
            if scenePhase != .background,
               item.snapshot.revision.id.utf8.elementsEqual(selectedID.utf8), hd.isCurrent(item.snapshot) {
                PhotoShareSheet(image: item.image)
            } else {
                ContentUnavailableView("照片访问权限已更改", systemImage: "lock",
                                       description: Text("请关闭分享并检查照片访问权限。"))
            }
        }
        .sheet(item: $photoCheckSelection, onDismiss: { state?.dismissPhotoCheck() }) { selection in
            if debugToolsEnabled, let state, state.debugToolsEnabled {
                PhotoCheckSheet(state: state, photoID: selection.id, initialQuery: selection.initialQuery)
            }
        }
        .sheet(item: previewComparisonBinding) { selection in
            if debugToolsEnabled, state?.debugToolsEnabled == true {
                LocalPreviewComparisonSheet(state: selection.state)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { cancelDisplay(); clearPhotoCheck(); dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IQStyle.text)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭照片预览")
            .accessibilityIdentifier("close-photo-preview")
            Spacer()
            let position = ids.firstIndex(of: selectedID).map { $0 + 1 } ?? 0
            Text("\(position) / \(ids.count)")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(IQStyle.text)
                .accessibilityLabel("第\(position)张照片，共\(ids.count)张")
                .accessibilityIdentifier("photo-preview-counter")
            Spacer()
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(IQStyle.viewerBackground.opacity(0.8))
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            hdControls
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    shareButton
                    if let state {
                        Button {
                            let id = selectedID
                            cancelDisplay()
                            dismiss()
                            state.searchSimilar(to: id)
                        } label: {
                            Label("找相似", systemImage: "rectangle.on.rectangle")
                                .frame(minHeight: 44)
                        }
                        .disabled(state.isBusy || !ids.contains(selectedID))
                        .accessibilityIdentifier("find-similar-photos")
                    }
                    if debugToolsEnabled { checkButton }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 8) {
                    shareButton
                    if let state {
                        Button("找相似", systemImage: "rectangle.on.rectangle") {
                            let id = selectedID
                            cancelDisplay()
                            dismiss()
                            state.searchSimilar(to: id)
                        }
                        .frame(minHeight: 44)
                        .disabled(state.isBusy || !ids.contains(selectedID))
                    }
                    if debugToolsEnabled { checkButton }
                }
            }
            if debugToolsEnabled, state?.debugToolsEnabled == true {
                Button(action: openPreviewComparison) {
                    Label("本地预览对比", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IQStyle.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(!hasCheckableSelection)
                .accessibilityIdentifier("compare-local-previews")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(IQStyle.viewerBackground.opacity(0.8))
    }

    private var shareButton: some View {
        Button(action: shareCurrentPhoto) {
            Label(hd.shareQuality.rawValue, systemImage: "square.and.arrow.up")
                .font(.body.weight(.semibold))
                .foregroundStyle(IQStyle.accent)
                .padding(.horizontal, 28)
                .frame(minHeight: 48)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(currentImage == nil)
        .opacity(currentImage == nil ? 0.4 : 1)
        .accessibilityHint("分享当前显示版本，不是原图，不包含位置元数据")
        .accessibilityIdentifier("share-photo-preview")
    }

    private var hdControls: some View {
        PhotoViewerHDControls(phase: hd.phase, canRequestCloud: hd.canRequestCloud,
            isCurrentSelection: hasCurrentDisplaySelection, onCancel: { hd.cancelUpgrade() }, onRequest: {
                guard scenePhase == .active, hasCurrentDisplaySelection else { return }
                hd.requestCloudConfirmation()
            })
    }

    private var checkButton: some View {
        Group {
            if let state, state.debugToolsEnabled {
                PhotoCheckPreviewButton(state: state, hasSelection: hasCheckableSelection, action: openPhotoCheck)
                    .buttonStyle(.plain)
                    .accessibilityHint("将已保存的索引与新获取的本地预览进行比较，不修改索引")
                    .accessibilityIdentifier("check-photo-preview")
            }
        }
    }

    private var hasCheckableSelection: Bool {
        guard !selectedID.isEmpty, ids.contains(selectedID) else { return false }
        if hd.phase == .access { return false }
        return true
    }

    private func openPhotoCheck() {
        guard let state, state.debugToolsEnabled, state.canRead, hasCheckableSelection else { return }
        guard library.currentRevision(id: selectedID) != nil else {
            recheckAccess()
            return
        }
        state.dismissPhotoCheck()
        guard state.debugToolsEnabled else { return }
        // Independent of the display-image task, so this action works while
        // that image is loading. The sheet never follows subsequent paging.
        // Reproduce the text actually used for these results; never translate it
        // a second time or pass Chinese while the visible ranking used English.
        photoCheckSelection = PhotoCheckSelection(id: selectedID, initialQuery: state.photoCheckInitialQuery)
    }

    private func openPreviewComparison() {
        guard let state, state.debugToolsEnabled, hasCheckableSelection else { return }
        guard library.currentRevision(id: selectedID) != nil else { return }
        clearPhotoCheck()
        guard state.debugToolsEnabled else { return }
        let preview = LocalPreviewComparisonState(service: library, photoID: selectedID)
        guard state.registerDebugPreview(preview) else { return }
        previewComparisonSelection = PreviewComparisonSelection(id: selectedID, state: preview)
    }

    private func clearPhotoCheck() {
        if let selection = previewComparisonSelection {
            state?.unregisterDebugPreview(selection.state)
        }
        previewComparisonSelection = nil
        photoCheckSelection = nil
        state?.dismissPhotoCheck()
    }

    private func page(id: String) -> some View {
        GeometryReader { geometry in
            ZStack {
                IQStyle.viewerBackground
                if id == selectedID, let image = currentImage {
                    // Identity is the page attempt, NOT the rendition. Upgrading
                    // the UIImage must not recreate the zoom state.
                    PhotoFitZoomView(image: image) { zoom in
                        guard id == selectedID, hd.selectedID.utf8.elementsEqual(id.utf8) else { return }
                        hd.updateDemand(viewport: geometry.size, displayScale: displayScale, zoom: zoom)
                    }
                    .id(request)
                } else if id == selectedID, let issue = hd.issue {
                    failureView(issue)
                } else {
                    VStack(spacing: 12) {
                        ProgressView().tint(IQStyle.accent)
                        Text("正在加载照片…").font(.subheadline).foregroundStyle(IQStyle.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .task(id: ViewerViewport(width: geometry.size.width, height: geometry.size.height,
                                    scale: displayScale, selected: id == selectedID,
                                    ownerID: Array(hd.selectedID.utf8))) {
                if id == selectedID, hd.selectedID.utf8.elementsEqual(id.utf8) {
                    hd.updateViewport(geometry.size, displayScale: displayScale)
                }
            }
        }
        .clipped()
    }

    @Environment(\.displayScale) private var displayScale
    private struct ViewerViewport: Hashable {
        let width: CGFloat
        let height: CGFloat
        let scale: CGFloat
        let selected: Bool
        let ownerID: [UInt8]
    }

    private func failureView(_ issue: PhotoPreviewIssue) -> some View {
        // This scroll view contains only error copy, so accessibility text sizes
        // and landscape do not push the retry action offscreen.
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: issue.symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(IQStyle.accent)
                    .accessibilityHidden(true)
                Text(issue.localizedTitle).font(.title3.weight(.semibold)).foregroundStyle(IQStyle.text)
                Text(hd.phase == .access ? issue.localizedMessage(networkAllowed: false) :
                     "暂时无法获取本地预览。可重试本地读取，或使用下方“加载高清”仅下载这一张。")
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    attempt += 1
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 20)
                        .frame(minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(IQStyle.accent)
                .foregroundStyle(IQStyle.onAccent)
                .accessibilityIdentifier("retry-photo-preview")
            }
            .multilineTextAlignment(.center)
            .padding(28)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }

    private func startLoad(_ requested: Request) {
        guard !Task.isCancelled, request == requested else { return }
        shareItem = nil
        hd.open(id: ids.contains(requested.id) ? requested.id : "")
    }

    private func cancelDisplay(clearShare: Bool = true) {
        hd.stop()
        // A presented activity sheet can cover this view. Its immutable image
        // remains owned by that sheet; only an explicit close/page clears it.
        if clearShare { shareItem = nil }
    }

    private func recheckAccess() {
        if let item = shareItem, !hd.isCurrent(item.snapshot) { shareItem = nil }
        guard !hd.recheckAccess() else { return }
        shareItem = nil
        clearPhotoCheck()
    }

    private func shareCurrentPhoto() {
        guard scenePhase == .active, currentImage != nil else { return }
        shareItem = hd.makeShareRendition()
    }
}

/// Reserve the natural size of every HD status, even with sufficient pixels.
/// Only the overlay is conditional: eligibility must never resize the photo's
/// GeometryReader and feed a different coverage target back into eligibility.
@MainActor
struct PhotoViewerHDControls: View {
    let phase: PhotoViewerHDState.Phase
    let canRequestCloud: Bool
    let isCurrentSelection: Bool
    let onCancel: () -> Void
    let onRequest: () -> Void

    private enum Status: CaseIterable, Hashable {
        case local, cloud, cancelling, request, failed, cancelled

        var isWorking: Bool { self == .local || self == .cloud || self == .cancelling }
        var message: String? {
            switch self {
            case .local: return "正在读取本地高清…"
            case .cloud: return "正在加载这一张高清…"
            case .cancelling: return "正在取消…"
            case .request: return nil
            case .failed: return "未能加载高清，当前显示版本不变"
            case .cancelled: return "已取消，当前显示版本不变"
            }
        }
    }

    private var status: Status? {
        guard isCurrentSelection else { return nil }
        switch phase {
        case .local: return .local
        case .cloud: return .cloud
        case .cancelling: return .cancelling
        default:
            guard canRequestCloud else { return nil }
            return phase == .failed ? .failed : (phase == .cancelled ? .cancelled : .request)
        }
    }

    var body: some View {
        ZStack {
            ForEach(Status.allCases, id: \.self) { status in
                row(status) {
                    // Inert labels reserve button dimensions, not hidden live
                    // actions. Dynamic Type and available width still apply.
                    Text(status.isWorking ? "取消" : "加载高清")
                        .frame(minWidth: status.isWorking ? 44 : nil, minHeight: 44)
                }
                .hidden()
                .accessibilityHidden(true)
            }
        }
        .overlay {
            if let status {
                row(status) {
                    if status.isWorking {
                        Button("取消", action: onCancel)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(status == .cancelling)
                            .accessibilityIdentifier("cancel-photo-hd")
                    } else {
                        Button("加载高清", action: onRequest)
                            .frame(minHeight: 44)
                            .accessibilityHint("先确认，再仅为这一张照片允许 iCloud 下载")
                            .accessibilityIdentifier("load-photo-hd")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row<Action: View>(_ status: Status, @ViewBuilder action: () -> Action) -> some View {
        if status.isWorking {
            HStack(spacing: 8) {
                ProgressView().tint(IQStyle.accent)
                Text(status.message ?? "").font(.footnote).foregroundStyle(IQStyle.secondary)
                action()
            }
        } else {
            VStack(spacing: 0) {
                if let message = status.message {
                    Text(message).font(.footnote).foregroundStyle(IQStyle.secondary)
                }
                action()
            }
        }
    }
}

/// Observe authorization without requiring AppState in the compatibility viewer.
@MainActor
private struct PhotoCheckPreviewButton: View {
    @ObservedObject var state: AppState
    let hasSelection: Bool
    let action: () -> Void

    var body: some View {
        Button {
            guard state.debugToolsEnabled else { return }
            action()
        } label: { PhotoCheckPreviewLabel() }
        .disabled(!state.debugToolsEnabled || !hasSelection || !state.canRead)
        .opacity(state.debugToolsEnabled && hasSelection && state.canRead ? 1 : 0.4)
    }
}

private struct PhotoCheckPreviewLabel: View {
    var body: some View {
        Label("检查这张照片", systemImage: "magnifyingglass")
            .font(.body.weight(.semibold))
            .foregroundStyle(IQStyle.accent)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background(.ultraThinMaterial, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Two-finger zoom only: no horizontal drag recognizer competes with TabView.
/// Swiping always turns the page; returning to a page starts at full-image fit.
@MainActor
struct PhotoFitZoomView: View {
    let image: UIImage
    let onZoom: (CGFloat) -> Void
    @StateObject private var zoomState: PhotoViewerZoomState
    @GestureState private var pinchScale: CGFloat = 1

    init(image: UIImage, zoomState: PhotoViewerZoomState? = nil, onZoom: @escaping (CGFloat) -> Void = { _ in }) {
        self.image = image
        self.onZoom = onZoom
        _zoomState = StateObject(wrappedValue: zoomState ?? PhotoViewerZoomState())
    }

    private func bounded(_ scale: CGFloat) -> CGFloat { scale.isFinite ? max(scale, 1) : zoomState.scale }

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(bounded(zoomState.scale * pinchScale))
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .clipped()
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($pinchScale) { value, scale, _ in scale = value.magnification }
                        .onEnded { value in
                            zoomState.magnify(by: value.magnification)
                            onZoom(zoomState.scale)
                        }
                )
                .onTapGesture(count: 2) { zoomState.reset(); onZoom(1) }
                .onChange(of: geometry.size) { _, _ in onZoom(zoomState.scale) }
                .accessibilityLabel("当前照片")
                .accessibilityHint("双指捏合缩放，轻点两下还原缩放，左右轻扫切换照片。")
                .accessibilityAction(named: Text("还原缩放")) { zoomState.reset(); onZoom(1) }
                .accessibilityIdentifier("photo-preview-image")
        }
        .clipped()
    }
}