import XCTest
import SwiftUI
import UIKit
import Combine
import CryptoKit
import QuartzCore
import Photos
import ImageIQCore
@testable import LocalImageIQ

#if targetEnvironment(simulator)
/// Seven hosted-view tests; exactly four single-viewport native review attachments.
/// Supported UIKit rendering/layout checks, not in-process accessibility tests,
/// XCUI taps, reference-image baselines or evidence of device/Photos behavior.
/// CI 36394279080 exposed no SwiftUI AX identifiers, including normal anchors;
/// that was a harness failure, not evidence that production controls were hidden.
/// Settings/Library semantic visibility and clicks belong to the existing
/// cross-process UITests/PresentationNavigationTests. Viewer pixel differences
/// prove an observed rendering change, NOT which controls/text appeared or their
/// enabled state; its exact semantic presentation still needs manual screen review.
/// All views are production views, without copied controls, AX activation,
/// reflection or observed wrapper views. Form inventories check every native row
/// for actual visible layout/content, not the semantic identity of those rows.
///
/// Every state injects .notDetermined. Library intentionally shows its connect
/// state, not fabricated authorized coverage. No authorize/index/search action or
/// asset ID is supplied. Empty viewer IDs short-circuit load/recheckAccess before
/// any currentRevision/displayImage request. AppState still constructs its normal
/// Photos wrapper/default manager and reads authorization; this is not zero
/// PhotoKit API use. Refresh is allowed only in an unreadable simulator library,
/// so the concrete observer cannot register. Settings uses only the fake pack API.
@MainActor
final class DebugToolsPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    // MARK: Exactly four captures, with no overlays, axes or stitched scrolls

    func testSettingsUserModeAllFormRowsLayOutAndBottomRendersNonblankSnapshot() async throws {
        let c = try await context()
        try await withHost(SettingsSheet(state: c.state)) { view in
            XCTAssertFalse(c.state.debugToolsEnabled)
            _ = try await self.inspectFormRows(in: view)
            XCTAssertEqual(c.state.translationAvailability, .installed)
            XCTAssertEqual(c.translator.availabilityCalls, [.simplified])
            // The production switch is at the bottom; do not stitch other rows
            // into this viewport or claim the row inventory identifies a switch.
            let frame = try await self.formEdgeFrame(in: view, bottom: true)
            self.capture(frame, named: "settings-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testLibraryUserModeAllFormRowsLayOutAndTopRendersNonblankSnapshot() async throws {
        let c = try await context()
        try await withHost(LibrarySheet(state: c.state)) { view in
            XCTAssertFalse(c.state.debugToolsEnabled)
            _ = try await self.inspectFormRows(in: view)
            let frame = try await self.formEdgeFrame(in: view, bottom: false)
            self.capture(frame, named: "library-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testEmptyViewerUserModeRendersStableNonblankPhoneSnapshotWithoutWork() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            XCTAssertFalse(c.state.debugToolsEnabled)
            let frame = try await self.settledFrame(in: view)
            self.capture(frame, named: "viewer-default")
        }
        assertUnchanged(c, since: c.baseline)
    }

    func testEmptyViewerDebugSnapshotChangesAndRestoresSameHostPixels() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            // Return the actual ON sample, after checking OFF/ON/OFF in this
            // one host. The other two samples do not create extra attachments.
            let debugFrame = try await self.viewerRoundTrip(c, in: view)
            self.capture(debugFrame, named: "viewer-debug")
        }
        assertUnchanged(c, since: c.baseline)
    }

    // MARK: No-capture OFF -> ON -> OFF checks; never replace rootView/host/state

    func testSettingsSameHostModeRoundTripChangesPixelsAndRestoresFormRowsWithoutWork() async throws {
        let c = try await context()
        try await withHost(SettingsSheet(state: c.state)) { view in
            try await self.formRoundTrip(c, in: view)
            XCTAssertEqual(c.translator.availabilityCalls, [.simplified],
                           "Debug changes must not restart the language-pack task")
            XCTAssertEqual(c.state.translationAvailability, .installed)
        }
    }

    func testLibrarySameHostModeRoundTripChangesPixelsAndRestoresFormRowsWithoutWork() async throws {
        let c = try await context()
        try await withHost(LibrarySheet(state: c.state)) { view in
            try await self.formRoundTrip(c, in: view)
            // No scan or disclosure interaction: no claim about expanded
            // place counters, indexing-info contents or semantic AX visibility.
            XCTAssertTrue(c.translator.availabilityCalls.isEmpty)
        }
    }

    func testEmptyViewerCombineModeRoundTripChangesAndRestoresPixelsWithoutReconstructionOrWork() async throws {
        let c = try await context()
        try await withHost(viewer(c)) { view in
            _ = try await self.viewerRoundTrip(c, in: view)
            XCTAssertTrue(c.translator.availabilityCalls.isEmpty)
        }
    }

    // MARK: Fake services and state invariants

    private func context() async throws -> DebugPresentationContext {
        guard #available(iOS 18.0, *) else {
            XCTFail("Native Form review requires iOS 18+ Simulator")
            throw DebugPresentationFailure.unsupportedSimulator
        }
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use a simulator without Photos read access; no permission changes are made")
            throw DebugPresentationFailure.readablePhotoLibrary
        }
        let c = DebugPresentationContext()
        XCTAssertFalse(c.state.debugToolsEnabled, "Every new state must start in user mode")
        XCTAssertEqual(c.state.authorization, .notDetermined)
        XCTAssertNil(c.state.appleTranslationService, "Never mount Apple's translation host")
        c.state.refresh() // Fake summary only; no authorized Photos observer.
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.calls, ["refresh"])
        XCTAssertTrue(c.state.modelsReady)
        XCTAssertFalse(c.state.canRead)
        XCTAssertTrue(c.state.chineseSearchEnabled)
        XCTAssertEqual(c.state.resultLimit, 12)
        XCTAssertEqual(c.state.locationWeight, 0.6)
        XCTAssertFalse(c.state.allowICloudDownload)
        c.baseline = DebugPresentationSnapshot(c.state)
        addTeardownBlock { @MainActor in
            c.state.cancel()
            await c.state.waitUntilIdle()
        }
        return c
    }

    private func viewer(_ c: DebugPresentationContext) -> PhotoGalleryViewer {
        PhotoGalleryViewer(ids: [], initialID: "", library: c.state.library,
                           networkAllowed: false, state: c.state)
    }

    private func assertUnchanged(_ c: DebugPresentationContext, since before: DebugPresentationSnapshot,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(DebugPresentationSnapshot(c.state), before, file: file, line: line)
        XCTAssertEqual(c.worker.calls, ["refresh"], "No checks, indexing, searches, clears or extra refreshes", file: file, line: line)
        XCTAssertTrue(c.translator.translationCalls.isEmpty, file: file, line: line)
        XCTAssertTrue(c.translator.prepareCalls.isEmpty, file: file, line: line)
        XCTAssertNil(c.state.appleTranslationService, file: file, line: line)
        XCTAssertNil(c.state.photoCheckReport, file: file, line: line)
        XCTAssertNil(c.state.photoCheckIssue, file: file, line: line)
        XCTAssertNil(c.state.errorMessage, file: file, line: line)
        XCTAssertNil(c.state.activity, file: file, line: line)
    }

    // MARK: Public UIKit Form layout and actual rendered pixels (not AX)

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func form(in view: UIView) throws -> UICollectionView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? UICollectionView }.first,
                      "Expected the production iOS 18 Form collection, not a replacement settings UI")
    }

    private func formRows(_ collection: UICollectionView) -> [IndexPath] {
        (0..<collection.numberOfSections).flatMap { section in
            (0..<collection.numberOfItems(inSection: section)).map { IndexPath(item: $0, section: section) }
        }
    }

    private func formRowCounts(_ collection: UICollectionView) -> [Int] {
        (0..<collection.numberOfSections).map { collection.numberOfItems(inSection: $0) }
    }

    /// Inventory every live collapsed row, including normal rows initially below
    /// the fold. Counts are structural evidence, not invented semantic baselines.
    private func inspectFormRows(in view: UIView) async throws -> [Int] {
        await settle(view)
        let collection = try form(in: view)
        XCTAssertTrue(collection.window === view.window)
        XCTAssertFalse(collection.isHidden)
        XCTAssertGreaterThan(collection.alpha, 0)
        let counts = formRowCounts(collection)
        let rows = formRows(collection)
        XCTAssertGreaterThan(counts.reduce(0, +), 0, "The production Form must have real native rows")
        _ = try XCTUnwrap(rows.first, "An empty Form is not layout coverage")
        for path in rows {
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            await settle(view)
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(path), "Native row \(path) must actually become visible")
            let cell = try XCTUnwrap(collection.cellForItem(at: path), "Native row \(path) must be materialized")
            let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: path))
            XCTAssertEqual(attributes.representedElementCategory, .cell)
            XCTAssertGreaterThan(attributes.frame.width, 0)
            XCTAssertGreaterThan(attributes.frame.height, 0)
            XCTAssertTrue(cell.window === view.window)
            XCTAssertFalse(cell.isHidden)
            XCTAssertGreaterThan(cell.alpha, 0)
            XCTAssertGreaterThan(cell.bounds.width, 0)
            XCTAssertGreaterThan(cell.bounds.height, 0)
            let viewport = view.convert(collection.bounds, from: collection).intersection(view.bounds)
            let visible = view.convert(cell.bounds, from: cell).intersection(viewport)
            XCTAssertFalse(visible.isNull || visible.isEmpty, "Row \(path) must intersect the actual phone viewport")
            let frame = try render(view)
            let pixels = try XCTUnwrap(frame.image.cgImage)
            let crop = try XCTUnwrap(pixels.cropping(to: visible.integral.intersection(view.bounds)),
                                     "Row \(path) needs visible rendered pixels")
            _ = try pixelFingerprint(crop, label: "Native Form row \(path)")
        }
        XCTAssertEqual(formRowCounts(collection), counts, "Scrolling must not add or lose Form rows")
        return counts
    }

    private func formEdgeFrame(in view: UIView, bottom: Bool) async throws -> DebugPresentationFrame {
        let collection = try form(in: view)
        let rows = formRows(collection)
        let edge = try XCTUnwrap(bottom ? rows.last : rows.first)
        collection.scrollToItem(at: edge, at: bottom ? .bottom : .top, animated: false)
        let frame = try await settledFrame(in: view)
        XCTAssertTrue(collection.indexPathsForVisibleItems.contains(edge), "Capture the requested Form edge")
        let cell = try XCTUnwrap(collection.cellForItem(at: edge))
        let cellFrame = view.convert(cell.bounds, from: cell)
        let viewport = view.convert(collection.bounds, from: collection).intersection(view.bounds)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(cellFrame),
                      "The first/last row must fit in the review viewport, not be clipped")
        return frame
    }

    private func formRoundTrip(_ c: DebugPresentationContext, in view: UIView) async throws {
        XCTAssertFalse(c.state.debugToolsEnabled)
        let initialRows = try await inspectFormRows(in: view)
        let initial = try await formEdgeFrame(in: view, bottom: true)
        assertUnchanged(c, since: c.baseline)

        c.state.debugToolsEnabled = true
        await settle(view)
        XCTAssertTrue(c.state.debugToolsEnabled)
        let debugRows = try await inspectFormRows(in: view)
        XCTAssertGreaterThan(debugRows.reduce(0, +), initialRows.reduce(0, +),
                             "ON must add actual collapsed Form rows, not just change a stored Bool")
        let debug = try await formEdgeFrame(in: view, bottom: true)
        XCTAssertNotEqual(debug.fingerprint, initial.fingerprint, "ON must change actual rendered pixels")
        assertUnchanged(c, since: c.baseline)

        c.state.debugToolsEnabled = false
        await settle(view)
        XCTAssertFalse(c.state.debugToolsEnabled)
        let restoredRows = try await inspectFormRows(in: view)
        let restored = try await formEdgeFrame(in: view, bottom: true)
        XCTAssertEqual(restoredRows, initialRows, "OFF must restore every section's native row count")
        XCTAssertNotEqual(restored.fingerprint, debug.fingerprint, "Returning OFF must change the rendering again")
        // Form restoration uses the complete section/row inventory, not fragile
        // cross-scroll pixel equality (selection/focus/scroll adornments can vary).
        // Each individual sampled frame must nevertheless be layout/pixel stable.
        assertUnchanged(c, since: c.baseline)
    }

    private func viewerRoundTrip(_ c: DebugPresentationContext, in view: UIView) async throws -> DebugPresentationFrame {
        XCTAssertFalse(c.state.debugToolsEnabled)
        var publications: [Bool] = []
        let subscription = c.state.$debugToolsEnabled.sink { publications.append($0) }
        defer { subscription.cancel() }

        let initial = try await settledFrame(in: view)
        assertUnchanged(c, since: c.baseline)
        c.state.debugToolsEnabled = true
        let debug = try await settledFrame(in: view)
        XCTAssertTrue(c.state.debugToolsEnabled)
        XCTAssertNotEqual(debug.fingerprint, initial.fingerprint,
                          "The already-mounted empty viewer must react to the ON publication")
        assertUnchanged(c, since: c.baseline)
        c.state.debugToolsEnabled = false
        let restored = try await settledFrame(in: view)
        XCTAssertFalse(c.state.debugToolsEnabled)
        XCTAssertNotEqual(restored.fingerprint, debug.fingerprint)
        XCTAssertEqual(restored.fingerprint, initial.fingerprint,
                       "The settled empty viewer has no images, scrolling or input focus: OFF must restore its pixels")
        XCTAssertEqual(publications, [false, true, false], "Observe this same session's Combine publications")
        assertUnchanged(c, since: c.baseline)
        return debug
    }

    // MARK: One immutable native host per test body

    private func settle(_ view: UIView) async {
        let settled = expectation(description: "SwiftUI publication and native layout settled")
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setCompletionBlock {
                        DispatchQueue.main.async { settled.fulfill() }
                    }
                    view.setNeedsLayout()
                    view.layoutIfNeeded()
                    CATransaction.commit()
                }
            }
            view.setNeedsLayout()
            view.layoutIfNeeded()
            CATransaction.commit()
        }
        await fulfillment(of: [settled], timeout: 5)
    }

    private func withHost<Content: View>(_ content: Content,
                                        body: @MainActor (UIView) async throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "An iOS app test host is required")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: phone)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        // No @ObservedObject wrapper: viewer must use its own Combine subscription.
        let root = content.preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.scenePhase, .active)
        let host = DebugPresentationHostingController(rootView: root)
        let laidOut = expectation(description: "Native phone viewport mounted")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == self.phone else { return }
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
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)
        let mountedView = host.view!
        await settle(mountedView)
        try await body(mountedView)
        XCTAssertTrue(window.rootViewController === host)
        XCTAssertTrue(host.view === mountedView, "ON/OFF must update the existing native hierarchy")
        XCTAssertTrue(mountedView.window === window)
    }

    /// No taps, text focus or synthetic selection. Compare two committed samples
    /// before using a fingerprint, so transient rendering cannot prove a change.
    private func settledFrame(in view: UIView) async throws -> DebugPresentationFrame {
        await settle(view)
        let first = try render(view)
        await settle(view)
        let second = try render(view)
        XCTAssertEqual(first.fingerprint, second.fingerprint,
                       "A mode sample must be stable across native layout/transaction completions")
        return second
    }

    private func render(_ view: UIView) throws -> DebugPresentationFrame {
        _ = try XCTUnwrap(view.window, "Render only the mounted production view")
        XCTAssertFalse(view.isHidden)
        XCTAssertGreaterThan(view.alpha, 0)
        XCTAssertEqual(view.bounds.origin, .zero)
        XCTAssertEqual(view.bounds.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(size: phone, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: phone))
            drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: phone), afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "Capture the actual UIKit-hosted production hierarchy")
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 393)
        XCTAssertEqual(pixels.height, 852)
        XCTAssertEqual(image.scale, 1)
        return DebugPresentationFrame(image: image,
                                      fingerprint: try pixelFingerprint(pixels, label: "Production phone viewport"))
    }

    /// Hash decoded RGBA, not PNG metadata. Require opaque, genuinely varying
    /// content rather than accepting drawHierarchy success on a blank canvas.
    /// The dominant quantized color estimates the local background; variation
    /// must cover >0.1% of pixels, not just one stray antialiased/noisy pixel.
    private func pixelFingerprint(_ image: CGImage, label: String) throws -> Data {
        let pixelCount = image.width * image.height
        XCTAssertGreaterThan(pixelCount, 0, label)
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        let rasterized = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                         bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rasterized else {
            XCTFail("\(label): could not read the actual pixel buffer")
            throw DebugPresentationFailure.invalidPixelBuffer
        }
        var colors: [UInt32: Int] = [:]
        var opaquePixels = 0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            if rgba[offset + 3] == 255 { opaquePixels += 1 }
            let color = (UInt32(rgba[offset] >> 3) << 10)
                | (UInt32(rgba[offset + 1] >> 3) << 5)
                | UInt32(rgba[offset + 2] >> 3)
            colors[color, default: 0] += 1
        }
        XCTAssertEqual(opaquePixels, pixelCount, "\(label): the captured viewport must be opaque")
        let backgroundPixels = try XCTUnwrap(colors.values.max(), "\(label): missing pixels")
        XCTAssertGreaterThan(colors.count, 2, "\(label): a flat fill is not production content")
        XCTAssertGreaterThan(pixelCount - backgroundPixels, pixelCount / 1_000,
                             "\(label): actual nonbackground content must be present")
        return Data(SHA256.hash(data: Data(rgba)))
    }

    private func capture(_ frame: DebugPresentationFrame, named name: String) {
        let attachment = XCTAttachment(image: frame.image)
        attachment.name = "UIReview-user-mode-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Exactly four actual production frames; manual review still needs to
        // check semantic content, visual quality and clipping beyond row bounds.
    }
}

