import Foundation
import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Six controller tests and two hosted presentation tests. All scan data and
/// validators are synthetic: no SQL, models, photo reads, or deletion calls.
/// These are regression contracts, not evidence of the reported phone freeze's
/// cause, nor an end-to-end tap on ContentView's cleanup entry button.
@MainActor
final class SimilarCleanupPublicationStateTests: XCTestCase {
    func testBlockedSynchronousValidationLeavesMainActorResponsiveThenPublishesLegacyResult() async throws {
        let gate = CleanupPublicationGate(blocked: true)
        // Deliberately omit the epoch closure, as legacy fixtures do. Its default
        // must not rerun the synchronous access validator on MainActor.
        let f = fixture([CleanupPublicationPlan(gate: gate, stale: 2, unindexed: 4)])
        XCTAssertFalse(f.state.isValidating)
        f.state.scan()
        try await entered(gate)
        assertValidating(f.state)
        XCTAssertEqual(f.state.progress, SimilarPhotoGroupingProgress(total: 39, completed: 39, groupCount: 1))
        XCTAssertEqual(gate.trace.accessThreads, [false])
        try await heartbeat { self.assertValidating(f.state); XCTAssertFalse(gate.isReleased) }

        gate.release()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertEqual(f.state.groups.map(\.id), ["TEST-publication-old"])
        XCTAssertEqual(f.state.candidateCount, 39)
        XCTAssertEqual(f.state.staleCount, 2)
        XCTAssertEqual(f.state.unindexedCount, 4)
        XCTAssertNil(f.state.message)
        XCTAssertEqual(gate.trace.accessThreads, [false], "The default cheap fence must not repeat validation")
        XCTAssertEqual(gate.trace.successfulReturnsCancelled, [false])
        XCTAssertTrue(gate.trace.epochThreads.isEmpty)
        XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
    }

