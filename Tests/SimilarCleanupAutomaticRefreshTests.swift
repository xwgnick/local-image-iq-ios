import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Model-free controller tests. Only synthetic revisions/results, isolated
/// preferences and continuation milestones; no Photos, SQL, network or sleeps.
@MainActor
final class SimilarCleanupAutomaticRefreshTests: XCTestCase {
    func testStartupSourcesAndCommittedReleaseWaitForFirstReadyPageEntry() async throws {
        let defaults = try preferences()
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, preferences: defaults)
        f.state.setAutomaticRefreshDeferred(true)
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        f.state.invalidateAccess()
        f.state.setDraftThreshold(0.76)
        f.state.commitDraftThreshold()
        f.state.availabilityChanged(ready: true)
        f.state.pause()
        f.state.resume()
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertEqual(f.state.threshold, 0.90)
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 90)
        f.state.enterPage(ready: false)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.thresholds, [0.76, 0.76])
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 76)
        XCTAssertTrue(f.state.canSelect)
    }

    func testFirstEntryStaleDiskRestoresThenComputesAutomaticallyExactlyOnce() async {
        let f = fixture(service: RefreshGrouping(restore: { _, _ in .stale }))
        await enter(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.entryThreads, [false, false])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertFalse(f.state.canRetryAutomaticRefresh)
        f.state.enterPage(ready: true)
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        f.state.commitDraftThreshold()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testDeferredIndexBurstDoesNoReadsThenComputesSingleLatestRevision() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: RefreshGrouping(group: { _, threshold in
            refreshResult(threshold, count: Int(access.revision) + 2)
        }))
        await enter(f.state)
        let oldSession = f.state.selectionSessionID
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.setAutomaticRefreshDeferred(true)
        for _ in 0..<4 {
            let writer = try await access.acquireWrite()
            f.state.indexSourceChanged()
            writer.release()
            f.state.indexSourceChanged() // Same revision delivered again.
            f.state.setAutomaticRefreshDeferred(true)
            f.state.availabilityChanged(ready: true)
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
            assertBrowsingWithoutAuthority(f.state)
        }
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.state.candidateCount, 2, "Old browsing counts are not relabeled as the newest source")
        f.state.setAutomaticRefreshDeferred(false)
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "group"])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
        XCTAssertEqual(f.state.candidateCount, 6)
        XCTAssertNotEqual(f.state.selectionSessionID, oldSession)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.indexSourceChanged()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events.count, 4)
    }

    func testThresholdEditsBlockSelectionAndReleaseUpdatesOnceAtLatestValue() async throws {
        let defaults = try preferences()
        let f = fixture(preferences: defaults)
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        for value: Float in [0.88, 0.82, 0.73] {
            f.state.setDraftThreshold(value)
            XCTAssertFalse(f.state.canSelect)
            XCTAssertNil(f.state.pendingDeletion)
            f.state.toggleSelection("b")
            f.state.selectGroup("pair")
            f.state.confirmDeletion(intent)
            XCTAssertNil(f.state.beginRangeSelection(groupID: "pair"))
        }
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.state.selectedIDs, ["a"], "A draft blocks use but does not itself change committed selection")
        XCTAssertEqual(f.state.threshold, 0.90)
        XCTAssertEqual(f.state.resultThreshold, 0.90)
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 90)
        f.state.commitDraftThreshold()
        assertBrowsingWithoutAuthority(f.state)
        f.state.commitDraftThreshold()
        await f.state.waitUntilIdle()
        f.state.commitDraftThreshold()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90, 0.73, 0.73])
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 73)
        XCTAssertEqual(f.state.resultThreshold, 0.73)
        XCTAssertFalse(f.state.hasPendingThresholdChange)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testDeferredReleasedThresholdsOnlyApplyAndPersistLatestEligibleTarget() async throws {
        let defaults = try preferences()
        let f = fixture(preferences: defaults)
        await enter(f.state)
        f.state.setAutomaticRefreshDeferred(true)
        for value: Float in [0.84, 0.79, 0.68] {
            f.state.setDraftThreshold(value)
            f.state.commitDraftThreshold()
            f.state.commitDraftThreshold()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.state.threshold, 0.90)
            XCTAssertEqual(f.state.resultThreshold, 0.90)
            XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 90)
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        }
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90, 0.68, 0.68])
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 68)
        XCTAssertTrue(f.state.canSelect)
    }

    func testLatestReleaseWaitsForCancelledReadAndEntireQueuedLegacyTail() async throws {
        for failsOld in [false, true] {
            let old = hold()
            let defaults = try preferences()
            let f = fixture(preferences: defaults, service: RefreshGrouping(group: { call, threshold in
                if call == 0 {
                    await old.wait()
                    if failsOld { throw RefreshError.failed }
                    return refreshResult(threshold, count: 999)
                }
                return refreshResult(threshold, count: 7)
            }))
            f.state.enterPage(ready: true)
            try await reached(old.entered)
            f.state.scan()
            f.state.scan() // A cancelled queued replacement still owns its predecessor.
            f.state.indexSourceChanged()
            f.state.setDraftThreshold(0.84)
            f.state.commitDraftThreshold()
            f.state.setDraftThreshold(0.72)
            f.state.commitDraftThreshold()
            f.state.indexSourceChanged()
            XCTAssertTrue(old.cancelled)
            XCTAssertTrue(f.state.isReadDraining)
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
            XCTAssertEqual(f.state.threshold, 0.90)
            XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 90)
            let joined = expectation(description: "Idle waiter joined cancelled tail")
            var finished = false
            let waiter = Task { @MainActor in
                joined.fulfill()
                await f.state.waitUntilIdle()
                finished = true
            }
            try await reached(joined)
            XCTAssertFalse(finished)
            old.open()
            await waiter.value
            XCTAssertTrue(finished)
            XCTAssertFalse(f.state.isReadDraining)
            XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "group"])
            XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90, 0.72, 0.72])
            XCTAssertEqual(f.service.trace.maximumActive, 1)
            XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 72)
            XCTAssertEqual(f.state.candidateCount, 7)
            XCTAssertEqual(f.state.progress.total, 7, "Late progress from the cancelled 999-candidate read is rejected")
            XCTAssertTrue(f.state.canSelect)
            XCTAssertNil(f.state.failureDiagnostic)
            XCTAssertNil(f.state.message)
        }
    }

    func testNewDraftSupersedesQueuedReleaseButWaitsForItsOwnReleaseAfterDrain() async throws {
        let old = hold()
        let defaults = try preferences()
        let f = fixture(preferences: defaults, service: RefreshGrouping(group: { call, threshold in
            if call == 0 { await old.wait() }
            return refreshResult(threshold)
        }))
        f.state.enterPage(ready: true)
        try await reached(old.entered)
        f.state.setDraftThreshold(0.82)
        f.state.commitDraftThreshold()
        f.state.setDraftThreshold(0.74)
        old.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.state.threshold, 0.90)
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 90)
        XCTAssertFalse(f.state.canSelect)
        f.state.commitDraftThreshold()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90, 0.74, 0.74])
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 74)
        XCTAssertTrue(f.state.canSelect)
    }

    func testHiddenBackgroundAndNotReadyChangesWaitThenRefreshFreshOnReturn() async {
        let f = fixture()
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.leavePage()
        f.state.indexSourceChanged()
        assertBrowsingWithoutAuthority(f.state)
        f.state.pause()
        f.state.invalidateAccess()
        f.state.setDraftThreshold(0.78)
        f.state.commitDraftThreshold()
        f.state.enterPage(ready: false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.state.threshold, 0.95)
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.95, 0.95, 0.78, 0.78])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
    }

    func testFailureAndSelfCancellationNeverRetryOnRepeatedReadyAndAllowExplicitRetry() async {
        for cancelled in [false, true] {
            let access = IndexAccessCoordinator()
            let f = fixture(access: access, service: RefreshGrouping(group: { call, threshold in
                if call == 0 {
                    if cancelled { throw CancellationError() }
                    throw RefreshError.failed
                }
                return refreshResult(threshold)
            }))
            await enter(f.state)
            XCTAssertTrue(f.state.needsAutomaticRefreshRetry)
            XCTAssertEqual(f.state.failureDiagnostic == nil, cancelled)
            XCTAssertFalse(f.state.canSelect)
            await repeatNonEvents(f.state)
            f.state.indexSourceChanged() // Already observed revision, not a new event.
            f.state.commitDraftThreshold() // Releasing the same value is not a retry.
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
            XCTAssertTrue(f.state.canRetryAutomaticRefresh)
            f.state.retryAutomaticRefresh()
            f.state.retryAutomaticRefresh()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "group"])
            XCTAssertFalse(f.state.needsAutomaticRefreshRetry)
            XCTAssertTrue(f.state.canSelect)
        }
    }

    func testUserCancelSurvivesDrainAndLifecycleUntilExplicitRetry() async throws {
        let old = hold()
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: RefreshGrouping(restore: { call, _ in
            if call == 0 { await old.wait() }
            return .stale
        }))
        f.state.enterPage(ready: true)
        try await reached(old.entered)
        f.state.cancelAutomaticRefresh()
        XCTAssertTrue(old.cancelled)
        XCTAssertTrue(f.state.isReadDraining)
        XCTAssertFalse(f.state.canRetryAutomaticRefresh)
        f.state.availabilityChanged(ready: false)
        f.state.availabilityChanged(ready: true)
        f.state.leavePage()
        f.state.enterPage(ready: true)
        f.state.indexSourceChanged()
        old.open()
        await f.state.waitUntilIdle()
        await repeatNonEvents(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        XCTAssertFalse(f.state.isReadDraining)
        XCTAssertTrue(f.state.canRetryAutomaticRefresh)
        XCTAssertNil(f.state.message)
        XCTAssertFalse(f.state.hasScanned)
        f.state.retryAutomaticRefresh()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "restore", "group"])
        XCTAssertTrue(f.state.canSelect)
    }

    func testActualIndexOrThresholdEventRearmsSuppressionButDuplicateRevisionDoesNot() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: RefreshGrouping(group: { call, threshold in
            if call < 2 { throw CancellationError() }
            return refreshResult(threshold)
        }))
        await enter(f.state)
        f.state.indexSourceChanged()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events.count, 2)
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events.count, 4)
        XCTAssertTrue(f.state.canRetryAutomaticRefresh)
        f.state.indexSourceChanged()
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events.count, 4)
        f.state.setDraftThreshold(0.79)
        f.state.commitDraftThreshold()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.95, 0.95, 0.95, 0.95, 0.79, 0.79])
        XCTAssertTrue(f.state.canSelect)
    }

    func testSourceEventImmediatelyRevokesAllSelectionAndImmutableConfirmation() async throws {
        let f = fixture(service: RefreshGrouping(restore: { _, threshold in
            .restored(refreshResult(threshold))
        }))
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        let range = try XCTUnwrap(f.state.beginRangeSelection(groupID: "pair"))
        f.state.setAutomaticRefreshDeferred(true)
        f.state.invalidateAccess()
        XCTAssertTrue(f.state.groups.isEmpty, "Access invalidation removes old Photos content, not merely selection")
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertFalse(f.state.canSelect)
        f.state.toggleSelection("a")
        f.state.selectGroup("pair")
        f.state.prepareDeletion()
        f.state.confirmDeletion(intent)
        f.state.finishRangeSelection(token: range, selectedInGroup: ["a", "b"])
        XCTAssertNil(f.state.beginRangeSelection(groupID: "pair"))
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"], "Matching cache rebinds validators, not old authority")
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testDeletionIsNeverCancelledAndRefreshWaitsForActualMutationCompletion() async throws {
        for outcome in 0..<3 {
            let mutation = hold()
            let deletion = RefreshDeletion { _ in
                await mutation.wait()
                if outcome == 1 { throw PhotoDeletionError.mutationFailed }
                if outcome == 2 { throw CancellationError() }
            }
            let f = fixture(service: RefreshGrouping(group: { call, threshold in
                XCTAssertFalse(deletion.isActive, "No grouping may enter while the real write is active")
                return refreshResult(threshold, empty: call > 0)
            }), deletion: deletion)
            await enter(f.state)
            f.state.toggleSelection("a")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            f.state.confirmDeletion(intent)
            f.state.confirmDeletion(intent)
            try await reached(mutation.entered)
            f.state.setAutomaticRefreshDeferred(true)
            f.state.indexSourceChanged()
            f.state.invalidateAccess()
            f.state.cancelAutomaticRefresh() // Stops pending reads only, never the mutation.
            f.state.leavePage()
            f.state.pause()
            f.state.setDraftThreshold(0.75)
            f.state.commitDraftThreshold()
            XCTAssertEqual(f.state.draftThreshold, 0.95)
            f.state.resume()
            f.state.enterPage(ready: true)
            f.state.setAutomaticRefreshDeferred(false)
            f.state.indexSourceChanged()
            f.state.scan()
            XCTAssertTrue(f.state.isDeleting)
            XCTAssertFalse(mutation.cancelled)
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
            let joined = expectation(description: "Idle waiter joined independent mutation")
            var finished = false
            let waiter = Task { @MainActor in
                joined.fulfill()
                await f.state.waitUntilIdle()
                finished = true
            }
            try await reached(joined)
            XCTAssertFalse(finished)
            mutation.open()
            await waiter.value
            XCTAssertTrue(finished)
            XCTAssertFalse(mutation.cancelled)
            XCTAssertEqual(deletion.calls, [intent.revisions])
            XCTAssertFalse(f.state.isDeleting)
            XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "group"])
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertTrue(f.state.groups.isEmpty)
            XCTAssertTrue(f.state.selectedIDs.isEmpty)
            XCTAssertNil(f.state.pendingDeletion)
            let expected: String? = outcome == 0 ? nil
                : outcome == 1 ? PhotoDeletionError.mutationFailed.localizedDescription
                : PhotoDeletionError.cancelled.localizedDescription
            XCTAssertEqual(f.state.message, expected)
            if outcome == 0 { XCTAssertEqual(f.state.statusNotice, "已删除1张照片") }
        }
    }

    func testSyncCheckingCancelsReadAndCoalescesUntilCancellingHasDrained() async throws {
        let old = hold()
        let f = fixture(service: RefreshGrouping(group: { call, threshold in
            if call == 0 { await old.wait() }
            return refreshResult(threshold)
        }))
        f.state.enterPage(ready: true)
        try await reached(old.entered)
        f.state.setAutomaticRefreshDeferred(true)
        XCTAssertTrue(old.cancelled)
        for _ in 0..<4 {
            f.state.indexSourceChanged()
            f.state.invalidateAccess()
            f.state.setAutomaticRefreshDeferred(true)
        }
        old.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertTrue(f.state.isAutomaticRefreshDeferred)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertFalse(f.state.needsAutomaticRefreshRetry, "Sync suspension is not explicit user cancellation")
        f.state.setAutomaticRefreshDeferred(false)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "group"])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
        XCTAssertTrue(f.state.canSelect)
    }

    func testSourceDuringPublicationDrainsValidatorBeforeStartingLatestRestore() async throws {
        let validation = RefreshValidationGate()
        addTeardownBlock { validation.open() }
        let f = fixture(service: RefreshGrouping(restore: { call, threshold in
            if call == 0 {
                return .restored(refreshResult(threshold, count: 999, access: { try validation.wait() }))
            }
            XCTAssertTrue(validation.didReturn, "The whole publication validator must drain before replacement")
            return .stale
        }, group: { _, threshold in refreshResult(threshold, count: 7) }))
        f.state.enterPage(ready: true)
        try await reached(validation.entered)
        XCTAssertTrue(f.state.isValidating)
        f.state.invalidateAccess()
        f.state.setDraftThreshold(0.83)
        f.state.commitDraftThreshold()
        XCTAssertTrue(f.state.isReadDraining)
        XCTAssertFalse(f.state.isValidating)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        XCTAssertFalse(f.state.canSelect)
        validation.open()
        await f.state.waitUntilIdle()
        XCTAssertTrue(validation.returnedCancelled)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore", "group"])
        XCTAssertEqual(f.service.trace.thresholds, [0.95, 0.83, 0.83])
        XCTAssertEqual(f.state.candidateCount, 7)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertNil(f.state.failureDiagnostic)
    }

    func testFailedWriterWithoutCallbackIsDetectedWhenSyncDeferralEnds() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: RefreshGrouping(restore: { _, threshold in
            .restored(refreshResult(threshold))
        }))
        await enter(f.state)
        f.state.toggleSelection("a")
        let session = f.state.selectionSessionID
        f.state.setAutomaticRefreshDeferred(true)
        let writer = try await access.acquireWrite()
        writer.release() // A rolled-back writer advances revision without a commit notification.
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore"])
        XCTAssertFalse(f.state.canSelect)
        f.state.setAutomaticRefreshDeferred(false)
        assertBrowsingWithoutAuthority(f.state)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertTrue(f.state.canSelect)
        f.state.indexSourceChanged()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
    }

    func testFailedSourceRefreshKeepsBrowsingButNeverReenablesOldAuthorityOnReady() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: RefreshGrouping(restore: { call, threshold in
            if call == 0 { return .missing }
            if call == 1 { throw RefreshError.failed }
            return .restored(refreshResult(threshold, count: 3))
        }))
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        await f.state.waitUntilIdle()
        assertBrowsingWithoutAuthority(f.state)
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertTrue(f.state.canRetryAutomaticRefresh)
        XCTAssertNotNil(f.state.failureDiagnostic)
        for _ in 0..<3 {
            f.state.availabilityChanged(ready: false)
            f.state.availabilityChanged(ready: true)
            f.state.setAutomaticRefreshDeferred(true)
            f.state.setAutomaticRefreshDeferred(false)
            f.state.indexSourceChanged()
            f.state.commitDraftThreshold()
            f.state.dismissMessage()
            f.state.toggleSelection("a")
            f.state.prepareDeletion()
            f.state.confirmDeletion(intent)
            await f.state.waitUntilIdle()
            assertBrowsingWithoutAuthority(f.state)
        }
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.retryAutomaticRefresh()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore", "restore"])
        XCTAssertEqual(f.state.candidateCount, 3)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    // MARK: Deterministic fixtures (timeouts bound test expectations only)

    private func fixture(access: IndexAccessCoordinator? = nil, preferences: UserDefaults? = nil,
                         service: RefreshGrouping = RefreshGrouping(), deletion: RefreshDeletion = RefreshDeletion()) -> RefreshFixture {
        RefreshFixture(state: SimilarPhotoCleanupState(grouping: service, deletion: deletion,
            preferences: preferences, indexAccess: access), service: service, deletion: deletion)
    }

    private func preferences() throws -> UserDefaults {
        let name = "SimilarCleanupAutomaticRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(90, forKey: SimilarCleanupPreferences.thresholdKey)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func enter(_ state: SimilarPhotoCleanupState) async {
        state.enterPage(ready: true)
        await state.waitUntilIdle()
    }

    private func repeatNonEvents(_ state: SimilarPhotoCleanupState) async {
        for _ in 0..<3 {
            state.availabilityChanged(ready: false)
            state.availabilityChanged(ready: true)
            state.leavePage()
            state.enterPage(ready: true)
            state.pause()
            state.resume()
            state.setAutomaticRefreshDeferred(true)
            state.setAutomaticRefreshDeferred(false)
            state.dismissMessage()
        }
        await state.waitUntilIdle()
    }

    private func assertBrowsingWithoutAuthority(_ state: SimilarPhotoCleanupState,
                                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.hasScanned, file: file, line: line)
        XCTAssertEqual(state.groups.map(\.id), ["pair"], file: file, line: line)
        XCTAssertEqual(state.displayGroups.map(\.id), ["pair"], file: file, line: line)
        XCTAssertNotNil(state.resultThreshold, file: file, line: line)
        XCTAssertNotNil(state.selectionSessionID, "Presentation identity survives index-only changes", file: file, line: line)
        XCTAssertFalse(state.canSelect, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
    }

    private func hold() -> RefreshGate {
        let gate = RefreshGate()
        addTeardownBlock { gate.open() }
        return gate
    }

    private func reached(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Missing deterministic milestone: \(event.expectationDescription)")
            throw RefreshError.missingEvent
        }
    }
}

