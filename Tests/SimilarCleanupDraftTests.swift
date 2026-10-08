import Combine
import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Synthetic metadata services with the real IndexAccessCoordinator. Explicit
/// milestones/continuations, not sleeps or scheduling guesses. No Photos, SQL,
/// encoders, network, standard defaults, terminal commands or real deletion.
@MainActor
final class SimilarCleanupDraftTests: XCTestCase {
    func testInitialDraftUsesPolicyDefaultWithoutWorkOrPreferenceWrite() async throws {
        let defaults = try preferences()
        let f = fixture(preferences: defaults)
        XCTAssertEqual(f.state.threshold, 0.90)
        XCTAssertEqual(f.state.draftThreshold, SimilarPhotoGroupingPolicy.defaultThreshold)
        XCTAssertNil(f.state.resultThreshold)
        XCTAssertFalse(f.state.hasPendingThresholdChange)
        XCTAssertNil(defaults.object(forKey: SimilarCleanupPreferences.thresholdKey))
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertTrue(f.state.displayGroups.isEmpty)
        XCTAssertNil(f.state.displayNumber(for: "old"))
    }

    func testEveryValidV1TickIncluding80IsPreservedWithoutMigrationWrites() throws {
        let defaults = try preferences()
        for tick in 50...99 {
            defaults.set(tick, forKey: SimilarCleanupPreferences.thresholdKey)
            let f = fixture(preferences: defaults)
            XCTAssertEqual(f.state.threshold, Float(tick) / 100)
            XCTAssertEqual(f.state.draftThreshold, Float(tick) / 100)
            XCTAssertEqual(defaults.object(forKey: SimilarCleanupPreferences.thresholdKey) as? Int, tick)
            XCTAssertTrue(f.service.trace.events.isEmpty)
        }
    }

    func testInvalidSavedValueFallsBackWithoutRepairingV1() throws {
        let defaults = try preferences()
        let invalid: [Any] = [true, "80", 80.5, 49, 100]
        for value in invalid {
            defaults.set(value, forKey: SimilarCleanupPreferences.thresholdKey)
            let before = defaults.object(forKey: SimilarCleanupPreferences.thresholdKey) as? NSObject
            let f = fixture(preferences: defaults)
            XCTAssertEqual(f.state.draftThreshold, SimilarPhotoGroupingPolicy.defaultThreshold)
            XCTAssertEqual(defaults.object(forKey: SimilarCleanupPreferences.thresholdKey) as? NSObject, before)
        }
    }

