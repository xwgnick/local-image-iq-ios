import Foundation
import Combine
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Synthetic metadata only. No PhotoLibraryClient, network, inference or Photos
/// mutation. The lightweight display proof is deliberately NOT a delete grant.
@MainActor
final class SimilarCleanupRefinementTests: XCTestCase {
    func testFilterKeepsHiddenSelectionsAuthorityCanonicalOrderAndNoRecompute() async throws {
        let f = await fixture()
        f.state.toggleGroupSelection("g0")
        await f.state.waitUntilIdle()
        f.state.toggleGroupSelection("g1")
        await f.state.waitUntilIdle()
        let session = f.state.selectionSessionID
        let ids = f.state.groups.map { $0.photos.map(\.id) }
        XCTAssertEqual(f.state.selectedCount, 10)
        f.state.setMinimumGroupCount(5)
        XCTAssertEqual(f.state.visibleGroups.map(\.id), ["g0"])
        XCTAssertEqual(f.state.groups.map { $0.photos.map(\.id) }, ids)
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.service.readCount, 1)
        XCTAssertEqual(f.state.selectionSummary, .init(groupCount: 2, photoCount: 10, fullGroupCount: 2,
                                                      hiddenGroupCount: 1, hiddenPhotoCount: 4))
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertEqual(intent.count, 10)
        XCTAssertEqual(intent.emptiedGroupCount, 2)
        XCTAssertEqual(intent.hiddenGroupCount, 1)
        XCTAssertEqual(intent.hiddenPhotoCount, 4)
        XCTAssertEqual(intent.revisions.map(\.id), ids.flatMap { $0 })
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.setMinimumGroupCount(2)
        XCTAssertNil(f.state.pendingDeletion)
        f.state.confirmDeletion(intent)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.deletion.calls.isEmpty, "Changing disclosure invalidates an open confirmation, not selection")
        XCTAssertEqual(f.state.selectedCount, 10)
        XCTAssertEqual(f.service.readCount, 1)
    }

    func testGroupCheckboxNonePartialAllAndClearCurrentGroupNeverChoosesKeeper() async throws {
        let f = await fixture()
        let group = f.state.groups[0]
        XCTAssertEqual(SimilarGroupPresentation.selection(in: group, selectedIDs: f.state.selectedIDs), .none)
        f.state.toggleSelection("p0-1")
        XCTAssertEqual(SimilarGroupPresentation.selection(in: group, selectedIDs: f.state.selectedIDs), .partial)
        f.state.toggleGroupSelection("g1")
        await f.state.waitUntilIdle()
        f.state.toggleGroupSelection("g0") // Partial -> ALL, including first/last members.
        await f.state.waitUntilIdle()
        XCTAssertEqual(SimilarGroupPresentation.selection(in: group, selectedIDs: f.state.selectedIDs), .all)
        XCTAssertTrue(f.state.selectedIDs.contains("p0-0"))
        XCTAssertTrue(f.state.selectedIDs.contains("p0-5"))
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "g0"))
        f.state.finishRangeSelection(token: token, selectedInGroup: [])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(f.state.groups[1].photos.map(\.id)))
        f.state.toggleGroupSelection("g1") // ALL -> none.
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testMinimumUsesActualMaximumAndNeverAnArbitraryCapacityLimit() async {
        let f = await fixture(sizes: [2, 3_017])
        XCTAssertEqual(f.state.minimumGroupCount, 2)
        XCTAssertEqual(f.state.largestGroupCount, 3_017)
        f.state.setMinimumGroupCount(Int.max)
        XCTAssertEqual(f.state.minimumGroupCount, 3_017)
        XCTAssertEqual(f.state.visibleGroups.first?.photos.count, 3_017)
        f.state.setMinimumGroupCount(Int.min)
        XCTAssertEqual(f.state.minimumGroupCount, 2)
        XCTAssertEqual(f.service.readCount, 1)
    }

    func testReleasedSimilarityClearsSelectionWithNoticeButRetainsBrowseUntilFreshResult() async {
        let f = await fixture()
        f.state.toggleSelection("p0-0")
        let browse = f.state.browsingSessionID
        f.state.setAutomaticRefreshDeferred(true)
        f.state.setDraftThreshold(0.75)
        XCTAssertEqual(f.state.selectedCount, 1, "Preview does not commit the slider")
        f.state.commitDraftThreshold()
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertEqual(f.state.browsingSessionID, browse)
        XCTAssertEqual(f.state.statusNotice, "相似度已更改，原选择已清除。")
        XCTAssertEqual(f.service.readCount, 1)
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.threshold, 0.75)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.state.browsingSessionID, browse)
    }

    func testPauseRetainsIdentityButHidesPixelsRevokesIntentAndNeedsFreshDisplayCheck() async throws {
        let f = await fixture()
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let browse = f.state.browsingSessionID
        let session = f.state.selectionSessionID
        f.state.setAutomaticRefreshDeferred(true)
        f.state.pause()
        XCTAssertFalse(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.state.groups.count, 2)
        XCTAssertEqual(f.state.browsingSessionID, browse)
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.canBrowse, "Fresh metadata can restore display while the index is busy")
        XCTAssertFalse(f.state.canSelect, "Display proof is not source/selection authority")
        XCTAssertEqual(f.library.batchReads, 1)
        XCTAssertEqual(f.service.readCount, 1)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.canSelect)
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.browsingSessionID, browse)
    }

    func testProtectedDataBlocksDisplayChecksAndFullReadsUntilReadable() async {
        let f = await fixture()
        f.state.setAutomaticRefreshDeferred(true)
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: false, canRead: true)
        f.state.resume() // A parent resume alone cannot bypass protected data.
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.library.batchReads, 0)
        XCTAssertEqual(f.service.readCount, 1)
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.library.batchReads, 1)
    }

    func testInactiveHidesPhotosWithoutDiscardingCommittedSelectionOrReplayingOldConfirmation() async throws {
        let f = await fixture()
        f.state.selectGroup("g1")
        f.state.prepareDeletion()
        let old = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        let browsing = f.state.browsingSessionID
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: true, active: false)
        XCTAssertFalse(f.state.displayActive)
        XCTAssertFalse(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertFalse(f.state.canUpdateResults)
        XCTAssertEqual(f.state.selectedIDs, Set(old.revisions.map(\.id)))
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.browsingSessionID, browsing)
        XCTAssertNil(f.state.pendingDeletion)
        f.state.resume() // Foreground alone must not bypass an inactive scene.
        f.state.scan()
        f.state.confirmDeletion(old)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.canBrowse)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.service.readCount, 1)
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: true, active: true)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.state.selectionSessionID, session)
        f.state.prepareDeletion()
        let fresh = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertNotEqual(fresh.id, old.id)
        f.state.confirmDeletion(old)
        XCTAssertEqual(f.state.pendingDeletion?.id, fresh.id, "A late old surface cannot dismiss the fresh confirmation")
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.library.batchReads, 0, "Unchanged inactive/active is not a full background restore")
    }

    func testInactiveAndSourceEventsCannotCancelMutationOrStartConcurrentCleanupWork() async throws {
        let f = await fixture()
        let gate = RefinementMutationGate()
        addTeardownBlock { @MainActor in gate.open() }
        f.deletion.gate = gate
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.confirmDeletion(intent)
        try await reached(gate.entered)
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: true, active: false)
        f.state.photosChanged()
        f.state.indexSourceChanged()
        f.state.resume()
        f.state.scan()
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.state.isDeleting)
        XCTAssertFalse(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.deletion.calls, [intent.revisions])
        XCTAssertEqual(f.service.readCount, 1)
        XCTAssertEqual(f.library.batchReads, 0, "New display checks also wait for the submitted mutation")
        f.state.setAutomaticRefreshDeferred(true)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.deletion.wasCancelled)
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertEqual(f.service.confirmedBaseline, f.service.baseline)
        XCTAssertEqual(f.service.readCount, 1)
        XCTAssertFalse(f.state.canBrowse, "Even a successful late display proof cannot uncover an inactive scene")
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.state.statusNotice, "已删除1张照片")
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: true, active: true)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect, "The survivor projection is display-only until source restore")
    }

    func testPermissionRevocationBlocksCachedDisplayBeforeLifecycleCallbackAndClearsOnCallback() async {
        let f = await fixture()
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        f.library.revoke()
        XCTAssertFalse(f.state.canBrowse, "Cached pixels are never authority to ignore current permission")
        XCTAssertFalse(f.state.canSelect)
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: false)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertNil(f.state.browsingSessionID)
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.service.readCount, 1)
    }

    func testTypedReadRevocationClearsCachedBrowsingAndCancelsLateMetadataProof() async throws {
        for code in [SimilarCleanupDiagnostic.Code.permissionDenied, .photoAccessChanged] {
            let f = await fixture()
            let hold = RefinementMetadataGate()
            addTeardownBlock { hold.open() }
            f.library.setGate(hold)
            f.state.setAutomaticRefreshDeferred(true)
            f.state.pause()
            f.state.resume()
            try await reached(hold.entered)
            let failed = expectation(description: "Typed source revocation published")
            let subscription = f.state.$failureDiagnostic.compactMap { $0 }.prefix(1).sink { _ in failed.fulfill() }
            defer { subscription.cancel() }
            f.service.failure = SimilarCleanupDiagnostic(phase: .photos, code: code)
            f.state.setAutomaticRefreshDeferred(false)
            try await reached(failed)
            XCTAssertTrue(f.state.groups.isEmpty)
            XCTAssertNil(f.state.browsingSessionID)
            XCTAssertFalse(f.state.canBrowse)
            hold.open()
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.state.groups.isEmpty, "An older successful metadata proof cannot resurrect revoked content")
            XCTAssertFalse(f.state.canSelect)
            XCTAssertEqual(f.state.failureDiagnostic?.code, code)
            f.state.resume()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.readCount, 2, "A lifecycle repeat is not a failure retry")
        }
    }

    func testCancelledOldDisplayFailureCannotClearFreshlyPublishedGroups() async throws {
        let f = await fixture()
        let hold = RefinementMetadataGate()
        addTeardownBlock { hold.open() }
        f.library.setGate(hold)
        f.state.setAutomaticRefreshDeferred(true)
        f.state.pause()
        f.state.resume()
        try await reached(hold.entered)
        let published = expectation(description: "Fresh full result published")
        let subscription = f.state.$selectionSessionID.compactMap { $0 }.prefix(1).sink { _ in published.fulfill() }
        defer { subscription.cancel() }
        f.state.setAutomaticRefreshDeferred(false)
        try await reached(published)
        let session = try XCTUnwrap(f.state.selectionSessionID)
        f.library.setDuplicateResponse(true) // Force the superseded metadata operation to fail.
        hold.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.groups.map(\.id), ["g0", "g1"])
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertNil(f.state.failureDiagnostic)
        XCTAssertEqual(f.library.batchReads, 1)
        XCTAssertEqual(f.service.readCount, 2)
    }

    func testRepeatedForegroundEventsCoalesceOneInFlightDisplayCheck() async throws {
        let f = await fixture()
        let hold = RefinementMetadataGate()
        addTeardownBlock { hold.open() }
        f.library.setGate(hold)
        f.state.setAutomaticRefreshDeferred(true)
        f.state.pause()
        f.state.resume()
        try await reached(hold.entered)
        for _ in 0..<5 { f.state.resume(); f.state.availabilityChanged(ready: true) }
        hold.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.library.batchReads, 1)
        XCTAssertEqual(f.service.readCount, 1)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
    }

    func testDisplayCanRecoverWhileWriterHeldWithoutReusingOldIndexOrDeletionAuthority() async throws {
        let access = IndexAccessCoordinator()
        let f = await fixture(indexAccess: access)
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let oldSession = f.state.selectionSessionID
        f.state.pause()
        let writer = try await access.acquireWrite()
        defer { writer.release() }
        let visible = expectation(description: "Lightweight display check does not wait for the index writer")
        let subscription = f.state.$browsingAllowed.dropFirst().filter { $0 }.prefix(1).sink { _ in visible.fulfill() }
        defer { subscription.cancel() }
        f.state.resume()
        try await reached(visible)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.service.readCount, 1, "Full source restore still waits for its read lease")
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        writer.release()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.canSelect)
        XCTAssertNotEqual(f.state.selectionSessionID, oldSession)
        XCTAssertEqual(f.service.readCount, 2)
    }

    func testRevocationClearsRetainedDataAndLateDisplayProofCannotResurrectIt() async throws {
        let f = await fixture()
        let hold = RefinementMetadataGate()
        addTeardownBlock { hold.open() }
        f.library.setGate(hold)
        f.state.setAutomaticRefreshDeferred(true)
        f.state.pause()
        f.state.resume()
        try await reached(hold.entered)
        f.library.revoke()
        f.state.setDisplayEnvironment(foreground: true, protectedDataAvailable: true, canRead: false)
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertNil(f.state.browsingSessionID)
        XCTAssertFalse(f.state.canBrowse)
        hold.open()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.service.readCount, 1)
    }

    func testEditedCreationMissingOrLimitedMemberFailsDisplayAndDoesNotLoop() async {
        for change in 0..<3 {
            let f = await fixture()
            f.state.setAutomaticRefreshDeferred(true)
            f.state.pause()
            f.library.changeFirst(mode: change)
            f.state.resume()
            await f.state.waitUntilIdle()
            XCTAssertFalse(f.state.canBrowse)
            XCTAssertTrue(f.state.groups.isEmpty)
            XCTAssertNil(f.state.browsingSessionID)
            for _ in 0..<3 { f.state.resume(); f.state.availabilityChanged(ready: true) }
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.library.batchReads, 1)
            XCTAssertEqual(f.service.readCount, 1)
            XCTAssertTrue(f.deletion.calls.isEmpty)
        }
    }

    func testLightweightProofCannotBypassSourcePublicationFailure() async {
        let f = await fixture()
        f.service.failure = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceDataVersionChanged)
        f.state.pause()
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canBrowse, "A source-index failure does not revoke independently validated photo display")
        XCTAssertEqual(f.state.groups.map(\.id), ["g0", "g1"])
        XCTAssertTrue(f.state.needsAutomaticRefreshRetry)
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        let reads = f.service.readCount
        for _ in 0..<3 { f.state.resume(); f.state.enterPage(ready: true) }
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.readCount, reads)
    }

    func testSuccessfulDeletionRetainsSurvivorsAndBaselineBeforeAnyNewAuthority() async throws {
        let f = await fixture()
        let browse = f.state.browsingSessionID
        let baseline = f.service.baseline
        f.state.toggleSelection("p0-0")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.confirmDeletion(intent)
        // Admission is blocked only AFTER the immutable intent was submitted.
        f.state.setAutomaticRefreshDeferred(true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.deletion.calls, [intent.revisions])
        XCTAssertEqual(f.service.confirmedBaseline, baseline)
        XCTAssertEqual(f.state.groups.map { $0.photos.count }, [5, 4])
        XCTAssertFalse(f.state.groups.flatMap(\.photos).contains { $0.id == "p0-0" })
        XCTAssertEqual(f.state.browsingSessionID, browse)
        XCTAssertTrue(f.state.canBrowse)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.state.statusNotice, "已删除1张照片")
        XCTAssertNil(f.state.message)
        f.state.showDeletionRecovery()
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        XCTAssertFalse(f.state.message?.contains("手动重新分组") ?? true)
        f.state.dismissMessage()
        f.state.confirmDeletion(intent)
        XCTAssertEqual(f.deletion.calls.count, 1)
    }

    func testTamperedHiddenDisclosureCannotSubmitEvenWithCopiedUUID() async throws {
        let f = await fixture()
        f.state.selectGroup("g1")
        f.state.setMinimumGroupCount(5)
        f.state.prepareDeletion()
        var forged = try XCTUnwrap(f.state.pendingDeletion)
        forged.hiddenPhotoCount = 0
        f.state.confirmDeletion(forged)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
    }

    func testFreshMetadataChecksEpochAuthorizationFullRevisionAndDuplicateResponses() async throws {
        let expected = [PhotoRevision(id: "synthetic", modificationTime: 1, creationTime: 2)]
        let library = RefinementLibrary(expected)
        let access = SimilarCleanupBrowsingAccess(library: library)
        let proof = try await access.check(expected)
        try proof.validate()
        library.changeFirst(mode: 0)
        XCTAssertThrowsError(try proof.validate())
        do { _ = try await access.check(expected); XCTFail("Edited revision accepted") } catch { }
        library.setDuplicateResponse(true)
        do { _ = try await access.check(library.revisions); XCTFail("Duplicate response accepted") } catch { }
        XCTAssertEqual(library.unexpectedCalls, 0)
    }

    func testMissingEpochUsesFreshRevisionFenceInsteadOfTreatingNilAsStable() async throws {
        let library = RefinementLibrary([PhotoRevision(id: "synthetic", modificationTime: 1, creationTime: 2)], hasEpoch: false)
        let proof = try await SimilarCleanupBrowsingAccess(library: library).check(library.revisions)
        library.changeFirst(mode: 1)
        XCTAssertThrowsError(try proof.validate())
    }

    func testMissingEpochProofRechecksPermissionAfterLastLegacyRevisionRead() async throws {
        let library = RefinementLibrary([PhotoRevision(id: "synthetic", modificationTime: 1, creationTime: 2)], hasEpoch: false)
        let proof = try await SimilarCleanupBrowsingAccess(library: library).check(library.revisions)
        library.revokeAfterNextRevisionRead()
        XCTAssertThrowsError(try proof.validate()) { error in
            XCTAssertEqual(error as? PhotoDeletionError, .permissionDenied)
        }
        XCTAssertFalse(library.canReadImages)
        XCTAssertEqual(library.unexpectedCalls, 0)
    }

    func testRecoveryNoticeDisclosesAllMembersHiddenSelectionsAndSystemLimitations() {
        let warning = PhotoDeletionRecoveryNotice.warning(emptiedGroupCount: 2, hiddenGroupCount: 1, hiddenPhotoCount: 4)
        for text in ["2个分组的全部照片", "不保留任何照片", "1组 · 4张", "本次删除", "30天", "提前永久删除", "共享图库", "iCloud"] {
            XCTAssertTrue(warning.contains(text), text)
        }
        XCTAssertFalse(PhotoDeletionRecoveryNotice.success(count: 10).contains("手动重新分组"))
    }

    func testBrowserRetainsRouteAcrossPrivacyAndUnambiguousDeletionReseedingOnly() async throws {
        let f = await fixture()
        let browser = SimilarPhotoGroupBrowser()
        let group = f.state.groups[0]
        browser.open(group: group, photoID: group.photos[2].id, sessionID: try XCTUnwrap(f.state.browsingSessionID))
        let route = try XCTUnwrap(browser.detailRoute)
        browser.viewPhoto(group.photos[2].id, in: group)
        browser.comparisonGroup = group
        browser.hidePrivateSurfaces()
        XCTAssertEqual(browser.detailRoute, route)
        XCTAssertNil(browser.viewer)
        XCTAssertNil(browser.comparisonGroup)
        let reseeded = SimilarPhotoGroup(id: "new-seed", photos: Array(group.photos.dropFirst()), minimumSimilarity: 1)
        browser.reconcile(groups: [reseeded], sessionID: f.state.browsingSessionID)
        XCTAssertEqual(browser.detailRoute?.id, route.id)
        XCTAssertEqual(browser.detailRoute?.groupID, "new-seed")
        XCTAssertEqual(browser.detailRoute?.photoID, route.photoID)
        browser.reconcile(groups: [], sessionID: f.state.browsingSessionID)
        XCTAssertNil(browser.detailRoute)
    }

    private func fixture(sizes: [Int] = [6, 4], indexAccess: IndexAccessCoordinator? = nil) async -> RefinementFixture {
        var groups: [SimilarPhotoGroup] = []
        for (ordinal, count) in sizes.enumerated() {
            var photos: [IndexedPhoto] = []
            for index in 0..<count {
                photos.append(IndexedPhoto(id: "p\(ordinal)-\(index)", modificationTime: 10, modelVersion: "synthetic",
                                           imageEmbedding: TestFixtures.vector(), creationTime: Double(index)))
            }
            groups.append(SimilarPhotoGroup(id: "g\(ordinal)", photos: photos, minimumSimilarity: 1))
        }
        let library = RefinementLibrary(groups.flatMap(\.photos).map {
            PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime)
        })
        let service = RefinementGrouping(groups: groups)
        let deletion = RefinementDeletion(library: library)
        let state = SimilarPhotoCleanupState(grouping: service, deletion: deletion,
                                             indexAccess: indexAccess, browsingAccess: SimilarCleanupBrowsingAccess(library: library))
        state.enterPage(ready: true)
        await state.waitUntilIdle()
        XCTAssertTrue(state.canSelect)
        return RefinementFixture(state: state, service: service, deletion: deletion, library: library)
    }

    private func reached(_ expectation: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [expectation], timeout: 5) == .completed else {
            XCTFail("Missing deterministic metadata milestone")
            throw PhotoDeletionError.accessChanged
        }
    }
}

