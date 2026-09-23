import Foundation
import UIKit
import CoreML
import ImageIO

/*
 The bilinear resampler below is a Swift adaptation of the numeric rules in
 Pillow 11.1.0, src/libImaging/Resample.c (BILINEAR, precompute_coeffs,
 normalize_coeffs_8bpc and the two 8-bit passes):
 https://github.com/python-pillow/Pillow/blob/11.1.0/src/libImaging/Resample.c
 License: https://github.com/python-pillow/Pillow/blob/11.1.0/LICENSE

 The Python Imaging Library (PIL) is
 Copyright © 1997-2011 by Secret Labs AB
 Copyright © 1995-2011 by Fredrik Lundh and contributors
 Pillow is the friendly PIL fork. It is
 Copyright © 2010 by Jeffrey A. Clark and contributors

 Like PIL, Pillow is licensed under the open source MIT-CMU License:

 By obtaining, using, and/or copying this software and/or its associated
 documentation, you agree that you have read, understood, and will comply
 with the following terms and conditions:

 Permission to use, copy, modify and distribute this software and its
 documentation for any purpose and without fee is hereby granted,
 provided that the above copyright notice appears in all copies, and that
 both that copyright notice and this permission notice appear in supporting
 documentation, and that the name of Secret Labs AB or the author not be
 used in advertising or publicity pertaining to distribution of the software
 without specific, written prior permission.

 SECRET LABS AB AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS
 SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.
 IN NO EVENT SHALL SECRET LABS AB OR THE AUTHOR BE LIABLE FOR ANY SPECIAL,
 INDIRECT OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
 LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE
 OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 PERFORMANCE OF THIS SOFTWARE.
 */

enum ImagePreprocessor {
    static let size = 224
    static let mean: [Float] = [0.5, 0.5, 0.5]
    static let standardDeviation: [Float] = [0.5, 0.5, 0.5]

    /// EXIF orientation -> sRGB -> full-image 224-square warp -> Float32 NCHW.
    /// Resize follows Pillow 11.1.0 RGB BILINEAR, including antialiased downscale
    /// and separate 8-bit rounding after each pass. Quartz only decodes/converts
    /// native pixels to sRGB and composites alpha over black; it never resizes.
    /// Native/reference embedding cosine >= 0.995 remains a release gate.
    static func values(data: Data, orientation: CGImagePropertyOrientation? = nil) throws -> [Float] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppFailure.photo("The image could not be decoded.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let effectiveOrientation = orientation ?? CGImagePropertyOrientation(rawValue: raw) ?? .up
        return try values(image: decoded, orientation: effectiveOrientation)
    }

