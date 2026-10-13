import SwiftUI
import UIKit

/// Observes only the automatic worker. AppState/foreground search publications
/// are neither the clock nor the visibility source for this card.
@MainActor
struct PhotoSyncToast: View {
    @ObservedObject var state: PhotoSyncState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @State private var detailsPresented = false
    let isPresented: Bool
    private let onPresentedSurfaceChanged: (Bool) -> Void

    /// Mount once in the shared root footer, including while idle/covered.
    /// The parent includes this callback's value in its modal AX gate, but must
    /// NOT unmount this view: isPresented hides the capsule, not its sheet/job.
    init(state: PhotoSyncState, isPresented: Bool = true,
         onPresentedSurfaceChanged: @escaping (Bool) -> Void = { _ in }) {
        self.state = state
        self.isPresented = isPresented
        self.onPresentedSurfaceChanged = onPresentedSurfaceChanged
    }

    var compactTitle: String {
        if state.phase == .updating {
            if let total = state.progress.total {
                return "同步最新照片\(state.progress.completed)/\(total)"
            }
            return "同步最新照片"
        }
        return title
    }

    var title: String {
        switch state.phase {
        case .idle: return ""
        case .checking: return "正在检查照片"
        case .updating: return "正在同步照片"
        case .cancelling: return "正在取消…"
        case .cancelled: return "同步已取消"
        case .completed: return "照片已同步"
        case .needsAttention: return state.progress.needsNetwork > 0 ? "部分照片需要联网" : "照片同步待处理"
        case .failed: return "照片同步未完成"
        }
    }

    var detail: String {
        switch state.phase {
        case .idle: return ""
        case .checking: return "检查新增及已变化的照片"
        case .updating: return "新照片处理中 · 已移除\(state.progress.removed)条失效索引"
        case .cancelling: return "正在等待本次处理停止，已完成的索引会保留"
        case .cancelled: return "已完成的索引已保留，不会立即自动重启"
        case .completed: return "新增\(state.progress.encoded)张可搜索 · 移除\(state.progress.removed)条失效索引"
        case .needsAttention:
            var parts = ["已完成\(state.progress.encoded)张"]
            if state.progress.needsNetwork > 0 { parts.append("\(state.progress.needsNetwork)张需联网") }
            if state.progress.failed > 0 { parts.append("\(state.progress.failed)张未完成") }
            return parts.joined(separator: " · ") + "，可手动重新同步"
        case .failed: return state.failureMessage ?? "已完成的索引保留。"
        }
    }

    // Only an actual known, nonempty processing total has a ratio ring. Checking,
    // cancellation, partial/failure and completion never get a decorative fill.
    var fraction: Double? {
        guard state.phase == .updating, let total = state.progress.total, total > 0 else { return nil }
        return state.progress.fraction
    }

    private var showsCancelAction: Bool {
        state.phase == .checking || state.phase == .updating || state.phase == .cancelling
    }

