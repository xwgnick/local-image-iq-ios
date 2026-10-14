import SwiftUI

@MainActor
final class SearchPhotoTextPresentation: ObservableObject {
    @Published var showingIntroduction = false
    @Published var showingLocationIntroduction = false
}

/// OFF->ON requests one incremental OCR update through AppState. Merely
/// rendering this view or opening its introduction never requests any work.
@MainActor
struct SearchPhotoTextTools: View {
    @ObservedObject var state: AppState
    var filtersDisabled = false
    var onPresentedSurfaceChanged: (Bool) -> Void
    let openFilters: () -> Void
    @StateObject private var presentation: SearchPhotoTextPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption2) private var subtitleSize: CGFloat = 11

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
            HStack {
                Button(action: openFilters) {
                    Label(state.searchFilters.isEmpty ? "筛选" : "已筛选",
                          systemImage: "line.3.horizontal.decrease")
                        .font(.caption).fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(state.isBusy || filtersDisabled)
                .accessibilityIdentifier("open-search-filters")
                .background { measuredFrame(.filters) }
                Spacer()
            }
            toolsLayout {
                enhancement(title: "OCR 增强", subtitle: "搜索照片中的文字",
                            enabled: $state.textSearchEnabled, location: false) {
                    presentation.showingIntroduction = true
                }
                enhancement(title: "地点增强", subtitle: "搜索某地点的照片",
                            enabled: $state.locationSearchEnabled, location: true) {
                    presentation.showingLocationIntroduction = true
                }
            }
            if !state.searchFilters.isEmpty {
                Text(filterSummary).font(.caption).foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.similarPhotoID != nil {
                Text("相似照片").font(.caption).foregroundStyle(IQStyle.accent)
            }
        }
        .tint(IQStyle.accent)
        .onChange(of: introductionPresented, initial: true) { _, presented in
            onPresentedSurfaceChanged(presented)
        }
        .sheet(isPresented: $presentation.showingIntroduction) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("识别照片里的文字，让文字也能成为搜索线索。")
                        Text("适合查找证件、票据、截图和招牌；识别结果可能有遗漏。")
                        Text("查看介绍不会开启功能。每次从关闭切换为开启，会自动增量更新一次文字索引；忙碌时等待当前任务结束。识别在本机完成，是否允许读取 iCloud 照片仍由原设置决定。关闭会取消等待或正在进行的更新，已完成的索引保留。")
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
        .sheet(isPresented: $presentation.showingLocationIntroduction) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("把照片拍摄地点也作为搜索线索。").font(.title3.weight(.semibold))
                        Text("适合找“上海外滩的夜景”“杭州西湖边的照片”等包含地点的回忆。默认关闭，开启后参与结果排序。")
                        Text("默认地点权重 0.6，可在「设置 → 搜索增强」调整。关闭增强不会清除已保存的地点标签。")
                        Text("地点来自照片自带的定位信息，取决于离线地点包覆盖。不使用你的实时位置。")
                        NavigationLink("前往搜索增强设置") {
                            QueryTranslationSettingsView(state: state)
                        }
                        .frame(minHeight: 44).accessibilityIdentifier("open-location-enhancement-settings")
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(IQStyle.background).foregroundStyle(IQStyle.text)
                .navigationTitle("地点增强").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { presentation.showingLocationIntroduction = false }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("close-location-info")
                    }
                }
            }
            .tint(IQStyle.accent)
        }
    }

    private var introductionPresented: Bool {
        presentation.showingIntroduction || presentation.showingLocationIntroduction
    }

    private func enhancement(title: String, subtitle: String, enabled: Binding<Bool>,
                             location: Bool, info: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(title).font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .background { measuredFrame(location ? .locationLabel : .label) }
                Spacer(minLength: 0)
                Button(action: info) {
                    Image(systemName: "info.circle").resizable().scaledToFit()
                        .frame(width: 13, height: 13)
                        .foregroundStyle(IQStyle.accent)
                        .background { measuredFrame(location ? .locationInfoGlyph : .infoGlyph) }
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(location ? "地点增强介绍" : "文本（ocr）增强搜索介绍")
                .accessibilityIdentifier(location ? "location-search-info" : "photo-text-search-info")
                .background { measuredFrame(location ? .locationInfo : .info) }
            }
            HStack(spacing: 4) {
                Text(subtitle).font(.system(size: subtitleSize))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(IQStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { measuredFrame(location ? .locationSubtitle : .subtitle) }
                Toggle(title, isOn: enabled)
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityLabel(location ? "地点增强" : "文本（ocr）增强搜索")
                    .accessibilityIdentifier(location ? "location-search-enabled" : "photo-text-search-enabled")
                    .fixedSize().frame(minWidth: 51, minHeight: 44)
                    .background { measuredFrame(location ? .locationToggle : .toggle) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var toolsLayout: SearchEnhancementsLayout {
        SearchEnhancementsLayout(stacked: dynamicTypeSize.isAccessibilitySize)
    }

    struct SearchEnhancementsLayout: Layout {
        let stacked: Bool
        private func vertical(_ width: CGFloat) -> Bool { stacked || width < 340 }
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? 353
            let columnWidth = vertical(width) ? width : (width - 20) / 2
            let heights = subviews.map { $0.sizeThatFits(.init(width: columnWidth, height: nil)).height }
            return CGSize(width: width, height: vertical(width) ? heights.reduce(0, +) + 8 : heights.max() ?? 0)
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let columnWidth = vertical(bounds.width) ? bounds.width : (bounds.width - 20) / 2
            var y = bounds.minY
            for (index, subview) in subviews.enumerated() {
                let height = subview.sizeThatFits(.init(width: columnWidth, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX + (vertical(bounds.width) ? 0 : CGFloat(index) * (columnWidth + 20)),
                                         y: y), anchor: .topLeading,
                              proposal: .init(width: columnWidth, height: height))
                if vertical(bounds.width) { y += height + 8 }
            }
        }
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

enum SearchPhotoTextElement: Hashable {
    case filters, label, info, toggle, subtitle, infoGlyph
    case locationLabel, locationInfo, locationToggle, locationSubtitle, locationInfoGlyph
}
struct SearchPhotoTextFrames: PreferenceKey {
    static var defaultValue: [SearchPhotoTextElement: CGRect] = [:]
    static func reduce(value: inout [SearchPhotoTextElement: CGRect], nextValue: () -> [SearchPhotoTextElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}