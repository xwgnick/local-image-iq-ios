import XCTest
import SwiftUI
import UIKit
@testable import LocalImageIQ

/// Render-only fixtures: no AppState, model, database, Photos, network, or image
/// fixtures. Exactly two native phone-viewport attachments carry a test watermark.
/// These are human-review captures, not real launch measurements or XCUI evidence.
@MainActor
final class LaunchTimingPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testDurationUsesSecondsAndThreeDecimalsWithoutLocaleGrouping() {
        let cases: [(Double, String)] = [
            (0, "0.000 秒"), (0.001, "0.001 秒"), (1.23456, "1.235 秒"),
            (65.432, "65.432 秒"), (3600, "3600.000 秒"), (123456.789, "123456.789 秒")
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(LaunchTimingReport.duration(seconds), expected)
        }
    }

    func testLatestFirstPreservesEveryEarlierAttemptAndSourceOrder() throws {
        let first = report(kind: .cold, outcome: .interrupted, seconds: 3)
        let second = report(kind: .foreground, outcome: .failed, seconds: 4)
        let latest = report(kind: .retry, outcome: .ready, seconds: 5)
        let source = [first, second, latest]
        let content = LaunchTimingContent(reports: source, version: "test", build: "fixture")
        XCTAssertEqual(try XCTUnwrap(content.latest).id, latest.id)
        XCTAssertEqual(content.earlierReports.map(\.id), [second.id, first.id])
        XCTAssertEqual(content.reports.map(\.id), [first.id, second.id, latest.id])
        XCTAssertEqual(source.map(\.id), [first.id, second.id, latest.id])
        XCTAssertEqual(content.earlierReports.map(\.totalSeconds), [4, 3])
        XCTAssertEqual(content.earlierReports.map { $0.outcome.rawValue }, ["准备失败", "准备中断"])
    }

    func testEmptyReportsHaveNoInventedZeroOrHistory() {
        let content = LaunchTimingContent(reports: [], version: nil, build: nil)
        XCTAssertNil(content.latest)
        XCTAssertTrue(content.earlierReports.isEmpty)
        let single = LaunchTimingContent(reports: [report()], version: nil, build: nil)
        XCTAssertNotNil(single.latest)
        XCTAssertTrue(single.earlierReports.isEmpty)
    }

    func testKindLabelsAndCacheNotesDoNotPromiseAColdSystemCache() {
        XCTAssertEqual(LaunchTimingKind.cold.rawValue, "本进程首次启动")
        XCTAssertEqual(LaunchTimingKind.retry.rawValue, "手动重试")
        XCTAssertEqual(LaunchTimingKind.foreground.rawValue, "中断后恢复")
        XCTAssertEqual(LaunchTimingContent.historyNote,
                       "仅保留本次进程记录；前台轻量刷新不覆盖记录。重试可能复用模型。")
        XCTAssertEqual(LaunchTimingContent.coldNote,
                       "“本进程首次启动”不代表系统或模型缓存为空。")
    }

    func testReadyFailedAndInterruptedUseHonestMeasurementScopes() {
        let ready = report(outcome: .ready)
        XCTAssertEqual(LaunchTimingContent.totalLabel(for: ready), "到首页就绪")
        XCTAssertEqual(LaunchTimingContent.scope(for: ready),
                       "从 App 开始准备到发布首页就绪；不含 iOS 启动进程及首帧绘制")
        for outcome in [LaunchTimingOutcome.failed, .interrupted] {
            let stopped = report(outcome: outcome)
            XCTAssertEqual(LaunchTimingContent.totalLabel(for: stopped), "到本次准备结束")
            XCTAssertEqual(LaunchTimingContent.scope(for: stopped),
                           "从 App 开始准备到本次准备结束；不含 iOS 启动进程及首帧绘制")
            XCTAssertFalse(LaunchTimingContent.scope(for: stopped).contains("首页就绪"))
        }
    }

    func testProductionMetadataReadsVersionAndBuildFromBundle() {
        let content = LaunchTimingContent(reports: [], bundle: .main)
        XCTAssertEqual(content.version, Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertEqual(content.build, Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        let fixture = LaunchTimingContent(reports: [], version: "0.0-test", build: "42")
        XCTAssertEqual(fixture.versionText, "版本 0.0-test · 构建 42")
    }

    func testMissingMetadataIsExplicitInsteadOfInventingAVersion() {
        XCTAssertEqual(LaunchTimingContent(reports: [], version: nil, build: nil).versionText,
                       "版本 未知 · 构建 未知")
        XCTAssertEqual(LaunchTimingContent(reports: [], version: " \n ", build: "42").versionText,
                       "版本 未知 · 构建 42")
    }

    func testAllStageLabelsAndRepeatedStagesRemainInReportOrder() throws {
        let stages = LaunchTimingStage.allCases + [.counts]
        let rows = stages.enumerated().map {
            LaunchTimingRow(id: $0.offset, stage: $0.element, seconds: Double($0.offset) / 10)
        }
        let older = report(outcome: .failed, rows: rows)
        let latest = report(kind: .retry, rows: Array(rows.reversed()))
        let content = LaunchTimingContent(reports: [older, latest], version: nil, build: nil)
        XCTAssertEqual(try XCTUnwrap(content.latest).rows.map(\.id), rows.reversed().map(\.id))
        XCTAssertEqual(content.earlierReports.first?.rows.map(\.id), rows.map(\.id))
        XCTAssertEqual(content.earlierReports.first?.rows.map { $0.stage.rawValue }, stages.map(\.rawValue))
        XCTAssertEqual(content.earlierReports.first?.rows.map(\.seconds), rows.map(\.seconds))
        XCTAssertEqual(LaunchTimingStage.allCases.count, 13)
    }

    func testTotalUsesRecordedWallTimeAndSlowestUsesRecordedStage() throws {
        // A deliberately partial fixture proves the page must not manufacture
        // its total by summing only the supplied rows or dropping unknown time.
        let rows = [LaunchTimingRow(id: 0, stage: .resources, seconds: 0.041),
                    LaunchTimingRow(id: 1, stage: .imageModel, seconds: 12.345),
                    LaunchTimingRow(id: 2, stage: .counts, seconds: 0.062)]
        let content = LaunchTimingContent(reports: [report(seconds: 21.935, rows: rows)],
                                          version: nil, build: nil)
        let latest = try XCTUnwrap(content.latest)
        XCTAssertEqual(LaunchTimingReport.duration(latest.totalSeconds), "21.935 秒")
        XCTAssertNotEqual(latest.totalSeconds, rows.reduce(0) { $0 + $1.seconds })
        let slowest = try XCTUnwrap(latest.slowest)
        XCTAssertEqual(slowest.stage.rawValue, "加载图像模型")
        XCTAssertEqual(LaunchTimingReport.duration(slowest.seconds), "12.345 秒")
        XCTAssertNil(report(rows: []).slowest, "No invented slowest stage when there are no rows")
    }

    func testLightPhoneSnapshot() async throws {
        try await snapshot(appearance: .light, name: "UIReview-startup-timing-light")
    }

    func testDarkPhoneSnapshot() async throws {
        try await snapshot(appearance: .dark, name: "UIReview-startup-timing-dark")
    }

    func testLargestDynamicTypeScrollsAllThirteenStagesOnSmallPhoneWithoutHorizontalOverflow() async throws {
        let rows = LaunchTimingStage.allCases.enumerated().map {
            LaunchTimingRow(id: $0.offset, stage: $0.element, seconds: 123456.789 + Double($0.offset))
        }
        let content = LaunchTimingContent(
            reports: [report(seconds: rows.reduce(0) { $0 + $1.seconds }, rows: rows)],
            version: "test", build: "fixture")
        try await withHost(content, size: CGSize(width: 320, height: 568), appearance: .dark,
                           dynamicTypeSize: .accessibility5) { view in
            let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UIScrollView }
                .first(where: { $0.contentSize.height > $0.bounds.height && $0.bounds.width > 0 }),
                "Large text must use a real vertical scroll view, not shrink-to-fit text")
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            await self.settle(view)
            XCTAssertGreaterThan(scroll.contentOffset.y, 0)
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        }
    }

    private func report(kind: LaunchTimingKind = .cold, outcome: LaunchTimingOutcome = .ready,
                        seconds: Double = 1, rows: [LaunchTimingRow] = []) -> LaunchTimingReport {
        LaunchTimingReport(id: UUID(), kind: kind, outcome: outcome, totalSeconds: seconds, rows: rows)
    }

    private var fixture: LaunchTimingContent {
        let stages: [(LaunchTimingStage, Double)] = [
            (.entry, 0.012), (.queue, 0.004), (.worker, 0.002), (.places, 0.017),
            (.models, 0.001), (.resources, 0.041), (.tokenizer, 1.230),
            (.imageModel, 12.345), (.textModel, 8.210), (.counts, 0.062), (.publish, 0.011)
        ]
        let rows = stages.enumerated().map {
            LaunchTimingRow(id: $0.offset, stage: $0.element.0, seconds: $0.element.1)
        }
        let failed = report(outcome: .failed, seconds: 0.240,
                            rows: [LaunchTimingRow(id: 0, stage: .resources, seconds: 0.240)])
        let ready = report(kind: .retry, seconds: rows.reduce(0) { $0 + $1.seconds }, rows: rows)
        return LaunchTimingContent(reports: [failed, ready], version: "0.0-test", build: "fixture")
    }

    private func snapshot(appearance: UIUserInterfaceStyle, name: String) async throws {
        try await withHost(fixture, size: phone, appearance: appearance) { view in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            var drewHierarchy = false
            let image = UIGraphicsImageRenderer(size: self.phone, format: format).image { context in
                UIColor.systemBackground.resolvedColor(with: UITraitCollection(userInterfaceStyle: appearance)).setFill()
                context.fill(view.bounds)
                drewHierarchy = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drewHierarchy, "Capture the real hosted page, not a reconstructed graphic")
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(pixels.width, Int(self.phone.width))
            XCTAssertEqual(pixels.height, Int(self.phone.height))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            self.add(attachment)
        }
    }

    private func withHost<Content: View>(_ content: Content, size: CGSize,
                                         appearance: UIUserInterfaceStyle,
                                         dynamicTypeSize: DynamicTypeSize = .large,
                                         inspect: (UIView) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native presentation tests require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = appearance
        // This watermark exists only in the test target, not the shipping page.
        // Capture a single real viewport, never a stitched full-scroll image.
        let root = NavigationStack { content }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("测试场景 · 合成耗时 · 非实际测量")
                    .font(.caption2)
                    .foregroundStyle(IQStyle.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity)
                    .background(IQStyle.muted)
            }
            .preferredColorScheme(appearance == .dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        let host = LaunchTimingReviewHostingController(rootView: root)
        host.overrideUserInterfaceStyle = appearance
        let laidOut = expectation(description: "Launch timing native viewport laid out")
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
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, appearance)
        try await inspect(host.view)
    }

    private func settle(_ view: UIView) async {
        let settled = expectation(description: "Launch timing SwiftUI layout settled")
        DispatchQueue.main.async {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor
private final class LaunchTimingReviewHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}