import XCTest
import SwiftUI
import UIKit
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// Overlay unit renders plus hosted PhotoThumbnailView/cache integration tests.
/// All pixels/records are synthetic; the injected provider never accesses Photos.
/// No AppState, permissions, model, database, network or real assets are used.
/// Two 393x852 review attachments; a failed hosted comparison also retains one
/// combined production/oracle capture. Failure artifacts never count as a pass.
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
                XCTAssertNotEqual(try ThumbnailPresentationPixels(image: plain),
                                  try ThumbnailPresentationPixels(image: overlaid))
                let untouchedHeight = floor(size.height - footer.size.height) - 1
                XCTAssertGreaterThan(untouchedHeight, 0)
                guard untouchedHeight > 0 else { continue }
                let upperPhoto = CGRect(x: 0, y: 0, width: size.width, height: untouchedHeight)
                try assertSamePixels(crop(plain, to: upperPhoto), crop(overlaid, to: upperPhoto),
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
        let returned = XCTestExpectation(description: "Injected HQ224 request returned")
        let provider = ThumbnailPresentationProvider(load: { _ in selected }, didReturn: { _ in returned.fulfill() })
        let cache = PhotoThumbnailCache(library: provider)
        let state = ThumbnailPresentationFixture(expected: selected)
        let hosted = try mountThumbnail(state, cache: cache)
        defer { hosted.close() }

        try await waitFor(returned)
        let plain = try await matchingThumbnailFrame(hosted, size: state.size, step: "toggle.initial-off")
        XCTAssertEqual(provider.plans.map(\.targetSize), [target])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false])

        // Mutate a parent observable, not the hosting root or the child's identity.
        // The production view must have retained metadata while debug was OFF.
        state.showDiagnostics = true
        let debug = try await matchingThumbnailFrame(hosted, size: state.size, step: "toggle.on")
        let footer = try render(ThumbnailDiagnosticOverlay(thumbnail:
            CachedThumbnail(result: selected, cacheHit: false)).frame(width: state.size.width))
        let upper = CGRect(x: 0, y: 0, width: state.size.width,
                           height: floor(state.size.height - footer.size.height) - 1)
        XCTAssertGreaterThan(upper.height, 0)
        try assertSamePixels(crop(plain, to: upper), crop(debug, to: upper), "Debug preserves upper image pixels")
        XCTAssertNotEqual(try crop(plain, to: CGRect(origin: .zero, size: state.size)),
                          try crop(debug, to: CGRect(origin: .zero, size: state.size)),
                          "The actual tile must draw the selected HQ224 metadata footer")
        XCTAssertEqual(provider.plans.count, 1, "Debug ON is not a new thumbnail request")

        state.showDiagnostics = false
        let restored = try await matchingThumbnailFrame(hosted, size: state.size, step: "toggle.restored-off")
        try assertSamePixels(crop(plain, to: CGRect(origin: .zero, size: state.size)),
                             crop(restored, to: CGRect(origin: .zero, size: state.size)), "Debug OFF restores the tile")
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
        // Standalone expectations may be fulfilled before their wait. An early
        // render failure must not leave a future event registered on XCTestCase.
        let firstReturned = XCTestExpectation(description: "First geometry returned")
        let nextReturned = XCTestExpectation(description: "Changed geometry returned")
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
        try await waitFor(firstReturned)
        let before = try await matchingThumbnailFrame(hosted, size: state.size, step: "geometry.initial")

        state.expected = next
        state.size = nextSize
        try await waitFor(nextReturned)
        // A new image with the old footer (or the reverse) cannot match this
        // native reference, including selected stage, dimensions, flag and route.
        let after = try await matchingThumbnailFrame(hosted, size: nextSize, step: "geometry.changed")
        let imagePatch = CGRect(x: 20, y: 20, width: 60, height: 60)
        XCTAssertNotEqual(try crop(before, to: imagePatch), try crop(after, to: imagePatch))
        XCTAssertNotEqual(try crop(before, to: CGRect(x: 0, y: before.size.height - 48, width: 180, height: 48)),
                          try crop(after, to: CGRect(x: 0, y: after.size.height - 48, width: 180, height: 48)))
        XCTAssertEqual(provider.plans.map(\.targetSize), [firstTarget, nextTarget])
        XCTAssertEqual(provider.plans.map(\.id), [state.photoID, state.photoID])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false, false])

        state.showDiagnostics = false
        _ = try await matchingThumbnailFrame(hosted, size: nextSize, step: "geometry.debug-off")
        state.showDiagnostics = true
        _ = try await matchingThumbnailFrame(hosted, size: nextSize, step: "geometry.debug-on")
        XCTAssertEqual(provider.plans.count, 2, "Geometry reloads; debug visibility alone does not")
    }

    func testHostedIdentityChangeAfterCacheClearRejectsLateOldPixelsAndFooter() async throws {
        let target = CGSize(width: 400, height: 500)
        let old = try integrationResult(.systemRed, stage: .localHQ224,
            pixels: CGSize(width: 224, height: 299), target: target)
        let replacement = try integrationResult(.systemBlue, stage: .localHQ,
            pixels: target, target: target, degraded: nil)
        let started = XCTestExpectation(description: "Old request continuation installed")
        let oldReturned = XCTestExpectation(description: "Cancelled old provider actually returned")
        let newReturned = XCTestExpectation(description: "Replacement provider returned")
        let gate = ThumbnailPresentationGate()
        // Also release on assertion/throw cleanup; never strand a continuation.
        addTeardownBlock { await gate.release(old) }
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
        try await waitFor(started)

        cache.clear()
        state.expected = replacement
        state.photoID = "synthetic-replacement"
        try await waitFor(newReturned)
        let current = try await matchingThumbnailFrame(hosted, size: state.size, step: "identity.replacement")
        await gate.release(old) // Intentionally ignores cancellation, like a late callback.
        try await waitFor(oldReturned)
        let afterLateReturn = try await matchingThumbnailFrame(hosted, size: state.size, step: "identity.late-old-return")
        try assertSamePixels(crop(current, to: CGRect(origin: .zero, size: state.size)),
                             crop(afterLateReturn, to: CGRect(origin: .zero, size: state.size)),
                             "A late old return must not replace either pixels or metadata")
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
        try verifyPixelCoordinates()
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native app-hosted tests require a UIWindowScene, not Photos authorization")
        let measurements = ThumbnailPresentationMeasurements()
        let root = ThumbnailPresentationPair(state: state, cache: cache, onFrames: { measurements.frames = $0 })
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.layoutDirection, .leftToRight)
            .transaction { $0.animation = nil }
        return ThumbnailPresentationHost(scene: scene, root: AnyView(root), size: phone,
                                         state: state, measurements: measurements)
    }

    private func waitFor(_ event: XCTestExpectation,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        print("[ThumbnailPresentation TEST] waiting: \(event.expectationDescription)")
        let outcome = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        guard outcome == .completed else {
            XCTFail("Synthetic event not reached: \(event.expectationDescription); waiter=\(outcome)",
                    file: file, line: line)
            throw ThumbnailPresentationFailure.eventNotObserved
        }
        print("[ThumbnailPresentation TEST] observed: \(event.expectationDescription)")
    }

    /// Provider completion is NOT render completion. Wait for layout preferences
    /// belonging to the current parent inputs, then compare the two measured
    /// regions in ONE native capture. No encoded PNG comparison, guessed origin,
    /// temporal two-frame equality, tolerance, or placeholder-only success.
    /// The five seconds are only XCTest's failure bound, not a settling sleep.
    private func matchingThumbnailFrame(_ hosted: ThumbnailPresentationHost, size: CGSize, step: String,
                                        file: StaticString = #filePath, line: UInt = #line) async throws -> UIImage {
        let rendered = XCTestExpectation(description: "Synthetic native render: \(step)")
        let revision = hosted.state.renderRevision
        var result: Result<UIImage, Error>?
        var active = true
        var sampling = false
        var comparisons = 0
        var lastCapture: UIImage?
        var lastObservation = "No current layout preferences captured"
        var lastDifference = "No comparable RGBA regions captured"
        print("[ThumbnailPresentation TEST] render \(step): revision=\(revision), size=\(size), debug=\(hosted.state.showDiagnostics)")
        hosted.controller.onLayout = {
            guard active, result == nil, !sampling else { return }
            sampling = true
            DispatchQueue.main.async {
                defer { sampling = false }
                guard active, result == nil else { return }
                do {
                    let view = hosted.controller.view!
                    guard view.window === hosted.window else {
                        lastObservation = "Hosting view is not in the test window"
                        return
                    }
                    let frames = hosted.measurements.frames
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = true
                    format.preferredRange = .standard
                    var drawn = false
                    let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
                        drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
                    }
                    lastCapture = image // Includes BOTH views even on a geometry failure.
                    guard drawn else { throw ThumbnailPresentationFailure.hierarchyNotDrawn }
                    // drawHierarchy can cause another layout. Never pair pixels
                    // with pre-draw rectangles or an earlier oracle revision.
                    guard frames == hosted.measurements.frames, hosted.state.renderRevision == revision else {
                        lastObservation = "Parent inputs or measured frames changed during capture"
                        return
                    }
                    guard let canvas = frames[.canvas], let actualFrame = frames[.actual],
                          let referenceFrame = frames[.reference] else {
                        lastObservation = "Missing measured canvas/production/reference frame"
                        return
                    }
                    lastObservation = "canvas=\(canvas.rect); production=\(actualFrame.rect)@\(actualFrame.revision); "
                        + "reference=\(referenceFrame.rect)@\(referenceFrame.revision); expected revision=\(revision), size=\(size)"
                    guard [canvas, actualFrame, referenceFrame].allSatisfy({ $0.revision == revision }),
                          canvas.rect == CGRect(origin: .zero, size: view.bounds.size),
                          actualFrame.rect.size == size, referenceFrame.rect.size == size else { return }
                    guard !actualFrame.rect.intersects(referenceFrame.rect) else {
                        throw ThumbnailPresentationFailure.overlappingRegions
                    }
                    let pixels = try ThumbnailPresentationPixels(image: image)
                    let actualRect = try pixels.pixelRect(for: actualFrame.rect, in: canvas.rect)
                    let referenceRect = try pixels.pixelRect(for: referenceFrame.rect, in: canvas.rect)
                    let actual = try pixels.crop(actualRect)
                    let reference = try pixels.crop(referenceRect)
                    let difference = try actual.difference(from: reference)
                    comparisons += 1
                    lastDifference = "\(difference); production pixel rect=\(actualRect); reference pixel rect=\(referenceRect)"
                    if comparisons == 1 {
                        print("[ThumbnailPresentation TEST] \(step) measured: \(lastObservation); \(lastDifference)")
                    }
                    guard difference.count == 0 else { return }
                    // Assert sizes, not positions. Cropped images returned to
                    // callers have a known top-left origin and one pixel/point.
                    XCTAssertEqual(actualFrame.rect.size, size, file: file, line: line)
                    XCTAssertEqual(referenceFrame.rect.size, size, file: file, line: line)
                    let cg = try XCTUnwrap(image.cgImage?.cropping(to: actualRect))
                    let tileImage = UIImage(cgImage: cg, scale: 1, orientation: .up)
                    // Check that the returned local-coordinate tile is exactly
                    // the same raster that passed, not a differently flipped crop.
                    guard try ThumbnailPresentationPixels(image: tileImage) == actual else {
                        throw ThumbnailPresentationFailure.inconsistentCrop
                    }
                    result = .success(tileImage)
                    rendered.fulfill()
                } catch {
                    // Fixed test-only error cases; do not echo external errors.
                    if let failure = error as? ThumbnailPresentationFailure {
                        lastObservation += "; raster/capture validation failed: \(failure)"
                    } else {
                        lastObservation += "; raster/capture unwrap failed"
                    }
                    result = .failure(error)
                    rendered.fulfill()
                }
            }
        }
        let driver = ThumbnailPresentationFrameDriver { hosted.layout() }
        let link = CADisplayLink(target: driver, selector: #selector(ThumbnailPresentationFrameDriver.tick))
        defer {
            active = false // Disarm already queued samples after timeout/throw.
            link.invalidate()
            hosted.controller.onLayout = nil
        }
        link.add(to: .main, forMode: .common)
        let outcome = await XCTWaiter.fulfillment(of: [rendered], timeout: 5)
        active = false
        if outcome == .completed, case .success(let image)? = result {
            print("[ThumbnailPresentation TEST] matched \(step): comparisons=\(comparisons); \(lastDifference)")
            return image
        }
        if let lastCapture {
            let attachment = XCTAttachment(image: lastCapture)
            attachment.name = "UIReview-thumbnail-diagnostic-mismatch-\(step)-TEST-top-production-bottom-oracle"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let diagnostic = "Synthetic render \(step) failed; waiter=\(outcome); comparisons=\(comparisons). "
            + lastObservation + ". " + lastDifference
        print("[ThumbnailPresentation TEST] \(diagnostic)")
        XCTFail(diagnostic, file: file, line: line)
        if case .failure(let error)? = result { throw error }
        throw ThumbnailPresentationFailure.renderNotObserved
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

    private func crop(_ image: UIImage, to rect: CGRect) throws -> ThumbnailPresentationPixels {
        // All callers use one-pixel/point, upright captures and tile-local pixel
        // rectangles. Copy RGBA rows, never slice or compare encoded PNG data.
        guard image.scale == 1 else { throw ThumbnailPresentationFailure.invalidRaster }
        return try ThumbnailPresentationPixels(image: image).crop(rect)
    }

    private func assertSamePixels(_ actual: ThumbnailPresentationPixels, _ reference: ThumbnailPresentationPixels,
                                  _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let difference = try actual.difference(from: reference)
        XCTAssertEqual(difference.count, 0, "\(message); \(difference)", file: file, line: line)
    }

    private func verifyPixelCoordinates() throws {
        // An asymmetric 2x2 raster verifies row order, exact crop addressing and
        // the difference counter itself before trusting the hosted comparison.
        // Top: red/green. Bottom: blue/white. No UIKit layout or PNG involved.
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                             0, 0, 255, 255, 255, 255, 255, 255]
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: colorSpace, bitmapInfo: ThumbnailPresentationPixels.bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let pixels = try ThumbnailPresentationPixels(image: UIImage(cgImage: cg))
        let bottomLeft = CGRect(x: 0, y: 1, width: 1, height: 1)
        let croppedCG = try XCTUnwrap(cg.cropping(to: bottomLeft))
        let cropped = try pixels.crop(bottomLeft)
        let nativeCrop = try ThumbnailPresentationPixels(image: UIImage(cgImage: croppedCG))
        let zero = try pixels.difference(from: pixels)
        let topLeft = try pixels.crop(CGRect(x: 0, y: 0, width: 1, height: 1))
        let one = try topLeft.difference(from: cropped)
        guard pixels.rgba == bytes, cropped.rgba == [0, 0, 255, 255], cropped == nativeCrop,
              zero.count == 0, zero.bounds == nil, one.count == 1,
              one.bounds == CGRect(x: 0, y: 0, width: 1, height: 1) else {
            XCTFail("Synthetic RGBA decode/crop/difference coordinate contract failed")
            throw ThumbnailPresentationFailure.inconsistentCrop
        }
        print("[ThumbnailPresentation TEST] verified synthetic top-left RGBA addressing and exact diff counts/bounds")
    }
}

