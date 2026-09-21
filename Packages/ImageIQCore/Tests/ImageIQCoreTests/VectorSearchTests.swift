import XCTest
@testable import ImageIQCore

final class VectorSearchTests: XCTestCase {
    private func photo(
        _ id: String, _ vector: [Float], place: String? = nil, location: [Float] = [1, 0]
    ) -> IndexedPhoto {
        IndexedPhoto(
            id: id, modificationTime: 123.5, modelVersion: "synthetic-pair",
            imageEmbedding: vector,
            location: place.map { PlaceEmbedding(text: $0, vector: location) }
        )
    }

    private func search(
        _ photos: [IndexedPhoto], weight: Float, limit: Int = Int.max, query: [Float] = [1, 0]
    ) throws -> [SearchHit] {
        try VectorSearch.search(query: query, photos: photos, limit: limit, locationWeight: weight)
    }

    private func score(_ id: String, in hits: [SearchHit]) throws -> Float {
        try XCTUnwrap(hits.first { $0.id == id }).score
    }

    /// Independent exhaustive reference for synthetic two-dimensional inputs.
    /// Materializes fused coordinates here ONLY, never in production search.
    private func reference(_ photos: [IndexedPhoto], weight: Float) -> [SearchHit] {
        var places: [String: [Float]] = [:]
        for photo in photos {
            if let location = photo.location { places[location.text] = location.vector }
        }
        var center = [Double](repeating: 0, count: 2)
        for key in places.keys.sorted() {
            for axis in 0..<2 { center[axis] += Double(places[key]![axis]) / Double(places.count) }
        }
        let w = Double(weight)
        return photos.map { photo in
            let fused = (0..<2).map { axis -> Double in
                let residual = photo.location.map { Double($0.vector[axis]) - center[axis] } ?? 0
                return (1 - w) * Double(photo.imageEmbedding[axis]) + w * residual
            }
            return SearchHit(photo: photo, score: Float(fused[0])) // query=[1,0]
        }.sorted {
            $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
        }
    }

    func testWeightZeroUsesImageOnlyAndIdentifierTies() throws {
        let photos = [
            photo("z", [0.6, 0.8], place: "A"),
            photo("b", [1, 0], place: "B", location: [-1, 0]),
            photo("a", [1, 0]), photo("negative", [-1, 0])
        ]
        let hits = try search(photos, weight: 0)
        XCTAssertEqual(hits.map(\.id), ["a", "b", "z", "negative"])
        for hit in hits { XCTAssertEqual(hit.score, try EmbeddingMath.dot([1, 0], hit.photo.imageEmbedding)) }
    }

    func testWeightOneIsPlaceOnlyAndSamePlaceTiesByIdentifier() throws {
        let hits = try search([
            photo("a2", [-1, 0], place: "A"), photo("a1", [0, 1], place: "A"),
            photo("b", [1, 0], place: "B", location: [-1, 0]), photo("unknown", [1, 0])
        ], weight: 1)
        XCTAssertEqual(hits.map(\.id), ["a1", "a2", "unknown", "b"])
        XCTAssertEqual(hits.map(\.score), [1, 1, 0, -1])
    }

    func testMissingLocationScalesImageInsteadOfPreservingBaselineScore() throws {
        let hits = try search([photo("unknown", [0.8, 0.6])], weight: 0.25)
        XCTAssertEqual(try score("unknown", in: hits), 0.6, accuracy: 0.000001)
    }

    func testUnknownZeroCanOutrankNegativeLocationSignal() throws {
        let hits = try search([
            photo("negative-place", [1, 0], place: "B", location: [-1, 0]),
            photo("positive-place", [-1, 0], place: "A"), photo("unknown", [-1, 0])
        ], weight: 1)
        XCTAssertEqual(hits.map(\.id), ["positive-place", "unknown", "negative-place"])
        XCTAssertEqual(try score("unknown", in: hits), 0)
        XCTAssertEqual(try score("negative-place", in: hits), -1)
    }

