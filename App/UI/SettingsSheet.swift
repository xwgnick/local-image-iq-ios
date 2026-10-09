import SwiftUI

@MainActor
struct SettingsSheet: View {
    enum Route: String, CaseIterable, Hashable {
        case translation, privacy, advanced

        var title: String {
            switch self {
            case .translation: return "搜索增强"
            case .privacy: return "隐私与关于"
            case .advanced: return "高级"
            }
        }
        var accessibilityIdentifier: String { "settings-\(rawValue)" }
    }

    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var localPath: [Route] = []
    private let navigationPath: Binding<[Route]>?

    init(state: AppState, cleanup: SimilarPhotoCleanupState? = nil, path: Binding<[Route]>? = nil) {
        self.state = state
        navigationPath = path
    }

    var body: some View {
        NavigationStack(path: navigationPath ?? $localPath) {
            Form {
                Section {
                    NavigationLink(value: Route.translation) {
                        LabeledContent("搜索增强", value: state.chineseSearchEnabled ? "自动" : "关闭")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(Route.translation.accessibilityIdentifier)
                    Toggle("允许下载 iCloud 照片", isOn: $state.allowICloudDownload)
                        .disabled(state.isBusy)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("icloud-download-opt-in")
                    NavigationLink(value: Route.privacy) {
                        Text(Route.privacy.title).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(Route.privacy.accessibilityIdentifier)
                    NavigationLink(value: Route.advanced) {
                        Text(Route.advanced.title).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier(Route.advanced.accessibilityIdentifier)
                }
                .listRowBackground(IQStyle.surface)
            }
            .managementPage("设置")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .translation: QueryTranslationSettingsView(state: state)
                case .privacy: PrivacySettingsView(state: state)
                case .advanced: AdvancedSettingsView(state: state)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("close-settings")
                }
            }
        }
        .tint(IQStyle.accent)
    }
}

/// All diagnostic controls remain behind the existing session-only opt-in.
@MainActor
struct AdvancedSettingsView: View {
    @ObservedObject var state: AppState
    @State private var advancedExpanded = false
    @State private var diagnosticsExpanded = false

    var body: some View {
        Form {
            debugToolsSection
            if state.debugToolsEnabled {
                searchSection
                diagnosticsSection
            }
        }
        .managementPage("高级")
        .onChange(of: state.debugToolsEnabled) { _, enabled in
            if !enabled {
                advancedExpanded = false
                diagnosticsExpanded = false
            }
        }
    }

