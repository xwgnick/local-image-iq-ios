import XCTest
@testable import ImageIQCore

final class EmbeddingMathTests: XCTestCase {
    func testNormalizesThreeFourWithoutMutatingInput() throws {
        let raw: [Float] = [3, 4]
        let unit = try EmbeddingMath.normalized(raw)
        XCTAssertEqual(unit[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(unit[1], 0.8, accuracy: 0.000001)
        XCTAssertEqual(try EmbeddingMath.dot(unit, unit), 1, accuracy: 0.000001)
        XCTAssertEqual(raw, [3, 4])
    }

    func testNormalizesPairedModelDimension512() throws {
        let raw = (0..<512).map { Float($0 - 256) }
        let unit = try EmbeddingMath.normalized(raw)
        XCTAssertEqual(unit.count, 512)
        XCTAssertEqual(try EmbeddingMath.dot(unit, unit), 1, accuracy: 0.000001)
    }

    func testOneDimensionalSigns() throws {
        XCTAssertEqual(try EmbeddingMath.normalized([12]), [1])
        XCTAssertEqual(try EmbeddingMath.normalized([-12]), [-1])
    }

    func testZeroVectorCannotBeNormalized() {
        XCTAssertThrowsError(try EmbeddingMath.normalized([0, -0.0])) {
            XCTAssertEqual($0 as? EmbeddingError, .zeroNorm)
        }
    }

    func testEmptyVectorsAreRejected() {
        XCTAssertThrowsError(try EmbeddingMath.normalized([])) {
            XCTAssertEqual($0 as? EmbeddingError, .emptyVector)
        }
        XCTAssertThrowsError(try EmbeddingMath.dot([], []))
        XCTAssertThrowsError(try EmbeddingMath.dot([1], []))
    }

    func testMismatchedDimensionsAreRejected() {
        XCTAssertThrowsError(try EmbeddingMath.dot([1, 2], [1])) {
            XCTAssertEqual($0 as? EmbeddingError, .dimensionMismatch(expected: 2, actual: 1))
        }
    }

    func testNonFiniteComponentsAreRejected() {
        for bad in [Float.nan, Float.infinity, -Float.infinity] {
            XCTAssertThrowsError(try EmbeddingMath.normalized([1, bad])) {
                XCTAssertEqual($0 as? EmbeddingError, .nonFiniteValue(index: 1))
            }
            XCTAssertThrowsError(try EmbeddingMath.dot([1, bad], [1, 0]))
            XCTAssertThrowsError(try EmbeddingMath.dot([1, 0], [bad, 1]))
        }
    }

    func testDotIsInnerProductNotCosine() throws {
        XCTAssertEqual(try EmbeddingMath.dot([2, 3], [4, -1]), 5)
        XCTAssertEqual(try EmbeddingMath.dot([1, 0], [-1, 0]), -1)
    }

    func testFiniteZeroDotIsAllowed() throws {
        XCTAssertEqual(try EmbeddingMath.dot([0, 0], [2, 3]), 0)
    }

    func testExtremeFiniteFloatsNormalizeWithoutOverflowOrUnderflow() throws {
        let largest = Float.greatestFiniteMagnitude
        let large = try EmbeddingMath.normalized([largest, -largest])
        let component = Float(1 / Double(2).squareRoot())
        XCTAssertEqual(large[0], component, accuracy: 0.000001)
        XCTAssertEqual(large[1], -component, accuracy: 0.000001)
        let tiny = try EmbeddingMath.normalized([Float.leastNonzeroMagnitude, 0])
        XCTAssertEqual(tiny, [1, 0])
    }

    func testUnrepresentableDotThrowsInsteadOfReturningInfinity() {
        XCTAssertThrowsError(try EmbeddingMath.dot([Float.greatestFiniteMagnitude], [2])) {
            XCTAssertEqual($0 as? EmbeddingError, .nonFiniteResult)
        }
    }

    func testDotAccumulatesBeforeConvertingToFloat() throws {
        let value = Float.greatestFiniteMagnitude
        XCTAssertEqual(try EmbeddingMath.dot([value, value], [2, -2]), 0)
    }
}