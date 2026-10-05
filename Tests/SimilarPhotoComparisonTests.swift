import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Actual comparison adapter and one app-hosted actual comparison sheet.
/// All IDs, revisions and pixels are synthetic. No Photos fetch/authorization
/// request, database, model, file or network operation is performed by fixtures.
/// The concrete source initializer gets a construction smoke test, NOT a mock
/// library/no-read spy claim. Request cancellation uses the production loader's
/// existing PhotoRequestGate; these fixtures only supply/capture callbacks.
/// Rendering is not gesture/picker activation, deletion confirmation, automatic
/// cleanup or private SwiftUI accessibility evidence. Shared selection/deletion
/// controller behavior is covered in SimilarPhotoCleanupStateTests separately.
@MainActor
final class SimilarPhotoComparisonTests: XCTestCase {
    private typealias Reply = ComparisonRequests.Reply
    private let bounds = CGSize(width: 600, height: 800)

    func testPortraitFitsBothPaneAxesAndLetterboxingDoesNotRequestNetwork() async throws {
        let image = try solidImage(width: 400, height: 800)
        let requests = ComparisonRequests(replies: [[Reply(image: image)]])
        let result = try await load(requests, network: true)
        XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 400, height: 800)])
        assertOptions(requests, networks: [false], deliveries: [.highQualityFormat], resizes: [.exact])
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.stage, .localHQ)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertLessThan(result.requestedSize.width, bounds.width, "Empty horizontal space is not missing photo detail")
        XCTAssertLessThanOrEqual(result.requestedSize.height, bounds.height)
        XCTAssertEqual(result.attempts.count, 1)
    }

    func testLandscapeFitsBothPaneAxesAndLetterboxingDoesNotRequestNetwork() async throws {
        let image = try solidImage(width: 600, height: 300)
        let requests = ComparisonRequests(replies: [[Reply(image: image)]])
        let result = try await load(requests, width: 2400, height: 1200, network: true)
        XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 600, height: 300)])
        assertOptions(requests, networks: [false], deliveries: [.highQualityFormat], resizes: [.exact])
        XCTAssertTrue(result.image === image)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertLessThanOrEqual(result.requestedSize.width, bounds.width)
        XCTAssertLessThan(result.requestedSize.height, bounds.height, "Vertical letterboxing must not trigger iCloud")
        XCTAssertEqual(result.attempts.count, 1)
    }

    func testEitherInsufficientFittedAxisTriesHQ224ButNeverAutomaticallyCloudOrFast() async throws {
        for size in [CGSize(width: 399, height: 800), CGSize(width: 400, height: 799)] {
            let image = try solidImage(width: Int(size.width), height: Int(size.height))
            let requests = ComparisonRequests(replies: [[Reply(image: image)], [Reply()]])
            let result = try await load(requests)
            XCTAssertTrue(result.image === image)
            XCTAssertFalse(result.isSufficientForDisplay)
            XCTAssertEqual(result.attempts.map(\.stage), [.localHQ, .localHQ224])
            XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 400, height: 800), CGSize(width: 224, height: 448)])
            assertOptions(requests, networks: [false, false],
                          deliveries: [.highQualityFormat, .highQualityFormat], resizes: [.exact, .fast])
        }
    }

    func testOfflineMissingHQFallsBackToWholeImageFastWithEveryNetworkFlagFalse() async throws {
        let image = try solidImage(width: 112, height: 224)
        let requests = ComparisonRequests(replies: [[Reply()], [Reply()],
            [Reply(image: image, info: [PHImageResultIsDegradedKey: true])]])
        let result = try await load(requests)
        XCTAssertTrue(result.image === image)
        XCTAssertEqual(result.stage, .localFast224)
        XCTAssertEqual(result.degraded, true)
        XCTAssertFalse(result.isSufficientForDisplay)
        XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 400, height: 800),
                                                    CGSize(width: 224, height: 448), CGSize(width: 224, height: 448)])
        assertOptions(requests, networks: [false, false, false],
                      deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], resizes: [.exact, .fast, .fast])
    }

    func testOfflineCloudOnlyRemainsAnErrorWithoutAnAutomaticNetworkAttempt() async {
        let missing = Reply(info: [PHImageErrorKey: NSError(domain: PHPhotosErrorDomain, code: 3164),
                                   PHImageResultIsInCloudKey: true])
        let requests = ComparisonRequests(replies: [[missing], [missing], [missing]])
        do { _ = try await load(requests); XCTFail("Expected cloud-only result") }
        catch AppFailure.cloudOnly { }
        catch { XCTFail("Lost cloud-only classification: \(error)") }
        assertOptions(requests, networks: [false, false, false],
                      deliveries: [.highQualityFormat, .highQualityFormat, .fastFormat], resizes: [.exact, .fast, .fast])
    }

    func testOptInStillStopsAtSufficientLocalHQ224() async throws {
        let image = try solidImage(width: 400, height: 800)
        let requests = ComparisonRequests(replies: [[Reply()], [Reply(image: image)]])
        let result = try await load(requests, network: true)
        XCTAssertEqual(result.stage, .localHQ224)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertEqual(result.requestedSize, CGSize(width: 224, height: 448), "Returned pixels can exceed the request")
        XCTAssertEqual(result.returnedSize, CGSize(width: 400, height: 800))
        assertOptions(requests, networks: [false, false],
                      deliveries: [.highQualityFormat, .highQualityFormat], resizes: [.exact, .fast])
    }

    func testOptInNetworkIsThirdOnlyAfterBothLocalHQCandidatesAreInsufficient() async throws {
        let small = try solidImage(width: 112, height: 224)
        let hq224 = try solidImage(width: 224, height: 448)
        let full = try solidImage(width: 400, height: 800)
        let requests = ComparisonRequests(replies: [[Reply(image: small)], [Reply(image: hq224)],
            [Reply(image: small, info: [PHImageResultIsDegradedKey: true]),
             Reply(image: full, info: [PHImageResultIsDegradedKey: false])]])
        let result = try await load(requests, network: true)
        XCTAssertTrue(result.image === full)
        XCTAssertEqual(result.stage, .networkHQ)
        XCTAssertEqual(result.attempts.map(\.stage), [.localHQ, .localHQ224, .networkHQ])
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 400, height: 800),
                                                    CGSize(width: 224, height: 448), CGSize(width: 400, height: 800)])
        assertOptions(requests, networks: [false, false, true],
                      deliveries: [.highQualityFormat, .highQualityFormat, .highQualityFormat], resizes: [.exact, .fast, .exact])
    }

    func testComparisonPreservesRawRasterScaleAndOrientationWhileMeasuringOrientedCoverage() async throws {
        let raw = try solidImage(width: 800, height: 400)
        let image = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 3, orientation: .right)
        let requests = ComparisonRequests(replies: [[Reply(image: image)]])
        let result = try await load(requests, network: true)
        XCTAssertTrue(result.image === image)
        XCTAssertTrue(result.image.cgImage === image.cgImage)
        XCTAssertEqual(result.image.imageOrientation, .right)
        XCTAssertEqual(result.image.scale, 3)
        XCTAssertEqual(result.returnedSize, CGSize(width: 800, height: 400))
        XCTAssertEqual(result.requestedSize, CGSize(width: 400, height: 800))
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertEqual(requests.plans.count, 1)
    }

    func testInvalidAssetOrPaneGeometryFailsBeforeTheInjectedRequest() async {
        let invalid: [(Int, Int, CGSize)] = [
            (0, 2400, bounds), (1200, -1, bounds), (1200, 2400, .zero),
            (1200, 2400, CGSize(width: CGFloat.nan, height: 800)),
            (1200, 2400, CGSize(width: 600, height: CGFloat.infinity))
        ]
        for (width, height, size) in invalid {
            let requests = ComparisonRequests(replies: [])
            do {
                _ = try await load(requests, width: width, height: height, target: size)
                XCTFail("Invalid geometry must not invent a default request")
            } catch AppFailure.photo { }
            catch { XCTFail("Unexpected geometry failure: \(error)") }
            XCTAssertTrue(requests.plans.isEmpty)
        }
    }

    func testPermissionAndOrdinaryErrorsDoNotFallBackEvenWithCloudFlagAndOptIn() async {
        let ordinary = NSError(domain: "SyntheticComparison", code: 17)
        let failures: [Error] = [AppFailure.permission, ordinary]
        for failure in failures {
            let requests = ComparisonRequests(replies: [[Reply(info: [PHImageErrorKey: failure,
                                                                       PHImageResultIsInCloudKey: true])]])
            do { _ = try await load(requests, network: true); XCTFail("Expected original failure") }
            catch {
                if case AppFailure.permission = failure {
                    guard case AppFailure.permission = error else { XCTFail("Lost permission failure"); continue }
                } else {
                    XCTAssertEqual((error as NSError).domain, ordinary.domain)
                    XCTAssertEqual((error as NSError).code, ordinary.code)
                }
            }
            XCTAssertEqual(requests.plans.count, 1)
            XCTAssertEqual(requests.plans.map(\.network), [false])
        }
    }

    func testAccessValidationRejectsBeforeRequestBeforeFallbackAndAfterSuccessfulPixels() async throws {
        let full = try solidImage(width: 400, height: 800)
        // Check 1: entry. Check 2: first external request. Check 3: either
        // second-stage preflight (nil pixels) or final publication (full pixels).
        for (rejectAt, returnsImage) in [(1, false), (2, false), (3, false), (3, true)] {
            let validation = ComparisonValidation(rejectAt: rejectAt)
            let requests = ComparisonRequests(replies: [[Reply(image: returnsImage ? full : nil)]])
            do {
                _ = try await load(requests, network: true, validate: { try validation.check() })
                XCTFail("Invalid access must prevent fallback/publication")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(validation.count, rejectAt)
            XCTAssertEqual(requests.plans.count, rejectAt < 3 ? 0 : 1)
            XCTAssertTrue(requests.plans.allSatisfy { !$0.network })
        }
    }

    func testConcreteProductionSourceInitializerDoesNotInvokeLoadOrValidate() {
        let library = PhotoLibraryClient()
        let generation = library.changeGeneration
        let source = SimilarComparisonImageSource(library: library)
        // The real initializer only captures closures. Do not invoke either:
        // production validate/load would read Photos. The final concrete library
        // cannot be spied on here; this is construction coverage, not a measured
        // assertion that zero framework calls occurred inside PHImageManager.init.
        withExtendedLifetime(source) { XCTAssertEqual(library.changeGeneration, generation) }
    }

    func testAlreadyCancelledCallerPerformsNeitherValidationNorImageRequest() async {
        let requests = ComparisonRequests(replies: [])
        let validation = ComparisonValidation()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await load(requests, validate: { try validation.check() })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(requests.plans.isEmpty)
        XCTAssertEqual(validation.count, 0)
    }

    func testCancellationBeforeRequestIDCancelsEventualIDAndBeatsSynchronousCallback() async throws {
        let image = try solidImage(width: 400, height: 800)
        let cases: [[Reply]] = [[], [Reply(image: image)]]
        for replies in cases {
            let requests = ComparisonRequests(replies: [replies], cancelBeforeID: true)
            let task = Task { @MainActor in try await load(requests, network: true) }
            do { _ = try await task.value; XCTFail("Early cancellation must win") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.cancelledIDs, [1])
            XCTAssertEqual(requests.plans.count, 1)
        }
    }

    func testTaskAndCallbackCancellationBothRejectLateSuccessAndDuplicateCallbacks() async throws {
        let image = try solidImage(width: 400, height: 800)
        for cancelTask in [true, false] {
            let entered = XCTestExpectation(description: "Comparison callback captured")
            let requests = ComparisonRequests(replies: [[]], didRequest: { entered.fulfill() })
            let task = Task { @MainActor in try await load(requests, network: true) }
            defer { task.cancel(); requests.clearCallbacks() }
            try await waitFor(entered)
            if cancelTask { task.cancel() }
            else { requests.complete(1, Reply(info: [PHImageCancelledKey: true])) }
            requests.complete(1, Reply(image: image))
            requests.complete(1, Reply(info: [PHImageErrorKey: AppFailure.permission]))
            do { _ = try await task.value; XCTFail("A late callback must not publish pixels or start fallback") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(requests.plans.count, 1)
            XCTAssertEqual(requests.cancelledIDs, cancelTask ? [1] : [])
        }
    }

    func testHostedActualSheetRendersOnlyCurrentPairAndClearsPixelsWhenCleanupInvalidates() async throws {
        let photos = (0..<4).map { index in
            IndexedPhoto(id: "synthetic-comparison-\(index)", modificationTime: Double(100 + index),
                         modelVersion: "comparison-fixture", imageEmbedding: TestFixtures.vector(),
                         creationTime: Double(10 + index))
        }
        let group = SimilarPhotoGroup(id: "synthetic-comparison-group", photos: photos, minimumSimilarity: 0.98)
        let grouping = ComparisonGrouping(group: group)
        let deletion = ComparisonDeletion()
        let cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        cleanup.scan()
        await cleanup.waitUntilIdle()
        let selectedGroup = try XCTUnwrap(cleanup.groups.first)
        XCTAssertEqual(selectedGroup.photos.count, 4)
        cleanup.toggleSelection(photos[0].id) // Fixture preparation, NOT a native checkbox tap.
        XCTAssertEqual(cleanup.selectedIDs, Set([photos[0].id]))
        XCTAssertNil(cleanup.pendingDeletion)

        let worker = ComparisonWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             queryTranslator: ComparisonTranslator())
        // Do not start/refresh AppState: that could synchronize a real observer.
        XCTAssertTrue(state.canRead)
        XCTAssertFalse(state.allowICloudDownload)
        let sourceReturned = XCTestExpectation(description: "Both current synthetic image IDs returned")
        let pair = Array(photos.prefix(2))
        let revisions = pair.map { PhotoRevision(id: $0.id, modificationTime: $0.modificationTime,
                                                 creationTime: $0.creationTime) }
        let red = try solidImage(width: 1200, height: 1600, color: .red)
        let blue = try solidImage(width: 1600, height: 1200, color: .blue)
        let probe = ComparisonSourceProbe(revisions: revisions, generation: state.library.changeGeneration,
                                         images: [pair[0].id: red, pair[1].id: blue], returned: sourceReturned)
        let source = SimilarComparisonImageSource(load: { try await probe.load($0, $1, $2) },
                                                  validate: { try probe.validate($0, $1, $2) })
        let content = SimilarPhotoComparisonSheet(group: selectedGroup, cleanup: cleanup,
                                                 appState: state, imageSource: source)
        let host = try mount(content)
        defer { host.close() }
        try await waitFor(sourceReturned) // Source completion alone is not render completion.
        try await settle(host)
        let capture = try await renderedFrame(host, containsPair: true)
        let colors = try ComparisonColorCounts(image: capture)
        XCTAssertGreaterThan(colors.redLeft, 1000)
        XCTAssertGreaterThan(colors.blueRight, 1000)
        XCTAssertEqual(colors.redRight, 0)
        XCTAssertEqual(colors.blueLeft, 0)
        let attachment = XCTAttachment(image: capture)
        attachment.name = "UIReview-similar-cleanup-comparison-dark"
        attachment.lifetime = .keepAlways
        add(attachment) // The only explicit attachment; no extra failure captures.

        let calls = probe.loads
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertEqual(Set(calls.map(\.id)), Set(pair.map(\.id)), "Never load all four group members")
        XCTAssertGreaterThanOrEqual(probe.validations.count, 4, "Preflight, both reads and final publication")
        for check in probe.validations {
            XCTAssertEqual(check.revisions, revisions, "Validate the two visible revisions, not the whole group")
            XCTAssertEqual(check.authorization, PHAuthorizationStatus.authorized.rawValue)
            XCTAssertEqual(check.generation, state.library.changeGeneration)
        }
        for call in calls {
            XCTAssertFalse(call.network)
            // Check a half-width pane at 2x without assuming UIKit's nested
            // navigation viewport rounds identically to the custom UIWindow.
            XCTAssertTrue(call.target.width.isFinite && call.target.width > 0 && call.target.width <= 393)
            XCTAssertTrue(call.target.height.isFinite && call.target.height > 0 && call.target.height <= 1704)
        }
        XCTAssertEqual(probe.plans.count, calls.count, "Large synthetic local images need only one HQ request per load")
        for plan in probe.plans {
            XCTAssertEqual(plan.mode, .aspectFit)
            XCTAssertEqual(plan.delivery, .highQualityFormat)
            XCTAssertEqual(plan.resize, .exact)
            XCTAssertEqual(plan.version, .current)
            XCTAssertFalse(plan.network)
            XCTAssertFalse(plan.synchronous)
            XCTAssertTrue(plan.size.width.isFinite && plan.size.height.isFinite)
            XCTAssertGreaterThan(plan.size.width, 0)
            XCTAssertGreaterThan(plan.size.height, 0)
        }

        // Public cleanup invalidation must remove already-rendered pixels. The
        // view's private pair-switch/late-await seam is not exposed or simulated;
        // late rejection at the adapter boundary is tested above, not claimed as
        // gesture-driven view coverage. No additional review attachment is made.
        cleanup.invalidateAccess()
        try await settle(host)
        _ = try await renderedFrame(host, containsPair: false)
        XCTAssertEqual(probe.loads.count, calls.count, "Invalidation must not load the other group members")
        XCTAssertTrue(cleanup.groups.isEmpty)
        XCTAssertTrue(cleanup.selectedIDs.isEmpty)
        XCTAssertNil(cleanup.pendingDeletion)
        XCTAssertFalse(cleanup.isDeleting)
        XCTAssertEqual(grouping.count, 1, "No automatic regrouping")
        XCTAssertEqual(deletion.count, 0)
        XCTAssertEqual(worker.count, 0)
    }

    // MARK: Actual static adapter, synthetic callback provider

    private func load(_ requests: ComparisonRequests, width: Int = 1200, height: Int = 2400,
                      target: CGSize? = nil, network: Bool = false,
                      validate: @escaping @Sendable () throws -> Void = {}) async throws -> DisplayThumbnailResult {
        defer { requests.clearCallbacks() }
        return try await PhotoLibraryClient.comparisonResult(pixelWidth: width, pixelHeight: height,
            targetSize: target ?? bounds, networkAllowed: network,
            request: { requests.request($0, $1, $2, $3) }, cancel: { requests.cancel($0) }, validate: validate)
    }

    private func assertOptions(_ requests: ComparisonRequests, networks: [Bool],
                               deliveries: [PHImageRequestOptionsDeliveryMode], resizes: [PHImageRequestOptionsResizeMode],
                               file: StaticString = #filePath, line: UInt = #line) {
        let plans = requests.plans
        XCTAssertEqual(plans.map(\.network), networks, file: file, line: line)
        XCTAssertEqual(plans.map(\.delivery), deliveries, file: file, line: line)
        XCTAssertEqual(plans.map(\.resize), resizes, file: file, line: line)
        for plan in plans {
            XCTAssertEqual(plan.mode, .aspectFit, file: file, line: line)
            XCTAssertEqual(plan.version, .current, file: file, line: line)
            XCTAssertFalse(plan.synchronous, file: file, line: line)
        }
    }

    private func solidImage(width: Int, height: Int, color: UIColor = .red) throws -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, width)
        XCTAssertEqual(pixels.height, height)
        return image
    }

    // MARK: Existing PresentationTests-style stable native window and 5s waits

    private func waitFor(_ event: XCTestExpectation) async throws {
        let outcome = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        guard outcome == .completed else {
            XCTFail("Synthetic event not reached: \(event.expectationDescription)")
            throw ComparisonTestFailure.event
        }
    }

    private func mount<V: View>(_ content: V) throws -> ComparisonHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }),
                                  "An active native app-host window is required; do not skip or substitute a mock view")
        let root = content
            .safeAreaInset(edge: .top, spacing: 0) {
                Text("TEST FIXTURE · Synthetic pixels / no Photos reads")
                    .font(.caption2).foregroundStyle(.white).padding(6)
                    .frame(maxWidth: .infinity).background(Color.black)
            }
            .preferredColorScheme(.dark)
            .environment(\.scenePhase, .active)
            .environment(\.displayScale, 2)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        return ComparisonHost(scene: scene, root: AnyView(root))
    }

    private func settle(_ host: ComparisonHost) async throws {
        let settled = XCTestExpectation(description: "Pending comparison layout updates completed")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); settled.fulfill() }
        }
        try await waitFor(settled)
    }

    /// Sample actual backing pixels on display ticks until both synthetic colors
    /// draw (or clear after invalidation). Five seconds bounds test failure; it is
    /// not a sleep. No AX traversal, exact relocated-image equality or golden PNG.
    private func renderedFrame(_ host: ComparisonHost, containsPair: Bool) async throws -> UIImage {
        let ready = XCTestExpectation(description: containsPair ? "Both native panes rendered" : "Invalidated native pixels cleared")
        var output: Result<UIImage, Error>?
        var sampling = false
        let driver = ComparisonFrameDriver {
            guard output == nil, !sampling else { return }
            sampling = true
            defer { sampling = false }
            do {
                host.layout()
                guard host.controller.view.window === host.window,
                      host.controller.view.bounds.size == CGSize(width: 393, height: 852) else { return }
                let image = try host.capture()
                let counts = try ComparisonColorCounts(image: image)
                let matches = containsPair
                    ? counts.redLeft > 1000 && counts.blueRight > 1000 && counts.redRight == 0 && counts.blueLeft == 0
                    : counts.redLeft + counts.redRight + counts.blueLeft + counts.blueRight == 0
                guard matches else { return }
                output = .success(image)
                ready.fulfill()
            } catch { output = .failure(error); ready.fulfill() }
        }
        let link = CADisplayLink(target: driver, selector: #selector(ComparisonFrameDriver.tick))
        defer { link.invalidate() }
        link.add(to: .main, forMode: .common)
        try await waitFor(ready)
        return try XCTUnwrap(output).get()
    }
}

