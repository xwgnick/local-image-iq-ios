import XCTest
import SwiftUI
import UIKit
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// Overlay unit renders plus hosted PhotoThumbnailView/cache integration tests.
/// All pixels/records are synthetic; the injected provider never accesses Photos.
/// No AppState, permissions, model, database, network or real assets are used.
/// Exactly two 393x852 review attachments are produced when these tests run.
@MainActor
final class ThumbnailDiagnosticPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let tile = CGSize(width: 200, height: 250)

    func testSelectedStageUsesActualRawValueIncludingUnknown() {
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ, .localFast224, .unknown]
        for stage in stages {
            let thumbnail = fixture(stage: stage)
            let lines = ThumbnailDiagnosticPresentation.lines(for: thumbnail)
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(lines[0], "\(stage.rawValue) · 本次请求")
            XCTAssertEqual(Array(lines.prefix(3)), ThumbnailDiagnosticPresentation.selectedLines(for: thumbnail))
            XCTAssertEqual(lines[3], ThumbnailDiagnosticPresentation.attemptSummary(for: thumbnail))
        }
    }

    func testReturnedPixelsStayRawDespiteImageScaleOrientationAndDifferentRequest() {
        let thumbnail = fixture(requested: CGSize(width: 448, height: 598),
                                returned: CGSize(width: 299, height: 224),
                                target: CGSize(width: 224, height: 299), orientation: .right, scale: 3)
        XCTAssertTrue(thumbnail.result.isSufficientForDisplay, "The result applies orientation for coverage only")
        XCTAssertEqual(thumbnail.result.image.scale, 3)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: thumbnail)[1],
                       "返回 299×224 · 请求 448×598")
        let unverified = CachedThumbnail(result: .unverified(image: UIImage(), targetSize: tile), cacheHit: false)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: unverified)[0], "来源未知 · 本次请求")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: unverified)[1], "返回 未知 · 请求 200×250")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.cacheSummary(for: unverified), "未缓存(尺寸未知/来源未知)")
    }

    func testDimensionsPreservePositiveFiniteFractionsAndNeverPrintNaNOrInfinity() {
        XCTAssertEqual(ThumbnailDiagnosticPresentation.dimensions(CGSize(width: 299, height: 224)), "299×224")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.dimensions(CGSize(width: 224, height: 398.25)), "224×398.25")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.dimensions(CGSize(width: 0.125, height: 0.5)), "0.125×0.5")
        let invalid: [CGFloat] = [0, -0.0, -1, .nan, .infinity, -.infinity]
        for value in invalid {
            XCTAssertEqual(ThumbnailDiagnosticPresentation.dimensions(CGSize(width: value, height: 224)), "未知")
            XCTAssertEqual(ThumbnailDiagnosticPresentation.dimensions(CGSize(width: 224, height: value)), "未知")
        }
        for value in [CGFloat.leastNonzeroMagnitude, CGFloat.greatestFiniteMagnitude] {
            let text = ThumbnailDiagnosticPresentation.dimensions(CGSize(width: value, height: value))
            XCTAssertNotEqual(text, "未知")
            XCTAssertNotEqual(text, "0×0")
            XCTAssertFalse(text.lowercased().contains("nan"))
            XCTAssertFalse(text.lowercased().contains("inf"))
        }
    }

    func testDegradedIsThreeStateAndUnknownDoesNotInventARejection() {
        let cases: [(Bool?, String, String)] = [
            (false, "否", "可缓存"), (true, "是", "未缓存(降质)"), (nil, "未知", "可缓存")
        ]
        for (flag, label, cache) in cases {
            let thumbnail = fixture(degraded: flag)
            XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: thumbnail)[2], "降质：\(label) · \(cache)")
            XCTAssertEqual(thumbnail.result.isReusable, flag != true)
        }
    }

    func testCacheHitFreshEligibilityAndEveryNonReusableReasonAreDistinct() {
        let fresh = fixture()
        let hit = CachedThumbnail(result: fresh.result, cacheHit: true)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: fresh)[0], "本地 HQ224 · 本次请求")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.cacheSummary(for: fresh), "可缓存")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: hit)[0], "本地 HQ224 · 缓存命中")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.cacheSummary(for: hit), "已缓存")

        let cases: [(CachedThumbnail, String)] = [
            (fixture(returned: CGSize(width: 68, height: 120)), "未缓存(像素不足)"),
            (fixture(degraded: true), "未缓存(降质)"),
            (fixture(stage: .localFast224), "未缓存(Fast)"),
            (fixture(stage: .unknown), "未缓存(来源未知)"),
            (fixture(returned: .zero), "未缓存(尺寸未知)"),
            (fixture(requested: .zero, returned: .zero), "未缓存(尺寸未知)"),
            (fixture(stage: .localFast224, returned: CGSize(width: 68, height: 120), degraded: true),
             "未缓存(像素不足/降质/Fast)"),
            (fixture(stage: .unknown, returned: .zero, degraded: true), "未缓存(尺寸未知/降质/来源未知)")
        ]
        for (thumbnail, expected) in cases {
            XCTAssertFalse(thumbnail.result.isReusable)
            XCTAssertEqual(ThumbnailDiagnosticPresentation.cacheSummary(for: thumbnail), expected)
        }
    }

    func testCoverageAndHQLabelsAreMetadataNotSharpnessOrModelInputClaims() {
        // Intentionally use the same one-pixel test image with different result
        // metadata. Presentation must report metadata, not inspect/rejudge it.
        let sufficient = fixture()
        let reduced = fixture(returned: CGSize(width: 68, height: 120))
        XCTAssertTrue(sufficient.result.isSufficientForDisplay)
        XCTAssertFalse(reduced.result.isSufficientForDisplay)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: reduced)[2], "降质：否 · 未缓存(像素不足)")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: sufficient)[2], "降质：否 · 可缓存")
        for thumbnail in [sufficient, reduced, fixture(stage: .networkHQ)] {
            let text = ThumbnailDiagnosticPresentation.lines(for: thumbnail).joined(separator: "\n")
            for claim in ["清晰", "原图", "模型", "索引", "已下载", "iCloud", "画质合格"] {
                XCTAssertFalse(text.contains(claim), "No unsupported claim: \(claim)")
            }
        }
    }

    func testAttemptOrderCountAndCacheHistoryDoNotReplaceSelectedStage() {
        let attempts = [attempt(.localHQ, outcome: "无可用像素"),
                        attempt(.localHQ224, outcome: "native return"),
                        attempt(.networkHQ, outcome: "需网络")]
        let thumbnail = fixture(attempts: attempts)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: thumbnail),
                       "尝试（3）：大图HQ 无图 → HQ224 返回 → 联网HQ 需网")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.lines(for: thumbnail)[0], "本地 HQ224 · 本次请求",
                       "The selected candidate is not necessarily the last attempted stage")
        let hit = CachedThumbnail(result: thumbnail.result, cacheHit: true)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: hit),
                       "尝试（缓存记录·3）：大图HQ 无图 → HQ224 返回 → 联网HQ 需网")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: fixture()), "尝试：未记录")
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: fixture(cacheHit: true)),
                       "尝试（缓存记录）：未记录")
        let fast = fixture(stage: .localFast224, attempts: [attempt(.localFast224, outcome: "native return")])
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: fast), "尝试（1）：Fast224 返回")
    }

    func testUnknownAttemptOutcomesNeverEchoErrorsOrPrivateMetadata() {
        let payloads = ["TEST-ID/TEST-NAME.jpg", "GPS=12.345,67.890 query=TEST-QUERY",
                        "file:///TEST/private.png\nNSError TEST-ERROR", "native return\nTEST-SECRET"]
        let stages: [DisplayThumbnailStage] = [.localHQ, .localHQ224, .networkHQ, .unknown]
        let attempts = zip(stages, payloads).map { attempt($0.0, outcome: $0.1) }
        let thumbnail = fixture(attempts: attempts)
        XCTAssertEqual(ThumbnailDiagnosticPresentation.attemptSummary(for: thumbnail),
                       "尝试（4）：大图HQ 未知 → HQ224 未知 → 联网HQ 未知 → 未知 未知")
        let text = ThumbnailDiagnosticPresentation.lines(for: thumbnail).joined(separator: "\n")
        for payload in payloads { XCTAssertFalse(text.contains(payload)) }
        for marker in ["TEST-", "GPS", "query", "file:", "NSError"] { XCTAssertFalse(text.contains(marker)) }
    }

    func testNormalNativeFooterFits200By250AndCompact144TileWithoutCoveringWholePhoto() throws {
        let thumbnails = [highFixture, lowFixture, fastFixture]
        for size in [tile, CGSize(width: 144, height: 180)] {
            for thumbnail in thumbnails {
                let footer = try render(ThumbnailDiagnosticOverlay(thumbnail: thumbnail).frame(width: size.width))
                XCTAssertEqual(footer.size.width, size.width)
                XCTAssertGreaterThan(footer.size.height, 0)
                XCTAssertLessThan(footer.size.height, size.height,
                                  "Measure the real footer, not just a forcibly sized wrapper")
                let plain = try render(cell(nil, size: size, title: "TEST"))
                let overlaid = try render(cell(thumbnail, size: size, title: "TEST"))
                XCTAssertEqual(overlaid.size, size)
                XCTAssertNotEqual(try XCTUnwrap(plain.pngData()), try XCTUnwrap(overlaid.pngData()))
                let untouchedHeight = floor(size.height - footer.size.height) - 1
                XCTAssertGreaterThan(untouchedHeight, 0)
                guard untouchedHeight > 0 else { continue }
                let upperPhoto = CGRect(x: 0, y: 0, width: size.width, height: untouchedHeight)
                XCTAssertEqual(try crop(plain, to: upperPhoto), try crop(overlaid, to: upperPhoto),
                               "The footer stays bottom-aligned; the photo area above it is unchanged")
            }
        }
    }

    func testLargeTypeGrowsVerticallyRatherThanPretendingAllMetadataFitsA250PointTile() throws {
        let content = ThumbnailDiagnosticOverlay(thumbnail: fastFixture).frame(width: tile.width)
        let normal = try render(content)
        let large = try render(content, dynamicType: .accessibility5)
        XCTAssertEqual(normal.size.width, tile.width)
        XCTAssertEqual(large.size.width, tile.width)
        XCTAssertGreaterThan(large.size.height, normal.size.height)
        XCTAssertGreaterThan(large.size.height, tile.height,
                             "Full selected metadata at maximum type cannot fit this fixed tile; do not shrink it")
        // This wrapper mirrors a clipped tile, NOT a claim that all large text
        // remains visible. The natural-size render above exposes that overflow.
        let bounded = try render(cell(fastFixture, size: tile, title: "TEST"), dynamicType: .accessibility5)
        XCTAssertEqual(bounded.size, tile)
    }

    func testLightSyntheticPhoneSnapshot() throws {
        try snapshot(scheme: .light, name: "UIReview-thumbnail-diagnostic-light")
    }

    func testDarkSyntheticPhoneSnapshot() throws {
        try snapshot(scheme: .dark, name: "UIReview-thumbnail-diagnostic-dark")
    }

    // MARK: Actual PhotoThumbnailView @State/task/cache integration

    func testHostedThumbnailDiagnosticsToggleKeepsLoadedPixelsAndDoesNotRequestAgain() async throws {
        let target = CGSize(width: 400, height: 500)
        let selected = try integrationResult(.systemRed, stage: .localHQ224,
            pixels: CGSize(width: 224, height: 299), target: target)
        XCTAssertFalse(selected.isSufficientForDisplay)
        let returned = expectation(description: "Injected HQ224 request returned")
        let provider = ThumbnailPresentationProvider(load: { _ in selected }, didReturn: { _ in returned.fulfill() })
        let cache = PhotoThumbnailCache(library: provider)
        let state = ThumbnailPresentationFixture(expected: selected)
        let hosted = try mountThumbnail(state, cache: cache)
        defer { hosted.close() }

        await fulfillment(of: [returned], timeout: 5)
        let plain = try await matchingThumbnailFrame(hosted, size: state.size)
        XCTAssertEqual(provider.plans.map(\.targetSize), [target])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false])

        // Mutate a parent observable, not the hosting root or the child's identity.
        // The production view must have retained metadata while debug was OFF.
        state.showDiagnostics = true
        let debug = try await matchingThumbnailFrame(hosted, size: state.size)
        let footer = try render(ThumbnailDiagnosticOverlay(thumbnail:
            CachedThumbnail(result: selected, cacheHit: false)).frame(width: state.size.width))
        let upper = CGRect(x: 0, y: 0, width: state.size.width,
                           height: floor(state.size.height - footer.size.height) - 1)
        XCTAssertGreaterThan(upper.height, 0)
        XCTAssertEqual(try crop(plain, to: upper), try crop(debug, to: upper))
        XCTAssertNotEqual(try crop(plain, to: CGRect(origin: .zero, size: state.size)),
                          try crop(debug, to: CGRect(origin: .zero, size: state.size)),
                          "The actual tile must draw the selected HQ224 metadata footer")
        XCTAssertEqual(provider.plans.count, 1, "Debug ON is not a new thumbnail request")

        state.showDiagnostics = false
        let restored = try await matchingThumbnailFrame(hosted, size: state.size)
        XCTAssertEqual(try crop(plain, to: CGRect(origin: .zero, size: state.size)),
                       try crop(restored, to: CGRect(origin: .zero, size: state.size)))
        XCTAssertEqual(provider.plans.count, 1, "Debug OFF restores pixels without reloading")
    }

    func testHostedGeometryChangePublishesNewPixelsAndSelectedMetadataTogether() async throws {
        let firstTarget = CGSize(width: 400, height: 500)
        let nextSize = CGSize(width: 244, height: 300)
        let nextTarget = CGSize(width: 488, height: 600)
        let first = try integrationResult(.systemRed, stage: .localHQ224,
            pixels: CGSize(width: 224, height: 299), target: firstTarget)
        let next = try integrationResult(.systemBlue, stage: .localHQ,
            pixels: nextTarget, target: nextTarget, degraded: nil)
        let firstReturned = expectation(description: "First geometry returned")
        let nextReturned = expectation(description: "Changed geometry returned")
        let provider = ThumbnailPresentationProvider(load: { plan in
            if plan.targetSize == firstTarget { return first }
            if plan.targetSize == nextTarget { return next }
            throw ThumbnailPresentationFailure.unexpectedRequest
        }, didReturn: { plan in
            if plan.targetSize == firstTarget { firstReturned.fulfill() }
            if plan.targetSize == nextTarget { nextReturned.fulfill() }
        })
        let state = ThumbnailPresentationFixture(expected: first)
        state.showDiagnostics = true
        let hosted = try mountThumbnail(state, cache: PhotoThumbnailCache(library: provider))
        defer { hosted.close() }
        await fulfillment(of: [firstReturned], timeout: 5)
        let before = try await matchingThumbnailFrame(hosted, size: state.size)

        state.expected = next
        state.size = nextSize
        await fulfillment(of: [nextReturned], timeout: 5)
        // A new image with the old footer (or the reverse) cannot match this
        // native reference, including selected stage, dimensions, flag and route.
        let after = try await matchingThumbnailFrame(hosted, size: nextSize)
        let imagePatch = CGRect(x: 20, y: 20, width: 60, height: 60)
        XCTAssertNotEqual(try crop(before, to: imagePatch), try crop(after, to: imagePatch))
        XCTAssertNotEqual(try crop(before, to: CGRect(x: 0, y: before.size.height - 48, width: 180, height: 48)),
                          try crop(after, to: CGRect(x: 0, y: after.size.height - 48, width: 180, height: 48)))
        XCTAssertEqual(provider.plans.map(\.targetSize), [firstTarget, nextTarget])
        XCTAssertEqual(provider.plans.map(\.id), [state.photoID, state.photoID])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])

        state.showDiagnostics = false
        _ = try await matchingThumbnailFrame(hosted, size: nextSize)
        state.showDiagnostics = true
        _ = try await matchingThumbnailFrame(hosted, size: nextSize)
        XCTAssertEqual(provider.plans.count, 2, "Geometry reloads; debug visibility alone does not")
    }

    func testHostedIdentityChangeAfterCacheClearRejectsLateOldPixelsAndFooter() async throws {
        let target = CGSize(width: 400, height: 500)
        let old = try integrationResult(.systemRed, stage: .localHQ224,
            pixels: CGSize(width: 224, height: 299), target: target)
        let replacement = try integrationResult(.systemBlue, stage: .localHQ,
            pixels: target, target: target, degraded: nil)
        let started = expectation(description: "Old request continuation installed")
        let oldReturned = expectation(description: "Cancelled old provider actually returned")
        let newReturned = expectation(description: "Replacement provider returned")
        let gate = ThumbnailPresentationGate()
        // Also release on assertion/throw cleanup; never strand a continuation.
        defer { Task { await gate.release(old) } }
        let provider = ThumbnailPresentationProvider(load: { plan in
            if plan.id == "synthetic-old" {
                return await gate.wait { started.fulfill() }
            }
            return replacement
        }, didReturn: { plan in
            if plan.id == "synthetic-old" { oldReturned.fulfill() }
            else { newReturned.fulfill() }
        })
        let state = ThumbnailPresentationFixture(expected: old)
        state.showDiagnostics = true
        let cache = PhotoThumbnailCache(library: provider)
        let hosted = try mountThumbnail(state, cache: cache)
        defer { hosted.close() }
        await fulfillment(of: [started], timeout: 5)

        cache.clear()
        state.expected = replacement
        state.photoID = "synthetic-replacement"
        await fulfillment(of: [newReturned], timeout: 5)
        let current = try await matchingThumbnailFrame(hosted, size: state.size)
        await gate.release(old) // Intentionally ignores cancellation, like a late callback.
        await fulfillment(of: [oldReturned], timeout: 5)
        let afterLateReturn = try await matchingThumbnailFrame(hosted, size: state.size)
        XCTAssertEqual(try crop(current, to: CGRect(origin: .zero, size: state.size)),
                       try crop(afterLateReturn, to: CGRect(origin: .zero, size: state.size)))
        XCTAssertEqual(provider.plans.map(\.id), ["synthetic-old", "synthetic-replacement"])
        XCTAssertEqual(provider.plans.map(\.targetSize), [target, target])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])
    }

    private func integrationResult(_ color: UIColor, stage: DisplayThumbnailStage, pixels: CGSize,
                                   target: CGSize, degraded: Bool? = false) throws -> DisplayThumbnailResult {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: pixels))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: pixels.width / 2, y: 0, width: 12, height: pixels.height))
        }
        let cg = try XCTUnwrap(image.cgImage, "Integration images must have real generated CG pixels")
        let returned = CGSize(width: cg.width, height: cg.height)
        let request = stage == .localHQ224 ? pixels : target
        var attempts: [DisplayThumbnailAttempt] = []
        if stage == .localHQ224 {
            attempts.append(DisplayThumbnailAttempt(stage: .localHQ, requestedSize: target,
                returnedSize: nil, degraded: nil, outcome: "无可用像素"))
        }
        attempts.append(DisplayThumbnailAttempt(stage: stage, requestedSize: request,
            returnedSize: returned, degraded: degraded, outcome: "native return"))
        return DisplayThumbnailResult(image: image, stage: stage, requestedSize: request,
            returnedSize: returned, degraded: degraded, attempts: attempts, targetSize: target)
    }

    private func mountThumbnail(_ state: ThumbnailPresentationFixture,
                                cache: PhotoThumbnailCache) throws -> ThumbnailPresentationHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native app-hosted tests require a UIWindowScene, not Photos authorization")
        let root = ThumbnailPresentationPair(state: state, cache: cache)
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.layoutDirection, .leftToRight)
            .transaction { $0.animation = nil }
        return ThumbnailPresentationHost(scene: scene, root: AnyView(root), size: phone)
    }

    /// Provider completion is NOT render completion. Observe real native layout,
    /// then sample on the main queue after that layout. Two consecutive display
    /// frames must match the independently supplied image + production footer.
    /// The five seconds are only XCTest's failure bound, not a settling sleep.
    private func matchingThumbnailFrame(_ hosted: ThumbnailPresentationHost, size: CGSize) async throws -> UIImage {
        let rendered = expectation(description: "Actual thumbnail pixels and footer match after native layout")
        var result: Result<UIImage, Error>?
        var previous: Data?
        var sampling = false
        hosted.controller.onLayout = {
            guard result == nil, !sampling else { return }
            sampling = true
            DispatchQueue.main.async {
                defer { sampling = false }
                guard result == nil else { return }
                do {
                    let view = hosted.controller.view!
                    guard view.window === hosted.window, view.bounds.size == self.phone else { return }
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    format.preferredRange = .standard
                    var drawn = false
                    let image = UIGraphicsImageRenderer(size: self.phone, format: format).image { _ in
                        drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                    }
                    guard drawn else { throw ThumbnailPresentationFailure.hierarchyNotDrawn }
                    let actualRect = CGRect(origin: .zero, size: size)
                    let referenceRect = CGRect(x: 0, y: size.height, width: size.width, height: size.height)
                    let actual = try self.crop(image, to: actualRect)
                    let reference = try self.crop(image, to: referenceRect)
                    guard actual == reference else { previous = nil; return }
                    if previous == actual {
                        let cg = try XCTUnwrap(image.cgImage?.cropping(to: actualRect))
                        result = .success(UIImage(cgImage: cg))
                        rendered.fulfill()
                    } else { previous = actual }
                } catch {
                    result = .failure(error)
                    rendered.fulfill()
                }
            }
        }
        let driver = ThumbnailPresentationFrameDriver { hosted.layout() }
        let link = CADisplayLink(target: driver, selector: #selector(ThumbnailPresentationFrameDriver.tick))
        defer {
            link.invalidate()
            hosted.controller.onLayout = nil
        }
        link.add(to: .main, forMode: .common)
        await fulfillment(of: [rendered], timeout: 5)
        return try XCTUnwrap(result, "A provider return/placeholder alone is not a rendered thumbnail").get()
    }

    // MARK: Test-only metadata and solid-gray stand-ins

    private func fixture(stage: DisplayThumbnailStage = .localHQ224,
                         requested: CGSize = CGSize(width: 299, height: 224),
                         returned: CGSize = CGSize(width: 299, height: 224),
                         target: CGSize = CGSize(width: 299, height: 224),
                         degraded: Bool? = false, cacheHit: Bool = false,
                         attempts: [DisplayThumbnailAttempt] = [],
                         orientation: UIImage.Orientation = .up, scale: CGFloat = 1) -> CachedThumbnail {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let image = pixel.cgImage.map { UIImage(cgImage: $0, scale: scale, orientation: orientation) } ?? pixel
        return CachedThumbnail(result: DisplayThumbnailResult(image: image, stage: stage, requestedSize: requested,
            returnedSize: returned, degraded: degraded, attempts: attempts, targetSize: target), cacheHit: cacheHit)
    }

    private func attempt(_ stage: DisplayThumbnailStage, outcome: String) -> DisplayThumbnailAttempt {
        DisplayThumbnailAttempt(stage: stage, requestedSize: CGSize(width: 299, height: 224),
            returnedSize: outcome == "native return" ? CGSize(width: 299, height: 224) : nil,
            degraded: nil, outcome: outcome)
    }

    private var highFixture: CachedThumbnail {
        fixture(cacheHit: true, attempts: [attempt(.localHQ, outcome: "无可用像素"),
                                          attempt(.localHQ224, outcome: "native return")])
    }

    private var lowFixture: CachedThumbnail {
        let request = CGSize(width: 224, height: 398)
        let returned = CGSize(width: 68, height: 120)
        return fixture(requested: request, returned: returned, target: CGSize(width: 600, height: 750), attempts: [
            attempt(.localHQ, outcome: "无可用像素"),
            DisplayThumbnailAttempt(stage: .localHQ224, requestedSize: request, returnedSize: returned,
                                    degraded: false, outcome: "native return")
        ])
    }

    private var fastFixture: CachedThumbnail {
        let request = CGSize(width: 224, height: 398)
        let returned = CGSize(width: 68, height: 120)
        return fixture(stage: .localFast224, requested: request, returned: returned,
                       target: CGSize(width: 600, height: 750), degraded: true, attempts: [
            attempt(.localHQ, outcome: "无可用像素"), attempt(.localHQ224, outcome: "无可用像素"),
            DisplayThumbnailAttempt(stage: .localFast224, requestedSize: request, returnedSize: returned,
                                    degraded: true, outcome: "native return")
        ])
    }

    private func cell(_ thumbnail: CachedThumbnail?, size: CGSize, title: String) -> some View {
        Color(white: 0.55)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                Text(verbatim: title).font(.caption2).foregroundStyle(.white).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if let thumbnail { ThumbnailDiagnosticOverlay(thumbnail: thumbnail) }
            }
            .clipped()
    }

    private func snapshot(scheme: ColorScheme, name: String) throws {
        let content = VStack(alignment: .leading, spacing: 16) {
            Text("TEST · Synthetic thumbnail diagnostics").font(.headline)
            Text("Standalone overlay · No Photos or app state").font(.caption)
            VStack(spacing: 12) {
                cell(highFixture, size: tile, title: "TEST · HQ metadata / cache hit")
                cell(lowFixture, size: tile, title: "TEST · Reduced-size metadata")
            }
            .frame(maxWidth: .infinity)
            Text("Metadata is not a sharpness score.\nSolid gray cells are test placeholders.").font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .padding(20)
        .frame(width: phone.width, height: phone.height, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        let image = try render(content, scheme: scheme)
        XCTAssertEqual(image.size, phone)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 393)
        XCTAssertEqual(pixels.height, 852)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func render<Content: View>(_ content: Content, scheme: ColorScheme = .light,
                                      dynamicType: DynamicTypeSize = .large) throws -> UIImage {
        var image: UIImage?
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        traits.performAsCurrent {
            let renderer = ImageRenderer(content: content
                .environment(\.colorScheme, scheme)
                .environment(\.dynamicTypeSize, dynamicType)
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
                .environment(\.layoutDirection, .leftToRight))
            renderer.scale = 1
            image = renderer.uiImage
        }
        return try XCTUnwrap(image, "Render the real SwiftUI overlay, not a reconstructed text graphic")
    }

    private func crop(_ image: UIImage, to rect: CGRect) throws -> Data {
        let pixels = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(pixels.cropping(to: rect))
        return try XCTUnwrap(UIImage(cgImage: cropped).pngData())
    }
}

@MainActor
private final class ThumbnailPresentationFixture: ObservableObject {
    @Published var showDiagnostics = false
    @Published var photoID = "synthetic-old"
    @Published var size = CGSize(width: 200, height: 250)
    @Published var expected: DisplayThumbnailResult

    init(expected: DisplayThumbnailResult) { self.expected = expected }

    var photo: IndexedPhoto {
        IndexedPhoto(id: photoID, modificationTime: 1, modelVersion: "synthetic-thumbnail-only",
                     imageEmbedding: [1, 0])
    }
}

/// The upper tile is the real production view. The lower tile is a pixel oracle
/// using the expected tuple, never the child's private state. Both share native
/// rendering/traits so ImageRenderer vs UIKit font rasterization cannot mask a bug.
@MainActor
private struct ThumbnailPresentationPair: View {
    @ObservedObject var state: ThumbnailPresentationFixture
    let cache: PhotoThumbnailCache

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhotoThumbnailView(photo: state.photo, cache: cache, networkAllowed: false,
                               showDiagnostics: state.showDiagnostics)
                .frame(width: state.size.width, height: state.size.height)
            Image(uiImage: state.expected.image)
                .resizable()
                .scaledToFill()
                .frame(width: state.size.width, height: state.size.height)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if state.showDiagnostics {
                        ThumbnailDiagnosticOverlay(thumbnail: CachedThumbnail(result: state.expected, cacheHit: false))
                    }
                }
                .clipped()
        }
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Immutable synchronous access metadata; only the request log needs a lock.
/// UIImage is carried read-only inside the production Sendable result type.
private final class ThumbnailPresentationProvider: PhotoThumbnailProviding, @unchecked Sendable {
    struct Plan: Sendable {
        let id: String
        let targetSize: CGSize
        let networkAllowed: Bool
    }
    let canReadImages = true
    let changeGeneration: UInt64? = 0
    private let lock = NSLock()
    private var recorded: [Plan] = []
    private let load: @Sendable (Plan) async throws -> DisplayThumbnailResult
    private let didReturn: @Sendable (Plan) -> Void

