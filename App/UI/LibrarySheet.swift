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
        .onChange(of: state.debugToolsEnabled) { _, enabled in
            if !enabled {
                detailsExpanded = false
                placesExpanded = false
            }
        }
        .sheet(isPresented: $showLimitedPicker, onDismiss: {
            // The completion only dismisses. Refresh once here, including swipe dismissal.
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
                    Text(state.activity == .indexing ? "正在准备图库" : "准备图库")
                        .font(.title2.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                if state.activity == .refreshing || state.activity == .clearing {
                    ProgressView(state.activity == .clearing ? "正在清除本地索引…" : "正在检查已授权照片…")
                } else if state.activity == .indexing {
                    scanProgress
                } else {
                    VStack(spacing: 6) {
                        Text("\(state.summary.indexedCount.formatted()) / \(state.summary.authorizedCount.formatted())")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(IQStyle.accent)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("可搜索 / 已授权照片")
                            .font(.subheadline.weight(.medium))
                        Text("以上为上次图库检查的结果")
                            .font(.caption)
                            .foregroundStyle(IQStyle.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("上次图库检查：已授权 \(state.summary.authorizedCount) 张，可搜索 \(state.summary.indexedCount) 张")
                }
            }

            if state.activity != .indexing {
                Text(coverageDescription)
                    .font(.subheadline)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if modelProblem != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Label("搜索暂不可用", systemImage: "exclamationmark.circle")
                        .font(.headline)
                        .foregroundStyle(IQStyle.warning)
                    Text("暂时无法准备图库或搜索，仍可管理照片权限。原照片未改变。")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("重新检查", systemImage: "arrow.clockwise") { state.refresh() }
                    .disabled(state.isBusy)
                    .frame(minHeight: 44)
            }

            if state.activity == .indexing {
                Button("暂停准备", systemImage: "pause.fill") { state.cancel() }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("stop-indexing")
                    .accessibilityHint("停止本次准备，保留已完成的记录")
            } else {
                Button { state.index() } label: {
                    Label(state.summary.indexedCount > 0 || state.progress.completed > 0 ? "继续准备" : "开始准备", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(IQStyle.onAccent)
                .disabled(!state.canRead || !state.canIndex)
                .accessibilityIdentifier("index-photos")
            }

            if state.canRead && state.activity != .indexing && state.progress.total > 0 {
                scanProgress
            }
        } header: {
            Text("搜索覆盖")
        } footer: {
            Text("准备时请保持应用在前台；已完成的记录会保留。")
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(state.activity == .indexing ? "本次准备" : "上次准备", systemImage: "photo.stack")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(IQStyle.accent)
            if state.activity == .indexing {
                if state.progress.total > 0 {
                    ProgressView(value: state.progress.fraction)
                        .accessibilityLabel("已检查照片")
                        .accessibilityValue("\(state.progress.completed) 张，共 \(state.progress.total) 张")
                } else {
                    ProgressView("正在准备照片…")
                }
            }
            if state.progress.total > 0 {
                Text("已检查 \(state.progress.completed.formatted()) / \(state.progress.total.formatted()) 张")
                    .font(.subheadline.weight(.medium))
            }
            LabeledContent("可搜索", value: "\((state.progress.encoded + state.progress.reused).formatted()) 张")
            if state.progress.cloudSkipped > 0 {
                LabeledContent("本地预览不可用", value: "\(state.progress.cloudSkipped.formatted()) 张")
                Text("这些照片本次尚未准备好；允许 iCloud 后可重试，不保证能够下载。")
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
                  ? "以上仅为本次准备的数量，检查过不等于可搜索；图库总数在结束后更新。"
                  : "以上仅为上次准备的数量，包含停止前完成的记录，不是整个图库的总数。")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            if state.activity != .indexing {
                Button("刷新搜索覆盖", systemImage: "arrow.clockwise") { state.refresh() }
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
                Text(state.activity == .indexing ? "地点 · 本次准备" : "地点 · 上次准备")
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
                         ? "刷新图库后重试，原照片未改变。"
                         : "请先检查上方照片权限，再刷新图库。")
                        .font(.subheadline)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Button("刷新图库", systemImage: "arrow.clockwise") { state.refresh() }
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
            Text("优先使用手机已有的预览。关闭时，准备图库不会下载图像；开启后，仅在本地预览不可用时，允许系统照片通过无线网络或移动数据下载。下载量由系统决定，应用不请求原图。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var detailsSection: some View {
        Section {
            DisclosureGroup("详细信息", isExpanded: $detailsExpanded) {
                diagnostic("状态", state.status)
                LabeledContent("已授权照片", value: state.summary.authorizedCount.formatted())
                LabeledContent("上次检查时的有效索引", value: state.summary.indexedCount.formatted())
                LabeledContent("上次检查时已保存的地点标签", value: state.summary.locatedCount.formatted())
                Text("这是已建索引照片中保存的标签数，不是带定位照片数，也不是上次准备时的观察数。")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                if state.progress.total > 0 {
                    diagnostic(state.activity == .indexing ? "本次准备" : "上次准备", "\(state.progress.completed)/\(state.progress.total) 张已检查 · \(state.progress.encoded) 张新编码 · \(state.progress.reused) 张复用 · \(state.progress.cloudSkipped) 张本地预览不可用 · \(state.progress.failed) 张读取失败 · \(state.progress.localPreviews) 次本地预览 · \(state.progress.reducedPreviews) 次低清预览 · \(state.progress.networkPreviews) 次联网回退预览")
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
                Text("未变化的已完成记录会复用。来源数量只统计本轮新编码的照片；联网回退次数不代表下载次数或字节数。低清预览可能影响匹配，并会持续复用，直到照片或索引版本改变。")
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

    private var accessDescription: String {
        switch state.authorization {
        case .authorized:
            return state.activity == .refreshing
                ? "正在更新已授权照片数量…"
                : "图库中有 \(state.summary.authorizedCount.formatted()) 张已授权照片。"
        case .limited:
            return state.activity == .refreshing
                ? "正在更新已选照片数量…"
                : "已授权 \(state.summary.authorizedCount.formatted()) 张，仅能访问你选中的照片。"
        case .denied: return "请在系统设置中允许访问所选照片或全部照片。"
        case .restricted: return "此设备的限制不允许访问照片，请检查系统设置。"
        default: return "可选择部分照片或整个图库，原照片仍保留在系统照片中。"
        }
    }

    private var coverageDescription: String {
        if !state.canRead { return "请先选择照片，授权后才能准备图库与搜索。" }
        if state.activity == .refreshing || state.activity == .clearing { return "正在更新搜索覆盖…" }
        if !state.modelsReady { return "暂时无法准备图库或搜索。" }
        if state.summary.authorizedCount == 0 { return "当前照片权限下没有可用照片。" }
        if state.summary.indexedCount < state.summary.authorizedCount {
            return "尚有照片未准备好，暂不能搜索。开始或继续准备可尝试处理这些照片。"
        }
        return "上次检查时，已授权照片均可搜索。"
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