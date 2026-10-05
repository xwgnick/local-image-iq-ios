import SwiftUI

/// No work on appearance or toggle. Only the explicit update button scans pixels.
@MainActor
struct PhotoTextIndexSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        Section {
            Toggle("文字搜索增强", isOn: $state.textSearchEnabled)
                .accessibilityIdentifier("photo-text-search-enabled")
            if state.textSearchEnabled {
                if state.activity == .indexingText {
                    if state.textIndexProgress.total > 0 {
                        ProgressView(value: state.textIndexProgress.fraction)
                            .accessibilityLabel("文字索引进度")
                    } else {
                        Text("正在检查已有图片索引…").font(.footnote)
                    }
                    Button("暂停文字索引", systemImage: "pause.fill") { state.cancel() }
                        .frame(minHeight: 44).accessibilityIdentifier("pause-text-index")
                } else {
                    if state.summary.textIndexStatisticsKnown {
                        Text("已识别 \(state.summary.textIndexCounts.records) 张 · 含文字 \(state.summary.textIndexCounts.withText) 张")
                            .font(.subheadline).monospacedDigit()
                            .accessibilityIdentifier("text-index-counts")
                        if state.summary.textIndexCounts.reduced > 0 {
                            Text("其中 \(state.summary.textIndexCounts.reduced) 张使用较小或降质预览，细字可能识别不全；下次手动更新会重试。")
                                .font(.caption).foregroundStyle(IQStyle.secondary)
                        }
                    } else {
                        Text(state.summary.textIndexIssue ?? "文字索引统计尚未刷新。")
                            .font(.footnote).foregroundStyle(IQStyle.secondary)
                    }
                    Button("更新文字索引", systemImage: "text.viewfinder") { state.indexPhotoText() }
                        .frame(minHeight: 44).disabled(!state.canIndexText)
                        .accessibilityIdentifier("index-photo-text")
                }
                if state.textIndexProgress.total > 0 {
                    Text(state.textIndexProgress.summary)
                        .font(.caption).foregroundStyle(IQStyle.secondary)
                        .accessibilityIdentifier("text-index-progress-summary")
                }
                if let issue = state.textIndexOperationIssue {
                    Text(issue).font(.footnote).foregroundStyle(IQStyle.secondary)
                }
                Text("仅处理已有图片索引中未变化的照片。先更新图片索引，才能纳入新增或编辑过的照片。识别时请保持应用在前台。")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
                Text("识别文字仅保存在本机，不参与备份。这里只显示保存统计，不代表当前有权限搜索的数量。关闭增强不会删除已有文字索引；清除索引会一起删除。")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
            }
        } header: {
            Text("照片文字")
        } footer: {
            Text(state.textSearchEnabled
                 ? "手动识别中英文后，与图片结果合并搜索；搜索本身不重新识别。优先本地高清像素，取不到可能用小预览；仅在已允许 iCloud 时请求云端资源。"
                 : "可选：查找截图、票据或照片中的文字。开启后需手动建立文字索引，不会自动扫描照片。")
        }
        .listRowBackground(IQStyle.surface)
    }
}