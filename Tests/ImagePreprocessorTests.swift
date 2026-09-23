import XCTest
import UIKit
import CoreML
import ImageIO
@testable import LocalImageIQ

final class ImagePreprocessorTests: XCTestCase {
    func testKnownSolidColorUsesRGBNCHWAndExactNormalizationConstants() throws {
        let image = try TestFixtures.image(width: 29, height: 17) { _, _ in (255, 128, 0) }
        let values = try ImagePreprocessor.values(image: image)
        XCTAssertEqual(values.count, 3 * 224 * 224)
        XCTAssertEqual(ImagePreprocessor.mean, [0.5, 0.5, 0.5])
        XCTAssertEqual(ImagePreprocessor.standardDeviation, [0.5, 0.5, 0.5])
        for channel in 0..<3 {
            let raw: [Float] = [255, 128, 0]
            let expected = (raw[channel] / 255 - 0.5) / 0.5
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

    func testNonSquareFullImageWarpPreservesDistinctPixelsOnAllFourSides() throws {
        for (width, height) in [(448, 224), (224, 448)] {
            let source = try TestFixtures.image(width: width, height: height) { x, y in
                if x < width / 4 { return (255, 0, 0) }
                if x >= 3 * width / 4 { return (0, 0, 255) }
                if y < height / 4 { return (255, 255, 0) }
                if y >= 3 * height / 4 { return (255, 0, 255) }
                return (0, 255, 0)
            }
            let values = try ImagePreprocessor.values(image: source)
            XCTAssertEqual(values.count, 3 * 224 * 224)
            // Center-cropping loses the red/blue sides in landscape and the
            // yellow/magenta sides in portrait; letterboxing also fails here.
            assertPixel(values, x: 5, y: 112, rgb: [255, 0, 0])
            assertPixel(values, x: 218, y: 112, rgb: [0, 0, 255])
            assertPixel(values, x: 112, y: 5, rgb: [255, 255, 0])
            assertPixel(values, x: 112, y: 218, rgb: [255, 0, 255])
            assertPixel(values, x: 112, y: 112, rgb: [0, 255, 0])
        }
    }

    @MainActor
    func testDataDecodeAndCoreMLTensorShape() throws {
        let source = try TestFixtures.image(width: 19, height: 31) { _, _ in (255, 0, 0) }
        let data = try XCTUnwrap(UIImage(cgImage: source).pngData())
        let tensor = try ImagePreprocessor.tensor(data: data, orientation: .up)
        XCTAssertEqual(tensor.shape.map(\.intValue), [1, 3, 224, 224])
        XCTAssertEqual(tensor.dataType, .float32)
        XCTAssertEqual(tensor[0].floatValue, 1, accuracy: 0.02)
    }

    func testOddNonSquareDimensionsPreserveOppositeEdgeBands() throws {
        // Odd extents are warped in full, not assigned a floor/rounded crop offset.
        let image = try TestFixtures.image(width: 451, height: 227) { x, y in
            if x < 56 { return (255, 0, 0) }
            if x >= 395 { return (0, 0, 255) }
            if y < 28 { return (255, 255, 0) }
            if y >= 199 { return (0, 255, 255) }
            return (0, 0, 0)
        }
        let values = try ImagePreprocessor.values(image: image)
        assertPixel(values, x: 0, y: 100, rgb: [255, 0, 0])
        assertPixel(values, x: 223, y: 100, rgb: [0, 0, 255])
        assertPixel(values, x: 112, y: 0, rgb: [255, 255, 0])
        assertPixel(values, x: 112, y: 223, rgb: [0, 255, 255])
        assertPixel(values, x: 112, y: 100, rgb: [0, 0, 0])
    }

    func testSquareWarpInterpolatesBothAxesWithBilinearWeights() throws {
        // Permit interpolation on this CGImage; other pixel fixtures keep their
        // existing hint so this test does not silently alter their rendering.
        let source = try TestFixtures.image(width: 2, height: 2, shouldInterpolate: true) { x, y in
            (x == 1 ? 255 : 0, y == 1 ? 255 : 0, x == y ? 255 : 0)
        }
        let values = try ImagePreprocessor.values(image: source)
        for y in [70, 98, 126, 154] {
            for x in [70, 98, 126, 154] {
                // Independent half-pixel, separable bilinear interpolation of
                // four known source pixels, sampled away from clamped borders.
                let wx = (Float(x) + 0.5) * 2 / 224 - 0.5
                let wy = (Float(y) + 0.5) * 2 / 224 - 0.5
                let rgb = [wx, wy, (1 - wx) * (1 - wy) + wx * wy]
                for channel in 0..<3 {
                    XCTAssertEqual(values[channel * 224 * 224 + y * 224 + x],
                                   (rgb[channel] - 0.5) / 0.5, accuracy: 0.02)
                }
            }
        }
        // This is a native interpolation contract, not a claim of pixel-identical
        // Pillow antialiased downsampling; real-model parity is tested separately.
    }

    func testInvalidImageDataThrows() {
        XCTAssertThrowsError(try ImagePreprocessor.values(data: Data([0, 1, 2])))
    }

    func testDirectPreviewTensorMatchesOriginalDataForAllEXIFOrientations() throws {
        let orientations: [CGImagePropertyOrientation] = [
            .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
        ]
        var comparisons = 0
        for (width, height) in [(319, 231), (231, 319)] {
            let source = try TestFixtures.image(width: width, height: height) { x, y in
                (UInt8((3 * x + y) % 256), UInt8((5 * y) % 256),
                 x < width / 3 && y < height / 2 ? 250 : 30)
            }
            for orientation in orientations {
                try autoreleasepool {
                    // Lossless bytes are an original-data control, not a production preview round-trip.
                    let data = try pngData(source, orientation: orientation)
                    let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                    XCTAssertEqual(decoded.width, width)
                    XCTAssertEqual(decoded.height, height) // ImageIO must leave these raw pixels unoriented.
                    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
                    XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
                                   orientation.rawValue)
                    let preview = IndexingImage(cgImage: source, orientation: orientation, source: .localPreview)
                    let direct = try tensorValues(ImagePreprocessor.tensor(image: preview.cgImage,
                                                                          orientation: preview.orientation))
                    let original = try tensorValues(ImagePreprocessor.tensor(data: data, orientation: orientation))
                    let label = "\(width)x\(height), EXIF \(orientation.rawValue)"
                    XCTAssertTrue(direct.elementsEqual(original), "Direct CG vs original-data tensor: \(label)")
                    XCTAssertTrue(direct.elementsEqual(try ImagePreprocessor.values(data: data)),
                                  "Explicit preview vs embedded EXIF: \(label)")
                    comparisons += 1
                }
            }
        }
        XCTAssertEqual(comparisons, 16)
    }

    func testDirectPreviewTensorHasFiniteNCHWAndPinnedNormalization() throws {
        let source = try TestFixtures.image(width: 29, height: 17) { _, _ in (31, 127, 223) }
        // Exercise the default .up argument; pin expectations independently of production constants.
        let values = try tensorValues(ImagePreprocessor.tensor(image: source))
        let rgb: [Float] = [31, 127, 223]
        let mean: [Float] = [0.5, 0.5, 0.5]
        let std: [Float] = [0.5, 0.5, 0.5]
        let pixels = 224 * 224
        for channel in 0..<3 {
            let expected = (rgb[channel] / 255 - mean[channel]) / std[channel]
            let plane = values[(channel * pixels)..<((channel + 1) * pixels)]
            XCTAssertTrue(plane.allSatisfy { abs($0 - expected) <= 1e-5 }, "RGB plane \(channel)")
        }
    }

    func testDirectPreviewTensorOrientsNonSquareQuadrantsForEveryEXIFOrientation() throws {
        // Independent expected TL/TR/BL/BR source quadrant indices, not production
        // transforms. Both landscape and portrait exercise axis-swapping EXIF.
        let cases: [(CGImagePropertyOrientation, [Int])] = [
            (.up, [0, 1, 2, 3]), (.upMirrored, [1, 0, 3, 2]),
            (.down, [3, 2, 1, 0]), (.downMirrored, [2, 3, 0, 1]),
            (.leftMirrored, [0, 2, 1, 3]), (.right, [2, 0, 3, 1]),
            (.rightMirrored, [3, 1, 2, 0]), (.left, [1, 3, 0, 2]),
        ]
        let colors: [[Float]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 255]]
        let positions = [(40, 40), (180, 40), (40, 180), (180, 180)]
        for (width, height) in [(448, 224), (224, 448)] {
            let source = try quadrants(width: width, height: height)
            for (orientation, expected) in cases {
                let preview = IndexingImage(cgImage: source, orientation: orientation, source: .localReducedPreview)
                let values = try tensorValues(ImagePreprocessor.tensor(image: preview.cgImage, orientation: preview.orientation))
                for (position, colorIndex) in zip(positions, expected) {
                    assertPixel(values, x: position.0, y: position.1, rgb: colors[colorIndex])
                }
            }
        }
    }

