import XCTest
import Foundation
import SwiftUI
import UIKit
import CoreGraphics
@testable import LocalImageIQ

/// State contracts and exactly four small native review attachments, not pixel
/// baselines or XCUI interaction tests. Only the injected service and procedural
/// RGBA pixels are used: no PhotoLibraryClient/AppState, authorization queries,
/// asset fetches, model, database, file reads or network-capable service.
/// LocalPreviewComparisonPixels is private in the production sheet, so its
/// uprightSize/orientation/fittedRect helpers cannot be unit-tested here. Do not
/// copy their implementation into this target and call that production coverage.
@MainActor
final class LocalPreviewComparisonPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let compactPhone = CGSize(width: 375, height: 667)

    // MARK: Explicit start and duplicate suppression

    func testSheetInitialTaskAutostartsIdleInjectedStateExactlyOnceWithoutCapture() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let started = expectation(description: "The real sheet's initial task starts the injected fake")
        let (state, service) = makeState([.init(.success(report), held: true, started: started)])
        assertEmpty(state)
        XCTAssertTrue(service.observations.requests.isEmpty)
        // No explicit start here and no fifth attachment. This hosts the actual
        // .task lifecycle; it does not claim to tap the Start/Retry control.
        try await snapshot(LocalPreviewComparisonSheet(state: state), id: "autostart-no-capture",
                           size: phone, capture: false, afterLayout: { [state, service] in
            await self.fulfillment(of: [started], timeout: 3)
            XCTAssertTrue(state.isRunning)
            XCTAssertNil(state.result)
            XCTAssertEqual(service.observations.requests, [report.photoID])
            service.release(0)
            await state.waitUntilIdle()
        }) { [state, service, report] in
            try self.assertPreloadedFixture(state, service: service, report: report)
        }
        state.cancelAndClear()
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.observations.requests, [report.photoID])
        XCTAssertEqual(service.observations.unplannedCalls, 0)
    }

    func testStateStartsIdleAndExplicitStartPublishesExactlyThreeEntries() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let started = expectation(description: "Explicit start reaches the fake latch")
        let (state, service) = makeState([.init(.success(report), held: true, started: started)])
        assertEmpty(state)
        XCTAssertTrue(service.observations.requests.isEmpty, "Initialization itself must not start work")

        state.start() // The sheet's initial .task uses this same explicit state API.
        XCTAssertTrue(state.isRunning)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(state.result, "A held comparison must not publish partial entries")
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(service.observations.requests, [LocalPreviewPresentationFixtures.photoID])
        service.release(0)
        await state.waitUntilIdle()

        try assertReport(state, equals: report)
        let observed = service.observations
        XCTAssertEqual(observed.successes, 1)
        XCTAssertEqual(observed.failures, 0)
        XCTAssertEqual(observed.finished, 1)
        XCTAssertEqual(observed.currentPhotoIDs, [report.photoID])
        XCTAssertEqual(observed.currentRevisionIDs, [report.revision.id])
        XCTAssertEqual(observed.peakActive, 1)
        XCTAssertEqual(observed.pending, 0)
    }

    func testDuplicateStartWhileHeldDoesNotCancelOrEnqueue() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let started = expectation(description: "Original comparison is held")
        let (state, service) = makeState([.init(.success(report), held: true, started: started)])
        state.start()
        await fulfillment(of: [started], timeout: 3)
        state.start()
        state.start()
        XCTAssertTrue(state.isRunning)
        XCTAssertEqual(service.observations.requests.count, 1)
        XCTAssertEqual(service.observations.cancellations, 0)
        service.release(0)
        await state.waitUntilIdle()

        try assertReport(state, equals: report)
        let observed = service.observations
        XCTAssertEqual(observed.requests, [report.photoID], "Duplicates must not be queued for later either")
        XCTAssertEqual(observed.finished, 1)
        XCTAssertEqual(observed.cancellations, 0)
        XCTAssertEqual(observed.unplannedCalls, 0)
        XCTAssertEqual(observed.events, ["begin.0", "release.0", "end.0"])
    }

    // MARK: Clearing, cancellation and predecessor drain

    func testCancelClearsCompletedComparisonWithoutAnotherRequest() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let (state, service) = makeState([.init(.success(report))])
        state.start()
        await state.waitUntilIdle()
        try assertReport(state, equals: report)
        state.cancelAndClear()
        state.cancelAndClear()
        assertEmpty(state)
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.observations.requests, [report.photoID])
        XCTAssertEqual(service.observations.currentPhotoIDs.count, 1)
    }

    func testCancelRejectsLateSuccess() async throws {
        try await assertCancelledOutcomeIsDiscarded(failure: false)
    }

    func testCancelRejectsLateFailure() async throws {
        try await assertCancelledOutcomeIsDiscarded(failure: true)
    }

    func testRestartAwaitsCancelledSuccessPredecessorDrain() async throws {
        try await assertRestartWaitsForDrain(failure: false)
    }

    func testRestartAwaitsCancelledFailurePredecessorDrain() async throws {
        try await assertRestartWaitsForDrain(failure: true)
    }

    func testRestartClearsOldResultUntilReplacementCompletes() async throws {
        let first = try LocalPreviewPresentationFixtures.comparison()
        let second = try LocalPreviewPresentationFixtures.comparison(available: false)
        let started = expectation(description: "Replacement result is held")
        let (state, service) = makeState([.init(.success(first)),
                                         .init(.success(second), held: true, started: started)])
        state.start()
        await state.waitUntilIdle()
        try assertReport(state, equals: first)
        state.start()
        XCTAssertTrue(state.isRunning)
        XCTAssertNil(state.result)
        XCTAssertNil(state.errorMessage)
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(state.result)
        service.release(1)
        await state.waitUntilIdle()
        try assertReport(state, equals: second)
        XCTAssertEqual(service.observations.requests, [first.photoID, second.photoID])
        XCTAssertEqual(service.observations.peakActive, 1)
    }

    // MARK: Publication validation and private-error redaction

    func testIsCurrentFalseRejectsSnapshotRevokedWhileAwaitingResult() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let started = expectation(description: "Snapshot is held before revocation")
        let (state, service) = makeState([.init(.success(report), held: true, started: started)])
        state.start()
        await fulfillment(of: [started], timeout: 3)
        service.setCurrent(false) // A fake validity bit, not a Photos permission change.
        service.release(0)
        await state.waitUntilIdle()
        XCTAssertNil(state.result)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.errorMessage, LocalPreviewPresentationFixtures.changedMessage)
        XCTAssertEqual(service.observations.currentPhotoIDs, [report.photoID])
        XCTAssertEqual(service.observations.currentRevisionIDs, [report.revision.id])
        XCTAssertEqual(service.observations.successes, 1, "The service really returned the now-revoked result")
    }

    func testWrongPhotoIDIsRejectedEvenWhenServiceWouldValidateIt() async throws {
        let valid = try LocalPreviewPresentationFixtures.comparison()
        let wrong = LocalPreviewComparison(photoID: LocalPreviewPresentationFixtures.otherID,
                                           revision: valid.revision,
                                           authorizationRawValue: valid.authorizationRawValue,
                                           entries: valid.entries)
        await assertWrongIdentityRejected(wrong)
    }

    func testWrongRevisionIDIsRejectedEvenWhenServiceWouldValidateIt() async throws {
        let valid = try LocalPreviewPresentationFixtures.comparison()
        let revision = PhotoRevision(id: LocalPreviewPresentationFixtures.otherID,
                                     modificationTime: 123, creationTime: 100)
        let wrong = LocalPreviewComparison(photoID: valid.photoID, revision: revision,
                                           authorizationRawValue: valid.authorizationRawValue,
                                           entries: valid.entries)
        await assertWrongIdentityRejected(wrong)
    }

    func testServiceErrorIsRedactedAndCancelClearsIt() async throws {
        let (state, service) = makeState([.init(.failure(LocalPreviewPresentationFixtures.privateError))])
        state.start()
        await state.waitUntilIdle()
        XCTAssertNil(state.result)
        XCTAssertFalse(state.isRunning)
        let message = try XCTUnwrap(state.errorMessage)
        XCTAssertEqual(message, LocalPreviewPresentationFixtures.failureMessage)
        for marker in LocalPreviewPresentationFixtures.privateMarkers {
            XCTAssertFalse(message.contains(marker), "Never display service metadata: \(marker)")
        }
        XCTAssertEqual(service.observations.failures, 1)
        XCTAssertTrue(service.observations.currentPhotoIDs.isEmpty)
        state.cancelAndClear()
        assertEmpty(state)
        XCTAssertEqual(service.observations.requests.count, 1)
    }

    func testRestartClearsOldErrorBeforeAwaitingNewReport() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let started = expectation(description: "Retry is held after error is cleared")
        let (state, service) = makeState([
            .init(.failure(LocalPreviewPresentationFixtures.privateError)),
            .init(.success(report), held: true, started: started)
        ])
        state.start()
        await state.waitUntilIdle()
        XCTAssertEqual(state.errorMessage, LocalPreviewPresentationFixtures.failureMessage)
        state.start()
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.result)
        XCTAssertTrue(state.isRunning)
        await fulfillment(of: [started], timeout: 3)
        service.release(1)
        await state.waitUntilIdle()
        try assertReport(state, equals: report)
        XCTAssertEqual(service.observations.requests.count, 2)
        XCTAssertEqual(service.observations.failures, 1)
        XCTAssertEqual(service.observations.successes, 1)
    }

    func testServiceCancellationErrorDoesNotBecomeUserVisibleFailure() async {
        let (state, service) = makeState([.init(.failure(CancellationError()))])
        state.start()
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.observations.failures, 1)
        XCTAssertEqual(service.observations.finished, 1)
        XCTAssertTrue(service.observations.currentPhotoIDs.isEmpty)
    }

    // MARK: Exactly four native captures; no taps, gestures or scrolling

    func testEntireSheetThreeDifferentProceduralResolutionsSnapshot() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison(reviewPixels: true)
        XCTAssertEqual(report.entries.compactMap { $0.preview?.cgImage.width }, [68, 224, 480])
        XCTAssertEqual(report.entries.compactMap { $0.preview?.cgImage.height }, [120, 398, 853])
        try await sheetSnapshot(report, id: "sheet-three-resolutions", size: phone)
    }

    func testEntireSheetAllThreePreviewsUnavailableSnapshot() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison(available: false)
        XCTAssertEqual(report.entries.count, 3)
        XCTAssertTrue(report.entries.allSatisfy { $0.preview == nil && $0.issue != nil })
        try await sheetSnapshot(report, id: "sheet-all-unavailable", size: phone)
    }

    func testDirectDetailPanelsUseOneIdenticalNormalizedCropSnapshot() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison(reviewPixels: true)
        // Deliberately off-centre, with one upright normalized crop supplied to
        // the real three-panel view. Not three independently guessed pixel crops.
        let crop = CGRect(x: 0.17, y: 0.33, width: 0.4, height: 0.4)
        let (state, service) = makeState([.init(.success(report))])
        state.start()
        await state.waitUntilIdle()
        let published = try XCTUnwrap(state.result)
        let panels = LocalPreviewComparisonImages(entries: published.entries, displayMode: .detail,
                                                  normalizedCrop: crop)
        XCTAssertEqual(panels.displayMode, .detail)
        XCTAssertEqual(panels.normalizedCrop, crop)
        XCTAssertEqual(panels.entries.map(\.mode), LocalPreviewMode.allCases)
        try await snapshot(panels.padding(16).background(IQStyle.background),
                           id: "detail-same-normalized-crop", size: phone) { [state, service, report] in
            try self.assertPreloadedFixture(state, service: service, report: report)
        }
        try assertPreloadedFixture(state, service: service, report: report)
        state.cancelAndClear()
        await state.waitUntilIdle()
        assertEmpty(state)
    }

    func testEntireSheetLargeDynamicTypeSnapshot() async throws {
        let report = try LocalPreviewPresentationFixtures.comparison(reviewPixels: true)
        try await sheetSnapshot(report, id: "sheet-accessibility-large", size: compactPhone,
                                dynamicTypeSize: .accessibility1)
    }

    // MARK: State helpers

    private func makeState(_ plans: [LocalPreviewPresentationService.Plan])
        -> (LocalPreviewComparisonState, LocalPreviewPresentationService) {
        let service = LocalPreviewPresentationService(plans: plans)
        let state = LocalPreviewComparisonState(service: service, photoID: LocalPreviewPresentationFixtures.photoID)
        // Strong captures keep each fixture alive until cleanup. Even an early
        // assertion/unwrap failure must release every held checked continuation.
        addTeardownBlock { [state, service] in
            await MainActor.run { state.cancelAndClear() }
            service.close()
        }
        return (state, service)
    }

    private func assertCancelledOutcomeIsDiscarded(failure: Bool) async throws {
        let report = try LocalPreviewPresentationFixtures.comparison()
        let outcome: Result<LocalPreviewComparison, Error> = failure
            ? .failure(LocalPreviewPresentationFixtures.privateError) : .success(report)
        let started = expectation(description: "Comparison reached a noninterruptible latch")
        let cancelled = expectation(description: "Cancellation reached the held comparison")
        let (state, service) = makeState([.init(outcome, held: true, started: started, cancelled: cancelled)])
        state.start()
        await fulfillment(of: [started], timeout: 3)
        state.cancelAndClear()
        assertEmpty(state)
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(service.observations.finished, 0, "Cancellation must not release the fake latch")
        XCTAssertEqual(service.observations.pending, 1)
        service.release(0)
        await state.waitUntilIdle()

        assertEmpty(state)
        let observed = service.observations
        XCTAssertEqual(observed.requests, [report.photoID])
        XCTAssertEqual(observed.cancellations, 1)
        XCTAssertEqual(observed.finished, 1)
        XCTAssertEqual(observed.successes, failure ? 0 : 1)
        XCTAssertEqual(observed.failures, failure ? 1 : 0)
        XCTAssertTrue(observed.currentPhotoIDs.isEmpty, "Cancelled results must not reach publication validation")
        XCTAssertEqual(observed.pending, 0)
    }

    private func assertRestartWaitsForDrain(failure: Bool) async throws {
        let first = try LocalPreviewPresentationFixtures.comparison()
        let second = try LocalPreviewPresentationFixtures.comparison(available: false)
        let outcome: Result<LocalPreviewComparison, Error> = failure
            ? .failure(LocalPreviewPresentationFixtures.privateError) : .success(first)
        let started = expectation(description: "Predecessor reached its latch")
        let cancelled = expectation(description: "Predecessor observes cancellation without completing")
        let replacement = expectation(description: "Replacement starts only after predecessor drain")
        let (state, service) = makeState([
            .init(outcome, held: true, started: started, cancelled: cancelled),
            .init(.success(second), held: true, started: replacement)
        ])
        state.start()
        await fulfillment(of: [started], timeout: 3)
        state.cancelAndClear()
        assertEmpty(state)
        state.start()
        state.start() // Also exercise the busy guard while waiting on the predecessor.
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertTrue(state.isRunning)
        XCTAssertNil(state.result)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(service.observations.requests.count, 1)
        XCTAssertEqual(service.observations.finished, 0)

        service.release(0)
        await fulfillment(of: [replacement], timeout: 3)
        XCTAssertTrue(state.isRunning, "The old task's defer must not clear the replacement's running flag")
        XCTAssertNil(state.result, "A late predecessor success must not replace the new pending result")
        XCTAssertNil(state.errorMessage, "A late predecessor failure must not replace the new pending state")
        XCTAssertEqual(service.observations.finished, 1)
        XCTAssertEqual(service.observations.active, 1)
        service.release(1)
        await state.waitUntilIdle()

        try assertReport(state, equals: second)
        let observed = service.observations
        XCTAssertEqual(observed.requests, [first.photoID, second.photoID])
        XCTAssertEqual(observed.peakActive, 1, "The fake allows overlap; only the production state serializes it")
        XCTAssertEqual(observed.events, ["begin.0", "release.0", "end.0", "begin.1", "release.1", "end.1"])
        XCTAssertEqual(observed.currentPhotoIDs, [second.photoID])
        XCTAssertEqual(observed.cancellations, 1)
        XCTAssertEqual(observed.finished, 2)
        XCTAssertEqual(observed.successes, failure ? 1 : 2)
        XCTAssertEqual(observed.failures, failure ? 1 : 0)
        XCTAssertEqual(observed.unplannedCalls, 0)
        XCTAssertEqual(observed.pending, 0)
    }

    private func assertWrongIdentityRejected(_ report: LocalPreviewComparison) async {
        let (state, service) = makeState([.init(.success(report))])
        state.start()
        await state.waitUntilIdle()
        XCTAssertNil(state.result)
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.errorMessage, LocalPreviewPresentationFixtures.changedMessage)
        XCTAssertEqual(service.observations.requests, [LocalPreviewPresentationFixtures.photoID])
        XCTAssertEqual(service.observations.successes, 1)
        XCTAssertTrue(service.observations.currentPhotoIDs.isEmpty,
                      "The state must reject either mismatched ID before the permissive fake validator")
    }

    private func assertEmpty(_ state: LocalPreviewComparisonState,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.result, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertFalse(state.isRunning, file: file, line: line)
    }

    private func assertReport(_ state: LocalPreviewComparisonState, equals expected: LocalPreviewComparison,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try XCTUnwrap(state.result, file: file, line: line)
        XCTAssertFalse(state.isRunning, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertEqual(actual.photoID, LocalPreviewPresentationFixtures.photoID, file: file, line: line)
        XCTAssertEqual(actual.photoID, expected.photoID, file: file, line: line)
        XCTAssertEqual(actual.revision, expected.revision, file: file, line: line)
        XCTAssertEqual(actual.revision.id, actual.photoID, file: file, line: line)
        XCTAssertEqual(actual.authorizationRawValue, expected.authorizationRawValue, file: file, line: line)
        XCTAssertEqual(actual.entries.count, 3, file: file, line: line)
        XCTAssertEqual(actual.entries.map(\.mode), [.fast224, .quality224, .quality480], file: file, line: line)
        for (entry, fixture) in zip(actual.entries, expected.entries) {
            XCTAssertEqual(entry.requestedSize, fixture.requestedSize, file: file, line: line)
            XCTAssertEqual(entry.issue, fixture.issue, file: file, line: line)
            if let pixels = fixture.preview {
                let preview = try XCTUnwrap(entry.preview, file: file, line: line)
                XCTAssertTrue(preview.cgImage === pixels.cgImage, "Retain fixture pixels without replacement", file: file, line: line)
                XCTAssertEqual(preview.cgImage.width, pixels.cgImage.width, file: file, line: line)
                XCTAssertEqual(preview.cgImage.height, pixels.cgImage.height, file: file, line: line)
                XCTAssertEqual(preview.orientation, pixels.orientation, file: file, line: line)
                XCTAssertEqual(preview.source, pixels.source, file: file, line: line)
                XCTAssertNotEqual(preview.source, .networkPreview, file: file, line: line)
                XCTAssertEqual(preview.requestedSize, pixels.requestedSize, file: file, line: line)
                XCTAssertEqual(preview.photokitDegraded, pixels.photokitDegraded, file: file, line: line)
            } else {
                XCTAssertNil(entry.preview, file: file, line: line)
            }
        }
    }

    private func assertPreloadedFixture(_ state: LocalPreviewComparisonState,
                                        service: LocalPreviewPresentationService,
                                        report: LocalPreviewComparison) throws {
        try assertReport(state, equals: report)
        let observed = service.observations
        XCTAssertEqual(observed.requests, [LocalPreviewPresentationFixtures.photoID])
        XCTAssertEqual(observed.currentPhotoIDs, [report.photoID])
        XCTAssertEqual(observed.currentRevisionIDs, [report.revision.id])
        XCTAssertEqual(observed.successes, 1)
        XCTAssertEqual(observed.finished, 1)
        XCTAssertEqual(observed.failures, 0)
        XCTAssertEqual(observed.unplannedCalls, 0, "Rendering must not restart the preloaded fake service")
        XCTAssertEqual(observed.active, 0)
        XCTAssertEqual(observed.pending, 0)
    }

    // MARK: Native window hosting, following PhotoCheckPresentationTests

    private func sheetSnapshot(_ report: LocalPreviewComparison, id: String, size: CGSize,
                               dynamicTypeSize: DynamicTypeSize = .large) async throws {
        let (state, service) = makeState([.init(.success(report))])
        state.start()
        await state.waitUntilIdle()
        try assertPreloadedFixture(state, service: service, report: report)
        // Always use the state initializer, never the concrete PhotoLibraryClient
        // initializer. The .task may run, but a completed injected result prevents
        // another comparison. No fake can fall through to a real/network loader.
        try await snapshot(LocalPreviewComparisonSheet(state: state), id: id, size: size,
                           dynamicTypeSize: dynamicTypeSize) { [state, service, report] in
            try self.assertPreloadedFixture(state, service: service, report: report)
        }
        state.cancelAndClear() // Idempotent with the real sheet's onDisappear.
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.observations.requests, [report.photoID], "Still exactly one fake request after unhosting")
        XCTAssertEqual(service.observations.unplannedCalls, 0)
    }

    private func snapshot<Content: View>(_ content: Content, id: String, size: CGSize,
                                         dynamicTypeSize: DynamicTypeSize = .large,
                                         capture: Bool = true,
                                         afterLayout: @MainActor () async -> Void = {},
                                         validate: @MainActor () throws -> Void) async throws {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native captures require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        let root = VStack(spacing: 0) {
            // Test-target watermark, including for the unavailable and large-font
            // states. Production views and their controls are not reconstructed.
            Text("TEST FIXTURE · procedural pixels · no real photo")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.black)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.scenePhase, .active) // Test environment only; never query/change Photos permission.
        let host = LocalPreviewPresentationHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        let laidOut = expectation(description: "\(id): native phone-size layout")
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
        let settled = expectation(description: "\(id): pending SwiftUI layout updates completed")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        await afterLayout()
        try validate() // Catch cleared/wrong fixtures and .task restarts before drawing.
        XCTAssertTrue(host.view.window === window)
        XCTAssertTrue(window.rootViewController === host)
        XCTAssertFalse(window.isHidden)
        XCTAssertEqual(host.view.bounds.size, size)
        guard capture else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drewHierarchy = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "Capture the actual hosted production view, not a stand-in image")
        XCTAssertEqual(image.size, size)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int(size.width))
        XCTAssertEqual(pixels.height, Int(size.height))
        try validate() // drawHierarchy can service pending UI work too.
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-local-preview-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Four phone viewports, including the whole production sheet at large
        // Dynamic Type (not a stitched full-scroll image). Human visual review is
        // still needed: dimensions/state identity do not prove clipping, label
        // visibility, taps, mode switching, region gestures or real-photo quality.
    }
}

