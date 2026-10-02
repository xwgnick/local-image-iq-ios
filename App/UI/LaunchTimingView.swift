import SwiftUI

/// Observation and debug visibility live here; the content below only renders
/// completed reports and never starts preparation, refresh, or photo work.
@MainActor
struct LaunchTimingView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.debugToolsEnabled {
                LaunchTimingContent(reports: state.launchTimings)
            } else {
                Text("调试工具已隐藏")
                    .foregroundStyle(IQStyle.secondary)
            }
        }
        .navigationTitle("启动耗时")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Render-only seam for native fixtures. Reports arrive in chronological order;
/// reversing their presentation never changes the session's stored history.
struct LaunchTimingContent: View {
    let reports: [LaunchTimingReport]
    let version: String?
    let build: String?

    init(reports: [LaunchTimingReport], bundle: Bundle = .main) {
        self.init(reports: reports,
                  version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    init(reports: [LaunchTimingReport], version: String?, build: String?) {
        self.reports = reports
        self.version = version
        self.build = build
    }

    var latest: LaunchTimingReport? { reports.last }
    var earlierReports: [LaunchTimingReport] { Array(reports.dropLast().reversed()) }
    var versionText: String {
        "版本 \(Self.metadata(version)) · 构建 \(Self.metadata(build))"
    }

    static let historyNote = "仅保留本次进程记录；前台轻量刷新不覆盖记录。重试可能复用模型。"
    static let coldNote = "“本进程首次启动”不代表系统或模型缓存为空。"
    static let parallelNote = "并行总等待包含排队、各任务启动时间差，以及结束或取消时等待全部任务退出，因此可能长于最慢子任务。但准备中断会立即冻结记录，不含其后共享任务继续加载或退出的时间。子任务记录的是经过时间，不是 CPU 用时；时间重叠，不相加，也不计入总耗时加总。"

    static func totalLabel(for report: LaunchTimingReport) -> String {
        report.outcome == .ready ? "到首页就绪" : "到本次准备结束"
    }

    static func scope(for report: LaunchTimingReport) -> String {
        report.outcome == .ready
            ? "从 App 开始准备到发布首页就绪；不含 iOS 启动进程及首帧绘制"
            : "从 App 开始准备到本次准备结束；不含 iOS 启动进程及首帧绘制"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("请截图本页；长列表可分两张")
                    Text(versionText)
                        .accessibilityIdentifier("launch-timing-version")
                }
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)

                if let latest {
                    summary(latest)
                    stageList(latest)
                    if !latest.components.isEmpty {
                        LaunchTimingComponentList(components: latest.components)
                            .padding(12)
                            .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    Text("本次进程暂无准备记录")
                        .font(.headline)
                        .padding(.vertical, 20)
                        .accessibilityIdentifier("launch-timing-empty")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("各段为实际经过时间，包含调度和等待，不是 CPU 用时。起点在启动准备入口，不含此前的 App 初始化。")
                    Text(Self.parallelNote)
                    Text(Self.historyNote)
                    Text(Self.coldNote)
                }
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)

                if !earlierReports.isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(earlierReports) { report in
                                VStack(alignment: .leading, spacing: 8) {
                                    attemptHeading(report)
                                    LaunchTimingMetricRow(
                                        title: Self.totalLabel(for: report),
                                        value: LaunchTimingReport.duration(report.totalSeconds))
                                    slowest(report)
                                    Text(Self.scope(for: report))
                                        .font(.caption)
                                        .foregroundStyle(IQStyle.secondary)
                                    rows(report)
                                    LaunchTimingComponentList(components: report.components)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    } label: {
                        Text("此前准备（\(earlierReports.count) 次）")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("launch-timing-history")
                    }
                    .padding(12)
                    .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("startup-timing-page")
        .background(IQStyle.background)
        .foregroundStyle(IQStyle.text)
        .tint(IQStyle.accent)
        .navigationTitle("启动耗时")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(IQStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func summary(_ report: LaunchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近一次")
                .font(.caption.weight(.semibold))
                .foregroundStyle(IQStyle.secondary)
            attemptHeading(report)
            Text(LaunchTimingReport.duration(report.totalSeconds))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(IQStyle.accent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("launch-timing-total")
            Text(Self.totalLabel(for: report))
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            slowest(report)
            Text(Self.scope(for: report))
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func attemptHeading(_ report: LaunchTimingReport) -> some View {
        Text("\(report.kind.rawValue) · \(report.outcome.rawValue)")
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func slowest(_ report: LaunchTimingReport) -> some View {
        if let row = report.slowest {
            VStack(alignment: .leading, spacing: 2) {
                Text("最慢阶段")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
                LaunchTimingMetricRow(title: row.stage.rawValue,
                                      value: LaunchTimingReport.duration(row.seconds))
            }
        }
    }

    private func stageList(_ report: LaunchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分段耗时")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            rows(report)
        }
        .padding(12)
        .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func rows(_ report: LaunchTimingReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(report.rows) { row in
                LaunchTimingMetricRow(title: row.stage.rawValue,
                                      value: LaunchTimingReport.duration(row.seconds))
            }
        }
    }

    private static func metadata(_ value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "未知"
        }
        return value
    }
}

/// Shared by the latest card and each older attempt; no invented missing rows.
/// Kept separate from wall rows so overlapping branches cannot imply a sum.
struct LaunchTimingComponentList: View {
    let components: [LaunchTimingComponent]

    static let title = "并行任务（时间重叠，不相加）"

    static func detail(for component: LaunchTimingComponent) -> String {
        "\(component.outcome.rawValue) · 启动后 +\(LaunchTimingReport.duration(component.startOffsetSeconds))开始"
    }

    var body: some View {
        if !components.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(components) { component in
                        VStack(alignment: .leading, spacing: 2) {
                            LaunchTimingMetricRow(title: component.stage.rawValue,
                                                  value: LaunchTimingReport.duration(component.seconds))
                            Text(Self.detail(for: component))
                                .font(.caption2)
                                .foregroundStyle(IQStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("launch-timing-component-\(component.stage.rawValue)")
                    }
                }
            }
        }
    }
}

/// Prefer compact columns, but stack instead of shrinking or ellipsizing a
/// duration when Dynamic Type, a long stage label, or a long value needs room.
private struct LaunchTimingMetricRow: View {
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