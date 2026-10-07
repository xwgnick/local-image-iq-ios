import Foundation
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

final class SimilarCleanupDiagnosticTests: XCTestCase {
    private typealias Diagnostic = SimilarCleanupDiagnostic
    private let phases: [SimilarCleanupPhase] = [.photos, .resources, .indexLocation, .sourceOpen,
        .sourceCheck, .indexRead, .cacheRead, .cacheWrite, .compute, .publication, .selection]
    private let operations: [SimilarCleanupOperation] = [.restore, .group, .publication, .selection]
    private let privateDetail = "synthetic-private-id /private/path OCR=secret model-version=private"

    func testStableCodeVocabularyIsUniqueAndAllowlisted() {
        let expected = """
        SG-PHOTOS-PERMISSION SG-PHOTOS-ACCESS SG-MODEL-UNAVAILABLE SG-INDEX-UNAVAILABLE SG-INDEX-DATA
        SG-CACHE-READ SG-CACHE-WRITE SG-CANCELLED SG-UNKNOWN
        SG-SOURCE-PARENT-STAT SG-SOURCE-PARENT-SYMLINK SG-SOURCE-PARENT-KIND
        SG-SOURCE-FILE-STAT SG-SOURCE-FILE-SYMLINK SG-SOURCE-FILE-KIND SG-SOURCE-FILE-LINKS
        SG-SOURCE-JOURNAL-STAT SG-SOURCE-WAL-STAT SG-SOURCE-SHM-STAT
        SG-SOURCE-JOURNAL-PRESENT SG-SOURCE-WAL-PRESENT SG-SOURCE-SHM-PRESENT
        SG-SOURCE-OPEN SG-SOURCE-READONLY SG-SOURCE-CONNECTION SG-SOURCE-QUERY-PREPARE
        SG-SOURCE-QUERY-MISSING SG-SOURCE-QUERY-STEP SG-SOURCE-MODE-MISSING SG-SOURCE-MODE-WAL
        SG-SOURCE-MODE-MEMORY SG-SOURCE-MODE-TRUNCATE SG-SOURCE-MODE-PERSIST SG-SOURCE-MODE-OFF
        SG-SOURCE-MODE-UNKNOWN SG-SOURCE-FILE-CONTROL SG-SOURCE-FILE-POINTER SG-SOURCE-LOCK-METHOD
        SG-SOURCE-LOCK-CHECK SG-SOURCE-WRITER SG-SOURCE-DATA-VERSION SG-SOURCE-FILE-IDENTITY
        SG-INDEX-OPEN SG-INDEX-PREPARE SG-INDEX-STEP SG-INDEX-BIND SG-INDEX-SCHEMA-MISSING
        SG-INDEX-SCHEMA-UNSUPPORTED SG-INDEX-METADATA-MISSING SG-INDEX-METADATA-UTF8
        SG-INDEX-BLOB-MISSING SG-INDEX-DUPLICATE SG-INDEX-SNAPSHOT
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let actual = Diagnostic.Code.allCases.map(\.rawValue)
        XCTAssertEqual(actual.count, Set(actual).count)
        XCTAssertEqual(Set(actual), Set(expected))
    }

    func testOperationAndPhaseRawValuesAreStable() {
        XCTAssertEqual(operations.map(\.rawValue), ["restore", "group", "publication", "selection"])
        XCTAssertEqual(phases.map(\.rawValue), ["photos", "resources", "indexLocation", "sourceOpen",
            "sourceCheck", "indexRead", "cacheRead", "cacheWrite", "compute", "publication", "selection"])
    }

    func testMessagesHaveVisibleOperationReasonCodeAndNonDeletionFooter() {
        let titles = ["恢复分组失败", "照片分组失败", "分组结果核验失败", "照片选择核验失败"]
        let diagnostic = Diagnostic(phase: .sourceCheck, code: .sourceLockMethodMissing)
        for (operation, title) in zip(operations, titles) {
            let lines = diagnostic.message(operation: operation).components(separatedBy: "\n")
            XCTAssertEqual(lines, ["SG-SOURCE-LOCK-METHOD · sourceCheck", title, "无法检查图片索引的写入状态。",
                "本次未删除照片，已有索引未清除。"])
        }
    }

    func testOnlyTruePermissionFailureSuggestsSystemPhotoPermission() {
        for phase in phases {
            let diagnostic = Diagnostic.classify(AppFailure.permission, phase: phase)
            XCTAssertEqual(diagnostic.code, .permissionDenied)
            XCTAssertTrue(diagnostic.message(operation: .restore).contains("系统设置"))
        }
        for code in Diagnostic.Code.allCases where code != .permissionDenied {
            let message = Diagnostic(phase: .photos, code: code).message(operation: .restore)
            XCTAssertFalse(message.contains("权限"))
            XCTAssertFalse(message.contains("重装"))
            XCTAssertFalse(message.contains("清除索引"))
        }
    }

    func testPhotoFailureDoesNotClaimPermissionWasDenied() {
        for phase in phases {
            let diagnostic = Diagnostic.classify(AppFailure.photo(privateDetail), phase: phase)
            XCTAssertEqual(diagnostic.code, .photoAccessChanged)
            XCTAssertFalse(diagnostic.message(operation: .selection).contains(privateDetail))
            XCTAssertFalse(diagnostic.message(operation: .selection).contains("权限"))
        }
    }

    func testStorageClassificationUsesReadOrWriteContextWithoutRawDetail() {
        for phase in phases {
            let diagnostic = Diagnostic.classify(AppFailure.storage(privateDetail), phase: phase)
            XCTAssertEqual(diagnostic.code, phase == .cacheRead ? .cacheUnreadable
                : phase == .cacheWrite ? .cacheUnwritable : .indexUnavailable)
            XCTAssertNil(diagnostic.nativeCode)
            XCTAssertFalse(diagnostic.message(operation: .restore).contains(privateDetail))
        }
    }

    func testModelContractAndMissingModelAreClassifiedAtActualPhase() {
        for error in [AppFailure.modelsMissing(privateDetail), .modelContract(privateDetail)] {
            for phase in phases {
                let diagnostic = Diagnostic.classify(error, phase: phase)
                XCTAssertEqual(diagnostic.code, phase == .indexRead || phase == .compute ? .invalidIndex : .modelUnavailable)
                XCTAssertFalse(diagnostic.message(operation: .group).contains(privateDetail))
            }
        }
    }

    func testUnknownNSErrorNeverCopiesDomainDescriptionUserInfoOrNumericCode() {
        let error = NSError(domain: privateDetail, code: 987654321,
                            userInfo: [NSLocalizedDescriptionKey: privateDetail, NSFilePathErrorKey: privateDetail])
        for phase in phases {
            let diagnostic = Diagnostic.classify(error, phase: phase)
            XCTAssertEqual(diagnostic, Diagnostic(phase: phase, code: .unknown))
            for operation in operations {
                let message = diagnostic.message(operation: operation)
                XCTAssertFalse(message.contains(privateDetail))
                XCTAssertFalse(message.contains("987654321"))
                XCTAssertFalse(message.contains("权限"))
            }
        }
    }

    func testDecodingErrorDoesNotCopyCodingPathOrUnderlyingError() {
        let key = DiagnosticCodingKey(stringValue: privateDetail)
        let error = DecodingError.dataCorrupted(.init(codingPath: [key], debugDescription: privateDetail,
            underlyingError: NSError(domain: privateDetail, code: 123456789)))
        for phase in phases {
            let diagnostic = Diagnostic.classify(error, phase: phase)
            XCTAssertEqual(diagnostic.code, phase == .indexRead || phase == .compute ? .invalidIndex : .unknown)
            XCTAssertNil(diagnostic.nativeCode)
            XCTAssertFalse(diagnostic.message(operation: .restore).contains(privateDetail))
        }
    }

    func testEmbeddingErrorsNeverExposeDimensionOrComponentIndices() {
        for error in [EmbeddingError.dimensionMismatch(expected: 768, actual: 987654), .nonFiniteValue(index: 123456)] {
            let diagnostic = Diagnostic.classify(error, phase: .indexRead)
            XCTAssertEqual(diagnostic.code, .invalidIndex)
            XCTAssertNil(diagnostic.nativeCode)
            XCTAssertFalse(diagnostic.message(operation: .group).contains("987654"))
            XCTAssertFalse(diagnostic.message(operation: .group).contains("123456"))
        }
    }

    func testCacheErrorClassificationDoesNotSuggestClearingIndex() {
        for error in [SimilarGroupingCacheError.invalid, .unavailable] {
            XCTAssertEqual(Diagnostic.classify(error, phase: .cacheRead).code, .cacheUnreadable)
            XCTAssertEqual(Diagnostic.classify(error, phase: .cacheWrite).code, .cacheUnwritable)
            XCTAssertEqual(Diagnostic.classify(error, phase: .indexRead).code, .indexUnavailable)
        }
    }

    func testTypedFirstDiagnosticSurvivesEveryOuterPhaseUnchanged() {
        let first = Diagnostic(phase: .sourceCheck, code: .sourceLockCheckFailed, nativeCode: SQLITE_IOERR)
        for phase in phases { XCTAssertEqual(Diagnostic.classify(first, phase: phase), first) }
    }

    func testNativeCodeIsAllowedOnlyForExplicitSystemCallFailures() {
        let allowed: Set<Diagnostic.Code> = [.sourceParentStat, .sourceFileStat, .sourceJournalStat,
            .sourceWALStat, .sourceSHMStat, .sourceOpen, .sourceReadOnly, .sourceQueryPrepare,
            .sourceQueryStep, .sourceFileControl, .sourceLockCheckFailed,
            .indexOpen, .indexPrepare, .indexStep, .indexBind]
        for code in Diagnostic.Code.allCases {
            let diagnostic = Diagnostic(phase: .sourceCheck, code: code, nativeCode: SQLITE_IOERR)
            XCTAssertEqual(diagnostic.nativeCode, allowed.contains(code) ? SQLITE_IOERR : nil)
        }
    }

    func testLockFailureAndReservedWriterHaveDifferentCodesAndReasons() {
        let failed = SourceLockInspectionFault.failed(SQLITE_IOERR).diagnostic
        let writer = SourceLockInspectionFault.writer.diagnostic
        XCTAssertEqual(failed.code.rawValue, "SG-SOURCE-LOCK-CHECK")
        XCTAssertEqual(failed.nativeCode, SQLITE_IOERR)
        XCTAssertTrue(failed.message(operation: .restore).contains("SG-SOURCE-LOCK-CHECK (10)"))
        XCTAssertEqual(writer.code.rawValue, "SG-SOURCE-WRITER")
        XCTAssertNil(writer.nativeCode)
        XCTAssertFalse(failed.message(operation: .restore).contains("正被写入占用"))
        XCTAssertTrue(writer.message(operation: .restore).contains("正被写入占用"))
    }

    func testLocalizedErrorUsesOnlyFixedMessage() {
        let diagnostic = Diagnostic.classify(AppFailure.storage(privateDetail), phase: .sourceOpen)
        XCTAssertEqual(diagnostic.errorDescription, diagnostic.message(operation: .restore))
        XCTAssertEqual(diagnostic.localizedDescription, diagnostic.message(operation: .restore))
        XCTAssertFalse(String(reflecting: diagnostic).contains(privateDetail))
    }

    func testAccidentalCancellationClassificationHasOnlyNeutralSentinel() {
        let diagnostic = Diagnostic.classify(CancellationError(), phase: .photos)
        XCTAssertEqual(diagnostic.code, .cancelled)
        XCTAssertNil(diagnostic.nativeCode)
        XCTAssertFalse(diagnostic.isSourceFailure)
        XCTAssertFalse(diagnostic.message(operation: .restore).contains("权限"))
    }

    func testCallerRethrowsCancellationBeforeFactory() {
        XCTAssertThrowsError(try callerBoundary { throw CancellationError() }) { error in
            XCTAssertTrue(error is CancellationError)
            XCTAssertFalse(error is Diagnostic)
        }
    }

    func testCancelledTaskAlsoRethrowsCancellationInsteadOfUnrelatedError() async {
        let task = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            try self.callerBoundary { throw AppFailure.storage(self.privateDetail) }
        }
        do { try await task.value; XCTFail("Expected cancellation.") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUnknownLocalizedErrorsAndUnrelatedAppFailuresStayUnknown() {
        let errors: [Error] = [DiagnosticPrivateError(), AppFailure.cloudOnly, AppFailure.places(privateDetail)]
        for error in errors {
            for phase in phases {
                XCTAssertEqual(Diagnostic.classify(error, phase: phase), Diagnostic(phase: phase, code: .unknown))
            }
        }
    }

    func testSourceFailureCompatibilityIncludesStorageAndExcludesUnprovenUnknowns() {
        let notStorage: Set<Diagnostic.Code> = [.permissionDenied, .photoAccessChanged, .modelUnavailable, .cancelled, .unknown]
        for code in Diagnostic.Code.allCases {
            XCTAssertEqual(Diagnostic(phase: .sourceCheck, code: code).isSourceFailure, !notStorage.contains(code))
        }
    }

    /// Integration callers must use this ordering; the factory cannot throw.
    private func callerBoundary(_ operation: () throws -> Void) throws {
        do { try operation() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Diagnostic.classify(error, phase: .indexRead)
        }
    }
}

private struct DiagnosticCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct DiagnosticPrivateError: LocalizedError {
    var errorDescription: String? { "synthetic-private-id /private/path OCR=secret model-version=private" }
}