@MainActor
private final class LocalPreviewPresentationHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private enum LocalPreviewPresentationFixtures {
    static let photoID = "local-preview-presentation-test-only-never-a-PHAsset"
    static let otherID = "local-preview-presentation-test-only-other-ID"
    static let changedMessage = "照片或访问权限已变化，请关闭后重新打开对比。"
    static let failureMessage = "未能完成本地预览对比。请确认仍可访问这张照片，保持应用在前台后重试。"
    static let privateMarkers = [photoID, otherID, "/TEST_PRIVATE/photo.jpg", "TEST_GPS_12.34_56.78"]
    static var privateError: NSError {
        NSError(domain: "TEST_PRIVATE_SERVICE", code: 7,
                userInfo: [NSLocalizedDescriptionKey: privateMarkers.joined(separator: " | "),
                           NSFilePathErrorKey: privateMarkers[2]])
    }

    static func comparison(available: Bool = true, reviewPixels: Bool = false) throws -> LocalPreviewComparison {
        // Unit-state tests keep tiny RGBA buffers; only review captures allocate
        // the requested 68x120, 224x398 and 480x853 illustrative representations.
        let sizes = reviewPixels ? [(68, 120), (224, 398), (480, 853)] : [(7, 11), (14, 22), (21, 33)]
        let issues = [LocalPreviewComparisonLoader.issueNeedsNetwork,
                      LocalPreviewComparisonLoader.issueUnavailable,
                      LocalPreviewComparisonLoader.issueFailed]
        var entries: [LocalPreviewEntry] = []
        for (index, mode) in LocalPreviewMode.allCases.enumerated() {
            let target = LocalPreviewComparisonLoader.targetSize(width: 1080, height: 1920, shortEdge: mode.shortEdge)
            let preview: IndexingImage?
            if available {
                let (width, height) = sizes[index]
                let pixels = try pattern(width: width, height: height)
                // false is deliberately retained for the undersized first image;
                // a raw degraded=false flag is not a pixel-quality guarantee.
                let degraded: Bool? = index == 1 ? nil : false
                let source: IndexingImage.Source = width < mode.shortEdge ? .localReducedPreview : .localPreview
                preview = IndexingImage(cgImage: pixels, orientation: .up, source: source,
                                        requestedSize: target, photokitDegraded: degraded)
            } else { preview = nil }
            entries.append(LocalPreviewEntry(mode: mode, requestedSize: target, preview: preview,
                                             issue: available ? nil : issues[index]))
        }
        return LocalPreviewComparison(photoID: photoID,
                                      revision: PhotoRevision(id: photoID, modificationTime: 123, creationTime: 100),
                                      authorizationRawValue: 4, // Synthetic scalar, never a permission query.
                                      entries: entries)
    }

