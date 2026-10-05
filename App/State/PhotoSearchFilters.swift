import Foundation

enum PhotoSearchImageKind: String, CaseIterable, Sendable, Identifiable {
    case all, photos, screenshots, livePhotos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部图片"
        case .photos: return "普通照片"
        case .screenshots: return "截屏"
        case .livePhotos: return "实况照片"
        }
    }

    /// Screenshot and Live Photo are independent PhotoKit subtype flags.
    /// Ordinary photos exclude BOTH; the two specialized filters may overlap.
    func matches(isScreenshot: Bool, isLivePhoto: Bool) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !isScreenshot && !isLivePhoto
        case .screenshots: return isScreenshot
        case .livePhotos: return isLivePhoto
        }
    }
}

struct PhotoSearchFilters: Equatable, Sendable {
    var startDate: Date? = nil
    var endDateExclusive: Date? = nil
    var albumID: String? = nil
    var imageKind: PhotoSearchImageKind = .all

    var isEmpty: Bool {
        startDate == nil && endDateExclusive == nil && albumID == nil && imageKind == .all
    }

    func validate() throws {
        if let startDate, !startDate.timeIntervalSinceReferenceDate.isFinite {
            throw PhotoSearchFilterError.invalidDateRange
        }
        if let endDateExclusive, !endDateExclusive.timeIntervalSinceReferenceDate.isFinite {
            throw PhotoSearchFilterError.invalidDateRange
        }
        if let startDate, let endDateExclusive, startDate >= endDateExclusive {
            throw PhotoSearchFilterError.invalidDateRange
        }
        if let albumID, albumID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PhotoSearchFilterError.invalidAlbumID
        }
    }

    /// Call validate() first. Dates are absolute instants: [start, end).
    /// The UI must derive the next day's boundary with Calendar, NOT +86,400s.
    /// Missing creation dates match only when no date boundary is active.
    func contains(creationDate: Date?) -> Bool {
        guard startDate != nil || endDateExclusive != nil else { return true }
        guard let creationDate, creationDate.timeIntervalSinceReferenceDate.isFinite else { return false }
        if let startDate, creationDate < startDate { return false }
        if let endDateExclusive, creationDate >= endDateExclusive { return false }
        return true
    }

    /// Metadata-only portion. The worker must ALSO resolve albumID, reject a
    /// missing/inaccessible album, and intersect its current accessible images.
    func matches(creationDate: Date?, isScreenshot: Bool, isLivePhoto: Bool) -> Bool {
        contains(creationDate: creationDate)
            && imageKind.matches(isScreenshot: isScreenshot, isLivePhoto: isLivePhoto)
    }
}

enum PhotoSearchFilterError: Error, Equatable, Sendable, LocalizedError {
    case invalidDateRange, invalidAlbumID

    var errorDescription: String? {
        switch self {
        case .invalidDateRange: return "请选择有效的日期范围。"
        case .invalidAlbumID: return "请选择有效的相册。"
        }
    }
}