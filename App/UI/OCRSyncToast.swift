import SwiftUI

/// Mount this ONE region in the root footer in place of PhotoSyncToast, not in
/// addition to it. All sheet owners stay mounted while mutually exclusive
/// capsules share one reservation: preparation, then a live photo job, then OCR.
@MainActor
struct IndexSyncFooter: View {
    @ObservedObject private var state: AppState
    @ObservedObject private var photo: PhotoSyncState
    @ObservedObject private var ocr: OCRSyncState
    let isPresented: Bool
    let onPresentedSurfaceChanged: (Bool) -> Void

    init(state: AppState, isPresented: Bool = true,
         onPresentedSurfaceChanged: @escaping (Bool) -> Void = { _ in }) {
        self.state = state
        photo = state.photoSync
        ocr = state.ocrSync
        self.isPresented = isPresented
        self.onPresentedSurfaceChanged = onPresentedSurfaceChanged
    }

    var showsOCR: Bool {
        !showsPreparation && ocr.canShow && photo.phase != .checking && photo.phase != .updating && photo.phase != .cancelling
    }
    var showsPreparation: Bool { state.activity == .starting || state.launchPhase == .failed }

    var body: some View {
        ZStack {
            LaunchPreparationNotice(state: state, isPresented: isPresented && showsPreparation,
                                    onPresentedSurfaceChanged: onPresentedSurfaceChanged)
            PhotoSyncToast(state: photo, isPresented: isPresented && !showsOCR && !showsPreparation,
                           onPresentedSurfaceChanged: onPresentedSurfaceChanged)
            OCRSyncToast(state: ocr, isPresented: isPresented && showsOCR,
                         cancel: state.cancelOCRSync, retry: state.retryOCRSync,
                         onPresentedSurfaceChanged: onPresentedSurfaceChanged)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
struct OCRSyncToast: View {
    @ObservedObject var state: OCRSyncState
    let isPresented: Bool
    let cancel: () -> Void
    let retry: () -> Void
    let onPresentedSurfaceChanged: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var labelSize: CGFloat = 14
    @State private var detailsPresented = false

    init(state: OCRSyncState, isPresented: Bool = true,
         cancel: @escaping () -> Void, retry: @escaping () -> Void,
         onPresentedSurfaceChanged: @escaping (Bool) -> Void = { _ in }) {
        self.state = state
        self.isPresented = isPresented
        self.cancel = cancel
        self.retry = retry
        self.onPresentedSurfaceChanged = onPresentedSurfaceChanged
    }

    var compactTitle: String {
        if state.phase == .updating, state.totalKnown {
            return "更新文字索引\(state.progress.completed)/\(state.progress.total)"
        }
        return title
    }

    var title: String {
        switch state.phase {
        case .idle: return "当前没有文字索引更新"
        case .waiting: return state.lifecyclePaused ? "文字索引已保存，等待继续" : "文字索引等待更新"
        case .checking: return state.isResuming ? "正在检查已保存的文字索引" : "正在检查文字索引"
        case .updating: return "正在更新文字索引"
        case .cancelling: return state.lifecyclePaused ? "正在保存文字索引进度" : "正在取消文字更新"
        case .cancelled: return "文字更新已取消"
        case .completed: return "文字索引已更新"
        case .failed: return state.completionTitle
        }
    }

    var detail: String {
        switch state.phase {
        case .idle: return "开启文字搜索不会在每次打开页面或启动应用时重复更新。"
        case .waiting:
            return state.lifecyclePaused
                ? "已完成记录保留；回到应用并确认照片权限后继续，不会重新识别有效记录。"
                : "等待当前任务结束，并在前台、照片权限和图片索引就绪后更新一次；不会自动请求权限。"
        case .checking: return "正在检查已有文字记录，仅更新缺失或需要更新的项目，不重新计算图片索引。"
        case .updating:
            return "已新识别 \(state.progress.recognized) 张 · 已复用 \(state.progress.reused) 张。检查进度包含未完成项，不等于新增数量。"
        case .cancelling: return "正在等待当前识别和存储停止，已经成功提交的记录会保留。"
        case .cancelled: return "已完成记录保留，不会自动重试。开启文字搜索后可手动重试。"
        case .completed: return "本次增量检查已完成。降低分辨率的记录可在以后显式更新时再尝试。"
        case .failed: return state.completionDetail + "提示会自动收起，详情仍可在图库查看；不会自动重试，也不会改变 iCloud 设置。"
        }
    }

    private var hasStopAction: Bool {
        state.pending || state.currentRunning
    }

    var body: some View {
        let metrics = PhotoSyncCapsuleMetrics(fontSize: labelSize,
                                             accessibility: dynamicTypeSize.isAccessibilitySize)
        let shown = isPresented && state.canShow && !detailsPresented
        IndexSyncReservationLayout(metrics: metrics) {
            ZStack {
                if shown {
                    capsule
                        .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 4)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion || !isPresented || detailsPresented ? nil : .easeOut(duration: 0.18), value: shown)
            .allowsHitTesting(shown).accessibilityHidden(!shown)
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $detailsPresented, onDismiss: { onPresentedSurfaceChanged(false) }) {
            detailSheet
        }
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            Button {
                guard isPresented, state.canShow, !detailsPresented else { return }
                onPresentedSurfaceChanged(true)
                detailsPresented = true
            } label: {
                HStack(spacing: dynamicTypeSize.isAccessibilitySize ? 4 : 8) {
                    indicator
                    Text(compactTitle).font(.system(size: labelSize, weight: .medium))
                        .monospacedDigit().lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("ocr-sync-title")
                        .transaction { $0.animation = nil }
                }
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 8 : 12)
                .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 4 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(compactTitle)
            .accessibilityHint("查看文字索引更新详情")
            .accessibilityIdentifier("ocr-sync-open-details")
            Button {
                if hasStopAction { cancel() }
                else { state.dismiss() }
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .medium))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(hasStopAction && !state.canCancel)
            .accessibilityLabel(hasStopAction ? "取消文字索引更新" : "关闭文字更新提示")
            .accessibilityIdentifier(hasStopAction ? "cancel-ocr-sync" : "dismiss-ocr-sync")
        }
        .foregroundStyle(IQStyle.text).tint(IQStyle.accent)
        .background(IQStyle.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(IQStyle.line, lineWidth: 1))
    }

    @ViewBuilder private var indicator: some View {
        if let fraction = state.fraction {
            // Same primitive appearance as photo sync, but no PhotoSyncFrames
            // preference: OCR geometry must not masquerade as photo progress.
            IndexSyncProgressRing(fraction: fraction)
            .accessibilityElement(children: .ignore).accessibilityLabel("文字索引进度")
            .accessibilityValue("\(state.progress.completed) / \(state.progress.total)")
            .accessibilityIdentifier("ocr-sync-progress")
        } else {
            Image(systemName: statusSymbol).font(.system(size: 14))
                .foregroundStyle(IQStyle.accent).frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
    }

    private var statusSymbol: String {
        switch state.phase {
        case .idle, .waiting, .checking, .updating: return "text.viewfinder"
        case .cancelling, .cancelled: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(title).font(.headline)
                    Text(detail).foregroundStyle(IQStyle.secondary)
                        .accessibilityIdentifier("ocr-sync-detail")
                    if state.totalKnown {
                        Text(state.progress.summary).monospacedDigit()
                            .accessibilityIdentifier("ocr-sync-counts")
                    } else {
                        Text("总数尚未确定").foregroundStyle(IQStyle.secondary)
                    }
                    Text("识别在本机完成。是否允许读取 iCloud 照片仍使用原设置。取消或关闭功能不会删除已完成的文字记录，也不会删除系统照片。")
                        .font(.footnote).foregroundStyle(IQStyle.secondary)
                    if hasStopAction {
                        Button("取消文字索引更新", action: cancel)
                            .disabled(!state.canCancel).frame(minHeight: 44)
                            .accessibilityIdentifier("cancel-ocr-sync-details")
                    } else if state.phase != .idle {
                        Button("重新更新文字索引", action: retry)
                            .disabled(!state.canRetry).frame(minHeight: 44)
                            .accessibilityIdentifier("retry-ocr-sync")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(IQStyle.background).foregroundStyle(IQStyle.text)
            .navigationTitle("文字索引更新").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { detailsPresented = false }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("dismiss-ocr-sync-details")
                }
            }
        }
        .tint(IQStyle.accent)
    }
}

struct IndexSyncProgressRing: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().stroke(IQStyle.line, lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(IQStyle.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: fraction)
        }
        .padding(1).frame(width: 14, height: 14)
    }
}

struct IndexSyncReservationLayout: Layout {
    let metrics: PhotoSyncCapsuleMetrics
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 256, height: metrics.reservationHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.minY + 4), anchor: .top,
                          proposal: ProposedViewSize(width: metrics.cardWidth(available: bounds.width), height: metrics.cardHeight))
        }
    }
}