private enum ComparisonTestFailure: Error { case event, capture, unexpected, invalidAccess }

/// Mutable test records are lock protected; no continuation/completion gate is
/// reimplemented here. All callbacks and expectation signals run outside locks.
private final class ComparisonRequests: @unchecked Sendable {
    struct Reply {
        var image: UIImage? = nil
        var info: [AnyHashable: Any]? = nil
    }
    struct Plan {
        let size: CGSize
        let mode: PHImageContentMode
        let delivery: PHImageRequestOptionsDeliveryMode
        let resize: PHImageRequestOptionsResizeMode
        let version: PHImageRequestOptionsVersion
        let network: Bool
        let synchronous: Bool

        init(_ size: CGSize, _ mode: PHImageContentMode, _ options: PHImageRequestOptions) {
            self.size = size
            self.mode = mode
            delivery = options.deliveryMode
            resize = options.resizeMode
            version = options.version
            network = options.isNetworkAccessAllowed
            synchronous = options.isSynchronous
        }
    }
    private let lock = NSLock()
    private let replies: [[Reply]]
    private let cancelBeforeID: Bool
    private let didRequest: @Sendable () -> Void
    private var storedPlans: [Plan] = []
    private var cancelled: [PHImageRequestID] = []
    private var callbacks: [PHImageRequestID: DisplayThumbnailLoader.Callback] = [:]
    var plans: [Plan] { locked { storedPlans } }
    var cancelledIDs: [PHImageRequestID] { locked { cancelled } }

