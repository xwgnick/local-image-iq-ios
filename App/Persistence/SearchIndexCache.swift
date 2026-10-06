import CryptoKit
import Darwin
import Foundation
import ImageIQCore
import SQLite3

enum SearchIndexCacheSource: String, Sendable {
    case sqlite, binary, resident
}

struct SearchIndexCacheResult: Sendable {
    let records: [CachedPhoto]
    let source: SearchIndexCacheSource
    let signature: String
}

/// Disposable, scope-bound records, not a scorer or a replacement for SQLite.
/// Initialization does no I/O. Only an explicit records request can write the
/// single derived file; this type never opens the image database for writing.
actor SearchIndexCache {
    private let directory: URL
    private var databaseURL: URL { directory.appendingPathComponent("index.sqlite3") }
    private var binaryURL: URL { directory.appendingPathComponent("search-vectors-v1.bin") }
    private var monitor: SearchCacheMonitor?
    private var resident: Resident?
    private var generation = UUID()
    private var ownPartials: Set<URL> = []

    init(directory: URL) { self.directory = directory }

    /// Closes the monitor and drops memory, but leaves the disposable disk file.
    func invalidate() {
        generation = UUID()
        resident = nil
        monitor = nil
    }

    /// Manual clear never enumerates or deletes image/OCR databases, sidecars,
    /// other actors' temporary files, or the containing directory.
    func clear() throws {
        invalidate()
        var failed = false
        for url in [binaryURL] + Array(ownPartials) {
            do {
                try Self.removeFileOnly(url)
                ownPartials.remove(url)
            } catch { failed = true }
        }
        if failed { throw SearchCacheFailure.unavailable }
    }

    func records(modelVersion: String, accessibleIDs: Set<String>,
                 load: @escaping @Sendable () async throws -> [CachedPhoto]) async throws -> SearchIndexCacheResult {
        // Actor reentrancy must not allow a suspended loader to undo clear(),
        // invalidate(), or a newer request (including a narrower access scope).
        let ticket = UUID()
        generation = ticket
        var publication: SearchCacheFileIdentity?
        do {
            try check(ticket)
            let scope = try SearchCacheScope(model: modelVersion, ids: accessibleIDs)
            let state = try cacheFacilityValue({ try observe() }) ?? .unsafe
            guard case .stable(let stamp) = state else {
                resident = nil
                return try await uncached(scope: scope, ids: accessibleIDs, ticket: ticket, load: load)
            }

            if let resident, resident.scope == scope, resident.stamp == stamp {
                if try unchanged(stamp) {
                    try check(ticket)
                    return SearchIndexCacheResult(records: resident.records, source: .resident,
                                                  signature: resident.signature)
                }
                self.resident = nil
                return try await uncached(scope: scope, ids: accessibleIDs, ticket: ticket, load: load)
            }
            resident = nil

            // Only the disposable file is ever read whole. The source database
            // is streamed in fixed 64 KiB chunks, including inaccessible rows as
            // opaque bytes, never interpreting their vector JSON.
            guard let sourceSHA = try cacheFacilityValue({ try Self.hashDatabase(databaseURL) }) else {
                return try await uncached(scope: scope, ids: accessibleIDs, ticket: ticket, load: load)
            }
            guard try unchanged(stamp) else {
                return try await uncached(scope: scope, ids: accessibleIDs, ticket: ticket, load: load)
            }
            let key = SearchCacheKey(scope: scope, databaseSHA256: sourceSHA)
            let signature = key.signature
            if let decoded = try readBinary(key: key, ids: accessibleIDs) {
                guard try unchanged(stamp) else {
                    return try await uncached(scope: scope, ids: accessibleIDs, ticket: ticket, load: load)
                }
                try check(ticket)
                resident = Resident(scope: scope, stamp: stamp, records: decoded, signature: signature)
                return SearchIndexCacheResult(records: decoded, source: .binary, signature: signature)
            }

            let loaded = try await load()
            try check(ticket)
            let records = try Self.acceptLoaded(loaded, scope: scope, ids: accessibleIDs)
            guard try unchanged(stamp) else { return try Self.uncachedResult(records) }

            // Serialization/disk errors are optional-cache misses, not search
            // failures. Source changes and cancellation are NOT swallowed.
            let data = try encodeIfPossible(records, key: key)
            if let data {
                let write = try persist(data, stamp: stamp, ticket: ticket)
                publication = write.publication
                guard write.safe else {
                    return try Self.uncachedResult(records)
                }
            }
            guard try unchanged(stamp) else {
                discardOwnPublication(publication)
                return try Self.uncachedResult(records)
            }
            try check(ticket)
            resident = Resident(scope: scope, stamp: stamp, records: records, signature: signature)
            return SearchIndexCacheResult(records: records, source: .sqlite, signature: signature)
        } catch {
            discardOwnPublication(publication)
            if generation == ticket { resident = nil }
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let failure = error as? SearchCacheFailure { throw failure }
            // No paths, private identifiers, SQLite messages or vector contents.
            throw SearchCacheFailure.unavailable
        }
    }

    private struct Resident {
        let scope: SearchCacheScope
        let stamp: SearchCacheStamp
        let records: [CachedPhoto]
        let signature: String
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard generation == ticket else { throw CancellationError() }
    }

    private static func uncachedResult(_ records: [CachedPhoto]) throws -> SearchIndexCacheResult {
        try Task.checkCancellation()
        return SearchIndexCacheResult(records: records, source: .sqlite, signature: UUID().uuidString)
    }

    private func uncached(scope: SearchCacheScope, ids: Set<String>, ticket: UUID,
                          load: @escaping @Sendable () async throws -> [CachedPhoto]) async throws -> SearchIndexCacheResult {
        resident = nil
        let loaded = try await load()
        try check(ticket)
        let records = try Self.acceptLoaded(loaded, scope: scope, ids: ids)
        try check(ticket)
        // A supplied SQLite snapshot is still useful during a writer/WAL. Its
        // UUID explicitly prevents the parent's matrix from reusing this read.
        return try Self.uncachedResult(records)
    }

    private static func acceptLoaded(_ loaded: [CachedPhoto], scope: SearchCacheScope,
                                     ids: Set<String>) throws -> [CachedPhoto] {
        var accepted: [CachedPhoto] = []
        var seen: Set<Data> = []
        for cached in loaded {
            try Task.checkCancellation()
            let photo = cached.photo
            // Normally already filtered by SQLitePhotoStore. Do this BEFORE
            // inspecting any vector even if a caller supplies an overbroad load.
            guard ids.contains(photo.id), Data(photo.modelVersion.utf8) == scope.modelUTF8 else { continue }
            try SearchCacheRow.validateMetadata(id: photo.id, revision: photo.modificationTime,
                                               creation: photo.creationTime)
            guard seen.insert(Data(photo.id.utf8)).inserted else { throw SearchCacheFailure.invalidRecords }
            try SearchCacheRow.validateVector(photo.imageEmbedding)
            if let place = photo.location { try SearchCacheRow.validateVector(place.vector) }
            accepted.append(cached)
        }
        return accepted
    }

    private enum Observation {
        case missing, unsafe, stable(SearchCacheStamp)
    }

    /// Only observation/hash I/O belongs here, never the supplied SQL loader.
    /// An unavailable cache facility cannot make the old read-only path fail,
    /// but a confirmed source disappearance/change or cancellation still must.
    private func cacheFacilityValue<T>(_ operation: () throws -> T) throws -> T? {
        do { return try operation() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let failure = error as? SearchCacheFailure {
                switch failure {
                case .unavailable, .unsafeMonitor: break
                case .sourceChanged, .invalidRecords: throw failure
                }
            } else {
                let ns = error as NSError
                guard ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain else { throw error }
                // Initial absence is an Observation.missing, not an exception.
                // Missing-file errors here mean it vanished during observation
                // or after observation while opening/streaming the source hash.
                if (ns.domain == NSCocoaErrorDomain &&
                    (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError)) ||
                    (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOENT) || ns.code == Int(ENOTDIR))) {
                    throw SearchCacheFailure.sourceChanged
                }
            }
            monitor = nil
            resident = nil
            return nil
        }
    }

    private func hasSidecars() throws -> Bool {
        for suffix in ["-journal", "-wal", "-shm"] {
            // Existence alone is unsafe, including an empty journal. Avoid a
            // second resource lookup racing a writer's removal of the sidecar.
            if try SearchCacheFileIdentity.attributes(URL(fileURLWithPath: databaseURL.path + suffix)) != nil {
                return true
            }
        }
        return false
    }

    /// data_version is comparable ONLY on this same live C connection. File
    /// replacement closes it before opening a new monitor with a new UUID.
    private func observe() throws -> Observation {
        try Task.checkCancellation()
        guard let before = try SearchCacheFileIdentity.read(databaseURL) else {
            monitor = nil
            resident = nil
            return .missing
        }
        guard try !hasSidecars() else {
            monitor = nil
            resident = nil
            return .unsafe
        }
        if let monitor, !monitor.openedFile.sameObject(as: before) { self.monitor = nil }
        do {
            if monitor == nil { monitor = try SearchCacheMonitor(url: databaseURL, identity: before) }
            guard let monitor else { throw SearchCacheFailure.unavailable }
            let version = try monitor.dataVersion()
            let after = try SearchCacheFileIdentity.read(databaseURL)
            guard try !hasSidecars() else {
                self.monitor = nil
                resident = nil
                return .unsafe
            }
            guard before == after else {
                self.monitor = nil
                throw SearchCacheFailure.sourceChanged
            }
            return .stable(SearchCacheStamp(file: before, connectionID: monitor.id, dataVersion: version))
        } catch SearchCacheFailure.unsafeMonitor {
            monitor = nil
            resident = nil
            return .unsafe
        }
    }

    /// No automatic job retry. A changed safe snapshot is an explicit generic
    /// error; journal/WAL activity instead keeps the one SQLite loader usable.
    private func unchanged(_ expected: SearchCacheStamp) throws -> Bool {
        switch try cacheFacilityValue({ try observe() }) ?? .unsafe {
        case .stable(let current):
            guard current == expected else { throw SearchCacheFailure.sourceChanged }
            return true
        case .unsafe: return false
        case .missing: throw SearchCacheFailure.sourceChanged
        }
    }

    private static func hashDatabase(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        try Task.checkCancellation()
        return Data(hash.finalize())
    }

    private func readBinary(key: SearchCacheKey, ids: Set<String>) throws -> [CachedPhoto]? {
        do {
            try Task.checkCancellation()
            let bytes = try Data(contentsOf: binaryURL)
            let decoder = PropertyListDecoder()
            let envelope = try decoder.decode(SearchCacheEnvelope.self, from: bytes)
            // Scope/model/source checks precede decoding ANY payload vectors.
            guard envelope.magic == SearchCacheEnvelope.magicValue, envelope.schema == 1,
                  envelope.key == key,
                  envelope.headerSHA256 == envelope.expectedHeaderSHA256,
                  envelope.payloadSHA256 == Data(SHA256.hash(data: envelope.payload)) else { return nil }
            try Task.checkCancellation()
            let rows = try decoder.decode([SearchCacheRow].self, from: envelope.payload)
            var seen: Set<Data> = []
            var result: [CachedPhoto] = []
            // Per-read, location-only memo: exact vector bytes, not String or
            // Float equality. Text/metadata and scope are still checked per row.
            var validatedLocationVectors: [Data: [Float]] = [:]
            for row in rows {
                try Task.checkCancellation()
                guard ids.contains(row.id), Data(row.modelVersion.utf8) == key.scope.modelUTF8,
                      seen.insert(Data(row.id.utf8)).inserted else { return nil }
                result.append(try row.record(validatedLocationVectors: &validatedLocationVectors))
            }
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil // A derived failure never hides an accessible SQLite error.
        }
    }

    private func encodeIfPossible(_ records: [CachedPhoto], key: SearchCacheKey) throws -> Data? {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            var packedLocations: [Data: Data] = [:]
            let rows = try records.map { cached -> SearchCacheRow in
                try Task.checkCancellation()
                let locationData = cached.photo.location.map { place -> Data in
                    let bytes = SearchCacheRow.pack(place.vector)
                    if let packed = packedLocations[bytes] { return packed }
                    packedLocations[bytes] = bytes
                    return bytes
                }
                return SearchCacheRow(cached, locationData: locationData)
            }
            let payload = try encoder.encode(rows)
            try Task.checkCancellation()
            let bytes = try encoder.encode(SearchCacheEnvelope(key: key, payload: payload))
            try Task.checkCancellation()
            return bytes
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    private func persist(_ bytes: Data, stamp: SearchCacheStamp, ticket: UUID) throws
        -> (safe: Bool, publication: SearchCacheFileIdentity?) {
        guard try unchanged(stamp) else { return (false, nil) }
        try check(ticket)
        let temporary = directory.appendingPathComponent(".search-vectors-v1-\(UUID().uuidString).tmp")
        ownPartials.insert(temporary)
        defer {
            if (try? Self.removeFileOnly(temporary)) != nil { ownPartials.remove(temporary) }
        }
        let identity: SearchCacheFileIdentity
        do {
            // Source existence implies the parent already exists. In particular
            // never create a directory for an absent/fresh-install database.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path)
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try bytes.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
            var excludedFile = temporary
            try excludedFile.setResourceValues(values)
            guard let stagedIdentity = try SearchCacheFileIdentity.read(temporary) else {
                throw SearchCacheFailure.unavailable
            }
            identity = stagedIdentity
        } catch {
            try check(ticket)
            return (try unchanged(stamp), nil) // Optional I/O failure, still usable in memory.
        }

        guard try unchanged(stamp) else { return (false, nil) }
        try check(ticket)
        // Same-directory POSIX rename atomically replaces only the derived file;
        // there is no delete-then-write window or partially written final file.
        let published = temporary.path.withCString { from in
            binaryURL.path.withCString { to in Darwin.rename(from, to) == 0 }
        }
        do {
            try check(ticket)
            let safe = try unchanged(stamp)
            if !safe, published { discardOwnPublication(identity) }
            return (safe, safe && published ? identity : nil)
        } catch {
            if published { discardOwnPublication(identity) }
            throw error
        }
    }

    private func discardOwnPublication(_ identity: SearchCacheFileIdentity?) {
        // Do not remove a different actor's replacement if it won the rename.
        if let identity, let current = try? SearchCacheFileIdentity.read(binaryURL),
           identity.sameObject(as: current) { try? Self.removeFileOnly(binaryURL) }
    }

    private static func removeFileOnly(_ url: URL) throws {
        guard let attributes = try SearchCacheFileIdentity.attributes(url) else { return }
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeSymbolicLink else { throw SearchCacheFailure.unavailable }
        try FileManager.default.removeItem(at: url)
    }
}

