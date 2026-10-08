import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Controller contracts only. Backend cache/SQLite integration lives in
/// SimilarGroupingReuseTests. These synthetic services never touch Photos,
/// models, indexing, OCR, real deletion, network or standard UserDefaults.
@MainActor
final class SimilarCleanupAutomaticEntryTests: XCTestCase {
    func testInitializationDoesNoWorkAndUsesApprovedDefault() async {
        let f = fixture()
        XCTAssertEqual(f.state.threshold, 0.90)
        XCTAssertFalse(f.state.isPageVisible)
        XCTAssertFalse(f.state.isRestoring)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.canChangeThreshold)
        XCTAssertFalse(f.state.canSelect)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testDefaultSearchStartupReadinessAndResumeDoNotReadWithoutPageEntry() async {
        let f = fixture()
        f.state.availabilityChanged(ready: true)
        f.state.invalidateAccess()
        f.state.pause()
        f.state.resume()
        f.state.availabilityChanged(ready: false)
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertFalse(f.state.isPageVisible)
    }

    func testFirstReadyEntryRestoresThenGroupsExactlyOnce() async {
        let f = fixture()
        f.state.enterPage(ready: true)
        XCTAssertTrue(f.state.isPageVisible)
        XCTAssertTrue(f.state.isRestoring)
        XCTAssertFalse(f.state.isGrouping)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90])
        XCTAssertEqual(f.service.trace.entryThreads, [false, false])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.canSelect)
        f.state.enterPage(ready: true)
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testPermissionModelIndexAndBusyReadinessWaitForFirstTrue() async {
        // The UI combines each of these prerequisites into the same Bool.
        for prerequisite in ["permission", "models", "index statistics", "search", "image indexing", "OCR"] {
            let f = fixture()
            f.state.enterPage(ready: false)
            f.state.availabilityChanged(ready: false)
            f.state.resume()
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.service.trace.events.isEmpty, prerequisite)
            XCTAssertFalse(f.state.canSelect)
            f.state.availabilityChanged(ready: true)
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["restore", "group"], prerequisite)
        }
    }

    func testEnteringWhileBackgroundDoesNotResumeForegroundImplicitly() async {
        let f = fixture()
        f.state.pause()
        f.state.enterPage(ready: true)
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.isPageVisible)
        XCTAssertTrue(f.service.trace.events.isEmpty)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testReadinessWhileHiddenDefersUnconsumedFirstAttemptUntilEntry() async {
        let f = fixture()
        f.state.enterPage(ready: false)
        f.state.leavePage()
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testDuplicateEntriesDuringRestoreNeverQueueDuplicates() async throws {
        let gate = hold()
        let f = fixture(restore: { _, _ in await gate.wait(); return .missing })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        for _ in 0..<4 {
            f.state.enterPage(ready: true)
            f.state.availabilityChanged(ready: true)
            f.state.resume()
        }
        XCTAssertEqual(f.service.trace.events, ["restore"])
        XCTAssertTrue(f.state.isRestoring)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
    }

    func testDuplicateEntriesDuringComputeNeverQueueDuplicates() async throws {
        let gate = hold()
        let f = fixture(group: { _, threshold in await gate.wait(); return automaticResult(threshold) })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        XCTAssertFalse(f.state.isRestoring)
        XCTAssertTrue(f.state.isGrouping)
        f.state.enterPage(ready: true)
        f.state.availabilityChanged(ready: true)
        XCTAssertFalse(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testLeavingRestoreCancelsAndRejectsLateResultThenOnlyRestoresOnReturn() async throws {
        let gate = hold()
        let f = fixture(restore: { index, threshold in
            if index == 0 { await gate.wait() }
            return .restored(automaticResult(threshold))
        })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        f.state.leavePage()
        XCTAssertTrue(gate.cancelled)
        XCTAssertFalse(f.state.isRestoring)
        XCTAssertFalse(f.state.isPageVisible)
        gate.open()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
    }

    func testLeavingComputeCancelsAndMissingOnReturnRequiresManualRegroup() async throws {
        let gate = hold()
        let f = fixture(group: { _, threshold in await gate.wait(); return automaticResult(threshold) })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        f.state.leavePage()
        XCTAssertTrue(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.needsRegroup)
        assertUnknown(f.state)
        f.state.leavePage()
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
    }

    func testTabRoundTripPreservesCompletedSessionAndCommittedSelectionNotConfirmation() async throws {
        let f = fixture()
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let oldIntent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        f.state.leavePage()
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertTrue(f.state.hasScanned)
        // Busy search while hidden is not an input invalidation.
        f.state.availabilityChanged(ready: false)
        f.state.availabilityChanged(ready: true)
        f.state.enterPage(ready: true)
        f.state.confirmDeletion(oldIntent)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.state.groups.map(\.id), ["pair"])
        XCTAssertTrue(f.state.canSelect)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testLeaveCancelsUncommittedRangeValidationButDrainsAndKeepsCommittedSelection() async throws {
        let validation = AutomaticValidation(blockPhotos: true)
        addTeardownBlock { validation.release() }
        let f = fixture(restore: { _, threshold in .restored(automaticResult(threshold, validation: validation)) })
        await enter(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "pair"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["b"])
        try await reached(validation.entered)
        XCTAssertTrue(f.state.isValidatingSelection)
        f.state.leavePage()
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertFalse(f.state.isValidatingSelection)
        XCTAssertTrue(f.state.hasScanned)
        let joined = expectation(description: "selection waiter started")
        var finished = false
        let waiter = Task { @MainActor in joined.fulfill(); await f.state.waitUntilIdle(); finished = true }
        try await reached(joined)
        XCTAssertFalse(finished)
        f.state.enterPage(ready: true)
        validation.release()
        await waiter.value
        XCTAssertTrue(finished)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.service.trace.events, ["restore"])
    }

    func testFailedOrSelfCancelledComputeDoesNotLoopOnEntryReadinessOrResume() async {
        for cancellation in [false, true] {
            let f = fixture(group: { _, _ in
                if cancellation { throw CancellationError() }
                throw automaticPrivateError()
            })
            await enter(f.state)
            assertUnknown(f.state)
            if cancellation {
                XCTAssertNil(f.state.message)
                XCTAssertNil(f.state.failureDiagnostic)
                XCTAssertNil(f.state.failureOperation)
            } else {
                assertFailure(f.state, code: .unknown, phase: .compute, operation: .group,
                              reason: "原因尚未确定")
            }
            await exerciseLifecycle(f.state)
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        }
    }

    func testPermissionOrOtherRestoreFailureIsNotMissingAndDoesNotRetryAutomatically() async {
        for permission in [false, true] {
            let f = fixture(restore: { _, _ in
                if permission { throw AppFailure.permission }
                throw automaticPrivateError()
            })
            await enter(f.state)
            // This injected restore has no service phase; State knows only the Photos boundary.
            assertFailure(f.state, code: permission ? .permissionDenied : .unknown,
                          phase: .photos, operation: .restore,
                          reason: permission ? "系统设置" : "原因尚未确定")
            XCTAssertFalse(f.state.message?.contains("private") ?? true)
            assertUnknown(f.state)
            await exerciseLifecycle(f.state)
            XCTAssertEqual(f.service.trace.events, ["restore"])
            f.state.scan() // Explicit retry is still permitted.
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        }
    }

    func testCorruptOrStaleCacheRequiresManualRegroupWithoutAutomaticComputation() async {
        // The backend maps corrupt binary cache data to .stale, not .missing.
        let f = fixture(restore: { _, _ in .stale })
        await enter(f.state)
        assertUnknown(f.state)
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertFalse(f.state.canSelect)
        await exerciseLifecycle(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        f.state.scan()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testRestoredResultPublishesExactCountsAndUsesFreshValidatorsWithoutGrouping() async {
        let validation = AutomaticValidation()
        let f = fixture(restore: { _, threshold in
            .restored(automaticResult(threshold, candidateCount: 9, staleCount: 2, unindexedCount: 4, validation: validation))
        })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.state.candidateCount, 9)
        XCTAssertEqual(f.state.staleCount, 2)
        XCTAssertEqual(f.state.unindexedCount, 4)
        XCTAssertEqual(validation.trace.accessThreads, [false])
        XCTAssertEqual(validation.trace.epochThreads, [true])
        f.state.toggleSelection("b")
        XCTAssertEqual(validation.trace.photoIDs, [["b"]])
        XCTAssertEqual(f.state.selectedIDs, ["b"])
        XCTAssertEqual(f.service.trace.events, ["restore"])
    }

    func testRestoredZeroCountsAreCompletedAndNeverTreatedAsFirstMissingCache() async {
        let f = fixture(restore: { _, threshold in
            .restored(automaticResult(threshold, empty: true, candidateCount: 0))
        })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertEqual(f.state.candidateCount, 0)
        XCTAssertEqual(f.state.staleCount, 0)
        XCTAssertEqual(f.state.unindexedCount, 0)
        f.state.leavePage()
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertEqual(f.service.trace.events, ["restore"])
    }

    func testComputedZeroGroupsAreCompletedAndNotRepeatedOnTabEntry() async {
        let f = fixture(group: { _, threshold in automaticResult(threshold, empty: true, candidateCount: 0) })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.groups.isEmpty)
        f.state.leavePage()
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertFalse(f.state.needsRegroup)
    }

    func testNewControllerRestoresBackendCompletedCacheAcrossSimulatedRestart() async {
        let service = AutomaticGrouping(restore: { index, threshold in
            index == 0 ? .missing : .restored(automaticResult(threshold, empty: true, candidateCount: 0))
        }, group: { _, threshold in automaticResult(threshold, empty: true, candidateCount: 0) })
        let first = fixture(service: service)
        await enter(first.state)
        first.state.pause()
        let next = fixture(service: service)
        XCTAssertFalse(next.state.hasScanned)
        XCTAssertEqual(service.trace.events, ["restore", "group"])
        await enter(next.state)
        XCTAssertTrue(next.state.hasScanned)
        XCTAssertTrue(next.state.groups.isEmpty)
        XCTAssertEqual(service.trace.events, ["restore", "group", "restore"])
    }

    func testReadinessLossCancelsActiveReadAndLaterReadyNeverRecomputesAutomatically() async throws {
        let gate = hold()
        let f = fixture(group: { _, threshold in await gate.wait(); return automaticResult(threshold) })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        f.state.availabilityChanged(ready: false)
        XCTAssertTrue(gate.cancelled)
        assertUnknown(f.state)
        gate.open()
        await f.state.waitUntilIdle()
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
    }

    func testLegacyExplicitHiddenScanAndInvalidationRemainNonAutomatic() async {
        let f = fixture()
        f.state.scan()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.isPageVisible)
        f.state.toggleSelection("a")
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        f.state.invalidateAccess()
        f.state.pause()
        f.state.resume()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        XCTAssertEqual(f.service.trace.events, ["group"])

        let explicit = fixture()
        explicit.state.scan()
        await explicit.state.waitUntilIdle()
        await enter(explicit.state)
        XCTAssertTrue(explicit.state.hasScanned)
        XCTAssertEqual(explicit.service.trace.events, ["group"], "Explicit scans consume the first automatic attempt")
    }

    func testExplicitScanDuringRestoreDrainsWholeCancelledChainWithoutDeadlock() async throws {
        let old = hold(), latest = hold()
        let f = fixture(restore: { _, threshold in
            await old.wait()
            return .restored(automaticResult(threshold, candidateCount: 999))
        }, group: { _, threshold in await latest.wait(); return automaticResult(threshold) })
        f.state.enterPage(ready: true)
        try await reached(old.entered)
        f.state.scan()
        f.state.scan() // The cancelled middle request retains its predecessor.
        XCTAssertTrue(old.cancelled)
        let joined = expectation(description: "read waiter started")
        var finished = false
        let waiter = Task { @MainActor in joined.fulfill(); await f.state.waitUntilIdle(); finished = true }
        try await reached(joined)
        XCTAssertFalse(finished)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        old.open()
        try await reached(latest.entered)
        XCTAssertFalse(finished)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
        XCTAssertNil(f.state.message)
        latest.open()
        await waiter.value
        XCTAssertEqual(f.state.candidateCount, 2)
        XCTAssertTrue(f.state.hasScanned)
    }

    func testAccessNotificationDuringGroupSerializesFreshRestoreAndRejectsOldResult() async throws {
        let gate = hold()
        let f = fixture(restore: { index, threshold in
            index == 0 ? .missing : .restored(automaticResult(threshold, candidateCount: 7))
        }, group: { _, threshold in await gate.wait(); return automaticResult(threshold, candidateCount: 999) })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        f.state.invalidateAccess()
        XCTAssertTrue(gate.cancelled)
        XCTAssertTrue(f.state.isRestoring)
        XCTAssertFalse(f.state.needsRegroup)
        assertUnknown(f.state)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.candidateCount, 7)
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
    }

    func testThresholdPersistsIntegerTicksAndRestoresEverySupportedTickWithoutWork() throws {
        let defaults = try preferences()
        for tick in 50...99 {
            let f = fixture(preferences: defaults)
            f.state.threshold = Float(tick) / 100
            XCTAssertEqual(defaults.object(forKey: "similarCleanupThreshold.v1") as? Int, tick)
            let next = fixture(preferences: defaults)
            XCTAssertEqual(next.state.threshold, Float(tick) / 100)
            XCTAssertTrue(f.service.trace.events.isEmpty)
            XCTAssertTrue(next.service.trace.events.isEmpty)
        }
        let isolated = fixture()
        XCTAssertEqual(isolated.state.threshold, 0.90, "Default nil does not consult any persistent defaults")
    }

    func testInvalidStoredThresholdTypesFallBackWithoutCoercionOrRepairWrites() throws {
        let defaults = try preferences()
        let invalid: [Any] = [true, false, "80", "0.80", 49, 100, -1, 80.5,
                              Double.nan, Double.infinity, -Double.infinity, [80], ["ticks": 80], Data([80])]
        for value in invalid {
            defaults.set(value, forKey: "similarCleanupThreshold.v1")
            let f = fixture(preferences: defaults)
            XCTAssertEqual(f.state.threshold, 0.90)
            XCTAssertTrue(f.service.trace.events.isEmpty)
            XCTAssertNotNil(defaults.object(forKey: "similarCleanupThreshold.v1"), "Invalid settings are not silently rewritten")
        }
        defaults.removeObject(forKey: "similarCleanupThreshold.v1")
        XCTAssertEqual(fixture(preferences: defaults).state.threshold, 0.90)
    }

    func testInvalidRuntimeThresholdsRemainVisibleButNeverPersistOrReachService() async throws {
        let defaults = try preferences()
        let f = fixture(preferences: defaults)
        f.state.threshold = 0.73
        let invalid: [Float] = [.nan, .infinity, -.infinity, Float(0.50).nextDown, Float(0.99).nextUp]
        for value in invalid {
            f.state.threshold = value
            f.state.scan()
            await f.state.waitUntilIdle()
            assertFailure(f.state, code: .invalidIndex, phase: .compute, operation: .group,
                          reason: "图片索引数据未通过分组校验")
            XCTAssertEqual(defaults.integer(forKey: "similarCleanupThreshold.v1"), 73)
            XCTAssertTrue(f.service.trace.events.isEmpty)
            if value.isNaN { XCTAssertTrue(f.state.threshold.isNaN) }
            else { XCTAssertEqual(f.state.threshold, value) }
        }
        f.state.threshold = 0.805 // Valid API value, but not a persistent slider tick.
        XCTAssertEqual(defaults.integer(forKey: "similarCleanupThreshold.v1"), 73)

        let firstEntry = fixture()
        firstEntry.state.threshold = .nan
        await enter(firstEntry.state)
        assertFailure(firstEntry.state, code: .invalidIndex, phase: .photos, operation: .restore,
                  reason: "图片索引数据未通过分组校验")
        XCTAssertTrue(firstEntry.service.trace.events.isEmpty)
    }

    func testSettingsEditBeforeFirstEntryDoesNotWorkAndFirstEntryUsesNewThreshold() async throws {
        let f = fixture(preferences: try preferences())
        f.state.threshold = 0.72
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertFalse(f.state.needsRegroup)
        await enter(f.state)
        XCTAssertEqual(f.service.trace.thresholds, [0.72, 0.72])
    }

    func testThresholdEditAfterSeenRequiresManualRegroupAndEqualValueKeepsSelection() async {
        let f = fixture()
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intentID = f.state.pendingDeletion?.id
        f.state.threshold = 0.90
        XCTAssertEqual(f.state.pendingDeletion?.id, intentID)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        f.state.threshold = 0.75
        assertUnknown(f.state)
        XCTAssertTrue(f.state.needsRegroup)
        await exerciseLifecycle(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        f.state.scan()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.service.trace.thresholds, [0.90, 0.90, 0.75])

        let seenButNotReady = fixture()
        seenButNotReady.state.enterPage(ready: false)
        seenButNotReady.state.threshold = 0.75
        seenButNotReady.state.availabilityChanged(ready: true)
        await seenButNotReady.state.waitUntilIdle()
        XCTAssertTrue(seenButNotReady.state.needsRegroup)
        XCTAssertTrue(seenButNotReady.service.trace.events.isEmpty, "Settings edits are not automatic regroup requests")
    }

    func testUnchangedInputsNotificationClearsUnsafeStateThenRebindsFreshValidators() async throws {
        let old = AutomaticValidation(), fresh = AutomaticValidation()
        let gate = hold()
        let f = fixture(restore: { index, threshold in
            if index > 0 { await gate.wait() }
            return .restored(automaticResult(threshold, validation: index == 0 ? old : fresh))
        })
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        old.fail()
        f.state.invalidateAccess()
        assertUnknown(f.state)
        XCTAssertFalse(f.state.needsRegroup, "A notification alone is not a stale classification")
        XCTAssertTrue(f.state.isRestoring)
        f.state.confirmDeletion(intent)
        try await reached(gate.entered)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.toggleSelection("b")
        XCTAssertEqual(f.state.selectedIDs, ["b"])
        XCTAssertEqual(fresh.trace.photoIDs, [["b"]])
        XCTAssertEqual(old.trace.photoIDs, [["a"], ["a"]])
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
    }

    func testEditedInputsStaleClassificationNeverComputesUntilManualUpdate() async {
        let f = fixture(restore: { index, threshold in
            index == 0 ? .restored(automaticResult(threshold)) : .stale
        })
        await enter(f.state)
        f.state.invalidateAccess()
        XCTAssertFalse(f.state.needsRegroup)
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        XCTAssertTrue(f.state.needsRegroup)
        await exerciseLifecycle(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
        f.state.scan()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore", "group"])
    }

    func testMissingCacheAfterCompletedZeroNeverPermitsAnotherAutomaticCompute() async {
        let f = fixture(group: { _, threshold in automaticResult(threshold, empty: true, candidateCount: 0) })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        f.state.invalidateAccess()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.needsRegroup)
        assertUnknown(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
    }

    func testHiddenAccessNotificationClearsImmediatelyAndDefersRestoreUntilEntry() async {
        let f = fixture(restore: { _, threshold in .restored(automaticResult(threshold)) })
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.leavePage()
        f.state.invalidateAccess()
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertEqual(f.service.trace.events, ["restore"])
        await enter(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
    }

    func testBackgroundClearsLiveAuthorityAndRestoresOnlyWhenVisibleForegroundReady() async {
        let f = fixture(restore: { _, threshold in .restored(automaticResult(threshold)) })
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.pause()
        assertUnknown(f.state)
        f.state.invalidateAccess()
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore"])
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
        f.state.pause()
        f.state.leavePage()
        f.state.resume()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        XCTAssertEqual(f.service.trace.events.count, 2)
        await enter(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore", "restore"])
    }

    func testFailedRestoreAfterPriorSuccessDoesNotResumeRetryLoop() async {
        let f = fixture(restore: { index, threshold in
            if index == 0 { return .restored(automaticResult(threshold)) }
            throw AppFailure.permission
        })
        await enter(f.state)
        f.state.invalidateAccess()
        await f.state.waitUntilIdle()
        assertFailure(f.state, code: .permissionDenied, phase: .photos, operation: .restore,
                  reason: "系统设置")
        await exerciseLifecycle(f.state)
        XCTAssertEqual(f.service.trace.events, ["restore", "restore"])
        assertUnknown(f.state)
    }

    func testOptionalPersistenceWarningDoesNotTurnValidGroupsIntoFailure() async {
        let warning = "本次分组可正常使用，但未能保存；下次打开可能需要重新分组。"
        let f = fixture(group: { _, threshold in automaticResult(threshold, persistenceIssue: warning) })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.state.persistenceIssue, warning)
        XCTAssertNil(f.state.message)
        f.state.toggleSelection("a")
        f.state.leavePage()
        await enter(f.state)
        XCTAssertEqual(f.state.persistenceIssue, warning)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        f.state.pause()
        XCTAssertNil(f.state.persistenceIssue)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
    }

    func testRestoredEpochOrThresholdFailureCannotPublishCountsOrAuthorizeSelection() async {
        for wrongThreshold in [false, true] {
            let validation = AutomaticValidation(epochFails: !wrongThreshold)
            let f = fixture(restore: { _, threshold in
                .restored(automaticResult(wrongThreshold ? 0.99 : threshold, validation: validation))
            })
            await enter(f.state)
            assertUnknown(f.state)
            // AutomaticTestError.stale is untyped, not proof of lost photo access.
            assertFailure(f.state, code: wrongThreshold ? .invalidIndex : .unknown,
                          phase: .publication, operation: .publication,
                          reason: wrongThreshold ? "图片索引数据未通过分组校验" : "原因尚未确定")
            f.state.toggleSelection("a")
            XCTAssertFalse(f.state.canSelect)
            XCTAssertTrue(validation.trace.photoIDs.isEmpty)
            XCTAssertEqual(validation.trace.accessThreads, wrongThreshold ? [] : [false])
            XCTAssertEqual(validation.trace.epochThreads, wrongThreshold ? [] : [true])
            XCTAssertEqual(f.service.trace.events, ["restore"])
        }
    }

    func testRestoredPublicationValidationStaysOffMainAndCannotPublishAfterLeaving() async throws {
        let validation = AutomaticValidation(blockAccess: true)
        addTeardownBlock { validation.release() }
        let f = fixture(restore: { _, threshold in .restored(automaticResult(threshold, validation: validation)) })
        f.state.enterPage(ready: true)
        try await reached(validation.entered)
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertTrue(f.state.isRestoring)
        XCTAssertTrue(f.state.isValidating)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertEqual(validation.trace.accessThreads, [false])
        f.state.leavePage()
        assertUnknown(f.state)
        XCTAssertFalse(f.state.isValidating)
        validation.release()
        await f.state.waitUntilIdle()
        assertUnknown(f.state)
        XCTAssertTrue(validation.trace.epochThreads.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore"])
    }

    func testDeletionSurvivesPageBackgroundAndInputChangesAndIdleJoinsRealOutcome() async throws {
        let gate = hold()
        let deletion = AutomaticDeletion { _ in await gate.wait() }
        let f = fixture(deletion: deletion)
        await enter(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.confirmDeletion(intent)
        try await reached(gate.entered)
        XCTAssertFalse(f.state.canChangeThreshold)
        f.state.leavePage()
        f.state.pause()
        f.state.invalidateAccess()
        f.state.threshold = 0.75
        f.state.resume()
        f.state.enterPage(ready: true)
        f.state.scan()
        XCTAssertFalse(gate.cancelled)
        XCTAssertTrue(f.state.isDeleting)
        let joined = expectation(description: "mutation waiter started")
        var finished = false
        let waiter = Task { @MainActor in joined.fulfill(); await f.state.waitUntilIdle(); finished = true }
        try await reached(joined)
        XCTAssertFalse(finished)
        gate.open()
        await waiter.value
        XCTAssertTrue(finished)
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertTrue(f.state.canChangeThreshold)
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        XCTAssertEqual(deletion.calls, [intent.revisions])
        XCTAssertFalse(gate.cancelled)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        f.state.invalidateAccess() // Photos may deliver the mutation event later.
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        XCTAssertEqual(f.service.trace.events, ["restore", "group", "restore"])
        XCTAssertTrue(f.state.needsRegroup)
    }

    // MARK: Deterministic fixtures; timeouts bound tests only, not app work.

    private func assertFailure(_ state: SimilarPhotoCleanupState, code: SimilarCleanupDiagnostic.Code,
                               phase: SimilarCleanupPhase, operation: SimilarCleanupOperation, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.failureDiagnostic, SimilarCleanupDiagnostic(phase: phase, code: code), file: file, line: line)
        XCTAssertNil(state.failureDiagnostic?.nativeCode, file: file, line: line)
        XCTAssertEqual(state.failureOperation, operation, file: file, line: line)
        XCTAssertTrue(state.message?.hasPrefix("\(code.rawValue) · \(phase.rawValue)\n") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains(reason) == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("本次未删除照片") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("已有索引未清除") == true, file: file, line: line)
        for privateText in ["synthetic-private", "private asset", "/private/library/photo.jpg"] {
            XCTAssertFalse(state.message?.contains(privateText) ?? true, file: file, line: line)
        }
        if code != .permissionDenied {
            XCTAssertFalse(state.message?.contains("照片权限") ?? true, file: file, line: line)
        }
    }

    private func fixture(service: AutomaticGrouping? = nil,
                         restore: @escaping AutomaticGrouping.Restore = { _, _ in .missing },
                         group: @escaping AutomaticGrouping.Group = { _, threshold in automaticResult(threshold) },
                         deletion: AutomaticDeletion = AutomaticDeletion(),
                         preferences: UserDefaults? = nil) -> AutomaticFixture {
        let service = service ?? AutomaticGrouping(restore: restore, group: group)
        return AutomaticFixture(state: SimilarPhotoCleanupState(grouping: service, deletion: deletion, preferences: preferences),
                                service: service, deletion: deletion)
    }

    private func preferences() throws -> UserDefaults {
        let name = "SimilarCleanupAutomaticEntryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func enter(_ state: SimilarPhotoCleanupState) async {
        state.enterPage(ready: true)
        await state.waitUntilIdle()
    }

    private func exerciseLifecycle(_ state: SimilarPhotoCleanupState) async {
        state.leavePage()
        state.enterPage(ready: true)
        state.availabilityChanged(ready: false)
        state.availabilityChanged(ready: true)
        state.pause()
        state.resume()
        await state.waitUntilIdle()
    }

    private func assertUnknown(_ state: SimilarPhotoCleanupState,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertNil(state.selectionSessionID, file: file, line: line)
        XCTAssertEqual(state.candidateCount, 0, file: file, line: line)
        XCTAssertEqual(state.staleCount, 0, file: file, line: line)
        XCTAssertEqual(state.unindexedCount, 0, file: file, line: line)
    }

    private func hold() -> AutomaticGate {
        let gate = AutomaticGate()
        addTeardownBlock { gate.open() }
        return gate
    }

    private func reached(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Missing deterministic event: \(event.expectationDescription)")
            throw AutomaticTestError.missingEvent
        }
    }
}

private struct AutomaticFixture {
    let state: SimilarPhotoCleanupState
    let service: AutomaticGrouping
    let deletion: AutomaticDeletion
}

private enum AutomaticTestError: Error { case missingEvent, mainThread, stale }

private func automaticPrivateError() -> Error {
    NSError(domain: "synthetic-private", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "private asset /private/library/photo.jpg"])
}

