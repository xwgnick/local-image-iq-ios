import XCTest
import Photos
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import LocalImageIQ

/// Synthetic metadata and temporary files ONLY. No system album enumeration,
/// permission prompts, downloads, or actual Photos mutations in this suite.
final class PhotoLibraryActionsTests: XCTestCase {
    func testDefaultFiltersAreEmptyAndEquatable() throws {
        let filters = PhotoSearchFilters()
        XCTAssertTrue(filters.isEmpty)
        XCTAssertEqual(filters, PhotoSearchFilters())
        XCTAssertNoThrow(try filters.validate())
        XCTAssertTrue(filters.contains(creationDate: nil))
    }

    func testEveryFilterFieldMakesFiltersNonempty() {
        XCTAssertFalse(PhotoSearchFilters(startDate: Date()).isEmpty)
        XCTAssertFalse(PhotoSearchFilters(endDateExclusive: Date()).isEmpty)
        XCTAssertFalse(PhotoSearchFilters(albumID: "album").isEmpty)
        XCTAssertFalse(PhotoSearchFilters(imageKind: .photos).isEmpty)
    }

    func testDateRangeHasClosedStartAndExclusiveEnd() throws {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let filters = PhotoSearchFilters(startDate: start, endDateExclusive: end)
        try filters.validate()
        XCTAssertFalse(filters.contains(creationDate: start.addingTimeInterval(-0.001)))
        XCTAssertTrue(filters.contains(creationDate: start))
        XCTAssertTrue(filters.contains(creationDate: end.addingTimeInterval(-0.001)))
        XCTAssertFalse(filters.contains(creationDate: end))
        XCTAssertFalse(filters.contains(creationDate: nil))
    }

    func testOpenEndedDateRangesAndMissingDates() throws {
        let boundary = Date(timeIntervalSince1970: 100)
        let after = PhotoSearchFilters(startDate: boundary)
        let before = PhotoSearchFilters(endDateExclusive: boundary)
        try after.validate()
        try before.validate()
        XCTAssertTrue(after.contains(creationDate: boundary))
        XCTAssertFalse(before.contains(creationDate: boundary))
        XCTAssertTrue(before.contains(creationDate: .distantPast))
        XCTAssertTrue(after.contains(creationDate: .distantFuture))
        XCTAssertFalse(after.contains(creationDate: nil))
        XCTAssertFalse(before.contains(creationDate: nil))
    }

    func testEqualAndReversedDateBoundariesAreInvalid() {
        let start = Date(timeIntervalSince1970: 100)
        for end in [start, start.addingTimeInterval(-1)] {
            XCTAssertThrowsError(try PhotoSearchFilters(startDate: start, endDateExclusive: end).validate()) {
                XCTAssertEqual($0 as? PhotoSearchFilterError, .invalidDateRange)
            }
        }
    }

    func testNonfiniteDateBoundariesAreInvalid() {
        for value in [Double.nan, .infinity, -.infinity] {
            let date = Date(timeIntervalSinceReferenceDate: value)
            XCTAssertThrowsError(try PhotoSearchFilters(startDate: date).validate())
            XCTAssertThrowsError(try PhotoSearchFilters(endDateExclusive: date).validate())
            XCTAssertFalse(PhotoSearchFilters(startDate: .distantPast).contains(creationDate: date))
        }
    }

    func testSpringDSTDayUsesCalendarBoundaryNot24Hours() throws {
        try assertCalendarDay(year: 2026, month: 3, day: 8, hours: 23)
    }

    func testAutumnDSTDayUsesCalendarBoundaryNot24Hours() throws {
        try assertCalendarDay(year: 2026, month: 11, day: 1, hours: 25)
    }

    func testFilterAlbumIDIsOpaqueButCannotBeBlank() throws {
        for id in ["", " \n\t "] {
            XCTAssertThrowsError(try PhotoSearchFilters(albumID: id).validate()) {
                XCTAssertEqual($0 as? PhotoSearchFilterError, .invalidAlbumID)
            }
        }
        let filters = PhotoSearchFilters(albumID: "opaque/album-ID")
        try filters.validate()
        XCTAssertEqual(filters.albumID, "opaque/album-ID")
        // This helper deliberately does not pretend to resolve album membership.
        XCTAssertTrue(filters.matches(creationDate: nil, isScreenshot: false, isLivePhoto: false))
    }

