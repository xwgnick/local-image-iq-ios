import Combine
import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

/// Read/selection controller contracts only. All results/errors are synthetic;
/// there is no PhotoKit, SQLite, index, model, cache or network work in this file.
@MainActor
final class SimilarCleanupFailureStateTests: XCTestCase {
    private var readHolds: [FailureReadHold] = []
    private var selectionHolds: [FailureSelectionHold] = []

    func testInitialDiagnosticsAreNilAndReadinessWithoutEntryDoesNoWork() async {
        let f = fixture()
        assertNoFailure(f.state)
        f.state.availabilityChanged(ready: true)
        f.state.resume()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.service.events.isEmpty)
        assertNoFailure(f.state)
    }

    func testFirstEntryPermissionFailureHasGenuinePermissionHintAndNoComputeFallback() async {
        let f = fixture(restore: { _ in throw AppFailure.permission })
        await enter(f.state)
        assertFailure(f.state, .init(phase: .photos, code: .permissionDenied), operation: .restore)
        XCTAssertTrue(f.state.message?.contains("系统设置") == true)
        XCTAssertEqual(f.service.events, ["restore"])
        assertUnpublished(f.state)
    }

    func testFirstEntryStorageFailureNeverClaimsPhotoPermission() async {
        let f = fixture(restore: { _ in throw AppFailure.storage(failurePrivateDetail) })
        await enter(f.state)
        assertFailure(f.state, .init(phase: .photos, code: .indexUnavailable), operation: .restore)
        XCTAssertEqual(f.service.events, ["restore"])
        assertUnpublished(f.state)
    }

    func testFirstEntryTypedSourceFailurePreservesPhaseCodeAndNativeCode() async {
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: 10)
        let f = fixture(restore: { _ in throw diagnostic })
        await enter(f.state)
        assertFailure(f.state, diagnostic, operation: .restore)
        XCTAssertEqual(f.state.message?.components(separatedBy: "\n").first,
                       "SG-SOURCE-LOCK-CHECK (10) · sourceCheck")
        XCTAssertEqual(f.service.events, ["restore"])
    }

    func testTypedResourceAndCacheReadErrorsAreNotReclassifiedAtStateBoundary() async {
        for diagnostic in [SimilarCleanupDiagnostic(phase: .resources, code: .modelUnavailable),
                           .init(phase: .cacheRead, code: .cacheUnreadable),
                           .init(phase: .indexRead, code: .indexStep, nativeCode: 11)] {
            let f = fixture(restore: { _ in throw diagnostic })
            await enter(f.state)
            assertFailure(f.state, diagnostic, operation: .restore)
            XCTAssertEqual(f.service.events, ["restore"])
        }
    }

    func testFirstMissingCacheThenComputeFailureIdentifiesGroupNotRestore() async {
        let f = fixture(group: { _ in throw AppFailure.modelContract(failurePrivateDetail) })
        await enter(f.state)
        assertFailure(f.state, .init(phase: .compute, code: .invalidIndex), operation: .group)
        XCTAssertTrue(f.state.message?.contains("照片分组失败") == true)
        XCTAssertFalse(f.state.message?.contains("恢复分组失败") == true)
        XCTAssertEqual(f.service.events, ["restore", "group"])
        XCTAssertEqual(f.state.progress, SimilarPhotoGroupingProgress())
    }

    func testExplicitScanFailureNeverCallsRestore() async {
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceOpen, code: .sourceOpen, nativeCode: 14)
        let f = fixture(group: { _ in throw diagnostic })
        f.state.scan()
        await f.state.waitUntilIdle()
        assertFailure(f.state, diagnostic, operation: .group)
        XCTAssertEqual(f.service.events, ["group"])
    }

    func testCachedPublicationFailurePreservesSourceCauseButIdentifiesPublication() async {
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceFileControl, nativeCode: 12)
        let probe = FailureValidationProbe(accessError: diagnostic)
        let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(f.state)
        assertFailure(f.state, diagnostic, operation: .publication)
        XCTAssertTrue(f.state.message?.contains("分组结果核验失败") == true)
        XCTAssertFalse(f.state.message?.contains("恢复分组失败") == true)
        XCTAssertEqual(probe.accessThreads, [false])
        XCTAssertTrue(probe.epochThreads.isEmpty)
        XCTAssertEqual(f.service.events, ["restore"])
        assertUnpublished(f.state)
    }

    func testCachedCheapPublicationFenceClassifiesGenericErrorWithoutRepeatingFullValidation() async {
        let probe = FailureValidationProbe(epochError: AppFailure.storage(failurePrivateDetail))
        let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(f.state)
        assertFailure(f.state, .init(phase: .publication, code: .indexUnavailable), operation: .publication)
        XCTAssertEqual(probe.accessThreads, [false])
        XCTAssertEqual(probe.epochThreads, [true])
        XCTAssertEqual(f.service.events, ["restore"])
        assertUnpublished(f.state)
    }

    func testFreshPublicationFailureDoesNotMislabelItAsCompute() async {
        let probe = FailureValidationProbe(accessError: AppFailure.permission)
        let f = fixture(group: { failureResult($0, probe: probe) })
        await enter(f.state)
        assertFailure(f.state, .init(phase: .publication, code: .permissionDenied), operation: .publication)
        XCTAssertEqual(f.service.events, ["restore", "group"])
        assertUnpublished(f.state)
    }

    func testWrongResultThresholdIsInvalidIndexNotPermissionAndSkipsValidators() async {
        for restored in [false, true] {
            let probe = FailureValidationProbe()
            let f = fixture(restore: { _ in restored ? .restored(failureResult(0.99, probe: probe)) : .missing },
                            group: { _ in failureResult(0.99, probe: probe) })
            await enter(f.state)
            assertFailure(f.state, .init(phase: .publication, code: .invalidIndex), operation: .publication)
            XCTAssertTrue(probe.accessThreads.isEmpty)
            XCTAssertTrue(probe.epochThreads.isEmpty)
            XCTAssertEqual(f.service.events, restored ? ["restore"] : ["restore", "group"])
            assertUnpublished(f.state)
        }
    }

    func testUnknownNSErrorAtEveryReadBoundaryDiscardsAllPrivateFieldsAndNativeCode() async {
        let unknown = failurePrivateError()
        let restoring = fixture(restore: { _ in throw unknown })
        await enter(restoring.state)
        assertFailure(restoring.state, .init(phase: .photos, code: .unknown), operation: .restore)
        let computing = fixture(group: { _ in throw unknown })
        await enter(computing.state)
        assertFailure(computing.state, .init(phase: .compute, code: .unknown), operation: .group)
        let probe = FailureValidationProbe(accessError: unknown)
        let publishing = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(publishing.state)
        assertFailure(publishing.state, .init(phase: .publication, code: .unknown), operation: .publication)
        XCTAssertNil(restoring.state.failureDiagnostic?.nativeCode)
        XCTAssertNil(computing.state.failureDiagnostic?.nativeCode)
        XCTAssertNil(publishing.state.failureDiagnostic?.nativeCode)
    }

    func testSelfCancelledRestoreDoesNotPublishDiagnosticOrCompute() async {
        let f = fixture(restore: { _ in throw CancellationError() })
        await enter(f.state)
        assertNoFailure(f.state)
        XCTAssertEqual(f.service.events, ["restore"])
        assertUnpublished(f.state)
    }

    func testSelfCancelledComputeDoesNotPublishDiagnosticOrAutoRetry() async {
        let f = fixture(group: { _ in throw CancellationError() })
        await enter(f.state)
        await lifecycle(f.state)
        assertNoFailure(f.state)
        XCTAssertEqual(f.service.events, ["restore", "group"])
    }

    func testSelfCancelledPublicationDoesNotPublishDiagnostic() async {
        for fence in [false, true] {
            let probe = FailureValidationProbe(accessError: fence ? nil : CancellationError(),
                                               epochError: fence ? CancellationError() : nil)
            let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
            await enter(f.state)
            assertNoFailure(f.state)
            assertUnpublished(f.state)
            XCTAssertEqual(f.service.events, ["restore"])
        }
    }

    func testCancelledTaskWithUnrelatedErrorStillPublishesNoFailure() async {
        let f = fixture(restore: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw AppFailure.storage(failurePrivateDetail)
        })
        await enter(f.state)
        assertNoFailure(f.state)
        XCTAssertEqual(f.service.events, ["restore"])
    }

    func testLateRestoreFailureAfterLeavingCannotOverwriteDismissedMessage() async throws {
        let gate = hold()
        let f = fixture(restore: { _ in
            await gate.wait()
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceWriterReserved)
        })
        f.state.enterPage(ready: true)
        try await reached(gate.entered)
        f.state.leavePage()
        f.state.dismissMessage()
        gate.open()
        await f.state.waitUntilIdle()
        assertNoFailure(f.state)
        assertUnpublished(f.state)
        XCTAssertEqual(f.service.events, ["restore"])
    }

    func testReplacementDrainsOldFailureAndOnlyPublishesCurrentDiagnostic() async throws {
        let gate = hold()
        var calls = 0
        let f = fixture(group: { _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceWriterReserved)
            }
            throw AppFailure.storage(failurePrivateDetail)
        })
        var published: [SimilarCleanupDiagnostic.Code] = []
        let subscription = f.state.$failureDiagnostic.sink { value in
            if let value { published.append(value.code) }
        }
        defer { subscription.cancel() }
        f.state.scan()
        try await reached(gate.entered)
        f.state.scan()
        XCTAssertEqual(calls, 1, "The replacement must wait for the cancelled predecessor")
        assertNoFailure(f.state)
        gate.open()
        await f.state.waitUntilIdle()
        assertFailure(f.state, .init(phase: .compute, code: .indexUnavailable), operation: .group)
        XCTAssertEqual(published, [.indexUnavailable])
        XCTAssertEqual(f.service.events, ["group", "group"])
    }

    func testFailureIsNotRetriedByEntryReadinessForegroundOrTabRoundTrip() async {
        let f = fixture(restore: { _ in throw AppFailure.storage(failurePrivateDetail) })
        await enter(f.state)
        let original = f.state.message
        await lifecycle(f.state)
        XCTAssertEqual(f.state.message, original)
        XCTAssertEqual(f.service.events, ["restore"])
        assertFailure(f.state, .init(phase: .photos, code: .indexUnavailable), operation: .restore)
    }

    func testNewExplicitScanClearsAllFailureRecordsBeforeItsServiceCompletes() async throws {
        let gate = hold()
        let f = fixture(restore: { _ in throw AppFailure.permission }, group: {
            await gate.wait()
            return failureResult($0)
        })
        await enter(f.state)
        XCTAssertNotNil(f.state.failureDiagnostic)
        f.state.scan()
        assertNoFailure(f.state)
        try await reached(gate.entered)
        assertNoFailure(f.state)
        gate.open()
        await f.state.waitUntilIdle()
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.canSelect)
        assertNoFailure(f.state)
        XCTAssertEqual(f.service.events, ["restore", "group"])
    }

    func testDismissClearsMessageDiagnosticAndOperationWithoutRetry() async {
        let f = fixture(restore: { _ in throw AppFailure.permission })
        await enter(f.state)
        f.state.dismissMessage()
        assertNoFailure(f.state)
        await lifecycle(f.state)
        assertNoFailure(f.state)
        XCTAssertEqual(f.service.events, ["restore"])
    }

    func testStaleCacheIsNormalManualRegroupStateWithoutErrorOrFallback() async {
        let f = fixture(restore: { _ in .stale })
        await enter(f.state)
        XCTAssertTrue(f.state.needsRegroup)
        assertNoFailure(f.state)
        assertUnpublished(f.state)
        await lifecycle(f.state)
        XCTAssertEqual(f.service.events, ["restore"])
    }

    func testOptionalCacheWriteWarningKeepsCompletedResultWithoutFailureDiagnostic() async {
        let warning = "SG-CACHE-WRITE\n本次分组可正常使用，但未能保存；下次打开可能需要重新分组。"
        let f = fixture(group: { failureResult($0, persistenceIssue: warning) })
        await enter(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.state.persistenceIssue, warning)
        assertNoFailure(f.state)
        f.state.toggleSelection("TEST-a")
        XCTAssertEqual(f.state.selectedIDs, ["TEST-a"])
        f.state.leavePage()
        await enter(f.state)
        XCTAssertEqual(f.state.selectedIDs, ["TEST-a"])
        XCTAssertEqual(f.service.events, ["restore", "group"])
    }

    func testSelectionFailuresUseActualTypedErrorForToggleGroupPrepareAndConfirm() async throws {
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: 10)
        for action in 0..<4 {
            let probe = FailureValidationProbe()
            let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
            await enter(f.state)
            if action >= 2 { f.state.toggleSelection("TEST-a") }
            var intent: SimilarPhotoDeletionIntent?
            if action == 3 {
                f.state.prepareDeletion()
                intent = try XCTUnwrap(f.state.pendingDeletion)
            }
            probe.setPhotoError(diagnostic)
            switch action {
            case 0: f.state.toggleSelection("TEST-a")
            case 1: f.state.selectGroup("TEST-pair")
            case 2: f.state.prepareDeletion()
            default: f.state.confirmDeletion(try XCTUnwrap(intent))
            }
            assertFailure(f.state, diagnostic, operation: .selection)
            assertUnpublished(f.state)
            XCTAssertEqual(f.deletion.calls, 0, "Read failure must stop before any Photos mutation")
            XCTAssertEqual(f.service.events, ["restore"])
        }
    }

    func testUnknownSelectionNSErrorDoesNotTurnIntoPhotoPermission() async {
        let probe = FailureValidationProbe(photoError: failurePrivateError())
        let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(f.state)
        f.state.toggleSelection("TEST-a")
        assertFailure(f.state, .init(phase: .selection, code: .unknown), operation: .selection)
        assertUnpublished(f.state)
    }

    func testKnownSelectionPermissionAndAccessChangedHaveDifferentHints() async {
        for error in [PhotoDeletionError.permissionDenied, .accessChanged, .revisionChanged, .unavailableAssets] {
            let probe = FailureValidationProbe(photoError: error)
            let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
            await enter(f.state)
            f.state.selectGroup("TEST-pair")
            let code: SimilarCleanupDiagnostic.Code = error == .permissionDenied ? .permissionDenied : .photoAccessChanged
            assertFailure(f.state, .init(phase: .selection, code: code), operation: .selection)
            assertUnpublished(f.state)
        }
    }

    func testSynchronousSelectionCancellationInvalidatesWithoutPublishingFailure() async {
        let errors: [Error] = [CancellationError(), PhotoDeletionError.cancelled]
        for error in errors {
            let probe = FailureValidationProbe(photoError: error)
            let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
            await enter(f.state)
            f.state.toggleSelection("TEST-a")
            assertNoFailure(f.state)
            assertUnpublished(f.state)
            XCTAssertEqual(f.service.events, ["restore"])
        }
    }

    func testRangeBeginFenceFailureIsSelectionOperationWithOriginalSourcePhase() async {
        let probe = FailureValidationProbe()
        let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(f.state)
        let diagnostic = SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceFileIdentityChanged)
        probe.setEpochError(diagnostic)
        XCTAssertNil(f.state.beginRangeSelection(groupID: "TEST-pair"))
        assertFailure(f.state, diagnostic, operation: .selection)
        assertUnpublished(f.state)
    }

    func testRangeCommitFailurePublishesActualErrorOnceAfterOffMainValidation() async throws {
        let probe = FailureValidationProbe(photoError: AppFailure.storage(failurePrivateDetail))
        let f = fixture(restore: { .restored(failureResult($0, probe: probe)) })
        await enter(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "TEST-pair"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["TEST-a"])
        await f.state.waitUntilIdle()
        assertFailure(f.state, .init(phase: .selection, code: .indexUnavailable), operation: .selection)
        XCTAssertEqual(probe.photoThreads, [false])
        assertUnpublished(f.state)
    }

    func testLateRangeFailureAfterCancellationCannotPublishOrChangeCommittedSelection() async throws {
        let gate = FailureSelectionHold()
        selectionHolds.append(gate)
        addTeardownBlock { gate.open() }
        let f = fixture(restore: {
            .restored(failureResult($0, validatePhotos: { _ in try gate.waitAndFail() }))
        })
        await enter(f.state)
        let token = try XCTUnwrap(f.state.beginRangeSelection(groupID: "TEST-pair"))
        f.state.finishRangeSelection(token: token, selectedInGroup: ["TEST-a"])
        try await reached(gate.entered)
        f.state.cancelRangeSelection()
        gate.open()
        await f.state.waitUntilIdle()
        assertNoFailure(f.state)
        XCTAssertTrue(f.state.hasScanned)
        XCTAssertTrue(f.state.selectedIDs.isEmpty)
        XCTAssertTrue(f.state.canSelect)
        XCTAssertEqual(f.service.events, ["restore"])
    }

    // MARK: Only fake service boundaries; teardown proves zero deletion calls.

    private func fixture(
        restore: @escaping @MainActor (Float) async throws -> SimilarPhotoGroupingRestore = { _ in .missing },
        group: @escaping @MainActor (Float) async throws -> SimilarPhotoGroupingResult = { failureResult($0) }
    ) -> FailureStateFixture {
        let service = FailureGroupingStub(restore: restore, group: group)
        let deletion = FailureNoDeletion()
        let state = SimilarPhotoCleanupState(grouping: service, deletion: deletion, preferences: nil)
        let reads = readHolds
        let selections = selectionHolds
        addTeardownBlock { @MainActor in
            // XCTest teardown is LIFO: unblock before joining even when a
            // reached()/unwrap assertion throws before the explicit release.
            reads.forEach { $0.open() }
            selections.forEach { $0.open() }
            state.pause()
            await state.waitUntilIdle()
            XCTAssertEqual(deletion.calls, 0)
        }
        return FailureStateFixture(state: state, service: service, deletion: deletion)
    }

    private func enter(_ state: SimilarPhotoCleanupState) async {
        state.enterPage(ready: true)
        await state.waitUntilIdle()
    }

    private func lifecycle(_ state: SimilarPhotoCleanupState) async {
        state.enterPage(ready: true)
        state.availabilityChanged(ready: false)
        state.availabilityChanged(ready: true)
        state.leavePage()
        state.enterPage(ready: true)
        state.pause()
        state.resume()
        await state.waitUntilIdle()
    }

    private func assertNoFailure(_ state: SimilarPhotoCleanupState,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(state.failureDiagnostic, file: file, line: line)
        XCTAssertNil(state.failureOperation, file: file, line: line)
        XCTAssertNil(state.message, file: file, line: line)
    }

    private func assertFailure(_ state: SimilarPhotoCleanupState, _ diagnostic: SimilarCleanupDiagnostic,
                               operation: SimilarCleanupOperation,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(state.failureDiagnostic, diagnostic, file: file, line: line)
        XCTAssertEqual(state.failureOperation, operation, file: file, line: line)
        let marker = diagnostic.code.rawValue + (diagnostic.nativeCode.map { " (\($0))" } ?? "")
        let firstLine = "\(marker) · \(diagnostic.phase.rawValue)"
        XCTAssertEqual(state.message, diagnostic.message(operation: operation), file: file, line: line)
        XCTAssertEqual(state.message?.components(separatedBy: "\n").first, firstLine, file: file, line: line)
        let text = (state.message ?? "") + String(reflecting: state.failureDiagnostic)
        for secret in [failurePrivateDetail, "private-domain", "secret-path", "secret-query", "private-photo-id", "987654321"] {
            XCTAssertFalse(text.contains(secret), file: file, line: line)
        }
        XCTAssertEqual(state.message?.contains("权限"), diagnostic.code == .permissionDenied, file: file, line: line)
        XCTAssertEqual(state.message?.contains("系统设置"), diagnostic.code == .permissionDenied, file: file, line: line)
        XCTAssertTrue(state.message?.contains("本次未删除照片，已有索引未清除。") == true, file: file, line: line)
        XCTAssertFalse(state.isDeleting, file: file, line: line)
    }

    private func assertUnpublished(_ state: SimilarPhotoCleanupState,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertFalse(state.canSelect, file: file, line: line)
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertNil(state.selectionSessionID, file: file, line: line)
        XCTAssertFalse(state.isGrouping || state.isRestoring || state.isValidating, file: file, line: line)
        XCTAssertFalse(state.isSelecting || state.isValidatingSelection || state.isDeleting, file: file, line: line)
        XCTAssertEqual(state.candidateCount, 0, file: file, line: line)
        XCTAssertEqual(state.staleCount, 0, file: file, line: line)
        XCTAssertEqual(state.unindexedCount, 0, file: file, line: line)
    }

    private func hold() -> FailureReadHold {
        let gate = FailureReadHold()
        readHolds.append(gate)
        addTeardownBlock { @MainActor in gate.open() }
        return gate
    }

    private func reached(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Missing deterministic read/selection boundary")
            throw FailureStateTestError.event
        }
    }
}