private enum SearchCacheFailure: Error, LocalizedError {
    case unavailable, sourceChanged, invalidRecords, unsafeMonitor

    var errorDescription: String? {
        switch self {
        case .sourceChanged: return "The search index changed while it was being read. Search again."
        default: return "The search index could not be read."
        }
    }
}

private struct SearchCacheStamp: Equatable {
    let file: SearchCacheFileIdentity
    let connectionID: UUID
    let dataVersion: Int64
}

private struct SearchCacheFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let resourceIdentifier: NSObject?
    let size: UInt64
    let modified: Date
    let created: Date

    func sameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && created == other.created
            && resourceIdentifier == other.resourceIdentifier
    }

    static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileNoSuchFileError || ns.code == NSFileReadNoSuchFileError) {
                return nil
            }
            throw SearchCacheFailure.unavailable
        }
    }

    static func read(_ url: URL) throws -> Self? {
        guard let attributes = try attributes(url) else { return nil }
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date else { throw SearchCacheFailure.unavailable }
        let values = try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return Self(device: device.uint64Value, inode: inode.uint64Value,
                    resourceIdentifier: values.fileResourceIdentifier as? NSObject,
                    size: size.uint64Value, modified: modified, created: created)
    }
}

/// Actor-owned, never transferred to a task. Wrapper deinit owns C-handle cleanup
/// (rather than accessing a non-Sendable pointer from an actor's deinitializer).
private final class SearchCacheMonitor {
    let id = UUID()
    let openedFile: SearchCacheFileIdentity
    private var handle: OpaquePointer?