    func testDraftKeepsPublishedGroupsCountsSessionSelectionAndCommittedPreference() async throws {
        let defaults = try preferences()
        defaults.set(80, forKey: SimilarCleanupPreferences.thresholdKey)
        let f = fixture(preferences: defaults)
        await scan(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        var projections = 0
        let subscription = f.state.$displayGroups.sink { _ in projections += 1 }
        defer { subscription.cancel() }
        f.state.setDraftThreshold(0.85)
        XCTAssertEqual(f.state.threshold, 0.80)
        XCTAssertEqual(f.state.resultThreshold, 0.80)
        XCTAssertEqual(f.state.draftThreshold, 0.85)
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.groups.map(\.id), ["old", "new"])
        XCTAssertEqual(f.state.displayGroups.map(\.id), ["new", "old"])
        XCTAssertEqual(f.state.candidateCount, 8)
        XCTAssertEqual(f.state.staleCount, 2)
        XCTAssertEqual(f.state.unindexedCount, 3)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.hasPendingThresholdChange)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canUpdateResults)
        XCTAssertNil(f.state.pendingDeletion)
        f.state.toggleSelection("b")
        f.state.selectGroup("new")
        f.state.prepareDeletion()
        f.state.confirmDeletion(intent)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "old"))
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.service.trace.events, ["group"])
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 80)
        XCTAssertEqual(projections, 1, "Draft editing must not rebuild the display projection")
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testNoOpDraftPreservesConfirmationAndDoesNotRepublish() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        var drafts: [Float] = []
        let subscription = f.state.$draftThreshold.sink { drafts.append($0) }
        defer { subscription.cancel() }
        f.state.setDraftThreshold(f.state.draftThreshold)
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.service.trace.events, ["group"])
    }

    func testRevertingDraftReenablesCommittedSelectionButCannotReviveOldConfirmation() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let old = try XCTUnwrap(f.state.pendingDeletion)
        f.state.setDraftThreshold(0.75)
        f.state.setDraftThreshold(f.state.threshold)
        XCTAssertFalse(f.state.hasPendingThresholdChange)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertFalse(f.state.canUpdateResults)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertNil(f.state.pendingDeletion)
        f.state.confirmDeletion(old)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testDraftDuringComputeDoesNotCancelAndResultRetainsRequestedThreshold() async throws {
        let gate = hold()
        let f = fixture(service: DraftGrouping(group: { _, threshold in
            await gate.wait()
            return draftResult(threshold)
        }))
        f.state.scan()
        let committed = f.state.threshold
        try await reached(gate.entered)
        f.state.setDraftThreshold(0.75)
        f.state.updateResults()
        XCTAssertFalse(gate.cancelled)
        XCTAssertTrue(f.state.isGrouping)
        XCTAssertFalse(f.state.canUpdateResults)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [committed])
        XCTAssertEqual(f.state.resultThreshold, committed)
        XCTAssertEqual(f.state.draftThreshold, 0.75)
        XCTAssertTrue(f.state.hasPendingThresholdChange)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canUpdateResults)
    }

    func testDraftDuringPublicationDoesNotCancelValidationOrRelabelResult() async throws {
        let gate = validationGate()
        let f = fixture(service: DraftGrouping(group: { _, threshold in
            draftResult(threshold, access: { try gate.wait() })
        }))
        f.state.scan()
        let committed = f.state.threshold
        try await reached(gate.entered)
        XCTAssertTrue(f.state.isValidating)
        f.state.setDraftThreshold(0.72)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(gate.cancelledReturns, [false])
        XCTAssertEqual(f.state.resultThreshold, committed)
        XCTAssertEqual(f.state.draftThreshold, 0.72)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.canSelect)
    }

    func testUpdateCommitsAndPersistsOnceWithoutDuplicateOrReplacementWork() async throws {
        let defaults = try preferences()
        defaults.set(80, forKey: SimilarCleanupPreferences.thresholdKey)
        let gate = hold()
        let f = fixture(preferences: defaults, service: DraftGrouping(group: { call, threshold in
            if call == 1 { await gate.wait() }
            return draftResult(threshold)
        }))
        await scan(f.state)
        let oldSession = f.state.selectionSessionID
        f.state.toggleSelection("a")
        f.state.setDraftThreshold(0.85)
        f.state.updateResults()
        f.state.updateResults()
        XCTAssertEqual(f.state.threshold, 0.85)
        XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 85)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        try await reached(gate.entered)
        f.state.updateResults()
        XCTAssertFalse(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.thresholds, [0.80, 0.85])
        XCTAssertEqual(f.service.trace.maximumActive, 1)
        XCTAssertNotEqual(f.state.selectionSessionID, oldSession)
        XCTAssertEqual(f.state.resultThreshold, 0.85)
        XCTAssertFalse(f.state.hasPendingThresholdChange)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(fixture(preferences: defaults).state.draftThreshold, 0.85)
    }

    func testInvalidDraftNeverCommitsPersistsOrCallsService() async throws {
        let defaults = try preferences()
        defaults.set(80, forKey: SimilarCleanupPreferences.thresholdKey)
        let f = fixture(preferences: defaults)
        await scan(f.state)
        let session = f.state.selectionSessionID
        let invalid: [Float] = [.nan, .infinity, -.infinity, 0.49, 1]
        for value in invalid {
            f.state.setDraftThreshold(value)
            f.state.updateResults()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.state.threshold, 0.80)
            XCTAssertEqual(f.state.resultThreshold, 0.80)
            XCTAssertEqual(f.state.selectionSessionID, session)
            XCTAssertEqual(defaults.integer(forKey: SimilarCleanupPreferences.thresholdKey), 80)
            XCTAssertEqual(f.state.failureDiagnostic?.code, .invalidIndex)
            XCTAssertFalse(f.state.canSelect)
        }
        XCTAssertEqual(f.service.trace.events, ["group"])
    }

    func testUpdateRequiresForegroundAndEmbeddedPageReadinessButLegacyManualStillWorks() async {
        let f = fixture()
        f.state.enterPage(ready: false)
        f.state.setDraftThreshold(0.73)
        f.state.updateResults()
        XCTAssertFalse(f.state.canUpdateResults)
        f.state.leavePage()
        f.state.availabilityChanged(ready: true)
        f.state.updateResults()
        f.state.pause()
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertEqual(f.state.threshold, SimilarPhotoGroupingPolicy.defaultThreshold)
        let legacy = fixture()
        legacy.state.setDraftThreshold(0.73)
        legacy.state.updateResults()
        await legacy.state.waitUntilIdle()
        XCTAssertEqual(legacy.service.trace.thresholds, [0.73])
    }

    func testFirstAutomaticMissingCacheUsesCommittedPreferenceDespiteDraft() async throws {
        let defaults = try preferences()
        defaults.set(80, forKey: SimilarCleanupPreferences.thresholdKey)
        let f = fixture(preferences: defaults)
        f.state.setDraftThreshold(0.73)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertEqual(f.service.trace.thresholds, [0.80, 0.80])
        XCTAssertEqual(f.state.resultThreshold, 0.80)
        XCTAssertEqual(f.state.draftThreshold, 0.73)
        XCTAssertFalse(f.state.canSelect)
    }

    func testExternalThresholdKeepsLegacyImmediateInvalidationAndResetsDraft() async throws {
        let gate = hold()
        let f = fixture(service: DraftGrouping(group: { _, threshold in
            await gate.wait()
            return draftResult(threshold)
        }))
        f.state.scan()
        try await reached(gate.entered)
        f.state.setDraftThreshold(0.72)
        f.state.threshold = 0.85
        XCTAssertEqual(f.state.draftThreshold, 0.85)
        XCTAssertFalse(f.state.hasPendingThresholdChange)
        XCTAssertTrue(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.hasScanned)
        XCTAssertTrue(f.state.groups.isEmpty)
        XCTAssertTrue(f.state.displayGroups.isEmpty)
        XCTAssertNil(f.state.resultThreshold)
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertEqual(f.service.trace.events, ["group"])
    }

    func testExternalEqualThresholdResetsDraftWithoutInvalidatingCommittedResult() async {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a")
        let session = f.state.selectionSessionID
        f.state.setDraftThreshold(0.72)
        let committed = f.state.threshold
        f.state.threshold = committed
        XCTAssertEqual(f.state.draftThreshold, committed)
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertTrue(f.state.canSelect)
    }

    func testDraftCancelsDragAndHeldSelectionWithoutLateCommitOrConfirmation() async throws {
        for fails in [false, true] {
            let validation = DraftValidation()
            let gate = validationGate(fails: fails)
            let f = fixture(service: DraftGrouping(group: { _, threshold in
                draftResult(threshold, photos: { try validation.photos($0) })
            }))
            await scan(f.state)
            f.state.toggleSelection("a")
            let session = f.state.selectionSessionID
            let drag = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
            f.state.setDraftThreshold(0.75)
            f.state.finishRangeSelection(token: drag, selectedInGroup: ["b"])
            XCTAssertFalse(f.state.isSelecting)
            f.state.setDraftThreshold(f.state.threshold)
            validation.gate = gate
            let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
            f.state.finishRangeSelection(token: token, selectedInGroup: ["b"])
            try await reached(gate.entered)
            f.state.setDraftThreshold(0.74)
            XCTAssertFalse(f.state.isSelecting)
            XCTAssertFalse(f.state.isValidatingSelection)
            gate.open()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.state.selectedIDs, ["a"])
            XCTAssertEqual(f.state.selectionSessionID, session)
            XCTAssertNil(f.state.pendingDeletion)
            XCTAssertNil(f.state.message)
            XCTAssertEqual(gate.cancelledReturns, [true])
        }
    }

    func testUpdateCancelsUncommittedDragAndDoesNotReplaceSelectionValidation() async throws {
        let validation = DraftValidation()
        let gate = validationGate()
        let f = fixture(service: DraftGrouping(group: { _, threshold in
            draftResult(threshold, photos: { try validation.photos($0) })
        }))
        await scan(f.state)
        let drag = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
        f.state.setDraftThreshold(0.75) // Ends any previous drag before committing.
        f.state.updateResults()
        f.state.finishRangeSelection(token: drag, selectedInGroup: ["a"])
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
        validation.gate = gate
        f.state.finishRangeSelection(token: token, selectedInGroup: ["b"])
        try await reached(gate.entered)
        f.state.updateResults()
        XCTAssertFalse(f.state.canUpdateResults)
        XCTAssertTrue(f.state.isValidatingSelection)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, ["b"])
        XCTAssertEqual(f.service.trace.events, ["group", "group"])
    }

    func testIndexEventKeepsBrowsingProjectionButClearsAuthorityWithoutAutoRegroup() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        let threshold = f.state.resultThreshold
        var projections = 0
        let subscription = f.state.$displayGroups.sink { _ in projections += 1 }
        defer { subscription.cancel() }
        let writer = try await access.acquireWrite()
        f.state.indexSourceChanged()
        writer.release()
        f.state.indexSourceChanged()
        f.state.confirmDeletion(intent)
        f.state.leavePage()
        f.state.enterPage(ready: true)
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canUpdateResults)
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.resultThreshold, threshold)
        XCTAssertEqual(f.state.groups.map(\.id), ["old", "new"])
        XCTAssertEqual(f.state.displayGroups.map(\.id), ["new", "old"])
        XCTAssertEqual(f.state.displayNumber(for: "new"), 1)
        XCTAssertEqual(f.state.displayNumber(for: "old"), 2)
        XCTAssertNil(f.state.displayNumber(for: "unknown"))
        XCTAssertEqual(f.state.candidateCount, 8)
        XCTAssertEqual(f.state.staleCount, 2)
        XCTAssertEqual(f.state.unindexedCount, 3)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertNil(f.state.failureDiagnostic)
        XCTAssertNil(f.state.message)
        XCTAssertEqual(projections, 1)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertNotEqual(f.state.selectionSessionID, session)
    }

    func testIndexEventsBeforeFirstEntryDoNotConsumeAutomaticAttempt() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access)
        let writer = try await access.acquireWrite()
        f.state.indexSourceChanged()
        writer.release()
        f.state.indexSourceChanged()
        XCTAssertFalse(f.state.needsRegroup)
        f.state.enterPage(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
        XCTAssertTrue(f.state.canSelect)
    }

    func testManualUpdateAfterSourceChangeRestoresMatchingCacheWithoutPairwiseRegroup() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: DraftGrouping(restore: { _, threshold in
            .restored(draftResult(threshold))
        }))
        await scan(f.state)
        let session = f.state.selectionSessionID
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        XCTAssertEqual(f.service.trace.events, ["group"])
        f.state.updateResults()
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["group", "restore"])
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertEqual(f.state.resultThreshold, f.state.threshold)
    }

    func testManualUpdateAfterSourceChangeComputesOnlyWhenCacheIsStaleOrMissing() async throws {
        for stale in [false, true] {
            let events = DraftEnqueues()
            let access = IndexAccessCoordinator(didEnqueue: { events.send() })
            let f = fixture(access: access, service: DraftGrouping(restore: { _, _ in
                stale ? .stale : .missing
            }))
            await scan(f.state)
            let writer = try await access.acquireWrite()
            writer.release()
            f.state.indexSourceChanged()
            f.state.updateResults()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["group", "restore", "group"])
            XCTAssertEqual(events.total, 3, "One read for the entire manual restore + compute + publish")
            XCTAssertTrue(f.state.canSelect)
            XCTAssertFalse(f.state.needsRegroup)
        }
    }

    func testFailedWriterWithoutCommitNotificationAllowsManualMatchingCacheRestore() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let restore = hold()
        let f = fixture(access: access, service: DraftGrouping(restore: { _, threshold in
            await restore.wait()
            return .restored(draftResult(threshold))
        }))
        await scan(f.state)
        f.state.enterPage(ready: true)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        let threshold = f.state.resultThreshold
        XCTAssertFalse(f.state.canUpdateResults)
        f.state.availabilityChanged(ready: false)
        do {
            let writer = try await access.acquireWrite()
            defer { writer.release() }
            XCTAssertFalse(f.state.canSelect)
            throw DraftError.failed // Synthetic rollback: no source/commit callback.
        } catch {
            XCTAssertTrue(error is DraftError)
        }
        XCTAssertEqual(access.revision, 1)
        XCTAssertFalse(access.isWriting)
        XCTAssertFalse(f.state.canUpdateResults, "Page readiness still gates manual updates")
        f.state.availabilityChanged(ready: true)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.needsRegroup, "No source callback has invalidated the result yet")
        XCTAssertFalse(f.state.canSelect)
        XCTAssertTrue(f.state.canUpdateResults, "Revision mismatch alone must enable manual recovery")
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.resultThreshold, threshold)
        XCTAssertEqual(f.state.groups.map(\.id), ["old", "new"])
        XCTAssertEqual(f.state.displayGroups.map(\.id), ["new", "old"])
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.service.trace.events, ["group"], "Readiness must not trigger a retry")
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)

        f.state.updateResults()
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        try await reached(restore.entered)
        f.state.updateResults()
        XCTAssertFalse(restore.cancelled)
        XCTAssertEqual(events.total, 3, "One whole read lease for manual restore and publication")
        restore.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["group", "restore"], "Matching cache needs no pairwise regroup")
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.resultThreshold, threshold)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertFalse(f.state.canUpdateResults)
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.failureDiagnostic)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testLateSourceCallbackPreservesFreshCachedSelectionDespiteQueuedWriter() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let f = fixture(access: access, service: DraftGrouping(restore: { _, threshold in
            .restored(draftResult(threshold))
        }))
        await scan(f.state)
        let committed = try await access.acquireWrite()
        committed.release()
        f.state.indexSourceChanged()
        f.state.updateResults()
        await f.state.waitUntilIdle()
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let session = f.state.selectionSessionID
        var projections = 0
        let subscription = f.state.$displayGroups.sink { _ in projections += 1 }
        defer { subscription.cancel() }
        let blocker = try await access.acquireRead()
        defer { blocker.release() }
        let writer = Task { try await access.acquireWrite() }
        defer { writer.cancel() }
        try await reached(events.at(5))
        XCTAssertEqual(access.revision, 1)
        XCTAssertFalse(access.isWriting)
        XCTAssertFalse(access.canReadImmediately)
        XCTAssertFalse(f.state.canSelect)
        f.state.indexSourceChanged() // Delayed notification for the already-observed commit.
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
        XCTAssertEqual(f.state.groups.map(\.id), ["old", "new"])
        XCTAssertEqual(f.state.displayGroups.map(\.id), ["new", "old"])
        XCTAssertEqual(projections, 1)
        writer.cancel()
        do {
            let unexpected = try await writer.value
            unexpected.release()
            XCTFail("Expected queued writer cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(access.canReadImmediately)
        XCTAssertEqual(access.revision, 1)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertFalse(f.state.canUpdateResults)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
        XCTAssertEqual(f.service.trace.events, ["group", "restore"])
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testManualCacheRestoreFailureIsNotMissingAndDoesNotTriggerRecompute() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: DraftGrouping(restore: { _, _ in throw DraftError.failed }))
        await scan(f.state)
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        f.state.updateResults()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.service.trace.events, ["group", "restore"])
        XCTAssertNotNil(f.state.failureDiagnostic)
        XCTAssertFalse(f.state.canSelect)
        let next = try await access.acquireWrite()
        next.release()
    }

    func testDelayedCurrentRevisionEventDoesNotInvalidateFreshResultOrSelection() async throws {
        let access = IndexAccessCoordinator()
        let writer = try await access.acquireWrite()
        writer.release()
        let f = fixture(access: access)
        await scan(f.state)
        f.state.toggleSelection("a")
        let session = f.state.selectionSessionID
        f.state.indexSourceChanged()
        XCTAssertFalse(f.state.needsRegroup)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertEqual(f.state.selectionSessionID, session)
    }

    func testCompletedZeroSurvivesIndexEventButBackgroundStillClearsBrowsing() async throws {
        let access = IndexAccessCoordinator()
        let f = fixture(access: access, service: DraftGrouping(group: { _, threshold in
            SimilarPhotoGroupingResult(groups: [], candidateCount: 1, staleCount: 2, unindexedCount: 3, threshold: threshold)
        }))
        await scan(f.state)
        let writer = try await access.acquireWrite()
        writer.release()
        f.state.indexSourceChanged()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertEqual(f.state.candidateCount, 1)
        XCTAssertNotNil(f.state.resultThreshold)
        f.state.pause()
        XCTAssertFalse(f.state.hasScanned)
        XCTAssertNil(f.state.resultThreshold)
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertEqual(f.state.candidateCount, 0)
        XCTAssertTrue(f.state.displayGroups.isEmpty)
        XCTAssertNil(f.state.message)
    }

    func testRestoreAndManualGroupWaitForWriterBeforeServiceEntry() async throws {
        for restoring in [false, true] {
            let events = DraftEnqueues()
            let access = IndexAccessCoordinator(didEnqueue: { events.send() })
            let writer = try await access.acquireWrite()
            let f = fixture(access: access)
            if restoring { f.state.enterPage(ready: true) } else { f.state.scan() }
            try await reached(events.at(2))
            XCTAssertTrue(f.service.trace.events.isEmpty)
            f.state.indexSourceChanged() // Queued front read captures the new version itself.
            writer.release()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, restoring ? ["restore", "group"] : ["group"])
            XCTAssertTrue(f.state.canSelect)
        }
    }

    func testOneReadLeaseSpansRestoreMissingComputeAndPublicationThenWriterDisablesSelectionBeforeUIEvent() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let restore = hold(), compute = hold(), publication = validationGate()
        let f = fixture(access: access, service: DraftGrouping(restore: { _, _ in
            await restore.wait()
            return .missing
        }, group: { _, threshold in
            await compute.wait()
            return draftResult(threshold, access: { try publication.wait() })
        }))
        f.state.enterPage(ready: true)
        try await reached(restore.entered)
        let writer = Task { try await access.acquireWrite() }
        defer { writer.cancel() }
        try await reached(events.at(2))
        XCTAssertEqual(access.revision, 0)
        restore.open()
        try await reached(compute.entered)
        XCTAssertEqual(access.revision, 0)
        compute.open()
        try await reached(publication.entered)
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 0)
        publication.open()
        await f.state.waitUntilIdle()
        let lease = try await writer.value
        defer { lease.release() }
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(access.revision, 1)
        XCTAssertFalse(f.state.needsRegroup, "No UI source notification has run yet")
        XCTAssertFalse(f.state.canSelect)
        f.state.toggleSelection("a")
        lease.release()
        XCTAssertFalse(f.state.canSelect, "An ended writer is still a different result revision")
        f.state.toggleSelection("a")
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertEqual(f.service.trace.events, ["restore", "group"])
    }

    func testCancelledQueuedReadReleasesWithoutEnteringServiceEvenWhileWriterHeld() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let writer = try await access.acquireWrite()
        defer { writer.release() }
        let f = fixture(access: access)
        f.state.scan()
        try await reached(events.at(2))
        f.state.pause()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.trace.events.isEmpty)
        XCTAssertNil(f.state.message)
        writer.release()
        let reader = try XCTUnwrap(access.tryRead())
        reader.release()
    }

    func testCancelledUncooperativeTailRetainsLeaseAndReplacementDrainChain() async throws {
        for fails in [false, true] {
            let events = DraftEnqueues()
            let access = IndexAccessCoordinator(didEnqueue: { events.send() })
            let gate = hold()
            let f = fixture(access: access, service: DraftGrouping(group: { call, threshold in
                if call == 0 {
                    await gate.wait()
                    if fails { throw DraftError.failed }
                }
                return draftResult(threshold)
            }))
            f.state.scan()
            try await reached(gate.entered)
            let writer = Task { try await access.acquireWrite() }
            defer { writer.cancel() }
            try await reached(events.at(2))
            f.state.scan()
            f.state.scan()
            XCTAssertTrue(gate.cancelled)
            XCTAssertEqual(access.revision, 0)
            XCTAssertEqual(f.service.trace.events, ["group"])
            gate.open()
            let lease = try await writer.value
            lease.release()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.service.trace.events, ["group", "group"])
            XCTAssertEqual(f.service.trace.maximumActive, 1)
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertTrue(f.state.canSelect)
            XCTAssertNil(f.state.message)
            let next = try await access.acquireWrite()
            next.release()
        }
    }

    func testRestoreComputeAndPublicationFailuresReturnReadLease() async throws {
        for phase in 0..<3 {
            let access = IndexAccessCoordinator()
            let f = fixture(access: access, service: DraftGrouping(restore: { _, _ in
                if phase == 0 { throw DraftError.failed }
                return .missing
            }, group: { _, threshold in
                if phase == 1 { throw DraftError.failed }
                return draftResult(threshold, access: { throw DraftError.failed })
            }))
            f.state.enterPage(ready: true)
            await f.state.waitUntilIdle()
            XCTAssertFalse(f.state.hasScanned)
            XCTAssertNotNil(f.state.failureDiagnostic)
            let writer = try await access.acquireWrite()
            XCTAssertTrue(access.isWriting)
            writer.release()
        }
    }

    func testQueuedWriterMakesSynchronousSelectionAndConfirmationReturnWithoutValidation() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let validation = DraftValidation()
        let f = fixture(access: access, service: DraftGrouping(group: { _, threshold in
            draftResult(threshold, photos: { try validation.photos($0) })
        }))
        await scan(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let before = validation.calls
        let blocker = try await access.acquireRead()
        defer { blocker.release() }
        let writer = Task { try await access.acquireWrite() }
        defer { writer.cancel() }
        try await reached(events.at(3))
        XCTAssertFalse(access.isWriting)
        XCTAssertEqual(access.revision, 0)
        XCTAssertFalse(access.canReadImmediately)
        XCTAssertFalse(f.state.canSelect, "Controls must reflect the queued writer, not silently reject enabled actions")
        f.state.toggleSelection("b")
        f.state.selectGroup("new")
        f.state.prepareDeletion()
        f.state.confirmDeletion(intent)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "old"))
        XCTAssertEqual(validation.calls, before)
        XCTAssertEqual(f.state.selectedIDs, ["a"])
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        blocker.release()
        let lease = try await writer.value
        lease.release()
        XCTAssertFalse(f.state.canSelect)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testAsyncSelectionRechecksRevisionAfterWaitingBeforeCallingValidator() async throws {
        let events = DraftEnqueues()
        let access = IndexAccessCoordinator(didEnqueue: { events.send() })
        let validation = DraftValidation()
        let f = fixture(access: access, service: DraftGrouping(group: { _, threshold in
            draftResult(threshold, photos: { try validation.photos($0) })
        }))
        await scan(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
        let blocker = try await access.acquireRead()
        defer { blocker.release() }
        let writer = Task { try await access.acquireWrite() }
        defer { writer.cancel() }
        try await reached(events.at(3))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["b"])
        try await reached(events.at(4))
        XCTAssertTrue(f.state.isValidatingSelection)
        blocker.release()
        let lease = try await writer.value
        lease.release()
        await f.state.waitUntilIdle()
        XCTAssertTrue(validation.calls.isEmpty)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertNil(f.state.message)
    }

    func testHeldAsyncSelectionProtectsSourceAndReleasesOnSuccessFailureOrCancellation() async throws {
        for outcome in 0..<3 {
            let events = DraftEnqueues()
            let access = IndexAccessCoordinator(didEnqueue: { events.send() })
            let validation = DraftValidation()
            let gate = validationGate(fails: outcome == 1)
            let f = fixture(access: access, service: DraftGrouping(group: { _, threshold in
                draftResult(threshold, photos: { try validation.photos($0) })
            }))
            await scan(f.state)
            validation.gate = gate
            let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
            f.state.finishRangeSelection(token: token, selectedInGroup: ["b"])
            try await reached(gate.entered)
            let writer = Task { try await access.acquireWrite() }
            defer { writer.cancel() }
            try await reached(events.at(3))
            if outcome == 2 { f.state.cancelRangeSelection() }
            XCTAssertFalse(access.isWriting)
            XCTAssertEqual(access.revision, 0)
            gate.open()
            await f.state.waitUntilIdle()
            let lease = try await writer.value
            lease.release()
            let expected: Set<String> = outcome == 0 ? ["b"] : []
            XCTAssertEqual(f.state.selectedIDs, expected)
            XCTAssertEqual(f.state.failureDiagnostic == nil, outcome != 1)
            XCTAssertFalse(f.state.canSelect)
            XCTAssertFalse(f.state.isSelecting)
        }
    }

    func testConfirmedDeletionDoesNotHoldIndexReadLeaseOrCancelActualPhotosTask() async throws {
        let access = IndexAccessCoordinator()
        let gate = hold()
        let deletion = DraftDeletion { _ in await gate.wait() }
        let f = fixture(access: access, deletion: deletion)
        await scan(f.state)
        f.state.toggleSelection("a")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        let committed = f.state.threshold
        f.state.confirmDeletion(intent)
        try await reached(gate.entered)
        let writer = try await access.acquireWrite()
        XCTAssertTrue(access.isWriting, "The index lease must not cover the asynchronous Photos write")
        f.state.indexSourceChanged()
        f.state.setDraftThreshold(0.75)
        f.state.updateResults()
        f.state.pause()
        writer.release()
        XCTAssertTrue(f.state.isDeleting)
        XCTAssertFalse(gate.cancelled)
        XCTAssertEqual(f.state.draftThreshold, committed)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertEqual(deletion.calls, [intent.revisions])
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
        XCTAssertEqual(f.service.trace.events, ["group"])
    }

    func testNilCoordinatorStillAllowsLegacyRangeAndPhotosInvalidationStillClears() async throws {
        let f = fixture()
        await scan(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "old"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a", "b"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, ["a", "b"])
        XCTAssertTrue(f.state.canSelect)
        f.state.indexSourceChanged()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.needsRegroup)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.invalidateAccess()
        XCTAssertFalse(f.state.hasScanned)
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertNil(f.state.resultThreshold)
        XCTAssertTrue(f.state.displayGroups.isEmpty)
        XCTAssertNil(f.state.displayNumber(for: "old"))
    }

    // MARK: Fixtures

    private func fixture(access: IndexAccessCoordinator? = nil, preferences: UserDefaults? = nil,
                         service: DraftGrouping = DraftGrouping(), deletion: DraftDeletion = DraftDeletion()) -> DraftFixture {
        DraftFixture(state: SimilarPhotoCleanupState(grouping: service, deletion: deletion,
            preferences: preferences, indexAccess: access), service: service, deletion: deletion)
    }

    private func preferences() throws -> UserDefaults {
        let name = "SimilarCleanupDraftTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func scan(_ state: SimilarPhotoCleanupState) async {
        state.scan()
        await state.waitUntilIdle()
    }

    private func hold() -> DraftGate {
        let gate = DraftGate()
        addTeardownBlock { gate.open() }
        return gate
    }

    private func validationGate(fails: Bool = false) -> DraftSyncGate {
        let gate = DraftSyncGate(fails: fails)
        addTeardownBlock { gate.open() }
        return gate
    }

    private func reached(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Missing milestone: \(event.expectationDescription)")
            throw DraftError.missingEvent
        }
    }
}

