import XCTest
import SwiftUI
import UIKit
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic state/host layout only. No timer, rendering side effect, Photos
/// enumeration, recognition or model invocation is needed for these fixtures.
@MainActor
final class OCRSyncPresentationTests: XCTestCase {
    func testTitlesAndFractionReflectActualStagesAndNotClockTime() throws {
        let state = OCRSyncState()
        let view = toast(state)
        state.userChangedEnabled(true)
        XCTAssertEqual(view.compactTitle, "文字索引等待更新")
        XCTAssertNil(state.fraction)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        XCTAssertEqual(view.compactTitle, "正在检查文字索引")
        XCTAssertNil(state.fraction)
        state.accept(.init(total: 38, completed: 12, recognized: 4, reused: 8), token: run)
        XCTAssertEqual(view.compactTitle, "更新文字索引12/38")
        XCTAssertEqual(state.fraction, Double(12) / 38)
        state.cancel()
        XCTAssertEqual(view.compactTitle, "正在取消文字更新")
        XCTAssertNil(state.fraction)
        state.finish(token: run, completion: .cancelled)
        XCTAssertEqual(view.compactTitle, "文字更新已取消")
        XCTAssertTrue(view.detail.contains("不会自动重试"))
    }

    func testCompletedAndPartialFailureAreDistinctAndDoNotHaveProgressRings() throws {
        for failed in [false, true] {
            let state = OCRSyncState()
            state.userChangedEnabled(true)
            state.updateAvailability(ready: true)
            let run = try XCTUnwrap(state.takeReadyRequest())
            state.accept(.init(total: 4, completed: 4, recognized: failed ? 3 : 4, failed: failed ? 1 : 0), token: run)
            state.finish(token: run, completion: .completed)
            XCTAssertEqual(toast(state).compactTitle, failed ? "文字索引未完成" : "文字索引已更新")
            XCTAssertNil(state.fraction)
            XCTAssertTrue(state.canRetry)
        }
    }

    func testRenderingRestoredOnNeverCreatesARequest() {
        let state = OCRSyncState(enabled: true)
        for presented in [true, false, true] {
            let host = UIHostingController(rootView: toast(state, presented: presented))
            _ = host.sizeThatFits(in: CGSize(width: 393, height: 852))
            XCTAssertEqual(state.phase, .idle)
            XCTAssertFalse(state.pending)
            XCTAssertFalse(state.currentRunning)
        }
    }

    func testIdleWaitingUpdatingAndCoveredReserveSameCompactHeightAsPhotoToast() throws {
        let state = OCRSyncState()
        let baseline = height(PhotoSyncToast(state: PhotoSyncState()))
        XCTAssertEqual(height(toast(state)), baseline, accuracy: 0.001)
        state.userChangedEnabled(true)
        XCTAssertEqual(height(toast(state)), baseline, accuracy: 0.001)
        state.updateAvailability(ready: true)
        let run = try XCTUnwrap(state.takeReadyRequest())
        state.accept(.init(total: 38, completed: 12), token: run)
        XCTAssertEqual(height(toast(state)), baseline, accuracy: 0.001)
        XCTAssertEqual(height(toast(state, presented: false)), baseline, accuracy: 0.001)
        state.cancel()
        XCTAssertEqual(height(toast(state)), baseline, accuracy: 0.001)
        state.finish(token: run, completion: .cancelled)
        XCTAssertEqual(height(toast(state)), baseline, accuracy: 0.001)
    }

    func testSharedFooterReservesOneRegionNotTwoAndPresentationDoesNotRunWorkers() {
        let worker = OCRFooterNoWorkService()
        let state = AppState(worker: worker, authorizationStatus: { .notDetermined })
        let baseline = height(PhotoSyncToast(state: state.photoSync))
        XCTAssertEqual(height(IndexSyncFooter(state: state)), baseline, accuracy: 0.001)
        state.textSearchEnabled = true // Unreadable synthetic state queues, never runs.
        let footer = IndexSyncFooter(state: state)
        XCTAssertTrue(footer.showsOCR)
        XCTAssertEqual(height(footer), baseline, accuracy: 0.001)
        XCTAssertEqual(height(IndexSyncFooter(state: state, isPresented: false)), baseline, accuracy: 0.001)
        XCTAssertTrue(state.ocrSync.pending)
        XCTAssertFalse(state.ocrSync.currentRunning)
        XCTAssertNil(state.activity)
        state.cancelOCRSync()
    }

    private func toast(_ state: OCRSyncState, presented: Bool = true) -> OCRSyncToast {
        OCRSyncToast(state: state, isPresented: presented,
                     cancel: { state.cancel() }, retry: { state.requestUpdate() })
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = UIHostingController(rootView: view.dynamicTypeSize(.large))
        return host.sizeThatFits(in: CGSize(width: 393, height: 852)).height
    }
}

private struct OCRFooterNoWorkService: PhotoWorkServicing {
    func refresh() async throws -> LibrarySummary {
        XCTFail("Rendering cannot refresh")
        return LibrarySummary()
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        XCTFail("Rendering cannot index images")
        return LibrarySummary()
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        XCTFail("Rendering cannot search")
        return SearchResponse(summary: LibrarySummary(), hits: [])
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        XCTFail("Rendering cannot recognize text")
        return LibrarySummary()
    }
    func clear() async throws -> LibrarySummary {
        XCTFail("Rendering cannot clear storage")
        return LibrarySummary()
    }
}