    init(url: URL, identity: SearchCacheFileIdentity) throws {
        openedFile = identity
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SearchCacheFailure.unavailable
        }
        handle = pointer
        // No migrations, journal-mode assignments, busy timeout, or DB writes.
        do {
            guard sqlite3_db_readonly(handle, "main") == 1 else { throw SearchCacheFailure.unavailable }
            let mode = try statement("PRAGMA journal_mode") { query -> String in
                guard let text = sqlite3_column_text(query, 0) else { throw SearchCacheFailure.unavailable }
                return String(cString: text)
            }
            guard mode == "delete" else { throw SearchCacheFailure.unsafeMonitor }
        } catch {
            sqlite3_close(pointer)
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func dataVersion() throws -> Int64 {
        try requireNoReservedWriter()
        let version = try statement("PRAGMA data_version") { sqlite3_column_int64($0, 0) }
        try requireNoReservedWriter()
        return version
    }

    /// BEGIN IMMEDIATE can reserve a writer before creating a journal. Query the
    /// existing SQLite VFS lock, without acquiring a write lock/transaction or
    /// issuing a schema/configuration write. Sidecars still exclude WAL mode.
    private func requireNoReservedWriter() throws {
        var file: UnsafeMutablePointer<sqlite3_file>?
        guard sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK,
              let file, let methods = file.pointee.pMethods,
              let checkLock = methods.pointee.xCheckReservedLock else { throw SearchCacheFailure.unsafeMonitor }
        var reserved: Int32 = 0
        guard checkLock(file, &reserved) == SQLITE_OK, reserved == 0 else { throw SearchCacheFailure.unsafeMonitor }
    }

    private func statement<T>(_ sql: String, read: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &query, nil)
        defer { if let query { sqlite3_finalize(query) } }
        try check(prepared, expected: SQLITE_OK)
        guard let query else { throw SearchCacheFailure.unavailable }
        try check(sqlite3_step(query), expected: SQLITE_ROW)
        return try read(query)
    }

