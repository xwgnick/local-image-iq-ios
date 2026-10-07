import Foundation
import ImageIQCore

enum SimilarCleanupOperation: String, Sendable {
    case restore, group, publication, selection
}

enum SimilarCleanupPhase: String, Sendable {
    case photos, resources, indexLocation, sourceOpen, sourceCheck, indexRead
    case cacheRead, cacheWrite, compute, publication, selection
}

/// Ephemeral, allowlisted diagnostics only. Never retains an underlying error,
/// userInfo, path, asset ID, model version, SQLite message or journal-mode text.
struct SimilarCleanupDiagnostic: Error, LocalizedError, Sendable, Equatable {
    enum Code: String, Sendable, CaseIterable {
        case permissionDenied = "SG-PHOTOS-PERMISSION"
        case photoAccessChanged = "SG-PHOTOS-ACCESS"
        case modelUnavailable = "SG-MODEL-UNAVAILABLE"
        case indexUnavailable = "SG-INDEX-UNAVAILABLE"
        case invalidIndex = "SG-INDEX-DATA"
        case cacheUnreadable = "SG-CACHE-READ"
        case cacheUnwritable = "SG-CACHE-WRITE"
        case cancelled = "SG-CANCELLED"
        case unknown = "SG-UNKNOWN"

        case sourceParentStat = "SG-SOURCE-PARENT-STAT"
        case sourceParentSymlink = "SG-SOURCE-PARENT-SYMLINK"
        case sourceParentKind = "SG-SOURCE-PARENT-KIND"
        case sourceFileStat = "SG-SOURCE-FILE-STAT"
        case sourceFileSymlink = "SG-SOURCE-FILE-SYMLINK"
        case sourceFileKind = "SG-SOURCE-FILE-KIND"
        case sourceFileLinks = "SG-SOURCE-FILE-LINKS"
        case sourceJournalStat = "SG-SOURCE-JOURNAL-STAT"
        case sourceWALStat = "SG-SOURCE-WAL-STAT"
        case sourceSHMStat = "SG-SOURCE-SHM-STAT"
        case sourceJournalPresent = "SG-SOURCE-JOURNAL-PRESENT"
        case sourceWALPresent = "SG-SOURCE-WAL-PRESENT"
        case sourceSHMPresent = "SG-SOURCE-SHM-PRESENT"
        case sourceOpen = "SG-SOURCE-OPEN"
        case sourceReadOnly = "SG-SOURCE-READONLY"
        case sourceConnectionMissing = "SG-SOURCE-CONNECTION"
        case sourceQueryPrepare = "SG-SOURCE-QUERY-PREPARE"
        case sourceQueryMissing = "SG-SOURCE-QUERY-MISSING"
        case sourceQueryStep = "SG-SOURCE-QUERY-STEP"
        case sourceJournalModeMissing = "SG-SOURCE-MODE-MISSING"
        case sourceJournalModeWAL = "SG-SOURCE-MODE-WAL"
        case sourceJournalModeMemory = "SG-SOURCE-MODE-MEMORY"
        case sourceJournalModeTruncate = "SG-SOURCE-MODE-TRUNCATE"
        case sourceJournalModePersist = "SG-SOURCE-MODE-PERSIST"
        case sourceJournalModeOff = "SG-SOURCE-MODE-OFF"
        case sourceJournalModeUnknown = "SG-SOURCE-MODE-UNKNOWN"
        case sourceFileControl = "SG-SOURCE-FILE-CONTROL"
        case sourceFilePointerMissing = "SG-SOURCE-FILE-POINTER"
        case sourceLockMethodMissing = "SG-SOURCE-LOCK-METHOD"
        case sourceLockCheckFailed = "SG-SOURCE-LOCK-CHECK"
        case sourceWriterReserved = "SG-SOURCE-WRITER"
        case sourceDataVersionChanged = "SG-SOURCE-DATA-VERSION"
        case sourceFileIdentityChanged = "SG-SOURCE-FILE-IDENTITY"

        case indexOpen = "SG-INDEX-OPEN"
        case indexPrepare = "SG-INDEX-PREPARE"
        case indexStep = "SG-INDEX-STEP"
        case indexBind = "SG-INDEX-BIND"
        case indexSchemaMissing = "SG-INDEX-SCHEMA-MISSING"
        case indexSchemaUnsupported = "SG-INDEX-SCHEMA-UNSUPPORTED"
        case indexMetadataMissing = "SG-INDEX-METADATA-MISSING"
        case indexMetadataInvalid = "SG-INDEX-METADATA-UTF8"
        case indexBlobMissing = "SG-INDEX-BLOB-MISSING"
        case indexDuplicateIdentity = "SG-INDEX-DUPLICATE"
        case indexSnapshotChanged = "SG-INDEX-SNAPSHOT"

        /// These codes alone carry errno/SQLite return codes captured at the
        /// failing call site. Schema/data versions and arbitrary NSError codes
        /// are deliberately NOT accepted as native diagnostics.
        fileprivate var allowsNativeCode: Bool {
            switch self {
            case .sourceParentStat, .sourceFileStat, .sourceJournalStat, .sourceWALStat, .sourceSHMStat,
                 .sourceOpen, .sourceReadOnly, .sourceQueryPrepare, .sourceQueryStep,
                 .sourceFileControl, .sourceLockCheckFailed,
                 .indexOpen, .indexPrepare, .indexStep, .indexBind:
                return true
            default: return false
            }
        }
    }