@MainActor
private final class ThumbnailPresentationFixture: ObservableObject {
    @Published var showDiagnostics = false { didSet { renderRevision += 1 } }
    @Published var photoID = "synthetic-old" { didSet { renderRevision += 1 } }
    @Published var size = CGSize(width: 200, height: 250) { didSet { renderRevision += 1 } }
    @Published var expected: DisplayThumbnailResult { didSet { renderRevision += 1 } }
    // Preference values carry this test-parent revision, including changes that
    // leave frames unchanged. It is not a signal from the production child.
    private(set) var renderRevision = 0

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
    let onFrames: ([ThumbnailPresentationRegion: ThumbnailPresentationMeasuredFrame]) -> Void
    private static let coordinateSpace = "synthetic-thumbnail-presentation"

    var body: some View {
        // Capture values, not just the observable object's identity, in the
        // GeometryReader content so unchanged geometry still updates the oracle.
        let expected = state.expected
        let showDiagnostics = state.showDiagnostics
        // The full-proposal root establishes the named capture coordinates.
        // Deliberately nonzero padding and a gap catch origin/stack-height guesses.
        GeometryReader { _ in
            VStack(alignment: .leading, spacing: 12) {
                PhotoThumbnailView(photo: state.photo, cache: cache, networkAllowed: false,
                                   showDiagnostics: showDiagnostics)
                    .frame(width: state.size.width, height: state.size.height)
                    .background(measure(.actual))
                GeometryReader { geometry in
                    ZStack {
                        IQStyle.muted
                        Image(uiImage: expected.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if showDiagnostics {
                            ThumbnailDiagnosticOverlay(thumbnail:
                                CachedThumbnail(result: expected, cacheHit: false))
                        }
                    }
                }
                .clipped()
                .frame(width: state.size.width, height: state.size.height)
                .background(measure(.reference))
            }
            .fixedSize()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(measure(.canvas))
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(ThumbnailPresentationFramesKey.self, perform: onFrames)
        .ignoresSafeArea()
    }

    private func measure(_ region: ThumbnailPresentationRegion) -> some View {
        let revision = state.renderRevision
        return GeometryReader { geometry in
            Color.clear.preference(key: ThumbnailPresentationFramesKey.self, value: [region:
                ThumbnailPresentationMeasuredFrame(rect: geometry.frame(in: .named(Self.coordinateSpace)),
                                                   revision: revision)])
        }
    }
}

private enum ThumbnailPresentationRegion: Hashable {
    case canvas, actual, reference
}

private struct ThumbnailPresentationMeasuredFrame: Equatable {
    let rect: CGRect
    let revision: Int
}

private struct ThumbnailPresentationFramesKey: PreferenceKey {
    static let defaultValue: [ThumbnailPresentationRegion: ThumbnailPresentationMeasuredFrame] = [:]

    static func reduce(value: inout [ThumbnailPresentationRegion: ThumbnailPresentationMeasuredFrame],
                       nextValue: () -> [ThumbnailPresentationRegion: ThumbnailPresentationMeasuredFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Callback sink owned by the host, not an observable dependency of either tile.
@MainActor
private final class ThumbnailPresentationMeasurements {
    var frames: [ThumbnailPresentationRegion: ThumbnailPresentationMeasuredFrame] = [:]
}

/// Upright, top-left-addressed sRGB, 8-bit premultiplied RGBA. Equality includes
/// dimensions and every channel; no compression metadata or image-size heuristic.
private struct ThumbnailPresentationPixels: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue)
    let width: Int
    let height: Int
    let rgba: [UInt8]

    var description: String { "RGBA \(width)x\(height) (\(rgba.count) bytes)" }
    var debugDescription: String { description }

    init(image: UIImage) throws {
        guard image.imageOrientation == .up, let cg = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ThumbnailPresentationFailure.invalidRaster
        }
        let width = cg.width
        let height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: Self.bitmapInfo.rawValue) else { throw ThumbnailPresentationFailure.invalidRaster }
            context.setBlendMode(.copy)
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.init(width: width, height: height, rgba: bytes)
    }

    private init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    func pixelRect(for frame: CGRect, in canvas: CGRect) throws -> CGRect {
        guard canvas.width > 0, canvas.height > 0, canvas.contains(frame) else {
            throw ThumbnailPresentationFailure.invalidPixelRect
        }
        // Scale comes from the actual capture, NOT the request displayScale or
        // the simulator screen. Fractional edges fail; never round/expand them.
        let scaleX = CGFloat(width) / canvas.width
        let scaleY = CGFloat(height) / canvas.height
        let rect = CGRect(x: (frame.minX - canvas.minX) * scaleX, y: (frame.minY - canvas.minY) * scaleY,
                          width: frame.width * scaleX, height: frame.height * scaleY)
        try validate(rect)
        return rect
    }

    private func validate(_ rect: CGRect) throws {
        let values = [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        guard values.allSatisfy({ $0.isFinite && $0 == $0.rounded() }),
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height) else {
            throw ThumbnailPresentationFailure.invalidPixelRect
        }
    }

    func crop(_ rect: CGRect) throws -> Self {
        try validate(rect)
        let croppedWidth = Int(rect.width)
        let croppedHeight = Int(rect.height)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(croppedWidth * croppedHeight * 4)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * width + Int(rect.minX)) * 4
            bytes.append(contentsOf: rgba[start..<(start + croppedWidth * 4)])
        }
        return Self(width: croppedWidth, height: croppedHeight, rgba: bytes)
    }

    struct Difference: CustomStringConvertible {
        let count: Int
        let total: Int
        let bounds: CGRect?

        var description: String {
            "differentPixels=\(count)/\(total); diffBounds(top-left px)=\(bounds.map { String(describing: $0) } ?? "none")"
        }
    }

    func difference(from other: Self) throws -> Difference {
        guard width == other.width, height == other.height else {
            throw ThumbnailPresentationFailure.differentRasterSizes
        }
        var count = 0
        var left = width, top = height, right = -1, bottom = -1
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            guard rgba[offset] != other.rgba[offset] || rgba[offset + 1] != other.rgba[offset + 1]
                || rgba[offset + 2] != other.rgba[offset + 2] || rgba[offset + 3] != other.rgba[offset + 3] else { continue }
            count += 1
            let x = (offset / 4) % width
            let y = (offset / 4) / width
            left = min(left, x)
            top = min(top, y)
            right = max(right, x)
            bottom = max(bottom, y)
        }
        let bounds = count == 0 ? nil : CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        return Difference(count: count, total: width * height, bounds: bounds)
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
        print("[ThumbnailPresentation TEST] provider entered: request=\(recorded.count), target=\(plan.targetSize), network=\(plan.networkAllowed)")
    }

    func currentRevision(id: String) -> PhotoRevision? { PhotoRevision(id: id, modificationTime: 1) }

    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        throw ThumbnailPresentationFailure.unexpectedImageOnlyRequest
    }

    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        let plan = Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed)
        record(plan)
        let result = try await load(plan)
        print("[ThumbnailPresentation TEST] provider returned: target=\(plan.targetSize)")
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
    case eventNotObserved, renderNotObserved, overlappingRegions
    case invalidRaster, invalidPixelRect, differentRasterSizes, inconsistentCrop
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
    let state: ThumbnailPresentationFixture
    let measurements: ThumbnailPresentationMeasurements
    private weak var previousKeyWindow: UIWindow?

    init(scene: UIWindowScene, root: AnyView, size: CGSize,
         state: ThumbnailPresentationFixture, measurements: ThumbnailPresentationMeasurements) {
        self.state = state
        self.measurements = measurements
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