private struct DraftFixture {
    let state: SimilarPhotoCleanupState
    let service: DraftGrouping
    let deletion: DraftDeletion
}

private enum DraftError: Error { case failed, mainThread, missingEvent }

private func draftResult(_ threshold: Float,
                         access: @escaping @Sendable () throws -> Void = {},
                         photos: @escaping @Sendable ([String]) throws -> Void = { _ in }) -> SimilarPhotoGroupingResult {
    func photo(_ id: String, _ time: TimeInterval) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: 41, modelVersion: "synthetic-cleanup-draft",
                     imageEmbedding: [1] + [Float](repeating: 0, count: 767), creationTime: time)
    }
    let groups = [SimilarPhotoGroup(id: "old", photos: [photo("a", 1), photo("b", 2)], minimumSimilarity: 1),
                  SimilarPhotoGroup(id: "new", photos: [photo("c", 10), photo("d", 9)], minimumSimilarity: 1)]
    return SimilarPhotoGroupingResult(groups: groups, candidateCount: 8, staleCount: 2, unindexedCount: 3,
                                      threshold: threshold, validateAccess: access, validatePhotos: photos)
}

private final class DraftGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    typealias Restore = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingRestore
    typealias Group = @Sendable (Int, Float) async throws -> SimilarPhotoGroupingResult
    struct Trace {
        var events: [String] = []
        var thresholds: [Float] = []
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
         group: @escaping Group = { _, threshold in draftResult(threshold) }) {
        restoreOperation = restore
        groupOperation = group
    }

    var trace: Trace { locked { recorded } }

    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        let index = begin("restore", threshold)
        defer { locked { recorded.active -= 1 } }
        return try await restoreOperation(index, threshold)
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        let index = begin("group", threshold)
        defer { locked { recorded.active -= 1 } }
        await progress(SimilarPhotoGroupingProgress(total: 8, completed: 8, groupCount: 2))
        return try await groupOperation(index, threshold)
    }

    private func begin(_ event: String, _ threshold: Float) -> Int {
        locked {
            let index: Int
            if event == "restore" { index = recorded.restores; recorded.restores += 1 }
            else { index = recorded.groups; recorded.groups += 1 }
            recorded.events.append(event)
            recorded.thresholds.append(threshold)
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

private final class DraftDeletion: PhotoDeleting, @unchecked Sendable {
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

private final class DraftGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Held asynchronous callback entered")
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

private final class DraftSyncGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Held synchronous validator entered")
    private let condition = NSCondition()
    private let fails: Bool
    private var opened = false
    private var returned: [Bool] = []
    init(fails: Bool) { self.fails = fails }
    var cancelledReturns: [Bool] {
        condition.lock(); defer { condition.unlock() }
        return returned
    }
    func wait() throws {
        entered.fulfill()
        guard !Thread.isMainThread else { throw DraftError.mainThread }
        condition.lock()
        while !opened { condition.wait() }
        returned.append(Task.isCancelled)
        condition.unlock()
        if fails { throw DraftError.failed }
    }
    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class DraftValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGate: DraftSyncGate?
    private var recorded: [[String]] = []
    var calls: [[String]] { locked { recorded } }
    var gate: DraftSyncGate? {
        get { locked { storedGate } }
        set { locked { storedGate = newValue } }
    }
    func photos(_ ids: [String]) throws {
        let held = locked { recorded.append(ids); return storedGate }
        try held?.wait()
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Coordinator install milestones also include immediately granted leases.
/// Registering after an event is safe; each expectation is fulfilled once.
private final class DraftEnqueues: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, XCTestExpectation)] = []
    var total: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func send() {
        lock.lock()
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        lock.unlock()
        ready.forEach { $0.1.fulfill() }
    }
    func at(_ target: Int) -> XCTestExpectation {
        let event = XCTestExpectation(description: "Coordinator acquired/queued \(target) leases")
        lock.lock()
        let ready = count >= target
        if !ready { waiters.append((target, event)) }
        lock.unlock()
        if ready { event.fulfill() }
        return event
    }
}