private let failurePrivateDetail = "/secret-path?secret-query=private-photo-id"
private func failurePrivateError() -> NSError {
    NSError(domain: "private-domain", code: 987654321,
            userInfo: [NSLocalizedDescriptionKey: failurePrivateDetail, NSFilePathErrorKey: failurePrivateDetail,
                       NSUnderlyingErrorKey: NSError(domain: "private-domain", code: 123)])
}
private enum FailureStateTestError: Error { case event, forbiddenDeletion }

@MainActor
private struct FailureStateFixture {
    let state: SimilarPhotoCleanupState
    let service: FailureGroupingStub
    let deletion: FailureNoDeletion
}

@MainActor
private final class FailureGroupingStub: SimilarPhotoGrouping {
    private let restoring: @MainActor (Float) async throws -> SimilarPhotoGroupingRestore
    private let computing: @MainActor (Float) async throws -> SimilarPhotoGroupingResult
    private(set) var events: [String] = []
    init(restore: @escaping @MainActor (Float) async throws -> SimilarPhotoGroupingRestore,
         group: @escaping @MainActor (Float) async throws -> SimilarPhotoGroupingResult) {
        restoring = restore
        computing = group
    }
    func restore(threshold: Float) async throws -> SimilarPhotoGroupingRestore {
        events.append("restore")
        return try await restoring(threshold)
    }
    func group(threshold: Float, progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        events.append("group")
        await progress(SimilarPhotoGroupingProgress(total: 2, completed: 1, groupCount: 0))
        return try await computing(threshold)
    }
}

