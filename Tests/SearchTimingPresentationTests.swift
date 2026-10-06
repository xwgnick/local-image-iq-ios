import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Two small native, render-only tests and exactly one review attachment.
/// SearchTimingContent is the actual production page body. Fixed TEST numbers
/// are not measured performance. No AppState, Photos, models or benchmark data.
/// No private/in-process AX traversal or assertion that all rows fit one screen.
@MainActor
final class SearchTimingPresentationTests: XCTestCase {
    func testDarkPhoneSnapshotUsesRealReportWithExplicitSyntheticCountsAndTimingScope() async throws {
        let report = fixtureReport()
        let content = SearchTimingContent(report: report)
        let supplied = try XCTUnwrap(content.report)
        XCTAssertEqual(supplied.mode, "加速")
        XCTAssertEqual(supplied.cacheSource, "内存驻留")
        XCTAssertEqual(supplied.candidateCount, 8_000)
        XCTAssertTrue(supplied.matrixReused)
        XCTAssertTrue(supplied.snapshotReused)
        XCTAssertEqual(supplied.outcome, .ready)
        XCTAssertEqual(supplied.stages.map(\.stage), SearchTimingStage.allCases)
        XCTAssertEqual(supplied.stages.count, 13)
        XCTAssertNotEqual(supplied.stages.count, supplied.candidateCount)
        XCTAssertEqual(supplied.stages.reduce(0) { $0 + $1.seconds }, 0.3, accuracy: 1e-12)
        XCTAssertEqual(SearchTimingReport.duration(supplied.totalSeconds), "0.300 秒")
        XCTAssertEqual(SearchTimingReport.duration(try XCTUnwrap(supplied.firstImageSeconds)), "0.400 秒")
        XCTAssertTrue(SearchTimingContent.imageNote.contains("不能与排名耗时相加"))
        XCTAssertTrue(SearchTimingContent.imageNote.contains("Fast"))
        XCTAssertTrue(SearchTimingContent.imageNote.contains("未返回不等于零耗时"))
        XCTAssertTrue(SearchTimingContent.cacheNote.contains("首次搜索不一定代表系统缓存为空"))
        XCTAssertTrue(SearchTimingContent.comparisonNote.contains("不同查询"))
        XCTAssertTrue(SearchTimingContent.limitNote.contains("不能替代手机实测"))

        let size = CGSize(width: 393, height: 852)
        try await withHost(content, size: size, dynamicType: .large) { view in
            let image = try self.capture(view, scale: 1)
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(pixels.width, 393)
            XCTAssertEqual(pixels.height, 852)
            let attachment = XCTAttachment(image: image)
            attachment.name = "UIReview-search-performance-dark"
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    func testMaximumDynamicTypeScrollsWithoutContentWiderThanActualViewport() async throws {
        let content = SearchTimingContent(report: fixtureReport())
        try await withHost(content, size: CGSize(width: 320, height: 568), dynamicType: .accessibility5) { view in
            // Materialize the native hierarchy before taking scroll measurements.
            // No attachment: only the normal-size phone snapshot is exported.
            _ = try self.capture(view, scale: view.window?.screen.scale ?? 1)
            await self.settle(view)
            let scroll = try XCTUnwrap(self.scrollViews(in: view).first {
                $0.bounds.width > 0 && $0.contentSize.height > $0.bounds.height
            })
            XCTAssertTrue(scroll.isScrollEnabled)
            XCTAssertGreaterThan(scroll.contentSize.width, 0)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
            let viewport = scroll.convert(scroll.bounds, to: view)
            XCTAssertGreaterThan(viewport.width, 0)
            XCTAssertGreaterThan(viewport.height, 0)
            // Compare content with UIScrollView's ACTUAL bounds, not containment
            // in a custom-width host (which may round differently at native scale).
            let initial = scroll.contentOffset
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            XCTAssertGreaterThan(bottom, initial.y)
            scroll.setContentOffset(CGPoint(x: initial.x, y: bottom), animated: false)
            await self.settle(view)
            _ = try self.capture(view, scale: view.window?.screen.scale ?? 1)
            XCTAssertGreaterThan(scroll.contentOffset.y, initial.y)
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1 / (view.window?.screen.scale ?? 1))
            XCTAssertEqual(scroll.contentOffset.x, initial.x)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
            XCTAssertEqual(scroll.convert(scroll.bounds, to: view), viewport)
            // This is native layout/scroll evidence, not per-row visibility,
            // VoiceOver coverage or proof that every child is free of clipping.
        }
    }

    private func fixtureReport() -> SearchTimingReport {
        let stages = SearchTimingStage.allCases
        let milliseconds: [Double] = [2, 30, 8, 5, 20, 100, 3, 5, 70, 20, 10, 12, 15]
        var rows: [SearchTimingRow] = []
        for (stage, milliseconds) in zip(stages, milliseconds) {
            rows.append(SearchTimingRow(id: rows.count, stage: stage, seconds: milliseconds / 1_000))
        }
        return SearchTimingReport(id: UUID(), stages: rows, totalSeconds: 0.3, outcome: .ready,
            mode: "加速", cacheSource: "resident", candidateCount: 8_000,
            matrixReused: true, snapshotReused: true, firstImageSeconds: 0.4)
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize, dynamicType: DynamicTypeSize,
                                         inspect: (UIView) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        // Test-only watermark ABOVE the real navigation header, not over rows.
        let root = VStack(spacing: 0) {
            Text("TEST · 合成耗时 · 非实际测量")
                .font(.caption2)
                .foregroundStyle(IQStyle.secondary)
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(IQStyle.muted)
            NavigationStack { content }
        }
        .background(IQStyle.background)
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, dynamicType)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = SearchTimingReviewHost(rootView: root)
        let laidOut = expectation(description: "Native search timing viewport laid out")
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
        await settle(host.view)
        XCTAssertEqual(host.view.bounds.size, size)
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .dark)
        try await inspect(host.view)
    }

    private func settle(_ view: UIView) async {
        let settled = expectation(description: "Native search timing layout settled")
        DispatchQueue.main.async {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            DispatchQueue.main.async { view.layoutIfNeeded(); settled.fulfill() }
        }
        await fulfillment(of: [settled], timeout: 5)
    }

    private func capture(_ view: UIView, scale: CGFloat) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Capture the real hosted hierarchy, not a reconstructed graphic.")
        XCTAssertNotNil(image.cgImage)
        return image
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        var values: [UIScrollView] = []
        if let scroll = view as? UIScrollView { values.append(scroll) }
        for child in view.subviews { values.append(contentsOf: scrollViews(in: child)) }
        return values
    }
}

@MainActor
private final class SearchTimingReviewHost<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}