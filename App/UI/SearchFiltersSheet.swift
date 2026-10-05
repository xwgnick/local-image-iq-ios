import Foundation
import SwiftUI

/// Value-only editing state. Opening, editing and clearing never publish filters.
/// Calendar is captured once per draft so day controls and conversion agree.
struct SearchFiltersDraft {
    enum DatePreset: String, CaseIterable, Identifiable {
        case any, thisYear, lastYear, custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "不限日期"
            case .thisYear: return "今年"
            case .lastYear: return "去年"
            case .custom: return "自定义"
            }
        }
    }

    static let unavailableAlbumText = "所选相册不可用"
    static let emptyAlbumsText = "暂无可选相册。若仅允许访问部分照片，相册列表可能不完整。"
    let calendar: Calendar
    private(set) var filters: PhotoSearchFilters
    private(set) var datePreset: DatePreset
    private(set) var startEnabled: Bool
    private(set) var endEnabled: Bool
    private(set) var startDay: Date
    private(set) var endDay: Date
    private var dateIssue: String?

    var albumID: String? {
        get { filters.albumID }
        set { filters.albumID = newValue }
    }
    var imageKind: PhotoSearchImageKind {
        get { filters.imageKind }
        set { filters.imageKind = newValue }
    }

    init(filters: PhotoSearchFilters, calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.filters = filters
        datePreset = filters.startDate == nil && filters.endDateExclusive == nil ? .any : .custom
        startEnabled = filters.startDate != nil
        endEnabled = filters.endDateExclusive != nil
        startDay = calendar.startOfDay(for: now)
        endDay = startDay
        // Preserve supplied instants exactly until a date control is changed.
        // Invalid incoming dates get safe picker values but remain invalid filters.
        if let start = filters.startDate, start.timeIntervalSinceReferenceDate.isFinite {
            startDay = calendar.startOfDay(for: start)
        }
        if let end = filters.endDateExclusive, end.timeIntervalSinceReferenceDate.isFinite {
            let day = calendar.startOfDay(for: end)
            endDay = end == day ? (calendar.date(byAdding: .day, value: -1, to: day) ?? day) : day
        }
    }

    mutating func clear(now: Date = Date()) {
        self = SearchFiltersDraft(filters: PhotoSearchFilters(), calendar: calendar, now: now)
    }

    mutating func selectDatePreset(_ preset: DatePreset, now: Date = Date()) {
        datePreset = preset
        dateIssue = nil
        switch preset {
        case .any:
            startEnabled = false
            endEnabled = false
            filters.startDate = nil
            filters.endDateExclusive = nil
        case .custom:
            if !startEnabled && !endEnabled {
                startEnabled = true
                endEnabled = true
                updateCustomDates()
            }
        case .thisYear, .lastYear:
            guard let year = calendar.dateInterval(of: .year, for: now),
                  let previousYear = calendar.date(byAdding: .year, value: -1, to: year.start),
                  let interval = calendar.dateInterval(of: .year,
                    for: preset == .thisYear ? year.start : previousYear),
                  let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) else {
                dateIssue = "请选择有效的日期范围。"
                return
            }
            filters.startDate = interval.start
            filters.endDateExclusive = interval.end
            startEnabled = true
            endEnabled = true
            startDay = interval.start
            endDay = lastDay
        }
    }

    mutating func setStartEnabled(_ enabled: Bool) {
        startEnabled = enabled
        updateCustomDates()
    }

    mutating func setEndEnabled(_ enabled: Bool) {
        endEnabled = enabled
        updateCustomDates()
    }

    mutating func setStartDay(_ day: Date) {
        startDay = day
        updateCustomDates()
    }

    mutating func setEndDay(_ day: Date) {
        endDay = day
        updateCustomDates()
    }

    private mutating func updateCustomDates() {
        datePreset = .custom
        dateIssue = nil
        guard (!startEnabled || startDay.timeIntervalSinceReferenceDate.isFinite),
              (!endEnabled || endDay.timeIntervalSinceReferenceDate.isFinite) else {
            dateIssue = "请选择有效的日期范围。"
            return
        }
        if startEnabled { startDay = calendar.startOfDay(for: startDay) }
        if endEnabled { endDay = calendar.startOfDay(for: endDay) }
        filters.startDate = startEnabled ? calendar.startOfDay(for: startDay) : nil
        filters.endDateExclusive = nil
        if endEnabled {
            // The last displayed day is inclusive, even on 23/25-hour DST days.
            guard let end = calendar.date(byAdding: .day, value: 1,
                                          to: calendar.startOfDay(for: endDay)) else {
                dateIssue = "请选择有效的日期范围。"
                return
            }
            filters.endDateExclusive = end
        }
    }

    func selectedAlbumIsMissing(in albums: [PhotoAlbum]) -> Bool {
        guard let albumID else { return false }
        return !albums.contains { $0.id == albumID }
    }

    func validationMessage(albums: [PhotoAlbum], albumsLoading: Bool) -> String? {
        if let dateIssue { return dateIssue }
        if startEnabled && endEnabled && startDay > endDay {
            return "结束日期不能早于开始日期。"
        }
        do { try filters.validate() }
        catch { return error.localizedDescription }
        if !albumsLoading && selectedAlbumIsMissing(in: albums) {
            return Self.unavailableAlbumText
        }
        return nil
    }

    func canApply(albums: [PhotoAlbum], albumsLoading: Bool) -> Bool {
        validationMessage(albums: albums, albumsLoading: albumsLoading) == nil
            && !(albumsLoading && albumID != nil)
    }

    @discardableResult
    func apply(albums: [PhotoAlbum], albumsLoading: Bool,
               onApply: (PhotoSearchFilters) -> Void) -> Bool {
        guard canApply(albums: albums, albumsLoading: albumsLoading) else { return false }
        onApply(filters)
        return true
    }
}

