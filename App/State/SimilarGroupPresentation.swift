import Foundation

/// Display-only projection. Canonical algorithm/cache ordering and the order of
/// every group's members remain untouched. Dates are photo creation/capture
/// times, never edits, index commits, or the time grouping completed.
enum SimilarGroupPresentation {
    enum Selection: Equatable { case none, partial, all }

    struct SelectionSummary: Equatable {
        var groupCount = 0
        var photoCount = 0
        var fullGroupCount = 0
        var hiddenGroupCount = 0
        var hiddenPhotoCount = 0
    }

    static func selection(in group: SimilarPhotoGroup, selectedIDs: Set<String>) -> Selection {
        let count = group.photos.filter { selectedIDs.contains($0.id) }.count
        if count == 0 { return .none }
        return count == group.photos.count ? .all : .partial
    }

    static func selectionSummary(_ groups: [SimilarPhotoGroup], selectedIDs: Set<String>,
                                 minimumCount: Int) -> SelectionSummary {
        var summary = SelectionSummary()
        for group in groups {
            let count = group.photos.filter { selectedIDs.contains($0.id) }.count
            guard count > 0 else { continue }
            summary.groupCount += 1
            summary.photoCount += count
            if count == group.photos.count { summary.fullGroupCount += 1 }
            if group.photos.count < minimumCount {
                summary.hiddenGroupCount += 1
                summary.hiddenPhotoCount += count
            }
        }
        return summary
    }

    static func visibleGroups(_ groups: [SimilarPhotoGroup], minimumCount: Int) -> [SimilarPhotoGroup] {
        groups.filter { $0.photos.count >= minimumCount }
    }

    static func latestCreationTime(in group: SimilarPhotoGroup) -> TimeInterval? {
        group.photos.compactMap { photo -> TimeInterval? in
            guard let time = photo.creationTime, time.isFinite else { return nil }
            return time
        }.max()
    }

    static func sortedGroups(_ groups: [SimilarPhotoGroup]) -> [SimilarPhotoGroup] {
        // Extract dates once, not again for every comparator invocation.
        groups.map { (group: $0, latest: latestCreationTime(in: $0)) }.sorted { lhs, rhs in
            switch (lhs.latest, rhs.latest) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.group.photos.count != rhs.group.photos.count {
                    return lhs.group.photos.count > rhs.group.photos.count
                }
                return lhs.group.id < rhs.group.id
            }
        }.map { $0.group }
    }
}