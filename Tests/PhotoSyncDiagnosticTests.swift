import Foundation
import XCTest
@testable import LocalImageIQ

final class PhotoSyncDiagnosticTests: XCTestCase {
    func testMessageHasOneSafeCodeAndStageWithoutBlindRetryAdvice() {
        let diagnostic = PhotoSyncDiagnostic(stage: .photos, code: .invalidPhotoMetadata,
                                             metadataField: .modificationTime)
        XCTAssertEqual(diagnostic.message,
            "同步未完成 · SS-PHOTOS-PHOTO-METADATA-MTIME / 检查照片\n已完成的索引保留。")
        XCTAssertEqual(diagnostic.errorDescription, diagnostic.message)
        XCTAssertEqual(diagnostic.message.components(separatedBy: "SS-").count, 2)
        XCTAssertFalse(diagnostic.message.contains("重试"))
        XCTAssertFalse(diagnostic.message.contains("权限"))
    }

    func testOnlyTrustedSQLiteReadDiagnosticsSupplyNativeCodes() {
        let open = SimilarCleanupDiagnostic(phase: .indexRead, code: .indexOpen, nativeCode: 14)
        let mapped = PhotoSyncDiagnostic.classify(open, stage: .indexRead)
        XCTAssertEqual(mapped.code, .sqlite)
        XCTAssertEqual(mapped.sqliteCode, .indexOpen)
        XCTAssertEqual(mapped.nativeCode, 14)
        XCTAssertEqual(mapped.identifier, "SS-INDEX-OPEN (14)")
        XCTAssertFalse(mapped.message.contains("SG-"))
        let schema = PhotoSyncDiagnostic.classify(SimilarCleanupDiagnostic(
            phase: .indexRead, code: .indexSchemaUnsupported, nativeCode: 999), stage: .indexRead)
        XCTAssertEqual(schema.identifier, "SS-INDEX-SCHEMA-UNSUPPORTED")
        XCTAssertNil(schema.nativeCode, "A schema number is not a SQLite error number.")
        let unrelated = PhotoSyncDiagnostic.classify(SimilarCleanupDiagnostic(
            phase: .sourceOpen, code: .sourceOpen, nativeCode: 1550), stage: .indexRead)
        XCTAssertEqual(unrelated.code, .unknown)
        XCTAssertNil(unrelated.sqliteCode)
        XCTAssertNil(unrelated.nativeCode, "Do not relabel source/VFS diagnostics as sync SQLite reads.")
    }

    func testUnknownErrorsStayUnknownAndOriginalCauseIsNotFormatted() {
        let unreadable = UnreadableSyncError()
        XCTAssertFalse(PhotoSyncDiagnostic.isCancellation(unreadable))
        XCTAssertEqual(PhotoSyncDiagnostic.classify(unreadable, stage: .photos).code, .unknown)
        XCTAssertFalse(String(reflecting: PhotoSyncFailure(error: unreadable, stage: .photos)).isEmpty)
        let secret = "private-photo-id /private/path query OCR sqlite permission"
        let original = NSError(domain: secret, code: 14,
                               userInfo: [NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: secret])
        for stage in PhotoSyncDiagnostic.Stage.allCases {
            let failure = PhotoSyncFailure(error: original, stage: stage)
            XCTAssertTrue((failure.underlyingError as NSError) === original)
            XCTAssertEqual(failure.diagnostic.stage, stage)
            XCTAssertEqual(failure.diagnostic.code, .unknown)
            XCTAssertNil(failure.diagnostic.nativeCode)
            XCTAssertNil(failure.diagnostic.sqliteCode)
            for text in [failure.localizedDescription, String(describing: failure), String(reflecting: failure),
                         String(reflecting: failure.diagnostic)] {
                XCTAssertFalse(text.contains(secret))
                XCTAssertFalse(text.contains("(14)"))
            }
            XCTAssertEqual(PhotoSyncDiagnostic.classify(AppFailure.photo(secret), stage: stage).code, .unknown)
            XCTAssertEqual(PhotoSyncDiagnostic.classify(AppFailure.storage(secret), stage: stage).code, .storage)
        }
        let inner = PhotoSyncFailure(error: original, stage: .photos,
                                    code: .invalidPhotoMetadata, metadataField: .id)
        let outer = PhotoSyncFailure(error: inner, stage: .prune)
        XCTAssertTrue((outer.underlyingError as NSError) === original)
        XCTAssertEqual(outer.diagnostic.stage, .prune)
        XCTAssertEqual(outer.diagnostic.metadataField, .id)
        XCTAssertEqual(PhotoSyncDiagnostic.classify(outer, stage: .setup), outer.diagnostic)
    }

