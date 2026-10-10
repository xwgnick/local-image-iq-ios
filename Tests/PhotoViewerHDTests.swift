import XCTest
import Photos
import UIKit
import Combine
@testable import LocalImageIQ

/// Synthetic source/raster tests only; no Photos access, writes, or network.
@MainActor
final class PhotoViewerHDTests: XCTestCase {
    private let viewport = CGSize(width: 300, height: 600)

    func testResolutionUsesDisplayAssetAspectAndZoomWithoutArbitraryCap() {
        let asset = CGSize(width: 12000, height: 24000)
        XCTAssertEqual(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3, zoom: 1),
                       CGSize(width: 900, height: 1800))
        XCTAssertEqual(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3, zoom: 8),
                       CGSize(width: 7200, height: 14400))
        XCTAssertEqual(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3, zoom: 100), asset)
        XCTAssertEqual(PhotoViewerResolution.target(asset: CGSize(width: 12000, height: 3000),
                       viewport: viewport, displayScale: 3, zoom: 1), CGSize(width: 900, height: 225))
        XCTAssertEqual(PhotoViewerResolution.target(asset: CGSize(width: 100, height: 200),
                       viewport: viewport, displayScale: 3, zoom: 1), CGSize(width: 100, height: 200))
        XCTAssertEqual(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3,
                       zoom: .greatestFiniteMagnitude), asset)
        XCTAssertNil(PhotoViewerResolution.target(asset: .zero, viewport: viewport, displayScale: 3, zoom: 1))
        XCTAssertNil(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: .nan, zoom: 1))
        XCTAssertNil(PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3, zoom: .infinity))
    }

    func testPreviewPublishesBeforeHeldLocalUpgradeAndNeverUsesGlobalOptIn() async throws {
        let fake = HDFixture()
        let entered = expectation(description: "Local upgrade entered")
        fake.onUpgrade = { _, _, _ in entered.fulfill() }
        fake.holdUpgrades = true
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(fake.events, ["metadata:a", "preview:a:false", "local:a"])
        XCTAssertTrue(state.photo?.result.image === fake.preview)
        XCTAssertEqual(state.phase, .local)
        XCTAssertEqual(state.shareQuality, .preview)
        XCTAssertEqual(fake.requests.first?.target, CGSize(width: 900, height: 1800))
        let hd = image(900, 1800)
        fake.complete(0, image: hd)
        await state.waitForCurrentWork()
        XCTAssertTrue(state.photo?.result.image === hd)
        XCTAssertEqual(state.shareQuality, .highDefinition)
        XCTAssertFalse(state.canRequestCloud)
        XCTAssertEqual(fake.requests.map(\.cloud), [false])
    }

    func testZoomRequestsMoreRealLocalPixelsAndViewportUpdatesRetainZoom() async throws {
        let fake = HDFixture()
        fake.autoImage = image(900, 1800)
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        fake.autoImage = image(1800, 3600)
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 2)
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.map(\.target), [CGSize(width: 900, height: 1800), CGSize(width: 1800, height: 3600)])
        XCTAssertEqual(fake.requests.map(\.cloud), [false, false])
        state.updateViewport(CGSize(width: 280, height: 560), displayScale: 3)
        XCTAssertEqual(state.zoom, 2)
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testTinyReadableFastFallbackSurvivesMissingSmallerAndDegradedUpgrade() async throws {
        for output in [0, 1, 2] {
            let fake = HDFixture()
            fake.preview = image(32, 64)
            fake.previewStage = .localFast224
            if output == 0 { fake.upgradeError = AppFailure.cloudOnly }
            if output == 1 { fake.autoImage = image(16, 32) }
            if output == 2 { fake.autoImage = image(32, 64); fake.degraded = true }
            let state = makeState(fake)
            defer { state.stop(); fake.drain() }
            state.open(id: "a")
            await state.waitForCurrentWork()
            XCTAssertTrue(state.photo?.result.image === fake.preview)
            XCTAssertEqual(state.shareQuality, .preview)
            XCTAssertTrue(state.canRequestCloud)
            XCTAssertEqual(fake.requests.map(\.cloud), [false])
        }
    }

    func testCloudDialogCancelDoesNotRequestAndConfirmationIsSingleUse() async throws {
        let fake = HDFixture()
        fake.upgradeError = AppFailure.cloudOnly
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        state.requestCloudConfirmation()
        let dismissed = try XCTUnwrap(state.consent)
        state.dismissCloudConfirmation()
        state.confirmCloud(dismissed)
        XCTAssertEqual(fake.requests.count, 1)
        state.requestCloudConfirmation()
        let approved = try XCTUnwrap(state.consent)
        XCTAssertEqual(fake.requests.count, 1)
        fake.upgradeError = nil
        fake.autoImage = image(900, 1800)
        state.confirmCloud(approved)
        state.confirmCloud(approved)
        await state.waitForCurrentWork()
        XCTAssertNil(state.consent)
        XCTAssertEqual(fake.requests.map(\.cloud), [false, true])
        XCTAssertEqual(fake.initialNetworks, [false])
        XCTAssertEqual(state.shareQuality, .highDefinition)
        state.open(id: "b")
        await state.waitForCurrentWork()
        state.confirmCloud(approved)
        XCTAssertEqual(fake.initialNetworks, [false, false])
        XCTAssertEqual(fake.requests.map(\.cloud), [false, true, false])
    }

    func testCloudOnlyWithoutAnyPreviewStillRequiresExplicitConfirmation() async throws {
        let fake = HDFixture()
        fake.previewError = AppFailure.cloudOnly
        fake.autoImage = image(900, 1800)
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        XCTAssertNil(state.photo)
        XCTAssertTrue(state.canRequestCloud)
        XCTAssertTrue(fake.requests.isEmpty)
        state.requestCloudConfirmation()
        state.confirmCloud(try XCTUnwrap(state.consent))
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.map(\.cloud), [true])
        XCTAssertNotNil(state.photo)
    }

    func testCloudFailureAndPhotoKitCancellationPreserveImageZoomAndRequireNewConsent() async throws {
        let failures: [Error] = [AppFailure.photo("Synthetic failure"), CancellationError()]
        for failure in failures {
            let fake = HDFixture()
            fake.upgradeError = AppFailure.cloudOnly
            let state = makeState(fake)
            defer { state.stop(); fake.drain() }
            state.open(id: "a")
            await state.waitForCurrentWork()
            state.updateDemand(viewport: viewport, displayScale: 3, zoom: 2)
            await state.waitForCurrentWork()
            state.requestCloudConfirmation()
            let approved = try XCTUnwrap(state.consent)
            fake.upgradeError = failure
            state.confirmCloud(approved)
            await state.waitForCurrentWork()
            XCTAssertTrue(state.photo?.result.image === fake.preview)
            XCTAssertEqual(state.zoom, 2)
            XCTAssertEqual(state.phase, failure is CancellationError ? .cancelled : .failed)
            XCTAssertNil(state.consent)
            state.confirmCloud(approved)
            XCTAssertEqual(fake.requests.map(\.cloud), [false, false, true])
        }
    }

    func testCancelWaitsForDrainAndLateCloudSuccessCannotPublishOrGrantConsent() async throws {
        let fake = HDFixture()
        fake.upgradeError = AppFailure.cloudOnly
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 2)
        await state.waitForCurrentWork()
        let entered = expectation(description: "Cloud request held")
        fake.onUpgrade = { _, _, cloud in if cloud { entered.fulfill() } }
        fake.holdUpgrades = true
        state.requestCloudConfirmation()
        state.confirmCloud(try XCTUnwrap(state.consent))
        await fulfillment(of: [entered], timeout: 5)
        state.cancelUpgrade()
        XCTAssertEqual(state.phase, .cancelling)
        XCTAssertTrue(state.photo?.result.image === fake.preview)
        XCTAssertEqual(state.zoom, 2)
        XCTAssertFalse(state.canRequestCloud)
        fake.complete(2, image: image(1800, 3600)) // Deliberately ignores task cancellation.
        await state.waitForCurrentWork()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(state.photo?.result.image === fake.preview)
        XCTAssertEqual(state.zoom, 2)
        XCTAssertTrue(state.canRequestCloud)
        XCTAssertEqual(fake.requests.count, 3)
    }

    func testPageChangeWaitsForOldDrainAndNeverAdmitsOldPhotoOrConsent() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let first = expectation(description: "Old page upgrade")
        fake.onUpgrade = { id, _, _ in if id == "a" { first.fulfill() } }
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [first], timeout: 5)
        state.open(id: "b")
        XCTAssertNil(state.photo)
        XCTAssertEqual(fake.initialIDs, ["a"], "No new source work before old task drains")
        fake.holdUpgrades = false
        fake.autoImage = image(900, 1800)
        fake.complete(0, image: image(1800, 3600))
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.initialIDs, ["a", "b"])
        XCTAssertEqual(state.photo?.snapshot.revision.id, "b")
        XCTAssertEqual(fake.requests.map(\.cloud), [false, false])
    }

    func testDismissClearsPixelsCancelsAndRejectsLateSuccess() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let entered = expectation(description: "Upgrade held")
        fake.onUpgrade = { _, _, _ in entered.fulfill() }
        let state = makeState(fake)
        defer { fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [entered], timeout: 5)
        state.stop()
        XCTAssertNil(state.photo)
        XCTAssertNil(state.consent)
        fake.complete(0, image: image(900, 1800))
        await state.waitForCurrentWork()
        XCTAssertNil(state.photo)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testRevisionAuthorizationGenerationAndDeletionChangesRejectLateResults() async throws {
        for change in 0..<6 {
            let fake = HDFixture()
            fake.holdUpgrades = true
            let entered = expectation(description: "Upgrade held for authority change")
            fake.onUpgrade = { _, _, _ in entered.fulfill() }
            let state = makeState(fake)
            defer { state.stop(); fake.drain() }
            state.open(id: "a")
            await fulfillment(of: [entered], timeout: 5)
            switch change {
            case 0: fake.authorization = .denied
            case 1: fake.authorization = .limited
            case 2: fake.generation = 9
            case 3: fake.modification = 2
            case 4: fake.creation = nil
            default: fake.missing = true
            }
            fake.complete(0, image: image(900, 1800))
            await state.waitForCurrentWork()
            XCTAssertNil(state.photo)
            XCTAssertNil(state.makeShareRendition())
            XCTAssertEqual(state.phase, .access)
        }
    }

    func testChangedAuthorityWhileDialogOpenInvalidatesConsentBeforeAnyCloudCall() async throws {
        let fake = HDFixture()
        fake.upgradeError = AppFailure.cloudOnly
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        state.requestCloudConfirmation()
        let approved = try XCTUnwrap(state.consent)
        fake.generation = 2
        state.confirmCloud(approved)
        XCTAssertEqual(state.phase, .access)
        XCTAssertNil(state.photo)
        XCTAssertNil(state.consent)
        XCTAssertEqual(fake.requests.map(\.cloud), [false])
    }

    func testReturnedWrongRevisionOrCanonicallyEquivalentIDCannotPublish() async throws {
        for wrong in ["other", "e\u{0301}"] {
            let fake = HDFixture()
            fake.returnedID = wrong
            fake.autoImage = image(900, 1800)
            let state = makeState(fake)
            defer { state.stop(); fake.drain() }
            state.open(id: "\u{00e9}")
            await state.waitForCurrentWork()
            XCTAssertNil(state.photo)
            XCTAssertEqual(state.phase, .access)
        }
    }

    func testZoomDuringCloudRequestDoesNotExpandTheConsumedCloudTarget() async throws {
        let fake = HDFixture()
        fake.upgradeError = AppFailure.cloudOnly
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        let entered = expectation(description: "Cloud starts at approved viewport")
        fake.onUpgrade = { _, _, cloud in if cloud { entered.fulfill() } }
        fake.holdUpgrades = true
        state.requestCloudConfirmation()
        state.confirmCloud(try XCTUnwrap(state.consent))
        await fulfillment(of: [entered], timeout: 5)
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 2)
        XCTAssertEqual(fake.requests.count, 2)
        fake.holdUpgrades = false
        fake.complete(1, image: image(900, 1800))
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.map(\.cloud), [false, true, false])
        XCTAssertEqual(fake.requests.map(\.target), [CGSize(width: 900, height: 1800),
                       CGSize(width: 900, height: 1800), CGSize(width: 1800, height: 3600)])
        XCTAssertEqual(state.zoom, 2)
        XCTAssertTrue(state.canRequestCloud)
    }

    func testShareBindsCopiedDisplayedPixelsQualityAndAuthorityNotLaterUpgrade() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let entered = expectation(description: "Held upgrade while sharing preview")
        fake.onUpgrade = { _, _, _ in entered.fulfill() }
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [entered], timeout: 5)
        let previewShare = try XCTUnwrap(state.makeShareRendition())
        XCTAssertEqual(previewShare.quality.rawValue, "分享预览")
        XCTAssertFalse(previewShare.image === fake.preview)
        XCTAssertEqual(previewShare.image.cgImage?.width, 224)
        fake.complete(0, image: image(900, 1800))
        await state.waitForCurrentWork()
        let hdShare = try XCTUnwrap(state.makeShareRendition())
        XCTAssertEqual(hdShare.quality.rawValue, "分享高清")
        XCTAssertEqual(hdShare.image.cgImage?.width, 900)
        XCTAssertEqual(previewShare.image.cgImage?.width, 224)
        XCTAssertEqual(previewShare.quality, .preview)
        XCTAssertNotEqual(previewShare.id, hdShare.id)
        fake.authorization = .denied
        XCTAssertNil(state.makeShareRendition())
        XCTAssertFalse(state.isCurrent(hdShare.snapshot))
        XCTAssertNil(state.photo)
    }

    func testQualityUsesActualOrientedPixelsNotHQRequestNameOrUIImageScale() {
        let base = image(1800, 900)
        let rotated = UIImage(cgImage: base.cgImage!, scale: 3, orientation: .rightMirrored)
        let good = result(rotated, stage: .localHQ, degraded: false)
        XCTAssertEqual(PhotoViewerShareQuality.classify(good, viewportTarget: CGSize(width: 900, height: 1800)), .highDefinition)
        for candidate in [result(image(68, 120), stage: .networkHQ, degraded: false),
                          result(image(900, 1800), stage: .localHQ, degraded: true),
                          result(image(900, 1800), stage: .localFast224, degraded: false)] {
            XCTAssertEqual(PhotoViewerShareQuality.classify(candidate, viewportTarget: CGSize(width: 900, height: 1800)), .preview)
        }
    }

    func testAuthorizationChangingDuringShareRenderingRejectsTheCopy() async {
        let fake = HDFixture()
        fake.autoImage = image(900, 1800)
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        fake.invalidateOnValidation = fake.validationCalls + 2
        XCTAssertNil(state.makeShareRendition())
        XCTAssertNil(state.photo)
        XCTAssertEqual(state.phase, .access)
    }

    func testRepeatedIdenticalDemandDoesNotLoopAfterUnavailableLocalUpgrade() async {
        let fake = HDFixture()
        fake.upgradeError = AppFailure.cloudOnly
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<10 { state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1) }
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertTrue(state.canRequestCloud)
        XCTAssertEqual(publications, 0)
    }

    func testIntermediatePortraitCoverageExplainsWhyControlsMustNotChangeDemand() {
        let asset = CGSize(width: 4000, height: 8000)
        let withoutControls = PhotoViewerResolution.target(asset: asset, viewport: viewport, displayScale: 3, zoom: 1)
        let withControls = PhotoViewerResolution.target(asset: asset, viewport: CGSize(width: 300, height: 548),
                                                       displayScale: 3, zoom: 1)
        XCTAssertEqual(withoutControls, CGSize(width: 900, height: 1800))
        XCTAssertEqual(withControls, CGSize(width: 822, height: 1644))
        let intermediate = result(image(860, 1720), stage: .localHQ, degraded: false)
        XCTAssertFalse(PhotoViewerResolution.covers(intermediate, CGSize(width: 900, height: 1800)))
        XCTAssertTrue(PhotoViewerResolution.covers(intermediate, CGSize(width: 822, height: 1644)))
    }

    func testIdenticalDemandWhileLocalRequestIsHeldDoesNotCancelOrPublish() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let entered = expectation(description: "Local request held")
        fake.onUpgrade = { _, _, _ in entered.fulfill() }
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [entered], timeout: 5)
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<10 { state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1) }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(fake.requests.count, 1)
        let completed = image(900, 1800)
        fake.complete(0, image: completed)
        await state.waitForCurrentWork()
        XCTAssertTrue(state.photo?.result.image === completed, "Identical demand must not cancel the held request")
        XCTAssertEqual(state.phase, .idle)
    }

    func testHeldLocalGrowThenShrinkBeforeReplacementStartsRetriesOriginalTarget() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let first = expectation(description: "T1 held")
        fake.onUpgrade = { _, _, _ in first.fulfill() }
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [first], timeout: 5)
        let replacement = expectation(description: "Fresh T1 starts after cancelled predecessor drains")
        fake.onUpgrade = { _, _, _ in replacement.fulfill() }
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 2)
        // No yield: T2 is queued, not started, when demand returns to T1.
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1)
        for _ in 0..<10 { state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1) }
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertTrue(state.photo?.result.image === fake.preview)
        fake.complete(0, image: image(1800, 3600)) // Late success ignores cancellation.
        await fulfillment(of: [replacement], timeout: 5)
        XCTAssertEqual(fake.requests.count, 2)
        guard fake.requests.count == 2 else { return } // A failed gate must not hang on a missing continuation.
        XCTAssertEqual(fake.requests.map(\.target), [CGSize(width: 900, height: 1800), CGSize(width: 900, height: 1800)])
        XCTAssertEqual(fake.requests.map(\.cloud), [false, false])
        XCTAssertTrue(state.photo?.result.image === fake.preview, "Cancelled T1 must not replace readable pixels")
        XCTAssertEqual(state.zoom, 1)
        XCTAssertEqual(state.phase, .local)
        let completed = image(900, 1800)
        fake.complete(1, image: completed)
        await state.waitForCurrentWork()
        XCTAssertTrue(state.photo?.result.image === completed)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(fake.requests.count, 2)
    }

    func testLocalCancellationDoesNotCountAsCompletedButTerminalAttemptsDo() async throws {
        let fake = HDFixture()
        fake.upgradeError = CancellationError()
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await state.waitForCurrentWork()
        XCTAssertEqual(state.phase, .cancelled)
        XCTAssertTrue(state.photo?.result.image === fake.preview)
        fake.upgradeError = nil
        fake.autoImage = image(860, 1720)
        state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1)
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.count, 2, "An uncancelled retry of the same target is still needed")
        XCTAssertTrue(state.photo?.result.image === fake.autoImage)
        XCTAssertTrue(state.canRequestCloud)
        var publications = 0
        let subscription = state.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<10 { state.updateDemand(viewport: viewport, displayScale: 3, zoom: 1) }
        await state.waitForCurrentWork()
        XCTAssertEqual(fake.requests.count, 2, "A completed undersized result must not cause a local retry loop")
        XCTAssertEqual(publications, 0)
    }

    func testStopAndSamePhotoResumeWhileLocalOrCloudCallbackIsPendingRejectsOldSession() async throws {
        // The gallery uses stop/open on background/resume. Exercise the exact
        // state boundary without claiming to suspend the OS or use real Photos.
        for cloud in [false, true] {
            let fake = HDFixture()
            let state = makeState(fake)
            defer { state.stop(); fake.drain() }
            var oldApproval: PhotoViewerHDState.Consent?
            let entered = expectation(description: "Old session callback held")
            if cloud {
                fake.upgradeError = AppFailure.cloudOnly
                state.open(id: "a")
                await state.waitForCurrentWork()
                state.requestCloudConfirmation()
                oldApproval = try XCTUnwrap(state.consent)
                fake.holdUpgrades = true
                fake.onUpgrade = { _, _, _ in entered.fulfill() }
                state.confirmCloud(try XCTUnwrap(oldApproval))
            } else {
                fake.holdUpgrades = true
                fake.onUpgrade = { _, _, _ in entered.fulfill() }
                state.open(id: "a")
            }
            await fulfillment(of: [entered], timeout: 5)
            let oldIndex = fake.requests.count - 1
            state.stop()
            XCTAssertNil(state.photo)
            XCTAssertNil(state.consent)
            state.open(id: "a") // Resume before the old callback returns.
            if let oldApproval { state.confirmCloud(oldApproval) }
            XCTAssertEqual(fake.initialIDs, ["a"], "Resume must wait for the old session to drain")
            XCTAssertNil(state.photo)
            let resumed = expectation(description: "New session local upgrade held")
            fake.onUpgrade = { _, _, _ in resumed.fulfill() }
            fake.complete(oldIndex, image: image(1800, 3600))
            await fulfillment(of: [resumed], timeout: 5)
            XCTAssertEqual(fake.requests.count, oldIndex + 2)
            guard fake.requests.count == oldIndex + 2 else { return }
            XCTAssertEqual(fake.initialIDs, ["a", "a"])
            XCTAssertEqual(fake.initialNetworks, [false, false])
            XCTAssertEqual(fake.requests.map(\.cloud), cloud ? [false, true, false] : [false, false])
            XCTAssertTrue(state.photo?.result.image === fake.preview)
            XCTAssertNil(state.consent)
            fake.complete(oldIndex + 1, image: image(900, 1800))
            await state.waitForCurrentWork()
            XCTAssertEqual(state.shareQuality, .highDefinition)
        }
    }

    func testResumeRevalidatesAccessBeforeLoadingAfterOldCallbackDrains() async throws {
        let fake = HDFixture()
        fake.holdUpgrades = true
        let entered = expectation(description: "Local callback held before background")
        fake.onUpgrade = { _, _, _ in entered.fulfill() }
        let state = makeState(fake)
        defer { state.stop(); fake.drain() }
        state.open(id: "a")
        await fulfillment(of: [entered], timeout: 5)
        state.stop()
        fake.authorization = .denied
        state.open(id: "a")
        fake.complete(0, image: image(900, 1800))
        await state.waitForCurrentWork()
        XCTAssertEqual(state.phase, .access)
        XCTAssertNil(state.photo)
        XCTAssertNil(state.makeShareRendition())
        XCTAssertNil(state.consent)
        XCTAssertEqual(fake.initialIDs, ["a"])
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testLegacySourceNeedsNoNewMethodsAndDoesNotIssueAnUpgrade() async throws {
        let snapshot = HDFixture.snapshot("a")
        let expected = PhotoViewerImage(snapshot: snapshot, result: result(image(32, 64), stage: .localHQ224, degraded: true))
        let source = PhotoViewerImageSource(load: { _, network in
            XCTAssertFalse(network)
            return expected
        }, validate: { _ in })
        let state = PhotoViewerHDState(source: source)
        state.updateViewport(viewport, displayScale: 3)
        state.open(id: "a")
        await state.waitForCurrentWork()
        XCTAssertTrue(state.photo?.result.image === expected.result.image)
        XCTAssertFalse(state.canRequestCloud)
        XCTAssertEqual(state.shareQuality, .preview)
        state.stop()
    }

    func testZoomStateHasNoFourTimesCapAndResetIsExplicit() {
        let zoom = PhotoViewerZoomState()
        zoom.magnify(by: 2)
        zoom.magnify(by: 3)
        XCTAssertEqual(zoom.scale, 6)
        zoom.magnify(by: .infinity)
        XCTAssertEqual(zoom.scale, 6)
        zoom.reset()
        XCTAssertEqual(zoom.scale, 1)
        zoom.magnify(by: 0.5)
        XCTAssertEqual(zoom.scale, 1)
    }

    private func makeState(_ fake: HDFixture) -> PhotoViewerHDState {
        let state = PhotoViewerHDState(source: fake.source)
        state.updateViewport(viewport, displayScale: 3)
        return state
    }

    private func image(_ width: Int, _ height: Int) -> UIImage { HDFixture.image(width, height) }
    private func result(_ image: UIImage, stage: DisplayThumbnailStage, degraded: Bool?) -> DisplayThumbnailResult {
        HDFixture.result(image, stage: stage, degraded: degraded, target: CGSize(width: 900, height: 1800))
    }
}