    func testThresholdInvalidatesImmediatelyWhileIdleWaiterStillDrainsLateValidationSuccess() async throws {
        let gate = CleanupPublicationGate(blocked: true)
        let f = fixture([CleanupPublicationPlan(gate: gate, checksEpoch: true)])
        f.state.scan()
        try await entered(gate)
        f.state.threshold = 0.75
        assertUnpublished(f.state)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertFalse(gate.isReleased, "Invalidation must finish without waiting for the blocked validator")

        let joining = expectation(description: "Idle waiter joined the cancelled validation")
        var drained = false
        let waiter = Task { @MainActor in
            joining.fulfill()
            await f.state.waitUntilIdle()
            drained = true
        }
        try await require(joining)
        try await heartbeat {
            XCTAssertFalse(drained)
            XCTAssertFalse(gate.isReleased)
            self.assertUnpublished(f.state)
        }
        XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold], "Changing the slider never starts a replacement")
        gate.release() // Uncooperative sync validation returns SUCCESS, not cancellation.
        await waiter.value
        XCTAssertTrue(drained)
        XCTAssertEqual(gate.trace.successfulReturnsCancelled, [true])
        XCTAssertTrue(gate.trace.epochThreads.isEmpty, "Cancelled work must not reach the publication fence")
        assertUnpublished(f.state)
        XCTAssertEqual(f.state.threshold, 0.75)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertNil(f.state.message)
    }

    func testNewExplicitScanDrainsPredecessorValidationBeforeEnteringReplacementService() async throws {
        let old = CleanupPublicationGate(blocked: true)
        let next = CleanupPublicationGate(blocked: true)
        let f = fixture([
            CleanupPublicationPlan(gate: old, checksEpoch: true),
            CleanupPublicationPlan(gate: next, groups: cleanupPublicationGroups("fresh"), checksEpoch: true)
        ])
        f.state.scan()
        try await entered(old)
        f.state.threshold = 0.75
        f.state.scan()
        try await heartbeat {
            XCTAssertTrue(f.state.isGrouping)
            XCTAssertFalse(f.state.isValidating, "A queued replacement has not begun validation")
            self.assertUnpublished(f.state)
            XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
        }
        old.release()
        try await entered(next)
        XCTAssertEqual(old.trace.successfulReturnsCancelled, [true])
        XCTAssertTrue(old.trace.epochThreads.isEmpty)
        XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold, 0.75])
        XCTAssertEqual(f.grouping.predecessorsReturnedAtEntry, [true, true],
                       "Checked in the service itself, not inferred from task scheduling order")
        assertValidating(f.state)
        XCTAssertNil(f.state.message)
        next.release()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.state.groups.map(\.id), ["TEST-publication-fresh"])
        XCTAssertEqual(f.state.threshold, 0.75)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertEqual(next.trace.accessThreads, [false])
        XCTAssertEqual(next.trace.epochThreads, [true])
        XCTAssertEqual(next.trace.successfulReturnsCancelled, [false])
    }

    func testCheapEpochFenceRejectsSuccessfulAsyncValidationWithoutRepeatingAccessCheck() async {
        let changedEpoch = CleanupPublicationGate(epochFails: true)
        let f = fixture([CleanupPublicationPlan(gate: changedEpoch, checksEpoch: true)])
        f.state.scan()
        await f.state.waitUntilIdle()
        // This fence ALWAYS throws while validateAccess succeeds. It models an
        // invalid epoch at the final fence; no race to mutate a flag between two
        // executors, and no claim to control that exact scheduling gap.
        XCTAssertEqual(changedEpoch.trace.accessThreads, [false])
        XCTAssertEqual(changedEpoch.trace.successfulReturnsCancelled, [false])
        XCTAssertEqual(changedEpoch.trace.epochThreads, [true])
        XCTAssertEqual(changedEpoch.trace.successesAtEpoch, [1])
        assertUnpublished(f.state)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        assertFailure(f.state, code: .photoAccessChanged, reason: "照片的可访问范围或内容已变化")

        let legacy = CleanupPublicationGate(epochFails: true)
        let control = fixture([CleanupPublicationPlan(gate: legacy)])
        control.state.scan()
        await control.state.waitUntilIdle()
        XCTAssertTrue(control.state.hasScanned, "With no epoch closure supplied, the same access check succeeds")
        XCTAssertEqual(control.state.groups.count, 1)
        XCTAssertFalse(control.state.isValidating)
        XCTAssertNil(control.state.message)
        XCTAssertEqual(legacy.trace.accessThreads, [false])
        XCTAssertTrue(legacy.trace.epochThreads.isEmpty)
    }

    func testValidationFailureKeepsCountsUnknownAndTypedDiagnosticUnlikeSuccessfulEmptyResult() async throws {
        let failed = CleanupPublicationGate(blocked: true, accessFails: true)
        let f = fixture([CleanupPublicationPlan(gate: failed, stale: 2, unindexed: 4, checksEpoch: true)])
        f.state.scan()
        try await entered(failed)
        assertValidating(f.state)
        failed.release()
        await f.state.waitUntilIdle()
        assertUnpublished(f.state)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertEqual(f.state.progress, SimilarPhotoGroupingProgress())
        assertFailure(f.state, code: .unknown, reason: "原因尚未确定")
        XCTAssertFalse(f.state.message?.contains("synthetic-private") ?? true)
        XCTAssertTrue(failed.trace.epochThreads.isEmpty)

        let emptyGate = CleanupPublicationGate()
        let empty = fixture([CleanupPublicationPlan(gate: emptyGate, groups: [])])
        empty.state.scan()
        await empty.state.waitUntilIdle()
        XCTAssertTrue(empty.state.hasScanned, "No groups is a successful answer, not an access failure")
        XCTAssertEqual(empty.state.candidateCount, 39)
        XCTAssertTrue(empty.state.groups.isEmpty)
        XCTAssertEqual(empty.state.staleCount, 0)
        XCTAssertEqual(empty.state.unindexedCount, 0)
        XCTAssertFalse(empty.state.isGrouping)
        XCTAssertFalse(empty.state.isValidating)
        XCTAssertNil(empty.state.message)
        XCTAssertEqual(emptyGate.trace.accessThreads, [false])
    }

    func testBackgroundClearsValidationImmediatelyAndResumeDoesNotPublishLateSuccessOrRescan() async throws {
        let gate = CleanupPublicationGate(blocked: true)
        let f = fixture([CleanupPublicationPlan(gate: gate, checksEpoch: true)])
        f.state.scan()
        try await entered(gate)
        f.state.pause()
        assertUnpublished(f.state)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isValidating)
        f.state.scan() // Background rejects even an explicit request.
        f.state.resume() // Merely permits a future explicit scan.
        try await heartbeat {
            XCTAssertFalse(gate.isReleased)
            XCTAssertFalse(f.state.isValidating)
            XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
        }
        gate.release()
        await f.state.waitUntilIdle()
        XCTAssertEqual(gate.trace.successfulReturnsCancelled, [true])
        XCTAssertTrue(gate.trace.epochThreads.isEmpty)
        assertUnpublished(f.state)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertNil(f.state.message)
        XCTAssertEqual(f.grouping.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
    }

    func testHostedActualSheetStaysPresentedAfterGroupsAndLibraryEpochClearsGroupsWithoutDismissal() async throws {
        let c = try await sheetFixture(empty: false)
        let host = try await mount(c)
        try assertPresented(host, c)
        XCTAssertTrue(c.fixture.grouping.thresholds.isEmpty)
        c.fixture.state.scan()
        try await entered(c.gate)
        try assertPresented(host, c)
        assertValidating(c.fixture.state)
        c.gate.release()
        await c.fixture.state.waitUntilIdle()
        try await settle(host)
        try assertPresented(host, c)
        XCTAssertTrue(c.fixture.state.hasScanned)
        XCTAssertEqual(c.fixture.state.groups.count, 1)
        XCTAssertFalse(c.fixture.state.isValidating)
        XCTAssertEqual(c.fixture.state.candidateCount, 39)
        let grouped = try capture(host)

        let epoch = c.app.photoLibraryEpoch
        c.app.libraryChanged() // The production sheet's onChange must invalidate.
        await c.app.waitUntilIdle()
        try await settle(host)
        XCTAssertNotEqual(c.app.photoLibraryEpoch, epoch)
        assertUnpublished(c.fixture.state)
        XCTAssertFalse(c.fixture.state.isValidating)
        XCTAssertEqual(c.fixture.state.threshold, 0.75)
        try assertPresented(host, c)
        let invalidated = try capture(host)
        XCTAssertNotEqual(try XCTUnwrap(grouped.pngData()), try XCTUnwrap(invalidated.pngData()),
                          "Render the changed real sheet; this is not private SwiftUI AX inspection")
        XCTAssertEqual(c.fixture.grouping.thresholds, [0.75], "Neither publication nor the epoch starts another scan")
        XCTAssertEqual(c.worker.refreshes, 2)
        XCTAssertNil(c.fixture.state.message)
        assertSheetServices(c)
    }

    func testHostedActualEmptySheetRemainsPresentedAndCapturesWideThresholdWarningOnce() async throws {
        let c = try await sheetFixture(empty: true)
        let host = try await mount(c)
        try assertPresented(host, c)
        XCTAssertFalse(c.fixture.state.hasScanned)
        XCTAssertTrue(c.fixture.grouping.thresholds.isEmpty)
        XCTAssertEqual(SimilarPhotoGroupingPolicy.thresholdRange, Float(0.50)...Float(0.99))
        XCTAssertEqual(SimilarPhotoGroupingPolicy.sliderTicks, 50.0...99.0)
        c.fixture.state.scan()
        try await entered(c.gate)
        assertValidating(c.fixture.state)
        try assertPresented(host, c)
        c.gate.release()
        await c.fixture.state.waitUntilIdle()
        try await settle(host)
        try assertPresented(host, c)
        XCTAssertTrue(c.fixture.state.hasScanned)
        XCTAssertTrue(c.fixture.state.groups.isEmpty)
        XCTAssertEqual(c.fixture.state.candidateCount, 39)
        XCTAssertEqual(c.fixture.state.staleCount, 0)
        XCTAssertEqual(c.fixture.state.unindexedCount, 0)
        XCTAssertFalse(c.fixture.state.isValidating)
        XCTAssertNil(c.fixture.state.message)
        XCTAssertEqual(c.fixture.state.threshold, 0.75)
        // The actual production controls render their <0.90 warning and actual
        // empty-result summary. Only this native image is attached for review;
        // no copied warning UI, AX traversal, fake delete, or bottom overlay.
        let attachment = XCTAttachment(image: try capture(host))
        attachment.name = "UIReview-similar-threshold-wide-dark"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await settle(host)
        try assertPresented(host, c)
        XCTAssertEqual(c.fixture.grouping.thresholds, [0.75])
        XCTAssertEqual(c.worker.refreshes, 1)
        assertSheetServices(c)
    }

    // MARK: Deterministic controller fixtures

    private func assertFailure(_ state: SimilarPhotoCleanupState, code: SimilarCleanupDiagnostic.Code, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.failureDiagnostic, SimilarCleanupDiagnostic(phase: .publication, code: code), file: file, line: line)
        XCTAssertNil(state.failureDiagnostic?.nativeCode, file: file, line: line)
        XCTAssertEqual(state.failureOperation, .publication, file: file, line: line)
        XCTAssertTrue(state.message?.hasPrefix("\(code.rawValue) · publication\n") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains(reason) == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("本次未删除照片") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("已有索引未清除") == true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("synthetic-private") ?? true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("metadata detail") ?? true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("照片权限") ?? true, file: file, line: line)
    }

    private func fixture(_ plans: [CleanupPublicationPlan]) -> CleanupPublicationFixture {
        let grouping = CleanupPublicationGrouping(plans: plans)
        let deletion = CleanupPublicationDeletion()
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        addTeardownBlock { @MainActor in
            // Even failed expectations must open every condition before joining.
            plans.forEach { $0.gate.release() }
            state.pause()
            await state.waitUntilIdle()
            XCTAssertFalse(state.isValidating)
            XCTAssertTrue(state.groups.isEmpty)
            XCTAssertEqual(deletion.calls, 0)
        }
        return CleanupPublicationFixture(state: state, grouping: grouping, deletion: deletion)
    }

    private func entered(_ gate: CleanupPublicationGate) async throws { try await require(gate.entered) }

    private func require(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Missing event: \(expectation.expectationDescription)")
            throw CleanupPublicationFailure.expectation
        }
    }

    private func heartbeat(_ inspect: @escaping @MainActor () -> Void) async throws {
        let beat = expectation(description: "MainActor heartbeat while synchronous validation is held")
        let task = Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            inspect()
            beat.fulfill()
        }
        try await require(beat)
        await task.value
    }

    private func assertUnpublished(_ state: SimilarPhotoCleanupState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertEqual(state.candidateCount, 0, file: file, line: line)
        XCTAssertEqual(state.staleCount, 0, file: file, line: line)
        XCTAssertEqual(state.unindexedCount, 0, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertFalse(state.isDeleting, file: file, line: line)
    }

    private func assertValidating(_ state: SimilarPhotoCleanupState,
                                  file: StaticString = #filePath, line: UInt = #line) {
        assertUnpublished(state, file: file, line: line)
        XCTAssertTrue(state.isGrouping, file: file, line: line)
        XCTAssertTrue(state.isValidating, file: file, line: line)
    }

    // MARK: Real SwiftUI sheet / public UIKit presentation, never private AX

    private func sheetFixture(empty: Bool) async throws -> CleanupPublicationSheetContext {
        let permission = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Hosted tests require unauthorized Photos; never request or reset permission")
            throw CleanupPublicationFailure.readablePhotos
        }
        let gate = CleanupPublicationGate(blocked: true)
        let f = fixture([CleanupPublicationPlan(gate: gate, groups: empty ? [] : cleanupPublicationGroups())])
        f.state.threshold = 0.75
        let worker = CleanupPublicationWorker()
        let translator = CleanupPublicationTranslator()
        let app = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        let c = CleanupPublicationSheetContext(fixture: f, gate: gate, app: app,
                                               worker: worker, translator: translator, permission: permission)
        addTeardownBlock { @MainActor in
            gate.release()
            f.state.pause()
            app.enterBackground()
            await f.state.waitUntilIdle()
            await app.waitUntilIdle()
            app.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, permission)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertEqual(f.deletion.calls, 0)
            XCTAssertEqual(worker.unexpectedCalls, 0)
            XCTAssertEqual(translator.calls, 0)
        }
        app.refresh() // Only the fake worker's current-model metadata is used.
        await app.waitUntilIdle()
        XCTAssertTrue(app.canRead)
        XCTAssertTrue(app.modelsReady)
        XCTAssertTrue(app.summary.indexStatisticsKnown)
        XCTAssertEqual(app.summary.indexedCount, 39)
        XCTAssertFalse(app.library.canReadImages, "Real thumbnail requests must stop at permission checking")
        return c
    }

    private func assertSheetServices(_ c: CleanupPublicationSheetContext) {
        XCTAssertEqual(c.fixture.deletion.calls, 0)
        XCTAssertEqual(c.worker.unexpectedCalls, 0)
        XCTAssertEqual(c.translator.calls, 0)
        XCTAssertFalse(PhotoLibraryClient.canRead)
        XCTAssertEqual(PhotoLibraryClient.authorization, c.permission)
        XCTAssertFalse(c.app.allowICloudDownload)
        XCTAssertTrue(c.app.results.isEmpty)
        XCTAssertEqual(c.app.progress, IndexProgress())
        XCTAssertNil(c.app.activity)
        XCTAssertNil(c.app.errorMessage)
        XCTAssertNil(c.app.appleTranslationService)
    }

    private func mount(_ c: CleanupPublicationSheetContext) async throws -> CleanupPublicationHost {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let appeared = expectation(description: "Actual parent.sheet finished appearing")
        let root = CleanupPublicationRoot(context: c, appeared: { appeared.fulfill() })
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.scenePhase, .active)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = CleanupPublicationHost(scene: scene, root: AnyView(root))
        addTeardownBlock { @MainActor in
            c.gate.release()
            c.fixture.state.pause()
            await c.fixture.state.waitUntilIdle()
            await host.close()
        }
        host.window.rootViewController = host.controller
        host.window.makeKeyAndVisible()
        host.layout()
        try await require(appeared)
        host.presented = try XCTUnwrap(host.controller.presentedViewController)
        try await settle(host)
        try assertPresented(host, c)
        return host
    }

    private func assertPresented(_ host: CleanupPublicationHost, _ c: CleanupPublicationSheetContext) throws {
        XCTAssertTrue(c.visible)
        XCTAssertTrue(c.bindingWrites.isEmpty, "Completion/library changes must not toggle the parent's sheet binding")
        let presented = try XCTUnwrap(host.controller.presentedViewController)
        XCTAssertTrue(presented === host.presented, "Retain the same actual UIKit presentation, not a replacement")
        XCTAssertNotNil(presented.presentingViewController)
        XCTAssertTrue(presented.view.window === host.window)
        XCTAssertFalse(presented.isBeingDismissed)
    }

    private func settle(_ host: CleanupPublicationHost) async throws {
        let laidOut = expectation(description: "Pending SwiftUI and UIKit sheet layout completed")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); laidOut.fulfill() }
        }
        try await require(laidOut)
    }

    private func capture(_ host: CleanupPublicationHost) throws -> UIImage {
        let presented = try XCTUnwrap(host.controller.presentedViewController)
        let view = try XCTUnwrap(presented.view)
        XCTAssertFalse(view.bounds.isEmpty)
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew else {
            XCTFail("UIKit could not draw the actual presented cleanup sheet")
            throw CleanupPublicationFailure.drawing
        }
        XCTAssertNotNil(image.cgImage)
        return image
    }
}

