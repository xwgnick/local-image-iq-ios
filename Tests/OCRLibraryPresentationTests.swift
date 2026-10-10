import XCTest
import SwiftUI
import UIKit
import Photos
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// OCR library-specific regression coverage. Synthetic workers, real child
/// publications and native hosted views; no Photos fetch, Vision or index IO.
/// Preferences use an isolated suite that is removed after worker teardown.
/// Calling the view's action methods tests its actual button closures, not an
/// XCUI tap. The footer harness tests covered layout, not ContentView routing.
@MainActor
final class OCRLibraryPresentationTests: XCTestCase {
    func testWaitingCancellationDoesNotCancelHeldManualImageIndex() async throws {
        let c = try await context()
        let image = OCRLibraryGate()
        c.worker.imageGate = image
        c.state.index()
        try await reached(c.worker.imageEntered)
        c.state.textSearchEnabled = true
        let content = PhotoTextIndexContent(state: c.state)
        XCTAssertEqual(c.state.activity, .indexing)
        XCTAssertEqual(c.state.ocrSync.phase, .waiting)
        XCTAssertTrue(content.hasStopAction)
        XCTAssertFalse(content.canUpdate)
        XCTAssertEqual(status(c.state).title, "文字索引等待更新")

        content.cancelUpdate()
        XCTAssertEqual(c.state.ocrSync.phase, .cancelled)
        XCTAssertFalse(c.state.ocrSync.pending)
        XCTAssertEqual(c.state.activity, .indexing)
        XCTAssertEqual(c.worker.textCalls, 0)
        image.open()
        await c.state.waitUntilIdle()
        XCTAssertFalse(c.worker.imageWasCancelled, "OCR cancel must not call the foreground-wide cancel()")
        XCTAssertEqual(c.worker.imageCalls, 1)
        XCTAssertEqual(c.worker.textCalls, 0, "Cancelled intent must not be admitted when the image job settles")
        XCTAssertTrue(content.canUpdate)
        XCTAssertEqual(content.updateTitle, "重试文字索引")
    }

    func testWaitingCancellationDoesNotStopAutomaticPhotoSync() async throws {
        let photo = OCRLibraryPhotoService()
        let c = try await context(photo: photo)
        c.state.start()
        await c.state.waitUntilIdle()
        try await reached(photo.entered)
        c.state.textSearchEnabled = true
        XCTAssertEqual(c.state.ocrSync.phase, .waiting)
        XCTAssertEqual(c.state.photoSync.phase, .updating)
        XCTAssertTrue(c.state.photoSync.canCancel)

        PhotoTextIndexContent(state: c.state).cancelUpdate()
        XCTAssertEqual(c.state.ocrSync.phase, .cancelled)
        XCTAssertEqual(c.state.photoSync.phase, .updating)
        XCTAssertTrue(c.state.photoSync.canCancel)
        photo.gate.open()
        await c.state.waitForSync()
        await c.state.waitUntilIdle()
        XCTAssertFalse(photo.wasCancelled)
        XCTAssertEqual(photo.calls, 1)
        XCTAssertEqual(c.worker.textCalls, 0)
        XCTAssertEqual(c.worker.imageCalls, 0)
    }

