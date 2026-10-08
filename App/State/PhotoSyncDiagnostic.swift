import Foundation

/// Safe, ephemeral presentation data. No asset IDs, paths, error descriptions,
/// NSError domains/userInfo, model identities or persisted diagnostic strings.
struct PhotoSyncDiagnostic: Error, LocalizedError, Sendable, Equatable {
    enum Stage: String, Sendable, CaseIterable {
        case setup = "SETUP", photos = "PHOTOS", resources = "RESOURCES"
        case indexRead = "INDEX-READ", difference = "DIFF", prune = "PRUNE"
        case models = "MODELS", encoding = "ENCODING", save = "SAVE", summary = "SUMMARY"

        var title: String {
            switch self {
            case .setup: return "同步准备"
            case .photos: return "检查照片"
            case .resources: return "检查模型资源"
            case .indexRead: return "读取索引"
            case .difference: return "比对照片变化"
            case .prune: return "移除失效索引"
            case .models: return "准备模型"
            case .encoding: return "处理照片"
            case .save: return "保存索引"
            case .summary: return "核验同步结果"
            }
        }
    }

    enum Code: String, Sendable {
        case permission = "PERMISSION", accessChanged = "ACCESS-CHANGED"
        case generationChanged = "GENERATION-CHANGED"
        case libraryChanged = "LIBRARY-CHANGED", photoChanged = "PHOTO-CHANGED"
        case invalidPhotoMetadata = "PHOTO-METADATA", invalidIndexMetadata = "INDEX-METADATA"
        case resources = "RESOURCES", model = "MODEL", storage = "STORAGE"
        case sqlite = "SQLITE", unknown = "UNKNOWN"
    }

    enum MetadataField: String, Sendable {
        case id = "ID", modificationTime = "MTIME", creationTime = "CTIME"
        case modelVersion = "MODEL", duplicateID = "DUPLICATE-ID"
    }

    let stage: Stage
    let code: Code
    let metadataField: MetadataField?
    /// Only the existing, allowlisted SQLite read codes are accepted below.
    /// These are translated to SS markers, never shown as cleanup failures.
    private(set) var sqliteCode: SimilarCleanupDiagnostic.Code?
    private(set) var nativeCode: Int32?

    init(stage: Stage, code: Code, metadataField: MetadataField? = nil) {
        self.stage = stage
        self.code = code
        self.metadataField = metadataField
        sqliteCode = nil
        nativeCode = nil
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? PhotoSyncFailure { return isCancellation(failure.underlyingError) }
        // Bridging a Swift LocalizedError to NSError can evaluate its private
        // errorDescription/userInfo. Inspect only an already-native NSError.
        guard type(of: error) is NSError.Type else { return false }
        return PhotoImageRequestInfo.isCancellation(error)
    }

    /// Does not classify by the current stage, arbitrary text or NSError code.
    /// Callers handle cancellation BEFORE creating a failure diagnostic.
    static func classify(_ error: Error, stage: Stage) -> Self {
        if let failure = error as? PhotoSyncFailure { return failure.diagnostic }
        if let diagnostic = error as? Self { return diagnostic }
        if let source = error as? SimilarCleanupDiagnostic {
            switch source.code {
            case .indexOpen, .indexPrepare, .indexStep, .indexBind,
                 .indexSchemaMissing, .indexSchemaUnsupported,
                 .indexMetadataMissing, .indexMetadataInvalid, .indexUnavailable:
                var result = Self(stage: stage, code: .sqlite)
                result.sqliteCode = source.code
                // SimilarCleanupDiagnostic already rejects numbers on schema /
                // metadata codes. Only actual SQLite call-site numbers survive.
                result.nativeCode = source.nativeCode
                return result
            default: return Self(stage: stage, code: .unknown)
            }
        }
        if let failure = error as? AppFailure {
            switch failure {
            case .permission: return Self(stage: stage, code: .permission)
            case .modelsMissing: return Self(stage: stage, code: .resources)
            case .modelContract: return Self(stage: stage, code: .model)
            case .storage: return Self(stage: stage, code: .storage)
            // An arbitrary .photo string does not establish invalid metadata,
            // a changed library, or revoked access. Known guards label themselves.
            case .photo, .cloudOnly, .places: break
            }
        }
        return Self(stage: stage, code: .unknown)
    }

    func atStage(_ stage: Stage) -> Self {
        var result = Self(stage: stage, code: code, metadataField: metadataField)
        result.sqliteCode = sqliteCode
        result.nativeCode = nativeCode
        return result
    }

    /// Same existing metadata checks, in the same order; only the failed field
    /// escapes. No field values are retained and no extra rejection is added.
    static func invalidField(_ revision: PhotoRevision, modelVersion: String? = nil,
                             duplicate: Bool) -> MetadataField? {
        if revision.id.isEmpty || revision.id.utf8.contains(0) { return .id }
        if modelVersion?.isEmpty == true { return .modelVersion }
        if !revision.modificationTime.isFinite { return .modificationTime }
        if revision.creationTime?.isFinite == false { return .creationTime }
        if duplicate { return .duplicateID }
        return nil
    }

    var identifier: String {
        let marker = sqliteCode.map { "SS-" + String($0.rawValue.dropFirst(3)) }
            ?? "SS-\(stage.rawValue)-\(code.rawValue)"
        return marker + (metadataField.map { "-\($0.rawValue)" } ?? "")
            + (nativeCode.map { " (\($0))" } ?? "")
    }

    var message: String {
        "同步未完成 · \(identifier) / \(stage.title)\n已完成的索引保留。"
    }
    var errorDescription: String? { message }
}

/// The thrown error keeps the original cause for typed callers/tests, separately
/// from the safe value published by PhotoSyncState. Never display/log that cause.
struct PhotoSyncFailure: Error, LocalizedError, CustomStringConvertible, CustomDebugStringConvertible {
    let diagnostic: PhotoSyncDiagnostic
    let underlyingError: Error

    init(error: Error, stage: PhotoSyncDiagnostic.Stage,
         code: PhotoSyncDiagnostic.Code? = nil, metadataField: PhotoSyncDiagnostic.MetadataField? = nil) {
        underlyingError = (error as? Self)?.underlyingError ?? error
        if let code {
            diagnostic = PhotoSyncDiagnostic(stage: stage, code: code, metadataField: metadataField)
        } else {
            diagnostic = PhotoSyncDiagnostic.classify(error, stage: stage).atStage(stage)
        }
    }

    var errorDescription: String? { diagnostic.message }
    var description: String { diagnostic.message }
    var debugDescription: String { diagnostic.message }
}