    init(load: @escaping @Sendable (Plan) async throws -> DisplayThumbnailResult,
         didReturn: @escaping @Sendable (Plan) -> Void) {
        self.load = load
        self.didReturn = didReturn
    }

    var plans: [Plan] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ plan: Plan) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(plan)
    }

    func currentRevision(id: String) -> PhotoRevision? { PhotoRevision(id: id, modificationTime: 1) }

    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        throw ThumbnailPresentationFailure.unexpectedImageOnlyRequest
    }

    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        let plan = Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed)
        record(plan)
        let result = try await load(plan)
        didReturn(plan)
        return result
    }
}

private actor ThumbnailPresentationGate {
    private var released: DisplayThumbnailResult?
    private var continuation: CheckedContinuation<DisplayThumbnailResult, Never>?

    func wait(installed: @Sendable () -> Void) async -> DisplayThumbnailResult {
        if let released { return released }
        return await withCheckedContinuation {
            continuation = $0
            installed()
        }
    }

    func release(_ result: DisplayThumbnailResult) {
        guard released == nil else { return }
        released = result
        let pending = continuation
        continuation = nil
        pending?.resume(returning: result)
    }
}

private enum ThumbnailPresentationFailure: Error {
    case unexpectedRequest, unexpectedImageOnlyRequest, hierarchyNotDrawn
}

@MainActor
private final class ThumbnailPresentationController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

@MainActor
private final class ThumbnailPresentationFrameDriver: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

@MainActor
private final class ThumbnailPresentationHost {
    let window: UIWindow
    let controller: ThumbnailPresentationController
    private weak var previousKeyWindow: UIWindow?

    init(scene: UIWindowScene, root: AnyView, size: CGSize) {
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        controller = ThumbnailPresentationController(rootView: root)
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }

    func layout() {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func close() {
        controller.onLayout = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}