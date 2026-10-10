import Combine
import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Synthetic grouping metadata and deletion spies only. NSCondition gates hold
/// the exact synchronous validator, not an actor proxy. No Photos, sleeps or I/O.
@MainActor
final class SimilarPhotoSelectionCommitTests: XCTestCase {
    func testBeginGuardsAndCapturesWithoutPhotoValidationOrSelectionMutation() async throws {
        let f = fixture()
        XCTAssertNil(f.state.selectionSessionID)
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "first"))
        f.state.pause()
        XCTAssertNil(f.state.beginRangeSelection(groupID: "first"))
        f.state.resume()
        f.state.scan()
        XCTAssertTrue(f.state.isGrouping)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "first"))
        await f.state.waitUntilIdle()
        let session = try XCTUnwrap(f.state.selectionSessionID)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "unknown"))
        f.state.toggleSelection("a0")
        f.state.toggleSelection("b0")
        f.state.prepareDeletion()
        let oldIntent = try XCTUnwrap(f.state.pendingDeletion)
        let before = f.probes[0].trace
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        XCTAssertTrue(f.state.isSelecting)
        XCTAssertFalse(f.state.isValidatingSelection, "A finger still dragging is not yet metadata validation")
        XCTAssertEqual(f.state.selectionSessionID, session)
        XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertEqual(f.probes[0].trace.photoIDs, before.photoIDs)
        XCTAssertEqual(f.probes[0].trace.accessThreads, before.accessThreads)
        XCTAssertEqual(f.probes[0].trace.epochThreads.count, before.epochThreads.count + 1)
        XCTAssertEqual(f.probes[0].trace.epochThreads.last, true)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "second"))
        f.state.toggleSelection("a1")
        f.state.selectGroup("second")
        f.state.prepareDeletion()
        f.state.confirmDeletion(oldIntent)
        XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.cancelRangeSelection()
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
        XCTAssertTrue(f.state.hasScanned)
    }

    func testCommitValidatesAllChangedIDsOffMainWhileHeartbeatAndSinglePublishStayCorrect() async throws {
        let f = fixture()
        await scan(f.state)
        for id in ["a0", "a7", "b0"] { f.state.toggleSelection(id) }
        f.state.prepareDeletion()
        let oldIntent = try XCTUnwrap(f.state.pendingDeletion)
        let base = f.state.selectedIDs
        let gate = SelectionCommitGate()
        f.probes[0].enqueue(gate)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        var publications: [Set<String>] = []
        let subscription = f.state.$selectedIDs.sink { publications.append($0) }
        defer { subscription.cancel() }
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a1", "a7", "a11"])
        XCTAssertTrue(f.state.isSelecting)
        XCTAssertTrue(f.state.isValidatingSelection)
        try await require(gate.entered)
        XCTAssertEqual(f.probes[0].trace.photoIDs.last, ["a0", "a1", "a11"],
                       "Validate the deselection as well as both additions, not unchanged a7 or other-group b0")
        XCTAssertEqual(f.probes[0].trace.photoThreads.last, false)
        try await heartbeat {
            XCTAssertTrue(f.state.isSelecting)
            XCTAssertFalse(gate.isReleased)
            XCTAssertEqual(f.state.selectedIDs, base)
            XCTAssertEqual(publications, [base])
            f.state.toggleSelection("b0")
            f.state.selectGroup("second")
            f.state.prepareDeletion()
            f.state.confirmDeletion(oldIntent)
            // Duplicate end events cannot replace an already validating capture.
            f.state.finishRangeSelection(token: token, selectedInGroup: [])
            XCTAssertNil(f.state.pendingDeletion)
            XCTAssertTrue(f.deletion.calls.isEmpty)
        }
        gate.release()
        await f.state.waitUntilIdle()
        let desired: Set<String> = ["a1", "a7", "a11", "b0"]
        XCTAssertEqual(f.state.selectedIDs, desired)
        XCTAssertEqual(publications, [base, desired])
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertFalse(f.state.isValidatingSelection)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertEqual(f.probes[0].trace.epochThreads.last, true)
        XCTAssertEqual(gate.returnedCancelled, [false])
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testExactDesiredSetAllowsWholeGroupThenNoMembersWithoutAutomaticKeeper() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("b1")
        let all = Set(selectionCommitGroups()[0].photos.map(\.id))
        let select = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: select, selectedInGroup: all)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, all.union(["b1"]))
        let deselect = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: deselect, selectedInGroup: [])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["b1"]))
        XCTAssertEqual(f.probes[0].trace.photoIDs.suffix(2).map { Set($0) }, [all, all])
        XCTAssertEqual(Array(f.probes[0].trace.photoThreads.suffix(2)), [false, false])
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testForeignDesiredIDsRejectEntireCommitWithoutFilteringOrChangingOtherGroups() async throws {
        for foreign in ["b1", "outside-result"] {
            let f = fixture()
            await scan(f.state)
            f.state.toggleSelection("a0")
            f.state.toggleSelection("b0")
            let session = f.state.selectionSessionID
            let before = f.probes[0].trace.photoIDs
            let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
            f.state.finishRangeSelection(token: token, selectedInGroup: ["a1", foreign])
            await f.state.waitUntilIdle()
            XCTAssertFalse(f.state.isSelecting)
            XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
            XCTAssertEqual(f.state.selectionSessionID, session)
            XCTAssertEqual(f.probes[0].trace.photoIDs, before)
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertNil(f.state.pendingDeletion)
            XCTAssertTrue(f.deletion.calls.isEmpty)
        }
    }

    func testUnchangedDesiredSetHasNoMetadataBatchButStillUsesFinalEpochFence() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a1")
        let before = f.probes[0].trace
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
        XCTAssertTrue(f.state.isSelecting)
        f.state.prepareDeletion()
        XCTAssertNil(f.state.pendingDeletion)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertEqual(f.state.selectedIDs, Set(["a1"]))
        XCTAssertEqual(f.probes[0].trace.photoIDs, before.photoIDs)
        XCTAssertEqual(f.probes[0].trace.epochThreads.count, before.epochThreads.count + 2)
    }

    func testLegacyResultWithDefaultEpochClosureDoesNotRepeatAccessValidation() async throws {
        let f = fixture(checksEpoch: false)
        await scan(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a2", "a11"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["a2", "a11"]))
        XCTAssertEqual(f.probes[0].trace.accessThreads, [false])
        XCTAssertEqual(f.probes[0].trace.photoThreads, [false])
        XCTAssertEqual(f.probes[0].trace.photoIDs, [["a2", "a11"]])
        XCTAssertTrue(f.probes[0].trace.epochThreads.isEmpty)
    }

    func testValidationFailureNeverPublishesPartialDesiredSetAndInvalidatesStaleGroups() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a0")
        f.state.toggleSelection("b0")
        let base = f.state.selectedIDs
        var publications: [Set<String>] = []
        let subscription = f.state.$selectedIDs.sink { publications.append($0) }
        defer { subscription.cancel() }
        let gate = SelectionCommitGate(fails: true)
        f.probes[0].enqueue(gate)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        let epochsAfterBegin = f.probes[0].trace.epochThreads.count
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a1", "a2"])
        try await require(gate.entered)
        XCTAssertEqual(publications, [base])
        XCTAssertTrue(f.state.isSelecting)
        gate.release()
        await f.state.waitUntilIdle()
        assertInvalidated(f.state)
        XCTAssertEqual(publications, [base, Set<String>()])
        assertFailure(f.state, code: .unknown, reason: "原因尚未确定")
        XCTAssertFalse(f.state.message?.contains("synthetic-private") ?? true)
        XCTAssertEqual(f.probes[0].trace.epochThreads.count, epochsAfterBegin)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testBeginEpochFailureClearsStaleGroupsWithoutAnyMetadataBatch() async {
        let f = fixture()
        await scan(f.state)
        f.probes[0].epochFails = true
        XCTAssertNil(f.state.beginRangeSelection(groupID: "first"))
        assertInvalidated(f.state)
        assertFailure(f.state, code: .photoAccessChanged, reason: "照片的可访问范围或内容已变化")
        XCTAssertTrue(f.probes[0].trace.photoIDs.isEmpty)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testFinalEpochFenceRejectsSuccessfulBatchAfterEpochChanges() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("a0")
        let gate = SelectionCommitGate()
        f.probes[0].enqueue(gate)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        let before = f.probes[0].trace.epochThreads.count
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
        try await require(gate.entered)
        f.probes[0].epochFails = true
        gate.release()
        await f.state.waitUntilIdle()
        XCTAssertEqual(gate.returnedCancelled, [false], "The metadata batch itself returned successfully")
        XCTAssertEqual(f.probes[0].trace.epochThreads.count, before + 1)
        assertInvalidated(f.state)
        assertFailure(f.state, code: .photoAccessChanged, reason: "照片的可访问范围或内容已变化")
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testStaleAndUnknownTokensCannotEndOrReplaceCurrentGesture() async throws {
        let f = fixture()
        await scan(f.state)
        let old = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.cancelRangeSelection()
        let current = try XCTUnwrap(f.state.beginRangeSelection(groupID: "second"))
        XCTAssertNotEqual(old, current)
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        f.state.finishRangeSelection(token: UUID(), selectedInGroup: ["foreign"])
        XCTAssertTrue(f.state.isSelecting)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertTrue(f.probes[0].trace.photoIDs.isEmpty)
        f.state.finishRangeSelection(token: current, selectedInGroup: ["b2"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["b2"]))
        XCTAssertEqual(f.probes[0].trace.photoIDs, [["b2"]])
        f.state.finishRangeSelection(token: current, selectedInGroup: [])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["b2"]))
    }

    func testEndThenImmediateCancelSkipsQueuedValidationAndPreservesCommittedIDs() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("b0")
        let before = f.probes[0].trace.photoIDs
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a0", "a1"])
        f.state.cancelRangeSelection() // No suspension: task has not entered validation.
        XCTAssertFalse(f.state.isSelecting)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["b0"]))
        XCTAssertEqual(f.probes[0].trace.photoIDs, before)
        XCTAssertTrue(f.state.hasScanned)
    }

    func testCancelHeldSuccessOrFailurePreservesLaterSingleSelectionAndNewIntent() async throws {
        for fails in [false, true] {
            let f = fixture()
            await scan(f.state)
            f.state.toggleSelection("a0")
            let gate = SelectionCommitGate(fails: fails)
            f.probes[0].enqueue(gate)
            let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
            f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
            try await require(gate.entered)
            f.state.cancelRangeSelection()
            XCTAssertFalse(f.state.isSelecting)
            XCTAssertEqual(f.state.selectedIDs, Set(["a0"]))
            f.state.toggleSelection("b0")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            try await heartbeat {
                XCTAssertFalse(gate.isReleased)
                XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
                XCTAssertTrue(f.state.hasScanned)
            }
            gate.release()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.state.selectedIDs, Set(["a0", "b0"]))
            XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
            XCTAssertNil(f.state.message)
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertEqual(gate.returnedCancelled, [true])
            XCTAssertTrue(f.deletion.calls.isEmpty)
        }
    }

    func testClearCancelsGestureAndValidationWithoutLateSelectionOrIntentPublication() async throws {
        for validating in [false, true] {
            let f = fixture()
            await scan(f.state)
            f.state.toggleSelection("a0")
            let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
            let gate = SelectionCommitGate()
            if validating {
                f.probes[0].enqueue(gate)
                f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
                try await require(gate.entered)
            }
            f.state.clearSelection()
            XCTAssertFalse(f.state.isSelecting)
            XCTAssertTrue(f.state.selectedIDs.isEmpty)
            XCTAssertNil(f.state.pendingDeletion)
            XCTAssertTrue(f.state.hasScanned)
            f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
            f.state.toggleSelection("b1")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            gate.release()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.state.selectedIDs, Set(["b1"]))
            XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
            XCTAssertTrue(f.state.hasScanned)
            XCTAssertTrue(f.deletion.calls.isEmpty)
        }
    }

    func testThresholdChangeCancelsGestureAndValidationWithoutLatePublicationOrScan() async throws {
        try await assertReadInvalidation(retainingBrowsing: true) { $0.threshold = 0.75 }
    }

    func testPauseCancelsGestureAndValidationAndResumeNeverRestoresThem() async throws {
        try await assertReadInvalidation(retainingBrowsing: true) {
            $0.pause()
            XCTAssertNil($0.beginRangeSelection(groupID: "first"))
            $0.scan() // Foreground guard must reject this explicit scan too.
            $0.resume()
        }
    }

    func testAccessInvalidationCancelsGestureAndValidationWithoutLatePublication() async throws {
        try await assertReadInvalidation { $0.invalidateAccess() }
    }

    func testSameThresholdDoesNotInvalidateGestureOrCommit() async throws {
        let f = fixture()
        await scan(f.state)
        let session = f.state.selectionSessionID
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.threshold = SimilarPhotoGroupingPolicy.defaultThreshold
        XCTAssertTrue(f.state.isSelecting)
        XCTAssertEqual(f.state.selectionSessionID, session)
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a4"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["a4"]))
        XCTAssertEqual(f.grouping.calls, 1)
    }

    func testNewScanChangesSessionAndOldGestureCannotPublishIntoReplacement() async throws {
        let f = fixture(probes: [SelectionCommitProbe(), SelectionCommitProbe()])
        await scan(f.state)
        let session = try XCTUnwrap(f.state.selectionSessionID)
        let old = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.scan()
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertNil(f.state.selectionSessionID)
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        await f.state.waitUntilIdle()
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        let current = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        f.state.finishRangeSelection(token: current, selectedInGroup: ["a5"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["a5"]))
        XCTAssertTrue(f.probes[0].trace.photoIDs.isEmpty)
        XCTAssertEqual(f.probes[1].trace.photoIDs, [["a5"]])
    }

    func testNewScanWhileValidationHeldRetainsCancelledTailAndRejectsOldFailure() async throws {
        let oldProbe = SelectionCommitProbe(), freshProbe = SelectionCommitProbe()
        let f = fixture(probes: [oldProbe, freshProbe])
        await scan(f.state)
        let session = f.state.selectionSessionID
        let oldGate = SelectionCommitGate(fails: true)
        oldProbe.enqueue(oldGate)
        let old = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        try await require(oldGate.entered)
        let published = expectation(description: "Replacement result published while old selection is still held")
        let subscription = f.state.$hasScanned.dropFirst().filter { $0 }.prefix(1).sink { _ in published.fulfill() }
        defer { subscription.cancel() }
        f.state.scan()
        assertInvalidated(f.state)
        try await require(published)
        XCTAssertNotEqual(f.state.selectionSessionID, session)
        XCTAssertFalse(oldGate.isReleased)
        XCTAssertTrue(f.state.hasScanned)
        let current = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        f.state.finishRangeSelection(token: current, selectedInGroup: ["a6"])
        try await heartbeat {
            XCTAssertTrue(f.state.isSelecting)
            XCTAssertTrue(f.state.selectedIDs.isEmpty)
            XCTAssertTrue(freshProbe.trace.photoIDs.isEmpty, "New validation drains the old tail first")
        }
        oldGate.release()
        await f.state.waitUntilIdle()
        XCTAssertEqual(oldGate.returnedCancelled, [true])
        XCTAssertEqual(f.state.selectedIDs, Set(["a6"]))
        XCTAssertEqual(freshProbe.trace.photoIDs, [["a6"]])
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertNil(f.state.message)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testIdleWaiterJoinsEntireCancelledChainAndSkipsCancelledQueuedReplacement() async throws {
        let f = fixture()
        await scan(f.state)
        let firstGate = SelectionCommitGate(), latestGate = SelectionCommitGate()
        f.probes[0].enqueue(firstGate)
        f.probes[0].enqueue(latestGate)
        let first = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: first, selectedInGroup: ["a0"])
        try await require(firstGate.entered)
        f.state.cancelRangeSelection()
        let joining = expectation(description: "Idle waiter entered while cancelled validation is held")
        var drained = false
        let waiter = Task { @MainActor in
            joining.fulfill()
            await f.state.waitUntilIdle()
            drained = true
        }
        try await require(joining)
        let middle = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: middle, selectedInGroup: ["a1"])
        f.state.cancelRangeSelection()
        let latest = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: latest, selectedInGroup: ["a2", "a3"])
        try await heartbeat {
            XCTAssertFalse(drained)
            XCTAssertTrue(f.state.isSelecting)
            XCTAssertEqual(f.probes[0].trace.photoIDs, [["a0"]])
        }
        firstGate.release()
        try await require(latestGate.entered)
        XCTAssertFalse(drained)
        XCTAssertTrue(f.state.isSelecting, "Finishing an old task must not clear the latest task's busy flag")
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertEqual(f.probes[0].trace.photoIDs, [["a0"], ["a2", "a3"]])
        XCTAssertEqual(f.probes[0].trace.maximumActive, 1)
        latestGate.release()
        await waiter.value
        XCTAssertTrue(drained)
        XCTAssertFalse(f.state.isSelecting)
        XCTAssertEqual(f.state.selectedIDs, Set(["a2", "a3"]))
        XCTAssertEqual(firstGate.returnedCancelled, [true])
        XCTAssertEqual(latestGate.returnedCancelled, [false])
    }

    func testOldTaskDrainCannotEndNewGestureThatHasNotSubmittedYet() async throws {
        let f = fixture()
        await scan(f.state)
        let gate = SelectionCommitGate()
        f.probes[0].enqueue(gate)
        let old = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: old, selectedInGroup: ["a0"])
        try await require(gate.entered)
        f.state.cancelRangeSelection()
        let new = try XCTUnwrap(f.state.beginRangeSelection(groupID: "second"))
        gate.release()
        await f.state.waitUntilIdle() // Joins work, not a finger still on screen.
        XCTAssertTrue(f.state.isSelecting)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        f.state.prepareDeletion()
        XCTAssertNil(f.state.pendingDeletion)
        f.state.finishRangeSelection(token: new, selectedInGroup: ["b0", "b2"])
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.state.selectedIDs, Set(["b0", "b2"]))
        XCTAssertFalse(f.state.isSelecting)
    }

    func testNoDeletionUntilExplicitConfirmationAndFinalChainUsesExactOrderedRevisions() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("b0")
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["a11", "a0"])
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertEqual(intent.revisions.map(\.id), ["a0", "a11", "b0"])
        XCTAssertEqual(intent.emptiedGroupCount, 0)
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.deletion.calls.isEmpty)
        f.state.confirmDeletion(intent)
        XCTAssertTrue(f.state.isDeleting)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "first"))
        f.state.confirmDeletion(intent)
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.deletion.calls, [intent.revisions])
        XCTAssertNil(f.state.message)
        XCTAssertEqual(f.state.statusNotice, "已删除3张照片")
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertFalse(f.state.canSelect)
        XCTAssertFalse(f.state.canBrowse, "A legacy fixture has no early display-check provider")
        XCTAssertTrue(Set(f.state.groups.flatMap(\.photos).map(\.id)).isDisjoint(with: intent.revisions.map(\.id)))
        XCTAssertFalse(f.state.isDeleting)
    }

    func testRecoveryNoticeMatchesRequestedSystemPathAndQualifiedRecoveryConditions() {
        XCTAssertEqual(PhotoDeletionRecoveryNotice.recovery,
            "通常会在系统“照片”的“最近删除”中保留30天，可前往那里恢复；以系统显示的剩余天数为准。提前永久删除后无法恢复。共享图库中的照片只能由添加者恢复。")
    }

    func testWarningIncludesSystemICloudSyncEvenWhenAppNetworkingIsOffAndOptionalFullGroupWarning() {
        let ordinary = PhotoDeletionRecoveryNotice.warning(emptiedGroupCount: 0)
        XCTAssertTrue(ordinary.contains("启用 iCloud 照片时，删除会同步到其他设备"))
        XCTAssertTrue(ordinary.contains("即使本 App 关闭网络访问，系统仍可能同步删除"))
        XCTAssertTrue(ordinary.contains(PhotoDeletionRecoveryNotice.recovery))
        XCTAssertFalse(ordinary.contains("已选中0个分组"))
        let full = PhotoDeletionRecoveryNotice.warning(emptiedGroupCount: 2)
        XCTAssertTrue(full.contains(PhotoDeletionRecoveryNotice.recovery))
        XCTAssertTrue(full.contains("已选中2个分组的全部照片"))
        XCTAssertTrue(full.contains("不保留任何照片"))
    }

    func testSuccessConfirmsDeletionAndRecoveryWithoutManualRegroupAdvice() {
        XCTAssertEqual(PhotoDeletionRecoveryNotice.success(count: 7),
            "已确认删除7张照片。" + PhotoDeletionRecoveryNotice.recovery)
    }

    // MARK: Deterministic gates; timeouts bound tests only, never app work.

    private func assertFailure(_ state: SimilarPhotoCleanupState, code: SimilarCleanupDiagnostic.Code, reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.failureDiagnostic, SimilarCleanupDiagnostic(phase: .selection, code: code), file: file, line: line)
        XCTAssertNil(state.failureDiagnostic?.nativeCode, file: file, line: line)
        XCTAssertEqual(state.failureOperation, .selection, file: file, line: line)
        XCTAssertTrue(state.message?.hasPrefix("\(code.rawValue) · selection\n") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains(reason) == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("本次未删除照片") == true, file: file, line: line)
        XCTAssertTrue(state.message?.contains("已有索引未清除") == true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("synthetic-private") ?? true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("asset metadata") ?? true, file: file, line: line)
        XCTAssertFalse(state.message?.contains("照片权限") ?? true, file: file, line: line)
    }

    private func fixture(probes: [SelectionCommitProbe] = [SelectionCommitProbe()],
                         checksEpoch: Bool = true) -> SelectionCommitFixture {
        let grouping = SelectionCommitGrouping(probes: probes, checksEpoch: checksEpoch)
        let deletion = SelectionCommitDeletion()
        let state = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        addTeardownBlock { @MainActor in
            // A timed-out expectation must release EVERY gate BEFORE joining.
            // Release queued gates too, not only the currently executing one.
            for probe in probes { probe.releaseAll() }
            state.pause()
            await state.waitUntilIdle()
            XCTAssertFalse(state.isSelecting)
        }
        return SelectionCommitFixture(state: state, grouping: grouping, deletion: deletion, probes: probes)
    }

    private func scan(_ state: SimilarPhotoCleanupState) async {
        state.scan()
        await state.waitUntilIdle()
    }

    private func require(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Missing event: \(event.expectationDescription)")
            throw SelectionCommitFailure.expectation
        }
    }

    private func heartbeat(_ inspect: @escaping @MainActor () -> Void) async throws {
        let event = expectation(description: "MainActor heartbeat while selection validation is held")
        let task = Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            inspect()
            event.fulfill()
        }
        try await require(event)
        await task.value
    }

    private func assertReadInvalidation(retainingBrowsing: Bool = false,
                                        _ invalidate: (SimilarPhotoCleanupState) -> Void) async throws {
        for validating in [false, true] {
            for fails in [false, true] {
                let f = fixture()
                await scan(f.state)
                let members = f.state.groups.map { $0.photos.map(\.id) }
                let candidateCount = f.state.candidateCount
                let check: @MainActor () -> Void = {
                    if retainingBrowsing {
                        XCTAssertEqual(f.state.groups.map { $0.photos.map(\.id) }, members)
                        XCTAssertEqual(f.state.candidateCount, candidateCount)
                        XCTAssertTrue(f.state.hasScanned)
                        XCTAssertNotNil(f.state.browsingSessionID)
                        XCTAssertFalse(f.state.canSelect)
                        XCTAssertFalse(f.state.isSelecting)
                        XCTAssertFalse(f.state.isValidatingSelection)
                        XCTAssertTrue(f.state.selectedIDs.isEmpty)
                        XCTAssertNil(f.state.pendingDeletion)
                    } else { self.assertInvalidated(f.state) }
                }
                f.state.toggleSelection("a0")
                let gate = SelectionCommitGate(fails: fails)
                let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "first"))
                if validating {
                    f.probes[0].enqueue(gate)
                    f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
                    try await require(gate.entered)
                }
                let epochs = f.probes[0].trace.epochThreads.count
                invalidate(f.state)
                check()
                f.state.finishRangeSelection(token: token, selectedInGroup: ["a1"])
                try await heartbeat {
                    check()
                    XCTAssertEqual(f.grouping.calls, 1)
                }
                gate.release()
                await f.state.waitUntilIdle()
                check()
                XCTAssertNil(f.state.message)
                XCTAssertEqual(f.probes[0].trace.epochThreads.count, epochs)
                XCTAssertEqual(f.grouping.calls, 1)
                XCTAssertTrue(f.deletion.calls.isEmpty)
                if validating { XCTAssertEqual(gate.returnedCancelled, [true]) }
            }
        }
    }

    private func assertInvalidated(_ state: SimilarPhotoCleanupState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.isSelecting, file: file, line: line)
        XCTAssertFalse(state.isValidatingSelection, file: file, line: line)
        XCTAssertNil(state.selectionSessionID, file: file, line: line)
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertEqual(state.candidateCount, 0, file: file, line: line)
        XCTAssertEqual(state.staleCount, 0, file: file, line: line)
        XCTAssertEqual(state.unindexedCount, 0, file: file, line: line)
    }
}

