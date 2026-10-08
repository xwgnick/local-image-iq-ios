import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

final class SimilarGroupPresentationTests: XCTestCase {
    func testNewestSmallGroupPrecedesOlderLargeGroup() {
        let old = group("old", dates: Array(repeating: 10, count: 100))
        let new = group("new", dates: [20, 19, 18, 17, 16])
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([old, new]).map(\.id), ["new", "old"])
    }

    func testLatestMemberCreationNotFirstMemberOrModificationControlsOrder() {
        let edited = group("edited", dates: [10, 11], modification: 10_000)
        let latest = group("latest", dates: [1, 50, 2], modification: 2)
        XCTAssertEqual(SimilarGroupPresentation.latestCreationTime(in: latest), 50)
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([edited, latest]).map(\.id), ["latest", "edited"])
    }

    func testEqualLatestDateUsesCountThenStableID() {
        let a = group("a", dates: [5, 10])
        let z = group("z", dates: [10, 9])
        let large = group("large", dates: [1, 10, 2])
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([z, a, large]).map(\.id), ["large", "a", "z"])
    }

    func testMissingDatesSortLastEvenAfterNegativeFiniteDate() {
        let missing = group("missing", dates: [nil, nil, nil])
        let dated = group("dated", dates: [-100, nil])
        XCTAssertNil(SimilarGroupPresentation.latestCreationTime(in: missing))
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([missing, dated]).map(\.id), ["dated", "missing"])
    }

    func testNonFiniteDatesAreIgnoredInsteadOfBreakingComparator() {
        let invalid = group("invalid", dates: [.nan, .infinity, -.infinity, nil])
        let mixed = group("mixed", dates: [.infinity, 12, .nan, 7])
        let valid = group("valid", dates: [13, nil])
        XCTAssertNil(SimilarGroupPresentation.latestCreationTime(in: invalid))
        XCTAssertEqual(SimilarGroupPresentation.latestCreationTime(in: mixed), 12)
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([invalid, mixed, valid]).map(\.id), ["valid", "mixed", "invalid"])
    }

    func testAllMissingDatesUseCountThenIDAndEmptyGroupIsSupported() {
        let a = group("a", dates: [nil, nil])
        let b = group("b", dates: [nil, nil])
        let large = group("large", dates: [nil, nil, nil])
        let empty = group("empty", dates: [])
        XCTAssertEqual(SimilarGroupPresentation.sortedGroups([empty, b, large, a]).map(\.id), ["large", "a", "b", "empty"])
        XCTAssertTrue(SimilarGroupPresentation.sortedGroups([]).isEmpty)
    }

    func testProjectionPreservesCanonicalInputAndEveryMemberAndScore() {
        let old = group("old", dates: [1, 3, 2])
        let new = group("new", dates: [20, 18])
        let canonical = [old, new]
        let projected = SimilarGroupPresentation.sortedGroups(canonical)
        XCTAssertEqual(canonical.map(\.id), ["old", "new"])
        for source in canonical {
            let displayed = projected.first { $0.id == source.id }
            XCTAssertEqual(displayed?.photos.map(\.id), source.photos.map(\.id))
            XCTAssertEqual(displayed?.photos.map(\.creationTime), source.photos.map(\.creationTime))
            XCTAssertEqual(displayed?.photos.map(\.modificationTime), source.photos.map(\.modificationTime))
            XCTAssertEqual(displayed?.photos.map(\.imageEmbedding), source.photos.map(\.imageEmbedding))
            XCTAssertEqual(displayed?.minimumSimilarity.bitPattern, source.minimumSimilarity.bitPattern)
        }
    }

    func testPermutationIndependentAndIdempotentOrdering() {
        let values = [group("z", dates: [5, 5]), group("a", dates: [5, 4]),
                      group("missing", dates: [nil, nil]), group("new", dates: [6, 1])]
        let expected = ["new", "a", "z", "missing"]
        for input in [values, Array(values.reversed()), Array(values.dropFirst()) + [values[0]]] {
            let output = SimilarGroupPresentation.sortedGroups(input)
            XCTAssertEqual(output.map(\.id), expected)
            XCTAssertEqual(SimilarGroupPresentation.sortedGroups(output).map(\.id), expected)
        }
    }

    private func group(_ id: String, dates: [TimeInterval?], modification: TimeInterval = 1) -> SimilarPhotoGroup {
        let photos: [IndexedPhoto] = dates.enumerated().map { index, date in
            IndexedPhoto(id: "\(id)-\(index)", modificationTime: modification,
                         modelVersion: "presentation-only", imageEmbedding: [1, 0], creationTime: date)
        }
        return SimilarPhotoGroup(id: id, photos: photos, minimumSimilarity: 0.9375)
    }
}