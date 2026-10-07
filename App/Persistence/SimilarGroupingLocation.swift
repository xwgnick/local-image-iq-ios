import Darwin
import Foundation

/// Only the system Application Support base is allowed to contain aliases.
/// Append the fixed index child AFTER resolving that base, never resolve an
/// unchecked index directory/file or an arbitrary injected directory.
struct SimilarGroupingLocation: Sendable {
    let directory: URL
    let originalDirectory: URL
    private let base: Base?

    /// Strict injection: inert, with no resolution or filesystem access.
    init(directory: URL) {
        self.directory = directory
        originalDirectory = directory
        base = nil
    }

    private init(base: Base) {
        self.base = base
        directory = base.canonical.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
        originalDirectory = base.original.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
    }

    static func system() throws -> Self {
        try Task.checkCancellation()
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        return try applicationSupport(base)
    }

    /// The caller explicitly trusts this BASE as Application Support. Tests may
    /// supply a synthetic system base; directory injection must not use this API.
    static func applicationSupport(_ base: URL) throws -> Self {
        try Task.checkCancellation()
        let identity = try Base.identity(at: base)
        let canonical = try canonicalBase(base)
        guard try Base.identity(at: canonical) == identity else { throw changed() }
        let location = Self(base: Base(original: base, canonical: canonical, identity: identity))
        try location.validate()
        return location
    }

    /// Constant-size object checks, not a directory walk or source-content hash.
    /// Ignore base size/timestamps: creating a derived cache changes metadata.
    /// These checks detect observed retargeting, not every filesystem TOCTOU.
    func validate() throws {
        try Task.checkCancellation()
        guard let base else { return }
        let original = try Base.identity(at: base.original)
        let canonical = try Base.identity(at: base.canonical)
        guard original == canonical else { throw Self.changed() }
        if let initial = base.identity {
            guard original == initial else { throw Self.changed() }
        } else {
            // A genuinely absent support directory may appear empty. Keep its
            // resolved destination fixed even while both base identities are nil.
            guard try Self.canonicalBase(base.original).path == base.canonical.path else {
                throw Self.changed()
            }
        }
        try Task.checkCancellation()
    }

    private static func canonicalBase(_ base: URL) throws -> URL {
        // Foundation may retain a system-prefix alias. realpath supplies the
        // actual physical BASE without any hard-coded /var or /private rewrite.
        try physicalBase(base.resolvingSymlinksInPath())
    }

    private static func physicalBase(_ base: URL) throws -> URL {
        if let path = base.path.withCString({ Darwin.realpath($0, nil) }) {
            defer { free(path) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        let savedErrno = errno
        let parent = base.deletingLastPathComponent()
        guard savedErrno == ENOENT, parent.path != base.path else {
            throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceParentStat, nativeCode: savedErrno)
        }
        // Missing support is still a valid empty source. Resolve its existing
        // prefix and append only missing BASE components, without creating any.
        // This path-prefix work is not an index-directory or file-tree walk.
        return try physicalBase(parent).appendingPathComponent(base.lastPathComponent, isDirectory: true)
    }

    private static func changed() -> SimilarCleanupDiagnostic {
        .init(phase: .sourceCheck, code: .sourceFileIdentityChanged)
    }

    private struct ObjectIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private struct Base: Sendable {
        let original: URL
        let canonical: URL
        let identity: ObjectIdentity?

        /// Follow links ONLY for the trusted base, never for its index child.
        /// Check errors explicitly; URL resolution alone can silently fail.
        static func identity(at url: URL) throws -> ObjectIdentity? {
            var info = stat()
            guard url.path.withCString({ Darwin.stat(_:_:)($0, &info) }) == 0 else {
                let savedErrno = errno
                if savedErrno == ENOENT { return nil }
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceParentStat, nativeCode: savedErrno)
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw SimilarCleanupDiagnostic(phase: .sourceCheck, code: .sourceParentKind)
            }
            return ObjectIdentity(device: info.st_dev, inode: info.st_ino)
        }
    }
}