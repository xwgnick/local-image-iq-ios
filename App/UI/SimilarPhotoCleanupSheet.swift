import SwiftUI
import ImageIQCore

/// The parent owns this sheet-local controller. Opening/resuming never scans.
@MainActor
struct SimilarPhotoCleanupSheet: View {
    @ObservedObject var state: SimilarPhotoCleanupState
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var hasRequestedGrouping = false
    @State private var comparisonGroup: SimilarPhotoGroup?
    @State private var confirmationIntent: SimilarPhotoDeletionIntent?
    @State private var showsConfirmation = false

    init(state: SimilarPhotoCleanupState, appState: AppState) {
        self.state = state
        self.appState = appState
    }

    private var canScan: Bool {
        scenePhase == .active && appState.canRead && appState.modelsReady
            && appState.summary.indexStatisticsKnown && appState.summary.indexedCount > 0 && !appState.isBusy
            && !state.isGrouping && !state.isDeleting
    }

    private var thresholdBinding: Binding<Double> {
        // Integer slider ticks avoid Float-to-Double roundoff at decimal steps.
        Binding(get: { (Double(state.threshold) * 100).rounded() }, set: { value in
            guard !state.isDeleting else { return }
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    controls
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
            .background(IQStyle.background.ignoresSafeArea())
            .navigationTitle("相似照片清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .disabled(state.isDeleting)
                        .accessibilityIdentifier("close-similar-cleanup")
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
                } else if state.selectedCount > 0 {
                    selectionToolbar
                }
            }
        }
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .interactiveDismissDisabled(state.isDeleting)
        .sheet(item: $comparisonGroup) { group in
            SimilarPhotoComparisonSheet(group: group, cleanup: state, appState: appState)
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
            .disabled(state.isDeleting || state.pendingDeletion?.id != intent.id)
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
            if let comparisonGroup, !ids.contains(comparisonGroup.id) {
                self.comparisonGroup = nil
            }
        }
        .onChange(of: appState.photoLibraryEpoch) { _, _ in invalidateAccess() }
        .onChange(of: appState.authorization) { _, _ in invalidateAccess() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .background:
                comparisonGroup = nil
                showsConfirmation = false
                state.pause()
            case .active:
                state.resume()
            default:
                // PhotoKit confirmation makes the scene inactive, not background.
                break
            }
        }
        .onAppear {
            if scenePhase == .active { state.resume() }
        }
        .onDisappear {
            // A compact full-screen comparison can cover this sheet. Its groups
            // must survive; the presenting owner's onDismiss handles actual dismissal.
            // Read cancellation never cancels a submitted deletion.
            if comparisonGroup == nil { state.pause() }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全组每两张均达阈值。只是建议，删除前请核对。")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("阈值\(String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(state.threshold)))（越高越严格）")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Slider(value: thresholdBinding, in: SimilarPhotoGroupingPolicy.sliderTicks, step: 1)
                    .disabled(state.isDeleting)
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
            Button(hasRequestedGrouping || state.hasScanned ? "重新分组" : "开始分组") {
                guard canScan else { return }
                hasRequestedGrouping = true
                state.scan()
            }
            .font(.body.weight(.semibold))
            .frame(minHeight: 44)
            .buttonStyle(.borderedProminent)
            .foregroundStyle(IQStyle.onAccent)
            .disabled(!canScan)
            .accessibilityIdentifier("start-similar-grouping")
            if let readinessHint {
                Text(readinessHint)
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readinessHint: String? {
        if !appState.canRead { return "请先在“我的图库”中允许照片访问。" }
        if !appState.modelsReady { return "搜索模型尚未就绪。" }
        if !appState.summary.indexStatisticsKnown { return "索引统计待确认，请先刷新本机统计。" }
        if appState.summary.indexedCount == 0 { return "请先手动更新图片索引。" }
        if appState.isBusy { return "请等待当前任务完成后开始分组。" }
        return state.hasScanned || state.isGrouping ? nil : "仅使用已有图片索引，不会自动更新。"
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
                Text("当前阈值下没有相似照片组。可调低阈值后点“重新分组”。")
                    .font(.subheadline)
                    .padding(.top, 4)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private func groupCard(_ group: SimilarPhotoGroup, number: Int) -> some View {
        let columns = horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize ? 3 : 2
        return VStack(alignment: .leading, spacing: 12) {
            actionLayout {
                VStack(alignment: .leading, spacing: 4) {
                    Text("第\(number)组 · \(group.photos.count)张").font(.headline)
                    Text("最低相似度 \(String(format: "%.3f", Double(group.minimumSimilarity)))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(IQStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("similar-cleanup-group-\(number)-header")
                Button("全选本组") { state.selectGroup(group.id) }
                    .frame(minHeight: 44)
                    .disabled(state.isGrouping || state.isDeleting)
                    .accessibilityLabel("全选第\(number)组的\(group.photos.count)张照片")
                    .accessibilityIdentifier("similar-cleanup-group-\(number)-select-group")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 8), count: columns), spacing: 8) {
                ForEach(Array(group.photos.enumerated()), id: \.element.id) { index, photo in
                    selectionTile(photo, number: index + 1, groupNumber: number)
                }
            }
            Button {
                guard !state.isDeleting, !state.isGrouping else { return }
                comparisonGroup = group
            } label: {
                Label("对比本组照片", systemImage: "rectangle.split.2x1")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(state.isDeleting || state.isGrouping || group.photos.count < 2)
            .accessibilityLabel("对比第\(number)组照片")
            .accessibilityIdentifier("similar-cleanup-group-\(number)-compare")
        }
        .padding(12)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IQStyle.line, lineWidth: 1))
    }

    private func selectionTile(_ photo: IndexedPhoto, number: Int, groupNumber: Int) -> some View {
        let selected = state.selectedIDs.contains(photo.id)
        let shape = RoundedRectangle(cornerRadius: 8)
        return Button { state.toggleSelection(photo.id) } label: {
            shape.fill(IQStyle.muted)
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay {
                    PhotoThumbnailView(photo: photo, cache: appState.thumbnails,
                                       networkAllowed: appState.allowICloudDownload)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? IQStyle.accent : IQStyle.line, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(selected ? IQStyle.accent : .white)
                        .background(.black.opacity(0.65), in: Circle())
                        .padding(8)
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(state.isGrouping || state.isDeleting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第\(groupNumber)组，照片\(number)，待删除选择")
        .accessibilityValue(selected ? "已勾选" : "未勾选")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("similar-cleanup-group-\(groupNumber)-photo-\(number)")
    }

    private var selectionToolbar: some View {
        actionLayout {
            Text("已选\(state.selectedCount)张")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("清空") { state.clearSelection() }
                .frame(minHeight: 44)
            Button("删除\(state.selectedCount)张", role: .destructive) {
                state.prepareDeletion()
                guard let intent = state.pendingDeletion else { return }
                confirmationIntent = intent
                showsConfirmation = true
            }
            .frame(minHeight: 44)
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
        let warning = "将从系统照片图库删除，可能同步到 iCloud 和其他设备。通常可在系统“最近删除”中恢复。"
        return intent.emptiedGroupCount > 0
            ? warning + "\n其中\(intent.emptiedGroupCount)组全部照片已被选中，不会保留照片。"
            : warning
    }

    private func invalidateAccess() {
        comparisonGroup = nil
        showsConfirmation = false
        state.invalidateAccess()
    }
}