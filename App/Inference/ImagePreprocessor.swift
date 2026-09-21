import Foundation
import UIKit
import CoreML
import ImageIO
import CoreImage

enum ImagePreprocessor {
    static let size = 224
    static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    static let standardDeviation: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// Orientation -> RGB -> shortest-side resize -> center crop -> Float32 NCHW.
    /// CGContext.high is a native approximation, NOT measured Pillow bicubic parity.
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
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation.rawValue))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let upright = context.createCGImage(oriented, from: oriented.extent),
              upright.width > 0, upright.height > 0 else {
            throw AppFailure.photo("Unable to orient the image.")
        }
        let scale = Double(size) / Double(min(upright.width, upright.height))
        let width = max(size, Int(Double(upright.width) * scale))
        let height = max(size, Int(Double(upright.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let resized = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw AppFailure.photo("Unable to allocate RGB preprocessing buffer.")
        }
        resized.setFillColor(UIColor.black.cgColor)
        resized.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        resized.interpolationQuality = .high
        resized.draw(upright, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let x = (width - size) / 2
        let y = (height - size) / 2
        guard let scaledImage = resized.makeImage(),
              let crop = scaledImage.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(size), height: CGFloat(size))) else {
            throw AppFailure.photo("Unable to center crop the image.")
        }
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: size, height: size,
                                         bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw AppFailure.photo("Unable to read cropped RGB pixels.")
            }
            bitmap.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)))
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

    static func tensor(data: Data, orientation: CGImagePropertyOrientation) throws -> MLMultiArray {
        let values = try values(data: data, orientation: orientation)
        let tensor = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        for (index, value) in values.enumerated() { tensor[index] = NSNumber(value: value) }
        return tensor
    }
}