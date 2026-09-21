import XCTest
import UIKit
import ImageIO
@testable import LocalImageIQ

final class ImagePreprocessorTests: XCTestCase {
    func testKnownSolidColorUsesRGBNCHWAndExactNormalizationConstants() throws {
        let image = try TestFixtures.image(width: 29, height: 17) { _, _ in (255, 128, 0) }
        let values = try ImagePreprocessor.values(image: image)
        XCTAssertEqual(values.count, 3 * 224 * 224)
        for channel in 0..<3 {
            let raw: [Float] = [255, 128, 0]
            let expected = (raw[channel] / 255 - ImagePreprocessor.mean[channel]) / ImagePreprocessor.standardDeviation[channel]
            for position in [0, 100, 224 * 112 + 112, 224 * 224 - 1] {
                XCTAssertEqual(values[channel * 224 * 224 + position], expected, accuracy: 0.02)
            }
        }
    }

    func testEXIFRightOrientationRotatesClockwise() throws {
        let source = try quadrants()
        let rotated = try ImagePreprocessor.values(image: source, orientation: .right)
        assertPixel(rotated, x: 40, y: 40, rgb: [0, 0, 255])
        assertPixel(rotated, x: 180, y: 40, rgb: [255, 0, 0])
        assertPixel(rotated, x: 40, y: 180, rgb: [255, 255, 255])
        assertPixel(rotated, x: 180, y: 180, rgb: [0, 255, 0])
    }

    func testMirroredOrientationIsNotIgnored() throws {
        let values = try ImagePreprocessor.values(image: quadrants(), orientation: .upMirrored)
        assertPixel(values, x: 40, y: 40, rgb: [0, 255, 0])
        assertPixel(values, x: 180, y: 40, rgb: [255, 0, 0])
    }

    func testNonSquareImageIsCenterCroppedNotStretched() throws {
        let source = try TestFixtures.image(width: 448, height: 224) { x, _ in
            if x < 112 { return (255, 0, 0) }
            if x >= 336 { return (0, 0, 255) }
            return (0, 255, 0)
        }
        let values = try ImagePreprocessor.values(image: source)
        for x in [5, 112, 218] { assertPixel(values, x: x, y: 112, rgb: [0, 255, 0]) }
    }

    @MainActor
    func testDataDecodeAndCoreMLTensorShape() throws {
        let source = try TestFixtures.image(width: 19, height: 31) { _, _ in (255, 0, 0) }
        let data = try XCTUnwrap(UIImage(cgImage: source).pngData())
        let tensor = try ImagePreprocessor.tensor(data: data, orientation: .up)
        XCTAssertEqual(tensor.shape.map(\.intValue), [1, 3, 224, 224])
        XCTAssertEqual(tensor.dataType, .float32)
        XCTAssertEqual(tensor[0].floatValue, (1 - ImagePreprocessor.mean[0]) / ImagePreprocessor.standardDeviation[0], accuracy: 0.02)
    }

    func testOddCropRemainderUsesFloorLikeHFProcessor() throws {
        // width 227 -> left floor((227 - 224) / 2) = 1, not rounded-to-even 2.
        let image = try TestFixtures.image(width: 227, height: 224) { x, _ in
            x == 1 ? (255, 0, 0) : (0, 0, 0)
        }
        let values = try ImagePreprocessor.values(image: image)
        assertPixel(values, x: 0, y: 100, rgb: [255, 0, 0])
        assertPixel(values, x: 1, y: 100, rgb: [0, 0, 0])
    }

    func testInvalidImageDataThrows() {
        XCTAssertThrowsError(try ImagePreprocessor.values(data: Data([0, 1, 2])))
    }

    private func quadrants() throws -> CGImage {
        try TestFixtures.image(width: 224, height: 224) { x, y in
            if y < 112 { return x < 112 ? (255, 0, 0) : (0, 255, 0) }
            return x < 112 ? (0, 0, 255) : (255, 255, 255)
        }
    }

    private func assertPixel(_ values: [Float], x: Int, y: Int, rgb: [Float], file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            let expected = (rgb[channel] / 255 - ImagePreprocessor.mean[channel]) / ImagePreprocessor.standardDeviation[channel]
            XCTAssertEqual(values[channel * 224 * 224 + y * 224 + x], expected, accuracy: 0.02, file: file, line: line)
        }
    }
}