    private func check(_ status: Int32, expected: Int32) throws {
        if status == SQLITE_BUSY || status == SQLITE_LOCKED { throw SearchCacheFailure.unsafeMonitor }
        guard status == expected else { throw SearchCacheFailure.unavailable }
    }
}

private struct SearchCacheScope: Codable, Equatable {
    let modelUTF8: Data
    let idsSHA256: Data

    init(model: String, ids: Set<String>) throws {
        modelUTF8 = Data(model.utf8)
        var hash = SHA256()
        hash.update(data: Data("search-scope-v1".utf8))
        let sorted = ids.map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
        Self.update(Data(String(sorted.count).utf8), hash: &hash)
        for id in sorted {
            try Task.checkCancellation()
            Self.update(id, hash: &hash)
        }
        idsSHA256 = Data(hash.finalize())
    }

    // Length framing prevents delimiter/concatenation collisions in private IDs.
    static func update(_ bytes: Data, hash: inout SHA256) {
        var length = UInt64(bytes.count).littleEndian
        Swift.withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
        hash.update(data: bytes)
    }
}

private struct SearchCacheKey: Codable, Equatable {
    let scope: SearchCacheScope
    let databaseSHA256: Data

    var digest: Data {
        var hash = SHA256()
        hash.update(data: Data("search-vectors-v1".utf8))
        SearchCacheScope.update(scope.modelUTF8, hash: &hash)
        SearchCacheScope.update(scope.idsSHA256, hash: &hash)
        SearchCacheScope.update(databaseSHA256, hash: &hash)
        return Data(hash.finalize())
    }

