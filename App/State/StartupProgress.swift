import CryptoKit
import Foundation

/// Nine distinct requirements, not time slices or estimates of remaining work.
/// Callers mark only completed requirements; waiting/cached/shared paths add no steps.
enum StartupStep: String, Sendable, CaseIterable {
    /// Entry and permission-state setup has returned (no photo enumeration).
    case entry = "入口与权限状态"
    /// Lightweight place metadata is available, including a known unavailable result.
    case places = "地点元数据"
    /// Required model resources and the manifest contract have been checked.
    case resources = "模型资源检查"
    /// The tokenizer has loaded successfully.
    case tokenizer = "分词器就绪"
    /// The primary image model has loaded and passed its contract checks.
    case imageModel = "图像模型就绪"
    /// The text model has loaded and passed its contract checks.
    case textModel = "文本模型就绪"
    /// The complete, validated model/tokenizer set has been assembled and published.
    case assembly = "模型组装完成"
    /// Read-only stored-index statistics have returned.
    case counts = "索引统计完成"
    /// The launch owner has actually published ready, not merely finished model loading.
    case ready = "启动就绪"

    static let modelSteps: Set<StartupStep> = [.resources, .tokenizer, .imageModel, .textModel, .assembly]
}

struct StartupProgressSnapshot: Sendable, Equatable {
    let completed: Set<StartupStep>

    var fraction: Double { Double(completed.count) / 9.0 }
}

/// All mutable state is protected by one lock; listeners execute with no lock held.
/// Notifications contain full snapshots and may arrive out of order, even relative
/// to registration replay. Consumers must union completed sets, not replace them.
///
/// This recorder has no clock, task cancellation, timing-recorder ownership or I/O.
/// A shared model load owns its own instance. Each launch attempt observes that
/// channel and removes its observation on cancellation; freezing an attempt must
/// never freeze the shared channel needed by a later waiter.
final class StartupProgressRecorder: @unchecked Sendable {
    private typealias Listener = @Sendable (StartupProgressSnapshot) -> Void
    private let lock = NSLock()
    private var completed: Set<StartupStep> = []
    private var observers: [UUID: Listener] = [:]
    private var frozen = false

    func complete(_ step: StartupStep) { complete([step]) }

    /// A batch produces one notification, and duplicates/empty batches produce none.
    func complete(_ steps: Set<StartupStep>) {
        lock.lock()
        guard !frozen, !steps.isSubset(of: completed) else {
            lock.unlock()
            return
        }
        completed.formUnion(steps)
        let value = StartupProgressSnapshot(completed: completed)
        let ids = Array(observers.keys)
        lock.unlock()

        for id in ids { deliver(value, to: id) }
    }

    var snapshot: StartupProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StartupProgressSnapshot(completed: completed)
    }

    /// Registers atomically with respect to completion, then synchronously replays
    /// outside the lock. After freeze, observation is a one-shot frozen replay and
    /// is not retained. A registration replay already captured before freeze is
    /// also allowed to finish; it can be older than a concurrent notification.
    func observe(_ listener: @escaping @Sendable (StartupProgressSnapshot) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if !frozen { observers[id] = listener }
        let replay = StartupProgressSnapshot(completed: completed)
        lock.unlock()
        listener(replay)
        return id
    }

    /// Stops future delivery admissions, not the shared producer. A callback
    /// already admitted on another thread may still finish; removal never waits.
    func removeObserver(_ id: UUID) {
        lock.lock()
        let removed = observers.removeValue(forKey: id)
        lock.unlock()
        // Release captured objects outside the state lock as well.
        withExtendedLifetime(removed) {}
    }

    /// Permanently freezes the completed set without adding .ready or notifying.
    /// No further change notifications are admitted, including pending listeners
    /// in an existing broadcast. Explicit observe() replay remains allowed.
    /// Already-admitted callbacks may finish: this is not a callback-drain barrier
    /// and does not block or deadlock when called reentrantly by a listener.
    @discardableResult
    func freeze() -> StartupProgressSnapshot {
        lock.lock()
        frozen = true
        let value = StartupProgressSnapshot(completed: completed)
        let removed = observers
        observers.removeAll()
        lock.unlock()
        withExtendedLifetime(removed) {}
        return value
    }

    private func deliver(_ value: StartupProgressSnapshot, to id: UUID) {
        lock.lock()
        // Recheck each listener so reentrant removal/freeze also suppresses the
        // rest of this broadcast. The unlock is the delivery-admission boundary.
        let listener = frozen ? nil : observers[id]
        lock.unlock()
        listener?(value)
    }
}