/// All mutable fixture state is MainActor-isolated. Source closures explicitly
/// hop there; production Photos request options/gates have separate tests below.
@MainActor
private final class HDFixture {
    struct Request {
        let asset: PhotoViewerAsset
        let target: CGSize
        let cloud: Bool
    }
    var preview = HDFixture.image(224, 448)
    var previewStage: DisplayThumbnailStage = .localHQ224
    var previewError: Error?
    var upgradeError: Error?
    var autoImage: UIImage?
    var degraded: Bool? = false
    var holdUpgrades = false
    var onUpgrade: ((String, CGSize, Bool) -> Void)?
    var authorization: PHAuthorizationStatus = .authorized
    var generation: UInt64? = 1
    var modification: Double = 1
    var creation: Double? = 1
    var missing = false
    var returnedID: String?
    private(set) var validationCalls = 0
    var invalidateOnValidation: Int?
    private(set) var events: [String] = []
    private(set) var initialNetworks: [Bool] = []
    private(set) var initialIDs: [String] = []
    private(set) var requests: [Request] = []
    private var pending: [Int: CheckedContinuation<PhotoViewerImage, Error>] = [:]
    var source: PhotoViewerImageSource {
        // This fixture is exclusively consumed by the MainActor state machine.
        // Assert that contract for its synchronous capture/validation callbacks;
        // low-level arbitrary-queue request gates are tested separately.
        PhotoViewerImageSource(load: { [self] id, network in
            try await first(id, network: network)
        }, validate: { [self] snapshot in
            try MainActor.assumeIsolated { try validate(snapshot) }
        }, asset: { [self] id in
            try MainActor.assumeIsolated { try capture(id) }
        }, upgrade: { [self] asset, target, cloud in
            try await upgrade(asset, target: target, cloud: cloud)
        })
    }

