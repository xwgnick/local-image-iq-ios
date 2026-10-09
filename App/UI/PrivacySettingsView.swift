import SwiftUI

@MainActor
struct PrivacySettingsView: View {
    @ObservedObject var state: AppState
    @State private var confirmClearHistory = false

    var body: some View {
        Form {
            Section {
                Button("清除搜索记录", role: .destructive) { confirmClearHistory = true }
                    .frame(minHeight: 44)
                    .disabled(state.recentSearchQueries.isEmpty && state.searchHistoryIssue == nil)
                    .accessibilityIdentifier("clear-search-history")
                if state.searchHistoryIssue != nil {
                    // Never render an underlying storage error or saved query.
                    Text("搜索记录暂不可用，可重试清除。")
                        .font(.footnote).foregroundStyle(IQStyle.secondary)
                        .accessibilityIdentifier("search-history-issue")
                }
            } header: {
                Text("搜索记录")
            } footer: {
                Text("仅清除本机保存的搜索记录，不删除照片，也不清除图片、地点或文字索引。")
            }
            .listRowBackground(IQStyle.surface)

            Section("本机处理") {
                note("搜索在本机运行，不向应用服务器上传照片或搜索内容。图片索引不保存原图或定位坐标；索引保存在受保护的本机目录，不参与备份。")
                note("可选文字搜索使用系统 Vision 在本机识别，识别文字保存在本机索引中。关闭增强只停止参与搜索；清除索引才会一并删除文字记录。")
            }
            .listRowBackground(IQStyle.surface)

            Section("系统服务与分享") {
                note("默认不允许下载 iCloud 照片。开启后，只有本地预览不可用时，应用才允许系统照片下载缺失资源；下载量由系统决定。语言包准备与此开关无关。Apple 系统服务的数据处理取决于其设置和隐私政策。")
                note("收藏、相册操作和分享由你主动发起；相似照片清理仅删除你勾选并再次确认的照片，不自动删除或修改原图像素。系统 iCloud 照片可能将删除同步到其他设备，与预览下载开关无关。")
                note("分享时临时生成去除位置等源元数据的 JPEG，结束后清理本机临时文件；照片画面本身仍可能包含私人信息，分享接收方可保留副本。")
            }
            .listRowBackground(IQStyle.surface)

            Section("关于") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            .listRowBackground(IQStyle.surface)
        }
        .managementPage("隐私与关于")
        .confirmationDialog("清除搜索记录？", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("清除搜索记录", role: .destructive) { state.clearSearchHistory() }
                .accessibilityIdentifier("confirm-clear-search-history")
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅删除本机搜索记录，照片和所有索引保持不变。")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(IQStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}