    @MainActor
    func testFailureRetainsCountsSettlesOnceAndOldCallbacksCannotOverwriteNewDiagnostic() async {
        let partial = PhotoSyncProgress(phase: .updating, total: 5, completed: 2, encoded: 2, removed: 3)
        let first = DiagnosticRun(progress: partial, error: PhotoSyncFailure(
            error: AppFailure.modelContract("private"), stage: .encoding))
        let second = DiagnosticRun(error: PhotoSyncFailure(error: SimilarCleanupDiagnostic(
            phase: .indexRead, code: .indexSchemaUnsupported), stage: .indexRead))
        let service = DiagnosticService([first, second])
        let state = PhotoSyncState(service: service)
        var settled = 0
        var commits = 0
        var summaries = 0
        state.onSettled = { settled += 1 }
        state.onCommitted = { commits += 1 }
        state.onCompleted = { _ in summaries += 1 }
        state.updateAvailability(ready: true, networkAllowed: false)
        await first.entered.wait()
        await first.release.open()
        await state.waitUntilIdle()
        let initial = state.failureDiagnostic
        XCTAssertEqual(initial?.stage, .encoding)
        XCTAssertEqual(initial?.code, .model)
        XCTAssertEqual(state.progress, partial)
        XCTAssertEqual(settled, 1)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(summaries, 0)
        XCTAssertEqual(PhotoSyncToast(state: state).detail, initial?.message)
        state.libraryChanged()
        state.updateAvailability(ready: false, networkAllowed: false)
        state.updateAvailability(ready: true, networkAllowed: true)
        await state.waitUntilIdle()
        let calls = await service.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(state.failureDiagnostic, initial)
        state.restart()
        XCTAssertNil(state.failureDiagnostic)
        XCTAssertNil(state.failureMessage)
        await second.entered.wait()
        await service.lateCallback(0)
        XCTAssertEqual(state.phase, .checking)
        XCTAssertNil(state.failureDiagnostic)
        await second.release.open()
        await state.waitUntilIdle()
        let current = state.failureDiagnostic
        XCTAssertEqual(current?.sqliteCode, .indexSchemaUnsupported)
        let progress = state.progress
        await service.lateCallback(0)
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.failureDiagnostic, current)
        XCTAssertEqual(state.progress, progress)
        XCTAssertEqual(state.failureMessage, current?.message)
        XCTAssertEqual(settled, 2)
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(summaries, 0)
    }

    @MainActor
    func testCancellationIncludingLateFailureNeverPublishesDiagnostic() async {
        for userCancel in [false, true] {
            let error: Error
            if userCancel {
                error = PhotoSyncFailure(error: AppFailure.storage("private"), stage: .save)
            } else {
                error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError,
                                userInfo: [NSLocalizedDescriptionKey: "private"])
            }
            let partial = PhotoSyncProgress(phase: .updating, total: 4, completed: 1, encoded: 1)
            let run = DiagnosticRun(progress: partial, error: error)
            let service = DiagnosticService([run])
            let state = PhotoSyncState(service: service)
            var settled = 0
            state.onSettled = { settled += 1 }
            state.updateAvailability(ready: true, networkAllowed: false)
            await run.entered.wait()
            if userCancel {
                state.cancel()
                XCTAssertEqual(state.phase, .cancelling)
                XCTAssertEqual(settled, 0, "Wait for the late backend before settling.")
            }
            await run.release.open()
            await state.waitUntilIdle()
            XCTAssertEqual(state.phase, userCancel ? .cancelled : .idle)
            XCTAssertEqual(state.progress, partial)
            XCTAssertNil(state.failureDiagnostic)
            XCTAssertNil(state.failureMessage)
            XCTAssertEqual(settled, 1)
            await service.lateCallback(0)
            XCTAssertNil(state.failureDiagnostic)
            XCTAssertEqual(state.progress, partial)
            XCTAssertEqual(settled, 1)
        }
    }
}

private struct UnreadableSyncError: LocalizedError {
    var errorDescription: String? {
        XCTFail("Classification/cancellation must not evaluate an unknown Swift error's description.")
        return "private"
    }
}

private actor DiagnosticGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct DiagnosticRun: Sendable {
    let entered = DiagnosticGate()
    let release = DiagnosticGate()
    var progress = PhotoSyncProgress()
    let error: Error
}

private actor DiagnosticService: PhotoSyncServicing {
    let runs: [DiagnosticRun]
    private(set) var calls = 0
    private var callbacks: [(@Sendable (PhotoSyncProgress) async -> Void, @Sendable () async -> Void)] = []
    init(_ runs: [DiagnosticRun]) { self.runs = runs }
    func synchronize(networkAllowed: Bool, progress: @escaping @Sendable (PhotoSyncProgress) async -> Void,
                     committed: @escaping @Sendable () async -> Void) async throws -> PhotoSyncResult {
        guard calls < runs.count else { XCTFail("Unexpected automatic retry"); throw CancellationError() }
        let run = runs[calls]
        calls += 1
        callbacks.append((progress, committed))
        await progress(run.progress)
        if run.progress.encoded > 0 { await committed() }
        await run.entered.open()
        await run.release.wait() // Intentionally ignores cancellation; verifies draining.
        throw run.error
    }
    func lateCallback(_ index: Int) async {
        await callbacks[index].0(PhotoSyncProgress(phase: .updating, total: 99, completed: 99, encoded: 99))
        await callbacks[index].1()
    }
}