    private func capture(_ id: String) throws -> PhotoViewerAsset {
        events.append("metadata:\(id)")
        let snapshot = currentSnapshot(id)
        try validate(snapshot)
        return PhotoViewerAsset(snapshot: snapshot, pixelSize: CGSize(width: 4000, height: 8000))
    }

    private func currentSnapshot(_ id: String) -> PhotoViewerSnapshot {
        PhotoViewerSnapshot(revision: PhotoRevision(id: id, modificationTime: modification, creationTime: creation),
                            authorization: authorization, generation: generation)
    }

    private func validate(_ snapshot: PhotoViewerSnapshot) throws {
        validationCalls += 1
        if validationCalls == invalidateOnValidation { authorization = .denied }
        try snapshot.validate(id: snapshot.revision.id, authorization: { authorization }, generation: { generation },
            currentRevision: { id in missing ? nil : currentSnapshot(id).revision })
    }

    private func first(_ id: String, network: Bool) throws -> PhotoViewerImage {
        events.append("preview:\(id):\(network)")
        initialNetworks.append(network)
        initialIDs.append(id)
        if let previewError { throw previewError }
        return PhotoViewerImage(snapshot: currentSnapshot(id), result: Self.result(preview,
            stage: previewStage, degraded: false, target: CGSize(width: 224, height: 448)))
    }

