import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Real production cleanup page -> first-entry restore -> its own SwiftUI alert.
/// Only public UIAlertController.message is inspected, never private AX/text
/// descendants. The fixture does not construct an alert or request Photos access.
@MainActor
final class SimilarCleanupFailurePresentationTests: XCTestCase {
    func testSourceFailureCodeAndNativeReturnAreFirstInActualOrdinaryAlert() async throws {
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: 10)
        let f = try await fixture(error: diagnostic)
        let host = try await mount(f)
        defer { host.close() }
        let alert = try await failRestore(f, in: host)
        let message = try assertAlert(alert, host: host, fixture: f,
                                      firstLine: "SG-SOURCE-LOCK-CHECK (10) · sourceCheck")
        XCTAssertEqual(f.cleanup.failureDiagnostic, diagnostic)
        XCTAssertEqual(f.cleanup.failureOperation, .restore)
        XCTAssertTrue(message.contains("恢复分组失败"))
        XCTAssertTrue(message.contains("无法检查图片索引的写入状态。"))
        XCTAssertFalse(message.contains("权限"))
        attach(try capture(host), name: "UIReview-similar-cleanup-failure-source-dark")
        try await dismiss(f, in: host)
        assertNoWork(f)
    }

    func testPermissionFailureCodeAndHintAreVisibleWithoutDebugAtMaximumDynamicType() async throws {
        let f = try await fixture(error: AppFailure.permission)
        let host = try await mount(f, maximumFont: true)
        defer { host.close() }
        let alert = try await failRestore(f, in: host)
        let message = try assertAlert(alert, host: host, fixture: f,
                                      firstLine: "SG-PHOTOS-PERMISSION · photos")
        XCTAssertEqual(f.cleanup.failureDiagnostic, .init(phase: .photos, code: .permissionDenied))
        XCTAssertEqual(f.cleanup.failureOperation, .restore)
        XCTAssertTrue(message.contains("请在系统设置中检查本 App 的照片权限。"))
        XCTAssertEqual(alert.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        attach(try capture(host), name: "UIReview-similar-cleanup-failure-permission-dark")
        try await dismiss(f, in: host)
        assertNoWork(f)
    }

    private func fixture(error: Error) async throws -> FailurePresentationFixture {
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos host; never request/reset permission")
            throw FailurePresentationError.photosReadable
        }
        let authorization = PhotoLibraryClient.authorization
        let f = FailurePresentationFixture(error: error)
        addTeardownBlock { @MainActor in
            f.grouping.release()
            f.cleanup.leavePage(); f.cleanup.pause(); f.app.enterBackground()
            await f.cleanup.waitUntilIdle(); await f.app.waitUntilIdle()
            f.app.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, authorization)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(f.worker.events, ["refresh"])
            XCTAssertEqual(f.deletion.calls, 0)
        }
        // A fake metadata-only summary establishes the real page's readiness.
        // Never call app.start()/model preparation or touch actual Photos.
        f.app.refresh()
        await f.app.waitUntilIdle()
        XCTAssertTrue(f.app.modelsReady && f.app.summary.indexStatisticsKnown && f.app.canRead)
        XCTAssertFalse(f.app.debugToolsEnabled)
        XCTAssertEqual(f.grouping.restores, 0)
        return f
    }

    private func mount(_ f: FailurePresentationFixture, maximumFont: Bool = false) async throws -> FailurePresentationHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let content = SimilarPhotoCleanupSheet(state: f.cleanup, appState: f.app,
            thumbnailContent: { _ in
                XCTFail("A failed first restore must never request a thumbnail")
                return AnyView(Color.gray)
            },
            comparisonImageSource: SimilarComparisonImageSource(
                load: { _, _, _ in throw FailurePresentationError.forbiddenWork },
                validate: { _, _, _ in XCTFail("No comparison on failed restore") }),
            embedded: true, isPageActive: true)
            .environment(\.scenePhase, .active)
            .environment(\.dynamicTypeSize, maximumFont ? .accessibility5 : .large)
            .preferredColorScheme(.dark)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = FailurePresentationHost(scene: scene, controller: UIHostingController(rootView: content),
            category: maximumFont ? .accessibilityExtraExtraExtraLarge : .large)
        do {
            try await requireLayout(host) {
                !self.descendants(host.controller.view, PrimaryPageAccessibilityAnchorView.self).isEmpty
                    && f.cleanup.isPageVisible && f.cleanup.isRestoring
            }
            return host
        } catch { host.close(); throw error }
    }

    private func failRestore(_ f: FailurePresentationFixture, in host: FailurePresentationHost) async throws -> UIAlertController {
        guard await XCTWaiter.fulfillment(of: [f.grouping.entered], timeout: 5) == .completed else {
            XCTFail("The actual embedded page did not request its first restore")
            throw FailurePresentationError.layout
        }
        XCTAssertNil(f.cleanup.message)
        XCTAssertNil(f.cleanup.failureDiagnostic)
        XCTAssertNil(findAlert(host.controller))
        f.grouping.release() // Resume the real state's awaited backend call with an error.
        await f.cleanup.waitUntilIdle()
        try await requireLayout(host) {
            guard let alert = self.findAlert(host.controller) else { return false }
            return alert.viewIfLoaded?.window === host.window && !alert.isBeingPresented
                && alert.message == f.cleanup.message
        }
        try await settle(host)
        return try XCTUnwrap(findAlert(host.controller))
    }

    @discardableResult
    private func assertAlert(_ alert: UIAlertController, host: FailurePresentationHost,
                             fixture f: FailurePresentationFixture, firstLine: String) throws -> String {
        XCTAssertEqual(alert.preferredStyle, .alert)
        XCTAssertEqual(alert.title, "相似照片清理")
        let message = try XCTUnwrap(alert.message)
        XCTAssertEqual(message, f.cleanup.message)
        XCTAssertEqual(message.components(separatedBy: "\n").first, firstLine,
                       "The ordinary alert starts with code/nativeCode/phase, not a debug-only detail")
        XCTAssertTrue(message.contains("本次未删除照片，已有索引未清除。"))
        XCTAssertFalse(f.app.debugToolsEnabled)
        XCTAssertTrue(alert.actions.contains { $0.title == "知道了" && $0.isEnabled })
        XCTAssertTrue(alert.view.window === host.window)
        XCTAssertFalse(alert.view.isHidden)
        XCTAssertGreaterThan(alert.view.alpha, 0)
        let frame = alert.view.convert(alert.view.bounds, to: host.window)
        let visible = frame.intersection(host.window.bounds)
        XCTAssertFalse(visible.isNull || visible.isEmpty)
        XCTAssertGreaterThan(visible.width, 0)
        XCTAssertGreaterThan(visible.height, 0)
        XCTAssertEqual(f.grouping.restores, 1)
        XCTAssertEqual(f.grouping.computes, 0, "Failure is not cache-missing and must not fall back to compute")
        XCTAssertFalse(f.cleanup.hasScanned || f.cleanup.canSelect || f.cleanup.isDeleting)
        XCTAssertTrue(f.cleanup.groups.isEmpty)
        XCTAssertNil(f.cleanup.pendingDeletion)
        XCTAssertNil(f.app.activity)
        return message
    }

    private func dismiss(_ f: FailurePresentationFixture, in host: FailurePresentationHost) async throws {
        f.cleanup.dismissMessage()
        try await requireLayout(host) { self.findAlert(host.controller) == nil }
        XCTAssertNil(f.cleanup.message)
        XCTAssertNil(f.cleanup.failureDiagnostic)
        XCTAssertNil(f.cleanup.failureOperation)
        f.cleanup.enterPage(ready: true)
        f.cleanup.availabilityChanged(ready: true)
        f.cleanup.resume()
        await f.cleanup.waitUntilIdle()
        XCTAssertEqual(f.grouping.restores, 1)
        XCTAssertEqual(f.grouping.computes, 0)
        XCTAssertNil(findAlert(host.controller))
    }

    private func assertNoWork(_ f: FailurePresentationFixture) {
        XCTAssertEqual(f.worker.events, ["refresh"])
        XCTAssertEqual(f.deletion.calls, 0)
        XCTAssertEqual(f.grouping.restores, 1)
        XCTAssertEqual(f.grouping.computes, 0)
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertFalse(f.app.debugToolsEnabled || f.app.allowICloudDownload)
        XCTAssertEqual(f.app.progress, IndexProgress())
        XCTAssertEqual(f.app.textIndexProgress, TextIndexProgress())
        XCTAssertTrue(f.app.results.isEmpty)
    }

    private func findAlert(_ root: UIViewController) -> UIAlertController? {
        if let alert = root as? UIAlertController { return alert }
        if let presented = root.presentedViewController, let alert = findAlert(presented) { return alert }
        for child in root.children { if let alert = findAlert(child) { return alert } }
        return nil
    }

    private func descendants<T: UIView>(_ view: UIView, _ type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
    }

    private func settle(_ host: FailurePresentationHost) async throws {
        let delivered = expectation(description: "Native cleanup alert transaction delivered")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); delivered.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [delivered], timeout: 5) == .completed else {
            XCTFail("Missing native alert layout")
            throw FailurePresentationError.layout
        }
    }

    private func requireLayout(_ host: FailurePresentationHost, observed: @escaping @MainActor () -> Bool) async throws {
        let inspect: @MainActor () -> Bool = { host.layout(); return observed() }
        let predicate = NSPredicate { _, _ in
            if Thread.isMainThread { return MainActor.assumeIsolated { inspect() } }
            return DispatchQueue.main.sync { inspect() }
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Missing actual native cleanup alert/page")
            throw FailurePresentationError.layout
        }
    }

    private func capture(_ host: FailurePresentationHost) throws -> UIImage {
        host.layout()
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        // Capture the window, not just the presenting page behind the alert.
        let image = UIGraphicsImageRenderer(size: host.window.bounds.size, format: format).image { context in
            UIColor.black.setFill(); context.fill(host.window.bounds)
            drew = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drew, "UIKit must draw the actual presented alert")
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, Int((host.window.bounds.width * format.scale).rounded()))
        XCTAssertEqual(cg.height, Int((host.window.bounds.height * format.scale).rounded()))
        // Small deterministic raster check, no private UIKit label/AX inspection.
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                bytesPerRow: 32 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        XCTAssertTrue(rendered)
        XCTAssertTrue(stride(from: 4, to: pixels.count, by: 4).contains {
            pixels[$0] != pixels[0] || pixels[$0 + 1] != pixels[1] || pixels[$0 + 2] != pixels[2]
        }, "Native screenshot must not be a uniform blank raster")
        return image
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum FailurePresentationError: Error { case photosReadable, layout, forbiddenWork }