    func testQueuedRequestRunsOnceAndCancellationRemainsDrainingUntilWorkerReturns() async throws {
        let c = try await context()
        let image = OCRLibraryGate()
        let text = OCRLibraryGate()
        c.worker.imageGate = image
        c.worker.textGate = text
        c.state.index()
        try await reached(c.worker.imageEntered)
        c.state.textSearchEnabled = true
        let content = PhotoTextIndexContent(state: c.state)
        XCTAssertEqual(c.state.ocrSync.phase, .waiting)
        image.open()
        try await reached(c.worker.textEntered)
        XCTAssertEqual(c.state.activity, .indexingText)
        XCTAssertEqual(c.state.ocrSync.phase, .checking)
        XCTAssertNil(c.state.ocrSync.fraction)
        let callback = try XCTUnwrap(c.worker.textProgress)
        await callback(.init(total: 8, completed: 3, recognized: 2, reused: 1))
        XCTAssertEqual(status(c.state).title, "正在更新文字索引 3/8")
        XCTAssertEqual(c.state.ocrSync.fraction, 0.375)
        content.cancelUpdate()
        XCTAssertEqual(c.state.ocrSync.phase, .cancelling)
        XCTAssertTrue(c.state.ocrSync.currentRunning)
        XCTAssertTrue(content.hasStopAction)
        XCTAssertFalse(c.state.ocrSync.canCancel)
        XCTAssertFalse(content.canUpdate)
        content.updateIndex() // Disabled UI action also guards a stale invocation.
        await callback(.init(total: 8, completed: 4, recognized: 3, reused: 1))
        XCTAssertEqual(c.state.ocrSync.phase, .cancelling)
        XCTAssertEqual(c.state.ocrSync.progress.completed, 4)
        XCTAssertNil(c.state.ocrSync.fraction)
        text.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.ocrSync.phase, .cancelled)
        XCTAssertEqual(c.state.ocrSync.progress.completed, 4)
        XCTAssertTrue(c.worker.textWasCancelled)
        XCTAssertFalse(c.worker.imageWasCancelled)
        XCTAssertEqual(c.worker.textCalls, 1)
        XCTAssertTrue(content.canUpdate)
        content.updateIndex()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.textCalls, 2, "Only the explicit retry starts another pass")
        XCTAssertEqual(c.state.ocrSync.phase, .completed)
    }

    func testDrainingOCRStillShowsStopStateWhenRefreshHasSupersededActivity() async throws {
        let c = try await context(savedEnabled: true)
        let text = OCRLibraryGate()
        c.worker.textGate = text
        let content = PhotoTextIndexContent(state: c.state)
        content.updateIndex()
        try await reached(c.worker.textEntered)
        c.state.refresh()
        XCTAssertEqual(c.state.activity, .refreshing)
        XCTAssertEqual(c.state.ocrSync.phase, .cancelling)
        XCTAssertEqual(status(c.state).title, "正在取消文字更新")
        XCTAssertTrue(content.hasStopAction, "Activity belongs to the successor while OCR is still draining")
        XCTAssertFalse(content.canUpdate)
        content.cancelUpdate() // Disabled cancelling button must not cancel refresh.
        content.updateIndex()
        text.open()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.worker.refreshCalls, 2)
        XCTAssertEqual(c.worker.textCalls, 1)
        XCTAssertTrue(c.state.summary.textIndexStatisticsKnown)
        XCTAssertNil(c.state.errorMessage)
        XCTAssertEqual(c.state.ocrSync.phase, .cancelled)
        XCTAssertTrue(content.canUpdate)
    }

    func testFailureNeedsExplicitRetryAndRenderingCompletedStateDoesNotRepeatWork() async throws {
        let c = try await context(savedEnabled: true)
        c.worker.failNextText = true
        let content = PhotoTextIndexContent(state: c.state)
        content.updateIndex()
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.state.ocrSync.phase, .failed)
        XCTAssertEqual(content.updateTitle, "重试文字索引")
        XCTAssertTrue(content.canUpdate)
        let host = try ControlsNativeHost(content: AnyView(LibraryTextIndexView(state: c.state)))
        defer { host.close() }
        try await host.settle()
        c.state.refresh()
        await c.state.waitUntilIdle()
        try await host.settle()
        XCTAssertEqual(c.worker.textCalls, 1, "Mount and refreshed readiness do not retry")
        content.updateIndex()
        await c.state.waitUntilIdle()
        try await host.settle()
        XCTAssertEqual(c.state.ocrSync.phase, .completed)
        XCTAssertEqual(content.updateTitle, "更新文字索引")
        XCTAssertEqual(c.worker.textCalls, 2)
        _ = try host.capture()
        XCTAssertEqual(c.worker.textCalls, 2)
    }

    func testOffOnDuringDrainShowsNewWaitingIntentWithoutOfferingPrematureRetry() async throws {
        let c = try await context()
        c.state.enterBackground()
        c.state.textSearchEnabled = true
        c.state.ocrSync.updateAvailability(ready: true)
        let old = try XCTUnwrap(c.state.ocrSync.takeReadyRequest())
        c.state.textSearchEnabled = false
        c.state.textSearchEnabled = true
        let content = PhotoTextIndexContent(state: c.state)
        XCTAssertEqual(c.state.ocrSync.phase, .cancelling)
        XCTAssertTrue(c.state.ocrSync.pending)
        XCTAssertTrue(content.hasStopAction)
        XCTAssertFalse(c.state.ocrSync.canCancel)
        XCTAssertFalse(content.canUpdate)
        XCTAssertTrue(status(c.state).detail.contains("再次开启请求的一次更新仍在等待"))
        content.updateIndex()
        c.state.ocrSync.finish(token: old, completion: .cancelled)
        XCTAssertEqual(c.state.ocrSync.phase, .waiting)
        XCTAssertTrue(c.state.ocrSync.canCancel)
        XCTAssertFalse(content.canUpdate)
        content.cancelUpdate()
        XCTAssertFalse(c.state.ocrSync.pending)
        XCTAssertEqual(c.state.ocrSync.phase, .cancelled)
        XCTAssertEqual(c.worker.textCalls, 0)
    }

    func testChildOnlyPublicationsUpdateSameMountedSectionAcrossEveryLiveStage() async throws {
        let c = try await context()
        c.state.enterBackground() // Toggle remains waiting; no worker is admitted.
        c.state.textSearchEnabled = true
        let host = try ControlsNativeHost(content: AnyView(OCRLibrarySectionFixture(state: c.state)))
        defer { host.close() }
        try await host.wait { !controlsDescendants(host.controller.view, UICollectionView.self).isEmpty }
        let mountedView = host.controller.view
        let form = try XCTUnwrap(controlsDescendants(host.controller.view, UICollectionView.self).first)
        XCTAssertEqual(form.numberOfItems(inSection: 0), 4)
        let waiting = try XCTUnwrap(host.capture().pngData())
        var parentPublications = 0
        let observation = c.state.objectWillChange.sink { parentPublications += 1 }
        defer { observation.cancel() }
        // Presentation-only fixture: drive the child protocol, not a real
        // admission while backgrounded. AppState and its progress stay unchanged.
        c.state.ocrSync.updateAvailability(ready: true)
        let token = try XCTUnwrap(c.state.ocrSync.takeReadyRequest())
        try await host.settle()
        let checking = try XCTUnwrap(host.capture().pngData())
        XCTAssertNotEqual(checking, waiting)
        XCTAssertEqual(form.numberOfItems(inSection: 0), 4)
        c.state.ocrSync.accept(.init(total: 8, completed: 3), token: token)
        try await host.settle()
        let updating = try XCTUnwrap(host.capture().pngData())
        XCTAssertNotEqual(updating, checking)
        XCTAssertEqual(form.numberOfItems(inSection: 0), 5,
                   "The containing section, not only its status label, must react to child progress")
        PhotoTextIndexContent(state: c.state).cancelUpdate()
        try await host.settle()
        let cancelling = try XCTUnwrap(host.capture().pngData())
        XCTAssertNotEqual(cancelling, updating)
        XCTAssertTrue(c.state.ocrSync.currentRunning)
        c.state.ocrSync.finish(token: token, completion: .cancelled)
        try await host.settle()
        XCTAssertNotEqual(try XCTUnwrap(host.capture().pngData()), cancelling)
        XCTAssertEqual(parentPublications, 0, "Rendering must be invalidated by the child, not AppState")
        XCTAssertTrue(host.controller.view === mountedView, "No replacement of the hosting root between stages")
        XCTAssertNil(c.state.activity)
        XCTAssertEqual(c.state.textIndexProgress, TextIndexProgress())
        XCTAssertEqual(c.worker.textCalls, 0)
    }

    func testLibraryLandingStatusObservesChildWithoutParentPublication() async throws {
        let c = try await context()
        c.state.enterBackground()
        let host = try ControlsNativeHost(content: AnyView(LibrarySheet(state: c.state)))
        defer { host.close() }
        try await host.wait { !controlsDescendants(host.controller.view, UICollectionView.self).isEmpty }
        let idle = try XCTUnwrap(host.capture().pngData())
        var parentPublications = 0
        let observation = c.state.objectWillChange.sink { parentPublications += 1 }
        defer { observation.cancel() }
        c.state.ocrSync.userChangedEnabled(true) // Child-only synthetic intent.
        try await host.settle()
        XCTAssertNotEqual(try XCTUnwrap(host.capture().pngData()), idle)
        XCTAssertEqual(parentPublications, 0)
        XCTAssertEqual(c.worker.textCalls, 0)
        c.state.cancelOCRSync()
    }

    func testRestoredOnLibraryRoutesAndPrivacyNeverCreateIntent() async throws {
        let c = try await context(savedEnabled: true)
        let views: [AnyView] = [
            AnyView(LibrarySheet(state: c.state)),
            AnyView(LibrarySheet(state: c.state, path: .constant([.textIndex]))),
            AnyView(PrivacySettingsView(state: c.state))
        ]
        for view in views {
            let host = try ControlsNativeHost(content: view)
            defer { host.close() }
            try await host.settle()
            XCTAssertEqual(c.state.ocrSync.phase, .idle)
            XCTAssertFalse(c.state.ocrSync.pending)
            XCTAssertFalse(c.state.ocrSync.currentRunning)
            XCTAssertTrue(PhotoTextIndexContent(state: c.state).canUpdate)
            XCTAssertEqual(c.worker.textCalls, 0)
            XCTAssertEqual(c.worker.imageCalls, 0)
        }
        XCTAssertEqual(LibrarySheet.Route.textIndex.accessibilityIdentifier, "library-text-index")
        XCTAssertTrue(PhotoTextIndexSection.triggerExplanation.contains("从关闭切换为开启"))
        XCTAssertTrue(PhotoTextIndexSection.triggerExplanation.contains("恢复已保存的开启状态"))
        XCTAssertTrue(LibrarySheet.manualIndexExplanation.contains("恢复已保存的开启状态不会自动运行"))
        XCTAssertFalse(LibrarySheet.manualIndexExplanation.contains("仍需单独手动建立"))
        XCTAssertTrue(PrivacySettingsView.ocrExplanation.contains("取消等待或正在进行"))
        XCTAssertTrue(PrivacySettingsView.ocrExplanation.contains("已完成的文字记录保留"))
        XCTAssertTrue(PrivacySettingsView.cloudExplanation.contains("即使全局开关关闭"))
        XCTAssertTrue(PrivacySettingsView.cloudExplanation.contains("仅为该照片"))
        XCTAssertFalse(c.state.allowICloudDownload)
    }

    func testCoveredFooterStaysBlankAndDoesNotOverlapLibraryFormDuringQueuedAndRunningOCR() async throws {
        let c = try await context()
        c.state.enterBackground()
        let host = try ControlsNativeHost(content: AnyView(OCRLibraryCoveredFooterFixture(state: c.state)))
        defer { host.close() }
        try await host.wait { !controlsDescendants(host.controller.view, UICollectionView.self).isEmpty }
        let probe = try XCTUnwrap(controlsDescendants(host.controller.view, UIView.self).first {
            $0.accessibilityIdentifier == "test-ocr-library-footer-region"
        })
        let frame = probe.convert(probe.bounds, to: host.window)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertEqual(frame.height, 52, accuracy: host.pixel)
        let baseline = try footerPixels(host, probe: probe)
        c.state.textSearchEnabled = true
        try await host.settle()
        XCTAssertEqual(c.state.ocrSync.phase, .waiting)
        XCTAssertTrue(IndexSyncFooter(state: c.state).showsOCR)
        XCTAssertEqual(try footerPixels(host, probe: probe), baseline)
        c.state.ocrSync.updateAvailability(ready: true)
        let token = try XCTUnwrap(c.state.ocrSync.takeReadyRequest())
        c.state.ocrSync.accept(.init(total: 8, completed: 3), token: token)
        try await host.settle()
        XCTAssertEqual(try footerPixels(host, probe: probe), baseline,
                       "Covered shared reservation must not render either capsule over the library")
        XCTAssertEqual(probe.convert(probe.bounds, to: host.window), frame)
        let form = try XCTUnwrap(controlsDescendants(host.controller.view, UICollectionView.self).first)
        let usable = form.convert(form.bounds.inset(by: form.adjustedContentInset), to: host.window)
        XCTAssertLessThanOrEqual(usable.maxY, frame.minY + host.pixel)
        XCTAssertEqual(c.worker.textCalls, 0)
        c.state.cancelOCRSync()
        c.state.ocrSync.finish(token: token, completion: .cancelled)
    }

    private func status(_ state: AppState) -> PhotoTextIndexStatusView {
        PhotoTextIndexStatusView(sync: state.ocrSync)
    }

    private func reached(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Synthetic worker did not reach its explicit hold")
            throw OCRLibraryFailure.unexpectedWork
        }
    }

    private func footerPixels(_ host: ControlsNativeHost, probe: UIView) throws -> Data {
        let image = try host.capture()
        let rect = probe.convert(probe.bounds, to: host.controller.view)
        let pixelRect = CGRect(x: (rect.minX * image.scale).rounded(), y: (rect.minY * image.scale).rounded(),
                               width: (rect.width * image.scale).rounded(), height: (rect.height * image.scale).rounded())
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: pixelRect))
        return try XCTUnwrap(UIImage(cgImage: crop).pngData())
    }

    private func context(savedEnabled: Bool = false, photo: OCRLibraryPhotoService? = nil) async throws -> OCRLibraryContext {
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unreadable Photos host; tests do not revoke or request permissions")
            throw OCRLibraryFailure.unexpectedWork
        }
        let suite = "OCRLibraryPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(savedEnabled, forKey: "photoTextSearchEnabled.v1")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let worker = OCRLibraryWorker()
        let state = AppState(worker: worker, authorizationStatus: { .authorized },
                             textSearchPreferences: defaults, syncService: photo)
        addTeardownBlock { @MainActor in
            state.enterBackground()
            worker.imageGate?.open()
            worker.textGate?.open()
            photo?.gate.open()
            await state.waitUntilIdle()
            await state.waitForSync()
            XCTAssertEqual(worker.unexpectedCalls, 0)
            XCTAssertFalse(PhotoLibraryClient.canRead)
        }
        state.refresh()
        await state.waitUntilIdle()
        XCTAssertEqual(worker.textCalls, 0)
        return OCRLibraryContext(state: state, worker: worker)
    }
}

