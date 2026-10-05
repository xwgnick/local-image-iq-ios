import Foundation
import Photos

/// Resolves current metadata only. The worker retains the complete accessible
/// indexed library for scoring, then intersects the globally ranked hits.
protocol PhotoSearchFiltering: Sendable {
    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String>
}

extension PhotoLibraryClient: PhotoSearchFiltering {
    func matchingPhotoIDs(filters: PhotoSearchFilters, snapshot: [PhotoRevision]) throws -> Set<String> {
        try Task.checkCancellation()
        try filters.validate()
        let snapshotIDs = Set(snapshot.map(\.id))
        guard !filters.isEmpty else { return snapshotIDs }

        // Query only an already-granted readWrite authorization. Never request
        // permission, register an observer or ask PhotoKit for image resources.
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorization == .authorized || authorization == .limited else { throw AppFailure.permission }
        let generation = changeGeneration
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        let assets: PHFetchResult<PHAsset>
        if let albumID = filters.albumID {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumID], options: nil).firstObject else {
                throw AppFailure.photo("所选相册已删除或无法访问，请重新选择相册。")
            }
            // An existing empty album is an empty result, NOT an absent filter.
            assets = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(snapshotIDs), options: options)
        }
        var matching = Set<String>()
        var interrupted = false
        assets.enumerateObjects { asset, _, stop in
            if Task.isCancelled { interrupted = true; stop.pointee = true; return }
            guard asset.mediaType == .image, snapshotIDs.contains(asset.localIdentifier),
                  filters.matches(creationDate: asset.creationDate,
                                  isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                  isLivePhoto: asset.mediaSubtypes.contains(.photoLive)) else { return }
            matching.insert(asset.localIdentifier)
        }
        guard !interrupted else { throw CancellationError() }
        try Task.checkCancellation()
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization,
              changeGeneration == generation else {
            throw AppFailure.photo("照片访问权限或相册已变化，请重新搜索。")
        }
        return matching
    }
}