    func testWeightImmediatelyBelowOneIsFiniteWithoutDivisionSingularity() throws {
        let weight = Float(1).nextDown
        let hits = try search([
            photo("positive", [1, 0], place: "A"),
            photo("negative", [1, 0], place: "B", location: [-1, 0]),
            photo("unknown", [1, 0])
        ], weight: weight)
        XCTAssertTrue(hits.allSatisfy { $0.score.isFinite })
        XCTAssertEqual(hits.map(\.id), ["positive", "unknown", "negative"])
        XCTAssertEqual(try score("positive", in: hits), 1)
        XCTAssertEqual(try score("unknown", in: hits), 1 - weight)
        XCTAssertEqual(try score("negative", in: hits), 1 - 2 * weight)
    }

    func testNeitherMeanResidualNorFinalVectorIsNormalized() throws {
        let hits = try search([
            photo("east", [1, 0], place: "East", location: [1, 0]),
            photo("north", [1, 0], place: "North", location: [0, 1]),
            photo("unknown", [1, 0])
        ], weight: 0.5)
        XCTAssertEqual(hits.map(\.id), ["east", "unknown", "north"])
        XCTAssertEqual(hits.map(\.score), [0.75, 0.5, 0.25])
    }

    func testObliqueQueryUsesEveryImageAndPlaceCoordinate() throws {
        let hits = try search([
            photo("a", [0, 1], place: "A", location: [1, 0]),
            photo("b", [1, 0], place: "B", location: [0, 1]),
            photo("unknown", [0.6, 0.8])
        ], weight: 0.25, query: [0.6, 0.8])
        XCTAssertEqual(hits.map(\.id), ["unknown", "a", "b"])
        XCTAssertEqual(try score("unknown", in: hits), 0.75, accuracy: 0.000001)
        XCTAssertEqual(try score("a", in: hits), 0.575, accuracy: 0.000001)
        XCTAssertEqual(try score("b", in: hits), 0.475, accuracy: 0.000001)
    }

    func testSingletonPlaceHasZeroResidual() throws {
        let weight: Float = 0.9
        let hits = try search([
            photo("known", [0.6, 0.8], place: "Only place"),
            photo("unknown", [0.6, 0.8])
        ], weight: weight)
        let expected = Float((1 - Double(weight)) * Double(Float(0.6)))
        XCTAssertEqual(hits.map(\.score), [expected, expected])
    }

    func testPlaceFrequencyDoesNotWeightCenterOrDeduplicatePhotos() throws {
        let base = [
            photo("a0", [1, 0], place: "A", location: [1, 0]),
            photo("b", [1, 0], place: "B", location: [0, 1])
        ]
        let repeated = base + (1...9).map { photo("a\($0)", [1, 0], place: "A") }
        let before = try search(base, weight: 0.5)
        let after = try search(repeated, weight: 0.5)
        XCTAssertEqual(after.count, 11)
        for id in ["a0", "b"] { XCTAssertEqual(try score(id, in: before), try score(id, in: after)) }
        XCTAssertEqual(try score("a0", in: after), 0.75)
        XCTAssertEqual(try score("b", in: after), 0.25)
    }

    func testDifferentTextsWithEqualVectorsRemainDistinctPlaces() throws {
        let hits = try search([
            photo("a", [1, 0], place: "A"), photo("b", [1, 0], place: "B"),
            photo("c", [1, 0], place: "C", location: [-1, 0])
        ], weight: 1)
        XCTAssertEqual(try score("a", in: hits), Float(2.0 / 3.0), accuracy: 0.000001)
        XCTAssertEqual(try score("c", in: hits), Float(-4.0 / 3.0), accuracy: 0.000001)
        // A centered inner-product score is not constrained to the cosine range.
        XCTAssertLessThan(try score("c", in: hits), -1)
    }

    func testConflictingSameTextVectorsThrowEvenWithEqualQueryProjection() {
        let photos = [
            photo("a", [1, 0], place: "Same", location: [1, 0]),
            photo("b", [1, 0], place: "Same", location: [1, 1])
        ]
        for weight in [Float(0), 0.5, 1] {
            for limit in [0, 1] {
                XCTAssertThrowsError(try search(photos, weight: weight, limit: limit)) {
                    XCTAssertEqual($0 as? VectorSearchError, .inconsistentPlaceVector(text: "Same"))
                }
            }
        }
    }