fileprivate enum CleanupPublicationFailure: Error { case expectation, readablePhotos, drawing, unexpected, mainThread }

fileprivate func cleanupPublicationGroups(_ suffix: String = "old") -> [SimilarPhotoGroup] {
    var vector = [Float](repeating: 0, count: 768)
    vector[0] = 1
    let photos = ["a", "b"].map { id in
        IndexedPhoto(id: "TEST-publication-\(suffix)-\(id)", modificationTime: 123,
                     modelVersion: "TEST-publication-model", imageEmbedding: vector, creationTime: 100)
    }
    return [SimilarPhotoGroup(id: "TEST-publication-\(suffix)", photos: photos, minimumSimilarity: 1)]
}

/// Intentionally NON-actor. The thread observation is inside the exact sync
/// validateAccess body reached by prepareForPublication, not a test actor hop.
/// NSCondition supplies ordering; no sleeps, deadlines, or cancellation handler
/// make this uncooperative validator return before the test explicitly releases it.
fileprivate final class CleanupPublicationGate: @unchecked Sendable {
    struct Trace {
        var accessThreads: [Bool] = []
        var successfulReturnsCancelled: [Bool] = []
        var epochThreads: [Bool] = []
        var successesAtEpoch: [Int] = []
    }
    let entered = XCTestExpectation(description: "Synchronous publication validator entered")
    private let condition = NSCondition()
    private var released: Bool
    private var recorded = Trace()
    private let accessFails: Bool
    private let epochFails: Bool

    init(blocked: Bool = false, accessFails: Bool = false, epochFails: Bool = false) {
        released = !blocked
        self.accessFails = accessFails
        self.epochFails = epochFails
    }

    var trace: Trace { condition.lock(); defer { condition.unlock() }; return recorded }
    var isReleased: Bool { condition.lock(); defer { condition.unlock() }; return released }

    func validateAccess() throws {
        let main = Thread.isMainThread
        condition.lock()
        recorded.accessThreads.append(main)
        condition.unlock()
        entered.fulfill()
        // A regression to MainActor must FAIL rather than deadlock the test host
        // before it can release the gate or process its expectation timeout.
        guard !main else { throw CleanupPublicationFailure.mainThread }
        condition.lock()
        while !released { condition.wait() }
        if !accessFails {
            recorded.successfulReturnsCancelled.append(withUnsafeCurrentTask { $0?.isCancelled ?? false })
        }
        condition.unlock()
        if accessFails {
            throw NSError(domain: "synthetic-private-publication", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "synthetic-private metadata detail"])
        }
    }

    func validateEpoch() throws {
        condition.lock()
        recorded.epochThreads.append(Thread.isMainThread)
        recorded.successesAtEpoch.append(recorded.successfulReturnsCancelled.count)
        condition.unlock()
        if epochFails { throw PhotoDeletionError.accessChanged }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

fileprivate struct CleanupPublicationPlan: Sendable {
    let gate: CleanupPublicationGate
    var groups: [SimilarPhotoGroup] = cleanupPublicationGroups()
    var stale = 0
    var unindexed = 0
    var checksEpoch = false
}

@MainActor
fileprivate final class CleanupPublicationGrouping: SimilarPhotoGrouping {
    let plans: [CleanupPublicationPlan]
    private(set) var thresholds: [Float] = []
    private(set) var predecessorsReturnedAtEntry: [Bool] = []
    init(plans: [CleanupPublicationPlan]) { self.plans = plans }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        let index = thresholds.count
        thresholds.append(threshold)
        guard plans.indices.contains(index) else {
            XCTFail("Unexpected automatic grouping request")
            throw CleanupPublicationFailure.unexpected
        }
        predecessorsReturnedAtEntry.append(plans.prefix(index).allSatisfy {
            !$0.gate.trace.successfulReturnsCancelled.isEmpty
        })
        let plan = plans[index]
        let gate = plan.gate
        await progress(SimilarPhotoGroupingProgress(total: 39, completed: 39, groupCount: plan.groups.count))
        if plan.checksEpoch {
            return SimilarPhotoGroupingResult(groups: plan.groups, candidateCount: 39,
                staleCount: plan.stale, unindexedCount: plan.unindexed, threshold: threshold,
                validateAccess: { try gate.validateAccess() }, validatePublicationEpoch: { try gate.validateEpoch() })
        }
        return SimilarPhotoGroupingResult(groups: plan.groups, candidateCount: 39,
            staleCount: plan.stale, unindexedCount: plan.unindexed, threshold: threshold,
            validateAccess: { try gate.validateAccess() })
    }
}