    init(replies: [[Reply]], cancelBeforeID: Bool = false, didRequest: @escaping @Sendable () -> Void = {}) {
        self.replies = replies
        self.cancelBeforeID = cancelBeforeID
        self.didRequest = didRequest
    }

    func request(_ size: CGSize, _ mode: PHImageContentMode, _ options: PHImageRequestOptions,
                 _ callback: @escaping DisplayThumbnailLoader.Callback) -> PHImageRequestID {
        let (id, responses): (PHImageRequestID, [Reply]) = locked {
            storedPlans.append(Plan(size, mode, options))
            let id = PHImageRequestID(storedPlans.count)
            callbacks[id] = callback
            let index = storedPlans.count - 1
            guard replies.indices.contains(index) else {
                return (id, [Reply(info: [PHImageErrorKey: ComparisonTestFailure.unexpected])])
            }
            return (id, replies[index])
        }
        didRequest()
        if cancelBeforeID { withUnsafeCurrentTask { $0?.cancel() } }
        for reply in responses { callback(reply.image, reply.info) }
        return id
    }

    func cancel(_ id: PHImageRequestID) { locked { cancelled.append(id) } }
    func complete(_ id: PHImageRequestID, _ reply: Reply) {
        let callback = locked { callbacks[id] }
        XCTAssertNotNil(callback, "A real adapter request must install this callback first")
        callback?(reply.image, reply.info)
    }
    func clearCallbacks() { locked { callbacks.removeAll() } }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class ComparisonValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    private let rejectAt: Int?
    init(rejectAt: Int? = nil) { self.rejectAt = rejectAt }
    var count: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        stored += 1
        if stored == rejectAt { throw CancellationError() }
    }
}

