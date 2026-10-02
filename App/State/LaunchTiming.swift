import Foundation

/// Fixed labels only: no photo IDs, queries, coordinates, paths or raw errors.
enum LaunchTimingStage: String, Sendable, CaseIterable {
    case entry = "入口与权限状态"
    case queue = "调度／等待前任务"
    case worker = "进入准备任务"
    case places = "地点元数据（非地图）"
    case models = "模型准备入口"
    case resources = "模型资源检查"
    case tokenizer = "加载分词器"
    case imageModel = "加载图像模型"
    case textModel = "加载文本模型"
    case sharedModels = "等待已有模型任务"
    case cachedModels = "复用已加载模型"
    case counts = "读取已存索引统计"
    case publish = "返回／发布就绪"
}

enum LaunchTimingKind: String, Sendable {
    case cold = "本进程首次启动"
    case retry = "手动重试"
    case foreground = "中断后恢复"
}

enum LaunchTimingOutcome: String, Sendable {
    case ready = "准备完成"
    case failed = "准备失败"
    case interrupted = "准备中断"
}

struct LaunchTimingRow: Identifiable, Sendable {
    let id: Int
    let stage: LaunchTimingStage
    let seconds: Double
}

struct LaunchTimingReport: Identifiable, Sendable {
    let id: UUID
    let kind: LaunchTimingKind
    let outcome: LaunchTimingOutcome
    let totalSeconds: Double
    let rows: [LaunchTimingRow]

    var slowest: LaunchTimingRow? { rows.max { $0.seconds < $1.seconds } }

    static func duration(_ seconds: Double) -> String {
        String(format: "%.3f 秒", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

/// One attempt, with a monotonic clock. The lock is never held across await.
/// Marks partition wall time rather than adding overlapping parent/child spans.
/// A cancelled attempt freezes immediately; late shared-model callbacks are ignored.
final class LaunchTimingRecorder: @unchecked Sendable {
    let id = UUID()
    let kind: LaunchTimingKind
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private let began: Double
    private var last: Double
    private var stage: LaunchTimingStage = .entry
    private var rows: [LaunchTimingRow] = []
    private var finished = false

    init(kind: LaunchTimingKind, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.kind = kind
        self.now = now
        let instant = now()
        began = instant
        last = instant
    }

    func mark(_ next: LaunchTimingStage) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, stage != next else { return }
        closeStage(at: max(last, now()))
        stage = next
    }

    /// Returns a report only once, so overlapping completion/cancellation paths
    /// cannot append duplicates or overwrite the completed attempt.
    func finish(_ outcome: LaunchTimingOutcome) -> LaunchTimingReport? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        let instant = max(last, now())
        closeStage(at: instant)
        finished = true
        return LaunchTimingReport(id: id, kind: kind, outcome: outcome,
                                  totalSeconds: instant - began, rows: rows)
    }

    private func closeStage(at instant: Double) {
        rows.append(LaunchTimingRow(id: rows.count, stage: stage, seconds: instant - last))
        last = instant
    }
}