    /// Same analytic scene sampled in normalized coordinates at each resolution.
    /// Fine linework is illustrative, not a simulated PhotoKit downsampling test.
    /// Even the TEST FIXTURE lettering is procedural; no file/font raster import.
    private static func pattern(width: Int, height: Int) throws -> CGImage {
        let letters = Array("TEST FIXTURE")
        return try TestFixtures.image(width: width, height: height, shouldInterpolate: true) { x, y in
            let u = (Double(x) + 0.5) / Double(width)
            let v = (Double(y) + 0.5) / Double(height)
            if v >= 0.06 && v < 0.14 && u >= 0.04 && u < 0.96 {
                let column = Int((u - 0.04) / 0.92 * Double(letters.count * 6))
                let row = Int((v - 0.06) / 0.08 * 7)
                let glyph = glyphs[letters[column / 6]] ?? [UInt8](repeating: 0, count: 7)
                let lit = column % 6 < 5 && (glyph[row] & (UInt8(1) << (4 - column % 6))) != 0
                return lit ? (255, 255, 255) : (12, 18, 30)
            }
            let checker = (Int(u * 48) + Int(v * 80)) % 2 == 0
            var color: (UInt8, UInt8, UInt8) = checker ? (38, 73, 102) : (17, 38, 69)
            if u > 0.18 && u < 0.82 && v > 0.26 && v < 0.76 {
                let fine = Int(u * 160) % 2 == 0
                color = fine ? (240, 175, 70) : (38, 125, 114)
            }
            if abs(u - (0.24 + (v - 0.25) * 0.8)) < 0.003 { color = (255, 255, 255) }
            let dx = u - 0.49, dy = (v - 0.56) * 1.7
            let radius = sqrt(dx * dx + dy * dy)
            if abs(radius - 0.13) < 0.004 || abs(radius - 0.19) < 0.003 { color = (255, 70, 130) }
            if abs(u - 0.49) < 0.002 || abs(v - 0.56) < 0.002 { color = (80, 230, 250) }
            return color
        }
    }

