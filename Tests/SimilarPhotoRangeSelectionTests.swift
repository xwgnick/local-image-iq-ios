import XCTest
@testable import LocalImageIQ

final class SimilarPhotoRangeSelectionTests: XCTestCase {
    private let ids = (0..<15).map { "p\($0)" }

    func testInitialAnchorDeterminesModeAndDoesNotSelectUntilPreviewRequested() throws {
        let select = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p1", "outside"], anchorID: "p2"))
        XCTAssertEqual(select.anchorID, "p2")
        XCTAssertTrue(select.selects)
        XCTAssertEqual(select.selection(throughID: "unknown"), Set(["p1"]))
        XCTAssertEqual(select.selection(throughID: "p2"), Set(["p1", "p2"]))
        let deselect = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p1", "p2"], anchorID: "p2"))
        XCTAssertFalse(deselect.selects)
        XCTAssertEqual(deselect.selection(throughID: "p2"), Set(["p1"]))
    }

    func testSkippedEndpointsSelectInclusiveRangeAcrossFiveColumnRows() throws {
        let model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: [], anchorID: "p3"))
        // No intermediate hover events: spans row 1, row 2 and row 3.
        XCTAssertEqual(model.selection(throughID: "p12"), Set(ids[3...12]))
        XCTAssertEqual(model.selection(throughID: "p5"), Set(ids[3...5]))
    }

    func testBackwardRangeIncludesBothEndpointsInDisplayRatherThanLexicalOrder() throws {
        let model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p14"], anchorID: "p12"))
        XCTAssertEqual(model.selection(throughID: "p3"), Set(ids[3...12]).union(["p14"]))
    }

    func testReversingSelectionRestoresOutsideRangeFromBase() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p1", "p10", "p14"], anchorID: "p6"))
        XCTAssertEqual(model.update(throughID: "p13"), Set(ids[6...13]).union(["p1", "p14"]))
        XCTAssertEqual(model.update(throughID: "p8"), Set(["p1", "p6", "p7", "p8", "p10", "p14"]))
        XCTAssertEqual(model.update(throughID: "p6"), Set(["p1", "p6", "p10", "p14"]))
    }

    func testDeselectingSkippedRangeRemovesOnlyInitiallySelectedMembers() throws {
        let base: Set<String> = ["p0", "p2", "p5", "p7", "p10", "p14"]
        let model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: base, anchorID: "p2"))
        XCTAssertFalse(model.selects)
        XCTAssertEqual(model.selection(throughID: "p10"), Set(["p0", "p14"]))
        XCTAssertEqual(model.selection(throughID: "p7"), Set(["p0", "p10", "p14"]))
    }

    func testReversingDeselectionRestoresOriginalHolesAndSelectedMembers() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p0", "p2", "p5", "p7", "p10", "p14"], anchorID: "p10"))
        XCTAssertEqual(model.update(throughID: "p2"), Set(["p0", "p14"]))
        XCTAssertEqual(model.update(throughID: "p7"), Set(["p0", "p2", "p5", "p14"]))
        XCTAssertEqual(model.update(throughID: "p10"), Set(["p0", "p2", "p5", "p7", "p14"]))
    }

    func testCrossingAnchorRestoresPreviousSideWhileSelectingNewSide() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p1", "p9"], anchorID: "p6"))
        XCTAssertEqual(model.update(throughID: "p11"), Set(ids[6...11]).union(["p1"]))
        XCTAssertEqual(model.update(throughID: "p3"), Set(ids[3...6]).union(["p1", "p9"]))
        XCTAssertEqual(model.update(throughID: "p8"), Set(["p1", "p6", "p7", "p8", "p9"]))
    }

    func testCrossingAnchorDuringDeselectionRestoresPreviousSide() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: Set(ids), anchorID: "p6"))
        XCTAssertEqual(model.update(throughID: "p11"), Set(ids).subtracting(ids[6...11]))
        XCTAssertEqual(model.update(throughID: "p2"), Set(ids).subtracting(ids[2...6]))
        XCTAssertEqual(model.update(throughID: "p6"), Set(ids).subtracting(["p6"]))
    }

    func testRepeatedPurePreviewsAndUpdatesNeverTogglePerHover() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p14"], anchorID: "p0"))
        let expected = Set(ids[0...8]).union(["p14"])
        XCTAssertEqual(model.selection(throughID: "p8"), expected)
        XCTAssertEqual(model.selection(throughID: "p8"), expected)
        XCTAssertEqual(model.update(throughID: "p8"), expected)
        XCTAssertEqual(model.update(throughID: "p8"), expected)
        XCTAssertTrue(model.selects)
    }

    func testUnknownEndpointsLeavePreviewUnchangedAndForeignBaseIDsNeverEscape() throws {
        var model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: ids, selectedIDs: ["p0", "other-group"], anchorID: "p2"))
        XCTAssertEqual(model.selection(throughID: "other-group"), Set(["p0"]))
        let previous = model.update(throughID: "p8")
        XCTAssertEqual(model.update(throughID: "missing"), previous)
        XCTAssertEqual(model.selection(throughID: ""), previous)
        XCTAssertFalse(previous.contains("other-group"))
    }

    func testRejectsMissingAnchorDuplicateIDsEmptyGroupAndEmptyIdentifier() {
        XCTAssertNil(SimilarPhotoRangeSelection(photoIDs: ids, selectedIDs: [], anchorID: "missing"))
        XCTAssertNil(SimilarPhotoRangeSelection(photoIDs: ["a", "b", "a"], selectedIDs: [], anchorID: "a"))
        XCTAssertNil(SimilarPhotoRangeSelection(photoIDs: [], selectedIDs: [], anchorID: "a"))
        XCTAssertNil(SimilarPhotoRangeSelection(photoIDs: [""], selectedIDs: [], anchorID: ""))
    }

    func testOpaqueIDsRemainExactWithoutTrimmingOrSorting() throws {
        let opaque = ["z", " a/id \n", "b", "d"]
        let model = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: opaque, selectedIDs: ["d"], anchorID: " a/id \n"))
        XCTAssertEqual(model.selection(throughID: "b"), Set([" a/id \n", "b", "d"]))
        XCTAssertEqual(model.selection(throughID: "a/id"), Set(["d"]))
    }

    func testWholeLargeGroupHasNoCapOrAutomaticKeeper() throws {
        let large = (0..<1234).map { "photo-\($0)" }
        let select = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: large, selectedIDs: [], anchorID: large[0]))
        XCTAssertEqual(select.selection(throughID: large[1233]), Set(large))
        let deselect = try XCTUnwrap(SimilarPhotoRangeSelection(
            photoIDs: large, selectedIDs: Set(large), anchorID: large[1233]))
        XCTAssertTrue(deselect.selection(throughID: large[0]).isEmpty)
    }
}