    var body: some View {
        let metrics = PhotoSyncCapsuleMetrics(fontSize: labelSize,
                                               accessibility: dynamicTypeSize.isAccessibilitySize)
        let showsCapsule = isPresented && state.visible && !detailsPresented
        let showsAction = showsCapsule && showsCancelAction
        let showsProgress = showsCapsule && fraction != nil
        PhotoSyncReservationLayout(metrics: metrics) {
            ZStack {
                if showsCapsule {
                    capsule
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion || !isPresented || detailsPresented ? nil : .easeOut(duration: 0.18),
                       value: showsCapsule)
            // A disappearing transition must not leave an interactive/AX card
            // beneath a modal. Only this branch is gated, never the sheet.
            .allowsHitTesting(showsCapsule)
            .accessibilityHidden(!showsCapsule)
        }
        .frame(maxWidth: .infinity)
        .toastFrame(.reservation)
        // Bound this subtree's diagnostic snapshot to its current branches.
        // An outgoing animated branch can still contribute old preferences;
        // only remove invalid entries, never invent missing geometry. The
        // shared key/reducer and the root's selection-toolbar entry stay intact.
        .transformPreference(PhotoSyncFrames.self) { frames in
            frames = frames.filter { entry in
                switch entry.key {
                case .reservation, .selectionToolbar: return true
                case .card, .text, .mainAction: return showsCapsule
                case .action: return showsAction
                case .progress, .fill: return showsProgress
                }
            }
        }
        .sheet(isPresented: $detailsPresented, onDismiss: {
            onPresentedSurfaceChanged(false)
        }) {
            PhotoSyncDetailSheet(state: state)
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            Button {
                guard isPresented && state.visible && !detailsPresented else { return }
                onPresentedSurfaceChanged(true)
                detailsPresented = true
            } label: {
                HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 4 : 8) {
                    indicator
                    Text(compactTitle)
                        .font(.system(size: labelSize, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("photo-sync-title")
                        .toastFrame(.text)
                        // Count text keeps its baseline; only the arc animates.
                        .transaction { $0.animation = nil }
                }
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 8 : 12)
                .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 4 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(compactTitle)
            .accessibilityHint("查看同步详情")
            .accessibilityIdentifier("photo-sync-open-details")
            .toastFrame(.mainAction)

            if showsCancelAction {
                Button { state.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!state.canCancel)
                .accessibilityLabel("取消同步")
                .accessibilityIdentifier("cancel-photo-sync")
                .toastFrame(.action)
            }
        }
        .foregroundStyle(IQStyle.text).tint(IQStyle.accent)
        .background(IQStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(IQStyle.line, lineWidth: 1))
        .toastFrame(.card)
    }

    @ViewBuilder private var indicator: some View {
        if let fraction {
            PhotoSyncProgressRing(fraction: fraction)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("照片同步进度")
                .accessibilityValue("\(state.progress.completed) / \(state.progress.total ?? 0)")
                .accessibilityIdentifier("photo-sync-progress")
                .toastFrame(.progress)
        } else {
            // Unknown work is not a made-up percent or a time-driven spinner.
            Image(systemName: statusSymbol).font(.system(size: 14))
                .foregroundStyle(IQStyle.accent).frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }

    private var statusSymbol: String {
        switch state.phase {
        case .idle, .checking, .updating: return "arrow.triangle.2.circlepath"
        case .cancelling, .cancelled: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .needsAttention, .failed: return "exclamationmark.circle"
        }
    }
}

/// No state/count-dependent height: idle, checking, working, completed and
/// covered presentations all reserve the same space at a given type size.
/// Two natural font lines fit at large sizes; no scaling/cropping of diagnostics.
struct PhotoSyncCapsuleMetrics {
    let fontSize: CGFloat
    let accessibility: Bool
    var cardHeight: CGFloat {
        max(44, ceil(UIFont.systemFont(ofSize: fontSize, weight: .medium).lineHeight) * 2 + 8)
    }
    var reservationHeight: CGFloat { cardHeight + 8 }
    func cardWidth(available: CGFloat) -> CGFloat {
        // Reclaim the decorative side gutter before compromising large text
        // or the independent 44pt cancel target on a narrow accessibility host.
        let insetWidth = max(0, available - (accessibility ? 8 : 32))
        return accessibility ? insetWidth : min(224, insetWidth)
    }
}

private struct PhotoSyncReservationLayout: Layout {
    let metrics: PhotoSyncCapsuleMetrics
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 256, height: metrics.reservationHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + 4), anchor: .top,
                          proposal: ProposedViewSize(width: metrics.cardWidth(available: bounds.width),
                                                     height: metrics.cardHeight))
        }
    }
}

struct PhotoSyncProgressRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(IQStyle.line, lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(IQStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: fraction)
                .toastFrame(.fill)
        }
        .padding(1) // Keep the complete 2pt stroke inside the actual 14pt view.
        .frame(width: 14, height: 14)
    }
}

/// Normal dismissal affects only presentation. Every operation below delegates
/// to the observed worker; no retry-on-appear, progress timer or guessed ETA.
@MainActor
struct PhotoSyncDetailSheet: View {
    @ObservedObject var state: PhotoSyncState
    @Environment(\.dismiss) private var dismiss
    private var presentation: PhotoSyncToast { PhotoSyncToast(state: state) }