private final class ComparisonSourceProbe: @unchecked Sendable {
    struct Load { let id: String; let target: CGSize; let network: Bool }
    struct Validation { let revisions: [PhotoRevision]; let authorization: Int; let generation: UInt64? }
    private let lock = NSLock()
    private let revisions: [PhotoRevision]
    private let generation: UInt64?
    private let images: [String: UIImage]
    private let returned: XCTestExpectation
    private var returnedIDs: Set<String> = []
    private var storedLoads: [Load] = []
    private var storedValidations: [Validation] = []
    private var storedPlans: [ComparisonRequests.Plan] = []
    var loads: [Load] { locked { storedLoads } }
    var validations: [Validation] { locked { storedValidations } }
    var plans: [ComparisonRequests.Plan] { locked { storedPlans } }

    init(revisions: [PhotoRevision], generation: UInt64?, images: [String: UIImage], returned: XCTestExpectation) {
        self.revisions = revisions
        self.generation = generation
        self.images = images
        self.returned = returned
    }

    func validate(_ values: [PhotoRevision], _ authorization: Int, _ currentGeneration: UInt64?) throws {
        try locked {
            storedValidations.append(Validation(revisions: values, authorization: authorization, generation: currentGeneration))
            guard values == revisions, authorization == PHAuthorizationStatus.authorized.rawValue,
                  currentGeneration == generation else { throw ComparisonTestFailure.invalidAccess }
        }
    }

