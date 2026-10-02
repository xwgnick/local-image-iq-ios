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
        XCTAssertEqual(LaunchTimingStage.allCases.count, 15)
    }

    func testTotalUsesRecordedWallTimeAndSlowestUsesRecordedStage() throws {
        // A deliberately partial fixture proves the page must not manufacture
        // its total by summing only the supplied rows or dropping unknown time.
        let rows = [LaunchTimingRow(id: 0, stage: .resources, seconds: 0.041),
                    LaunchTimingRow(id: 1, stage: .parallelModels, seconds: 12.700),
                    LaunchTimingRow(id: 2, stage: .modelAssembly, seconds: 0.009),
                    LaunchTimingRow(id: 3, stage: .counts, seconds: 0.062)]
        let components = parallelComponents
        let content = LaunchTimingContent(reports: [report(seconds: 21.935, rows: rows, components: components)],
                                          version: nil, build: nil)
        let latest = try XCTUnwrap(content.latest)
        XCTAssertEqual(LaunchTimingReport.duration(latest.totalSeconds), "21.935 秒")
        XCTAssertNotEqual(latest.totalSeconds, rows.reduce(0) { $0 + $1.seconds })
        XCTAssertNotEqual(latest.totalSeconds, components.reduce(0) { $0 + $1.seconds })
        XCTAssertNotEqual(latest.totalSeconds, rows.reduce(0) { $0 + $1.seconds }
                          + components.reduce(0) { $0 + $1.seconds })
        let slowest = try XCTUnwrap(latest.slowest)
        XCTAssertEqual(slowest.stage.rawValue, "并行准备模型（总等待）")
        XCTAssertEqual(LaunchTimingReport.duration(slowest.seconds), "12.700 秒")
        XCTAssertNil(report(rows: [], components: components).slowest,
                     "Even with components, no invented slowest wall stage when there are no rows")
    }

    func testLatestAndEarlierReportsPreserveComponentsAndStatuses() throws {
        let olderComponents = [
            LaunchTimingComponent(id: UUID(), stage: .tokenizer, startOffsetSeconds: 0,
                                  seconds: 2, outcome: .completed),
            LaunchTimingComponent(id: UUID(), stage: .imageModel, startOffsetSeconds: 1,
                                  seconds: 2, outcome: .failed),
            LaunchTimingComponent(id: UUID(), stage: .textModel, startOffsetSeconds: 2,
                                  seconds: 2, outcome: .interrupted)
        ]
        let latestComponents = parallelComponents
        let older = report(outcome: .failed, seconds: 4, components: olderComponents)
        let latest = report(kind: .retry, seconds: 13, components: latestComponents)
        let source = [older, latest]
        let content = LaunchTimingContent(reports: source, version: nil, build: nil)
        let shownLatest = try XCTUnwrap(content.latest)
        let shownOlder = try XCTUnwrap(content.earlierReports.first)
        XCTAssertEqual(shownLatest.components.map(\.id), latestComponents.map(\.id))
        XCTAssertEqual(shownLatest.components.map(\.startOffsetSeconds), [0.077, 0.112, 0.237])
        XCTAssertEqual(shownLatest.components.map(\.seconds), [1.230, 12.345, 8.210])
        XCTAssertEqual(shownLatest.components.map(\.outcome), [.completed, .completed, .completed])
        XCTAssertEqual(shownOlder.components.map(\.id), olderComponents.map(\.id))
        XCTAssertEqual(shownOlder.components.map(\.stage), [.tokenizer, .imageModel, .textModel])
        XCTAssertEqual(shownOlder.components.map(\.startOffsetSeconds), [0, 1, 2])
        XCTAssertEqual(shownOlder.components.map(\.outcome), [.completed, .failed, .interrupted])
        XCTAssertEqual(source.map { $0.components.map(\.id) },
                       [olderComponents.map(\.id), latestComponents.map(\.id)])
    }

    func testComponentLabelsOffsetsAndOverlapNoteAreExplicit() {
        XCTAssertEqual(LaunchTimingComponentList.title, "并行任务（时间重叠，不相加）")
        for outcome in [LaunchTimingComponentOutcome.completed, .failed, .interrupted] {
            let component = LaunchTimingComponent(id: UUID(), stage: .tokenizer,
                                                  startOffsetSeconds: 1.25, seconds: 2, outcome: outcome)
            XCTAssertEqual(LaunchTimingComponentList.detail(for: component),
                           "\(outcome.rawValue) · 启动后 +1.250 秒开始")
        }
        for explanation in ["排队", "启动时间差", "取消", "全部任务退出", "长于最慢子任务",
                            "准备中断会立即冻结记录", "不含其后共享任务", "不是 CPU 用时",
                            "时间重叠，不相加", "不计入总耗时加总"] {
            XCTAssertTrue(LaunchTimingContent.parallelNote.contains(explanation), explanation)
        }
    }

    func testLightPhoneSnapshot() async throws {
        try await snapshot(appearance: .light, name: "UIReview-startup-timing-light")
    }

    func testDarkPhoneSnapshot() async throws {
        try await snapshot(appearance: .dark, name: "UIReview-startup-timing-dark")
    }

    func testLargestDynamicTypeScrollsAllFifteenStagesOnSmallPhoneWithoutHorizontalOverflow() async throws {
        let rows = LaunchTimingStage.allCases.enumerated().map {
            LaunchTimingRow(id: $0.offset, stage: $0.element, seconds: 123456.789 + Double($0.offset))
        }
        let components = parallelComponents.map {
            LaunchTimingComponent(id: $0.id, stage: $0.stage, startOffsetSeconds: 123456.789,
                                  seconds: 123456.789, outcome: $0.outcome)
        }
        let content = LaunchTimingContent(
            reports: [report(seconds: rows.reduce(0) { $0 + $1.seconds }, rows: rows, components: components)],
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

    func testParallelComponentsAddScrollableContentWithoutHorizontalOverflow() async throws {
        let rows = [LaunchTimingRow(id: 0, stage: .parallelModels, seconds: 10)]
        let components = [
            LaunchTimingComponent(id: UUID(), stage: .tokenizer, startOffsetSeconds: 1,
                                  seconds: 8, outcome: .completed),
            LaunchTimingComponent(id: UUID(), stage: .imageModel, startOffsetSeconds: 2,
                                  seconds: 6, outcome: .failed),
            LaunchTimingComponent(id: UUID(), stage: .textModel, startOffsetSeconds: 3,
                                  seconds: 4, outcome: .interrupted)
        ]
        let variants: [[LaunchTimingComponent]] = [[], components]
        var heights: [CGFloat] = []
        for variant in variants {
            let content = LaunchTimingContent(
                reports: [report(outcome: .failed, seconds: 10, rows: rows, components: variant)],
                version: "test", build: "fixture")
            // Real native layout, but no additional screenshot attachments.
            try await withHost(content, size: CGSize(width: 320, height: 568), appearance: .light,
                               dynamicTypeSize: .accessibility5) { view in
                let scroll = try XCTUnwrap(self.descendants(view).compactMap { $0 as? UIScrollView }
                    .first(where: { $0.contentSize.height > $0.bounds.height && $0.bounds.width > 0 }))
                heights.append(scroll.contentSize.height)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
                await self.settle(view)
                XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
        }
        XCTAssertEqual(heights.count, 2)
        XCTAssertGreaterThan(heights[1], heights[0], "The separate component section must actually be laid out.")
    }

    private func report(kind: LaunchTimingKind = .cold, outcome: LaunchTimingOutcome = .ready,
                        seconds: Double = 1, rows: [LaunchTimingRow] = [],
                        components: [LaunchTimingComponent] = []) -> LaunchTimingReport {
        LaunchTimingReport(id: UUID(), kind: kind, outcome: outcome,
                           totalSeconds: seconds, rows: rows, components: components)
    }

    private var parallelComponents: [LaunchTimingComponent] {
        [LaunchTimingComponent(id: UUID(), stage: .tokenizer, startOffsetSeconds: 0.077,
                               seconds: 1.230, outcome: .completed),
         LaunchTimingComponent(id: UUID(), stage: .imageModel, startOffsetSeconds: 0.112,
                               seconds: 12.345, outcome: .completed),
         LaunchTimingComponent(id: UUID(), stage: .textModel, startOffsetSeconds: 0.237,
                               seconds: 8.210, outcome: .completed)]
    }

    private var fixture: LaunchTimingContent {
        let stages: [(LaunchTimingStage, Double)] = [
            (.entry, 0.012), (.queue, 0.004), (.worker, 0.002), (.places, 0.017),
            (.models, 0.001), (.resources, 0.041), (.parallelModels, 12.700),
            (.modelAssembly, 0.009), (.counts, 0.062), (.publish, 0.011)
        ]
        let rows = stages.enumerated().map {
            LaunchTimingRow(id: $0.offset, stage: $0.element.0, seconds: $0.element.1)
        }
        let failed = report(outcome: .failed, seconds: 0.240, rows: [
            LaunchTimingRow(id: 0, stage: .entry, seconds: 0.010),
            LaunchTimingRow(id: 1, stage: .resources, seconds: 0.080),
            LaunchTimingRow(id: 2, stage: .parallelModels, seconds: 0.150)
        ], components: [
            LaunchTimingComponent(id: UUID(), stage: .tokenizer, startOffsetSeconds: 0.090,
                                  seconds: 0.020, outcome: .completed),
            LaunchTimingComponent(id: UUID(), stage: .imageModel, startOffsetSeconds: 0.100,
                                  seconds: 0.140, outcome: .failed),
            LaunchTimingComponent(id: UUID(), stage: .textModel, startOffsetSeconds: 0.110,
                                  seconds: 0.130, outcome: .interrupted)
        ])
        let ready = report(kind: .retry, seconds: rows.reduce(0) { $0 + $1.seconds },
                           rows: rows, components: parallelComponents)
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