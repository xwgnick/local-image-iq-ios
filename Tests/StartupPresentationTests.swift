import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Four original icon-only attachments plus two slow-preparation attachments.
/// These render the actual StartupContent without constructing AppState, starting
/// tasks, requesting Photos access, loading models or using any photo fixtures.
/// Separate native raster tests assert geometry/colors and icon invariance, not
/// mock-image baselines. Gesture callback contracts are tested below; physical
/// touch recognition, VoiceOver discovery and launch routing still require XCUI.
@MainActor
final class StartupPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testCheckingLibraryLightSnapshot() async throws {
        try await snapshot(phase: .checkingLibrary, issue: nil, appearance: .light,
                           id: "loading-light")
    }

    func testPreparingSearchDarkSnapshot() async throws {
        try await snapshot(phase: .preparingSearch, issue: nil, appearance: .dark,
                           id: "loading-dark")
    }

    func testFailureLightSnapshot() async throws {
        try await snapshot(phase: .failed, issue: "暂时无法读取照片访问状态，请重试。",
                           appearance: .light, id: "error-light")
    }

    func testFailureDarkSnapshot() async throws {
        try await snapshot(phase: .failed, issue: "本机搜索模型尚未准备好，请重试。",
                           appearance: .dark, id: "error-dark")
    }

    func testSlowProgressDarkSnapshot() async throws {
        try await snapshot(phase: .preparingSearch, issue: nil, appearance: .dark,
                           id: "progress-dark", progressFraction: 0.375)
    }

    func testSlowProgressLightSnapshot() async throws {
        try await snapshot(phase: .preparingSearch, issue: nil, appearance: .light,
                           id: "progress-light", progressFraction: 0.375)
    }

    func testRecoveryActionsAreOnlyEnabledAfterFailure() {
        for phase in [AppState.LaunchPhase.pending, .checkingLibrary, .preparingSearch, .failed, .ready] {
            var retries = 0
            var openedHome = 0
            let content = StartupContent(phase: phase, issue: nil,
                                         onRetry: { retries += 1 }, onOpenHome: { openedHome += 1 })
            XCTAssertEqual(content.canRecover, phase == .failed)
            content.retryIfFailed()
            XCTAssertEqual(retries, phase == .failed ? 1 : 0)
            XCTAssertEqual(openedHome, 0, "Retry must not navigate")
            content.openHomeIfFailed()
            XCTAssertEqual(openedHome, phase == .failed ? 1 : 0)
            XCTAssertEqual(retries, phase == .failed ? 1 : 0, "Continue must not retry")
        }
    }

    func testVoiceOverFailureUsesGenericFallbackAndRedactsLocalDetails() {
        let fallback = StartupContent(phase: .failed, issue: nil, onRetry: {}, onOpenHome: {})
        let blank = StartupContent(phase: .failed, issue: " \n ", onRetry: {}, onOpenHome: {})
        XCTAssertEqual(blank.accessibilityStatus, fallback.accessibilityStatus)
        let redacted = StartupContent(phase: .failed, issue: "检查失败：file:///synthetic/private/model",
                                      onRetry: {}, onOpenHome: {})
        XCTAssertFalse(redacted.accessibilityStatus.contains("/synthetic/private/model"))
        let loading = StartupContent(phase: .checkingLibrary, issue: "过期的失败消息",
                                     onRetry: {}, onOpenHome: {})
        XCTAssertFalse(loading.accessibilityStatus.contains("过期的失败消息"))
    }

    func testSelectedLogoAndLaunchBackgroundExistInAppBundle() throws {
        let logo = try XCTUnwrap(UIImage(named: StartupAppearance.imageName))
        XCTAssertEqual(logo.size, CGSize(width: 192, height: 192))
        let pixels = try XCTUnwrap(logo.cgImage)
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertEqual(pixels.width, pixels.height)
        XCTAssertNotNil(UIColor(named: StartupAppearance.backgroundName))
        XCTAssertNotNil(Bundle.main.url(forResource: "LaunchScreen", withExtension: "storyboardc"),
                        "XcodeGen must bundle the static launch storyboard")
    }

    func testEveryPhaseDrawsTheSameIconOnlyPixels() throws {
        // Compare native SwiftUI rendering across phases, not against a mock image.
        // No time-varying pixels, status labels or failure adornments are allowed.
        for scheme in [ColorScheme.light, .dark] {
            for size in [phone, CGSize(width: 320, height: 568), CGSize(width: 852, height: 393)] {
                var baseline: Data?
                for phase in [AppState.LaunchPhase.pending, .checkingLibrary, .preparingSearch, .failed, .ready] {
                    let content = StartupContent(phase: phase, issue: "测试失败信息",
                                                 onRetry: { XCTFail("Rendering must not retry") },
                                                 onOpenHome: { XCTFail("Rendering must not navigate") })
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, .accessibility5)
                        .frame(width: size.width, height: size.height)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size, size)
                    let data = try XCTUnwrap(image.pngData())
                    if let baseline {
                        XCTAssertEqual(data, baseline, "Only accessibility/interaction may change with phase")
                    } else {
                        baseline = data
                    }
                }
            }
        }
    }

    func testLargestDynamicTypeOnSmallPhoneHasNoScrollOrSpinner() async throws {
        let content = StartupContent(phase: .failed, issue: nil,
                                     onRetry: { XCTFail("Rendering must not retry") },
                                     onOpenHome: { XCTFail("Rendering must not open home") })
        try await withHost(content, size: CGSize(width: 320, height: 568), appearance: .dark,
                           dynamicTypeSize: .accessibility5) { view in
            XCTAssertFalse(self.descendants(view).contains { $0 is UIScrollView })
            XCTAssertFalse(self.descendants(view).contains { $0 is UIActivityIndicatorView })
            XCTAssertLessThan(StartupAppearance.iconSize, min(view.bounds.width, view.bounds.height))
        }
    }

    func testProgressFractionSanitizesFiniteBoundsAndHidesOutsidePreparation() {
        let cases: [(Double?, Double?)] = [
            (nil, nil), (Double.nan, nil), (Double.infinity, nil), (-Double.infinity, nil),
            (-2, 0), (-0.0, 0), (0, 0), (0.375, 0.375), (0.75, 0.75), (1, 1), (2, 1)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(StartupStepProgressBar.sanitizedFraction(input), expected)
            for phase in allPhases {
                let content = startup(phase: phase, fraction: input)
                XCTAssertEqual(content.visibleProgressFraction,
                               phase == .checkingLibrary || phase == .preparingSearch ? expected : nil)
            }
        }
        for fraction in [-2.0, 0, 0.375, 0.75, 1, 2] {
            XCTAssertEqual(StartupStepProgressBar(fraction: fraction).fillWidth,
                           144 * CGFloat(min(max(fraction, 0), 1)), accuracy: 0.000001)
        }
    }

    func testStandaloneProgressBarHasExactZeroPartialFullNativePixels() throws {
        // 2x renders align the half-point root center and 3pt capsule edges.
        // Validate actual SwiftUI pixels, not just the fillWidth arithmetic.
        let size = CGSize(width: 160, height: 20)
        let box = CGRect(x: 16, y: 17, width: 288, height: 6)
        for scheme in [ColorScheme.light, .dark] {
            let background = try nativePixels(Color(StartupAppearance.backgroundName), size: size, scheme: scheme)
            for input in [-2.0, 0, 0.375, 0.75, 1, 2] {
                let pixels = try nativePixels(ZStack {
                    Color(StartupAppearance.backgroundName)
                    StartupStepProgressBar(fraction: input)
                }, size: size, scheme: scheme)
                XCTAssertEqual(pixels.differenceBounds(from: background), box)
                assertBarSamples(pixels, box: box, fraction: min(max(input, 0), 1), scheme: scheme)
            }
        }
    }

    func testPreparationProgressChangesOnlyBarPixelsAndKeepsIconCrop() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [phone, CGSize(width: 320, height: 568), CGSize(width: 852, height: 393)] {
                let normal = try nativePixels(startup(phase: .checkingLibrary), size: size, scheme: scheme)
                // Independent literal dimensions from the approved design, in
                // 2x pixels. Do not derive expected geometry from app constants.
                let iconBox = CGRect(x: size.width - 192, y: size.height - 192, width: 384, height: 384)
                let barBox = CGRect(x: size.width - 144, y: size.height + 248, width: 288, height: 6)
                for phase in [AppState.LaunchPhase.checkingLibrary, .preparingSearch] {
                    for fraction in [0.0, 0.375, 1] {
                        let pixels = try nativePixels(startup(phase: phase, fraction: fraction),
                                                      size: size, scheme: scheme)
                        let changed = try XCTUnwrap(pixels.differenceBounds(from: normal))
                        XCTAssertEqual(changed, barBox, "No pixels outside the approved bar may change")
                        XCTAssertEqual(changed.width / 2, 144)
                        XCTAssertEqual(changed.height / 2, 3)
                        XCTAssertEqual((changed.minY - iconBox.maxY) / 2, 28)
                        XCTAssertEqual(changed.midX / 2, size.width / 2)
                        XCTAssertEqual(pixels.crop(iconBox), normal.crop(iconBox),
                                       "The entire 192pt logo box must stay at the whole-screen center")
                        assertBarSamples(pixels, box: barBox, fraction: fraction, scheme: scheme)
                    }
                }
            }
        }
    }

    func testProgressIsHiddenForIneligibleStatesAndInvalidFractionsNativePixels() throws {
        for scheme in [ColorScheme.light, .dark] {
            let normal = try nativePixels(startup(phase: .checkingLibrary), size: phone, scheme: scheme)
            for phase in allPhases {
                var inputs: [Double?] = [nil, Double.nan, Double.infinity, -Double.infinity]
                if phase != .checkingLibrary && phase != .preparingSearch {
                    inputs += [-2, 0, 0.375, 1, 2]
                }
                for fraction in inputs {
                    let pixels = try nativePixels(startup(phase: phase, fraction: fraction),
                                                  size: phone, scheme: scheme)
                    XCTAssertEqual(pixels.rgba, normal.rgba, "Hidden progress must be genuinely icon-only")
                }
            }
        }
    }

    func testProgressPixelsAreIdenticalWithReduceMotionOnAndOff() throws {
        for scheme in [ColorScheme.light, .dark] {
            for fraction in [0.0, 0.375, 0.75, 1] {
                let content = startup(phase: .preparingSearch, fraction: fraction)
                let ordinary = try nativePixels(content.environment(\.accessibilityReduceMotion, false),
                                                size: phone, scheme: scheme)
                let reduced = try nativePixels(content.environment(\.accessibilityReduceMotion, true),
                                               size: phone, scheme: scheme)
                XCTAssertEqual(ordinary.rgba, reduced.rgba)
            }
        }
    }

    func testRecoveryExclusiveGestureDispatchRemainsFailureOnlyWithProgressInput() {
        // Feed the actual onEnded handler's ExclusiveGesture.Value, including a
        // non-completed long press. No synthetic UITouch/private UIKit APIs.
        let fractions: [Double?] = [nil, 0.375]
        for phase in allPhases {
            for fraction in fractions {
                var retries = 0
                var openedHome = 0
                let content = StartupContent(phase: phase, issue: "测试失败信息",
                                             onRetry: { retries += 1 }, onOpenHome: { openedHome += 1 },
                                             progressFraction: fraction)
                content.handleRecoveryGesture(.first(false))
                XCTAssertEqual(retries, 0)
                XCTAssertEqual(openedHome, 0)
                content.handleRecoveryGesture(.first(true))
                XCTAssertEqual(retries, 0, "A completed long press must never also retry")
                XCTAssertEqual(openedHome, phase == .failed ? 1 : 0)
                content.handleRecoveryGesture(.second(()))
                XCTAssertEqual(retries, phase == .failed ? 1 : 0)
                XCTAssertEqual(openedHome, phase == .failed ? 1 : 0, "A tap must not navigate")
            }
        }
    }

    func testProgressAccessibilityUsesOnlySanitizedCompletion() {
        let cases: [(Double, String)] = [
            (-2, "已完成 0%"), (0, "已完成 0%"), (0.375, "已完成 38%"), (0.75, "已完成 75%"),
            (1, "已完成 100%"), (2, "已完成 100%"),
            (.nan, "已完成 0%"), (.infinity, "已完成 0%"), (-.infinity, "已完成 0%")
        ]
        for (fraction, value) in cases {
            XCTAssertEqual(StartupStepProgressBar(fraction: fraction).accessibilityProgress, value)
        }
    }

    private var allPhases: [AppState.LaunchPhase] {
        [.pending, .checkingLibrary, .preparingSearch, .failed, .ready]
    }

    private func startup(phase: AppState.LaunchPhase, fraction: Double? = nil) -> StartupContent {
        StartupContent(phase: phase, issue: "测试失败信息",
                       onRetry: { XCTFail("Rendering must not retry") },
                       onOpenHome: { XCTFail("Rendering must not navigate") },
                       progressFraction: fraction)
    }

    private func nativePixels<Content: View>(_ content: Content, size: CGSize,
                                             scheme: ColorScheme) throws -> StartupNativePixels {
        var image: UIImage?
        let traits = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: .normal), UITraitCollection(displayGamut: .SRGB)
        ])
        traits.performAsCurrent {
            let renderer = ImageRenderer(content: content
                .environment(\.colorScheme, scheme)
                .environment(\.layoutDirection, .leftToRight)
                .environment(\.dynamicTypeSize, .accessibility5)
                .frame(width: size.width, height: size.height))
            renderer.scale = 2
            image = renderer.uiImage
        }
        let rendered = try XCTUnwrap(image)
        XCTAssertEqual(rendered.size, size)
        let pixels = try StartupNativePixels(image: rendered)
        XCTAssertEqual(pixels.width, Int(size.width * 2))
        XCTAssertEqual(pixels.height, Int(size.height * 2))
        return pixels
    }

    private func assertBarSamples(_ pixels: StartupNativePixels, box: CGRect,
                                  fraction: Double, scheme: ColorScheme,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let accent: UInt32 = scheme == .dark ? 0xD8B57C : 0x806025
        let track: UInt32 = scheme == .dark ? 0x393A3D : 0xE5E9ED
        let background: UInt32 = scheme == .dark ? 0x121416 : 0xF7F8FA
        let boundary = box.minX + box.width * CGFloat(fraction)
        let middle = Int(box.midY)
        // Skip only the 1.5pt antialiased endcaps, not the interior fill edge.
        // Samples either side of that edge verify the supplied fraction's width.
        for x in (Int(box.minX) + 4)..<(Int(box.maxX) - 4) {
            if fraction == 1 || (fraction > 0 && CGFloat(x) < boundary - 4) {
                pixels.assertRGB(x: x, y: middle, hex: accent, file: file, line: line)
            } else if fraction == 0 || CGFloat(x) >= boundary {
                pixels.assertRGB(x: x, y: middle, hex: track, file: file, line: line)
            }
        }
        pixels.assertRGB(x: Int(box.midX), y: Int(box.minY) - 1, hex: background, file: file, line: line)
        pixels.assertRGB(x: Int(box.midX), y: Int(box.maxY), hex: background, file: file, line: line)
        let corner = pixels.pixel(x: Int(box.minX), y: Int(box.minY))
        let interior = pixels.pixel(x: Int(box.minX) + 4, y: middle)
        XCTAssertNotEqual(corner, interior, "Endcaps must be clipped, not square", file: file, line: line)
    }

    private func snapshot(phase: AppState.LaunchPhase, issue: String?,
                          appearance: UIUserInterfaceStyle, id: String,
                          progressFraction: Double? = nil) async throws {
        let content = StartupContent(phase: phase, issue: issue,
                                     onRetry: { XCTFail("A snapshot must not start work") },
                                     onOpenHome: { XCTFail("A snapshot must not navigate") },
                                     progressFraction: progressFraction)
        try await withHost(content, size: phone, appearance: appearance) { view in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            var drewHierarchy = false
            let image = UIGraphicsImageRenderer(size: self.phone, format: format).image { context in
                UIColor(Color(StartupAppearance.backgroundName))
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance)).setFill()
                context.fill(view.bounds)
                drewHierarchy = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drewHierarchy, "Capture the actual UIKit-hosted SwiftUI hierarchy")
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(pixels.width, Int(self.phone.width))
            XCTAssertEqual(pixels.height, Int(self.phone.height))
            let attachment = XCTAttachment(image: image)
            attachment.name = "UIReview-startup-\(id)"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize,
                                          appearance: UIUserInterfaceStyle,
                                          dynamicTypeSize: DynamicTypeSize = .large,
                                          inspect: (UIView) throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native snapshots require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = appearance
        // Explicitly marked synthetic state; no imitation status bars, composed
        // scroll captures, app-state injection or replacement production controls.
        let root = content
            .overlay(alignment: .topTrailing) {
                Text("测试场景")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(IQStyle.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(IQStyle.muted, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
            .preferredColorScheme(appearance == .dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = StartupReviewHostingController(rootView: root)
        host.overrideUserInterfaceStyle = appearance
        let laidOut = expectation(description: "Startup content has a native phone layout")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == size else { return }
            host.onLayout = nil
            laidOut.fulfill()
        }
        defer {
            host.onLayout = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)

        // Drain native layout updates without sleeps, launch timers or
        // production delays for a static logo.
        let settled = expectation(description: "Startup native layout updates completed")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(host.view.bounds.size, size)
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, appearance)
        try inspect(host.view)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

/// Decode real native renderings into a fixed sRGB RGBA format. Comparisons are
/// over pixels, not PNG metadata, model output or precomposed design previews.
@MainActor
private struct StartupNativePixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(image: UIImage) throws {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                                                 bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                                                 bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                                    | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.width = width
        self.height = height
        rgba = bytes
    }

    func pixel(x: Int, y: Int) -> [UInt8] {
        guard (0..<width).contains(x), (0..<height).contains(y) else {
            XCTFail("Sample outside the native raster")
            return []
        }
        let offset = (y * width + x) * 4
        return Array(rgba[offset..<(offset + 4)])
    }

    func assertRGB(x: Int, y: Int, hex: UInt32,
                   file: StaticString = #filePath, line: UInt = #line) {
        let actual = pixel(x: x, y: y)
        let expected = [Int((hex >> 16) & 255), Int((hex >> 8) & 255), Int(hex & 255), 255]
        XCTAssertEqual(actual.count, 4, file: file, line: line)
        for (channel, target) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(Int(channel) - target), 1,
                                     "Native sRGB pixel at (\(x), \(y))", file: file, line: line)
        }
    }

    func crop(_ rect: CGRect) -> Data {
        guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height) else {
            XCTFail("Crop outside the native raster")
            return Data()
        }
        var result = Data()
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * width + Int(rect.minX)) * 4
            result.append(contentsOf: rgba[start..<(start + Int(rect.width) * 4)])
        }
        return result
    }

    func differenceBounds(from other: StartupNativePixels) -> CGRect? {
        guard width == other.width, height == other.height else {
            XCTFail("Native raster sizes must match")
            return nil
        }
        var left = width, top = height, right = -1, bottom = -1
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            if rgba[offset] == other.rgba[offset], rgba[offset + 1] == other.rgba[offset + 1],
               rgba[offset + 2] == other.rgba[offset + 2], rgba[offset + 3] == other.rgba[offset + 3] { continue }
            let x = (offset / 4) % width
            let y = (offset / 4) / width
            left = min(left, x)
            top = min(top, y)
            right = max(right, x)
            bottom = max(bottom, y)
        }
        guard right >= left else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}

@MainActor
private final class StartupReviewHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}