    func load(_ id: String, _ target: CGSize, _ network: Bool) async throws -> DisplayThumbnailResult {
        let image: UIImage = try locked {
            storedLoads.append(Load(id: id, target: target, network: network))
            guard let image = images[id] else { throw ComparisonTestFailure.unexpected }
            return image
        }
        guard let cg = image.cgImage else { throw ComparisonTestFailure.unexpected }
        let result = try await PhotoLibraryClient.comparisonResult(pixelWidth: cg.width, pixelHeight: cg.height,
            targetSize: target, networkAllowed: network, request: { [self] size, mode, options, callback in
                locked { storedPlans.append(ComparisonRequests.Plan(size, mode, options)) }
                callback(image, [PHImageResultIsDegradedKey: false])
                return 1
            }, cancel: { _ in })
        let signal = locked {
            let inserted = returnedIDs.insert(id).inserted
            return inserted && returnedIDs == Set(revisions.map(\.id))
        }
        if signal { returned.fulfill() }
        return result
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class ComparisonGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    let fixtureGroup: SimilarPhotoGroup
    private let calls = ComparisonValidation()
    var count: Int { calls.count }
    init(group: SimilarPhotoGroup) { fixtureGroup = group }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        try calls.check()
        let ids = Set(fixtureGroup.photos.map(\.id))
        return SimilarPhotoGroupingResult(groups: [fixtureGroup], candidateCount: 4, staleCount: 0,
            unindexedCount: 0, threshold: threshold, validatePhotos: { selected in
                guard Set(selected).isSubset(of: ids) else { throw ComparisonTestFailure.invalidAccess }
            })
    }
}