    private func upgrade(_ asset: PhotoViewerAsset, target: CGSize, cloud: Bool) async throws -> PhotoViewerImage {
        let index = requests.count
        requests.append(Request(asset: asset, target: target, cloud: cloud))
        events.append("\(cloud ? "cloud" : "local"):\(asset.snapshot.revision.id)")
        if holdUpgrades {
            return try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                onUpgrade?(asset.snapshot.revision.id, target, cloud)
            }
        }
        onUpgrade?(asset.snapshot.revision.id, target, cloud)
        if let upgradeError { throw upgradeError }
        return response(index, image: autoImage ?? preview)
    }

    private func response(_ index: Int, image: UIImage) -> PhotoViewerImage {
        let request = requests[index]
        let snapshot = returnedID.map { id in
            PhotoViewerSnapshot(revision: PhotoRevision(id: id, modificationTime: 1, creationTime: 1),
                                authorization: .authorized, generation: 1)
        } ?? request.asset.snapshot
        return PhotoViewerImage(snapshot: snapshot, result: Self.result(image,
            stage: request.cloud ? .networkHQ : .localHQ, degraded: degraded, target: request.target))
    }

    func complete(_ index: Int, image: UIImage) {
        guard let continuation = pending.removeValue(forKey: index) else { XCTFail("No held request"); return }
        continuation.resume(returning: response(index, image: image))
    }

    func drain() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }

    static func snapshot(_ id: String) -> PhotoViewerSnapshot {
        PhotoViewerSnapshot(revision: PhotoRevision(id: id, modificationTime: 1, creationTime: 1),
                            authorization: .authorized, generation: 1)
    }

    static func image(_ width: Int, _ height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func result(_ image: UIImage, stage: DisplayThumbnailStage, degraded: Bool?, target: CGSize) -> DisplayThumbnailResult {
        DisplayThumbnailResult(image: image, stage: stage, requestedSize: target,
            returnedSize: image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
            degraded: degraded, targetSize: target)
    }
}