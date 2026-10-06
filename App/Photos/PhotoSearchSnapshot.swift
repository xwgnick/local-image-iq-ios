import Foundation

/// Optional search-only capability. Do not add it to PhotoLibraryIndexing's
/// defaults: legacy libraries must retain the worker's three full enumerations.
struct PhotoSearchSnapshot: Sendable {
    let revisions: [PhotoRevision]
    /// True only when the sorted metadata/map were reused. A false value can
    /// also mean rebuilding from an updated retained fetch, not a new query.
    let reused: Bool
    let validate: @Sendable () throws -> Void
    let validatePhotos: @Sendable ([String]) throws -> Void

    /// No-op defaults are for synthetic snapshots, not production access checks.
    init(revisions: [PhotoRevision], reused: Bool = false,
         validate: @escaping @Sendable () throws -> Void = {},
         validatePhotos: @escaping @Sendable ([String]) throws -> Void = { _ in }) {
        self.revisions = revisions
        self.reused = reused
        self.validate = validate
        self.validatePhotos = validatePhotos
    }
}

protocol PhotoSearchSnapshotting: Sendable {
    func searchSnapshot() throws -> PhotoSearchSnapshot
    func invalidateSearchSnapshot()
}

/// In-memory, versioned metadata cache; no PhotoKit, permission requests, timers,
/// automatic observation, pixels, persistence or work in init. Source must be an
/// immutable, shareable fetch result. Synthetic sources exercise this same core,
/// but cannot simulate the OS's delivery guarantees for PHChange.
///
/// Privacy contract: registered observers permit epoch-only global validation.
/// Until an OS change callback arrives, the global membership/revisions (and thus
/// a search's distinct-place center) can be stale even with unchanged authorization.
/// Fresh selected-ID validation detects inaccessible/changed checked photos even
/// before their event; it cannot establish freshness of unselected global context.
/// Neither this cache nor PhotoKit reads atomically lock the photo library. This
/// is NOT equivalent to the legacy three fresh, full metadata comparisons. Keep
/// existing publication/page checks; integration must explicitly accept this
/// tradeoff and invalidate on background/foreground, not on every refresh.
final class PhotoSearchSnapshotCache<Source: Sendable>: @unchecked Sendable {
    struct Access: Equatable, Sendable {
        let authorization: Int
        let canRead: Bool
    }

    private struct Epoch: Equatable, Sendable {
        let generation: UInt64
        let access: Access
        let observing: Bool
    }

    private struct Entry: Sendable {
        let identity = UUID()
        let revisions: [PhotoRevision]
        let byID: [String: PhotoRevision]

        init(_ revisions: [PhotoRevision]) {
            self.revisions = revisions.sorted { $0.id < $1.id }
            byID = Dictionary(revisions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    private let lock = NSLock()
    // Serialize cold captures, but never hold the state lock across a full load
    // or enumeration: changes must advance the epoch during those operations.
    private let captureLock = NSLock()
    private var generation: UInt64 = 0
    private var effectiveAccess: Access?
    private var observing = false
    private var retainedSource: Source?
    private var entry: Entry?

    var changeGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var isObserving: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observing
    }

    /// Called by the owner's explicit observation lifecycle, never by capture.
    /// A repeated refresh with unchanged access/registration preserves warm data.
    func synchronizeObservation(isRegistered: Bool, access: Access) {
        lock.lock()
        defer { lock.unlock() }
        let registered = isRegistered && access.canRead
        if effectiveAccess != access || observing != registered {
            invalidateLocked()
            effectiveAccess = access
            observing = registered
        }
    }

    /// Foreground/background and detected access failures drop the retained fetch
    /// as well as sorted metadata. The next capture loads a fresh source.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    /// Always advances the generation, including unrelated/nil-detail events.
    /// The bounded source replacement runs under the lock and must not reenter
    /// this cache or enumerate metadata. Old snapshots are invalid before notify.
    func libraryDidChange(updateSource: (Source) -> Source?) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        entry = nil
        if observing, let source = retainedSource {
            retainedSource = updateSource(source)
        } else {
            retainedSource = nil
        }
    }