private final class ComparisonDeletion: PhotoDeleting, @unchecked Sendable {
    private let calls = ComparisonValidation()
    var count: Int { calls.count }
    func delete(revisions: [PhotoRevision]) async throws {
        try calls.check()
        XCTFail("Comparison render/fixture selection must never delete")
        throw ComparisonTestFailure.unexpected
    }
}

@MainActor
private final class ComparisonWorker: PhotoWorkServicing {
    private(set) var count = 0
    private func unexpected() -> ComparisonTestFailure {
        count += 1
        XCTFail("Comparison must not start indexing, searching or storage work")
        return .unexpected
    }
    func refresh() async throws -> LibrarySummary { throw unexpected() }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw unexpected() }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
}

@MainActor
private final class ComparisonTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        XCTFail("Comparison must not query translation"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("Comparison must not translate"); throw ComparisonTestFailure.unexpected
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Comparison must not prepare translation"); throw ComparisonTestFailure.unexpected
    }
}

@MainActor
private final class ComparisonHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, root: AnyView) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
    func capture() throws -> UIImage {
        let view = controller.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drawn else { throw ComparisonTestFailure.capture }
        return image
    }
}

@MainActor
private final class ComparisonFrameDriver: NSObject {
    private let sample: () -> Void
    init(_ sample: @escaping () -> Void) { self.sample = sample }
    @objc func tick() { sample() }
}

/// Decode explicit RGBA, counting broad saturated interiors independently in
/// each horizontal half. Scaling/letterbox edges need not equal source pixels.
/// Theme/checkbox gold and the white top watermark cannot satisfy these colors.
private struct ComparisonColorCounts {
    var redLeft = 0
    var redRight = 0
    var blueLeft = 0
    var blueRight = 0
    init(image: UIImage) throws {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let offset = (y * cg.width + x) * 4
                guard bytes[offset + 3] > 240 else { continue }
                let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
                if r > 200 && g < 60 && b < 60 {
                    if x < cg.width / 2 { redLeft += 1 } else { redRight += 1 }
                }
                if b > 200 && r < 60 && g < 60 {
                    if x < cg.width / 2 { blueLeft += 1 } else { blueRight += 1 }
                }
            }
        }
    }
}