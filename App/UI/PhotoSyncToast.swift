import SwiftUI

/// Observes only the automatic worker. AppState/foreground search publications
/// are neither the clock nor the visibility source for this card.
@MainActor
struct PhotoSyncToast: View {
    @ObservedObject var state: PhotoSyncState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var isPresented = true

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

    // Only an actual known, nonempty processing total has a ratio bar. Checking,
    // cancellation, partial/failure and completion never get a decorative fill.
    var fraction: Double? {
        guard state.phase == .updating, let total = state.progress.total, total > 0 else { return nil }
        return state.progress.fraction
    }

    var body: some View {
        if isPresented && state.visible {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        let heading = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
                        heading {
                            Text(title).font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("photo-sync-title")
                            if state.phase == .updating, let total = state.progress.total {
                                Text("\(state.progress.completed) / \(total)")
                                    .font(.caption).monospacedDigit()
                                    .accessibilityIdentifier("photo-sync-count")
                            }
                        }
                        Text(detail).font(.caption).foregroundStyle(IQStyle.secondary)
                            .accessibilityIdentifier("photo-sync-detail")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .syncFrame(.text)
                    action
                }
                if let fraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(IQStyle.line)
                            Capsule().fill(IQStyle.accent).frame(width: geometry.size.width * fraction)
                                .syncFrame(.fill)
                        }
                    }
                    .frame(height: 3)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("照片同步进度")
                    .accessibilityValue("\(state.progress.completed) / \(state.progress.total ?? 0)")
                    .accessibilityIdentifier("photo-sync-progress")
                    .syncFrame(.progress)
                }
            }
            .padding(12)
            .foregroundStyle(IQStyle.text).tint(IQStyle.accent)
            .background(IQStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(IQStyle.line, lineWidth: 1))
            .syncFrame(.card)
            .padding(.horizontal, 19).padding(.bottom, 11)
        }
    }

    @ViewBuilder private var action: some View {
        switch state.phase {
        case .checking, .updating, .cancelling:
            Button { state.cancel() } label: {
                Text("取消").font(.caption.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .disabled(!state.canCancel)
                .accessibilityIdentifier("cancel-photo-sync")
                .syncFrame(.action)
        case .cancelled, .failed, .needsAttention:
            Button { state.restart() } label: {
                Text("重新同步").font(.caption.weight(.medium))
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .disabled(!state.canRestart)
                .accessibilityIdentifier("restart-photo-sync")
                .syncFrame(.action)
        case .idle, .completed:
            EmptyView()
        }
    }
}

enum PhotoSyncFramePart: Hashable { case card, text, action, progress, fill, selectionToolbar }
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