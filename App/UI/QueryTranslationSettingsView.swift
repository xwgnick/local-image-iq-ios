import SwiftUI

/// A pushed page, never a second navigation stack. Only this explicitly opened
/// page owns the preparation host; viewing it checks availability, not downloads.
@MainActor
struct QueryTranslationSettingsView: View {
    @ObservedObject var state: AppState
    @State private var isPresented = false

    var body: some View {
        Form {
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
                    Button("取消准备") { state.dismissTranslationPreparation() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("cancel-translation-preparation")
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
            } footer: {
                Text("中文或中英混合搜索在本机译成英文，纯英文不变；结果可切回原文。已知缺包时用原文搜索，不自动请求下载。准备语言包需联网、可用空间和系统确认，与照片 iCloud 开关无关；若检查后语言包被移除，系统仍可能提示下载。")
            }
            .listRowBackground(IQStyle.surface)
        }
        .managementPage("搜索增强")
        .background {
            if isPresented, let service = state.appleTranslationService {
                AppleQueryTranslationHost(service: service, purpose: .preparation)
            }
        }
        .onAppear { isPresented = true }
        .task(id: state.translationLanguage) { await state.checkTranslationAvailability() }
        .onDisappear {
            // Does not cancel an unrelated search; AppState scopes this to prep.
            state.dismissTranslationPreparation()
            isPresented = false
        }
    }
}