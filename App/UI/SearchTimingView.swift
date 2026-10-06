import SwiftUI

/// Parent-owned state supplies the current report; this view starts no work.
@MainActor
struct SearchTimingView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.debugToolsEnabled {
                SearchTimingContent(report: state.searchTimingReport)
            } else {
                Text("调试工具已隐藏")
                    .foregroundStyle(IQStyle.secondary)
            }
        }
        .navigationTitle("搜索耗时")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Render-only seam: no observation, searches, photo requests, timers or history.
struct SearchTimingContent: View {
    let report: SearchTimingReport?

    static let cacheNote = "首次从 SQLite 数据库读取时，加速路径可能还要构建二进制缓存和评分矩阵；二进制缓存读取与内存驻留复用是不同情况，应分开比较。首次搜索不一定代表系统缓存为空。"
    static let imageNote = "首张缩略图从同一次搜索起点计时，包含排名前的耗时，不能与排名耗时相加。它可能是 Fast 回退图，不代表高清图已返回，也不测量屏幕绘制完成。未返回不等于零耗时。"
    static let comparisonNote = "在调试设置中切换参考基线与加速模式，保持图库、筛选、地点权重和文字搜索设置一致。先记录首次搜索，再连续使用不同查询；分别比较英文、中文翻译，以及照片文字搜索（OCR）开启与关闭的情况，不只重复同一句查询。"
    static let limitNote = "总耗时包含翻译、查询编码和图库访问检查。按 Amdahl 定律，只缩短评分阶段不能代表整个搜索按同样倍数提速；瓶颈需以本机分段数据判断。桌面缩放图片的像素基准和模拟器结果不能替代手机实测。"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let report {
                    summary(report)
                    metadata(report)
                    stageList(report)
                } else {
                    Text("本次进程暂无搜索耗时记录")
                        .font(.headline)
                        .padding(.vertical, 20)
                        .accessibilityIdentifier("search-timing-empty")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("如何比较")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(IQStyle.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(Self.comparisonNote)
                    Text(Self.cacheNote)
                    Text(Self.limitNote)
                    Text("本页只展示当前一次的内存报告，不保存历史或上传数据；不记录查询内容、照片标识或路径。")
                }
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
                .padding(12)
                .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("search-timing-page")
        .background(IQStyle.background)
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .navigationTitle("搜索耗时")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(IQStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func summary(_ report: SearchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近一次 · \(report.outcome.rawValue)")
                .font(.subheadline.weight(.semibold))

            Text(report.outcome == .ready ? "到排名发布耗时" : "到本次搜索结束耗时")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            Text(SearchTimingReport.duration(report.totalSeconds))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(IQStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("search-timing-total")

            Text("到首张缩略图")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            Text(report.firstImageSeconds.map { SearchTimingReport.duration($0) } ?? "未返回")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("search-timing-first-image")

            if report.outcome != .ready {
                Text("本次未成功发布排名；总耗时截止于取消或失败。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
            }
            Text(Self.imageNote)
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func metadata(_ report: SearchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchTimingMetricRow(title: "模式", value: report.mode)
            SearchTimingMetricRow(title: "缓存", value: report.cacheSource)
            SearchTimingMetricRow(title: "候选数", value: String(report.candidateCount))
            SearchTimingMetricRow(title: "矩阵复用", value: report.matrixReused ? "是" : "否")
            SearchTimingMetricRow(title: "图库快照复用", value: report.snapshotReused ? "是" : "否")
            Text("候选数为本次搜索实际报告的候选行数，不是每页显示数量。")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
        }
        .padding(12)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stageList(_ report: SearchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分段耗时")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ForEach(report.stages) { row in
                SearchTimingMetricRow(title: row.stage.rawValue,
                                      value: SearchTimingReport.duration(row.seconds))
            }
            Text("从搜索请求入口开始，包含排队和等待。各段互不重叠，加总为上述总耗时；显示值保留三位小数，逐项显示值相加可能有舍入差。未经过的阶段不补造耗时。")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
        }
        .padding(12)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Stack at large text sizes rather than truncate labels or shrink durations.
private struct SearchTimingMetricRow: View {
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).fixedSize()
                Spacer(minLength: 0)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value).monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.footnote)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title)，\(value)"))
    }
}