@MainActor
private final class FailureNoDeletion: PhotoDeleting {
    private(set) var calls = 0
    func delete(revisions: [PhotoRevision]) async throws {
        calls += 1
        XCTFail("Read/selection tests must never reach Photos deletion")
        throw FailureStateTestError.forbiddenDeletion
    }
}

private func failureResult(_ threshold: Float, probe: FailureValidationProbe? = nil,
                           persistenceIssue: String? = nil,
                           validatePhotos: (@Sendable ([String]) throws -> Void)? = nil) -> SimilarPhotoGroupingResult {
    var vector = [Float](repeating: 0, count: 768)
    vector[0] = 1
    let photos = ["TEST-a", "TEST-b"].map {
        IndexedPhoto(id: $0, modificationTime: 10, modelVersion: "TEST-only", imageEmbedding: vector, creationTime: 1)
    }
    return SimilarPhotoGroupingResult(groups: [SimilarPhotoGroup(id: "TEST-pair", photos: photos, minimumSimilarity: 1)],
        candidateCount: 2, staleCount: 0, unindexedCount: 0, threshold: threshold,
        validateAccess: { try probe?.validateAccess() },
        validatePhotos: { ids in
            if let validatePhotos { try validatePhotos(ids) }
            else { try probe?.validatePhotos() }
        },
        validatePublicationEpoch: { try probe?.validateEpoch() }, persistenceIssue: persistenceIssue)
}

