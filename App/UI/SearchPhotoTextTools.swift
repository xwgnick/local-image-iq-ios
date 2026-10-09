import SwiftUI

@MainActor
final class SearchPhotoTextPresentation: ObservableObject {
    @Published var showingIntroduction = false
}

/// Opt-in changes only the existing persisted preference. Recognition always
/// requires a separate explicit action, including the very first ON transition.
@MainActor
struct SearchPhotoTextTools: View {
    @ObservedObject var state: AppState
    var filtersDisabled = false
    var onPresentedSurfaceChanged: (Bool) -> Void
    let openFilters: () -> Void
    @StateObject private var presentation: SearchPhotoTextPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(state: AppState, filtersDisabled: Bool = false,
         presentation: SearchPhotoTextPresentation? = nil,
         onPresentedSurfaceChanged: @escaping (Bool) -> Void = { _ in },
         openFilters: @escaping () -> Void) {
        self.state = state
        self.filtersDisabled = filtersDisabled
        self.onPresentedSurfaceChanged = onPresentedSurfaceChanged
        self.openFilters = openFilters
        _presentation = StateObject(wrappedValue: presentation ?? SearchPhotoTextPresentation())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolsLayout {
                Button(action: openFilters) {
                    Label(state.searchFilters.isEmpty ? "筛选" : "已筛选",
                          systemImage: "line.3.horizontal.decrease")
                        .font(.caption).fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(state.isBusy || filtersDisabled)
                .accessibilityIdentifier("open-search-filters")
                .background { measuredFrame(.filters) }
                HStack(spacing: 0) {
                    Text("文本（ocr）增强搜索").font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHidden(true)
                        .background { measuredFrame(.label) }
                    Button { presentation.showingIntroduction = true } label: {
                        Image(systemName: "info.circle").font(.system(size: 17))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("文本（ocr）增强搜索介绍")
                    .accessibilityIdentifier("photo-text-search-info")
                    .background { measuredFrame(.info) }
                    Toggle("文本（ocr）增强搜索", isOn: $state.textSearchEnabled)
                        .labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("文本（ocr）增强搜索")
                        .accessibilityIdentifier("photo-text-search-enabled")
                        .fixedSize().frame(minWidth: 51, minHeight: 44)
                        .contentShape(Rectangle())
                        .background { measuredFrame(.toggle) }
                }
            }
            if !state.searchFilters.isEmpty {
                Text(filterSummary).font(.caption).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.similarPhotoID != nil {
                Text("相似照片").font(.caption).foregroundStyle(IQStyle.accent)
            }
            if state.textSearchEnabled {
                if state.activity == .indexingText {
                    ProgressView("正在识别照片文字…").font(.caption)
                    Button("暂停文字索引") { state.cancel() }
                        .frame(minHeight: 44).accessibilityIdentifier("pause-text-index")
                } else {
                    Button(state.summary.textIndexCounts.records == 0 ? "建立文字索引" : "更新文字索引") {
                        state.indexPhotoText()
                    }
                    .font(.caption).frame(minHeight: 44)
                    .disabled(!state.canIndexText).accessibilityIdentifier("index-photo-text")
                }
                if let issue = state.textIndexOperationIssue {
                    Text(issue).font(.caption).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(IQStyle.accent)
        .onChange(of: presentation.showingIntroduction, initial: true) { _, presented in
            onPresentedSurfaceChanged(presented)
        }
        .sheet(isPresented: $presentation.showingIntroduction) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("识别照片里的文字，让文字也能成为搜索线索。")
                        Text("适合查找证件、票据、截图和招牌；识别结果可能有遗漏。")
                        Text("查看介绍不会开启功能或建立索引。开启后仍需手动建立文字索引；识别在本机完成。关闭不会删除已有文字索引。")
                    }
                    .font(.body).foregroundStyle(IQStyle.text)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(IQStyle.background)
                .navigationTitle("文本（ocr）增强搜索").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { presentation.showingIntroduction = false }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("close-photo-text-info")
                    }
                }
            }
            .tint(IQStyle.accent)
        }
    }

    private var toolsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    private var filterSummary: String {
        var parts: [String] = []
        if state.searchFilters.startDate != nil || state.searchFilters.endDateExclusive != nil { parts.append("日期") }
        if state.searchFilters.albumID != nil { parts.append("相册") }
        if state.searchFilters.imageKind != .all { parts.append(state.searchFilters.imageKind.title) }
        return parts.joined(separator: " · ")
    }

    private func measuredFrame(_ element: SearchPhotoTextElement) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: SearchPhotoTextFrames.self, value: [element: geometry.frame(in: .global)])
        }
    }
}

enum SearchPhotoTextElement: Hashable { case filters, label, info, toggle }
struct SearchPhotoTextFrames: PreferenceKey {
    static var defaultValue: [SearchPhotoTextElement: CGRect] = [:]
    static func reduce(value: inout [SearchPhotoTextElement: CGRect], nextValue: () -> [SearchPhotoTextElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}