    private static let glyphs: [Character: [UInt8]] = [
        "T": [31, 4, 4, 4, 4, 4, 4], "E": [31, 16, 16, 30, 16, 16, 31],
        "S": [15, 16, 16, 14, 1, 1, 30], "F": [31, 16, 16, 30, 16, 16, 16],
        "I": [31, 4, 4, 4, 4, 4, 31], "X": [17, 17, 10, 4, 10, 17, 17],
        "U": [17, 17, 17, 17, 17, 17, 14], "R": [30, 17, 17, 30, 20, 18, 17]
    ]
}

/// Thread-safe, deliberately noninterruptible async fake. Locks protect counters
/// and latch installation only, never the asynchronous operation itself. Thus
/// peakActive/event ordering measure state serialization, not fake serialization.
/// No real loader/manager/client or networking implementation is stored here.
private final class LocalPreviewPresentationService: LocalPreviewComparing, @unchecked Sendable {
    struct Plan: Sendable {
        let outcome: Result<LocalPreviewComparison, Error>
        let held: Bool
        let started: XCTestExpectation?
        let cancelled: XCTestExpectation?

        init(_ outcome: Result<LocalPreviewComparison, Error>, held: Bool = false,
             started: XCTestExpectation? = nil, cancelled: XCTestExpectation? = nil) {
            self.outcome = outcome
            self.held = held
            self.started = started
            self.cancelled = cancelled
        }
    }

