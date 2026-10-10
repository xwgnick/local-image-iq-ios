import SwiftUI

/// Management only: the primary opt-in lives beside search filters, not here.
/// No work on appearance. OFF->ON and explicit maintenance request one pass.
@MainActor
struct PhotoTextIndexSection: View {
    let state: AppState

    static let triggerExplanation = "每次在主页从关闭切换为开启，会增量更新一次文字索引；忙碌时等待当前任务结束。仅恢复已保存的开启状态、打开页面或搜索不会再次扫描。也可在这里手动更新。"

    var body: some View { PhotoTextIndexContent(state: state) }
}

/// AppState does not forward its child's publications. Observe both objects so
/// queued intent, progress and an old OCR task draining behind other work remain
/// visible even when AppState.activity is not indexingText and the footer is hidden.
@MainActor
struct PhotoTextIndexContent: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var sync: OCRSyncState

    init(state: AppState) {
        self.state = state
        sync = state.ocrSync
    }

    var hasStopAction: Bool { sync.pending || sync.currentRunning }
    var canUpdate: Bool {
        !hasStopAction && (sync.phase == .idle ? state.canIndexText : sync.canRetry)
    }
    var updateTitle: String {
        sync.phase == .cancelled || sync.phase == .failed ? "重试文字索引" : "更新文字索引"
    }

    func cancelUpdate() {
        guard sync.canCancel else { return }
        state.cancelOCRSync()
    }

    func updateIndex() {
        guard canUpdate else { return }
        if sync.phase == .idle { state.indexPhotoText() }
        else { state.retryOCRSync() }
    }

    var body: some View {
        Section {
            if !state.textSearchEnabled {
                Text("文字搜索已关闭。再次开启会请求一次增量更新；已完成的文字记录保留。")
                    .font(.footnote).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasStopAction {
                VStack(alignment: .leading, spacing: 8) {
                    PhotoTextIndexStatusView(sync: sync)
                    if let fraction = sync.fraction {
                        ProgressView(value: fraction)
                            .accessibilityLabel("文字索引进度")
                            .accessibilityValue("\(sync.progress.completed) / \(sync.progress.total)")
                    }
                }
                Button("取消文字索引更新", systemImage: "xmark", action: cancelUpdate)
                    .disabled(!sync.canCancel)
                    .frame(minHeight: 44).accessibilityIdentifier("pause-text-index")
                    .accessibilityHint("只取消本次文字更新，保留已完成记录，不停止图片同步")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    PhotoTextIndexStatusView(sync: sync)
                    if state.summary.textIndexStatisticsKnown {
                        Text("已识别 \(state.summary.textIndexCounts.records) 张 · 含文字 \(state.summary.textIndexCounts.withText) 张")
                            .font(.subheadline).monospacedDigit()
                            .accessibilityIdentifier("text-index-counts")
                    } else {
                        Text(state.summary.textIndexIssue ?? "文字索引统计尚未刷新。")
                            .font(.footnote).foregroundStyle(IQStyle.secondary)
                    }
                }
                if state.summary.textIndexStatisticsKnown, state.summary.textIndexCounts.reduced > 0 {
                    Text("其中 \(state.summary.textIndexCounts.reduced) 张使用较小或降质预览，细字可能识别不全；下次增量更新会重试。")
                        .font(.caption).foregroundStyle(IQStyle.secondary)
                }
                Button(updateTitle, systemImage: "text.viewfinder", action: updateIndex)
                    .frame(minHeight: 44).disabled(!canUpdate)
                    .accessibilityIdentifier("index-photo-text")
            }
            if sync.totalKnown, sync.progress.total > 0 {
                Text(sync.progress.summary)
                    .font(.caption).foregroundStyle(IQStyle.secondary)
                    .accessibilityIdentifier("text-index-progress-summary")
            }
            if !hasStopAction, let issue = state.textIndexOperationIssue {
                Text(issue).font(.footnote).foregroundStyle(IQStyle.secondary)
            }
            Text("仅处理已有图片索引中未变化的照片。先更新图片索引，才能纳入新增或编辑过的照片。识别时请保持应用在前台。")
                .font(.caption).foregroundStyle(IQStyle.secondary)
            Text("识别文字仅保存在本机，不参与备份。这里只显示保存统计，不代表当前有权限搜索的数量。关闭增强会取消等待或正在进行的更新，已完成的文字记录保留；清除索引会一起删除。")
                .font(.caption).foregroundStyle(IQStyle.secondary)
        } header: {
            Text("照片文字")
        } footer: {
            Text(PhotoTextIndexSection.triggerExplanation + "识别中英文后与图片结果合并搜索。文字识别优先本地高清像素，取不到可能用小预览；本次文字更新仅在全局允许 iCloud 下载时请求云端资源。")
        }
        .listRowBackground(IQStyle.surface)
    }
}

/// Shared read-only status for the library landing page and its maintenance
/// destination. Neither mounting nor returning to these views creates intent.
@MainActor
struct PhotoTextIndexStatusView: View {
    @ObservedObject var sync: OCRSyncState
    var showsDetail = true

    var title: String {
        switch sync.phase {
        case .idle: return "当前没有文字索引更新"
        case .waiting: return "文字索引等待更新"
        case .checking: return "正在检查文字索引"
        case .updating: return "正在更新文字索引 \(sync.progress.completed)/\(sync.progress.total)"
        case .cancelling: return "正在取消文字更新"
        case .cancelled: return "文字更新已取消"
        case .completed: return "文字索引已更新"
        case .failed: return "文字索引未完成"
        }
    }

    var detail: String {
        switch sync.phase {
        case .idle: return ""
        case .waiting: return "等待当前任务结束，并在前台、照片权限和图片索引就绪后更新一次；不会自动请求权限。"
        case .checking: return "正在检查已有记录，仅增量更新缺失或需要更新的文字索引。"
        case .updating: return "正在本机识别文字；已检查数包含复用和未完成项，不等于新识别数。"
        case .cancelling:
            return sync.pending
                ? "正在等待上次识别和存储停止；再次开启请求的一次更新仍在等待，已完成记录保留。"
                : "正在等待当前识别和存储停止，已完成记录保留。停止前不能重试。"
        case .cancelled: return "已完成记录保留，不会自动重试；开启功能并就绪后可在这里手动重试。"
        case .completed: return "本次增量检查已完成。需要再次检查时可手动更新。"
        case .failed: return "本次检查或部分项目未完成。已完成记录保留；请检查照片权限和图片索引后手动重试。"
        }
    }

    var body: some View {
        if sync.canShow {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).monospacedDigit()
                    .accessibilityIdentifier("text-index-status")
                if showsDetail {
                    Text(detail).font(.caption)
                        .accessibilityIdentifier("text-index-status-detail")
                }
            }
            .foregroundStyle(IQStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}