@MainActor
fileprivate final class CleanupPublicationDeletion: PhotoDeleting {
    private(set) var calls = 0
    func delete(revisions: [PhotoRevision]) async throws {
        calls += 1
        XCTFail("These tests must not submit even a fake deletion")
        throw CleanupPublicationFailure.unexpected
    }
}

@MainActor
fileprivate struct CleanupPublicationFixture {
    let state: SimilarPhotoCleanupState
    let grouping: CleanupPublicationGrouping
    let deletion: CleanupPublicationDeletion
}

@MainActor
fileprivate final class CleanupPublicationSheetContext: ObservableObject {
    @Published var visible = true
    private(set) var bindingWrites: [Bool] = []
    let fixture: CleanupPublicationFixture
    let gate: CleanupPublicationGate
    let app: AppState
    let worker: CleanupPublicationWorker
    let translator: CleanupPublicationTranslator
    let permission: PHAuthorizationStatus

    init(fixture: CleanupPublicationFixture, gate: CleanupPublicationGate, app: AppState,
         worker: CleanupPublicationWorker, translator: CleanupPublicationTranslator, permission: PHAuthorizationStatus) {
        self.fixture = fixture; self.gate = gate; self.app = app
        self.worker = worker; self.translator = translator; self.permission = permission
    }

    var presentation: Binding<Bool> {
        Binding(get: { self.visible }, set: { self.bindingWrites.append($0); self.visible = $0 })
    }
}