private struct RefreshFixture {
    let state: SimilarPhotoCleanupState
    let service: RefreshGrouping
    let deletion: RefreshDeletion
}

private enum RefreshError: Error { case failed, missingEvent, mainThread }

private func refreshResult(_ threshold: Float, count: Int = 2, empty: Bool = false,
                           access: @escaping @Sendable () throws -> Void = {}) -> SimilarPhotoGroupingResult {
    let photos = ["a", "b"].map {
        IndexedPhoto(id: $0, modificationTime: 41, modelVersion: "synthetic-automatic-refresh",
                     imageEmbedding: [1] + [Float](repeating: 0, count: 767), creationTime: 13)
    }
    let groups = empty ? [] : [SimilarPhotoGroup(id: "pair", photos: photos, minimumSimilarity: 1)]
    return SimilarPhotoGroupingResult(groups: groups, candidateCount: empty ? 0 : count,
        staleCount: 0, unindexedCount: 0, threshold: threshold, validateAccess: access)
}

private final class RefreshGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    typealias Restore = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingRestore
    typealias Group = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingResult
    struct Trace {
        var events: [String] = []
        var thresholds: [Float] = []
        var entryThreads: [Bool] = []
        var restores = 0
        var groups = 0
        var active = 0
        var maximumActive = 0
    }
    private let lock = NSLock()
    private var recorded = Trace()
    private let restoreOperation: Restore
    private let groupOperation: Group

    init(restore: @escaping Restore = { _, _ in .missing },
         group: @escaping Group = { _, threshold in refreshResult(threshold) }) {
        restoreOperation = restore
        groupOperation = group
    }

    var trace: Trace { locked { recorded } }

    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        let call = begin("restore", threshold: threshold)
        defer { locked { recorded.active -= 1 } }
        return try await restoreOperation(call, threshold)
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        let call = begin("group", threshold: threshold)
        defer { locked { recorded.active -= 1 } }
        let result = try await groupOperation(call, threshold)
        // Even an uncooperative cancelled service may deliver a late progress
        // callback; the controller must reject it along with its late result.
        await progress(SimilarPhotoGroupingProgress(total: result.candidateCount,
            completed: result.candidateCount, groupCount: result.groups.count))
        return result
    }

    private func begin(_ event: String, threshold: Float) -> Int {
        locked {
            let call: Int
            if event == "restore" { call = recorded.restores; recorded.restores += 1 }
            else { call = recorded.groups; recorded.groups += 1 }
            recorded.events.append(event)
            recorded.thresholds.append(threshold)
            recorded.entryThreads.append(Thread.isMainThread)
            recorded.active += 1
            recorded.maximumActive = max(recorded.maximumActive, recorded.active)
            return call
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class RefreshDeletion: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PhotoRevision]] = []
    private var active = false
    private let operation: @Sendable ([PhotoRevision]) async throws -> Void
    init(_ operation: @escaping @Sendable ([PhotoRevision]) async throws -> Void = { _ in }) {
        self.operation = operation
    }
    var calls: [[PhotoRevision]] { locked { recorded } }
    var isActive: Bool { locked { active } }
    func delete(revisions: [PhotoRevision]) async throws {
        locked { recorded.append(revisions); active = true }
        defer { locked { active = false } }
        try await operation(revisions)
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class RefreshGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Held read or mutation callback entered")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var cancellationObserved = false
    var cancelled: Bool { locked { cancellationObserved } }
    func wait() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { install($0) }
        }, onCancel: { self.locked { self.cancellationObserved = true } })
    }
    func open() {
        let pending = locked {
            opened = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume()
    }
    private func install(_ value: CheckedContinuation<Void, Never>) {
        let ready = locked {
            if !opened { continuation = value }
            return opened
        }
        entered.fulfill()
        if ready { value.resume() }
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class RefreshValidationGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Held publication validator entered")
    private let condition = NSCondition()
    private var opened = false
    private var returned = false
    private var cancelled = false
    var didReturn: Bool {
        condition.lock(); defer { condition.unlock() }
        return returned
    }
    var returnedCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return cancelled
    }
    func wait() throws {
        entered.fulfill()
        guard !Thread.isMainThread else { throw RefreshError.mainThread }
        condition.lock()
        while !opened { condition.wait() }
        cancelled = Task.isCancelled
        returned = true
        condition.unlock()
    }
    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}