@MainActor
private final class FailurePresentationFixture {
    let worker = FailurePresentationWorker()
    let deletion = FailurePresentationNoDeletion()
    let grouping: FailurePresentationGrouping
    let app: AppState
    let cleanup: SimilarPhotoCleanupState
    init(error: Error) {
        grouping = FailurePresentationGrouping(error: error)
        app = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: FailurePresentationTranslator())
        cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion, preferences: nil)
    }
}

@MainActor
private final class FailurePresentationHost {
    let window: UIWindow
    let controller: UIViewController
    private weak var previousKey: UIWindow?
    init(scene: UIWindowScene, controller: UIViewController, category: UIContentSizeCategory) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        self.controller = controller
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        window.traitOverrides.preferredContentSizeCategory = category
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        if let presented = controller.presentedViewController {
            presented.view.setNeedsLayout(); presented.view.layoutIfNeeded()
        }
    }
    func close() {
        controller.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
private final class FailurePresentationGrouping: SimilarPhotoGrouping {
    let entered = XCTestExpectation(description: "Actual cleanup first restore entered")
    private(set) var restores = 0
    private(set) var computes = 0
    private let error: Error
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(error: Error) { self.error = error }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        restores += 1
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
            if released { self.continuation = nil; continuation.resume() }
        }
        throw error
    }
    func release() {
        released = true
        let pending = continuation; continuation = nil; pending?.resume()
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        computes += 1
        XCTFail("Restore failure must not fall back to computation")
        throw FailurePresentationError.forbiddenWork
    }
}