    private func pngData(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: NSNumber(value: orientation.rawValue)] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func tensorValues(_ tensor: MLMultiArray) throws -> [Float] {
        XCTAssertEqual(tensor.dataType, .float32)
        XCTAssertEqual(tensor.shape.map(\.intValue), [1, 3, 224, 224])
        XCTAssertEqual(tensor.count, 3 * 224 * 224)
        // Validate before coordinate subscripting so a bad shape fails without an out-of-bounds access.
        guard tensor.dataType == .float32, tensor.shape.map(\.intValue) == [1, 3, 224, 224] else {
            throw AppFailure.modelContract("Expected Float32 NCHW [1,3,224,224] in test.")
        }
        var values: [Float] = []
        values.reserveCapacity(tensor.count)
        for channel in 0..<3 {
            for y in 0..<224 {
                for x in 0..<224 {
                    values.append(tensor[[0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]].floatValue)
                }
            }
        }
        XCTAssertTrue(values.allSatisfy(\.isFinite))
        return values
    }

    private func quadrants(width: Int = 448, height: Int = 224) throws -> CGImage {
        try TestFixtures.image(width: width, height: height) { x, y in
            if y < height / 2 { return x < width / 2 ? (255, 0, 0) : (0, 255, 0) }
            return x < width / 2 ? (0, 0, 255) : (255, 255, 255)
        }
    }

    private func assertPixel(_ values: [Float], x: Int, y: Int, rgb: [Float], file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            let expected = (rgb[channel] / 255 - 0.5) / 0.5
            XCTAssertEqual(values[channel * 224 * 224 + y * 224 + x], expected, accuracy: 0.02, file: file, line: line)
        }
    }
}