@MainActor
private struct OCRLibrarySectionFixture: View {
    let state: AppState // Intentionally no observation or .id-driven remount.
    var body: some View {
        NavigationStack { Form { PhotoTextIndexSection(state: state) } }
    }
}

@MainActor
private struct OCRLibraryCoveredFooterFixture: View {
    let state: AppState
    var body: some View {
        VStack(spacing: 0) {
            LibraryTextIndexView(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            IndexSyncFooter(state: state, isPresented: false)
                .background(OCRLibraryFooterProbe())
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(IQStyle.background)
    }
}

private struct OCRLibraryFooterProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = "test-ocr-library-footer-region"
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { }
}

@MainActor
private struct OCRLibraryContext {
    let state: AppState
    let worker: OCRLibraryWorker
}

private enum OCRLibraryFailure: Error { case expectedTextFailure, unexpectedWork }

@MainActor
private final class OCRLibraryGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class OCRLibraryWorker: PhotoWorkServicing {
    let summary = LibrarySummary(indexedCount: 8, modelVersion: "TEST-ocr-library",
                                 textIndexCounts: .init(records: 4, withText: 2), textIndexStatisticsKnown: true)
    var imageGate: OCRLibraryGate?
    var textGate: OCRLibraryGate?
    let imageEntered = XCTestExpectation(description: "Manual image worker entered")
    let textEntered = XCTestExpectation(description: "OCR worker entered")
    private(set) var textProgress: (@Sendable (TextIndexProgress) async -> Void)?
    private(set) var refreshCalls = 0
    private(set) var imageCalls = 0
    private(set) var textCalls = 0
    private(set) var imageWasCancelled = false
    private(set) var textWasCancelled = false
    private(set) var unexpectedCalls = 0
    var failNextText = false

