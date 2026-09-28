import SwiftUI

@MainActor
struct SettingsSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                searchSection
                translationSection
                maintenanceSection
                diagnosticsSection
                privacySection
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .tint(IQStyle.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("close-settings")
                }
            }
            .confirmationDialog("Clear the local index?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear index", role: .destructive) { state.clearIndex() }
                    .disabled(state.isBusy)
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This deletes only the app's local search index, not your original photos. Index again to make your photos searchable.")
            }
        }
        .preferredColorScheme(.dark)
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
            Text("中文及中英混合查询在手机上翻译成英文，纯英文不翻译。缺少语言包时使用原文，不自动下载。点击准备并经系统确认后才可能下载语言包；需联网及存储空间，与照片 iCloud 开关无关。译文显示在结果上方，可切回原文。系统可能收集不含原文或译文的使用与性能指标。")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var searchSection: some View {
        Section {
            Picker("Result count", selection: $state.resultLimit) {
                Text("Top 3").tag(3)
                Text("Top 12").tag(12)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("result-limit")

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Location contribution")
                        .font(.subheadline.weight(.semibold))
                    Text(state.locationWeight, format: .percent.precision(.fractionLength(0)))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(IQStyle.accent)
                    Slider(value: $state.locationWeight, in: 0...1, step: 0.01) {
                        Text("Location contribution")
                    }
                    .accessibilityValue(state.locationWeight.formatted(.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("location-weight")
                    Text("0% uses image similarity; 100% uses place-label similarity. This changes ranking, not which places are allowed.")
                        .font(.footnote)
                        .foregroundStyle(IQStyle.secondary)
                    Text("Labels use GPS saved with a photo, not your live location. Raw coordinates aren't used for ranking.")
                        .font(.footnote)
                        .foregroundStyle(IQStyle.secondary)
                    Text(placeAvailability)
                        .font(.footnote)
                        .foregroundStyle(IQStyle.secondary)
                    Text("Saved index: \(state.summary.locatedCount.formatted()) of \(state.summary.indexedCount.formatted()) photos had place labels at the last library check. This is not a GPS count; scan observations are in Library.")
                        .font(.footnote)
                        .foregroundStyle(IQStyle.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 8) {
                    Text("About scores").font(.subheadline.weight(.semibold))
                    Text("Scores measure similarity, not probability. Place scores are centered over distinct place labels before blending with image scores. Missing labels add zero place contribution; at 100%, those photos score zero and can rank above negative place matches.")
                        .font(.footnote)
                        .foregroundStyle(IQStyle.secondary)
                    if !state.results.isEmpty {
                        Text("Current match scores").font(.caption.weight(.semibold))
                        ForEach(Array(state.results.enumerated()), id: \.element.id) { entry in
                            LabeledContent("Match \(entry.offset + 1)", value: entry.element.score.formatted(.number.precision(.fractionLength(3))))
                                .font(.footnote)
                                .monospacedDigit()
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
            }
        } header: {
            Text("Search")
        } footer: {
            Text("Changes apply to your next search. Changing search settings clears the current matches.")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var maintenanceSection: some View {
        Section {
            Button("Refresh library", systemImage: "arrow.clockwise") { state.refresh() }
                .disabled(state.isBusy)
                .frame(minHeight: 44)
            Button(role: .destructive) { confirmClear = true } label: {
                Label("Clear index", systemImage: "trash")
                    .frame(minHeight: 44)
            }
            .disabled(state.isBusy)
            if state.activity == .refreshing || state.activity == .clearing {
                ProgressView(state.activity == .clearing ? "Clearing local index…" : "Refreshing library…")
            }
            if let error = state.errorMessage {
                Text(state.summary.modelIssue != nil || error.hasPrefix("Models unavailable:") || error.hasPrefix("Model contract mismatch:")
                     ? "Requires a model-enabled build. You can still manage Photos access in Library."
                     : "The last action couldn't finish. Check Photos access in Library, then refresh and try again; technical details are below.")
                    .font(.footnote)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Library maintenance")
        } footer: {
            Text("Refresh checks Photos access and saved coverage without rebuilding. Clearing removes the local index, never your original photos.")
        }
        .listRowBackground(IQStyle.surface)
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("Diagnostics") {
                diagnostic("Status", state.status)
                diagnostic("Model version", state.summary.modelVersion ?? "Not available")
                if let issue = state.summary.modelIssue { diagnostic("Model check", issue) }
                diagnostic("Offline places", state.summary.placesDescription)
                if let error = state.errorMessage { diagnostic("Last operation issue", error) }
            }
        }
        .listRowBackground(IQStyle.surface)
    }

    private var privacySection: some View {
        Section("About & privacy") {
            Text("Your originals stay in your Photos library. Search runs on this device, with no photos or searches uploaded to an app server. The local index stores search data and optional place labels, not original images or GPS coordinates, and is excluded from backups. Only if you enable iCloud access in Library may Photos download missing image data.")
                .font(.subheadline)
                .foregroundStyle(IQStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4)
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
            return "This build has no offline place pack, so place labels are unavailable."
        }
        if description.hasPrefix("Offline boundary pack could not be read:") {
            return "The offline place pack couldn't be read; see Diagnostics."
        }
        if description.hasPrefix("Checking optional offline boundaries") {
            return "Offline place availability has not been checked yet."
        }
        if description.hasPrefix("Offline country coverage:") || description.hasPrefix("Offline coverage:") {
            // Keep the resolver's metadata-derived countries, not its feature diagnostics.
            let coverage = description.components(separatedBy: " Administrative boundaries")[0]
            return "\(coverage) Boundaries may be incomplete or historical; not global coverage."
        }
        return "Place labels depend on the offline pack's coverage and each photo's available location."
    }
}