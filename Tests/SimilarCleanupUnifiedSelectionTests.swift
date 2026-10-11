import SwiftUI
import UIKit
import XCTest
@testable import LocalImageIQ

@MainActor
final class SimilarCleanupUnifiedSelectionTests: XCTestCase {
    func testNativeOverviewShowsCirclesOnlyInSelectionAndNeverOnOverflow() async throws {
        let fixture = try await controlsFixture(in: self, sizes: [9])
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        let host = try ControlsNativeHost(content: AnyView(fixture.sheet()))
        defer { host.close() }
        func tiles() -> [SimilarPhotoPreviewControl] {
            controlsDescendants(host.controller.view, SimilarPhotoPreviewControl.self)
        }
        try await host.wait { tiles().count == 5 }
        XCTAssertTrue(tiles().allSatisfy { !$0.showsSelectionMark })
        try host.attach(to: self, name: "UIReview-build40-cleanup-browse")
        fixture.browser.selectionMode = true
        try await host.wait { tiles().filter(\.showsSelectionMark).count == 4 }
        let overflow = try XCTUnwrap(tiles().first {
            $0.accessibilityIdentifier == "similar-cleanup-group-1-photo-5"
        })
        XCTAssertFalse(overflow.showsSelectionMark)
        let first = try XCTUnwrap(tiles().first {
            $0.accessibilityIdentifier == "similar-cleanup-group-1-photo-1"
        })
        first.sendActions(for: .touchUpInside)
        try await host.wait { fixture.cleanup.selectedCount == 1 }
        XCTAssertNil(fixture.browser.detailRoute, "Selection does not open the group")
        try host.attach(to: self, name: "UIReview-build40-cleanup-selection")
        overflow.sendActions(for: .touchUpInside)
        try await host.wait { fixture.browser.detailRoute != nil }
        XCTAssertTrue(fixture.browser.selectionMode)
        XCTAssertEqual(fixture.cleanup.selectedCount, 1)
        try host.attach(to: self, name: "UIReview-build40-cleanup-expanded")
    }

    func testOverviewRangeSpansGroupsWithoutSelectingOverflowOrHiddenMembers() async throws {
        let fixture = try await controlsFixture(in: self, sizes: [9, 7, 4])
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        let groups = fixture.cleanup.visibleGroups
        let ids = fixture.cleanup.overviewSelectionIDs
        XCTAssertEqual(ids.count, 12)
        XCTAssertEqual(ids, groups.flatMap { Array($0.photos.prefix(4)).map(\.id) })
        let range = try XCTUnwrap(SimilarPhotoRangeSelection(photoIDs: ids, selectedIDs: [],
                                                            anchorID: ids[0]))
        let token = try XCTUnwrap(fixture.cleanup.beginOverviewRangeSelection())
        fixture.cleanup.finishRangeSelection(token: token, selectedInGroup: range.selection(throughID: ids[6]))
        await fixture.cleanup.waitUntilIdle()
        XCTAssertEqual(fixture.cleanup.selectedIDs, Set(ids[0...6]))
        XCTAssertEqual(fixture.cleanup.selectionSummary.groupCount, 2)
        for group in groups where group.photos.count > 5 {
            XCTAssertTrue(fixture.cleanup.selectedIDs.isDisjoint(with: group.photos.dropFirst(4).map(\.id)))
        }
    }

    func testOverviewRangePreservesAlreadySelectedCollapsedMembers() async throws {
        let fixture = try await controlsFixture(in: self, sizes: [9, 7])
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        let first = try XCTUnwrap(fixture.cleanup.visibleGroups.first)
        fixture.cleanup.selectGroup(first.id)
        let ids = fixture.cleanup.overviewSelectionIDs
        let token = try XCTUnwrap(fixture.cleanup.beginOverviewRangeSelection())
        fixture.cleanup.finishRangeSelection(token: token, selectedInGroup: [])
        await fixture.cleanup.waitUntilIdle()
        XCTAssertEqual(fixture.cleanup.selectedIDs, Set(first.photos.dropFirst(4).map(\.id)))
        XCTAssertTrue(Set(ids).isDisjoint(with: fixture.cleanup.selectedIDs))
    }