/// Lock protects both generic-executor validation and MainActor fence/selection.
private final class FailureValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var accessError: Error?
    private var photoError: Error?
    private var epochError: Error?
    private var accessLog: [Bool] = []
    private var photoLog: [Bool] = []
    private var epochLog: [Bool] = []
    init(accessError: Error? = nil, photoError: Error? = nil, epochError: Error? = nil) {
        self.accessError = accessError; self.photoError = photoError; self.epochError = epochError
    }
    var accessThreads: [Bool] { locked { accessLog } }
    var photoThreads: [Bool] { locked { photoLog } }
    var epochThreads: [Bool] { locked { epochLog } }
    func setPhotoError(_ error: Error) { locked { photoError = error } }
    func setEpochError(_ error: Error) { locked { epochError = error } }
    func validateAccess() throws {
        try locked { accessLog.append(Thread.isMainThread); if let accessError { throw accessError } }
    }
    func validatePhotos() throws {
        try locked { photoLog.append(Thread.isMainThread); if let photoError { throw photoError } }
    }
    func validateEpoch() throws {
        try locked { epochLog.append(Thread.isMainThread); if let epochError { throw epochError } }
    }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

@MainActor
private final class FailureReadHold {
    let entered = XCTestExpectation(description: "Uncooperative backend entered")
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
            if opened { self.continuation = nil; continuation.resume() }
        }
    }
    func open() {
        opened = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private final class FailureSelectionHold: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Uncooperative selection validator entered")
    private let condition = NSCondition()
    private var opened = false
    func waitAndFail() throws {
        guard !Thread.isMainThread else {
            XCTFail("Selection metadata validation must stay off MainActor")
            throw FailureStateTestError.event
        }
        condition.lock()
        entered.fulfill()
        while !opened { condition.wait() }
        condition.unlock()
        throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceWriterReserved)
    }
    func open() {
        condition.lock(); opened = true; condition.broadcast(); condition.unlock()
    }
}