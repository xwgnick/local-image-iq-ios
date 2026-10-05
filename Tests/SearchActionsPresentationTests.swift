import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Pure draft/callback contracts plus exactly TWO shallow native review captures.
/// No AppState, Photos reads/writes, permission changes, models, database or network.
/// Share tests use disposable synthetic bytes, never actual photo resources.
/// Captures are 393x852 app-hosted fixtures, NOT XCUI, golden baselines or device proof.
@MainActor
final class SearchActionsPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let albums = [
        PhotoAlbum(id: "fixture/travel", title: "旅行", canAdd: true),
        PhotoAlbum(id: "fixture/family", title: "家人", canAdd: true),
        PhotoAlbum(id: "fixture/read-only", title: "只读相册（不可加入）", canAdd: false)
    ]

    func testDefaultDraftHasNoFiltersAndConstructingSheetsDoesNotCallBack() throws {
        let draft = try makeDraft()
        XCTAssertTrue(draft.filters.isEmpty)
        XCTAssertEqual(draft.datePreset, .any)
        XCTAssertFalse(draft.startEnabled)
        XCTAssertFalse(draft.endEnabled)
        XCTAssertNil(draft.albumID)
        XCTAssertEqual(draft.imageKind, .all)
        XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
        _ = SearchFiltersSheet(filters: draft.filters, albums: []) { _ in XCTFail("Opening is not Apply") }
        _ = AlbumActionSheet(albums: albums) { _ in XCTFail("Opening must not request an action") }
    }

    func testEditingIsLocalUntilExplicitApplyCallback() throws {
        let original = PhotoSearchFilters(imageKind: .photos)
        var draft = try makeDraft(original)
        var applied: [PhotoSearchFilters] = []
        draft.albumID = albums[0].id
        draft.imageKind = .screenshots
        draft.selectDatePreset(.thisYear, now: try day(2026, 10, 5))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(original, PhotoSearchFilters(imageKind: .photos))
        XCTAssertTrue(draft.apply(albums: albums, albumsLoading: false) { applied.append($0) })
        XCTAssertEqual(applied, [draft.filters])
        XCTAssertEqual(applied.first?.albumID, albums[0].id)
        XCTAssertEqual(applied.first?.imageKind, .screenshots)
    }

    func testClearResetsFiltersAndAllDateFieldsWithoutPublishing() throws {
        var draft = try makeDraft(PhotoSearchFilters(albumID: "missing", imageKind: .livePhotos))
        let now = try day(2026, 10, 5, hour: 15)
        draft.selectDatePreset(.custom, now: now)
        draft.setStartDay(try day(2026, 12, 2))
        draft.setEndDay(try day(2026, 12, 1))
        XCTAssertNotNil(draft.validationMessage(albums: [], albumsLoading: false))
        var applied: [PhotoSearchFilters] = []
        draft.clear(now: now)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(draft.filters, PhotoSearchFilters())
        XCTAssertEqual(draft.datePreset, .any)
        XCTAssertFalse(draft.startEnabled)
        XCTAssertFalse(draft.endEnabled)
        XCTAssertEqual(draft.startDay, try day(2026, 10, 5))
        XCTAssertEqual(draft.endDay, draft.startDay)
        XCTAssertNil(draft.validationMessage(albums: [], albumsLoading: false))
        XCTAssertTrue(draft.apply(albums: [], albumsLoading: false) { applied.append($0) })
        XCTAssertEqual(applied, [PhotoSearchFilters()])
    }

    func testAnyDatePresetRemovesOnlyDateBounds() throws {
        var draft = try makeDraft(PhotoSearchFilters(albumID: albums[0].id, imageKind: .photos))
        draft.selectDatePreset(.lastYear, now: try day(2026, 10, 5))
        draft.selectDatePreset(.any)
        XCTAssertNil(draft.filters.startDate)
        XCTAssertNil(draft.filters.endDateExclusive)
        XCTAssertFalse(draft.startEnabled)
        XCTAssertFalse(draft.endEnabled)
        XCTAssertEqual(draft.albumID, albums[0].id)
        XCTAssertEqual(draft.imageKind, .photos)
    }

    func testYearPresetsUseCalendarIntervalStartsNotCurrentDSTOffset() throws {
        // October is PDT; Jan 1 is PST. Reusing October's offset would be wrong.
        let now = try day(2026, 10, 5, hour: 15)
        let calendar = try fixedCalendar()
        XCTAssertNotEqual(calendar.timeZone.secondsFromGMT(for: now),
                          calendar.timeZone.secondsFromGMT(for: try day(2026, 1, 1)))
        let cases: [(SearchFiltersDraft.DatePreset, Int)] = [(.thisYear, 2026), (.lastYear, 2025)]
        for (preset, year) in cases {
            var draft = try makeDraft()
            draft.selectDatePreset(preset, now: now)
            XCTAssertEqual(draft.datePreset, preset)
            XCTAssertEqual(draft.filters.startDate, try day(year, 1, 1))
            XCTAssertEqual(draft.filters.endDateExclusive, try day(year + 1, 1, 1))
            XCTAssertEqual(draft.startDay, try day(year, 1, 1))
            XCTAssertEqual(draft.endDay, try day(year, 12, 31))
            XCTAssertTrue(draft.filters.contains(creationDate: try day(year, 12, 31, hour: 23)))
            XCTAssertFalse(draft.filters.contains(creationDate: try day(year + 1, 1, 1)))
            XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
        }
    }

    func testLastYearIncludesLeapDayWithoutFixedYearDuration() throws {
        var draft = try makeDraft()
        draft.selectDatePreset(.lastYear, now: try day(2025, 10, 5))
        XCTAssertEqual(draft.filters.startDate, try day(2024, 1, 1))
        XCTAssertEqual(draft.filters.endDateExclusive, try day(2025, 1, 1))
        XCTAssertTrue(draft.filters.contains(creationDate: try day(2024, 2, 29, hour: 12)))
    }

    func testCustomSameDayIsInclusiveAndNormalizesPickerTimes() throws {
        var draft = try makeDraft()
        draft.selectDatePreset(.custom)
        draft.setStartDay(try day(2026, 10, 5, hour: 18))
        draft.setEndDay(try day(2026, 10, 5, hour: 2))
        XCTAssertEqual(draft.startDay, try day(2026, 10, 5))
        XCTAssertEqual(draft.endDay, draft.startDay)
        XCTAssertEqual(draft.filters.startDate, try day(2026, 10, 5))
        XCTAssertEqual(draft.filters.endDateExclusive, try day(2026, 10, 6))
        XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
        XCTAssertTrue(draft.filters.contains(creationDate: try day(2026, 10, 5, hour: 23)))
        XCTAssertFalse(draft.filters.contains(creationDate: try day(2026, 10, 6)))
    }

    func testCustomInclusiveEndHandlesBothDSTTransitionsIn2026() throws {
        for (month, date, hours) in [(3, 8, 23), (11, 1, 25)] {
            let start = try day(2026, month, date)
            let end = try day(2026, month, date + 1)
            var draft = try makeDraft()
            draft.selectDatePreset(.custom)
            draft.setStartDay(start)
            draft.setEndDay(start)
            XCTAssertEqual(draft.filters.startDate, start)
            XCTAssertEqual(draft.filters.endDateExclusive, end)
            XCTAssertEqual(end.timeIntervalSince(start), Double(hours) * 3_600)
            XCTAssertTrue(draft.filters.contains(creationDate: end.addingTimeInterval(-1)))
            XCTAssertFalse(draft.filters.contains(creationDate: end))
            // Reopening maps the exclusive boundary back to the same inclusive day.
            let reopened = try makeDraft(draft.filters)
            XCTAssertEqual(reopened.endDay, start)
            XCTAssertEqual(reopened.filters, draft.filters)
        }
    }

    func testCustomTogglesAllowBothOpenEndedRangesAndNoBounds() throws {
        var draft = try makeDraft()
        draft.selectDatePreset(.custom)
        let start = draft.filters.startDate
        let end = draft.filters.endDateExclusive
        draft.setStartEnabled(false)
        XCTAssertNil(draft.filters.startDate)
        XCTAssertEqual(draft.filters.endDateExclusive, end)
        draft.setStartEnabled(true)
        draft.setEndEnabled(false)
        XCTAssertEqual(draft.filters.startDate, start)
        XCTAssertNil(draft.filters.endDateExclusive)
        draft.setStartEnabled(false)
        XCTAssertTrue(draft.filters.isEmpty)
        XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
    }

    func testInvalidDateRangeShowsInlineMessageAndCannotEmitCallback() throws {
        var draft = try makeDraft()
        draft.selectDatePreset(.custom)
        draft.setStartDay(try day(2026, 10, 6))
        draft.setEndDay(try day(2026, 10, 5))
        XCTAssertEqual(draft.validationMessage(albums: [], albumsLoading: false), "结束日期不能早于开始日期。")
        XCTAssertFalse(draft.canApply(albums: [], albumsLoading: false))
        XCTAssertFalse(draft.apply(albums: [], albumsLoading: false) { _ in XCTFail("Invalid range") })
        draft.setEndDay(try day(2026, 10, 6))
        XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
        let invalid = try makeDraft(PhotoSearchFilters(startDate: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertNotNil(invalid.validationMessage(albums: [], albumsLoading: false))
        XCTAssertFalse(invalid.apply(albums: [], albumsLoading: false) { _ in XCTFail("Nonfinite date") })
    }

    func testExistingPreciseBoundariesRoundTripUntilDateControlChanges() throws {
        let source = PhotoSearchFilters(startDate: try day(2026, 10, 1, hour: 9),
                                       endDateExclusive: try day(2026, 10, 5, hour: 15))
        var draft = try makeDraft(source)
        draft.imageKind = .photos
        var applied: PhotoSearchFilters?
        XCTAssertTrue(draft.apply(albums: [], albumsLoading: false) { applied = $0 })
        XCTAssertEqual(applied?.startDate, source.startDate)
        XCTAssertEqual(applied?.endDateExclusive, source.endDateExclusive)
        XCTAssertEqual(draft.endDay, try day(2026, 10, 5))
    }

    func testMissingAlbumRemainsSelectedUntilUserChoosesAnotherOption() throws {
        var draft = try makeDraft(PhotoSearchFilters(albumID: "unavailable/opaque-id"))
        XCTAssertTrue(draft.selectedAlbumIsMissing(in: albums))
        XCTAssertEqual(draft.validationMessage(albums: albums, albumsLoading: false), "所选相册不可用")
        XCTAssertFalse(draft.apply(albums: albums, albumsLoading: false) { _ in XCTFail("Missing album") })
        XCTAssertEqual(draft.albumID, "unavailable/opaque-id")
        draft.albumID = albums[0].id
        XCTAssertTrue(draft.canApply(albums: albums, albumsLoading: false))
        draft.albumID = nil
        XCTAssertTrue(draft.canApply(albums: [], albumsLoading: false))
    }

    func testLoadingDefersSelectedAlbumValidationButDoesNotBlockAllAlbums() throws {
        let draft = try makeDraft(PhotoSearchFilters(albumID: albums[0].id))
        XCTAssertNil(draft.validationMessage(albums: [], albumsLoading: true))
        XCTAssertFalse(draft.canApply(albums: [], albumsLoading: true))
        XCTAssertFalse(draft.apply(albums: albums, albumsLoading: true) { _ in XCTFail("Still loading") })
        XCTAssertTrue(draft.canApply(albums: albums, albumsLoading: false))
        XCTAssertTrue(try makeDraft().canApply(albums: [], albumsLoading: true))
        XCTAssertEqual(draft.albumID, albums[0].id)
    }

    func testReadOnlyAlbumCanFilterAndAllFourImageKindsRoundTrip() throws {
        var draft = try makeDraft(PhotoSearchFilters(albumID: albums[2].id))
        XCTAssertFalse(albums[2].canAdd)
        XCTAssertTrue(draft.canApply(albums: albums, albumsLoading: false))
        XCTAssertEqual(PhotoSearchImageKind.allCases, [.all, .photos, .screenshots, .livePhotos])
        for kind in PhotoSearchImageKind.allCases {
            draft.imageKind = kind
            var applied: PhotoSearchFilters?
            XCTAssertTrue(draft.apply(albums: albums, albumsLoading: false) { applied = $0 })
            XCTAssertEqual(applied?.imageKind, kind)
            XCTAssertEqual(applied?.albumID, albums[2].id)
        }
    }

    func testMenuAndEmptyCopyDescribeMembershipAndConditionalLimitedAccess() {
        XCTAssertEqual(SearchFiltersDraft.DatePreset.allCases.map(\.title), ["不限日期", "今年", "去年", "自定义"])
        XCTAssertEqual(AlbumActionSheet.membershipText, "加入系统相册，不复制或删除原照片")
        XCTAssertTrue(SearchFiltersDraft.emptyAlbumsText.contains("若仅允许访问部分照片"))
        XCTAssertTrue(AlbumActionSheet.emptyAlbumsText.contains("若仅允许访问部分照片"))
    }

    func testAlbumListExcludesReadOnlyAndDispatchesExactIdentifierOnlyOnAction() {
        let opaqueID = " opaque/album-id "
        var actions: [PhotoBatchAction] = []
        let sheet = AlbumActionSheet(albums: albums + [PhotoAlbum(id: opaqueID, title: "旅行", canAdd: true)]) {
            actions.append($0)
        }
        XCTAssertTrue(actions.isEmpty)
        XCTAssertEqual(sheet.addableAlbums.map(\.id), [albums[0].id, albums[1].id, opaqueID])
        XCTAssertFalse(sheet.add(to: albums[2].id))
        XCTAssertFalse(sheet.add(to: "missing"))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(sheet.add(to: opaqueID))
        XCTAssertEqual(actions.count, 1)
        guard case .addToAlbum(let id) = actions[0] else { return XCTFail("Wrong action") }
        XCTAssertEqual(id, opaqueID, "Never trim opaque identifiers or substitute a same-titled album")
    }

    func testCreateAlbumTrimsWhitespaceRejectsEmptyAndHasNoInventedLengthCap() {
        var actions: [PhotoBatchAction] = []
        let sheet = AlbumActionSheet(albums: []) { actions.append($0) }
        for name in ["", " \n\t ", "\u{3000}"] { XCTAssertFalse(sheet.createAlbum(named: name)) }
        XCTAssertTrue(actions.isEmpty)
        let longName = String(repeating: "相册", count: 600)
        for name in ["夏日 旅行", longName] {
            XCTAssertTrue(sheet.createAlbum(named: " \n\(name)\t "))
            guard let action = actions.last, case .createAlbum(let title) = action else {
                return XCTFail("Wrong action")
            }
            XCTAssertEqual(title, name)
        }
        XCTAssertEqual(actions.count, 2)
    }

    func testBusyAlbumSheetBlocksActionsAndIssueAloneAllowsExplicitRetry() {
        var actions: [PhotoBatchAction] = []
        let busy = AlbumActionSheet(albums: albums, isLoading: true, issue: "正在处理") { actions.append($0) }
        XCTAssertFalse(busy.add(to: albums[0].id))
        XCTAssertFalse(busy.createAlbum(named: "新相册"))
        XCTAssertTrue(actions.isEmpty)
        let retry = AlbumActionSheet(albums: albums, issue: "未能加入，请重试。") { actions.append($0) }
        XCTAssertTrue(actions.isEmpty, "Displaying an error must not submit an automatic retry")
        XCTAssertTrue(retry.add(to: albums[0].id))
        XCTAssertEqual(actions.count, 1)
    }

    func testShareCoordinatorRetainsPreparationAndControllerCreationDoesNotCleanUp() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var prepared: PreparedPhotoShare? = try await makeShare(root: root)
        weak var retained = prepared
        let coordinator = BatchPhotoShareSheet(share: try XCTUnwrap(prepared)).makeCoordinator()
        prepared = nil
        XCTAssertNotNil(retained)
        let controller = coordinator.makeController()
        defer { coordinator.share.cleanup() }
        XCTAssertEqual(controller.excludedActivityTypes, [.saveToCameraRoll])
        XCTAssertNotNil(controller.completionWithItemsHandler)
        XCTAssertTrue(coordinator.share.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testShareCompletionAndCancellationCleanupAreIdempotentWithParentDismissal() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for completed in [true, false] {
            let share = try await makeShare(root: root)
            defer { share.cleanup() }
            let controller = BatchPhotoShareSheet(share: share).makeCoordinator().makeController()
            let completion = try XCTUnwrap(controller.completionWithItemsHandler)
            XCTAssertTrue(share.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            completion(completed ? .copyToPasteboard : nil, completed, nil, nil)
            XCTAssertTrue(share.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            share.cleanup() // Identity-scoped parent dismissal may repeat this.
            completion(nil, false, nil, nil)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testActivityCompletionReportsOnlyCapturedShareIDAfterCleanupAndLeavesReplacementAlone() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for completed in [true, false] {
            let old = try await makeShare(root: root), new = try await makeShare(root: root)
            defer { old.cleanup(); new.cleanup() }
            XCTAssertNotEqual(old.id, new.id)
            XCTAssertEqual(old.assetIDs, new.assetIDs, "Callbacks identify preparations, not selected asset IDs")
            var finishedIDs: [UUID] = []
            let oldCoordinator = BatchPhotoShareSheet(share: old, finished: { id in
                XCTAssertEqual(id, old.id)
                XCTAssertTrue(old.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
                XCTAssertTrue(new.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                finishedIDs.append(id)
            }).makeCoordinator()
            let newCoordinator = BatchPhotoShareSheet(share: new, finished: { id in
                XCTAssertEqual(id, new.id)
                XCTAssertTrue(new.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
                finishedIDs.append(id)
            }).makeCoordinator()
            // Coordinator callbacks only: makeController bypasses the representable's validation guard.
            let oldController = oldCoordinator.makeController()
            let newController = newCoordinator.makeController()
            XCTAssertTrue(finishedIDs.isEmpty, "Construction is not completion")
            let oldCompletion = try XCTUnwrap(oldController.completionWithItemsHandler)
            oldCompletion(completed ? .copyToPasteboard : nil, completed, nil, nil)
            XCTAssertEqual(finishedIDs, [old.id])
            oldCompletion(nil, false, nil, nil)
            XCTAssertEqual(finishedIDs, [old.id, old.id], "Even a repeated old callback must retain its old identity")
            let newCompletion = try XCTUnwrap(newController.completionWithItemsHandler)
            newCompletion(nil, false, nil, nil)
            XCTAssertEqual(finishedIDs, [old.id, old.id, new.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testDismantleCleansCapturedShareThenAsynchronouslyReportsOnlyItsID() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try await makeShare(root: root), new = try await makeShare(root: root)
        defer { old.cleanup(); new.cleanup() }
        var finishedIDs: [UUID] = []
        let oldFinished = expectation(description: "Old share dismantle callback")
        let newFinished = expectation(description: "New share dismantle callback")
        oldFinished.assertForOverFulfill = true
        newFinished.assertForOverFulfill = true
        let oldCoordinator = BatchPhotoShareSheet(share: old, finished: { id in
            XCTAssertEqual(id, old.id)
            XCTAssertTrue(old.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertTrue(new.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            finishedIDs.append(id)
            oldFinished.fulfill()
        }).makeCoordinator()
        let newCoordinator = BatchPhotoShareSheet(share: new, finished: { id in
            XCTAssertEqual(id, new.id)
            XCTAssertTrue(new.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            finishedIDs.append(id)
            newFinished.fulfill()
        }).makeCoordinator()
        // A plain controller exercises dismantling, not makeUIViewController's validation guard.
        BatchPhotoShareSheet.dismantleUIViewController(UIViewController(), coordinator: oldCoordinator)
        XCTAssertTrue(finishedIDs.isEmpty, "Parent publication must be deferred outside synchronous dismantling")
        XCTAssertTrue(old.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(new.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await fulfillment(of: [oldFinished], timeout: 3)
        XCTAssertEqual(finishedIDs, [old.id])
        XCTAssertTrue(new.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        BatchPhotoShareSheet.dismantleUIViewController(UIViewController(), coordinator: newCoordinator)
        XCTAssertEqual(finishedIDs, [old.id])
        XCTAssertTrue(new.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        await fulfillment(of: [newFinished], timeout: 3)
        XCTAssertEqual(finishedIDs, [old.id, new.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testFiltersPanelBlackGoldNativeSnapshot() async throws {
        try await snapshot(SearchFiltersSheet(filters: PhotoSearchFilters(), albums: albums) { _ in
            XCTFail("Render-only fixture must not apply filters")
        }, name: "UIReview-search-actions-filters-dark")
    }

    func testAlbumPanelBlackGoldNativeSnapshotExcludesReadOnlyFixture() async throws {
        let sheet = AlbumActionSheet(albums: albums) { _ in XCTFail("Render-only fixture must not act") }
        XCTAssertEqual(sheet.addableAlbums, Array(albums.prefix(2)))
        try await snapshot(sheet, name: "UIReview-search-actions-albums-dark")
    }

    // MARK: Fixed, local calendar and disposable share data

    private func fixedCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) throws -> Date {
        let calendar = try fixedCalendar()
        return try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
    }

    private func makeDraft(_ filters: PhotoSearchFilters = PhotoSearchFilters()) throws -> SearchFiltersDraft {
        SearchFiltersDraft(filters: filters, calendar: try fixedCalendar(), now: try day(2026, 10, 5))
    }

    private func makeShare(root: URL) async throws -> PreparedPhotoShare {
        try await PhotoSharePreparer.prepare(ids: ["synthetic-a", "synthetic-b"], temporaryRoot: root,
            validate: { _ in }, write: { _, url in try Data([1, 2, 3]).write(to: url) })
    }

    // MARK: Real shallow hosting; no private SwiftUI inspection or injected state

    private func snapshot<Content: View>(_ content: Content, name: String) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Requires the native iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: phone)
        window.overrideUserInterfaceStyle = .dark
        let root = content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("TEST FIXTURE · No photo library access")
                    .font(.caption2).foregroundStyle(IQStyle.secondary)
                    .padding(6).frame(maxWidth: .infinity).background(IQStyle.muted)
            }
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
        let host = SearchActionsReviewHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        let size = phone
        let laidOut = expectation(description: "Search action sheet laid out")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == size else { return }
            host.onLayout = nil
            laidOut.fulfill()
        }
        defer {
            host.onLayout = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)
        let settled = expectation(description: "Native Form layout settled")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(host.view.bounds.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: phone, format: format).image { context in
            UIColor.black.setFill()
            context.fill(host.view.bounds)
            drewHierarchy = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "Capture the actual sheet, not a reconstructed image")
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 393)
        XCTAssertEqual(pixels.height, 852)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class SearchActionsReviewHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}