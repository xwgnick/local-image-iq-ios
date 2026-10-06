/// Value-only range preview. No state controller, PhotoKit, geometry, row count,
/// keeper rule or group-size cap. IDs retain the supplied display order.
struct SimilarPhotoRangeSelection: Sendable {
    let anchorID: String
    let selects: Bool

    private let photoIDs: [String]
    private let indices: [String: Int]
    private let anchorIndex: Int
    private let baseSelectedIDs: Set<String>
    private var currentSelectedIDs: Set<String>

    init?(photoIDs: [String], selectedIDs: Set<String>, anchorID: String) {
        var indices: [String: Int] = [:]
        for (index, id) in photoIDs.enumerated() {
            guard !id.isEmpty, indices.updateValue(index, forKey: id) == nil else { return nil }
        }
        guard let anchorIndex = indices[anchorID] else { return nil }
        let base = selectedIDs.intersection(Set(photoIDs))
        self.photoIDs = photoIDs
        self.indices = indices
        self.anchorID = anchorID
        self.anchorIndex = anchorIndex
        self.baseSelectedIDs = base
        self.currentSelectedIDs = base
        self.selects = !base.contains(anchorID)
    }

    /// Each valid endpoint is recomputed from the immutable base, so skipping
    /// cells, reversing direction and crossing the anchor never toggle per hover.
    /// Unknown endpoints leave the current preview (initially the base) unchanged.
    func selection(throughID: String) -> Set<String> {
        guard let endpoint = indices[throughID] else { return currentSelectedIDs }
        let range = photoIDs[min(anchorIndex, endpoint)...max(anchorIndex, endpoint)]
        if selects { return baseSelectedIDs.union(range) }
        return baseSelectedIDs.subtracting(range)
    }

    @discardableResult
    mutating func update(throughID: String) -> Set<String> {
        currentSelectedIDs = selection(throughID: throughID)
        return currentSelectedIDs
    }
}