    var signature: String { digest.map { String(format: "%02x", $0) }.joined() }
}

private struct SearchCacheEnvelope: Codable {
    static let magicValue = "LocalImageIQ.SearchVectors"
    let magic: String
    let schema: Int
    let key: SearchCacheKey
    let payload: Data
    let payloadSHA256: Data
    let headerSHA256: Data

    init(key: SearchCacheKey, payload: Data) {
        magic = Self.magicValue
        schema = 1
        self.key = key
        self.payload = payload
        payloadSHA256 = Data(SHA256.hash(data: payload))
        headerSHA256 = Self.headerHash(key: key, payloadHash: payloadSHA256)
    }

    var expectedHeaderSHA256: Data { Self.headerHash(key: key, payloadHash: payloadSHA256) }

    private static func headerHash(key: SearchCacheKey, payloadHash: Data) -> Data {
        var hash = SHA256()
        hash.update(data: Data((magicValue + ":1").utf8))
        hash.update(data: key.digest)
        hash.update(data: payloadHash)
        return Data(hash.finalize())
    }
}

/// Per-record place storage deliberately preserves SQLite BINARY UTF-8 identity
/// and geography/model metadata, without a Swift String-normalizing dictionary.
/// Float bytes are little-endian bit patterns, not plist/JSON floating numbers.
private struct SearchCacheRow: Codable {
    let id: String
    let modificationTime: Double
    let modelVersion: String
    let creationTime: Double?
    let geographyVersion: String
    let image: Data
    let locationText: String?
    let locationVector: Data?

