import Foundation

/// Fixed, user-facing labels only. Never attach a query, photo identifier,
/// coordinate, path, or raw error to a timing event.
enum SearchTimingStage: String, Sendable, CaseIterable {
    case queue = "调度／等待前任务"
    case translation = "查询翻译"
    case snapshot = "获取图库快照"
    case models = "准备搜索模型"
    case indexRead = "读取索引／准备缓存"
    case queryEncoding = "查询编码"
    case counts = "读取索引统计"
    case accessCheck = "搜索前访问检查"
    case scoring = "向量评分与排序"
    case textMatch = "照片文字匹配"
    case filtering = "筛选搜索结果"
    case finalAccess = "发布前访问检查"
    case publication = "返回／发布排名"
}

enum SearchTimingOutcome: String, Sendable {
    case ready = "排名已发布"
    case cancelled = "搜索已取消"
    case failed = "搜索失败"
}

/// IDs identify intervals, not stages: a stage may be entered more than once.
struct SearchTimingRow: Sendable, Identifiable {
    let id: Int
    let stage: SearchTimingStage
    let seconds: Double
}

struct SearchTimingReport: Sendable, Identifiable {
    let id: UUID
    let stages: [SearchTimingRow]
    let totalSeconds: Double
    let outcome: SearchTimingOutcome
    let mode: String
    let cacheSource: String
    let candidateCount: Int
    let matrixReused: Bool
    let snapshotReused: Bool
    /// From recorder creation, NOT from publication; never add to totalSeconds.
    let firstImageSeconds: Double?

    init(id: UUID, stages: [SearchTimingRow], totalSeconds: Double,
         outcome: SearchTimingOutcome, mode: String, cacheSource: String,
         candidateCount: Int, matrixReused: Bool, snapshotReused: Bool,
         firstImageSeconds: Double? = nil) {
        self.id = id
        self.stages = stages
        self.totalSeconds = totalSeconds
        self.outcome = outcome
        // Sanitize fixtures/direct construction as well as recorder inputs.
        self.mode = SearchTimingLabels.mode(mode)
        self.cacheSource = SearchTimingLabels.source(cacheSource)
        self.candidateCount = max(0, candidateCount)
        self.matrixReused = matrixReused
        self.snapshotReused = snapshotReused
        self.firstImageSeconds = firstImageSeconds
    }

    var slowest: SearchTimingRow? { stages.max { $0.seconds < $1.seconds } }

    /// Includes repeated visits; an unvisited stage contributes no time.
    func seconds(for stage: SearchTimingStage) -> Double {
        stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.seconds }
    }

    static func duration(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        return String(format: "%.3f 秒", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// Exact allowlists, never substring/path parsing or arbitrary string passthrough.
private enum SearchTimingLabels {
    static func mode(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accelerated", "加速": return "加速"
        case "reference", "baseline", "参考", "基线", "参考基线": return "参考基线"
        default: return "未知"
        }
    }

    static func source(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sqlite", "数据库读取": return "数据库读取"
        case "binary", "二进制缓存": return "二进制缓存"
        case "resident", "内存驻留": return "内存驻留"
        case "reference", "参考基线": return "参考基线"
        default: return "未知"
        }
    }
}

/// One search attempt, entirely in memory. Create before queueing/translation.
/// mark begins the next interval; finish closes the current one. The caller
/// marks serial wall-time boundaries, not overlapping child tasks.
///
/// Every mutable field and clock read is protected by one NSLock, never across
/// await. The injected clock must be synchronous and must not reenter this object.
/// No I/O, telemetry, query storage, or persistent/session history lives here.
final class SearchTimingRecorder: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private let began: Double
    private let mode: String
    private var last: Double
    private var stage: SearchTimingStage = .queue
    private var rows: [SearchTimingRow] = []
    private var cacheSource = "未知"
    private var candidateCount = 0
    private var matrixReused = false
    private var snapshotReused = false
    private var report: SearchTimingReport?

    init(mode: String = "加速",
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.mode = SearchTimingLabels.mode(mode)
        self.clock = clock
        let sample = clock()
        let instant = sample.isFinite && sample >= 0 ? sample : 0
        began = instant
        last = instant
    }

    func mark(_ stage: SearchTimingStage) {
        lock.lock()
        defer { lock.unlock() }
        guard report == nil, self.stage != stage else { return }
        closeStage(at: instant())
        self.stage = stage
    }

    /// count is the caller's actual candidate-row count, not the number of
    /// timing rows, requested result limit, or an estimate from vector dimensions.
    func setIndex(source: String, count: Int, matrixReused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard report == nil else { return }
        cacheSource = SearchTimingLabels.source(source)
        candidateCount = max(0, count)
        self.matrixReused = matrixReused
    }

    func setSnapshotReused(_ reused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard report == nil else { return }
        snapshotReused = reused
    }

    /// First outcome wins. Repeated finishes replay the snapshot without reading
    /// the clock. Only firstImage may subsequently enrich it; ranking stays frozen.
    func finish(_ outcome: SearchTimingOutcome) -> SearchTimingReport {
        lock.lock()
        defer { lock.unlock() }
        if let report { return report }
        closeStage(at: instant())
        // Use this same partition for the total (no second clock sample and no
        // independent floating-point accumulation that could disagree with rows).
        let value = SearchTimingReport(
            id: id, stages: rows, totalSeconds: rows.reduce(0) { $0 + $1.seconds },
            outcome: outcome, mode: mode, cacheSource: cacheSource,
            candidateCount: candidateCount, matrixReused: matrixReused,
            snapshotReused: snapshotReused)
        report = value
        return value
    }

    /// Called for a usable thumbnail only after this attempt published ready.
    /// The parent must reject stale attempt IDs on replacement/invalidation before
    /// calling: this scalar-only recorder cannot infer which search is on screen.
    /// Early, duplicate, cancelled and failed notifications do not read the clock.
    func firstImage() -> SearchTimingReport? {
        lock.lock()
        defer { lock.unlock() }
        guard let frozen = report, frozen.outcome == .ready,
              frozen.firstImageSeconds == nil else { return nil }
        let elapsed = max(frozen.totalSeconds, instant() - began)
        let value = SearchTimingReport(
            id: frozen.id, stages: frozen.stages, totalSeconds: frozen.totalSeconds,
            outcome: frozen.outcome, mode: frozen.mode, cacheSource: frozen.cacheSource,
            candidateCount: frozen.candidateCount, matrixReused: frozen.matrixReused,
            snapshotReused: frozen.snapshotReused, firstImageSeconds: elapsed)
        report = value
        return value
    }

    // Private helpers require the lock. Invalid or regressing injected samples
    // cannot introduce negative/nonfinite intervals or move a boundary backwards.
    private func instant() -> Double {
        let sample = clock()
        guard sample.isFinite, sample >= 0 else { return last }
        return max(last, sample)
    }

    private func closeStage(at instant: Double) {
        rows.append(SearchTimingRow(id: rows.count, stage: stage, seconds: instant - last))
        last = instant
    }
}