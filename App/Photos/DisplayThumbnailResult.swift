import CoreGraphics
import UIKit

enum DisplayThumbnailStage: String, Sendable {
    case localHQ = "本地 HQ（显示尺寸）"
    case localHQ224 = "本地 HQ224"
    case networkHQ = "联网 HQ（显示尺寸）"
    case localFast224 = "本地 Fast224"
    case unknown = "来源未知"
}

struct DisplayThumbnailAttempt: Sendable {
    let stage: DisplayThumbnailStage
    let requestedSize: CGSize
    /// Raw raster dimensions before applying UIImage orientation; nil if unknown.
    let returnedSize: CGSize?
    let degraded: Bool?
    /// Loader supplies only fixed generic labels, never error descriptions/userInfo.
    let outcome: String
}

/// The only unchecked reference is UIImage, retained read-only (never mutated by
/// this value or the loader) for Swift 5 SDK compatibility. All metadata is value
/// data. Pixel coverage is a dimension check, NOT evidence of image sharpness.
struct DisplayThumbnailResult: @unchecked Sendable {
    let image: UIImage
    let stage: DisplayThumbnailStage
    let requestedSize: CGSize
    /// Raw CGImage dimensions, before UIImage orientation; .zero means unknown.
    let returnedSize: CGSize
    let degraded: Bool?
    let attempts: [DisplayThumbnailAttempt]
    let isSufficientForDisplay: Bool

    var isReusable: Bool {
        stage != .unknown && stage != .localFast224
            && degraded != true && isSufficientForDisplay
    }

    init(image: UIImage, stage: DisplayThumbnailStage, requestedSize: CGSize,
         returnedSize: CGSize, degraded: Bool?, attempts: [DisplayThumbnailAttempt] = [],
         targetSize: CGSize) {
        self.image = image
        self.stage = stage
        self.requestedSize = requestedSize
        self.returnedSize = returnedSize
        self.degraded = degraded
        self.attempts = attempts
        self.isSufficientForDisplay = Self.displayCoverage(
            returnedSize: returnedSize, orientation: image.imageOrientation, targetSize: targetSize) >= 1
    }

    /// Legacy protocol/test adapters cannot establish a PhotoKit source or flag.
    /// Only an existing raster establishes actual pixels: UIImage.size/scale and
    /// an unrendered CI extent are not substituted for a returned CGImage.
    static func unverified(image: UIImage, targetSize: CGSize) -> Self {
        let pixels = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        return Self(image: image, stage: .unknown, requestedSize: targetSize,
                    returnedSize: pixels, degraded: nil, targetSize: targetSize)
    }

    /// Aspect-fill coverage of both display axes, using oriented *pixel* sizes,
    /// independent of UIImage.scale. This neither scores nor proves sharpness.
    static func displayCoverage(returnedSize: CGSize, orientation: UIImage.Orientation,
                                targetSize: CGSize) -> CGFloat {
        guard returnedSize.width.isFinite, returnedSize.height.isFinite,
              targetSize.width.isFinite, targetSize.height.isFinite,
              returnedSize.width > 0, returnedSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else { return 0 }
        let oriented: CGSize
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            oriented = CGSize(width: returnedSize.height, height: returnedSize.width)
        default:
            oriented = returnedSize
        }
        return min(oriented.width / targetSize.width, oriented.height / targetSize.height)
    }
}