/// The parent owns the collapsed entry chip and fetches albums outside this view.
/// Cancel/swipe dismissal discards the local draft; only Apply emits a value.
@MainActor
struct SearchFiltersSheet: View {
    let albums: [PhotoAlbum]
    let albumsLoading: Bool
    let albumIssue: String?
    private let onApply: (PhotoSearchFilters) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SearchFiltersDraft

    init(filters: PhotoSearchFilters, albums: [PhotoAlbum], albumsLoading: Bool = false,
         albumIssue: String? = nil, onApply: @escaping (PhotoSearchFilters) -> Void) {
        self.albums = albums
        self.albumsLoading = albumsLoading
        self.albumIssue = albumIssue
        self.onApply = onApply
        _draft = State(initialValue: SearchFiltersDraft(filters: filters))
    }

    var body: some View {
        NavigationStack {
            Form {
                dateSection
                albumSection
                Section("图片类型") {
                    Picker("类型", selection: $draft.imageKind) {
                        ForEach(PhotoSearchImageKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("search-filter-image-kind")
                }
                .listRowBackground(IQStyle.surface)
                Section {
                    if let message = draft.validationMessage(albums: albums, albumsLoading: albumsLoading) {
                        Text(message)
                            .foregroundStyle(IQStyle.warning)
                            .accessibilityIdentifier("search-filter-validation")
                    }
                    Button("清除筛选") { draft.clear() }
                        .accessibilityIdentifier("clear-search-filters")
                }
                .listRowBackground(IQStyle.surface)
            }
            .scrollContentBackground(.hidden)
            .background(IQStyle.background)
            .foregroundStyle(IQStyle.text)
            .navigationTitle("筛选照片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .accessibilityIdentifier("cancel-search-filters")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        if draft.apply(albums: albums, albumsLoading: albumsLoading, onApply: onApply) {
                            dismiss()
                        }
                    }
                    .disabled(!draft.canApply(albums: albums, albumsLoading: albumsLoading))
                    .accessibilityIdentifier("apply-search-filters")
                }
            }
        }
        .tint(IQStyle.accent)
    }

    private var dateSection: some View {
        Section {
            Picker("日期范围", selection: Binding(get: { draft.datePreset }, set: { draft.selectDatePreset($0) })) {
                ForEach(SearchFiltersDraft.DatePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("search-filter-date-preset")
            if draft.datePreset == .custom {
                Toggle("设置开始日期", isOn: Binding(get: { draft.startEnabled }, set: { draft.setStartEnabled($0) }))
                    .accessibilityIdentifier("search-filter-start-enabled")
                if draft.startEnabled {
                    DatePicker("开始日期", selection: Binding(get: { draft.startDay }, set: { draft.setStartDay($0) }),
                               displayedComponents: .date)
                        .accessibilityIdentifier("search-filter-start-day")
                }
                Toggle("设置结束日期", isOn: Binding(get: { draft.endEnabled }, set: { draft.setEndEnabled($0) }))
                    .accessibilityIdentifier("search-filter-end-enabled")
                if draft.endEnabled {
                    DatePicker("结束日期", selection: Binding(get: { draft.endDay }, set: { draft.setEndDay($0) }),
                               displayedComponents: .date)
                        .accessibilityIdentifier("search-filter-end-day")
                }
            }
        } header: {
            Text("拍摄日期")
        } footer: {
            if draft.datePreset == .custom { Text("包含开始和结束当天；关闭某一项则不限该边界。") }
        }
        .environment(\.calendar, draft.calendar)
        .environment(\.timeZone, draft.calendar.timeZone)
        .listRowBackground(IQStyle.surface)
    }

    private var albumSection: some View {
        Section {
            Picker("相册", selection: $draft.albumID) {
                Text("全部相册").tag(String?.none)
                if let id = draft.albumID, draft.selectedAlbumIsMissing(in: albums) {
                    // Keep a matching optional tag: a vanished ID must NEVER become nil.
                    Text(albumsLoading ? "正在确认所选相册…" : SearchFiltersDraft.unavailableAlbumText)
                        .tag(Optional(id))
                        .disabled(true)
                }
                ForEach(albums) { album in
                    Text(album.title).tag(Optional(album.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("search-filter-album")
            if albumsLoading {
                ProgressView("正在加载相册…")
                    .accessibilityIdentifier("search-filter-albums-loading")
            } else if albums.isEmpty {
                Text(SearchFiltersDraft.emptyAlbumsText)
                    .font(.footnote).foregroundStyle(IQStyle.secondary)
            }
            if let albumIssue {
                Text(IQStyle.diagnosticText(albumIssue))
                    .foregroundStyle(IQStyle.warning)
                    .accessibilityIdentifier("search-filter-album-issue")
            }
        } header: {
            Text("系统相册")
        }
        .listRowBackground(IQStyle.surface)
    }
}