    func testPlaceTextIdentityIsByteExactNotCanonicalEquivalence() throws {
        let hits = try search([
            photo("composed", [1, 0], place: "\u{00E9}", location: [1, 0]),
            photo("decomposed", [1, 0], place: "e\u{0301}", location: [-1, 0])
        ], weight: 1)
        XCTAssertEqual(hits.map(\.score), [1, -1])
    }

    func testRootScopedPhotosChangeCenterAndRankingWithoutCrossCallState() throws {
        let rootA = [photo("known", [0.6, 0.8], place: "A"), photo("unknown", [0.8, 0.6])]
        let rootB = rootA + [photo("other-root", [-1, 0], place: "B", location: [-1, 0])]
        let first = try search(rootA, weight: 0.5)
        let expanded = try search(rootB, weight: 0.5)
        let again = try search(rootA, weight: 0.5)
        XCTAssertEqual(first.map(\.id), ["unknown", "known"])
        XCTAssertEqual(expanded.map(\.id), ["known", "unknown", "other-root"])
        XCTAssertEqual(again.map(\.id), first.map(\.id))
        XCTAssertEqual(again.map(\.score), first.map(\.score))
        XCTAssertEqual(try score("known", in: first), 0.3, accuracy: 0.000001)
        XCTAssertEqual(try score("known", in: expanded), 0.8, accuracy: 0.000001)
    }

    func testRelativeRankingMatchesRescaledLegacyCenteredFormulaBelowOne() throws {
        let photos = [
            photo("a", [0.6, 0.8], place: "A"), photo("unknown", [0.8, 0.6]),
            photo("b", [1, 0], place: "B", location: [-1, 0])
        ] // distinct-place center=[0,0]
        for weight in [Float(0), 0.05, 0.5, 0.95, Float(1).nextDown] {
            let w = Double(weight)
            let oldScores = photos.map { photo -> (id: String, score: Double) in
                let placeScore = photo.location.map { Double($0.vector[0]) } ?? 0
                return (photo.id, Double(photo.imageEmbedding[0]) + w / (1 - w) * placeScore)
            }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            let hits = try search(photos, weight: weight)
            XCTAssertEqual(hits.map(\.id), oldScores.map { $0.id })
            for (hit, old) in zip(hits, oldScores) {
                XCTAssertEqual(hit.score, Float((1 - w) * old.score), accuracy: 0.000001)
            }
        }
    }

    func testPhotoPermutationDoesNotChangeScoresOrIdentifierTies() throws {
        let photos = [
            photo("z", [1, 0], place: "Z", location: [0, 1]),
            photo("b", [1, 0], place: "A"), photo("a", [1, 0], place: "A"),
            photo("c", [-1, 0], place: "C", location: [-1, 0])
        ]
        let forward = try search(photos, weight: 0.4)
        let backward = try search(Array(photos.reversed()), weight: 0.4)
        XCTAssertEqual(forward.map(\.id), backward.map(\.id))
        XCTAssertEqual(forward.map(\.score), backward.map(\.score))
    }

    func testBoundedHeapMatchesIndependentExhaustiveReference() throws {
        let vectors: [[Float]] = [[-1, 0], [0, 1], [1, 0]]
        let photos = (0..<41).map { index -> IndexedPhoto in
            let place = index % 4 == 0 ? nil : "P\(index % 3)"
            return photo(
                "asset-\(index)", [Float(index % 7 - 3) / 4, 0.25],
                place: place, location: vectors[index % 3]
            )
        }
        let orders = [photos, Array(photos.reversed()), Array(photos.dropFirst(13)) + Array(photos.prefix(13))]
        for weight in [Float(0), 0.3, Float(1).nextDown, 1] {
            let expected = reference(photos, weight: weight)
            for order in orders {
                for limit in [0, 1, 2, 3, 4, 7, 20, 41, 100] {
                    let actual = try search(order, weight: weight, limit: limit)
                    XCTAssertEqual(actual.map(\.id), Array(expected.prefix(limit)).map(\.id))
                    for (hit, wanted) in zip(actual, expected) {
                        XCTAssertEqual(hit.score, wanted.score, accuracy: 0.000001)
                    }
                }
            }
        }
    }