@MainActor
fileprivate struct CleanupPublicationRoot: View {
    @ObservedObject var context: CleanupPublicationSheetContext
    let appeared: () -> Void
    var body: some View {
        NavigationStack {
            Text("TEST presentation parent — no homepage entry tap")
        }
        .sheet(isPresented: context.presentation) {
            VStack(spacing: 0) {
                Text("TEST FIXTURE · synthetic metadata · no Photos")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white).padding(.vertical, 6)
                    .frame(maxWidth: .infinity).background(Color.black)
                SimilarPhotoCleanupSheet(state: context.fixture.state, appState: context.app)
            }
            .environment(\.scenePhase, .active)
            .preferredColorScheme(.dark)
            .background(CleanupPublicationAppearance(appeared: appeared))
        }
    }
}

/// Public UIViewController lifecycle signals presentation completion, instead of
/// guessing an animation duration or searching SwiftUI's internal AX hierarchy.
@MainActor
fileprivate struct CleanupPublicationAppearance: UIViewControllerRepresentable {
    let appeared: () -> Void
    func makeUIViewController(context: Context) -> CleanupPublicationAppearanceController {
        CleanupPublicationAppearanceController(appeared: appeared)
    }
    func updateUIViewController(_ uiViewController: CleanupPublicationAppearanceController, context: Context) {}
}