private struct DebugPresentationFrame {
    let image: UIImage
    let fingerprint: Data
}

@MainActor
private final class DebugPresentationHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private struct DebugPresentationSnapshot: Equatable {
    let authorization: PHAuthorizationStatus
    let counts: [Int]
    let summaryText: [String?]
    let progress: IndexProgress
    let query: String
    let completedQuery: String?
    let resolution: SearchQueryResolution?
    let resultIDs: [String]
    let scores: [Float]
    let selection: String?
    let limit: Int
    let weight: Double
    let cloud: Bool
    let chinese: Bool
    let language: QueryTranslationLanguage

    @MainActor init(_ state: AppState) {
        authorization = state.authorization
        counts = [state.summary.authorizedCount, state.summary.indexedCount, state.summary.locatedCount]
        summaryText = [state.summary.modelVersion, state.summary.modelIssue, state.summary.placesDescription]
        progress = state.progress
        query = state.query
        completedQuery = state.completedQuery
        resolution = state.completedSearchQuery
        resultIDs = state.results.map(\.id)
        scores = state.results.map(\.score)
        selection = state.selection?.id
        limit = state.resultLimit
        weight = state.locationWeight
        cloud = state.allowICloudDownload
        chinese = state.chineseSearchEnabled
        language = state.translationLanguage
    }
}

