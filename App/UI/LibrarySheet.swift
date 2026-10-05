import SwiftUI
import Photos
import UIKit

@MainActor
struct LibrarySheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var showLimitedPicker = false
    @State private var detailsExpanded = false
    @State private var placesExpanded = false
    @State private var confirmRebuild = false

    var body: some View {
        NavigationStack {
            Form {
                if state.canRead {
                    coverageSection
                    accessSection
                } else {
                    accessSection
                    coverageSection
                }
                errorSection
                cloudSection
                if state.textSearchEnabled { PhotoTextIndexSection(state: state) }
                if state.debugToolsEnabled {
                    detailsSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .tint(IQStyle.accent)
            .navigationTitle("我的图库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("close-library")
                }
            }
        }
        .tint(IQStyle.accent)
        .confirmationDialog("全部重建索引？", isPresented: $confirmRebuild, titleVisibility: .visible) {
            Button("全部重建索引", role: .destructive) {
                guard state.canIndex else { return }
                state.rebuildIndex()
            }
            .disabled(!state.canIndex)
            .accessibilityIdentifier("confirm-rebuild-index")
            Button("取消", role: .cancel) { }
        } message: {
            Text("清除图片、地点及文字索引，再重新建立图片索引；文字索引需另行手动更新。不会修改或删除原照片，重建期间未完成索引的照片不可搜索。")
        }
        .onChange(of: state.debugToolsEnabled) { _, enabled in
            if !enabled {
                detailsExpanded = false
                placesExpanded = false
            }
        }
        .sheet(isPresented: $showLimitedPicker, onDismiss: {
            // Notify the state of a permission change, without starting an index update.
            state.libraryChanged()
        }) {
            LimitedLibraryPicker { showLimitedPicker = false }
        }
    }

    private var accessSection: some View {
        Section("照片权限") {
            VStack(alignment: .leading, spacing: 6) {
                Label(accessTitle, systemImage: state.canRead ? "checkmark.circle" : "photo.on.rectangle")
                    .font(.headline)
                    .foregroundStyle(IQStyle.accent)
                Text(accessDescription)
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

            if state.authorization == .notDetermined {
                Button("选择照片", systemImage: "photo.badge.plus") { state.authorize() }
                    .accessibilityIdentifier("authorize-photos")
                    .frame(minHeight: 44)
            } else {
                if state.authorization == .limited {
                    Button("管理已选照片", systemImage: "photo.stack") { showLimitedPicker = true }
                        .frame(minHeight: 44)
                }
                Button(state.canRead ? "前往系统设置管理权限" : "打开系统设置", systemImage: "arrow.up.right.square") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            }
        }
        .listRowBackground(IQStyle.surface)
    }

    private var coverageSection: some View {
        Section {
            if state.canRead {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(IQStyle.accent)
                        .padding(18)
                        .background(IQStyle.accentSoft, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                    Text(state.activity == .indexing ? "正在更新索引" : "照片索引")
                        .font(.title2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                if state.activity == .refreshing || state.activity == .clearing {
                    ProgressView(state.activity == .clearing ? "正在清除本地索引…" : "正在刷新索引统计…")
                } else if state.activity == .indexing {
                    scanProgress
                } else {
                    VStack(spacing: 6) {
                        Text(storedCountText)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(IQStyle.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("本机保存的索引数量，不代表当前可搜索数量")
                            .font(.caption)
                            .foregroundStyle(IQStyle.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("stored-index-count")
                }
            }

            if state.activity != .indexing {
                Text(coverageDescription)
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.summary.indexStatisticsKnown {
                Button("刷新索引统计", systemImage: "arrow.clockwise") { state.refresh() }
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("refresh-index-statistics")
            }

            if modelProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("搜索暂不可用", systemImage: "exclamationmark.circle")
                        .font(.headline)
                        .foregroundStyle(IQStyle.warning)
                    Text("暂时无法更新索引或搜索，仍可管理照片权限。原照片未改变。")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("刷新索引统计", systemImage: "arrow.clockwise") { state.refresh() }
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }

            if state.activity == .indexing {
                Button("暂停索引", systemImage: "pause.fill") { state.cancel() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("stop-indexing")
                    .accessibilityHint("停止本次索引，保留已完成的记录")
            } else {
                Button { state.index() } label: {
                    Label(indexActionTitle, systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(IQStyle.onAccent)
                .disabled(!state.canRead || !state.canIndex)
                .accessibilityIdentifier("index-photos")
            }

            Button("全部重建索引", systemImage: "arrow.triangle.2.circlepath") { confirmRebuild = true }
                .buttonStyle(.bordered)
                .disabled(!state.canIndex)
                .frame(minHeight: 44)
                .accessibilityIdentifier("rebuild-index")
                .accessibilityHint("需要再次确认；只重建本地索引，不改变原照片")

            if state.canRead && state.activity != .indexing && state.progress.total > 0 {
                scanProgress
            }
        } header: {
            Text("索引管理")
        } footer: {
            Text(Self.manualIndexExplanation)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.activity == .indexing ? "本次手动索引" : "上次手动索引", systemImage: "photo.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IQStyle.accent)
            if state.activity == .indexing {
                if state.progress.total > 0 {
                    ProgressView(value: state.progress.fraction)
                        .accessibilityLabel("已检查照片")
                        .accessibilityValue("\(state.progress.completed) 张，共 \(state.progress.total) 张")
                } else {
                    ProgressView("正在扫描照片以更新索引…")
                }
            }
            if state.progress.total > 0 {
                Text("已检查 \(state.progress.completed.formatted()) 张 · 扫描范围 \(state.progress.total.formatted()) 张")
                    .font(.subheadline.weight(.medium))
            }
            LabeledContent("已完成索引", value: "\((state.progress.encoded + state.progress.reused).formatted()) 张")
            if state.progress.cloudSkipped > 0 {
                LabeledContent("本地预览不可用", value: "\(state.progress.cloudSkipped.formatted()) 张")
                Text("这些照片本次尚未完成索引；允许 iCloud 后可手动更新索引重试，不保证能够下载。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
            if state.progress.failed > 0 {
                LabeledContent("读取失败", value: "\(state.progress.failed.formatted()) 张")
            }
            if state.debugToolsEnabled {
                placeProgress
            }
            Text(state.activity == .indexing
                ? "以上仅为本次手动索引的扫描进度，检查过不等于已完成索引。"
                : "以上仅为上次手动索引的扫描记录，包含停止前完成的部分，不是当前图库总数或可搜索数量。")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            if state.activity != .indexing {
                Button("刷新索引统计", systemImage: "arrow.clockwise") { state.refresh() }
                    .buttonStyle(.bordered)
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private var placeProgress: some View {
        DisclosureGroup(isExpanded: $placesExpanded) {
            if state.progress.placeChecked > 0 {
                LabeledContent("已检查位置", value: state.progress.placeChecked.formatted())
                LabeledContent("带定位信息", value: state.progress.gpsCount.formatted())
                LabeledContent("已找到地点标签", value: state.progress.placeResolved.formatted())
                LabeledContent("无定位信息", value: state.progress.noGPS.formatted())
                LabeledContent("无可用地点包", value: state.progress.noPlacePack.formatted())
                LabeledContent("超出地点包覆盖", value: state.progress.outsidePlaceCoverage.formatted())
                LabeledContent("位置信息不可用", value: state.progress.placeUnavailable.formatted())
                LabeledContent("已保存的地点更新", value: state.progress.placeUpdated.formatted())
                Text("位置检查包含未能建立图像索引的照片。「不可用」指位置无法读取或使用，不代表没有定位信息。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
                Text("保存的地点更新包括添加、修改、移除标签或刷新覆盖信息。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            } else {
                Text("检查照片位置前，定位与地点标签数量未知。已保存的标签数量单独列在「详细信息」中。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.activity == .indexing ? "地点 · 本次索引" : "地点 · 上次索引")
                    .font(.subheadline.weight(.medium))
                Text(state.progress.placeChecked > 0
                     ? "\(state.progress.gpsCount.formatted()) 张带定位 · 找到 \(state.progress.placeResolved.formatted()) 个标签"
                     : "尚未检查照片位置")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
        }
        .accessibilityIdentifier("debug-scan-places")
    }

    @ViewBuilder private var errorSection: some View {
        if state.errorMessage != nil && modelProblem == nil {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("操作未完成", systemImage: "exclamationmark.circle")
                        .font(.headline)
                        .foregroundStyle(IQStyle.warning)
                    Text(state.canRead
                        ? "可刷新索引统计后手动重试，原照片未改变。"
                        : "请先检查上方照片权限，再刷新索引统计。")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("刷新索引统计", systemImage: "arrow.clockwise") { state.refresh() }
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }
            .listRowBackground(IQStyle.surface)
        }
    }

    private var cloudSection: some View {
        Section {
            Toggle("需要时使用 iCloud", isOn: $state.allowICloudDownload)
                .disabled(state.isBusy)
                .accessibilityIdentifier("icloud-download-opt-in")
        } header: {
            Text("iCloud")
        } footer: {
            Text("优先使用手机已有的预览。关闭时，建立或更新索引不会下载图像；开启后，仅在本地预览不可用时，允许系统照片通过无线网络或移动数据下载。下载量由系统决定，应用不请求原图。开关不会自动更新索引。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("详细信息", isExpanded: $detailsExpanded) {
                diagnostic("状态", state.status)
                LabeledContent("上次操作核对时已授权", value: authorizedCountSnapshotText)
                LabeledContent("本机已保存的索引", value: state.summary.indexStatisticsKnown ? state.summary.indexedCount.formatted() : "待刷新")
                LabeledContent("本机已保存的地点标签", value: state.summary.indexStatisticsKnown ? state.summary.locatedCount.formatted() : "待刷新")
                Text("授权数量仅为上次索引或搜索操作核对的快照，不代表当前权限范围；未扫描时不估算数量。标签数是索引中保存的标签数，不是带定位照片数，也不是上次索引时的观察数。")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                if state.progress.total > 0 {
                    diagnostic(state.activity == .indexing ? "本次手动索引" : "上次手动索引", "\(state.progress.completed) 张已检查 · 扫描共 \(state.progress.total) 张 · \(state.progress.encoded) 张新编码 · \(state.progress.reused) 张复用 · \(state.progress.cloudSkipped) 张本地预览不可用 · \(state.progress.failed) 张读取失败 · \(state.progress.localPreviews) 次本地预览 · \(state.progress.reducedPreviews) 次低清预览 · \(state.progress.networkPreviews) 次联网回退预览")
                }
                if let failure = state.progress.lastFailure {
                    diagnostic("最近跳过照片的问题", failure)
                }
                if let issue = modelProblem { diagnostic("模型检查", issue) }
                if let error = state.errorMessage, error != modelProblem {
                    diagnostic("上次操作问题", error)
                }
                diagnostic("预览请求", "先请求短边 224 的高质量本地预览，不可用时再尝试快速本地预览，不请求原图。仅当两者均不可用且已开启 iCloud 时，系统照片才可能通过无线网络或移动数据下载，下载量由系统决定。关闭 iCloud 时，两次预览请求均离线。")
                    .accessibilityIdentifier("debug-indexing-info")
                Text("\(PhotoIndexWorker.indexingWorkerCount) 个图像任务并发读取与编码照片")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("优先高质量 224 预览，快速本地预览回退。并发越高，占用内存越多，可能导致系统关闭应用。")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("手动更新会复用未变化的已完成记录。来源数量只统计本轮新编码的照片；联网回退次数不代表下载次数或字节数。低清预览可能影响匹配；全部重建会重新请求预览，但不保证更高清。")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("debug-library-details")
        }
        .listRowBackground(IQStyle.surface)
    }

    private func diagnostic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(IQStyle.secondary)
            Text(IQStyle.diagnosticText(value))
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var accessTitle: String {
        switch state.authorization {
        case .authorized: return "可访问全部照片"
        case .limited: return "仅访问已选照片"
        case .denied: return "照片访问已关闭"
        case .restricted: return "照片访问受限"
        default: return "选择要搜索的照片"
        }
    }

    // Pure presentation values also exercised by model-free contract tests.
    var storedCountText: String {
        state.summary.indexStatisticsKnown ? "已索引 \(state.summary.indexedCount.formatted()) 张" : "索引统计待刷新"
    }

    var indexActionTitle: String { state.summary.indexedCount == 0 ? "建立索引" : "更新索引" }

    var authorizedCountSnapshotText: String {
        state.summary.authorizedCountKnown ? "\(state.summary.authorizedCount.formatted()) 张" : "未扫描"
    }

    static let manualIndexExplanation = "新增照片在更新索引后才能搜索；编辑过的照片在更新前仍按旧内容匹配。搜索会检查访问权限并排除已删除或不可访问的照片。更新或重建时请保持应用在前台；已完成的记录会保留。"

    var accessDescription: String {
        switch state.authorization {
        case .authorized:
            return "允许访问系统照片图库；新增或编辑照片后，请手动更新索引。"
        case .limited:
            return "仅能访问你选中的照片；调整选择后，请手动更新索引。"
        case .denied: return "请在系统设置中允许访问所选照片或全部照片。"
        case .restricted: return "此设备的限制不允许访问照片，请检查系统设置。"
        default: return "可选择部分照片或整个图库，原照片仍保留在系统照片中。"
        }
    }

    var coverageDescription: String {
        if !state.canRead { return "请先选择照片，授权后可手动建立索引与搜索。" }
        if state.activity == .clearing { return "正在清除本地索引，原照片不会改变。" }
        if state.activity == .refreshing { return "正在读取本机保存的索引统计，不扫描照片。" }
        if !state.modelsReady { return "暂时无法更新索引或搜索。" }
        if !state.summary.indexStatisticsKnown { return "清除或重建后统计待确认，请刷新本机统计；不会扫描照片。" }
        if state.summary.indexedCount == 0 { return "点「建立索引」后才能按照片内容搜索；索引由你手动更新。" }
        return "点「更新索引」处理新增或编辑过的照片，未变化的索引会复用。"
    }

    private var modelProblem: String? {
        if let issue = state.summary.modelIssue { return issue }
        // An indexing failure may arrive before a new LibrarySummary is published.
        if let error = state.errorMessage,
           error.hasPrefix("Models unavailable:") || error.hasPrefix("Model contract mismatch:") {
            return error
        }
        return nil
    }
}