    func testEmptyLibraryZeroLimitAndOversizedLimit() throws {
        XCTAssertTrue(try search([], weight: 1).isEmpty)
        let photos = [photo("a", [1, 0])]
        XCTAssertTrue(try search(photos, weight: 0, limit: 0).isEmpty)
        XCTAssertEqual(try search(photos, weight: 0, limit: Int.max).map(\.id), ["a"])
    }

    func testAllPhotosWithoutLocationsAtFullWeightTieByID() throws {
        let photos = [photo("b", [1, 0]), photo("a", [-1, 0])]
        XCTAssertEqual(try search(photos, weight: 1).map(\.id), ["a", "b"])
        XCTAssertEqual(try search(photos, weight: 1).map(\.score), [0, 0])
    }

    func testEmptyAndMismatchedVectorShapesThrow() {
        XCTAssertThrowsError(try search([], weight: 0, query: []))
        let invalidVectors: [[Float]] = [[], [1], [1, 0, 0]]
        for vector in invalidVectors {
            XCTAssertThrowsError(try search([photo("bad-image", vector)], weight: 0))
            XCTAssertThrowsError(try search([
                photo("bad-place", [1, 0], place: "A", location: vector)
            ], weight: 0))
        }
    }

    func testNonFiniteVectorsThrowEvenWhenTheirWeightIsZero() {
        for bad in [Float.nan, Float.infinity, -Float.infinity] {
            XCTAssertThrowsError(try search([], weight: 0, query: [bad, 0]))
            XCTAssertThrowsError(try search([photo("bad-image", [bad, 0])], weight: 1))
            XCTAssertThrowsError(try search([
                photo("bad-place", [1, 0], place: "A", location: [bad, 0])
            ], weight: 0))
        }
    }

    func testInvalidWeightsThrowEvenForEmptyLibraryOrZeroLimit() {
        for weight in [Float(-0.001), 1.001, .nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try search([], weight: weight, limit: 0)) {
                XCTAssertEqual($0 as? VectorSearchError, .invalidLocationWeight)
            }
        }
    }

    func testNegativeLimitThrows() {
        XCTAssertThrowsError(try search([], weight: 0, limit: -1)) {
            XCTAssertEqual($0 as? VectorSearchError, .negativeLimit)
        }
    }

    func testZeroLimitStillValidatesAllRecords() {
        let photos = [photo("good", [1, 0]), photo("bad", [1])]
        XCTAssertThrowsError(try search(photos, weight: 0, limit: 0))
        XCTAssertThrowsError(try search(photos, weight: 0, limit: 1))
    }

    func testScoreOverflowThrowsButRepresentableWeightedScoreIsAllowed() throws {
        let photos = [photo("large", [Float.greatestFiniteMagnitude])]
        XCTAssertThrowsError(try search(photos, weight: 0, query: [2])) {
            XCTAssertEqual($0 as? EmbeddingError, .nonFiniteResult)
        }
        XCTAssertEqual(try search(photos, weight: 0.5, query: [2]).first?.score, Float.greatestFiniteMagnitude)
        XCTAssertEqual(try search(photos, weight: 1, query: [2]).first?.score, 0)
    }

    func testProduction512AndGenericOneDimensionalSearch() throws {
        var axis = [Float](repeating: 0, count: 512)
        axis[511] = 1
        let photos = [photo("512", axis, place: "A", location: axis)]
        XCTAssertEqual(try search(photos, weight: 0.5, query: axis).first?.score, 0.5)
        XCTAssertEqual(try search([photo("one", [-1])], weight: 0, query: [-1]).first?.score, 1)
    }

    func testSearchDoesNotMutateStoredInputs() throws {
        let photos = [photo("a", [1, 0], place: "A", location: [0, 1])]
        let hits = try search(photos, weight: 0.75)
        XCTAssertEqual(photos[0].imageEmbedding, [1, 0])
        XCTAssertEqual(photos[0].location?.vector, [0, 1])
        XCTAssertEqual(hits[0].photo.modificationTime, 123.5)
        XCTAssertEqual(hits[0].photo.modelVersion, "synthetic-pair")
    }
}