@MainActor
private struct RefinementFixture {
    let state: SimilarPhotoCleanupState
    let service: RefinementGrouping
    let deletion: RefinementDeletion
    let library: RefinementLibrary
}

@MainActor
private final class RefinementGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    let baseline = UUID()
    var failure: Error?
    private(set) var readCount = 0
    private(set) var confirmedBaseline: UUID?
    init(groups: [SimilarPhotoGroup]) { self.groups = groups }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        readCount += 1
        if let failure { throw failure }
        return .restored(SimilarPhotoGroupingResult(groups: groups,
            candidateCount: groups.reduce(0) { $0 + $1.photos.count }, staleCount: 0, unindexedCount: 0,
            threshold: threshold, deletionBaselineID: baseline))
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        XCTFail("Synthetic restored result must not recompute")
        throw PhotoDeletionError.accessChanged
    }
    func confirmedDeletion(revisions: [PhotoRevision], baselineID: UUID?) async { confirmedBaseline = baselineID }
}

@MainActor
private final class RefinementDeletion: PhotoDeleting {
    let library: RefinementLibrary
    var gate: RefinementMutationGate?
    private(set) var wasCancelled = false
    private(set) var calls: [[PhotoRevision]] = []
    init(library: RefinementLibrary) { self.library = library }
    func delete(revisions: [PhotoRevision]) async throws {
        calls.append(revisions)
        await gate?.wait()
        wasCancelled = Task.isCancelled
        library.remove(Set(revisions.map(\.id)))
    }
}