@MainActor
fileprivate final class CleanupPublicationAppearanceController: UIViewController {
    private var appeared: (() -> Void)?
    init(appeared: @escaping () -> Void) { self.appeared = appeared; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("Test controller has no storyboard") }
    override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = appeared
        appeared = nil
        callback?()
    }
}

@MainActor
fileprivate final class CleanupPublicationHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    var presented: UIViewController? // Pin the actual controller through publication/invalidation.
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, root: AnyView) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = UIHostingController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        presented?.view.setNeedsLayout(); presented?.view.layoutIfNeeded()
    }
    func close() async {
        if controller.presentedViewController != nil {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: false) { continuation.resume() }
            }
        }
        presented = nil
        controller.rootView = AnyView(EmptyView())
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}

@MainActor
fileprivate final class CleanupPublicationWorker: PhotoWorkServicing {
    private(set) var refreshes = 0
    private(set) var unexpectedCalls = 0
    func refresh() async throws -> LibrarySummary {
        refreshes += 1
        return LibrarySummary(indexedCount: 39, modelVersion: "TEST-publication-model")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> CleanupPublicationFailure {
        unexpectedCalls += 1
        XCTFail("Publication presentation must not index, search, or clear storage")
        return .unexpected
    }
}

@MainActor
fileprivate final class CleanupPublicationTranslator: QueryTranslating {
    let isSupported = false
    private(set) var calls = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        calls += 1; XCTFail("Cleanup must not check translation availability"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        calls += 1; XCTFail("Cleanup must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        calls += 1; XCTFail("Cleanup must not prepare translation"); throw QueryTranslationFailure.unsupported
    }
}