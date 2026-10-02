import SwiftUI

@MainActor
struct SettingsSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var advancedExpanded = false
    @State private var diagnosticsExpanded = false

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                translationSection
                maintenanceSection
                if state.debugToolsEnabled {
                    diagnosticsSection
                }
                privacySection
                debugToolsSection
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .tint(IQStyle.accent)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("close-settings")
                }
            }
            .confirmationDialog("清除本地索引？", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清除索引", role: .destructive) { state.clearIndex() }
                    .disabled(state.isBusy)
                Button("取消", role: .cancel) { }
            } message: {
                Text("只删除本机的搜索索引，不删除原照片。重新准备图库后即可搜索。")
            }
        }
        .tint(IQStyle.accent)
        .onChange(of: state.debugToolsEnabled) { _, enabled in
            if !enabled {
                advancedExpanded = false
                diagnosticsExpanded = false
            }
        }
        .background {
            if let service = state.appleTranslationService {
                AppleQueryTranslationHost(service: service, purpose: .preparation)
            }
        }
        .task(id: state.translationLanguage) { await state.checkTranslationAvailability() }
        .onDisappear { state.dismissTranslationPreparation() }
    }

    private var translationSection: some View {
        Section {
            Toggle("中文搜索增强", isOn: $state.chineseSearchEnabled)
                .accessibilityIdentifier("chinese-search-enabled")
            Picker("离线语言包", selection: $state.translationLanguage) {
                ForEach(QueryTranslationLanguage.allCases) { language in
                    Text(language.title).tag(language)
                }
            }
            .disabled(state.activity == .preparingTranslation)
            .accessibilityIdentifier("translation-language")
            Text(state.translationSupported ? state.translationAvailability.message : "需要 iOS 18+ 真机；仍可原文搜索")
                .font(.footnote).foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("translation-availability")
            if state.activity == .preparingTranslation {
                ProgressView("正在准备离线语言包…")
                Button("取消准备") { state.dismissTranslationPreparation() }.frame(minHeight: 44)
            } else {
                Button(state.translationAvailability == .installed ? "检查离线语言包" : "下载离线语言包") {
                    state.prepareTranslation()
                }
                .disabled(state.isBusy || !state.translationSupported)
                .frame(minHeight: 44)
                .accessibilityIdentifier("prepare-translation")
            }
            if let issue = state.translationPreparationIssue {
                Text(issue).font(.footnote).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("中文搜索")
        } footer: {
            Text("中文或中英混合搜索在本机译成英文，纯英文不变；结果可切回原文。已知缺包时用原文搜索，不自动请求下载。准备语言包需联网、可用空间和系统确认，与照片 iCloud 开关无关；若检查后语言包被移除，系统仍可能提示下载。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var searchSection: some View {
        Section {
            Picker("结果数量", selection: $state.resultLimit) {
                Text("前3张").tag(3).accessibilityIdentifier("result-limit-3")
                Text("前12张").tag(12).accessibilityIdentifier("result-limit-12")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("result-limit")

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
        } footer: {
            Text("修改后清空当前结果，下次搜索时生效。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var maintenanceSection: some View {
        Section {
            Button("刷新索引统计", systemImage: "arrow.clockwise") { state.refresh() }
                .disabled(state.isBusy)
                .frame(minHeight: 44)
                .accessibilityIdentifier("refresh-library")
            Button(role: .destructive) { confirmClear = true } label: {
                Label("清除索引", systemImage: "trash")
                    .frame(minHeight: 44)
            }
            .disabled(state.isBusy)
            .accessibilityIdentifier("clear-index")
            if state.activity == .refreshing || state.activity == .clearing {
                ProgressView(state.activity == .clearing ? "正在清除本地索引…" : "正在刷新索引统计…")
            }
            if let error = state.errorMessage {
                Text(state.summary.modelIssue != nil || error.hasPrefix("Models unavailable:") || error.hasPrefix("Model contract mismatch:")
                     ? "搜索暂不可用。仍可在「我的图库」管理照片权限，或刷新后重试。"
                     : "上次操作未完成。请在「我的图库」检查照片权限，再刷新重试。原照片未改变。")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("图库维护")
        } footer: {
            Text("刷新只读取本机保存的索引统计，不扫描照片或更新索引。请在「我的图库」手动更新或全部重建索引。清除索引不会删除原照片。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("诊断信息", isExpanded: $diagnosticsExpanded) {
                diagnostic("状态", state.status)
                diagnostic("模型版本", state.summary.modelVersion ?? "不可用")
                if let issue = state.summary.modelIssue { diagnostic("模型检查", issue) }
                diagnostic("离线地点", state.summary.placesDescription)
                if let error = state.errorMessage { diagnostic("上次操作问题", error) }
            }
            .accessibilityIdentifier("debug-diagnostics")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var privacySection: some View {
        Section("关于与隐私") {
            Text("原照片保留在系统照片图库中。搜索在本机运行，不向应用服务器上传照片或搜索内容。索引只存搜索数据和可选地点标签，不存原图或定位坐标，也不参与备份。仅在「我的图库」开启 iCloud 后，系统照片才可能为准备图库下载缺失的图像数据。")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
            Text("Apple 翻译系统可能收集使用与性能指标，但不包含原文或译文。")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
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