    var summary: String {
        switch state.phase {
        case .idle: return "以下是本次已报告的处理记录。"
        case .updating: return "正在处理新增及已变化的照片，已写入的索引会保留。"
        case .completed:
            // Encoded includes changed photos too: never call every write a
            // newly added photo, or confuse processed with successful writes.
            return "本次已写入\(state.progress.encoded)张照片索引，移除\(state.progress.removed)条失效索引。"
        case .needsAttention:
            return "本次已写入\(state.progress.encoded)张照片索引，\(state.progress.needsNetwork)张需联网，\(state.progress.failed)张处理失败。可手动重新同步。"
        default: return presentation.detail
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(state.phase == .idle ? "当前没有正在运行的同步" : presentation.title)
                        .font(.headline)
                    Text(summary)
                        .font(.body).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("photo-sync-detail")
                    VStack(alignment: .leading, spacing: 12) {
                        statistic("已处理", value: state.progress.total.map {
                            "\(state.progress.completed) / \($0)"
                        } ?? "\(state.progress.completed)（总数尚未确定）")
                        statistic("本次写入索引", value: "\(state.progress.encoded)张")
                        statistic("移除失效索引", value: "\(state.progress.removed)条")
                        statistic("需联网", value: "\(state.progress.needsNetwork)张")
                        statistic("处理失败", value: "\(state.progress.failed)张")
                    }
                    Text("已处理数包含未成功的照片，不等于本次写入索引数。移除的是索引，不会删除系统照片。关闭此页不会暂停同步。")
                        .font(.footnote).foregroundStyle(IQStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    operation
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(IQStyle.background).foregroundStyle(IQStyle.text)
            .navigationTitle("照片同步").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Text("完成").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("dismiss-photo-sync-details")
                }
            }
        }
        .tint(IQStyle.accent)
    }

    private func statistic(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline).foregroundStyle(IQStyle.secondary)
            Text(value).font(.body).monospacedDigit()
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var operation: some View {
        switch state.phase {
        case .checking, .updating, .cancelling:
            Button { state.cancel() } label: {
                Text(state.phase == .cancelling ? "正在等待处理停止…" : "取消同步")
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.bordered).disabled(!state.canCancel)
            .accessibilityIdentifier("cancel-photo-sync")
        case .cancelled, .failed, .needsAttention:
            Button { state.restart() } label: {
                Text(state.phase == .cancelled ? "继续同步" : "重新同步")
                    .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent).disabled(!state.canRestart)
            .accessibilityIdentifier("restart-photo-sync")
        case .idle, .completed: EmptyView()
        }
    }
}

enum PhotoSyncFramePart: Hashable { case reservation, card, text, mainAction, action, progress, fill, selectionToolbar }

/// Passive layout evidence owned by the actual toast branch, not a registry or
/// a phase-filtered presence claim. Removal is observed by walking the current
/// native subtree. This is not an accessibility-tree or button-dispatch probe.
@MainActor
final class PhotoSyncLayoutProbeView: UIView {
    let part: PhotoSyncFramePart

    init(part: PhotoSyncFramePart) {
        self.part = part
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var windowFrame: CGRect? {
        guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
        return convert(bounds, to: window)
    }
}

private struct PhotoSyncLayoutProbe: UIViewRepresentable {
    let part: PhotoSyncFramePart
    func makeUIView(context: Context) -> PhotoSyncLayoutProbeView { PhotoSyncLayoutProbeView(part: part) }
    func updateUIView(_ uiView: PhotoSyncLayoutProbeView, context: Context) {}
}

private extension View {
    func toastFrame(_ part: PhotoSyncFramePart) -> some View {
        syncFrame(part)
            .background(PhotoSyncLayoutProbe(part: part).allowsHitTesting(false).accessibilityHidden(true))
    }
}

struct PhotoSyncFrames: PreferenceKey {
    static var defaultValue: [PhotoSyncFramePart: CGRect] { [:] }
    static func reduce(value: inout [PhotoSyncFramePart: CGRect], nextValue: () -> [PhotoSyncFramePart: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func syncFrame(_ part: PhotoSyncFramePart) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: PhotoSyncFrames.self, value: [part: geometry.frame(in: .global)])
            }
        }
    }
}