private func automaticResult(_ threshold: Float, empty: Bool = false, candidateCount: Int = 2,
                             staleCount: Int = 0, unindexedCount: Int = 0,
                             validation: AutomaticValidation? = nil,
                             persistenceIssue: String? = nil) -> SimilarPhotoGroupingResult {
    let photos = ["a", "b"].map {
        IndexedPhoto(id: $0, modificationTime: 41, modelVersion: "synthetic-automatic-cleanup",
                     imageEmbedding: [1] + [Float](repeating: 0, count: 767), creationTime: 13)
    }
    let groups = empty ? [] : [SimilarPhotoGroup(id: "pair", photos: photos, minimumSimilarity: 1)]
    return SimilarPhotoGroupingResult(groups: groups, candidateCount: candidateCount,
        staleCount: staleCount, unindexedCount: unindexedCount, threshold: threshold,
        validateAccess: { try validation?.access() }, validatePhotos: { try validation?.photos($0) },
        validatePublicationEpoch: { try validation?.epoch() }, persistenceIssue: persistenceIssue)
}

private final class AutomaticGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    typealias Restore = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingRestore
    typealias Group = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingResult
    struct Trace {
        var events: [String] = []
        var thresholds: [Float] = []
        var entryThreads: [Bool] = []
        var active = 0
        var maximumActive = 0
        var restores = 0
        var groups = 0
    }
    private let lock = NSLock()
    private var recorded = Trace()
    private let restoreOperation: Restore
    private let groupOperation: Group

    init(restore: @escaping Restore, group: @escaping Group) {
        restoreOperation = restore
        groupOperation = group
    }

    var trace: Trace { locked { recorded } }

    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        let index = begin("restore", threshold: threshold)
        defer { locked { recorded.active -= 1 } }
        return try await restoreOperation(index, threshold)
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        let index = begin("group", threshold: threshold)
        defer { locked { recorded.active -= 1 } }
        await progress(SimilarPhotoGroupingProgress(total: 2, completed: 2, groupCount: 1))
        return try await groupOperation(index, threshold)
    }

    private func begin(_ event: String, threshold: Float) -> Int {
        locked {
            let index: Int
            if event == "restore" { index = recorded.restores; recorded.restores += 1 }
            else { index = recorded.groups; recorded.groups += 1 }
            recorded.events.append(event)
            recorded.thresholds.append(threshold)
            recorded.entryThreads.append(Thread.isMainThread)
            recorded.active += 1
            recorded.maximumActive = max(recorded.maximumActive, recorded.active)
            return index
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class AutomaticDeletion: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PhotoRevision]] = []
    private let operation: @Sendable ([PhotoRevision]) async throws -> Void

    init(_ operation: @escaping @Sendable ([PhotoRevision]) async throws -> Void = { _ in }) {
        self.operation = operation
    }

    var calls: [[PhotoRevision]] { locked { recorded } }

    func delete(revisions: [PhotoRevision]) async throws {
        locked { recorded.append(revisions) }
        try await operation(revisions)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Cancellation is observed but deliberately does not release an uncooperative
/// service. Explicit open() provides ordering without sleeps or polling.
private final class AutomaticGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Read or mutation entered held callback")
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
        let alreadyOpen = locked {
            if !opened { continuation = value }
            return opened
        }
        entered.fulfill()
        if alreadyOpen { value.resume() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// The main-thread guard throws rather than deadlocking the test runner if a
/// regression ever runs a held synchronous metadata validator on MainActor.
private final class AutomaticValidation: @unchecked Sendable {
    struct Trace {
        var accessThreads: [Bool] = []
        var epochThreads: [Bool] = []
        var photoIDs: [[String]] = []
    }
    let entered = XCTestExpectation(description: "Synchronous metadata validation entered")
    private let condition = NSCondition()
    private var recorded = Trace()
    private var released = false
    private var failed = false
    private let blockAccess: Bool
    private let blockPhotos: Bool
    private let epochFails: Bool

    init(blockAccess: Bool = false, blockPhotos: Bool = false, epochFails: Bool = false) {
        self.blockAccess = blockAccess
        self.blockPhotos = blockPhotos
        self.epochFails = epochFails
    }

    var trace: Trace { locked { recorded } }
    func fail() { locked { failed = true } }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func access() throws {
        locked { recorded.accessThreads.append(Thread.isMainThread) }
        if blockAccess { try block() }
        try requireValid()
    }

    func photos(_ ids: [String]) throws {
        locked { recorded.photoIDs.append(ids) }
        if blockPhotos { try block() }
        try requireValid()
    }

    func epoch() throws {
        locked { recorded.epochThreads.append(Thread.isMainThread) }
        if epochFails { throw AutomaticTestError.stale }
        try requireValid()
    }

    private func block() throws {
        entered.fulfill()
        guard !Thread.isMainThread else { throw AutomaticTestError.mainThread }
        condition.lock()
        defer { condition.unlock() }
        while !released { condition.wait() }
    }

    private func requireValid() throws {
        if locked({ failed }) { throw AutomaticTestError.stale }
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock(); defer { condition.unlock() }
        return body()
    }
}