    let phase: SimilarCleanupPhase
    let code: Code
    let nativeCode: Int32?

    init(phase: SimilarCleanupPhase, code: Code, nativeCode: Int32? = nil) {
        self.phase = phase
        self.code = code
        self.nativeCode = code.allowsNativeCode ? nativeCode : nil
    }

    /// Callers MUST rethrow CancellationError / Task.isCancelled before calling
    /// this nonthrowing factory. The cancelled sentinel is privacy-safe if a
    /// caller violates that contract; it is not a replacement for cancellation.
    static func classify(_ error: Error, phase: SimilarCleanupPhase) -> Self {
        if let diagnostic = error as? Self { return diagnostic }
        if error is CancellationError { return Self(phase: phase, code: .cancelled) }
        if let failure = error as? AppFailure {
            switch failure {
            case .permission: return Self(phase: phase, code: .permissionDenied)
            case .photo: return Self(phase: phase, code: .photoAccessChanged)
            case .storage:
                return Self(phase: phase, code: phase == .cacheRead ? .cacheUnreadable
                    : phase == .cacheWrite ? .cacheUnwritable : .indexUnavailable)
            case .modelsMissing, .modelContract:
                return Self(phase: phase, code: phase == .indexRead || phase == .compute
                    ? .invalidIndex : .modelUnavailable)
            case .cloudOnly, .places: break
            }
        }
        if error is SimilarGroupingCacheError {
            return Self(phase: phase, code: phase == .cacheWrite ? .cacheUnwritable
                : phase == .cacheRead ? .cacheUnreadable : .indexUnavailable)
        }
        if error is DecodingError || error is EmbeddingError {
            return Self(phase: phase, code: phase == .indexRead || phase == .compute ? .invalidIndex : .unknown)
        }
        // Do not inspect an unknown error's description/domain/userInfo/code,
        // even when the phase happens to be Photos or a filesystem operation.
        return Self(phase: phase, code: .unknown)
    }

    /// Compatibility with former storage catches, not an assertion that the
    /// phone's filesystem (rather than a guard/adapter) caused this failure.
    var isSourceFailure: Bool {
        switch code {
        case .permissionDenied, .photoAccessChanged, .modelUnavailable, .cancelled, .unknown: return false
        default: return true
        }
    }

    func message(operation: SimilarCleanupOperation) -> String {
        let title: String
        switch operation {
        case .restore: title = "恢复分组失败"
        case .group: title = "照片分组失败"
        case .publication: title = "分组结果核验失败"
        case .selection: title = "照片选择核验失败"
        }
        let marker = code.rawValue + (nativeCode.map { " (\($0))" } ?? "")
        return "\(marker) · \(phase.rawValue)\n\(title)\n\(reason)\n本次未删除照片，已有索引未清除。"
    }

    var errorDescription: String? { message(operation: .restore) }

    private var reason: String {
        switch code {
        case .permissionDenied:
            return "无法访问照片。请在系统设置中检查本 App 的照片权限。"
        case .photoAccessChanged:
            return "照片的可访问范围或内容已变化，当前分组无法继续核验。"
        case .modelUnavailable:
            return "无法验证分组所需的模型资源。"
        case .cacheUnreadable:
            return "无法读取已保存的分组。"
        case .cacheUnwritable:
            return "无法保存本次分组。"
        case .sourceFileControl, .sourceFilePointerMissing, .sourceLockMethodMissing, .sourceLockCheckFailed:
            return "无法检查图片索引的写入状态。"
        case .sourceWriterReserved:
            return "图片索引正被写入占用，本次分组已停止。"
        case .sourceDataVersionChanged, .sourceFileIdentityChanged, .indexSnapshotChanged:
            return "图片索引在核验期间发生变化，本次分组已停止。"
        case .sourceJournalPresent, .sourceWALPresent, .sourceSHMPresent:
            return "检测到索引辅助文件，当前无法确认读取安全。"
        case .sourceJournalModeWAL, .sourceJournalModeMemory, .sourceJournalModeTruncate,
             .sourceJournalModePersist, .sourceJournalModeOff, .sourceJournalModeUnknown:
            return "当前索引日志模式不在分组校验支持范围内。"
        case .sourceParentSymlink, .sourceParentKind, .sourceFileSymlink, .sourceFileKind, .sourceFileLinks:
            return "索引文件或目录的类型不符合安全读取要求。"
        case .indexSchemaMissing, .indexSchemaUnsupported:
            return "当前图片索引结构无法通过分组校验。"
        case .invalidIndex, .indexMetadataMissing, .indexMetadataInvalid, .indexBlobMissing, .indexDuplicateIdentity:
            return "图片索引数据未通过分组校验。"
        case .cancelled:
            return "本次操作已取消。"
        case .unknown:
            return "本次操作未完成，原因尚未确定。"
        case .indexUnavailable, .sourceParentStat, .sourceFileStat, .sourceJournalStat, .sourceWALStat,
             .sourceSHMStat, .sourceOpen, .sourceReadOnly, .sourceConnectionMissing,
             .sourceQueryPrepare, .sourceQueryMissing, .sourceQueryStep, .sourceJournalModeMissing,
             .indexOpen, .indexPrepare, .indexStep, .indexBind:
            return "无法读取或核验图片索引。"
        }
    }
}