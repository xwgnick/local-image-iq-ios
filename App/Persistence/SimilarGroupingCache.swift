import CryptoKit
import Darwin
import Foundation
import ImageIQCore

/// A content identity, NOT a PhotoKit notification generation. Favorite/album
/// notifications across operations may reuse it when full revisions still match.
struct SimilarGroupingCacheKey: Codable, Equatable, Sendable {
    let authorizedRevisionDigest: Data
    let imagePayloadSignature: Data
    let modelUTF8: Data
    let policyUTF8: Data
    let algorithmUTF8: Data
    let authorization: Int?
    let thresholdBits: UInt32

    init(authorized: [String: PhotoRevision], imagePayloadSignature: Data,
         modelVersion: String, authorization: Int?, threshold: Float,
         algorithmVersion: String = SimilarPhotoGroupingPolicy.algorithmVersion,
         policyVersion: String = IndexImagePolicy.version) throws {
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        guard !modelVersion.isEmpty, imagePayloadSignature.count == SHA256.Digest.byteCount else {
            throw SimilarGroupingCacheError.invalid
        }
        authorizedRevisionDigest = try SimilarGroupingDigest.authorized(authorized)
        self.imagePayloadSignature = imagePayloadSignature
        modelUTF8 = Data(modelVersion.utf8)
        policyUTF8 = Data(policyVersion.utf8)
        algorithmUTF8 = Data(algorithmVersion.utf8)
        self.authorization = authorization
        thresholdBits = threshold.bitPattern
    }
}

enum SimilarGroupingDigest {
    static func bits(_ value: UInt64) -> Data {
        var little = value.littleEndian
        return Swift.withUnsafeBytes(of: &little) { Data($0) }
    }

    static func frame(_ bytes: Data, into hash: inout SHA256) {
        hash.update(data: bits(UInt64(bytes.count)))
        hash.update(data: bytes)
    }

    static func validate(_ revision: PhotoRevision) throws {
        guard !revision.id.isEmpty, revision.modificationTime.isFinite,
              revision.creationTime?.isFinite != false else { throw SimilarGroupingCacheError.invalid }
    }

    static func revision(_ revision: PhotoRevision, into hash: inout SHA256) {
        frame(Data(revision.id.utf8), into: &hash)
        frame(bits(revision.modificationTime.bitPattern), into: &hash)
        // Empty vs eight bytes distinguishes nil from zero (including -0).
        frame(revision.creationTime.map { bits($0.bitPattern) } ?? Data(), into: &hash)
    }

    static func sameRevision(_ lhs: PhotoRevision, _ rhs: PhotoRevision) -> Bool {
        Data(lhs.id.utf8) == Data(rhs.id.utf8)
            && lhs.modificationTime.bitPattern == rhs.modificationTime.bitPattern
            && lhs.creationTime?.bitPattern == rhs.creationTime?.bitPattern
    }

    static func authorized(_ revisions: [String: PhotoRevision]) throws -> Data {
        var hash = SHA256()
        frame(Data("grouping-authorized-full-revisions-v1".utf8), into: &hash)
        frame(bits(UInt64(revisions.count)), into: &hash)
        let ordered = try revisions.keys.sorted {
            try Task.checkCancellation()
            return $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for id in ordered {
            try Task.checkCancellation()
            guard let value = revisions[id], Data(id.utf8) == Data(value.id.utf8) else {
                throw SimilarGroupingCacheError.invalid
            }
            try validate(value)
            revision(value, into: &hash)
        }
        return Data(hash.finalize())
    }
}

struct SimilarGroupingCachedResult: Sendable {
    let groups: [SimilarPhotoGroup]
    let candidateCount: Int
    let staleCount: Int
    let unindexedCount: Int
    let threshold: Float
}

enum SimilarGroupingCacheRead: Sendable {
    case missing
    case stale
    case restored(SimilarGroupingCachedResult)
}

enum SimilarGroupingCacheError: Error, LocalizedError {
    case invalid, unavailable
    var errorDescription: String? { "无法读取或保存相似照片分组。请手动重新分组。" }
}

/// Completed results only, including a successful zero-group result. Initialization
/// is inert. Reads never create a folder, touch protected source files, repair a
/// cache, or fall back to computation. The sole write is an explicit group save.
/// SHA-256 detects accidental corruption; it is not an authenticity signature.
struct SimilarGroupingCache: Sendable {
    static let fileName = "similar-groups-v1.bin"
    let directory: URL
    // Deterministic pre-rename fault/cancellation injection for native tests.
    private let beforeCommit: @Sendable () throws -> Void