    struct Observations: Sendable {
        var requests: [String] = []
        var currentPhotoIDs: [String] = []
        var currentRevisionIDs: [String] = []
        var events: [String] = []
        var successes = 0
        var failures = 0
        var cancellations = 0
        var finished = 0
        var active = 0
        var peakActive = 0
        var pending = 0
        var unplannedCalls = 0
    }

    private enum FakeFailure: Error { case unplannedComparison }
    private let lock = NSLock()
    private let plans: [Plan]
    private var stored = Observations()
    private var current = true
    private var closed = false
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var cancelledCalls: Set<Int> = []

    init(plans: [Plan]) { self.plans = plans }

    var observations: Observations {
        locked {
            var copy = stored
            copy.pending = continuations.count
            return copy
        }
    }

    func setCurrent(_ value: Bool) { locked { current = value } }

    func isCurrent(_ comparison: LocalPreviewComparison) -> Bool {
        locked {
            stored.currentPhotoIDs.append(comparison.photoID)
            stored.currentRevisionIDs.append(comparison.revision.id)
            return current
        }
    }

    func compareLocalPreviews(id: String) async throws -> LocalPreviewComparison {
        let (number, plan) = begin(id)
        defer { finish(number) }
        await withTaskCancellationHandler(operation: {
            if plan.held {
                await withCheckedContinuation { continuation in
                    install(continuation, number: number)
                    plan.started?.fulfill()
                }
            } else { plan.started?.fulfill() }
        }, onCancel: { [self] in
            recordCancellation(number, expectation: plan.cancelled)
            // Intentionally neither resume nor throw here: explicitly release
            // the latch to deliver a late success or failure after cancellation.
        })
        do {
            let result = try plan.outcome.get()
            locked { stored.successes += 1 }
            return result
        } catch {
            locked { stored.failures += 1 }
            throw error
        }
    }