    init(_ cached: CachedPhoto, locationData: Data? = nil) {
        let photo = cached.photo
        id = photo.id
        modificationTime = photo.modificationTime
        modelVersion = photo.modelVersion
        creationTime = photo.creationTime
        geographyVersion = cached.geographyVersion
        image = Self.pack(photo.imageEmbedding)
        locationText = photo.location?.text
        locationVector = locationData ?? photo.location.map { Self.pack($0.vector) }
    }

    func record(validatedLocationVectors: inout [Data: [Float]]) throws -> CachedPhoto {
        try Self.validateMetadata(id: id, revision: modificationTime, creation: creationTime)
        guard (locationText == nil) == (locationVector == nil) else { throw SearchCacheFailure.invalidRecords }
        let vector = try Self.unpack(image)
        var place: PlaceEmbedding?
        if let text = locationText, let data = locationVector {
            let location: [Float]
            if let validated = validatedLocationVectors[data] {
                location = validated
            } else {
                location = try Self.unpack(data)
                validatedLocationVectors[data] = location
            }
            // Cache only the vector, never the text-bearing PlaceEmbedding.
            // Same text with different bytes must reach Core unchanged so its
            // inconsistent-place check can still reject different vectors.
            place = PlaceEmbedding(text: text, vector: location)
        }
        return CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: modificationTime,
                                               modelVersion: modelVersion, imageEmbedding: vector,
                                               location: place, creationTime: creationTime),
                           geographyVersion: geographyVersion)
    }

    static func validateMetadata(id: String, revision: Double, creation: Double?) throws {
        guard !id.isEmpty, revision.isFinite, creation?.isFinite != false else { throw SearchCacheFailure.invalidRecords }
    }

    static func validateVector(_ vector: [Float]) throws {
        guard vector.count == 512 || vector.count == 768 else { throw SearchCacheFailure.invalidRecords }
        try EmbeddingValidation.validateUnit(vector, dimension: vector.count)
    }

    private static let isLittleEndian = UInt32(1).littleEndian == 1

    static func pack(_ vector: [Float]) -> Data {
        if isLittleEndian {
            return vector.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        // Retain the v1 little-endian representation on a big-endian host too.
        let bits = vector.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func unpack(_ bytes: Data) throws -> [Float] {
        // Shape bounds are the existing decoder contract, not a file/row cap.
        guard bytes.count == 512 * 4 || bytes.count == 768 * 4 else { throw SearchCacheFailure.invalidRecords }
        var vector = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
        // Plist Data need not be Float-aligned. Copy bytes into allocated Float
        // storage; never bind or load native words from the source Data pointer.
        vector.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        if !isLittleEndian {
            for index in vector.indices {
                vector[index] = Float(bitPattern: vector[index].bitPattern.littleEndian)
            }
        }
        try validateVector(vector)
        return vector
    }
}