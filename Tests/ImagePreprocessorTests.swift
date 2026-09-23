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

    func testBilinearPixelsAreIndependentOfCGImageInterpolationHint() throws {
        func image(_ hint: Bool) throws -> CGImage {
            try TestFixtures.image(width: 2, height: 2, shouldInterpolate: hint) { x, y in
                (x == 1 ? 255 : 0, y == 1 ? 255 : 0, x == y ? 255 : 0)
            }
        }
        let withoutHint = try ImagePreprocessor.values(image: image(false))
        let withHint = try ImagePreprocessor.values(image: image(true))
        XCTAssertTrue(withoutHint.elementsEqual(withHint), "CG interpolation hints must not change resize pixels")

        // Independent four-pixel calculation: interpolate/round each source row,
        // then interpolate/round those bytes vertically. No production filters.
        let positions = [0, 55, 56, 70, 98, 111, 112, 126, 154, 167, 168, 223]
        for y in positions {
            let wy = min(1, max(0, (Double(y) + 0.5) / 112 - 0.5))
            for x in positions {
                let wx = min(1, max(0, (Double(x) + 0.5) / 112 - 0.5))
                let red = floor(255 * wx + 0.5)
                let green = floor(255 * wy + 0.5)
                let topBlue = floor(255 * (1 - wx) + 0.5)
                let bottomBlue = floor(255 * wx + 0.5)
                let blue = floor(topBlue * (1 - wy) + bottomBlue * wy + 0.5)
                assertExactPixel(withoutHint, x: x, y: y, rgb: [Float(red), Float(green), Float(blue)])
            }
        }
    }

    func testThumbnailSizedRampsMatchIndependentBilinearPixels() throws {
        // The two native-image dimensions that failed the SigLIP embedding gate.
        // Linear ramps give a closed-form pixel oracle without reimplementing
        // the production tap builder. Both use shouldInterpolate == false.
        let positions = [0, 1, 17, 55, 70, 98, 111, 112, 126, 154, 198, 222, 223]
        for (width, height) in [(68, 120), (112, 199)] {
            let source = try TestFixtures.image(width: width, height: height) { x, y in
                (UInt8(2 * x), UInt8(y), 127)
            }
            let values = try ImagePreprocessor.values(image: source)
            for y in positions {
                let sy = min(Double(height - 1), max(0, (Double(y) + 0.5) * Double(height) / 224 - 0.5))
                for x in positions {
                    let sx = min(Double(width - 1), max(0, (Double(x) + 0.5) * Double(width) / 224 - 0.5))
                    assertExactPixel(values, x: x, y: y,
                                     rgb: [Float(floor(2 * sx + 0.5)), Float(floor(sy + 0.5)), 127])
                }
            }
        }
    }

    func testIdentityResizePreservesEveryRGBByte() throws {
        let image = try TestFixtures.image(width: 224, height: 224) { x, y in
            (UInt8((3 * x + y) % 256), UInt8((x + 5 * y) % 256), UInt8((7 * x + 11 * y) % 256))
        }
        let values = try ImagePreprocessor.values(image: image)
        let pixels = 224 * 224
        XCTAssertEqual(values.count, 3 * pixels)
        for channel in 0..<3 {
            XCTAssertTrue((0..<pixels).allSatisfy { pixel in
                let x = pixel % 224
                let y = pixel / 224
                let rgb = [(3 * x + y) % 256, (x + 5 * y) % 256, (7 * x + 11 * y) % 256]
                let expected = (Float(rgb[channel]) / 255 - 0.5) / 0.5
                return values[channel * pixels + pixel] == expected
            }, "Identity must preserve every byte in RGB plane \(channel)")
        }
    }

    func testSinglePixelAndSingletonAxesHaveExactClampedBilinearValues() throws {
        let solid = try TestFixtures.image(width: 1, height: 1) { _, _ in (1, 128, 254) }
        let solidValues = try ImagePreprocessor.values(image: solid)
        let rgb: [Float] = [1, 128, 254]
        for channel in 0..<3 {
            let expected = (rgb[channel] / 255 - 0.5) / 0.5
            XCTAssertTrue(solidValues[(channel * 224 * 224)..<((channel + 1) * 224 * 224)]
                .allSatisfy { $0 == expected })
        }

        // Analytic 2 -> 224 half-pixel ramp, including both clamped borders.
        let samples: [(Int, Float)] = [(0, 0), (55, 0), (56, 1), (70, 33), (98, 97),
                                      (111, 126), (112, 129), (126, 161), (154, 224),
                                      (167, 254), (168, 255), (223, 255)]
        for (width, height) in [(2, 1), (1, 2)] {
            let source = try TestFixtures.image(width: width, height: height) { x, y in
                x + y == 0 ? (0, 255, 37) : (255, 0, 37)
            }
            let values = try ImagePreprocessor.values(image: source)
            for (position, red) in samples {
                for other in [0, 111, 223] {
                    assertExactPixel(values, x: width == 2 ? position : other,
                                     y: height == 2 ? position : other, rgb: [red, 255 - red, 37])
                }
            }
        }
    }

    func testPillow22BitCoefficientRoundingAtHalfByteTies() throws {
        let source = try TestFixtures.image(width: 2, height: 2) { x, y in
            (UInt8(x * 112), UInt8(y * 112), UInt8((x + y) * 112))
        }
        let values = try ImagePreprocessor.values(image: source)
        // Pinned from Pillow 11.1.0's published integer arithmetic, not a
        // floating-point bilinear oracle. At x=60 the right weight is 9/224:
        // round(2^22 * 9/224) = 168521, and
        // (112 * 168521 + 2^21) >> 22 = 4 (unquantized 4.5 rounds to 5).
        let samples: [(Int, Float)] = [(56, 1), (57, 2), (58, 3), (59, 4),
                                      (60, 4), (61, 5), (62, 6), (63, 8)]
        for (y, green) in samples {
            for (x, red) in samples {
                assertExactPixel(values, x: x, y: y, rgb: [red, green, red + green])
            }
        }
    }

    func testBilinearRoundsHorizontalBytesBeforeVerticalPass() throws {
        let source = try TestFixtures.image(width: 2, height: 2) { x, y in
            let value = UInt8(x + y)
            return (value, value, value)
        }
        let values = try ImagePreprocessor.values(image: source)
        // Source [[0, 1], [1, 2]]: at 111 the horizontal rows round to
        // [0, 1]; at 112 they round to [1, 2]. Rounding only once after a
        // floating-point 2-D blend would incorrectly produce 1 at both corners.
        assertExactPixel(values, x: 111, y: 111, rgb: [0, 0, 0])
        assertExactPixel(values, x: 112, y: 111, rgb: [1, 1, 1])
        assertExactPixel(values, x: 111, y: 112, rgb: [1, 1, 1])
        assertExactPixel(values, x: 112, y: 112, rgb: [2, 2, 2])
    }

    func testDownscaleCheckerboardUsesWidenedTriangleAndRenormalizedEdges() throws {
        let source = try TestFixtures.image(width: 448, height: 448) { x, y in
            (x.isMultiple(of: 2) ? 0 : 255, y.isMultiple(of: 2) ? 0 : 255,
             (x + y).isMultiple(of: 2) ? 0 : 255)
        }
        let values = try ImagePreprocessor.values(image: source)
        // Scale 2: interior taps [1,3,3,1]/8; left/top [3,3,1]/7,
        // right/bottom reversed. Pin bytes after EACH pass. A box filter,
        // nearest neighbor, or un-widened bilinear kernel fails the borders.
        for y in [0, 1, 111, 222, 223] {
            for x in [0, 1, 111, 222, 223] {
                let red: Float = x == 0 ? 109 : (x == 223 ? 146 : 128)
                let green: Float = y == 0 ? 109 : (y == 223 ? 146 : 128)
                let isCorner = (x == 0 || x == 223) && (y == 0 || y == 223)
                let blue: Float = isCorner ? (x == y ? 125 : 130) : 128
                assertExactPixel(values, x: x, y: y, rgb: [red, green, blue])
            }
        }
    }

    func testThreefoldDownscaleAntialiasesStepAndSinglePixelEdgeImpulses() throws {
        // Scale 3: interior [1,2,3,2,1]/9, first edge [2,3,2,1]/8.
        // The zero-valued endpoint tap has been omitted in this explanation.
        // A hard step leaks 1/9 into the preceding output, while an impulse
        // at the first/last input contributes 2/8 at the corresponding edge.
        let samples: [(Int, [Float])] = [
            (0, [0, 64, 0]), (1, [0, 0, 0]), (110, [0, 0, 0]),
            (111, [28, 0, 0]), (112, [227, 0, 0]), (113, [255, 0, 0]),
            (222, [255, 0, 0]), (223, [255, 0, 64]),
        ]
        for (width, height) in [(672, 1), (1, 672)] {
            let source = try TestFixtures.image(width: width, height: height) { x, y in
                let position = x + y
                return (position < 336 ? 0 : 255, position == 0 ? 255 : 0, position == 671 ? 255 : 0)
            }
            let values = try ImagePreprocessor.values(image: source)
            for (position, rgb) in samples {
                for other in [0, 112, 223] {
                    assertExactPixel(values, x: width == 672 ? position : other,
                                     y: height == 672 ? position : other, rgb: rgb)
                }
            }
        }
    }

    func testPremultipliedAlphaIsCompositedOverBlackBeforeBilinearResize() throws {
        // Premultiplied sRGB bytes: transparent, half-alpha, quarter-alpha, opaque.
        // Their RGB bytes are exactly the black-composited colors, NOT unpremultiplied.
        let bytes: [UInt8] = [0, 0, 0, 0, 32, 64, 96, 128, 1, 17, 63, 64, 13, 129, 251, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let source = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 8, space: space,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let opaque = try TestFixtures.image(width: 2, height: 2) { x, y in
            let offset = (y * 2 + x) * 4
            return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
        }
        let values = try ImagePreprocessor.values(image: source)
        let expected = try ImagePreprocessor.values(image: opaque)
        XCTAssertTrue(values.elementsEqual(expected), "Composite native pixels over black before filtering RGB")
        assertExactPixel(values, x: 0, y: 0, rgb: [0, 0, 0])
        assertExactPixel(values, x: 223, y: 0, rgb: [32, 64, 96])
        assertExactPixel(values, x: 0, y: 223, rgb: [1, 17, 63])
        assertExactPixel(values, x: 223, y: 223, rgb: [13, 129, 251])
    }

    func testEXIFReordersNativePixelsBeforeRoundedResizePasses() throws {
        // Independent explicit row-major permutations of a non-square 3x2 image.
        let cases: [(CGImagePropertyOrientation, Int, Int, [Int])] = [
            (.up, 3, 2, [0, 1, 2, 3, 4, 5]), (.upMirrored, 3, 2, [2, 1, 0, 5, 4, 3]),
            (.down, 3, 2, [5, 4, 3, 2, 1, 0]), (.downMirrored, 3, 2, [3, 4, 5, 0, 1, 2]),
            (.leftMirrored, 2, 3, [0, 3, 1, 4, 2, 5]), (.right, 2, 3, [3, 0, 4, 1, 5, 2]),
            (.rightMirrored, 2, 3, [5, 2, 4, 1, 3, 0]), (.left, 2, 3, [2, 5, 1, 4, 0, 3]),
        ]
        let colors: [(UInt8, UInt8, UInt8)] = [
            (0, 1, 253), (112, 127, 5), (7, 201, 91), (239, 3, 128), (17, 255, 31), (81, 61, 223),
        ]
        let source = try TestFixtures.image(width: 3, height: 2) { x, y in colors[y * 3 + x] }
        for (orientation, width, height, order) in cases {
            let reordered = try TestFixtures.image(width: width, height: height) { x, y in
                colors[order[y * width + x]]
            }
            let actual = try ImagePreprocessor.values(image: source, orientation: orientation)
            let expected = try ImagePreprocessor.values(image: reordered)
            XCTAssertTrue(actual.elementsEqual(expected), "All pixels after EXIF \(orientation.rawValue)")
        }
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

    private func assertExactPixel(_ values: [Float], x: Int, y: Int, rgb: [Float],
                                  file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            let expected = (rgb[channel] / 255 - 0.5) / 0.5
            XCTAssertEqual(values[channel * 224 * 224 + y * 224 + x], expected, accuracy: 1e-6,
                           "Pixel (\(x), \(y)), RGB channel \(channel)", file: file, line: line)
        }
    }
}