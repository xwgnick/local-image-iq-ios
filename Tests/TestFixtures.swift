import Foundation
import CoreGraphics
import XCTest
import ImageIQCore
@testable import LocalImageIQ

enum TestFixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImageIQTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Synthetic unit vectors for model-free tests only. Never used by app code.
    static func vector(axis: Int = 0) -> [Float] {
        var values = [Float](repeating: 0, count: 512)
        values[axis] = 1
        return values
    }

    static func photo(id: String = "synthetic-asset", revision: Double = 123, model: String = "test-model",
                      location: PlaceEmbedding? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision, modelVersion: model,
                                        imageEmbedding: vector(), location: location, creationTime: 100),
                    geographyVersion: "test-places")
    }

    static func image(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixel(x, y)
                bytes.append(contentsOf: [rgb.0, rgb.1, rgb.2, 255])
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    static let manifest = """
    {
      "schemaVersion":1,"modelVersion":"test-model","dimension":512,"sequenceLength":128,"imageSize":224,
      "imageModel":{"id":"sentence-transformers/clip-ViT-B-32","revision":"327ab6726d33c0e22f920c83f2ff9e4bd38ca37f"},
      "textModel":{"id":"sentence-transformers/clip-ViT-B-32-multilingual-v1","revision":"58edf8cada9e398793dca955574a48cbb7f18be2"},
      "imageInput":"pixel_values","textInputs":["input_ids","attention_mask"],"output":"output_embedding",
      "extraProvenance":"Allowed extension field"
    }
    """
}