    func release(_ number: Int) {
        let continuation: CheckedContinuation<Void, Never>? = locked {
            guard released.insert(number).inserted else { return nil }
            stored.events.append("release.\(number)")
            return continuations.removeValue(forKey: number)
        }
        continuation?.resume()
    }

    func close() {
        let pending: [CheckedContinuation<Void, Never>] = locked {
            closed = true
            let pending = Array(continuations.values)
            continuations.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }

    private func begin(_ id: String) -> (Int, Plan) {
        locked {
            let number = stored.requests.count
            stored.requests.append(id)
            stored.events.append("begin.\(number)")
            stored.active += 1
            stored.peakActive = max(stored.peakActive, stored.active)
            guard !closed, number < plans.count else {
                stored.unplannedCalls += 1
                return (number, Plan(.failure(FakeFailure.unplannedComparison)))
            }
            return (number, plans[number])
        }
    }

    private func finish(_ number: Int) {
        locked {
            stored.active -= 1
            stored.finished += 1
            stored.events.append("end.\(number)")
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Never>, number: Int) {
        let resumeNow = locked {
            if closed || released.contains(number) { return true }
            continuations[number] = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    private func recordCancellation(_ number: Int, expectation: XCTestExpectation?) {
        let first = locked {
            guard cancelledCalls.insert(number).inserted else { return false }
            stored.cancellations += 1
            return true
        }
        if first { expectation?.fulfill() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}