    func testImageKindFlagsIncludingOverlap() {
        for screenshot in [false, true] {
            for live in [false, true] {
                XCTAssertTrue(PhotoSearchImageKind.all.matches(isScreenshot: screenshot, isLivePhoto: live))
                XCTAssertEqual(PhotoSearchImageKind.photos.matches(isScreenshot: screenshot, isLivePhoto: live),
                               !screenshot && !live)
                XCTAssertEqual(PhotoSearchImageKind.screenshots.matches(isScreenshot: screenshot, isLivePhoto: live),
                               screenshot)
                XCTAssertEqual(PhotoSearchImageKind.livePhotos.matches(isScreenshot: screenshot, isLivePhoto: live), live)
            }
        }
    }

    func testImageKindsHaveStableIDsAndChineseTitles() {
        XCTAssertEqual(PhotoSearchImageKind.allCases.map(\.id), ["all", "photos", "screenshots", "livePhotos"])
        XCTAssertEqual(PhotoSearchImageKind.allCases.map(\.title), ["全部图片", "普通照片", "截屏", "实况照片"])
    }

    func testDateAndTypePredicatesIntersect() {
        let start = Date(timeIntervalSince1970: 100)
        let filters = PhotoSearchFilters(startDate: start, imageKind: .photos)
        XCTAssertTrue(filters.matches(creationDate: start, isScreenshot: false, isLivePhoto: false))
        XCTAssertFalse(filters.matches(creationDate: start, isScreenshot: true, isLivePhoto: false))
        XCTAssertFalse(filters.matches(creationDate: start.addingTimeInterval(-1), isScreenshot: false, isLivePhoto: false))
    }

    func testSelectionDeduplicatesWithoutChangingOrderOrIdentifiers() throws {
        XCTAssertEqual(try PhotoActionValidation.orderedUniqueIDs(["b/id", "a/id", "b/id", "c/id", "a/id"]),
                       ["b/id", "a/id", "c/id"])
    }

