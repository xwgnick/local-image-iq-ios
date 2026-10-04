import Foundation

/// Fixed labels only: no photo IDs, queries, coordinates, paths or raw errors.
enum LaunchTimingStage: String, Sendable, CaseIterable {
    case entry = "入口与权限状态"
    case queue = "调度／等待前任务"
    case worker = "进入准备任务"
    case places = "地点元数据（非地图）"
    case models = "模型准备入口"
    case resources = "模型资源检查"
    case parallelModels = "并行准备模型（总等待）"
    // Retained as wall stages for older sequential callers and fixtures.
    case tokenizer = "加载分词器"
    case imageModel = "加载图像模型"
    case textModel = "加载文本模型"
    case modelAssembly = "汇总模型并发布"
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

enum LaunchTimingComponentOutcome: String, Sendable {
    case completed = "完成"
    case failed = "失败"
    case interrupted = "中断"
}

/// Overlapping elapsed time, not CPU time and never part of the wall-row sum.
/// Offsets are relative to the beginning of the whole launch attempt.
struct LaunchTimingComponent: Identifiable, Sendable {
    let id: UUID
    let stage: LaunchTimingStage
    let startOffsetSeconds: Double
    let seconds: Double
    let outcome: LaunchTimingComponentOutcome
}

struct LaunchTimingReport: Identifiable, Sendable {
    let id: UUID
    let kind: LaunchTimingKind
    let outcome: LaunchTimingOutcome
    let totalSeconds: Double
    let rows: [LaunchTimingRow]
    let components: [LaunchTimingComponent]

    init(id: UUID, kind: LaunchTimingKind, outcome: LaunchTimingOutcome,
         totalSeconds: Double, rows: [LaunchTimingRow], components: [LaunchTimingComponent] = []) {
        self.id = id
        self.kind = kind
        self.outcome = outcome
        self.totalSeconds = totalSeconds
        self.rows = rows
        self.components = components
    }

    // Only mutually exclusive wall rows may identify the slowest parent stage.
    var slowest: LaunchTimingRow? { rows.max { $0.seconds < $1.seconds } }

    static func duration(_ seconds: Double) -> String {
        String(format: "%.3f 秒", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }
}

/// One attempt, with a monotonic clock. The lock is never held across await.
/// Marks partition wall time rather than adding overlapping parent/child spans.
/// A cancelled attempt freezes immediately; late shared-model callbacks are ignored.
final class LaunchTimingRecorder: @unchecked Sendable {
    /// Independent completed-step events; timing boundaries never imply success.
    let startupProgress: StartupProgressRecorder?
    private struct ActiveComponent {
        let id: UUID
        let stage: LaunchTimingStage
        let startOffsetSeconds: Double
    }

    private static let componentStages: [LaunchTimingStage] = [.tokenizer, .imageModel, .textModel]
    let id = UUID()
    let kind: LaunchTimingKind
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private let began: Double
    private var last: Double
    private var stage: LaunchTimingStage = .entry
    private var rows: [LaunchTimingRow] = []
    private var componentIDs: [UUID] = []
    private var activeComponents: [UUID: ActiveComponent] = [:]
    private var completedComponents: [UUID: LaunchTimingComponent] = [:]
    private var finished = false

    init(kind: LaunchTimingKind, now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         startupProgress: StartupProgressRecorder? = nil) {
        self.kind = kind
        self.now = now
        self.startupProgress = startupProgress
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

    /// The parent marks .parallelModels before spawning children, then marks
    /// .modelAssembly after the group returns/drains, including its error path.
    /// Children begin/end at their actual execution boundaries, not at enqueue.
    /// Neither operation changes the parent's stage or its last wall boundary.
    func beginComponent(_ stage: LaunchTimingStage) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, Self.componentStages.contains(stage) else { return nil }
        let id = UUID()
        let component = ActiveComponent(id: id, stage: stage,
                                        startOffsetSeconds: max(last, now()) - began)
        componentIDs.append(id)
        activeComponents[id] = component
        return id
    }

    func endComponent(_ id: UUID?, outcome: LaunchTimingComponentOutcome) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let id, let component = activeComponents.removeValue(forKey: id) else { return }
        completeComponent(component, at: max(last, now()), outcome: outcome)
    }

    /// Returns a report only once, so overlapping completion/cancellation paths
    /// cannot append duplicates or overwrite the completed attempt.
    func finish(_ outcome: LaunchTimingOutcome) -> LaunchTimingReport? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return nil }
        let instant = max(last, now())
        closeStage(at: instant)
        for component in activeComponents.values {
            completeComponent(component, at: instant, outcome: .interrupted)
        }
        activeComponents.removeAll()
        finished = true
        let totalSeconds = instant - began
        return LaunchTimingReport(id: id, kind: kind, outcome: outcome,
                                  totalSeconds: totalSeconds, rows: rows,
                                  components: frozenComponents(totalSeconds: totalSeconds))
    }

    // Private helpers are called only with the recorder lock held.
    private func completeComponent(_ component: ActiveComponent, at instant: Double,
                                   outcome: LaunchTimingComponentOutcome) {
        completedComponents[component.id] = LaunchTimingComponent(
            id: component.id, stage: component.stage, startOffsetSeconds: component.startOffsetSeconds,
            seconds: max(0, instant - began - component.startOffsetSeconds), outcome: outcome)
    }

    private func frozenComponents(totalSeconds: Double) -> [LaunchTimingComponent] {
        // Fixed branch order, then begin order for repeat occurrences of a branch.
        // A regressing injected clock must not extend the parent's attempt to
        // accommodate a child timestamp. Clamp every span to the frozen attempt.
        Self.componentStages.flatMap { stage in
            componentIDs.compactMap { id -> LaunchTimingComponent? in
                guard let component = completedComponents[id], component.stage == stage else { return nil }
                let offset = min(totalSeconds, max(0, component.startOffsetSeconds))
                return LaunchTimingComponent(
                    id: component.id, stage: component.stage, startOffsetSeconds: offset,
                    seconds: min(max(0, component.seconds), totalSeconds - offset), outcome: component.outcome)
            }
        }
    }

    private func closeStage(at instant: Double) {
        rows.append(LaunchTimingRow(id: rows.count, stage: stage, seconds: instant - last))
        last = instant
    }
}