    func refresh() async throws -> LibrarySummary { refreshCalls += 1; return summary }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        imageCalls += 1
        XCTAssertFalse(networkAllowed)
        imageEntered.fulfill()
        await imageGate?.wait()
        imageWasCancelled = Task.isCancelled
        try Task.checkCancellation()
        return summary
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        textCalls += 1
        XCTAssertFalse(networkAllowed)
        textProgress = progress
        if textCalls == 1 { textEntered.fulfill() }
        await textGate?.wait()
        textWasCancelled = Task.isCancelled
        try Task.checkCancellation()
        if failNextText { failNextText = false; throw OCRLibraryFailure.expectedTextFailure }
        return summary
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        unexpectedCalls += 1; XCTFail("Library presentation cannot search")
        throw OCRLibraryFailure.unexpectedWork
    }
    func clear() async throws -> LibrarySummary {
        unexpectedCalls += 1; XCTFail("Library presentation cannot clear storage")
        throw OCRLibraryFailure.unexpectedWork
    }
}

@MainActor
private final class OCRLibraryPhotoService: PhotoSyncServicing {
    let gate = OCRLibraryGate()
    let entered = XCTestExpectation(description: "Automatic photo sync is held")
    private(set) var calls = 0
    private(set) var wasCancelled = false
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        calls += 1
        XCTAssertFalse(networkAllowed)
        let value = PhotoSyncProgress(phase: .updating, total: 8, completed: 8, encoded: 8)
        await progress(value)
        entered.fulfill()
        await gate.wait()
        wasCancelled = Task.isCancelled
        try Task.checkCancellation()
        return PhotoSyncResult(summary: LibrarySummary(indexedCount: 8, modelVersion: "TEST-ocr-library"), progress: value)
    }
}