    init(directory: URL, beforeCommit: @escaping @Sendable () throws -> Void = {}) {
        self.directory = directory
        self.beforeCommit = beforeCommit
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func read(key: SimilarGroupingCacheKey, authorized: [String: PhotoRevision],
              indexed: [String: PhotoRevision]) throws -> SimilarGroupingCacheRead {
        try Task.checkCancellation()
        let bytes: Data
        do {
            guard let directoryFD = try openDirectory() else { return .missing }
            defer { Darwin.close(directoryFD) }
            let fd = Self.fileName.withCString { Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
            guard fd >= 0 else {
                if errno == ENOENT { return .missing }
                if errno == ELOOP || errno == ENOTDIR { return .stale }
                throw SimilarGroupingCacheError.unavailable
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, Self.isRegular(info), info.st_nlink == 1 else { return .stale }
            bytes = try handle.readToEnd() ?? Data()
        } catch SimilarGroupingCacheError.invalid {
            return .stale // Symlink/non-directory is not first use.
        } catch {
            try Task.checkCancellation()
            // Existing but unreadable MUST NOT turn into an automatic first run.
            throw AppFailure.storage("无法读取已保存的相似照片分组。请稍后手动重试。")
        }
        try Task.checkCancellation()
        do {
            let envelope = try PropertyListDecoder().decode(SimilarGroupingCacheEnvelope.self, from: bytes)
            try Task.checkCancellation()
            guard envelope.magic == SimilarGroupingCacheEnvelope.magicValue, envelope.schema == 1,
                  envelope.payloadSHA256 == Data(SHA256.hash(data: envelope.payload)) else { return .stale }
            let payload = try PropertyListDecoder().decode(SimilarGroupingCachePayload.self, from: envelope.payload)
            try Task.checkCancellation()
            // No vector materialization until complete input identity matches.
            guard payload.key == key else { return .stale }
            let result = try payload.validated(authorized: authorized, indexed: indexed)
            try Task.checkCancellation()
            return .restored(result)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return .stale
        }
    }

    func save(groups: [SimilarPhotoGroup], candidateCount: Int, staleCount: Int,
              unindexedCount: Int, key: SimilarGroupingCacheKey,
              authorized: [String: PhotoRevision], indexed: [String: PhotoRevision],
              validate: @Sendable () throws -> Void = {}) throws {
        try Task.checkCancellation()
        try validate()
        let payload = try SimilarGroupingCachePayload(groups: groups, candidateCount: candidateCount,
                                                      staleCount: staleCount, unindexedCount: unindexedCount, key: key)
        _ = try payload.validated(authorized: authorized, indexed: indexed)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payloadBytes = try encoder.encode(payload)
        let bytes = try encoder.encode(SimilarGroupingCacheEnvelope(payload: payloadBytes))
        try Task.checkCancellation()
        try validate()

        if try openAndCloseDirectory() == false {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        guard let directoryFD = try openDirectory() else { throw SimilarGroupingCacheError.unavailable }
        defer { Darwin.close(directoryFD) }
        try Self.protect(directory)
        try requireSafeDestination(directoryFD)
        let temporaryName = ".similar-groups-\(UUID().uuidString).tmp"
        let temporaryURL = directory.appendingPathComponent(temporaryName)
        let fd = temporaryName.withCString {
            Darwin.openat(directoryFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard fd >= 0 else { throw SimilarGroupingCacheError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var own = stat()
        let ownsIdentity = fstat(fd, &own) == 0
        defer {
            try? handle.close()
            // Never unlink an unknown/replaced temp, symlink or source file.
            var current = stat()
            let found = temporaryName.withCString { fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW) }
            if ownsIdentity, found == 0, Self.isRegular(current), current.st_dev == own.st_dev, current.st_ino == own.st_ino {
                _ = temporaryName.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }
        guard ownsIdentity else { throw SimilarGroupingCacheError.unavailable }
        try Self.protect(temporaryURL)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        try beforeCommit()
        try Task.checkCancellation()
        try validate()
        try requireSafeDestination(directoryFD)
                var staged = stat()
                let stagedStatus = temporaryName.withCString { fstatat(directoryFD, $0, &staged, AT_SYMLINK_NOFOLLOW) }
                guard stagedStatus == 0, Self.isRegular(staged), staged.st_nlink == 1,
                            staged.st_dev == own.st_dev, staged.st_ino == own.st_ino else {
                        throw SimilarGroupingCacheError.invalid
                }
        // Atomic same-directory publication; all throwing validation/I/O occurs
        // before rename. A failed/cancelled staging operation preserves old data.
        let status = temporaryName.withCString { from in
            Self.fileName.withCString { to in renameat(directoryFD, from, directoryFD, to) }
        }
        guard status == 0 else { throw SimilarGroupingCacheError.unavailable }
    }

    /// Shared by the new SQL readers: no fileExists ambiguity on EACCES and no
    /// symlink following. It never deletes, creates or changes the image index.
    static func regularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        if status != 0 {
            if errno == ENOENT { return false }
            throw AppFailure.storage("无法读取图片索引。")
        }
        guard isRegular(info) else { throw AppFailure.storage("图片索引不是普通文件。") }
        return true
    }

    private static func isRegular(_ info: stat) -> Bool { (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) }

    private func openDirectory() throws -> Int32? {
        let fd = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        if fd >= 0 { return fd }
        if errno == ENOENT { return nil }
        if errno == ELOOP || errno == ENOTDIR { throw SimilarGroupingCacheError.invalid }
        throw SimilarGroupingCacheError.unavailable
    }

    private func openAndCloseDirectory() throws -> Bool {
        guard let fd = try openDirectory() else { return false }
        Darwin.close(fd)
        return true
    }

    private func requireSafeDestination(_ fd: Int32) throws {
        var info = stat()
        let status = Self.fileName.withCString { fstatat(fd, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            if errno == ENOENT { return }
            throw SimilarGroupingCacheError.unavailable
        }
        guard Self.isRegular(info), info.st_nlink == 1 else { throw SimilarGroupingCacheError.invalid }
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}

struct SimilarGroupingCacheEnvelope: Codable {
    static let magicValue = "LocalImageIQ.CompletedSimilarGroups"
    let magic: String
    let schema: Int
    let payload: Data
    let payloadSHA256: Data

    init(payload: Data) {
        magic = Self.magicValue
        schema = 1
        self.payload = payload
        payloadSHA256 = Data(SHA256.hash(data: payload))
    }
}

/// All identity and counts live INSIDE the integrity-checked payload. Only grouped
/// photos need binary vectors; singleton/unindexed revisions remain in the key.
struct SimilarGroupingCachePayload: Codable {
    let key: SimilarGroupingCacheKey
    let candidateCount: Int
    let staleCount: Int
    let unindexedCount: Int
    let groups: [SimilarGroupingCacheGroup]

    init(groups: [SimilarPhotoGroup], candidateCount: Int, staleCount: Int,
         unindexedCount: Int, key: SimilarGroupingCacheKey) throws {
        self.key = key
        self.candidateCount = candidateCount
        self.staleCount = staleCount
        self.unindexedCount = unindexedCount
        var packed: [SimilarGroupingCacheGroup] = []
        for group in groups {
            try Task.checkCancellation()
            var photos: [SimilarGroupingCachePhoto] = []
            for photo in group.photos {
                try Task.checkCancellation()
                photos.append(SimilarGroupingCachePhoto(photo))
            }
            packed.append(SimilarGroupingCacheGroup(id: group.id, minimumBits: group.minimumSimilarity.bitPattern, photos: photos))
        }
        self.groups = packed
    }

    /// O(N log N + grouped N*768), not pairwise clique regeneration. Integrity
    /// protects the completed arithmetic; structural checks protect membership.
    func validated(authorized: [String: PhotoRevision], indexed: [String: PhotoRevision]) throws -> SimilarGroupingCachedResult {
        let threshold = Float(bitPattern: key.thresholdBits)
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        guard try key.authorizedRevisionDigest == SimilarGroupingDigest.authorized(authorized),
              indexed.count <= authorized.count else { throw SimilarGroupingCacheError.invalid }
        var eligible: [String: PhotoRevision] = [:]
        for (id, revision) in indexed {
            try Task.checkCancellation()
            try SimilarGroupingDigest.validate(revision)
            guard let current = authorized[id], Data(id.utf8) == Data(revision.id.utf8),
                  Data(current.id.utf8) == Data(id.utf8) else { throw SimilarGroupingCacheError.invalid }
            if SimilarGroupingDigest.sameRevision(current, revision) { eligible[id] = revision }
        }
        guard candidateCount == eligible.count, staleCount == indexed.count - eligible.count,
              unindexedCount == authorized.count - indexed.count else { throw SimilarGroupingCacheError.invalid }
        var seen = Set<Data>()
        var decoded: [SimilarPhotoGroup] = []
        var previous: SimilarGroupingCacheGroup?
        for group in groups {
            try Task.checkCancellation()
            let minimum = Float(bitPattern: group.minimumBits)
            guard group.photos.count >= 2, minimum.isFinite, minimum >= threshold, minimum <= 1,
                  let first = group.photos.first, Data(first.id.utf8) == Data(group.id.utf8) else {
                throw SimilarGroupingCacheError.invalid
            }
            if let previous {
                guard previous.photos.count > group.photos.count ||
                        (previous.photos.count == group.photos.count && previous.id < group.id) else {
                    throw SimilarGroupingCacheError.invalid
                }
            }
            var photos: [IndexedPhoto] = []
            for row in group.photos {
                try Task.checkCancellation()
                let revision = PhotoRevision(id: row.id, modificationTime: row.modificationTime, creationTime: row.creationTime)
                guard let expected = eligible[row.id], SimilarGroupingDigest.sameRevision(revision, expected),
                      Data(row.modelVersion.utf8) == key.modelUTF8, row.id >= group.id,
                      seen.insert(Data(row.id.utf8)).inserted else { throw SimilarGroupingCacheError.invalid }
                photos.append(try row.photo())
            }
            decoded.append(SimilarPhotoGroup(id: group.id, photos: photos, minimumSimilarity: minimum))
            previous = group
        }
        guard seen.count <= candidateCount else { throw SimilarGroupingCacheError.invalid }
        return SimilarGroupingCachedResult(groups: decoded, candidateCount: candidateCount,
                                            staleCount: staleCount, unindexedCount: unindexedCount, threshold: threshold)
    }
}

struct SimilarGroupingCacheGroup: Codable {
    let id: String
    let minimumBits: UInt32
    let photos: [SimilarGroupingCachePhoto]
}

struct SimilarGroupingCachePhoto: Codable {
    let id: String
    let modificationTime: Double
    let creationTime: Double?
    let modelVersion: String
    let image: Data

    init(_ photo: IndexedPhoto) {
        id = photo.id
        modificationTime = photo.modificationTime
        creationTime = photo.creationTime
        modelVersion = photo.modelVersion
        // Raw little-endian Float bits; never plist float coercion/JSON. No GPS,
        // place text or location vector is part of a cleanup result on disk.
        let words: [UInt32] = photo.imageEmbedding.map { $0.bitPattern.littleEndian }
        image = words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func photo() throws -> IndexedPhoto {
        guard image.count == 768 * MemoryLayout<UInt32>.size else { throw SimilarGroupingCacheError.invalid }
        var words = [UInt32](repeating: 0, count: 768)
        _ = words.withUnsafeMutableBytes { image.copyBytes(to: $0) }
        let vector: [Float] = words.map { Float(bitPattern: UInt32(littleEndian: $0)) }
        try EmbeddingValidation.validateUnit(vector, dimension: 768)
        return IndexedPhoto(id: id, modificationTime: modificationTime, modelVersion: modelVersion,
                            imageEmbedding: vector, location: nil, creationTime: creationTime)
    }
}