    func testOverviewCannotSmuggleOverflowIntoCapturedSelection() async throws {
        let fixture = try await controlsFixture(in: self, sizes: [9])
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        let group = try XCTUnwrap(fixture.cleanup.visibleGroups.first)
        let token = try XCTUnwrap(fixture.cleanup.beginOverviewRangeSelection())
        fixture.cleanup.finishRangeSelection(token: token, selectedInGroup: [group.photos[4].id])
        await fixture.cleanup.waitUntilIdle()
        XCTAssertTrue(fixture.cleanup.selectedIDs.isEmpty)
        XCTAssertFalse(fixture.cleanup.isSelecting)
    }

    func testGroupExpansionAndReturnDoNotResetGlobalModeOrSelection() async throws {
        let fixture = try await controlsFixture(in: self, sizes: [9, 7])
        fixture.cleanup.scan()
        await fixture.cleanup.waitUntilIdle()
        let browser = SimilarPhotoGroupBrowser()
        browser.selectionMode = true
        let groups = fixture.cleanup.visibleGroups
        fixture.cleanup.selectGroup(groups[0].id)
        fixture.cleanup.selectGroup(groups[1].id)
        browser.open(group: groups[0], photoID: groups[0].photos[0].id,
                     sessionID: try XCTUnwrap(fixture.cleanup.browsingSessionID))
        browser.closeDetail()
        XCTAssertTrue(browser.selectionMode)
        XCTAssertEqual(fixture.cleanup.selectedCount, 16)
        fixture.cleanup.clearSelection()
        browser.selectionMode = false
        XCTAssertEqual(fixture.cleanup.selectedCount, 0)
        XCTAssertFalse(browser.selectionMode)
    }

    func testHoldUsesOnePresentationAndReleaseDoesNotActivateTile() {
        let tile = SimilarPhotoPreviewControl()
        tile.photoID = "held"
        var opened = 0
        var changes: [String?] = []
        tile.open = { _ in opened += 1 }
        tile.hold.present = { changes.append($0) }
        tile.hold.begin("held")
        tile.hold.begin("ignored")
        tile.sendActions(for: .touchUpInside)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(changes, ["held"])
        tile.hold.end()
        tile.hold.end()
        XCTAssertEqual(changes, ["held", nil])
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(tile.hold.recognizer.minimumPressDuration, 0.35)
        XCTAssertTrue(tile.hold.recognizer.cancelsTouchesInView)
    }

    func testRevokingTileAccessAndDismantlingEndHeldImage() {
        let tile = SimilarPhotoPreviewControl()
        var changes: [String?] = []
        tile.hold.present = { changes.append($0) }
        tile.hold.begin("held")
        tile.isEnabled = false
        XCTAssertNil(tile.hold.activePhotoID)
        XCTAssertEqual(changes, ["held", nil])
        tile.isEnabled = true
        tile.hold.begin("second")
        tile.dismantlePreview()
        XCTAssertEqual(changes, ["held", nil, "second", nil])
    }
}

final class PhotoLibraryChangeRelevanceTests: XCTestCase {
    func testPostDeletionUnrelatedNotificationsDoNotScheduleAnotherImageSync() {
        var requests = 0
        // One batch deletion changes the image fetch. Follow-up album/video
        // notifications have no details for that updated image result.
        for hasDetails in [true] + Array(repeating: false, count: 30) {
            if PhotoLibraryClient.shouldNotifyImageChange(hasSnapshot: true,
                authorizationChanged: false, hasChangeDetails: hasDetails) { requests += 1 }
        }
        XCTAssertEqual(requests, 1)
    }

    func testRealImageChangesAndAuthorizationChangesStillNotify() {
        XCTAssertTrue(PhotoLibraryClient.shouldNotifyImageChange(hasSnapshot: true,
            authorizationChanged: false, hasChangeDetails: true))
        XCTAssertTrue(PhotoLibraryClient.shouldNotifyImageChange(hasSnapshot: true,
            authorizationChanged: true, hasChangeDetails: false))
        XCTAssertTrue(PhotoLibraryClient.shouldNotifyImageChange(hasSnapshot: false,
            authorizationChanged: false, hasChangeDetails: false))
        XCTAssertFalse(PhotoLibraryClient.shouldNotifyImageChange(hasSnapshot: true,
            authorizationChanged: false, hasChangeDetails: false))
    }
}