private enum SelectionCommitFailure: Error { case expectation, mainThread }

private struct SelectionCommitFixture {
    let state: SimilarPhotoCleanupState
    let grouping: SelectionCommitGrouping
    let deletion: SelectionCommitDeletion
    let probes: [SelectionCommitProbe]
}

private func selectionCommitGroups() -> [SimilarPhotoGroup] {
    var vector = [Float](repeating: 0, count: 768)
    vector[0] = 1
    var first: [IndexedPhoto] = []
    var second: [IndexedPhoto] = []
    for index in 0..<12 {
        first.append(IndexedPhoto(id: "a\(index)", modificationTime: Double(index + 10),
            modelVersion: "synthetic-selection", imageEmbedding: vector, creationTime: Double(index)))
    }
    for index in 0..<3 {
        second.append(IndexedPhoto(id: "b\(index)", modificationTime: Double(index + 30),
            modelVersion: "synthetic-selection", imageEmbedding: vector, creationTime: nil))
    }
    return [SimilarPhotoGroup(id: "first", photos: first, minimumSimilarity: 0.99),
            SimilarPhotoGroup(id: "second", photos: second, minimumSimilarity: 0.98)]
}

private final class SelectionCommitGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Exact synchronous selection validator entered")
    private let condition = NSCondition()
    private let fails: Bool
    private var released = false
    private var cancelledAtReturn: [Bool] = []

    init(fails: Bool = false) { self.fails = fails }

    var isReleased: Bool { condition.lock(); defer { condition.unlock() }; return released }
    var returnedCancelled: [Bool] {
        condition.lock(); defer { condition.unlock() }; return cancelledAtReturn
    }

    func validate() throws {
        entered.fulfill()
        // Regression must fail, not block MainActor from releasing its own gate.
        guard !Thread.isMainThread else { throw SelectionCommitFailure.mainThread }
        condition.lock()
        while !released { condition.wait() }
        cancelledAtReturn.append(withUnsafeCurrentTask { $0?.isCancelled ?? false })
        condition.unlock()
        if fails {
            throw NSError(domain: "synthetic-private-selection", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private asset metadata"])
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// Lock methods are synchronous and rethrows; no NSLock operation spans await.
private final class SelectionCommitProbe: @unchecked Sendable {
    struct Trace {
        var photoIDs: [[String]] = []
        var photoThreads: [Bool] = []
        var accessThreads: [Bool] = []
        var epochThreads: [Bool] = []
        var maximumActive = 0
    }
    private let lock = NSLock()
    private var recorded = Trace()
    private var gates: [SelectionCommitGate] = []
    private var nextGate = 0
    private var active = 0
    private var badEpoch = false

    var trace: Trace { locked { recorded } }
    var epochFails: Bool {
        get { locked { badEpoch } }
        set { locked { badEpoch = newValue } }
    }

    func enqueue(_ gate: SelectionCommitGate) { locked { gates.append(gate) } }
    func releaseAll() {
        let all = locked { gates }
        for gate in all { gate.release() }
    }

    func validateAccess() { locked { recorded.accessThreads.append(Thread.isMainThread) } }

    func validateEpoch() throws {
        try locked {
            recorded.epochThreads.append(Thread.isMainThread)
            if badEpoch { throw PhotoDeletionError.accessChanged }
        }
    }

    func validatePhotos(_ ids: [String]) throws {
        let gate: SelectionCommitGate? = locked {
            recorded.photoIDs.append(ids)
            recorded.photoThreads.append(Thread.isMainThread)
            active += 1
            recorded.maximumActive = max(recorded.maximumActive, active)
            guard nextGate < gates.count else { return nil }
            let gate = gates[nextGate]
            nextGate += 1
            return gate
        }
        defer { locked { active -= 1 } }
        try gate?.validate()
        let allowed = Set(selectionCommitGroups().flatMap(\.photos).map(\.id))
        guard Set(ids).isSubset(of: allowed) else { throw PhotoDeletionError.invalidSelection }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class SelectionCommitGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    private let probes: [SelectionCommitProbe]
    private let checksEpoch: Bool
    private let lock = NSLock()
    private var count = 0

    init(probes: [SelectionCommitProbe], checksEpoch: Bool) {
        self.probes = probes
        self.checksEpoch = checksEpoch
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void)
        async throws -> SimilarPhotoGroupingResult {
        let probe = nextProbe()
        if checksEpoch {
            return SimilarPhotoGroupingResult(groups: selectionCommitGroups(), candidateCount: 15,
                staleCount: 2, unindexedCount: 4, threshold: threshold,
                validateAccess: { probe.validateAccess() },
                validatePhotos: { try probe.validatePhotos($0) },
                validatePublicationEpoch: { try probe.validateEpoch() })
        }
        // Deliberately exercise the real default epoch closure, not a copied one.
        return SimilarPhotoGroupingResult(groups: selectionCommitGroups(), candidateCount: 15,
            staleCount: 2, unindexedCount: 4, threshold: threshold,
            validateAccess: { probe.validateAccess() }, validatePhotos: { try probe.validatePhotos($0) })
    }

    private func nextProbe() -> SelectionCommitProbe {
        lock.lock(); defer { lock.unlock() }
        let probe = probes[min(count, probes.count - 1)]
        count += 1
        return probe
    }
}

private final class SelectionCommitDeletion: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PhotoRevision]] = []
    var calls: [[PhotoRevision]] { lock.lock(); defer { lock.unlock() }; return recorded }

    func delete(revisions: [PhotoRevision]) async throws { record(revisions) }

    private func record(_ revisions: [PhotoRevision]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(revisions)
    }
}