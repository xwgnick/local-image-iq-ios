import Foundation

/// Display-only projection. Canonical algorithm/cache ordering and the order of
/// every group's members remain untouched. Dates are photo creation/capture
/// times, never edits, index commits, or the time grouping completed.
enum SimilarGroupPresentation {
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