@MainActor
private final class DebugPresentationContext {
    let worker = DebugPresentationWorker()
    let translator = DebugPresentationTranslator()
    let state: AppState
    var baseline: DebugPresentationSnapshot

    init() {
        let state = AppState(worker: worker, authorizationStatus: { .notDetermined },
                             queryTranslator: translator, translationPreferences: nil)
        self.state = state
        baseline = DebugPresentationSnapshot(state)
    }
}

private enum DebugPresentationFailure: Error {
    case unexpectedWork, unsupportedSimulator, readablePhotoLibrary, invalidPixelBuffer
}

@MainActor
private final class DebugPresentationWorker: PhotoWorkServicing {
    private(set) var calls: [String] = []
    func refresh() async throws -> LibrarySummary {
        calls.append("refresh")
        return LibrarySummary(modelVersion: "TEST-user-mode-no-model",
                              placesDescription: "TEST FIXTURE: no photo or place data")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        calls.append("index")
        XCTFail("Rendering or toggling must not index")
        throw DebugPresentationFailure.unexpectedWork
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        calls.append("search")
        XCTFail("Rendering or toggling must not search")
        throw DebugPresentationFailure.unexpectedWork
    }
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        calls.append("check")
        XCTFail("An empty viewer must not request a photo check")
        throw DebugPresentationFailure.unexpectedWork
    }
    func clear() async throws -> LibrarySummary {
        calls.append("clear")
        XCTFail("Rendering or toggling must not clear the index")
        throw DebugPresentationFailure.unexpectedWork
    }
}

@MainActor
private final class DebugPresentationTranslator: QueryTranslating {
    let isSupported = true
    private(set) var availabilityCalls: [QueryTranslationLanguage] = []
    private(set) var translationCalls: [String] = []
    private(set) var prepareCalls: [QueryTranslationLanguage] = []
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityCalls.append(language)
        return .installed
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationCalls.append(text)
        XCTFail("Presentation must not request translation; Chinese routing has separate state tests")
        throw DebugPresentationFailure.unexpectedWork
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareCalls.append(language)
        XCTFail("Presentation must not prepare/download a language pack")
        throw DebugPresentationFailure.unexpectedWork
    }
}
#endif