import XCTest
import CoreGraphics
@testable import LocalImageIQ

final class SearchQueryChipLayoutTests: XCTestCase {
    func testFittingShortLabelsKeepTheirOwnWidthsAndUnusedTrailingSpace() {
        let result = allocate([52, 96, 72], width: 353)
        assertWidths(result, [52, 96, 72])
        XCTAssertEqual(result.spacing, 6)
        XCTAssertLessThan(result.widths.reduce(0, +) + 12, 353)
    }

    func testOverflowScalesMeasuredContentInsteadOfAssigningEqualColumns() {
        let result = allocate([100, 200, 300], width: 312)
        assertWidths(result, [50, 100, 150])
    }

    func testShortChipFreezesAtMinimumAndLongChipsShareRemainingWidth() {
        assertWidths(allocate([44, 100, 300], width: 312), [44, 64, 192])
    }

    func testRedistributionCanFreezeAnotherChipOnTheNextPass() {
        // The 60-point chip initially scales below 44; after both shorter
        // chips freeze, the only long label receives all remaining space.
        assertWidths(allocate([44, 60, 500], width: 312), [44, 44, 212])
        // Here 70 initially scales ABOVE 44, then falls below after the first
        // minimum is reserved. This exercises a second redistribution pass.
        assertWidths(allocate([44, 70, 350], width: 312), [44, 44, 212])
    }

    func testReorderedHistoryMovesWidthsWithContentNotWithIndex() {
        let original: [CGFloat] = [44, 100, 300]
        let expected: [CGFloat] = [44, 64, 192]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            assertWidths(allocate(order.map { original[$0] }, width: 312), order.map { expected[$0] })
        }
    }

    func testViewportChangesReallocateAndRestoreWithoutRememberingOldWidths() {
        let ideal: [CGFloat] = [44, 100, 300]
        assertWidths(allocate(ideal, width: 280), [44, 56, 168])
        assertWidths(allocate(ideal, width: 353), [44, 74.25, 222.75])
        assertWidths(allocate(ideal, width: 500), ideal)
        assertWidths(allocate(ideal, width: 280), [44, 56, 168])
    }

    func testChangedFontMeasurementsUseNewIntrinsicWidths() {
        assertWidths(allocate([44, 100, 300], width: 312), [44, 64, 192])
        assertWidths(allocate([88, 200, 600], width: 312), [44, 64, 192])
        assertWidths(allocate([100, 100, 100], width: 312), [100, 100, 100])
        assertWidths(allocate([100, 200, 100], width: 312), [75, 150, 75])
    }

    func testGapsShrinkBeforeAnyTouchTargetWhenViewportSupportsThreeTimes44() {
        for (width, gap) in [(CGFloat(132), CGFloat(0)), (140, 4), (144, 6)] {
            let result = allocate([44, 100, 300], width: width)
            assertWidths(result, [44, 44, 44])
            XCTAssertEqual(result.spacing, gap)
            XCTAssertEqual(result.widths.reduce(0, +) + gap * 2, width, accuracy: 0.000001)
        }
    }

    func testImpossibleMinimumStillKeepsOneBoundedContentProportionalRow() {
        let result = allocate([50, 100, 300], width: 120)
        XCTAssertEqual(result.spacing, 0)
        assertWidths(result, [120 * 50 / 450, 120 * 100 / 450, 80])
        assertWidths(allocate([50, 100, 300], width: 0), [0, 0, 0])
    }

    func testEmptySingleAndUnderMinimumIntrinsicWidths() {
        assertWidths(allocate([], width: 353), [])
        assertWidths(allocate([12], width: 353), [44])
        XCTAssertEqual(allocate([12], width: 353).spacing, 0)
        assertWidths(allocate([500], width: 353), [353])
        assertWidths(allocate([10, 20, 30], width: 353), [44, 44, 44])
    }

    private func allocate(_ ideal: [CGFloat], width: CGFloat) -> SearchQueryChipAllocation {
        SearchQueryChipAllocation(intrinsicWidths: ideal, availableWidth: width)
    }

    private func assertWidths(_ result: SearchQueryChipAllocation, _ expected: [CGFloat],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.widths.count, expected.count, file: file, line: line)
        for (actual, width) in zip(result.widths, expected) {
            XCTAssertEqual(actual, width, accuracy: 0.000001, file: file, line: line)
        }
    }
}