    private var searchSection: some View {
        Section {
            if state.debugToolsEnabled {
                DisclosureGroup(isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("地点权重")
                            .font(.subheadline.weight(.semibold))
                        Text(state.locationWeight, format: .percent.precision(.fractionLength(0)))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(IQStyle.accent)
                        Slider(value: $state.locationWeight, in: 0...1, step: 0.01) {
                            Text("地点权重")
                        }
                        .accessibilityValue(state.locationWeight.formatted(.percent.precision(.fractionLength(0))))
                        .accessibilityIdentifier("location-weight")
                        Text("0% 只比较图像，100% 只比较地点标签。权重影响排序，不限制可搜索的地点。")
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                        Text("地点标签来自照片自带的定位信息，不使用你的实时位置，也不直接用坐标排序。")
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                        Text(placeAvailability)
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                        Text("本机保存的 \(state.summary.indexedCount.formatted()) 张照片索引中，有 \(state.summary.locatedCount.formatted()) 张保存了地点标签。这不是当前可搜索或带定位照片的数量；手动索引的扫描记录见「我的图库」。")
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("关于分数").font(.subheadline.weight(.semibold))
                        if state.textSearchUsed {
                            Text("本次按图片与文字的名次合并排序；下方分数仅为原图片／地点分数，不是合并排序分数。")
                                .font(.footnote).foregroundStyle(IQStyle.secondary)
                        }
                        Text("分数表示相似度，不是概率。地点分数按不同标签去均值后，再与图像分数加权。无标签时地点贡献为零；权重为 100% 时，这些照片得零分，可能排在地点分数为负的照片前面。")
                            .font(.footnote)
                            .foregroundStyle(IQStyle.secondary)
                        if !state.results.isEmpty {
                            Text("当前结果分数").font(.caption.weight(.semibold))
                            ForEach(Array(state.results.enumerated()), id: \.element.id) { entry in
                                LabeledContent("第 \(entry.offset + 1) 张", value: entry.element.score.formatted(.number.precision(.fractionLength(3))))
                                    .font(.footnote)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                } label: {
                    // Identify only the disclosure label. An identifier on the
                    // whole group can propagate to its nested controls in SwiftUI.
                    Text("高级设置").accessibilityIdentifier("debug-advanced")
                }
            }
        } header: {
            Text("搜索")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                NavigationLink {
                    SearchTimingView(state: state)
                } label: { Text("搜索耗时") }
                .accessibilityIdentifier("debug-search-timing")
                Toggle("使用原搜索作对照", isOn: $state.referenceSearchEnabled)
                    .accessibilityIdentifier("reference-search-enabled")
                    .disabled(state.isBusy)
                Text("仅用于测速：开启后走原读取和评分路径，下次显式搜索生效。关闭调试工具会恢复加速搜索，不改变模型、照片范围或清晰度。")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
                NavigationLink {
                    LaunchTimingView(state: state)
                } label: {
                    Text("启动耗时")
                }
                .accessibilityIdentifier("debug-launch-timing")
                diagnostic("状态", state.status)
                diagnostic("模型版本", state.summary.modelVersion ?? "不可用")
                if let issue = state.summary.modelIssue { diagnostic("模型检查", issue) }
                diagnostic("离线地点", state.summary.placesDescription)
                if let error = state.errorMessage { diagnostic("上次操作问题", error) }
            } label: {
                // Keep the group ID off its children, including the timing link.
                Text("诊断信息").accessibilityIdentifier("debug-diagnostics")
            }
        }
        .listRowBackground(IQStyle.surface)
    }

    private var debugToolsSection: some View {
        Section {
            Toggle("显示调试工具", isOn: $state.debugToolsEnabled)
                .accessibilityIdentifier("show-debug-tools")
        } header: {
            Text("调试工具")
        } footer: {
            Text("仅本次使用有效，下次启动默认关闭。隐藏工具不会清空搜索结果，也不会重置已调整的设置。")
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

    private var placeAvailability: String {
        let description = state.summary.placesDescription
        if description.hasPrefix("No offline boundary pack bundled") {
            return "此版本未附带离线地点包，暂不能生成地点标签。"
        }
        if description.hasPrefix("Offline boundary pack could not be read:") {
            return "无法读取离线地点包，详情见「诊断信息」。"
        }
        if description.hasPrefix("Checking optional offline boundaries") {
            return "尚未检查离线地点是否可用。"
        }
        if description.hasPrefix("Offline country coverage:") || description.hasPrefix("Offline coverage:") {
            // Keep the resolver's metadata-derived countries, not its feature diagnostics.
            let coverage = description.components(separatedBy: " Administrative boundaries")[0]
                .replacingOccurrences(of: "Offline country coverage:", with: "离线国家覆盖：")
                .replacingOccurrences(of: "Offline coverage: this pack only.", with: "离线覆盖：仅此地点包。")
                .replacingOccurrences(of: "China", with: "中国")
                .replacingOccurrences(of: "France", with: "法国")
                .replacingOccurrences(of: "Germany", with: "德国")
                .replacingOccurrences(of: "Netherlands", with: "荷兰")
            return "\(coverage) 边界可能不完整或属于历史数据，并非全球覆盖。"
        }
        return "地点标签取决于离线包覆盖范围和照片中可用的定位信息。"
    }
}
// Cleanup threshold editing now lives in SimilarCleanupThresholdControls.