    func capture(readAccess: @escaping @Sendable () -> Access,
                 loadSource: @escaping @Sendable () throws -> Source,
                 loadRevisions: @escaping @Sendable (Source) throws -> [PhotoRevision],
                 loadPhotos: @escaping @Sendable ([String]) throws -> [PhotoRevision]) throws -> PhotoSearchSnapshot {
        try Task.checkCancellation()
        captureLock.lock()
        defer { captureLock.unlock() }
        try Task.checkCancellation()

        lock.lock()
        let access = readAccess()
        updateAccessLocked(access)
        let epoch = Epoch(generation: generation, access: access, observing: observing)
        let cached = observing ? entry : nil
        let retained = observing ? retainedSource : nil
        lock.unlock()
        guard access.canRead else { throw AppFailure.permission }

        let captured: Entry
        if let cached {
            captured = cached
        } else {
            let source = try retained ?? loadSource()
            captured = Entry(try loadRevisions(source))
            try Task.checkCancellation()
            // Authorization, generation and registration must still match after
            // the slow work. Never install a result fetched across invalidation.
            lock.lock()
            let currentAccess = readAccess()
            updateAccessLocked(currentAccess)
            let current = Epoch(generation: generation, access: currentAccess, observing: observing)
            if current == epoch, epoch.observing {
                retainedSource = source
                entry = captured
            }
            lock.unlock()
            guard currentAccess.canRead else { throw AppFailure.permission }
            guard current == epoch else { throw Self.changed() }
        }
        try check(epoch, entry: captured, readAccess: readAccess)

        let validate: @Sendable () throws -> Void = { [self] in
            try check(epoch, entry: captured, readAccess: readAccess)
            if !epoch.observing {
                // No trustworthy events: every global boundary repeats a fresh
                // full metadata read (not just a count or fetch-result header).
                let current = try loadRevisions(loadSource()).sorted { $0.id < $1.id }
                try check(epoch, entry: captured, readAccess: readAccess)
                guard current == captured.revisions else {
                    reject(epoch)
                    throw Self.changed()
                }
                try check(epoch, entry: captured, readAccess: readAccess)
            }
        }
        return PhotoSearchSnapshot(revisions: captured.revisions, reused: cached != nil,
                                   validate: validate, validatePhotos: { [self] ids in
            try check(epoch, entry: captured, readAccess: readAccess)
            let requested = Array(Set(ids)).sorted()
            guard requested.allSatisfy({ captured.byID[$0] != nil }) else { throw Self.changed() }
            if !requested.isEmpty {
                // One batch, never one fetch per ID. Duplicate caller IDs are
                // dependencies on the same photo, not additional returned rows.
                let current = try loadPhotos(requested)
                try check(epoch, entry: captured, readAccess: readAccess)
                let returnedIDs = Set(current.map(\.id))
                guard current.count == requested.count, returnedIDs == Set(requested),
                      current.allSatisfy({ captured.byID[$0.id] == $0 }) else {
                    // A missed event affecting selected metadata poisons this
                    // entire generation, not only this query's local snapshot.
                    reject(epoch)
                    throw Self.changed()
                }
            }
            // For non-observing clients this also repeats full metadata once.
            // Observing clients perform only the final authorization/epoch check.
            try validate()
        })
    }

    private func check(_ epoch: Epoch, entry captured: Entry,
                       readAccess: @Sendable () -> Access) throws {
        try Task.checkCancellation()
        lock.lock()
        let access = readAccess()
        updateAccessLocked(access)
        let current = Epoch(generation: generation, access: access, observing: observing)
        let identityMatches = !epoch.observing || entry?.identity == captured.identity
        lock.unlock()
        guard access.canRead else { throw AppFailure.permission }
        guard current == epoch, identityMatches else { throw Self.changed() }
        try Task.checkCancellation()
    }

    private func updateAccessLocked(_ access: Access) {
        if effectiveAccess != access {
            invalidateLocked()
            effectiveAccess = access
        }
    }

    private func invalidateLocked() {
        generation &+= 1
        retainedSource = nil
        entry = nil
    }

    private func reject(_ epoch: Epoch) {
        lock.lock()
        defer { lock.unlock() }
        // An old validator must not evict a newer, already rebuilt generation.
        if generation == epoch.generation { invalidateLocked() }
    }

    private static func changed() -> AppFailure {
        .photo("Photo access changed during search. Search again.")
    }
}