    func testEmptyAndBlankSelectionsAreRejected() {
        XCTAssertThrowsError(try PhotoActionValidation.orderedUniqueIDs([])) {
            XCTAssertEqual($0 as? PhotoLibraryActionError, .emptySelection)
        }
        for ids in [[""], ["a", " \t\n"], ["a", ""]] {
            XCTAssertThrowsError(try PhotoActionValidation.orderedUniqueIDs(ids)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .invalidIdentifier)
            }
        }
    }

    func testSelectionHasNoInventedBatchLimit() throws {
        let ids = (0..<10_001).map { "synthetic-\($0)" }
        XCTAssertEqual(try PhotoActionValidation.orderedUniqueIDs(ids + ids), ids)
    }

    func testAlbumTitleIsTrimmedWithoutAnInventedLengthLimit() throws {
        let title = String(repeating: "相", count: 2_048)
        let action = try PhotoActionValidation.normalized(.createAlbum(" \n\(title)\t "))
        guard case .createAlbum(let actual) = action else { return XCTFail("Wrong action") }
        XCTAssertEqual(actual, title)
    }

    func testBlankAlbumTitlesAndTargetIDsAreRejected() {
        for value in ["", " \n\t "] {
            XCTAssertThrowsError(try PhotoActionValidation.normalized(.createAlbum(value))) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .emptyAlbumTitle)
            }
            XCTAssertThrowsError(try PhotoActionValidation.normalized(.addToAlbum(value))) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .invalidIdentifier)
            }
        }
    }

    func testOnlyFullAndLimitedReadWriteAuthorizationPass() {
        for status in [PHAuthorizationStatus.authorized, .limited] {
            XCTAssertNoThrow(try PhotoActionValidation.requireAccess(status))
        }
        for status in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
            XCTAssertThrowsError(try PhotoActionValidation.requireAccess(status)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .permissionDenied)
            }
        }
    }

    func testPlanPreservesFavoriteIntentAndSelectionOrder() throws {
        for favorite in [true, false] {
            let plan = try PhotoBatchMutationPlan(action: .favorite(favorite), ids: ["b", "a", "b"],
                assets: [asset("a"), asset("b")], authorization: .limited)
            XCTAssertEqual(plan.assetIDs, ["b", "a"])
            guard case .favorite(let actual) = plan.action else { return XCTFail("Wrong action") }
            XCTAssertEqual(actual, favorite)
        }
    }

    func testEveryActionRejectsAnyMissingSelectedAsset() {
        for action in [PhotoBatchAction.favorite(true), .addToAlbum("album"), .createAlbum("New")] {
            XCTAssertThrowsError(try PhotoBatchMutationPlan(action: action, ids: ["a", "missing"],
                assets: [asset("a")], album: PhotoAlbum(id: "album", title: "Album", canAdd: true),
                authorization: .authorized)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .unavailableAssets)
            }
        }
    }

    func testEveryActionRejectsNonimageAssets() {
        for action in [PhotoBatchAction.favorite(true), .addToAlbum("album"), .createAlbum("New")] {
            XCTAssertThrowsError(try PhotoBatchMutationPlan(action: action, ids: ["video"],
                assets: [asset("video", isImage: false)],
                album: PhotoAlbum(id: "album", title: "Album", canAdd: true), authorization: .authorized)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .unavailableAssets)
            }
        }
    }

    func testFavoriteRequiresPropertiesCapabilityForEveryAsset() {
        for value in [true, false] {
            XCTAssertThrowsError(try PhotoBatchMutationPlan(action: .favorite(value), ids: ["a", "b"],
                assets: [asset("a"), asset("b", canFavorite: false)], authorization: .authorized)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError, .favoriteUnavailable)
            }
        }
    }

    func testAlbumAdditionDoesNotRequireFavoriteCapability() throws {
        let plan = try PhotoBatchMutationPlan(action: .addToAlbum("album"), ids: ["a"],
            assets: [asset("a", canFavorite: false)],
            album: PhotoAlbum(id: "album", title: "Album", canAdd: true), authorization: .limited)
        guard case .addToAlbum(let id) = plan.action else { return XCTFail("Wrong action") }
        XCTAssertEqual(id, "album")
    }

    func testAlbumAdditionRejectsMissingMismatchedAndReadonlyTargets() {
        let targets: [PhotoAlbum?] = [nil, PhotoAlbum(id: "other", title: "Other", canAdd: true),
                                     PhotoAlbum(id: "album", title: "Favorites", canAdd: false)]
        for target in targets {
            XCTAssertThrowsError(try PhotoBatchMutationPlan(action: .addToAlbum("album"), ids: ["a"],
                assets: [asset("a")], album: target, authorization: .authorized)) {
                XCTAssertEqual($0 as? PhotoLibraryActionError,
                               target?.id == "album" ? .albumNotEditable : .albumUnavailable)
            }
        }
    }

    func testCreatePlanCannotExistForEmptySelection() {
        XCTAssertThrowsError(try PhotoBatchMutationPlan(action: .createAlbum("New"), ids: [],
            assets: [], authorization: .authorized)) {
            XCTAssertEqual($0 as? PhotoLibraryActionError, .emptySelection)
        }
    }

    func testCreatePlanIncludesAllAssetsAndNormalizedTitle() throws {
        let plan = try PhotoBatchMutationPlan(action: .createAlbum("  假日 \n"), ids: ["b", "a"],
            assets: [asset("a"), asset("b")], authorization: .authorized)
        XCTAssertEqual(plan.assetIDs, ["b", "a"])
        guard case .createAlbum(let title) = plan.action else { return XCTFail("Wrong action") }
        XCTAssertEqual(title, "假日")
    }

    func testPlanRejectsDeniedAuthorizationBeforeMutation() {
        XCTAssertThrowsError(try PhotoBatchMutationPlan(action: .createAlbum("New"), ids: ["a"],
            assets: [asset("a")], authorization: .denied)) {
            XCTAssertEqual($0 as? PhotoLibraryActionError, .permissionDenied)
        }
    }

    func testAlbumsDeduplicateAndUseStableTieOrder() {
        let a = PhotoAlbum(id: "a", title: "Same", canAdd: false)
        let b = PhotoAlbum(id: "b", title: "Same", canAdd: true)
        XCTAssertEqual(PhotoActionValidation.sortedAlbums([b, a, b, a]), [a, b])
        let titles = [PhotoAlbum(id: "2", title: "Z", canAdd: true),
                      PhotoAlbum(id: "1", title: "A", canAdd: true)]
        XCTAssertEqual(PhotoActionValidation.sortedAlbums(titles).map(\.title), ["A", "Z"])
    }

    func testCancellationBeforeQueuedMutationPreventsBeginning() {
        let gate = PhotoMutationGate()
        gate.cancel()
        XCTAssertThrowsError(try gate.checkCancellation()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try gate.beginMutation()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try gate.result(success: true).get()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testCancellationAfterMutationBeginsDoesNotHideSuccess() throws {
        let gate = PhotoMutationGate()
        try gate.beginMutation()
        gate.cancel()
        XCTAssertNoThrow(try gate.result(success: true).get())
    }

    func testCancellationAfterMutationBeginsDoesNotHidePhotosFailure() throws {
        let gate = PhotoMutationGate()
        try gate.beginMutation()
        gate.cancel()
        XCTAssertThrowsError(try gate.result(success: false).get()) {
            XCTAssertEqual($0 as? PhotoLibraryActionError, .mutationFailed)
        }
    }

    func testBlockPreflightFailureIsNotReportedAsSuccessfulEmptyTransaction() {
        let gate = PhotoMutationGate()
        gate.recordFailure(PhotoLibraryActionError.unavailableAssets)
        XCTAssertThrowsError(try gate.result(success: true).get()) {
            XCTAssertEqual($0 as? PhotoLibraryActionError, .unavailableAssets)
        }
    }

    func testShareWritesUniqueSelectionSequentiallyWithAnonymousNames() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        let share = try await PhotoSharePreparer.prepare(ids: ["b/private-id", "a/private-id", "b/private-id"],
            temporaryRoot: root, validate: { recorder.validate($0) }, write: { id, url in
                recorder.record(id)
                try Data([1, 2, 3]).write(to: url)
                await Task.yield()
            })
        defer { share.cleanup() }
        XCTAssertEqual(share.assetIDs, ["b/private-id", "a/private-id"])
        XCTAssertEqual(recorder.writes, share.assetIDs)
        XCTAssertEqual(recorder.validations, [share.assetIDs, [share.assetIDs[0]], [share.assetIDs[0]],
                                             [share.assetIDs[1]], [share.assetIDs[1]], share.assetIDs])
        XCTAssertEqual(share.urls.map(\.lastPathComponent), ["photo-001.jpg", "photo-002.jpg"])
        XCTAssertTrue(share.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let directory = try XCTUnwrap(share.urls.first).deletingLastPathComponent()
        XCTAssertTrue(directory.lastPathComponent.contains(share.id.uuidString))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testShareInitialValidationFailureCreatesNoDirectoryOrFiles() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        do {
            _ = try await PhotoSharePreparer.prepare(ids: ["a", "missing"], temporaryRoot: root,
                validate: { _ in throw PhotoLibraryActionError.unavailableAssets }, write: { id, _ in recorder.record(id) })
            XCTFail("Invalid selection must not prepare a share")
        } catch { XCTAssertEqual(error as? PhotoLibraryActionError, .unavailableAssets) }
        XCTAssertTrue(recorder.writes.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareFailureRemovesCompletedAndPartialFilesAndSanitizesError() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        do {
            _ = try await PhotoSharePreparer.prepare(ids: ["a", "b", "c"], temporaryRoot: root,
                validate: { _ in }, write: { id, url in
                    recorder.record(id)
                    try Data([7]).write(to: url)
                    if id == "b" { throw NSError(domain: "synthetic-private-path", code: 1) }
                })
            XCTFail("Partial share must not be returned")
        } catch { XCTAssertEqual(error as? PhotoLibraryActionError, .sharePreparationFailed) }
        XCTAssertEqual(recorder.writes, ["a", "b"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareRevalidatesAccessImmediatelyAfterEachWrite() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        do {
            _ = try await PhotoSharePreparer.prepare(ids: ["a", "b"], temporaryRoot: root,
                validate: { _ in
                    if !recorder.writes.isEmpty { throw PhotoLibraryActionError.accessChanged }
                }, write: { id, url in
                    recorder.record(id)
                    try Data([1]).write(to: url)
                })
            XCTFail("Revoked access must discard temporary files")
        } catch { XCTAssertEqual(error as? PhotoLibraryActionError, .accessChanged) }
        XCTAssertEqual(recorder.writes, ["a"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareRevalidatesWholeSelectionAfterAllWrites() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        do {
            _ = try await PhotoSharePreparer.prepare(ids: ["a", "b"], temporaryRoot: root,
                validate: { ids in
                    if ids.count == 2, recorder.writes.count == 2 { throw PhotoLibraryActionError.accessChanged }
                }, write: { id, url in
                    recorder.record(id)
                    try Data([1]).write(to: url)
                })
            XCTFail("Final access check must prevent publication")
        } catch { XCTAssertEqual(error as? PhotoLibraryActionError, .accessChanged) }
        XCTAssertEqual(recorder.writes, ["a", "b"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareCancellationBeforePreparationDoesNotCreateFiles() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task<PreparedPhotoShare, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PhotoSharePreparer.prepare(ids: ["a"], temporaryRoot: root,
                validate: { _ in XCTFail("Cancelled preparation must not read assets") },
                write: { _, _ in XCTFail("Cancelled preparation must not write") })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareCancellationDuringWriteCleansUpAndStopsNextImage() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ShareTestRecorder()
        let task = Task<PreparedPhotoShare, Error> {
            try await PhotoSharePreparer.prepare(ids: ["a", "b"], temporaryRoot: root,
                validate: { _ in }, write: { id, url in
                    recorder.record(id)
                    try Data([1]).write(to: url)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(recorder.writes, ["a"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testShareCleanupIsConcurrentIdempotentAndDoesNotDeleteSiblingShare() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await makeShare(root: root)
        let second = try await makeShare(root: root)
        defer { first.cleanup(); second.cleanup() }
        XCTAssertNotEqual(first.id, second.id)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in first.cleanup() }
        first.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first.urls.first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(second.urls.first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testShareDeinitializationReleasesItsTemporaryDirectory() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var share: PreparedPhotoShare? = try await makeShare(root: root)
        weak var weakShare = share
        let directory = try XCTUnwrap(share?.urls.first).deletingLastPathComponent()
        share = nil
        XCTAssertNil(weakShare)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testShareErrorsPreserveCancellationAndCloudOptInMeaningWithoutRawDetails() {
        XCTAssertTrue(PhotoSharePreparer.sanitizedError(CancellationError()) is CancellationError)
        XCTAssertEqual(PhotoSharePreparer.sanitizedError(AppFailure.cloudOnly) as? PhotoLibraryActionError, .cloudOnly)
        XCTAssertEqual(PhotoSharePreparer.sanitizedError(AppFailure.permission) as? PhotoLibraryActionError, .permissionDenied)
        let raw = NSError(domain: "private-file-path", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-id"])
        let sanitized = PhotoSharePreparer.sanitizedError(raw)
        XCTAssertEqual(sanitized as? PhotoLibraryActionError, .sharePreparationFailed)
        XCTAssertFalse(sanitized.localizedDescription.contains("private"))
    }

    func testJPEGWriterStripsSyntheticGPSAndKeepsPixelDimensions() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try TestFixtures.image(width: 6, height: 4) { _, _ in (180, 70, 30) }
        let sourceData = try XCTUnwrap(CFDataCreateMutable(kCFAllocatorDefault, 0))
        let source = try XCTUnwrap(CGImageDestinationCreateWithData(sourceData,
            UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 1.0, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.0, kCGImagePropertyGPSLongitudeRef: "E"]]
        CGImageDestinationAddImage(source, pixels, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(source))
        let original = try XCTUnwrap(CGImageSourceCreateWithData(sourceData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        let image = try XCTUnwrap(UIImage(data: sourceData as Data))
        let url = root.appendingPathComponent("rendered.jpg")
        try await PhotoShareJPEGWriter.write(image: image, to: url)
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertEqual((metadata[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 6)
        XCTAssertEqual((metadata[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 4)
        let orientation = (metadata[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        XCTAssertTrue(orientation == nil || orientation == 1)
    }

    func testJPEGWriterNormalizesRotatedImageUsingExistingRenderPolicy() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pixels = try TestFixtures.image(width: 6, height: 4) { x, _ in x < 3 ? (255, 0, 0) : (0, 0, 255) }
        let image = UIImage(cgImage: pixels, scale: 1, orientation: .right)
        let expectedSize = await MainActor.run {
            PhotoShareSheet.renderedCopy(of: image).size
        }
        let url = root.appendingPathComponent("rotated.jpg")
        try await PhotoShareJPEGWriter.write(image: image, to: url)
        let exported = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        XCTAssertEqual(exported.imageOrientation, .up)
        XCTAssertEqual(exported.size, expectedSize)
    }

    private func asset(_ id: String, isImage: Bool = true, canFavorite: Bool = true) -> PhotoBatchAssetState {
        PhotoBatchAssetState(id: id, isImage: isImage, canFavorite: canFavorite)
    }

    private func assertCalendarDay(year: Int, month: Int, day: Int, hours: Double) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), hours * 3_600)
        let filters = PhotoSearchFilters(startDate: start, endDateExclusive: end)
        try filters.validate()
        XCTAssertTrue(filters.contains(creationDate: start))
        XCTAssertTrue(filters.contains(creationDate: end.addingTimeInterval(-1)))
        XCTAssertFalse(filters.contains(creationDate: end))
    }

    private func makeShare(root: URL) async throws -> PreparedPhotoShare {
        try await PhotoSharePreparer.prepare(ids: ["synthetic"], temporaryRoot: root,
            validate: { _ in }, write: { _, url in try Data([1]).write(to: url) })
    }
}

private final class ShareTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var written: [String] = []
    private var checked: [[String]] = []

    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    var validations: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return checked
    }

    func record(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        written.append(id)
    }

    func validate(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        checked.append(ids)
    }
}