import SwiftUI

/// Opt-in changes only the existing persisted preference. Recognition always
/// requires a separate explicit action, including the very first ON transition.
@MainActor
struct SearchPhotoTextTools: View {
    @ObservedObject var state: AppState
    var filtersDisabled = false
    let openFilters: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            toolsLayout {
                Button(action: openFilters) {
                    Label(state.searchFilters.isEmpty ? "筛选" : "已筛选",
                          systemImage: "line.3.horizontal.decrease")
                        .font(.subheadline).fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(state.isBusy || filtersDisabled)
                .accessibilityIdentifier("open-search-filters")
                HStack(spacing: 8) {
                    switchLayout {
                        Text("照片文字").font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                        Toggle("照片文字", isOn: $state.textSearchEnabled)
                            .labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("照片文字")
                            .accessibilityIdentifier("photo-text-search-enabled")
                            .fixedSize().frame(minWidth: 51, minHeight: 44)
                            .contentShape(Rectangle())
                            .background { measuredFrame(.toggle) }
                    }
                    Text("用照片里的文字进行搜索")
                        .font(.caption2).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("photo-text-search-explanation")
                        .background { measuredFrame(.explanation) }
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
    }

    private var toolsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var switchLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
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

enum SearchPhotoTextElement: Hashable { case toggle, explanation }
struct SearchPhotoTextFrames: PreferenceKey {
    static var defaultValue: [SearchPhotoTextElement: CGRect] = [:]
    static func reduce(value: inout [SearchPhotoTextElement: CGRect], nextValue: () -> [SearchPhotoTextElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}