@MainActor
private final class FailurePresentationWorker: PhotoWorkServicing {
    private(set) var events: [String] = []
    func refresh() async throws -> LibrarySummary {
        events.append("refresh")
        return LibrarySummary(indexedCount: 4, modelVersion: "TEST-failed-restore")
    }
    func prepareForLaunch(progress: @escaping @Sendable (LaunchStage) async -> Void) async throws -> LibrarySummary {
        throw forbidden("prepareForLaunch")
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw forbidden("search") }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary { throw forbidden("index") }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary { throw forbidden("indexText") }
    func clear() async throws -> LibrarySummary { throw forbidden("clear") }
    private func forbidden(_ operation: String) -> FailurePresentationError {
        events.append(operation)
        XCTFail("Failure presentation must not prepare models, search, index, run OCR or clear storage")
        return .forbiddenWork
    }
}

@MainActor
private final class FailurePresentationNoDeletion: PhotoDeleting {
    private(set) var calls = 0
    func delete(revisions: [PhotoRevision]) async throws {
        calls += 1; XCTFail("Failure presentation must never submit a Photos deletion")
        throw FailurePresentationError.forbiddenWork
    }
}

@MainActor
private final class FailurePresentationTranslator: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        XCTFail("Failure presentation must not translate"); throw FailurePresentationError.forbiddenWork
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        XCTFail("Failure presentation must not prepare language packs"); throw FailurePresentationError.forbiddenWork
    }
}