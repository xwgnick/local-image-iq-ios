import Foundation
import UIKit
import CoreML
import ImageIO

enum ImagePreprocessor {
    static let size = 224
    static let mean: [Float] = [0.5, 0.5, 0.5]
    static let standardDeviation: [Float] = [0.5, 0.5, 0.5]

    /// EXIF orientation -> sRGB -> full-image 224-square warp -> Float32 NCHW.
    /// CGContext.medium approximates the reference Pillow antialiased BILINEAR
    /// resize; it is NOT pixel-identical. Native/reference embedding cosine >= 0.995
    /// remains a mandatory fixture acceptance gate before release (not verified here).
    /// Alpha is composited over black; camera originals are normally opaque.
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
        // One target-sized bitmap, including for upright PhotoKit previews. No
        // full-resolution orientation copy, intermediate rescale, or center crop.
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
        let transform = try orientationTransform(orientation)
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: size, height: size,
                                         bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw AppFailure.photo("Unable to allocate RGB preprocessing buffer.")
            }
            bitmap.setFillColor(UIColor.black.cgColor)
            bitmap.fill(bounds)
            bitmap.concatenate(transform)
            bitmap.interpolationQuality = .medium
            bitmap.draw(image, in: bounds)
        }
        let pixels = size * size
        var result = [Float](repeating: 0, count: 3 * pixels)
        for channel in 0..<3 {
            for pixel in 0..<pixels {
                result[channel * pixels + pixel] =
                    (Float(rgba[pixel * 4 + channel]) / 255 - mean[channel]) / standardDeviation[channel]
            }
        }
        return result
    }

    /// Quartz uses a bottom-left origin. Each EXIF transform maps the complete
    /// source rectangle onto the target square, also for axis-swapping orientations.
    private static func orientationTransform(_ orientation: CGImagePropertyOrientation) throws -> CGAffineTransform {
        let edge = CGFloat(size)
        switch orientation {
        case .up:
            return .identity
        case .upMirrored:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: edge, ty: 0)
        case .down:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: edge, ty: edge)
        case .downMirrored:
            return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: edge)
        case .leftMirrored:
            return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: edge, ty: edge)
        case .right:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: edge)
        case .rightMirrored:
            return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: edge, ty: 0)
        @unknown default:
            throw AppFailure.photo("Unsupported image orientation.")
        }
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