/// An installation/build/OS/model-configuration identity, not proof of Core ML
/// cache presence or a prediction of load duration. Only its digest may persist.
struct StartupContext: Equatable, Sendable {
    let fingerprint: String

    /// Keep in step with the primary paired-model loading configuration.
    static let modelConfigurationIdentity = ".all/image+text/input64/primary"

    /// Reads only the small required manifest. Other resource lookups obtain URL
    /// identities only: no weights/tokenizer reads, directory walks, cache probes,
    /// model initialization, GPS or photo access. Missing/invalid manifest => nil.
    static func current(bundle: Bundle = .main) -> StartupContext? {
        guard let manifestURL = BundleResources.url("model-manifest", extension: "json", bundle: bundle),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ModelManifest.self, from: data) else { return nil }
        do { try manifest.validate() }
        catch { return nil }

        // The order is part of fingerprint v1. Missing payloads have an explicit
        // identity too; context construction is not runtime-resource validation.
        let urls: [URL?] = [
            manifestURL,
            BundleResources.url("ImageEncoder", extension: "mlmodelc", bundle: bundle),
            BundleResources.url("TextEncoder", extension: "mlmodelc", bundle: bundle),
            BundleResources.url("tokenizer", extension: "json", bundle: bundle),
            BundleResources.url("tokenizer_config", extension: "json", bundle: bundle)
        ]
        return StartupContext(fingerprint: makeFingerprint(
            manifestData: data, bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            bundleVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            resourceURLs: urls))
    }

    /// Pure test seam. Fields are UTF-8 (manifest bytes remain verbatim), framed
    /// with unsigned 64-bit big-endian byte lengths, and domain-separated as v1.
    /// URL paths are standardized, not persisted or resolved through cache files.
    /// resourceURLs is an ordered list; nil differs from an empty/present path.
    static func makeFingerprint(
        manifestData: Data, bundleURL: URL, bundleIdentifier: String,
        bundleVersion: String, shortVersion: String, operatingSystemVersion: String,
        modelConfigurationIdentity: String = StartupContext.modelConfigurationIdentity,
        resourceURLs: [URL?] = []
    ) -> String {
        var hash = SHA256()
        func append(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        append(Data("startupPreparation.context.v1".utf8))
        append(manifestData)
        for field in [bundleURL.standardizedFileURL.path, bundleIdentifier, bundleVersion,
                      shortVersion, operatingSystemVersion, modelConfigurationIdentity] {
            append(Data(field.utf8))
        }
        append(Data(String(resourceURLs.count).utf8))
        for url in resourceURLs {
            append(Data([url == nil ? 0 : 1]))
            if let url { append(Data(url.standardizedFileURL.path.utf8)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
protocol StartupHistoryStoring: AnyObject {
    func hasSuccessfulPreparation(for context: StartupContext) -> Bool
    func recordSuccessfulPreparation(for context: StartupContext)
}

/// Inject only from the production composition root; tests can use in-memory
/// conformers or isolated suites. There is no implicit/global standard store.
/// The launch owner calls recordSuccessfulPreparation only after actual ready,
/// never on failure, cancellation, a visibility delay, or model-only completion.
@MainActor
final class StartupHistoryStore: StartupHistoryStoring {
    static let key = "startupPreparation.success.v1"

    private struct Record: Codable {
        let schema: Int
        let fingerprint: String
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func hasSuccessfulPreparation(for context: StartupContext) -> Bool {
        guard Self.isFingerprint(context.fingerprint),
              let data = defaults.data(forKey: Self.key),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.schema == 1, Self.isFingerprint(record.fingerprint) else { return false }
        return record.fingerprint == context.fingerprint
    }

    func recordSuccessfulPreparation(for context: StartupContext) {
        guard Self.isFingerprint(context.fingerprint),
              let data = try? JSONEncoder().encode(Record(schema: 1, fingerprint: context.fingerprint)) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func isFingerprint(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

enum StartupDisplayPolicy {
    /// Visibility fallback only: above the observed ~5-second older-phone
    /// baseline. Not a deadline, timeout, minimum display time or fake completion.
    static let fallbackDelaySeconds: Double = 8

    /// A previous exact success reduces slow risk, but cannot prove cache warmth:
    /// the OS can evict prepared artifacts without changing this context.
    @MainActor
    static func predictsSlow(context: StartupContext?, history: (any StartupHistoryStoring)?) -> Bool {
        guard let context, let history else { return true }
        return !history.hasSuccessfulPreparation(for: context)
    }
}