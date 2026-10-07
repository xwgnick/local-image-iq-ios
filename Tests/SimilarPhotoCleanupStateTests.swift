import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Synthetic metadata, result-bound validators, and continuation gates only.
/// No PhotoKit client, database, image pixels, AppState, network, or sleeps.
@MainActor
final class SimilarPhotoCleanupStateTests: XCTestCase {
    func testInitializationAndNonScanLifecycleNeverStartWork() async {
        let f = fixture()
        XCTAssertEqual(f.state.threshold, SimilarPhotoGroupingPolicy.defaultThreshold)
        assertEmpty(f.state)
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertNil(f.state.message)
        f.state.toggleSelection("z")
        f.state.selectGroup("first")
        f.state.clearSelection()
        f.state.prepareDeletion()
        f.state.cancelDeletionConfirmation()
        f.state.dismissMessage()
        f.state.pause()
        f.state.resume()
        f.state.invalidateAccess()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.grouping.calls.thresholds.isEmpty)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        XCTAssertEqual(f.validation.accessChecks, 0)
        XCTAssertTrue(f.validation.photoChecks.isEmpty)
    }

    func testExplicitScanPublishesSuppliedOrderCountsAndNoDefaultSelection() async {
        let f = fixture()
        f.state.scan()
        XCTAssertTrue(f.state.isGrouping)
        assertEmpty(f.state)
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.isGrouping)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.state.groups.map(\.id), ["first", "second"])
        XCTAssertEqual(f.state.groups.map { $0.photos.map(\.id) }, [["z", " a/id \n", "b"], ["d", "c"]])
        XCTAssertEqual(f.state.candidateCount, 9)
        XCTAssertEqual(f.state.staleCount, 2)
        XCTAssertEqual(f.state.unindexedCount, 4)
        XCTAssertEqual(f.state.selectedCount, 0)
        XCTAssertTrue(f.state.orderedSelectedPhotos.isEmpty)
        XCTAssertEqual(f.validation.accessChecks, 1)
        XCTAssertTrue(f.validation.photoChecks.isEmpty)
        XCTAssertEqual(f.grouping.calls.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testThresholdChangesInvalidateWithoutRegroupingAndEqualValueKeepsIntent() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.selectGroup("first")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.threshold = SimilarPhotoGroupingPolicy.defaultThreshold
        XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
        XCTAssertTrue(f.state.hasScanned)
        f.state.threshold = 0.98
        assertEmpty(f.state)
        f.state.confirmDeletion(intent)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertEqual(f.grouping.calls.thresholds.count, 1)
        XCTAssertTrue(f.deletion.calls.isEmpty)
        await scan(f.state)
        XCTAssertEqual(f.grouping.calls.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold, 0.98])
        XCTAssertTrue(f.state.hasScanned)
    }

    func testInvalidThresholdsFailBeforeServiceEntryWithoutLazyCorrection() async {
        let f = fixture()
        let invalid: [Float] = [.nan, .infinity, -.infinity, Float(0.50).nextDown, Float(0.99).nextUp]
        for threshold in invalid {
            f.state.threshold = threshold
            XCTAssertTrue(f.grouping.calls.thresholds.isEmpty)
            f.state.scan()
            await f.state.waitUntilIdle()
            assertEmpty(f.state)
            XCTAssertFalse(f.state.isGrouping)
            XCTAssertNotNil(f.state.message)
            if threshold.isNaN { XCTAssertTrue(f.state.threshold.isNaN) }
            else { XCTAssertEqual(f.state.threshold, threshold) }
        }
        XCTAssertTrue(f.grouping.calls.thresholds.isEmpty)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testReplacementDrainsWholeChainAndRejectsOldProgressSuccessAndFailure() async {
        for failOld in [false, true] {
            let old = hold(), latest = hold()
            let service = CleanupGrouping { call, threshold in
                if call == 0 {
                    await old.wait()
                    if failOld { throw cleanupPrivateError() }
                    return cleanupResult(threshold: threshold, candidateCount: 999)
                }
                await latest.wait()
                return cleanupResult(threshold: threshold)
            }
            let state = SimilarPhotoCleanupState(grouping: service, deletion: CleanupDeletion())
            state.scan()
            await entered(old)
            let initial = SimilarPhotoGroupingProgress(total: 9, completed: 2, groupCount: 1)
            await service.emit(initial, call: 0)
            XCTAssertEqual(state.progress, initial)
            state.scan() // This queued replacement must itself be drained/skipped.
            state.scan()
            XCTAssertTrue(old.cancelled)
            assertEmpty(state)
            await service.emit(SimilarPhotoGroupingProgress(total: 999, completed: 998), call: 0)
            XCTAssertEqual(state.progress, SimilarPhotoGroupingProgress())
            old.open()
            await entered(latest)
            XCTAssertEqual(service.calls.thresholds.count, 2, "The cancelled middle request never enters the service")
            XCTAssertEqual(service.calls.maximumActive, 1)
            XCTAssertTrue(state.isGrouping)
            XCTAssertFalse(state.hasScanned)
            XCTAssertNil(state.message)
            let current = SimilarPhotoGroupingProgress(total: 9, completed: 5, groupCount: 2)
            await service.emit(current, call: 1)
            await service.emit(SimilarPhotoGroupingProgress(total: 999, completed: 999), call: 0)
            XCTAssertEqual(state.progress, current)
            latest.open()
            await state.waitUntilIdle()
            XCTAssertEqual(state.candidateCount, 9)
            XCTAssertNil(state.message)
            XCTAssertFalse(state.isGrouping)
            await service.emit(initial, call: 1)
            XCTAssertEqual(state.progress, current, "Even same-token progress after completion is ignored")
        }
    }

    func testThresholdChangeCancelsInFlightReadAndRejectsLatePublication() async {
        let gate = hold()
        let service = CleanupGrouping { _, threshold in
            await gate.wait()
            return cleanupResult(threshold: threshold)
        }
        let state = SimilarPhotoCleanupState(grouping: service, deletion: CleanupDeletion())
        state.scan()
        await entered(gate)
        state.threshold = 0.97
        XCTAssertTrue(gate.cancelled)
        await service.emit(SimilarPhotoGroupingProgress(total: 9, completed: 8), call: 0)
        gate.open()
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertFalse(state.isGrouping)
        XCTAssertNil(state.message)
        XCTAssertEqual(service.calls.thresholds, [SimilarPhotoGroupingPolicy.defaultThreshold])
    }

    func testPauseCancelsReadAndResumeOnlyEnablesExplicitScan() async {
        let gate = hold()
        let service = CleanupGrouping { call, threshold in
            if call == 0 { await gate.wait() }
            return cleanupResult(threshold: threshold)
        }
        let state = SimilarPhotoCleanupState(grouping: service, deletion: CleanupDeletion())
        state.scan()
        await entered(gate)
        state.pause()
        state.scan() // Background must not even queue a read.
        XCTAssertTrue(gate.cancelled)
        state.resume()
        await service.emit(SimilarPhotoGroupingProgress(total: 9, completed: 9), call: 0)
        gate.open()
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.calls.thresholds.count, 1)
        await scan(state)
        XCTAssertTrue(state.hasScanned)
        XCTAssertEqual(service.calls.thresholds.count, 2)
    }

    func testAccessInvalidationCancelsReadWithoutAutomaticRefresh() async {
        let gate = hold()
        let service = CleanupGrouping { _, threshold in
            await gate.wait()
            return cleanupResult(threshold: threshold)
        }
        let state = SimilarPhotoCleanupState(grouping: service, deletion: CleanupDeletion())
        state.scan()
        await entered(gate)
        state.invalidateAccess()
        XCTAssertTrue(gate.cancelled)
        gate.open()
        await state.waitUntilIdle()
        assertEmpty(state)
        XCTAssertEqual(service.calls.thresholds.count, 1)
        XCTAssertNil(state.message)
    }

    func testPublicationValidatesActualResultAndReadErrorsNeverExposePrivateText() async {
        for mode in 0..<4 {
            let validation = CleanupValidation(photos: cleanupGroups().flatMap(\.photos))
            if mode == 0 { validation.accessError = cleanupPrivateError() }
            let service = CleanupGrouping { _, threshold in
                if mode == 1 { throw cleanupPrivateError() }
                if mode == 2 { throw CancellationError() }
                return cleanupResult(threshold: mode == 3 ? 0.90 : threshold, validation: validation)
            }
            let state = SimilarPhotoCleanupState(grouping: service, deletion: CleanupDeletion())
            await scan(state)
            assertEmpty(state)
            XCTAssertFalse(state.isGrouping)
            if mode == 2 { XCTAssertNil(state.message) }
            else {
                XCTAssertEqual(state.message, "未能完成相似照片分组，请确认照片访问权限后手动重新分组。")
            }
            XCTAssertEqual(validation.accessChecks, mode == 0 ? 1 : 0)
        }
        let empty = CleanupGrouping { _, threshold in
            cleanupResult(groups: [], threshold: threshold, candidateCount: 0)
        }
        let state = SimilarPhotoCleanupState(grouping: empty, deletion: CleanupDeletion())
        await scan(state)
        XCTAssertTrue(state.hasScanned, "A completed empty read is distinct from unknown/unscanned")
        XCTAssertTrue(state.groups.isEmpty)
        XCTAssertNil(state.message)
    }

    func testSelectionIsOnlyPublishedIDsAndSynchronouslyValidatesBeforeChanging() async {
        let f = fixture()
        await scan(f.state)
        f.state.toggleSelection("outside-result")
        f.state.selectGroup("unknown")
        XCTAssertTrue(f.validation.photoChecks.isEmpty)
        f.state.toggleSelection("z")
        XCTAssertEqual(f.state.selectedIDs, Set(["z"]))
        XCTAssertEqual(f.validation.photoChecks, [["z"]])
        f.state.toggleSelection("z")
        XCTAssertEqual(f.state.selectedCount, 0)
        XCTAssertEqual(f.validation.photoChecks, [["z"], ["z"]])
        f.validation.photoError = cleanupPrivateError()
        f.state.toggleSelection("c")
        assertEmpty(f.state)
        XCTAssertEqual(f.state.message, PhotoDeletionError.accessChanged.localizedDescription)
        XCTAssertTrue(f.deletion.calls.isEmpty)

        for prepare in [false, true] {
            let denied = fixture()
            await scan(denied.state)
            if prepare { denied.state.toggleSelection("z") }
            denied.validation.photoError = cleanupPrivateError()
            if prepare { denied.state.prepareDeletion() }
            else { denied.state.selectGroup("first") }
            assertEmpty(denied.state)
            XCTAssertEqual(denied.state.message, PhotoDeletionError.accessChanged.localizedDescription)
            XCTAssertTrue(denied.deletion.calls.isEmpty)
        }
    }

    func testSelectGroupAllowsAllMembersAndPreservesSuppliedDisplayOrder() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.selectGroup("second")
        f.state.selectGroup("first")
        f.state.selectGroup("first") // Union, not deselection or a keep-one rule.
        XCTAssertEqual(f.state.selectedCount, 5)
        XCTAssertEqual(f.state.orderedSelectedPhotos.map(\.id), ["z", " a/id \n", "b", "d", "c"])
        XCTAssertEqual(f.validation.photoChecks, [["d", "c"], ["z", " a/id \n", "b"], ["z", " a/id \n", "b"]])
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertEqual(intent.count, 5)
        XCTAssertEqual(intent.emptiedGroupCount, 2)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testPrepareCapturesImmutableExactRevisionsAndOnlyFullySelectedGroupCount() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.prepareDeletion()
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertEqual(f.state.message, PhotoDeletionError.emptySelection.localizedDescription)
        f.state.toggleSelection("c")
        f.state.selectGroup("first")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertEqual(intent.revisions, [cleanupRevision("z", modification: 41, creation: nil),
            cleanupRevision(" a/id \n", modification: 42, creation: -10),
            cleanupRevision("b", modification: 43, creation: 13),
            cleanupRevision("c", modification: 45, creation: 15)])
        XCTAssertEqual(intent.count, 4)
        XCTAssertEqual(intent.emptiedGroupCount, 1)
        f.state.clearSelection()
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertEqual(intent.count, 4, "A captured confirmation value never follows later checkbox edits")
        XCTAssertEqual(intent.revisions.first?.modificationTime, 41)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testCancellingConfirmationAndDismissingMessageNeverDeleteOrChangeSelection() async throws {
        let f = fixture()
        await scan(f.state)
        f.state.selectGroup("first")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        f.state.dismissMessage()
        XCTAssertEqual(f.state.pendingDeletion?.id, intent.id)
        f.state.prepareDeletion()
        let replacement = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertNotEqual(replacement.id, intent.id)
        XCTAssertEqual(replacement.sessionID, intent.sessionID)
        XCTAssertEqual(replacement.revisions, intent.revisions)
        f.state.confirmDeletion(intent)
        XCTAssertEqual(f.state.pendingDeletion?.id, replacement.id)
        f.state.cancelDeletionConfirmation()
        f.state.cancelDeletionConfirmation()
        f.state.confirmDeletion(replacement)
        await f.state.waitUntilIdle()
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertEqual(f.state.selectedCount, 3)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertEqual(f.state.groups.count, 2)
        XCTAssertTrue(f.deletion.calls.isEmpty)
    }

    func testCheckboxGroupAndClearChangesInvalidateAnExistingConfirmation() async throws {
        for mode in 0..<3 {
            let f = fixture()
            await scan(f.state)
            f.state.toggleSelection("z")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            if mode == 0 { f.state.toggleSelection("z") }
            else if mode == 1 { f.state.selectGroup("second") }
            else { f.state.clearSelection() }
            XCTAssertNil(f.state.pendingDeletion)
            f.state.confirmDeletion(intent)
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.deletion.calls.isEmpty)
            XCTAssertTrue(f.state.hasScanned)
        }
    }

    func testThresholdLibraryBackgroundAndNewScanInvalidatePendingConfirmation() async throws {
        for mode in 0..<4 {
            let f = fixture()
            await scan(f.state)
            f.state.selectGroup("first")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            if mode == 0 { f.state.threshold = 0.98 }
            else if mode == 1 { f.state.invalidateAccess() }
            else if mode == 2 { f.state.pause() }
            else { f.state.scan() }
            assertEmpty(f.state)
            f.state.resume()
            f.state.confirmDeletion(intent)
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.deletion.calls.isEmpty)
            XCTAssertEqual(f.grouping.calls.thresholds.count, mode == 3 ? 2 : 1)
        }
    }

    func testReplacementUsesNewResultValidatorAndSessionNotOldQueryScope() async throws {
        let originalGroups = cleanupGroups()
        let revisedGroups = [SimilarPhotoGroup(id: "first", photos: [
            cleanupPhoto("z", modification: 141, creation: 101),
            cleanupPhoto("b", modification: 143, creation: nil)], minimumSimilarity: 0.97)]
        let original = CleanupValidation(photos: originalGroups.flatMap(\.photos))
        let revised = CleanupValidation(photos: revisedGroups.flatMap(\.photos))
        let service = CleanupGrouping { call, threshold in
            cleanupResult(groups: call == 0 ? originalGroups : revisedGroups, threshold: threshold,
                          validation: call == 0 ? original : revised)
        }
        let deletion = CleanupDeletion()
        let state = SimilarPhotoCleanupState(grouping: service, deletion: deletion)
        await scan(state)
        state.selectGroup("first")
        state.prepareDeletion()
        let old = try XCTUnwrap(state.pendingDeletion)
        await scan(state)
        let oldChecks = original.photoChecks
        original.photoError = cleanupPrivateError()
        state.selectGroup("first")
        state.prepareDeletion()
        let current = try XCTUnwrap(state.pendingDeletion)
        XCTAssertNotEqual(current.sessionID, old.sessionID)
        state.confirmDeletion(old)
        XCTAssertEqual(state.pendingDeletion?.id, current.id, "An old UI callback cannot dismiss a new intent")
        XCTAssertTrue(deletion.calls.isEmpty)
        state.confirmDeletion(current)
        await state.waitUntilIdle()
        XCTAssertEqual(deletion.calls, [current.revisions])
        XCTAssertEqual(current.revisions, [cleanupRevision("z", modification: 141, creation: 101),
                                            cleanupRevision("b", modification: 143, creation: nil)])
        XCTAssertEqual(original.photoChecks, oldChecks)
        XCTAssertEqual(revised.photoChecks, [["z", "b"], ["z", "b"], ["z", "b"]])
    }

    func testCopiedIntentIDCannotAuthorizeAlteredSessionRevisionsIDsOrWarning() async throws {
        for mode in 0..<5 {
            let f = fixture()
            await scan(f.state)
            f.state.selectGroup("first")
            f.state.prepareDeletion()
            let valid = try XCTUnwrap(f.state.pendingDeletion)
            var revisions = valid.revisions
            if mode == 1 { revisions[0] = cleanupRevision("z", modification: 999, creation: nil) }
            if mode == 2 { revisions[0] = cleanupRevision("z", modification: 41, creation: 0) }
            if mode == 3 { revisions[0] = cleanupRevision("outside-result") }
            let altered = SimilarPhotoDeletionIntent(id: valid.id,
                sessionID: mode == 0 ? UUID() : valid.sessionID, revisions: revisions,
                emptiedGroupCount: mode == 4 ? 0 : valid.emptiedGroupCount)
            f.state.confirmDeletion(altered)
            await f.state.waitUntilIdle()
            XCTAssertTrue(f.deletion.calls.isEmpty)
            XCTAssertNil(f.state.pendingDeletion)
            XCTAssertEqual(f.state.message, PhotoDeletionError.invalidSelection.localizedDescription)
        }
    }

    func testConfirmationRevalidatesExactSelectionAndRejectsAccessOrRevisionChanges() async throws {
        for mode in 0..<3 {
            let f = fixture()
            await scan(f.state)
            f.state.toggleSelection("b")
            f.state.toggleSelection("z")
            f.state.prepareDeletion()
            let intent = try XCTUnwrap(f.state.pendingDeletion)
            if mode == 0 { f.validation.photoError = cleanupPrivateError() }
            else if mode == 1 {
                f.validation.replaceCurrent(cleanupRevision("z", modification: 41, creation: 99))
            } else {
                f.validation.replaceCurrent(cleanupRevision("z", modification: 141, creation: nil))
            }
            f.state.confirmDeletion(intent)
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.validation.photoChecks, [["b"], ["z"], ["z", "b"], ["z", "b"]])
            assertEmpty(f.state)
            XCTAssertTrue(f.deletion.calls.isEmpty)
            XCTAssertEqual(f.state.message, PhotoDeletionError.accessChanged.localizedDescription)
        }
    }

    func testOnlyConfirmDeletesExactlyOnceAndBusyStateBlocksSelectionAndScans() async throws {
        let gate = hold()
        let deletion = CleanupDeletion { _ in await gate.wait() }
        let f = fixture(deletion: deletion)
        await scan(f.state)
        f.state.selectGroup("second")
        f.state.selectGroup("first")
        f.state.prepareDeletion()
        let intent = try XCTUnwrap(f.state.pendingDeletion)
        XCTAssertTrue(deletion.calls.isEmpty)
        f.state.confirmDeletion(intent)
        XCTAssertNil(f.state.pendingDeletion)
        XCTAssertTrue(f.state.isDeleting)
        f.state.confirmDeletion(intent)
        await entered(gate)
        f.state.toggleSelection("z")
        f.state.selectGroup("second")
        f.state.clearSelection()
        f.state.prepareDeletion()
        f.state.scan()
        f.state.cancelDeletionConfirmation()
        f.state.dismissMessage()
        XCTAssertEqual(f.state.selectedCount, 5)
        XCTAssertEqual(deletion.calls, [intent.revisions])
        XCTAssertEqual(deletion.calls[0].map(\.id), ["z", " a/id \n", "b", "d", "c"])
        XCTAssertEqual(f.grouping.calls.thresholds.count, 1)
        XCTAssertFalse(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        assertEmpty(f.state)
        XCTAssertFalse(f.state.isDeleting)
        XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 5))
        f.state.confirmDeletion(intent)
        await f.state.waitUntilIdle()
        XCTAssertEqual(deletion.calls.count, 1)
    }

    func testPhotosNotificationDuringMutationCannotHideRealSuccessOrRegroup() async throws {
        let gate = hold()
        let f = fixture(deletion: CleanupDeletion { _ in await gate.wait() })
        await scan(f.state)
        f.state.toggleSelection("z")
        f.state.prepareDeletion()
        f.state.confirmDeletion(try XCTUnwrap(f.state.pendingDeletion))
        await entered(gate)
        f.state.invalidateAccess()
        f.validation.photoError = PhotoDeletionError.unavailableAssets
        assertEmpty(f.state)
        XCTAssertTrue(f.state.isDeleting)
        XCTAssertNil(f.state.message)
        XCTAssertFalse(gate.cancelled)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertFalse(f.state.isDeleting)
        let success = f.state.message
        XCTAssertEqual(success, PhotoDeletionRecoveryNotice.success(count: 1))
        f.state.invalidateAccess() // A second notification must retain that outcome.
        XCTAssertEqual(f.state.message, success)
        XCTAssertEqual(f.grouping.calls.thresholds.count, 1)
        XCTAssertEqual(f.deletion.calls.count, 1)
    }

    func testBackgroundAndThresholdChangesNeverCancelQueuedOrBegunDeletion() async throws {
        for pauseBeforeEntry in [false, true] {
            let gate = hold()
            let f = fixture(deletion: CleanupDeletion { _ in await gate.wait() })
            await scan(f.state)
            f.state.toggleSelection("c")
            f.state.prepareDeletion()
            f.state.confirmDeletion(try XCTUnwrap(f.state.pendingDeletion))
            if !pauseBeforeEntry { await entered(gate) }
            f.state.pause()
            f.state.threshold = 0.98
            f.state.invalidateAccess()
            f.state.dismissMessage()
            f.state.scan()
            if pauseBeforeEntry { await entered(gate) }
            XCTAssertTrue(f.state.isDeleting)
            XCTAssertFalse(gate.cancelled)
            gate.open()
            await f.state.waitUntilIdle()
            XCTAssertFalse(f.state.isDeleting)
            XCTAssertEqual(f.state.message, PhotoDeletionRecoveryNotice.success(count: 1))
            f.state.resume()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.grouping.calls.thresholds.count, 1)
            XCTAssertEqual(f.deletion.calls.count, 1)
            assertEmpty(f.state)
        }
    }

    func testDeletionFailuresDeniedAndCancellationReportSafeActualOutcomeWithoutRetry() async throws {
        let known: [PhotoDeletionError] = [.emptySelection, .invalidSelection, .permissionDenied,
            .accessChanged, .unavailableAssets, .revisionChanged, .notDeletable, .cancelled, .mutationFailed]
        let errors: [Error] = known.map { $0 as Error } + [cleanupPrivateError(), CancellationError()]
        for error in errors {
            let gate = hold()
            let f = fixture(deletion: CleanupDeletion { _ in await gate.wait(); throw error })
            await scan(f.state)
            f.state.toggleSelection("z")
            f.state.prepareDeletion()
            f.state.confirmDeletion(try XCTUnwrap(f.state.pendingDeletion))
            await entered(gate)
            f.state.pause()
            f.state.invalidateAccess()
            XCTAssertTrue(f.state.isDeleting, "Read invalidation is not mutation completion")
            XCTAssertNil(f.state.message)
            gate.open()
            await f.state.waitUntilIdle()
            let expected = error is CancellationError ? PhotoDeletionError.cancelled
                : (error as? PhotoDeletionError ?? .mutationFailed)
            XCTAssertEqual(f.state.message, expected.localizedDescription)
            XCTAssertFalse(f.state.message?.contains("未删除") ?? true)
            XCTAssertFalse(f.state.message?.contains("回滚") ?? true)
            XCTAssertFalse(f.state.message?.contains("synthetic-private") ?? true)
            XCTAssertFalse(f.state.isDeleting)
            XCTAssertFalse(gate.cancelled)
            assertEmpty(f.state)
            f.state.resume()
            await f.state.waitUntilIdle()
            XCTAssertEqual(f.deletion.calls.count, 1)
            XCTAssertEqual(f.grouping.calls.thresholds.count, 1)
        }
    }

    func testDeinitCancelsReadsButRetainsDeletionServiceBeforeEntryAndWhileBegun() async throws {
        let read = hold()
        let grouping = CleanupGrouping { _, threshold in
            await read.wait()
            return cleanupResult(threshold: threshold)
        }
        var reader: SimilarPhotoCleanupState? = SimilarPhotoCleanupState(grouping: grouping, deletion: CleanupDeletion())
        let readDone = track { reader?.scan() }
        await entered(read)
        weak var weakReader = reader
        reader = nil
        XCTAssertNil(weakReader)
        XCTAssertTrue(read.cancelled)
        read.open()
        await fulfillment(of: [readDone], timeout: 3)

        for dropBeforeEntry in [false, true] {
            let gate = hold()
            var service: CleanupDeletion? = CleanupDeletion { _ in await gate.wait() }
            weak var weakService = service
            var state: SimilarPhotoCleanupState? = SimilarPhotoCleanupState(
                grouping: CleanupGrouping { _, threshold in cleanupResult(threshold: threshold) },
                deletion: try XCTUnwrap(service))
            state?.scan()
            await state?.waitUntilIdle()
            state?.toggleSelection("z")
            state?.prepareDeletion()
            let intent = try XCTUnwrap(state?.pendingDeletion)
            let done = track { state?.confirmDeletion(intent) }
            if !dropBeforeEntry { await entered(gate) }
            weak var weakState = state
            state = nil
            service = nil
            XCTAssertNil(weakState, "Mutation must not retain the controller across its await")
            XCTAssertNotNil(weakService, "The confirmed task independently owns the service")
            if dropBeforeEntry { await entered(gate) }
            XCTAssertEqual(weakService?.calls, [intent.revisions])
            XCTAssertFalse(gate.cancelled)
            gate.open()
            await fulfillment(of: [done], timeout: 3)
            XCTAssertFalse(gate.cancelled)
        }
    }

    func testWaitUntilIdleJoinsCancelledReadReplacementAndIndependentMutation() async throws {
        let old = hold(), replacement = hold(), deletionGate = hold()
        let service = CleanupGrouping { call, threshold in
            await (call == 0 ? old : replacement).wait()
            return cleanupResult(threshold: threshold)
        }
        let state = SimilarPhotoCleanupState(grouping: service,
            deletion: CleanupDeletion { _ in await deletionGate.wait() })
        state.scan()
        await entered(old)
        state.pause()
        let started = XCTestExpectation(description: "Idle waiter entered")
        let finished = CleanupGate()
        let waiter = Task { @MainActor in
            started.fulfill()
            await state.waitUntilIdle()
            finished.open()
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(finished.isOpen, "Cancelled read still has a live service callback")
        state.resume()
        state.scan()
        old.open()
        await entered(replacement)
        XCTAssertFalse(finished.isOpen, "A replacement scheduled while joining is included")
        replacement.open()
        await waiter.value
        XCTAssertTrue(finished.isOpen)
        state.toggleSelection("z")
        state.prepareDeletion()
        state.confirmDeletion(try XCTUnwrap(state.pendingDeletion))
        await entered(deletionGate)
        state.pause()
        let mutationStarted = XCTestExpectation(description: "Mutation waiter entered")
        let mutationFinished = CleanupGate()
        let mutationWaiter = Task { @MainActor in
            mutationStarted.fulfill()
            await state.waitUntilIdle()
            mutationFinished.open()
        }
        await fulfillment(of: [mutationStarted], timeout: 3)
        XCTAssertFalse(mutationFinished.isOpen)
        XCTAssertTrue(state.isDeleting)
        deletionGate.open()
        await mutationWaiter.value
        XCTAssertTrue(mutationFinished.isOpen)
        XCTAssertFalse(state.isDeleting)
        XCTAssertNotNil(state.message)
    }

    // MARK: Deterministic helpers (timeouts bound tests only, never app work)

    private func scan(_ state: SimilarPhotoCleanupState) async {
        state.scan()
        await state.waitUntilIdle()
    }

    private func fixture(deletion: CleanupDeletion = CleanupDeletion()) -> CleanupFixture {
        let groups = cleanupGroups()
        let validation = CleanupValidation(photos: groups.flatMap(\.photos))
        let grouping = CleanupGrouping { _, threshold in
            cleanupResult(groups: groups, threshold: threshold, validation: validation)
        }
        return CleanupFixture(state: SimilarPhotoCleanupState(grouping: grouping, deletion: deletion),
                              grouping: grouping, deletion: deletion, validation: validation)
    }

    private func assertEmpty(_ state: SimilarPhotoCleanupState,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertEqual(state.candidateCount, 0, file: file, line: line)
        XCTAssertEqual(state.staleCount, 0, file: file, line: line)
        XCTAssertEqual(state.unindexedCount, 0, file: file, line: line)
        XCTAssertEqual(state.selectedCount, 0, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertTrue(state.orderedSelectedPhotos.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertEqual(state.progress, SimilarPhotoGroupingProgress(), file: file, line: line)
    }

    private func hold() -> CleanupGate {
        let gate = CleanupGate()
        addTeardownBlock { gate.open() }
        return gate
    }

    private func entered(_ gate: CleanupGate) async {
        await fulfillment(of: [gate.started], timeout: 3)
    }

    private func track(_ operation: () -> Void) -> XCTestExpectation {
        let done = XCTestExpectation(description: "Entire controller task released")
        CleanupTaskScope.$lifetime.withValue(CleanupTaskLifetime(done)) { operation() }
        return done
    }
}

private struct CleanupFixture {
    let state: SimilarPhotoCleanupState
    let grouping: CleanupGrouping
    let deletion: CleanupDeletion
    let validation: CleanupValidation
}

private func cleanupPhoto(_ id: String, modification: Double, creation: Double?) -> IndexedPhoto {
    IndexedPhoto(id: id, modificationTime: modification, modelVersion: "synthetic-cleanup",
                 imageEmbedding: [1] + [Float](repeating: 0, count: 767), creationTime: creation)
}

private func cleanupRevision(_ id: String, modification: Double = 41, creation: Double? = nil) -> PhotoRevision {
    PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
}

private func cleanupGroups() -> [SimilarPhotoGroup] {
    [SimilarPhotoGroup(id: "first", photos: [
        cleanupPhoto("z", modification: 41, creation: nil),
        cleanupPhoto(" a/id \n", modification: 42, creation: -10),
        cleanupPhoto("b", modification: 43, creation: 13)], minimumSimilarity: 0.97),
     SimilarPhotoGroup(id: "second", photos: [
        cleanupPhoto("d", modification: 44, creation: 14),
        cleanupPhoto("c", modification: 45, creation: 15)], minimumSimilarity: 0.98)]
}

private func cleanupResult(groups: [SimilarPhotoGroup] = cleanupGroups(), threshold: Float,
                           candidateCount: Int = 9, validation: CleanupValidation? = nil) -> SimilarPhotoGroupingResult {
    let bound = validation ?? CleanupValidation(photos: groups.flatMap(\.photos))
    return SimilarPhotoGroupingResult(groups: groups, candidateCount: candidateCount,
        staleCount: 2, unindexedCount: 4, threshold: threshold,
        validateAccess: { try bound.validateAccess() }, validatePhotos: { try bound.validatePhotos($0) })
}

private func cleanupPrivateError() -> Error {
    NSError(domain: "synthetic-private", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "synthetic-private asset z /private/photo.jpg"])
}

/// Each returned result owns one validator. No global/query-scope validator can
/// silently authorize IDs or newer revisions that were not in the result photos.
private final class CleanupValidation: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: [String: PhotoRevision]
    private var current: [String: PhotoRevision]
    private var accessFailure: Error?
    private var photoFailure: Error?
    private var accessCount = 0
    private var selections: [[String]] = []

    init(photos: [IndexedPhoto]) {
        let revisions = Dictionary(uniqueKeysWithValues: photos.map {
            ($0.id, cleanupRevision($0.id, modification: $0.modificationTime, creation: $0.creationTime))
        })
        expected = revisions
        current = revisions
    }

    var accessChecks: Int { locked { accessCount } }
    var photoChecks: [[String]] { locked { selections } }
    var accessError: Error? {
        get { locked { accessFailure } }
        set { locked { accessFailure = newValue } }
    }
    var photoError: Error? {
        get { locked { photoFailure } }
        set { locked { photoFailure = newValue } }
    }

    func replaceCurrent(_ revision: PhotoRevision) { locked { current[revision.id] = revision } }

    func validateAccess() throws {
        try locked {
            accessCount += 1
            if let accessFailure { throw accessFailure }
            guard current == expected else { throw PhotoDeletionError.revisionChanged }
        }
    }

    func validatePhotos(_ ids: [String]) throws {
        try locked {
            selections.append(ids)
            if let photoFailure { throw photoFailure }
            for id in ids {
                guard let revision = expected[id], current[id] == revision else {
                    throw PhotoDeletionError.accessChanged
                }
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class CleanupGrouping: SimilarPhotoGrouping, @unchecked Sendable {
    typealias Progress = @Sendable (SimilarPhotoGroupingProgress) async -> Void
    struct Calls {
        var thresholds: [Float] = []
        var active = 0
        var maximumActive = 0
    }
    private let lock = NSLock()
    private var recorded = Calls()
    private var callbacks: [Progress] = []
    private let operation: @Sendable (Int, Float) async throws -> SimilarPhotoGroupingResult

    init(_ operation: @escaping @Sendable (Int, Float) async throws -> SimilarPhotoGroupingResult) {
        self.operation = operation
    }

    var calls: Calls { locked { recorded } }

    func group(threshold: Float, progress: @escaping Progress) async throws -> SimilarPhotoGroupingResult {
        let index = locked {
            let index = recorded.thresholds.count
            recorded.thresholds.append(threshold)
            recorded.active += 1
            recorded.maximumActive = max(recorded.maximumActive, recorded.active)
            callbacks.append(progress)
            return index
        }
        defer { locked { recorded.active -= 1 } }
        return try await operation(index, threshold)
    }

    func emit(_ value: SimilarPhotoGroupingProgress, call: Int) async {
        let callback: Progress? = locked { callbacks.indices.contains(call) ? callbacks[call] : nil }
        await callback?(value)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

private final class CleanupDeletion: PhotoDeleting, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [[PhotoRevision]] = []
    private let operation: @Sendable ([PhotoRevision]) async throws -> Void

    init(_ operation: @escaping @Sendable ([PhotoRevision]) async throws -> Void = { _ in }) {
        self.operation = operation
    }

    var calls: [[PhotoRevision]] { locked { captured } }

    func delete(revisions: [PhotoRevision]) async throws {
        locked { captured.append(revisions) }
        try await operation(revisions)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

/// Pure read-only observations. Cancellation records a fact but deliberately does
/// not release the callback; only the test can open it. Never polls or sleeps.
private final class CleanupGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Service reached held callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var cancellationObserved = false

    var isOpen: Bool { locked { opened } }
    var cancelled: Bool { locked { cancellationObserved } }

    func wait() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { install($0) }
        }, onCancel: { self.recordCancellation() })
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
        started.fulfill()
        if alreadyOpen { value.resume() }
    }

    private func recordCancellation() { locked { cancellationObserved = true } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

/// Inherited by controller Tasks; completion joins the entire task, not merely
/// the fake service's return. This also tests deinit without retaining the state.
private enum CleanupTaskScope {
    @TaskLocal static var lifetime: CleanupTaskLifetime?
}

private final class CleanupTaskLifetime: @unchecked Sendable {
    private let done: XCTestExpectation
    init(_ done: XCTestExpectation) { self.done = done }
    deinit { done.fulfill() }
}