    static func values(image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Float] {
        guard image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw AppFailure.photo("Unable to prepare the image's RGB pixels.")
        }
        let layout = try orientedLayout(width: image.width, height: image.height, orientation: orientation)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                         bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw AppFailure.photo("Unable to allocate RGB preprocessing buffer.")
            }
            bitmap.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            bitmap.fill(bounds)
            // Exactly one device pixel per source pixel, with no transform or
            // interpolation, regardless of CGImage.shouldInterpolate.
            bitmap.interpolationQuality = .none
            bitmap.setShouldAntialias(false)
            bitmap.draw(image, in: bounds)
        }
        let rgb = bilinearRGB(rgba, layout: layout)
        let pixels = size * size
        var result = [Float](repeating: 0, count: 3 * pixels)
        for channel in 0..<3 {
            for pixel in 0..<pixels {
                result[channel * pixels + pixel] =
                    (Float(rgb[pixel * 3 + channel]) / 255 - mean[channel]) / standardDeviation[channel]
            }
        }
        return result
    }

    private struct PixelLayout {
        let width: Int
        let height: Int
        let origin: Int
        let xStep: Int
        let yStep: Int
    }

    /// Address native RGBA rows in EXIF-oriented, top-left pixel order without
    /// allocating a second full-resolution bitmap. Orient BEFORE resizing:
    /// rotating the result instead would swap the order of 8-bit pass rounding.
    private static func orientedLayout(width: Int, height: Int,
                                       orientation: CGImagePropertyOrientation) throws -> PixelLayout {
        let row = width * 4
        let right = (width - 1) * 4
        let bottom = (height - 1) * row
        switch orientation {
        case .up:
            return PixelLayout(width: width, height: height, origin: 0, xStep: 4, yStep: row)
        case .upMirrored:
            return PixelLayout(width: width, height: height, origin: right, xStep: -4, yStep: row)
        case .down:
            return PixelLayout(width: width, height: height, origin: bottom + right, xStep: -4, yStep: -row)
        case .downMirrored:
            return PixelLayout(width: width, height: height, origin: bottom, xStep: 4, yStep: -row)
        case .leftMirrored:
            return PixelLayout(width: height, height: width, origin: 0, xStep: row, yStep: 4)
        case .right:
            return PixelLayout(width: height, height: width, origin: bottom, xStep: -row, yStep: 4)
        case .rightMirrored:
            return PixelLayout(width: height, height: width, origin: bottom + right, xStep: -row, yStep: -4)
        case .left:
            return PixelLayout(width: height, height: width, origin: right, xStep: row, yStep: -4)
        @unknown default:
            throw AppFailure.photo("Unsupported image orientation.")
        }
    }

    private static let coefficientBits = 22
    private static let coefficientScale = 1 << coefficientBits
    private static let roundingBias = 1 << (coefficientBits - 1)

    private struct AxisFilter {
        let start: Int
        let coefficients: [Int]
    }

    private static func bilinearFilters(inputSize: Int) -> [AxisFilter] {
        if inputSize == size {
            // Exact identity taps, including when just one axis needs resizing.
            return (0..<size).map { AxisFilter(start: $0, coefficients: [coefficientScale]) }
        }
        let scale = Double(inputSize) / Double(size)
        let filterScale = max(1, scale)
        let inverseFilterScale = 1 / filterScale
        return (0..<size).map { output in
            let center = (Double(output) + 0.5) * scale
            // Int truncates toward zero, as in Pillow's C bounds calculation.
            // Clipped support is renormalized, not padded with repeated pixels.
            let start = max(0, Int(center - filterScale + 0.5))
            let end = min(inputSize, Int(center + filterScale + 0.5))
            var weights = [Double]()
            weights.reserveCapacity(end - start)
            var total = 0.0
            for input in start..<end {
                let distance = abs((Double(input) - center + 0.5) * inverseFilterScale)
                let weight = max(0, 1 - distance)
                weights.append(weight)
                total += weight
            }
            // Triangle weights are nonnegative. Round each normalized weight
            // independently to 22 bits; do NOT adjust their quantized sum.
            let coefficients = weights.map { Int(($0 / total) * Double(coefficientScale) + 0.5) }
            return AxisFilter(start: start, coefficients: coefficients)
        }
    }

    private static func bilinearRGB(_ rgba: [UInt8], layout: PixelLayout) -> [UInt8] {
        let horizontalFilters = bilinearFilters(inputSize: layout.width)
        let rowBytes = size * 3
        // Only 224 * oriented source height * 3 bytes between passes, not a
        // floating-point full-resolution image or a second oriented image copy.
        var horizontal = [UInt8](repeating: 0, count: rowBytes * layout.height)
        for y in 0..<layout.height {
            let rowStart = layout.origin + y * layout.yStep
            for x in 0..<size {
                let filter = horizontalFilters[x]
                var source = rowStart + filter.start * layout.xStep
                var red = roundingBias
                var green = roundingBias
                var blue = roundingBias
                for coefficient in filter.coefficients {
                    red += Int(rgba[source]) * coefficient
                    green += Int(rgba[source + 1]) * coefficient
                    blue += Int(rgba[source + 2]) * coefficient
                    source += layout.xStep
                }
                let target = y * rowBytes + x * 3
                horizontal[target] = UInt8(clamping: red >> coefficientBits)
                horizontal[target + 1] = UInt8(clamping: green >> coefficientBits)
                horizontal[target + 2] = UInt8(clamping: blue >> coefficientBits)
            }
        }
        if layout.height == size { return horizontal }

        let verticalFilters = bilinearFilters(inputSize: layout.height)
        var resized = [UInt8](repeating: 0, count: rowBytes * size)
        for y in 0..<size {
            let filter = verticalFilters[y]
            for x in 0..<size {
                var source = filter.start * rowBytes + x * 3
                var red = roundingBias
                var green = roundingBias
                var blue = roundingBias
                for coefficient in filter.coefficients {
                    red += Int(horizontal[source]) * coefficient
                    green += Int(horizontal[source + 1]) * coefficient
                    blue += Int(horizontal[source + 2]) * coefficient
                    source += rowBytes
                }
                let target = y * rowBytes + x * 3
                resized[target] = UInt8(clamping: red >> coefficientBits)
                resized[target + 1] = UInt8(clamping: green >> coefficientBits)
                resized[target + 2] = UInt8(clamping: blue >> coefficientBits)
            }
        }
        return resized
    }

    static func tensor(data: Data, orientation: CGImagePropertyOrientation) throws -> MLMultiArray {
        try tensor(values: values(data: data, orientation: orientation))
    }

    static func tensor(image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> MLMultiArray {
        try tensor(values: values(image: image, orientation: orientation))
    }

    private static func tensor(values: [Float]) throws -> MLMultiArray {
        let tensor = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
        for (index, value) in values.enumerated() { tensor[index] = NSNumber(value: value) }
        return tensor
    }
}