import XCTest
import ImageIQCore
@testable import LocalImageIQ

final class TextHybridRankingTests: XCTestCase {
    private func hit(_ id: String, score: Float = 0.5) -> SearchHit {
        SearchHit(photo: TestFixtures.photo(id: id).photo, score: score)
    }

    func testNoTextMatchesReturnsOriginalOrderDuplicatesAndEveryScoreBit() {
        let bits: [UInt32] = [0x80000000, 0x7FC01234, 0x00000001, 0x3F000001]
        let visual = bits.enumerated().map { hit($0.offset == 2 ? "0" : String($0.offset), score: Float(bitPattern: $0.element)) }
        let result = PhotoTextRanking.fuse(visual: visual, text: [])
        XCTAssertEqual(result.map(\.id), visual.map(\.id))
        XCTAssertEqual(result.map { $0.score.bitPattern }, bits)
        XCTAssertEqual(result.map { $0.photo.modificationTime }, visual.map { $0.photo.modificationTime })
    }

    func testTextOutsideVisualCandidatesCannotAddResultsOrChangeNoMatchArray() {
        let visual = [hit("a", score: -0.0), hit("a", score: 0.9), hit("b", score: -0.7)]
        let result = PhotoTextRanking.fuse(visual: visual, text: [PhotoTextMatch(id: "outside", score: 100)])
        XCTAssertEqual(result.map(\.id), visual.map(\.id))
        XCTAssertEqual(result.map { $0.score.bitPattern }, visual.map { $0.score.bitPattern })
        XCTAssertTrue(PhotoTextRanking.fuse(visual: [], text: [PhotoTextMatch(id: "outside", score: 1)]).isEmpty)
    }

    func testDuplicateIDsContributeOnceAndOutsideIDsDoNotConsumeTextRanks() {
        let base = [hit("a", score: 0.3), hit("b", score: 0.2), hit("c", score: 0.1)]
        let expected = PhotoTextRanking.fuse(visual: base, text: [PhotoTextMatch(id: "c", score: 2), PhotoTextMatch(id: "a", score: 1)])
        let result = PhotoTextRanking.fuse(visual: [base[0], hit("a", score: 9), base[1], base[2], base[2]],
                                          text: [PhotoTextMatch(id: "outside", score: 3), PhotoTextMatch(id: "c", score: 2),
                                                 PhotoTextMatch(id: "c", score: 2), PhotoTextMatch(id: "a", score: 1)])
        XCTAssertEqual(result.map(\.id), expected.map(\.id))
        XCTAssertEqual(result.map { $0.score.bitPattern }, expected.map { $0.score.bitPattern })
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
        XCTAssertEqual(result.first { $0.id == "a" }?.score.bitPattern, base[0].score.bitPattern)
    }

    func testEqualRRFScoreBreaksTieByOriginalVisualRankNotIDOrDiagnosticScore() {
        let visual = [hit("z", score: -0.5), hit("a", score: 0.9)]
        // z = 1/61 + 1/62; a = 1/62 + 1/61. Both are exactly the same sum.
        let result = PhotoTextRanking.fuse(visual: visual, text: [PhotoTextMatch(id: "a", score: 2), PhotoTextMatch(id: "z", score: 1)])
        XCTAssertEqual(result.map(\.id), ["z", "a"])
    }

    func testLexicalEvidenceReallyImprovesRankBeforeCallerFiltersAndLimits() {
        let visual = (1...100).map { hit("p\($0)", score: Float(101 - $0) / 100) }
        let result = PhotoTextRanking.fuse(visual: visual, text: [PhotoTextMatch(id: "p100", score: 2)])
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(result.first?.id, "p100", "1/160 + 1/61 beats an unmatched 1/61.")
        XCTAssertEqual(Array(result.prefix(3)).map(\.id), ["p100", "p1", "p2"])
        let filtered = result.filter { ["p100", "p2", "p3"].contains($0.id) }
        XCTAssertEqual(filtered.map(\.id), ["p100", "p2", "p3"])
        XCTAssertEqual(result.first?.score.bitPattern, visual.last?.score.bitPattern)
    }

    func testFusionKeepsOriginalPhotoAndImagePlaceDiagnosticIncludingNaNBits() {
        let place = PlaceEmbedding(text: "Synthetic Place", vector: TestFixtures.vector(axis: 1))
        let photo = IndexedPhoto(id: "target", modificationTime: 12.25, modelVersion: "unchanged",
                                 imageEmbedding: TestFixtures.vector(axis: 2), location: place, creationTime: 9.5)
        let target = SearchHit(photo: photo, score: Float(bitPattern: 0x7FC04321))
        let result = PhotoTextRanking.fuse(visual: [hit("other"), target], text: [PhotoTextMatch(id: "target", score: 2)])
        guard let retained = result.first else { return XCTFail("Missing target.") }
        XCTAssertEqual(retained.id, photo.id)
        XCTAssertEqual(retained.score.bitPattern, target.score.bitPattern)
        XCTAssertEqual(retained.photo.modificationTime, photo.modificationTime)
        XCTAssertEqual(retained.photo.modelVersion, photo.modelVersion)
        XCTAssertEqual(retained.photo.imageEmbedding, photo.imageEmbedding)
        XCTAssertEqual(retained.photo.location?.text, place.text)
        XCTAssertEqual(retained.photo.location?.vector, place.vector)
        XCTAssertEqual(retained.photo.creationTime, photo.creationTime)
    }

    func testRRFUsesRanksAndK60RatherThanCalibratingScoreMagnitudes() {
        let visual = [hit("a", score: 500), hit("b", score: -100), hit("c", score: 0)]
        // a: 1/61; b: 1/62 + 1/62; c: 1/63 + 1/61, so c > b > a.
        let text = [PhotoTextMatch(id: "c", score: 0.000002), PhotoTextMatch(id: "b", score: 0.000001)]
        let result = PhotoTextRanking.fuse(visual: visual, text: text)
        XCTAssertEqual(result.map(\.id), ["c", "b", "a"])
        let scaled = PhotoTextRanking.fuse(visual: visual, text: [PhotoTextMatch(id: "c", score: 2000), PhotoTextMatch(id: "b", score: 1000)])
        XCTAssertEqual(scaled.map(\.id), result.map(\.id))
        XCTAssertEqual(scaled.map { $0.score.bitPattern }, result.map { $0.score.bitPattern })
    }
}