@MainActor
private final class RefinementMutationGate {
    let entered = XCTestExpectation(description: "Synthetic mutation entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

/// The lock also covers counters/epoch. The optional test semaphore blocks ONLY
/// the off-main metadata callback and is always released by test teardown.
final class RefinementLibrary: PhotoLibraryIndexing, PhotoRevisionBatchReading, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PhotoRevision]
    private var readable = true
    private var authorization = 3
    private var epoch: UInt64 = 0
    private let hasEpoch: Bool
    private var reads = 0
    private var duplicates = false
    private var revokeAfterRead = false
    private var gate: RefinementMetadataGate?
    private var unexpected = 0
    init(_ revisions: [PhotoRevision], hasEpoch: Bool = true) { stored = revisions; self.hasEpoch = hasEpoch }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var revisions: [PhotoRevision] { locked { stored } }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { hasEpoch ? epoch : nil } }
    var batchReads: Int { locked { reads } }
    var unexpectedCalls: Int { locked { unexpected } }
    func setGate(_ value: RefinementMetadataGate) { locked { gate = value } }
    func setDuplicateResponse(_ value: Bool) { locked { duplicates = value } }
    func revokeAfterNextRevisionRead() { locked { revokeAfterRead = true } }
    func revoke() { locked { readable = false; authorization = 2; epoch += 1 } }
    func remove(_ ids: Set<String>) { locked { stored.removeAll { ids.contains($0.id) }; epoch += 1 } }
    func changeFirst(mode: Int) {
        locked {
            guard let old = stored.first else { return }
            if mode == 2 { stored.removeFirst(); authorization = 4 }
            else { stored[0] = PhotoRevision(id: old.id, modificationTime: old.modificationTime + (mode == 0 ? 1 : 0),
                                             creationTime: mode == 1 ? nil : old.creationTime) }
            epoch += 1
        }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        locked {
            let revision = readable ? stored.first { $0.id == id } : nil
            if revokeAfterRead {
                revokeAfterRead = false
                readable = false
                authorization = 2
                epoch += 1
            }
            return revision
        }
    }
    func currentRevisions(ids: [String]) throws -> [PhotoRevision] {
        XCTAssertFalse(Thread.isMainThread, "Fresh batch must not block UI")
        let gate = locked { reads += 1; return self.gate }
        gate?.wait()
        return locked {
            let result = readable ? stored.filter { ids.contains($0.id) } : []
            return duplicates ? result + result : result
        }
    }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        locked { unexpected += 1 }; XCTFail("Display check must not enumerate the whole library")
        throw PhotoDeletionError.accessChanged
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { locked { unexpected += 1 }; return nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { unexpected += 1 }; XCTFail("Display check must never request pixels")
        throw PhotoDeletionError.accessChanged
    }
}

final class RefinementMetadataGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Fresh metadata read entered")
    private let condition = NSCondition()
    private var released = false
    private var announced = false
    func wait() {
        condition.lock()
        if !announced { announced = true; entered.fulfill() }
        while !released { condition.wait() }
        condition.unlock()
    }
    func open() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}