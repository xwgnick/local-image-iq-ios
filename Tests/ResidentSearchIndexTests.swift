import Foundation
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic vectors only. The unmodified public Core search is the oracle;
/// every comparison checks ALL returned rows, byte-exact IDs and Float bits.
final class ResidentSearchIndexTests: XCTestCase {
    private let weights: [Float] = [0, 0.2, 0.6, 1]
    private let limits = [0, 1, 12, Int.max]

    private func photo(
        _ id: String, _ vector: [Float], place: String? = nil,
        location: [Float] = [1, 0], revision: Double = 123
    ) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: revision, modelVersion: "resident-synthetic",
                     imageEmbedding: vector,
                     location: place.map { PlaceEmbedding(text: $0, vector: location) },
                     creationTime: revision - 1)
    }

    private func assertHits(
        _ actual: [SearchHit], _ expected: [SearchHit],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (got, wanted) in zip(actual, expected) {
            XCTAssertEqual(Array(got.id.utf8), Array(wanted.id.utf8), file: file, line: line)
            XCTAssertEqual(got.score.bitPattern, wanted.score.bitPattern, file: file, line: line)
            // Disambiguate duplicate IDs and ensure the original photos survive.
            XCTAssertEqual(got.photo.modificationTime, wanted.photo.modificationTime, file: file, line: line)
            XCTAssertEqual(got.photo.creationTime, wanted.photo.creationTime, file: file, line: line)
        }
    }

    @discardableResult
    private func assertOracle(
        _ index: ResidentSearchIndex, query: [Float], weight: Float, limit: Int = Int.max,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (hits: [SearchHit], fallbacks: Int) {
        let expected = try VectorSearch.search(query: query, photos: index.photos,
                                              limit: limit, locationWeight: weight)
        let actual = try index.searchMeasured(query: query, limit: limit, locationWeight: weight)
        assertHits(actual.hits, expected, file: file, line: line)
        XCTAssertGreaterThanOrEqual(actual.fallbacks, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(actual.fallbacks, index.photos.count, file: file, line: line)
        if limit == 0 { XCTAssertEqual(actual.fallbacks, 0, file: file, line: line) }
        return actual
    }

    private func assertEmbeddingError(
        _ expected: EmbeddingError, _ operation: () throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            XCTAssertEqual($0 as? EmbeddingError, expected, file: file, line: line)
        }
    }

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }

        mutating func vector(_ dimension: Int) throws -> [Float] {
            var values: [Float] = []
            values.reserveCapacity(dimension)
            for _ in 0..<dimension {
                let numerator = Int(next() >> 40) - 8_388_608
                values.append(Float(numerator) / 8_388_608)
            }
            return try EmbeddingMath.normalized(values)
        }
    }

    private func fixture(count: Int, dimension: Int, seed: UInt64) throws -> [IndexedPhoto] {
        var random = Generator(state: seed)
        var places: [[Float]] = []
        for _ in 0..<17 { places.append(try random.vector(dimension)) }
        var result: [IndexedPhoto] = []
        result.reserveCapacity(count)
        for row in 0..<count {
            let place = row % places.count
            result.append(photo("synthetic-\(row)", try random.vector(dimension),
                                place: row % 5 == 0 ? nil : "place-\(place)",
                                location: places[place], revision: Double(row)))
        }
        return result
    }

    func testSeeded768DimensionalAllWeightsAndLimitsMatchOracleBits() throws {
        let photos = try fixture(count: 128, dimension: 768, seed: 0x128768)
        let index = try ResidentSearchIndex(photos: photos)
        XCTAssertEqual(index.packedImageElementCount, 128 * 768)
        XCTAssertEqual(index.uniquePlaceCount, 17)
        var random = Generator(state: 0xABCDEF)
        for _ in 0..<3 {
            let query = try random.vector(768)
            for weight in weights {
                for limit in limits { try assertOracle(index, query: query, weight: weight, limit: limit) }
            }
        }
    }

    func testGenericDimensionsIncluding512DoNotRequireUnitVectors() throws {
        for dimension in [1, 2, 7, 512] {
            let input = try fixture(count: 33, dimension: dimension, seed: UInt64(dimension))
            let photos = input.map {
                IndexedPhoto(id: $0.id, modificationTime: $0.modificationTime, modelVersion: $0.modelVersion,
                             imageEmbedding: $0.imageEmbedding.map { $0 * 3 }, location: $0.location,
                             creationTime: $0.creationTime)
            }
            let index = try ResidentSearchIndex(photos: photos)
            let query = [Float](repeating: 2, count: dimension)
            for weight in weights {
                for limit in limits { try assertOracle(index, query: query, weight: weight, limit: limit) }
            }
        }
    }

    func testSharedPlacesAreValidatedOnceAndCenterIsNotFrequencyWeighted() throws {
        let base = [photo("a", [1, 0], place: "A"),
                    photo("b", [1, 0], place: "B", location: [-1, 0]),
                    photo("c", [1, 0], place: "C")]
        var expanded = base
        for row in 0..<30 { expanded.append(photo("copy-\(row)", [1, 0], place: "A")) }
        let small = try ResidentSearchIndex(photos: base)
        let large = try ResidentSearchIndex(photos: expanded)
        XCTAssertEqual(large.uniquePlaceCount, 3, "Equal vectors with different text are distinct places.")
        for weight in weights {
            let before = try assertOracle(small, query: [1, 0], weight: weight).hits
            let after = try assertOracle(large, query: [1, 0], weight: weight).hits
            for hit in before {
                XCTAssertEqual(after.first { $0.id == hit.id }?.score.bitPattern, hit.score.bitPattern)
            }
        }
    }

    func testPlaceUTF8IdentityAndSortedScalarCenterMatchCore() throws {
        let big = Float(sign: .plus, exponent: 60, significand: 1)
        let photos = [photo("one", [1, 0], place: "z", location: [1, 0]),
                      photo("two", [1, 0], place: "e\u{0301}", location: [-big, 0]),
                      photo("three", [1, 0], place: "A", location: [big, 0]),
                      photo("four", [1, 0], place: "\u{00E9}", location: [2, 0])]
        let index = try ResidentSearchIndex(photos: photos)
        XCTAssertEqual(index.uniquePlaceCount, 4)
        for weight in weights {
            try assertOracle(index, query: [1, 0], weight: weight)
            let reversed = try ResidentSearchIndex(photos: Array(photos.reversed()))
            assertHits(try reversed.search(query: [1, 0], limit: Int.max, locationWeight: weight),
                       try index.search(query: [1, 0], limit: Int.max, locationWeight: weight))
        }
    }

    func testInconsistentSameBytePlaceThrowsBeforeAnyZeroResult() {
        let photos = [photo("a", [1, 0], place: "same", location: [1, 0]),
                      photo("b", [1, 0], place: "same", location: [1, 1])]
        XCTAssertThrowsError(try ResidentSearchIndex(photos: photos)) {
            XCTAssertEqual($0 as? VectorSearchError, .inconsistentPlaceVector(text: "same"))
        }
        for weight in weights {
            for limit in limits {
                XCTAssertThrowsError(try VectorSearch.search(query: [1, 0], photos: photos,
                                                            limit: limit, locationWeight: weight)) {
                    XCTAssertEqual($0 as? VectorSearchError, .inconsistentPlaceVector(text: "same"))
                }
            }
        }
    }

    func testAllMissingLocationsKeepImageScaleAndFullWeightZeroTies() throws {
        let index = try ResidentSearchIndex(photos: [photo("z", [3, -2]), photo("a", [-8, 1]),
                                                    photo("b", [0.25, 9])])
        XCTAssertEqual(index.uniquePlaceCount, 0)
        for weight in weights {
            for limit in limits { try assertOracle(index, query: [1, -1], weight: weight, limit: limit) }
        }
        let hits = try index.search(query: [1, -1], limit: Int.max, locationWeight: 1)
        XCTAssertEqual(hits.map(\.id), ["a", "b", "z"])
        XCTAssertEqual(hits.map { $0.score.bitPattern }, [UInt32](repeating: 0, count: 3))
    }

    func testZeroVectorsSignedZerosAndSignedZeroPlaceEquality() throws {
        let minusZero = Float(bitPattern: 0x80000000)
        let index = try ResidentSearchIndex(photos: [
            photo("b", [minusZero, 0], place: "same", location: [minusZero, 0]),
            photo("a", [0, minusZero], place: "same", location: [0, minusZero]),
            photo("c", [1, -1])
        ])
        XCTAssertEqual(index.uniquePlaceCount, 1)
        let queries: [[Float]] = [[0, 0], [minusZero, minusZero], [1, 1], [-1, -1]]
        for query in queries {
            for weight in weights + [minusZero] { try assertOracle(index, query: query, weight: weight) }
        }
    }

    func testNegativeNonunitScoresUseCertifiedPathWithoutClamping() throws {
        let index = try ResidentSearchIndex(photos: [photo("a", [-3]), photo("b", [2]), photo("c", [0.25])])
        let result = try assertOracle(index, query: [2], weight: 0)
        XCTAssertEqual(result.fallbacks, 0, "Well inside Float rounding cells; no scalar image work is needed.")
        XCTAssertEqual(result.hits.map(\.score), [4, 0.5, -6])
        for weight in weights { try assertOracle(index, query: [-2], weight: weight) }
    }

    func testFloatRoundingMidpointsRequireExactScalarFallback() throws {
        let halfULP = Float(sign: .plus, exponent: -24, significand: 1)
        let small = Float(sign: .plus, exponent: -50, significand: 1)
        let index = try ResidentSearchIndex(photos: [
            photo("mid-positive", [1, halfULP, 0]), photo("mid-negative", [-1, -halfULP, 0]),
            photo("above", [1, halfULP, small]), photo("below", [1, halfULP, -small])
        ])
        let result = try assertOracle(index, query: [1, 1, 1], weight: 0)
        XCTAssertGreaterThanOrEqual(result.fallbacks, 2)
        XCTAssertEqual(result.hits.first { $0.id == "above" }?.score.bitPattern, Float(1).nextUp.bitPattern)
        XCTAssertEqual(result.hits.first { $0.id == "below" }?.score.bitPattern, Float(1).bitPattern)
        for weight in weights { try assertOracle(index, query: [1, 1, 1], weight: weight) }

        // The image dot itself is far from a midpoint; fusion creates one.
        let fusedBoundary = try ResidentSearchIndex(photos: [
            photo("a", [2], place: "A", location: [2 * halfULP]),
            photo("b", [2], place: "B", location: [-2 * halfULP])
        ])
        let fused = try assertOracle(fusedBoundary, query: [1], weight: 0.5)
        XCTAssertGreaterThanOrEqual(fused.fallbacks, 1)
    }

    func testCatastrophicCancellationUsesOriginalLeftToRightDot() throws {
        let big = Float(sign: .plus, exponent: 100, significand: 1)
        var first = [Float](repeating: 0, count: 768)
        first[0] = big; first[1] = 1; first[2] = -big
        var second = first
        second[1] = -1; second[767] = -2
        let index = try ResidentSearchIndex(photos: [photo("a", first), photo("b", second)])
        let result = try assertOracle(index, query: [Float](repeating: 1, count: 768), weight: 0)
        XCTAssertEqual(result.fallbacks, 2)
        XCTAssertEqual(result.hits.map(\.score), [0, -2])
    }

    func testFloatSubnormalsAndUnderflowPreserveNegativeZeroBits() throws {
        let index = try ResidentSearchIndex(photos: [
            photo("negative-zero", [-0.25]), photo("positive-zero", [0.25]),
            photo("half", [0.5]), photo("above-half", [Float(0.5).nextUp]),
            photo("below-half", [Float(0.5).nextDown]), photo("negative-half", [-0.5])
        ])
        let result = try assertOracle(index, query: [Float.leastNonzeroMagnitude], weight: 0)
        XCTAssertEqual(result.hits.first { $0.id == "negative-zero" }?.score.bitPattern, 0x80000000)
        XCTAssertEqual(result.hits.first { $0.id == "positive-zero" }?.score.bitPattern, 0)
        XCTAssertGreaterThanOrEqual(result.fallbacks, 2)
        for weight in weights {
            try assertOracle(index, query: [Float.leastNonzeroMagnitude], weight: weight)
            try assertOracle(index, query: [-Float.leastNonzeroMagnitude], weight: weight)
        }
    }

    func testExtremeFiniteImagesThrowOnlyWhenFinalFloatOverflows() throws {
        let photos = [photo("large", [Float.greatestFiniteMagnitude]), photo("small", [1])]
        let index = try ResidentSearchIndex(photos: photos)
        for limit in [1, Int.max] {
            assertEmbeddingError(.nonFiniteResult) {
                _ = try index.search(query: [2], limit: limit, locationWeight: 0)
            }
            assertEmbeddingError(.nonFiniteResult) {
                _ = try VectorSearch.search(query: [2], photos: photos, limit: limit, locationWeight: 0)
            }
        }
        try assertOracle(index, query: [2], weight: 0, limit: 0)
        let weighted = try assertOracle(index, query: [2], weight: 0.5)
        XCTAssertEqual(weighted.hits.first?.score, Float.greatestFiniteMagnitude)
        try assertOracle(index, query: [Float.greatestFiniteMagnitude], weight: 1)
        let cancelling = try ResidentSearchIndex(photos: [
            photo("cancel", [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude])
        ])
        let result = try assertOracle(cancelling, query: [Float.greatestFiniteMagnitude,
                                                         Float.greatestFiniteMagnitude], weight: 0)
        XCTAssertEqual(result.fallbacks, 1)

        // Even a low-ranked row that cannot enter top-1 must still be scored.
        let tail = [photo("winner", [1]), photo("negative-overflow", [-Float.greatestFiniteMagnitude])]
        let tailIndex = try ResidentSearchIndex(photos: tail)
        assertEmbeddingError(.nonFiniteResult) { _ = try tailIndex.search(query: [2], limit: 1, locationWeight: 0) }
        assertEmbeddingError(.nonFiniteResult) {
            _ = try VectorSearch.search(query: [2], photos: tail, limit: 1, locationWeight: 0)
        }
    }

    func testExtremePlaceProjectionsAreNotPrematurelyConvertedToFloat() throws {
        let big = Float.greatestFiniteMagnitude
        let photos = [photo("a", [0], place: "A", location: [big]),
                      photo("b", [0], place: "B", location: [-big]), photo("missing", [0])]
        let index = try ResidentSearchIndex(photos: photos)
        try assertOracle(index, query: [big], weight: 0)
        try assertOracle(index, query: [big], weight: 1, limit: 0)
        for limit in [1, Int.max] {
            assertEmbeddingError(.nonFiniteResult) {
                _ = try index.search(query: [big], limit: limit, locationWeight: 1)
            }
            assertEmbeddingError(.nonFiniteResult) {
                _ = try VectorSearch.search(query: [big], photos: photos, limit: limit, locationWeight: 1)
            }
        }
    }

    func testEmptyLibraryAcceptsEveryValidQueryDimensionButStillValidates() throws {
        let index = try ResidentSearchIndex(photos: [])
        XCTAssertEqual(index.packedImageElementCount, 0)
        XCTAssertEqual(index.uniquePlaceCount, 0)
        for dimension in [1, 2, 512, 768] {
            for weight in weights {
                for limit in limits {
                    try assertOracle(index, query: [Float](repeating: 0, count: dimension),
                                     weight: weight, limit: limit)
                }
            }
        }
        assertEmbeddingError(.emptyVector) { _ = try index.search(query: [], limit: 0, locationWeight: 0) }
        assertEmbeddingError(.nonFiniteValue(index: 0)) {
            _ = try index.search(query: [.nan], limit: 0, locationWeight: 0)
        }
    }

    func testInvalidImageShapesAndNonfiniteComponentsFailConstruction() {
        let vectors: [[Float]] = [[], [1], [1, 0, 0], [.nan, 0], [0, .infinity], [0, -.infinity]]
        let errors: [EmbeddingError] = [.emptyVector, .dimensionMismatch(expected: 2, actual: 1),
                                       .dimensionMismatch(expected: 2, actual: 3),
                                       .nonFiniteValue(index: 0), .nonFiniteValue(index: 1), .nonFiniteValue(index: 1)]
        for (vector, error) in zip(vectors, errors) {
            let photos = [photo("good", [1, 0]), photo("bad", vector)]
            assertEmbeddingError(error) { _ = try ResidentSearchIndex(photos: photos) }
            assertEmbeddingError(error) {
                _ = try VectorSearch.search(query: [1, 0], photos: photos, limit: 0, locationWeight: 1)
            }
        }
        assertEmbeddingError(.emptyVector) { _ = try ResidentSearchIndex(photos: [photo("first", [])]) }
    }

    func testInvalidPlaceVectorsFailEvenIfImageOnlyOrZeroLimitWasIntended() {
        let vectors: [[Float]] = [[], [1], [1, 0, 0], [.nan, 0], [0, .infinity], [0, -.infinity]]
        let errors: [EmbeddingError] = [.emptyVector, .dimensionMismatch(expected: 2, actual: 1),
                                       .dimensionMismatch(expected: 2, actual: 3),
                                       .nonFiniteValue(index: 0), .nonFiniteValue(index: 1), .nonFiniteValue(index: 1)]
        for (vector, error) in zip(vectors, errors) {
            let photos = [photo("bad-place", [1, 0], place: "place", location: vector)]
            assertEmbeddingError(error) { _ = try ResidentSearchIndex(photos: photos) }
            assertEmbeddingError(error) {
                _ = try VectorSearch.search(query: [1, 0], photos: photos, limit: 0, locationWeight: 0)
            }
        }
    }

    func testEveryNewQueryValidatesDimensionsAndFinitenessBeforeZeroResult() throws {
        let index = try ResidentSearchIndex(photos: [photo("a", [1, 0])])
        try assertOracle(index, query: [1, 0], weight: 0)
        let queries: [[Float]] = [[], [1], [1, 0, 0], [.nan, 0], [0, .infinity], [0, -.infinity],
                                  [.nan], [1, .infinity, 0]]
        // Core validates a photo against the query dimension, so mismatch error
        // expected/actual fields must retain that direction in the resident API.
        for query in queries {
            for limit in limits {
                var expected: EmbeddingError?
                do {
                    _ = try VectorSearch.search(query: query, photos: index.photos, limit: limit, locationWeight: 0)
                    XCTFail("Expected invalid query.")
                } catch { expected = error as? EmbeddingError }
                XCTAssertNotNil(expected)
                XCTAssertThrowsError(try index.search(query: query, limit: limit, locationWeight: 0)) {
                    XCTAssertEqual($0 as? EmbeddingError, expected)
                }
            }
        }
        try assertOracle(index, query: [0, 1], weight: 0)
    }

    func testInvalidWeightsAndNegativeLimitsKeepCoreErrorPrecedence() throws {
        for photos in [[], [photo("a", [1, 0])]] {
            let index = try ResidentSearchIndex(photos: photos)
            let invalidWeights: [Float] = [-0.001, 1.001, .nan, .infinity, -.infinity]
            for weight in invalidWeights {
                for limit in [-1, 0, Int.max] {
                    XCTAssertThrowsError(try index.search(query: [], limit: limit, locationWeight: weight)) {
                        XCTAssertEqual($0 as? VectorSearchError, .invalidLocationWeight)
                    }
                }
            }
            for limit in [-1, Int.min] {
                XCTAssertThrowsError(try index.search(query: [], limit: limit, locationWeight: 0)) {
                    XCTAssertEqual($0 as? VectorSearchError, .negativeLimit)
                }
            }
        }
    }

    func testByteExactIdentifierTiesKeepDuplicateIDsInInputOrder() throws {
        let photos = [photo("\u{00E9}", [1, 0], revision: 1), photo("e\u{0301}", [1, 0], revision: 2),
                      photo("same", [1, 0], revision: 3), photo("same", [1, 0], revision: 4),
                      photo("Z", [1, 0], revision: 5), photo("a", [1, 0], revision: 6)]
        for input in [photos, Array(photos.reversed())] {
            let index = try ResidentSearchIndex(photos: input)
            for weight in weights {
                for limit in limits { try assertOracle(index, query: [1, 0], weight: weight, limit: limit) }
            }
            let hits = try index.search(query: [1, 0], limit: Int.max, locationWeight: 0)
            XCTAssertEqual(hits.filter { $0.id == "same" }.map { $0.photo.modificationTime },
                           input.filter { $0.id == "same" }.map(\.modificationTime))
            XCTAssertEqual(hits.count, photos.count)
        }
    }

    func testInputPermutationsKeepEveryScoreAndOrderForUniqueIDs() throws {
        let photos = try fixture(count: 41, dimension: 7, seed: 0x777)
        let permutations = [photos, Array(photos.reversed()), Array(photos.dropFirst(13)) + Array(photos.prefix(13))]
        let baseline = try ResidentSearchIndex(photos: photos)
        let query: [Float] = [1, -2, 3, -4, 5, -6, 7]
        for weight in weights + [Float(1).nextDown] {
            let expected = try baseline.search(query: query, limit: Int.max, locationWeight: weight)
            for input in permutations {
                let index = try ResidentSearchIndex(photos: input)
                assertHits(try assertOracle(index, query: query, weight: weight).hits, expected)
            }
        }
    }

    func testSnapshotRetainsOriginalFloatBitsAndDifferentQueriesAreNotCached() throws {
        var input = [photo("a", [2, -0.0], place: "A", location: [1, 0]),
                     photo("b", [-1, 1], place: "B", location: [0, 1])]
        let index = try ResidentSearchIndex(photos: input)
        input[0] = photo("replacement", [9, 9])
        XCTAssertEqual(index.photos[0].imageEmbedding.map(\.bitPattern), [Float(2).bitPattern, Float(-0.0).bitPattern])
        XCTAssertEqual(index.photos[0].location?.vector, [1, 0])
        XCTAssertEqual(index.photos[0].modelVersion, "resident-synthetic")
        let first = try assertOracle(index, query: [1, 0], weight: 0.2)
        let second = try assertOracle(index, query: [-1, 0], weight: 0.2)
        let again = try assertOracle(index, query: [1, 0], weight: 0.2)
        XCTAssertNotEqual(first.hits.map(\.id), second.hits.map(\.id))
        assertHits(first.hits, again.hits)
        XCTAssertEqual(first.fallbacks, again.fallbacks)
        XCTAssertEqual(index.packedImageElementCount, 4)
        XCTAssertEqual(index.uniquePlaceCount, 2)
        assertHits(try index.search(query: [1, 0], limit: Int.max, locationWeight: 0.2), first.hits)
    }

    func testCancelledConstructionNeverPublishesEvenAnEmptyIndex() async {
        let inputs: [[IndexedPhoto]] = [[], [photo("a", [1, 0])]]
        for input in inputs {
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try ResidentSearchIndex(photos: input)
            }
            do { _ = try await task.value; XCTFail("Expected cancellation.") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testCancelledSearchNeverPublishesEvenAnEmptyOrZeroLimitResult() async throws {
        let indexes = [try ResidentSearchIndex(photos: []),
                       try ResidentSearchIndex(photos: [photo("a", [1, 0])])]
        for index in indexes {
            for limit in [0, 1, Int.max] {
                let task = Task.detached {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try index.search(query: [1, 0], limit: limit, locationWeight: 0.6)
                }
                do { _ = try await task.value; XCTFail("Expected cancellation.") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
        }
    }

    /// One native performance case, not XCTest's repeated measure loop. Three
    /// distinct queries against exactly the same 8,000-row candidate pool.
    /// Includes full validation/place work/sorting in each Core search, and all
    /// query validation/place work/corrections/sorting in each resident search.
    /// Excludes SQLite, text encoders, Photos, and any end-to-end/10x claim.
    func testNativeTimings8000By768ThreeDistinctQueriesWithExactResults() throws {
        let rowCount = 8_000
        let dimension = 768
        let photos = try fixture(count: rowCount, dimension: dimension, seed: 0x8000768)
        var random = Generator(state: 0x54321)
        var queries: [[Float]] = []
        for _ in 0..<3 { queries.append(try random.vector(dimension)) }
        XCTAssertNotEqual(queries[0], queries[1])
        XCTAssertNotEqual(queries[1], queries[2])
        XCTAssertNotEqual(queries[0], queries[2])

        let buildStart = ProcessInfo.processInfo.systemUptime
        let index = try ResidentSearchIndex(photos: photos)
        let buildMS = (ProcessInfo.processInfo.systemUptime - buildStart) * 1_000
        XCTAssertEqual(index.packedImageElementCount, rowCount * dimension)
        var originalMS: [Double] = []
        var residentMS: [Double] = []
        var original: [[SearchHit]] = []
        var resident: [[SearchHit]] = []
        var fallbacks: [Int] = []
        for query in queries {
            let start = ProcessInfo.processInfo.systemUptime
            let hits = try VectorSearch.search(query: query, photos: photos, limit: Int.max, locationWeight: 0.6)
            originalMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            original.append(hits)
        }
        for query in queries {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try index.searchMeasured(query: query, limit: Int.max, locationWeight: 0.6)
            residentMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            resident.append(result.hits)
            fallbacks.append(result.fallbacks)
        }
        // Correctness assertions are outside both timed regions. No time-based
        // pass/fail, speedup requirement, repeated-query cache, or 50-batch loop.
        var exactAllHitBits = true
        for query in queries.indices {
            let actual = resident[query]
            let expected = original[query]
            assertHits(actual, expected)
            if actual.count != expected.count || !zip(actual, expected).allSatisfy({ pair in
                pair.0.id.utf8.elementsEqual(pair.1.id.utf8)
                    && pair.0.score.bitPattern == pair.1.score.bitPattern
                    && pair.0.photo.modificationTime == pair.1.photo.modificationTime
            }) {
                exactAllHitBits = false
            }
        }
        let evidence: [String: Any] = [
            "scope": "synthetic resident search only; not SQLite or end-to-end",
            "rows": rowCount, "dimension": dimension, "distinct_queries": queries.count,
            "limit": "all", "location_weight": 0.6,
            "packed_matrix_bytes": index.packedImageElementCount * MemoryLayout<Double>.stride,
            "retained_image_float32_payload_bytes": rowCount * dimension * MemoryLayout<Float>.stride,
            "unique_places": index.uniquePlaceCount, "build_ms": buildMS,
            "original_ms": originalMS, "accelerated_ms": residentMS,
            "original_ms_total": originalMS.reduce(0, +), "accelerated_ms_total": residentMS.reduce(0, +),
            "matrix_batches": queries.count, "matrix_image_dots": queries.count * rowCount,
            "scalar_image_fallbacks": fallbacks, "exact_all_hit_bits": exactAllHitBits
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(string: String(decoding: data, as: UTF8.self))
        attachment.name = "TIMINGS-ResidentSearchIndex-8000x768"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}