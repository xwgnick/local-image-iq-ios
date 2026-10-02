import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Exactly four native phone-viewport attachments, for human review only.
/// These render the actual StartupContent without constructing AppState, starting
/// tasks, requesting Photos access, loading models or using any photo fixtures.
/// They are not pixel baselines or proof of XCUI identifiers/button semantics;
/// actual launch routing, permission behavior and recovery taps need XCUI tests.
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

    private func snapshot(phase: AppState.LaunchPhase, issue: String?,
                          appearance: UIUserInterfaceStyle, id: String) async throws {
        let content = StartupContent(phase: phase, issue: issue,
                                     onRetry: { XCTFail("A snapshot must not start work") },
                                     onOpenHome: { XCTFail("A snapshot must not navigate") })
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

@MainActor
private final class StartupReviewHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}