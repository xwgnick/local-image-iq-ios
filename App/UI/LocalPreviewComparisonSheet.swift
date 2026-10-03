import ImageIO
import SwiftUI
import UIKit

@MainActor
struct LocalPreviewComparisonSheet: View {
    @StateObject private var state: LocalPreviewComparisonState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hasAppeared = false
    @State private var displayMode: LocalPreviewComparisonDisplayMode = .square
    @State private var cropCenter = CGPoint(x: 0.5, y: 0.5)
    @State private var magnification = 2.0

    /// Injectable for native presentation tests; the sheet owns this instance's lifecycle.
    init(state: LocalPreviewComparisonState) {
        _state = StateObject(wrappedValue: state)
    }

    init(library: PhotoLibraryClient, photoID: String) {
        _state = StateObject(wrappedValue: LocalPreviewComparisonState(service: library, photoID: photoID))
    }

    private var normalizedCrop: CGRect {
        let edge = CGFloat(1 / magnification)
        let half = edge / 2
        let x = min(max(cropCenter.x, half), 1 - half)
        let y = min(max(cropCenter.y, half), 1 - half)
        return CGRect(x: x - half, y: y - half, width: edge, height: edge)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("全部请求：网络访问关闭", systemImage: "wifi.slash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(IQStyle.accent)
                        Text("打开即对比三种本地预览，可直接截图。验证离线时，请先开飞行模式并关闭 Wi-Fi；本页不检测飞行模式。")
                            .font(.caption)
                            .foregroundStyle(IQStyle.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    runControls

                    if let message = state.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(IQStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("local-previews-error")
                    }

                    if let result = state.result {
                        displayControls
                        LocalPreviewComparisonImages(entries: result.entries, displayMode: displayMode,
                                                     normalizedCrop: normalizedCrop)
                        if displayMode == .detail, let preview = referencePreview(result.entries) {
                            detailControls(preview)
                        }
                        if hasDifferentAspectRatios(result.entries) {
                            Text("返回画面的比例有差异：选区按各图相同比例的位置对应，不保证内容完全对齐。")
                                .font(.caption)
                                .foregroundStyle(IQStyle.secondary)
                                .accessibilityIdentifier("local-previews-aspect-warning")
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("尺寸更大不一定细节更多；本次请求可能复用系统缓存。")
                        Text("依次请求 Fast 224、高质量 224、高质量 480；前一次请求可能影响后一次的缓存。")
                        Text("返回像素是方向校正前的 CG 图像尺寸。降质标记为系统原始值，“否”不保证清晰。")
                        Text("高质量请求不保证更清晰。选区放大仅用于观察，不会增加真实细节。")
                        Text("只在内存中对比，不改索引、不保存或导出图片；离开页面即清空。")
                    }
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(IQStyle.background)
            .navigationTitle("本地预览对比")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(IQStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        clear()
                        dismiss()
                    }
                    .accessibilityLabel("关闭本地预览对比")
                    .accessibilityIdentifier("close-local-previews")
                }
            }
        }
        .tint(IQStyle.accent)
        .preferredColorScheme(.dark)
        .task {
            guard !hasAppeared else { return }
            hasAppeared = true
            guard scenePhase == .active else { clear(); return }
            // Preserve a preloaded injected state for native screenshots/tests.
            if state.result == nil, state.errorMessage == nil, !state.isRunning {
                state.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clear() }
            // Returning to the app never restarts or resurrects old previews.
        }
        .onDisappear { clear() }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.isRunning {
                ProgressView("正在依次读取三种本地预览…")
                    .font(.subheadline)
                    .tint(IQStyle.accent)
                    .accessibilityIdentifier("local-previews-running")
                Button("取消") { clear() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("cancel-local-previews")
            } else {
                Button {
                    hasAppeared = true
                    state.start()
                } label: {
                    Text(hasAppeared || state.result != nil ? "重新对比" : "开始对比")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(IQStyle.onAccent)
                .disabled(scenePhase != .active)
                .accessibilityIdentifier("run-local-previews")
            }
        }
    }

    private var displayControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                modePicker.pickerStyle(.menu)
            } else {
                modePicker.pickerStyle(.segmented)
            }
        }
        .accessibilityIdentifier("local-previews-display-mode")
    }

    private var modePicker: some View {
        Picker("显示方式", selection: $displayMode) {
            ForEach(LocalPreviewComparisonDisplayMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
    }

    private func detailControls(_ preview: IndexingImage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("轻点参考图选择区域，三张预览同步移动。")
                .font(.subheadline)
            Text("参考图取返回像素最多的一张，不代表它一定最清晰。白框是当前选区。")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            LocalPreviewComparisonReference(preview: preview, normalizedCrop: normalizedCrop,
                                            center: $cropCenter)
                .frame(height: 180)
            Slider(value: $magnification, in: 1...4) {
                Text("细节放大（仅显示）")
            }
            .accessibilityValue("\(magnification.formatted(.number.precision(.fractionLength(1)))) 倍，仅显示放大")
            .accessibilityIdentifier("local-previews-magnification")
            Text("显示放大 \(magnification.formatted(.number.precision(.fractionLength(1))))× · 不增加像素细节")
                .font(.caption)
                .foregroundStyle(IQStyle.secondary)
            Button("回到中央选区") {
                cropCenter = CGPoint(x: 0.5, y: 0.5)
                magnification = 2
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("local-previews-reset-region")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func referencePreview(_ entries: [LocalPreviewEntry]) -> IndexingImage? {
        entries.compactMap(\.preview).max {
            Double($0.cgImage.width) * Double($0.cgImage.height)
                < Double($1.cgImage.width) * Double($1.cgImage.height)
        }
    }

    private func hasDifferentAspectRatios(_ entries: [LocalPreviewEntry]) -> Bool {
        let sizes = entries.compactMap(\.preview).map(LocalPreviewComparisonPixels.uprightSize)
        guard let first = sizes.first else { return false }
        return sizes.dropFirst().contains { $0.width * first.height != first.width * $0.height }
    }

    private func clear() {
        hasAppeared = true
        state.cancelAndClear()
        cropCenter = CGPoint(x: 0.5, y: 0.5)
        magnification = 2
    }
}

enum LocalPreviewComparisonDisplayMode: String, CaseIterable, Identifiable {
    case square = "等框对比"
    case full = "完整画面"
    case detail = "同一区域细节"
    var id: String { rawValue }
}

/// Also usable directly by native screenshot tests without starting PhotoKit work.
@MainActor
struct LocalPreviewComparisonImages: View {
    let entries: [LocalPreviewEntry]
    let displayMode: LocalPreviewComparisonDisplayMode
    let normalizedCrop: CGRect
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(entries: [LocalPreviewEntry], displayMode: LocalPreviewComparisonDisplayMode = .square,
         normalizedCrop: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) {
        self.entries = entries
        self.displayMode = displayMode
        self.normalizedCrop = normalizedCrop
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 20) { panels }
            } else {
                HStack(alignment: .top, spacing: 8) { panels }
            }
        }
        .accessibilityIdentifier("local-previews-comparison")
    }

    private var panels: some View {
        ForEach(LocalPreviewMode.allCases) { mode in
            panel(mode: mode, entry: entries.first { $0.mode == mode })
        }
    }

    private func panel(mode: LocalPreviewMode, entry: LocalPreviewEntry?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The square base constrains the overlay, never the UIImage's intrinsic size.
            Color.black.aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let preview = entry?.preview {
                        LocalPreviewComparisonImage(preview: preview, displayMode: displayMode,
                                                    normalizedCrop: normalizedCrop)
                    } else {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(IQStyle.secondary)
                            .accessibilityLabel("本地预览不可用")
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("local-preview-image-\(mode.rawValue)")
            Text(mode.title)
                .font(.caption.weight(.bold))
                .foregroundStyle(IQStyle.accent)
                .accessibilityAddTraits(.isHeader)
            metadata("请求像素", entry.map { LocalPreviewComparisonPixels.dimensions($0.requestedSize) } ?? "未返回")
            if let preview = entry?.preview {
                metadata("返回 CG 像素", "\(preview.cgImage.width) × \(preview.cgImage.height)")
                metadata("方向", LocalPreviewComparisonPixels.orientationText(preview.orientation))
                metadata("降质标记", preview.photokitDegraded.map { $0 ? "是" : "否" } ?? "未知")
                metadata("来源", LocalPreviewComparisonPixels.sourceText(preview.source))
            } else {
                metadata("返回 CG 像素", "无预览")
                metadata("方向 / 降质标记", "未知")
                metadata("来源", "未取得本地预览")
            }
            if entry?.issue != nil || entry?.preview == nil {
                // Do not render free-form service text, even after ID redaction:
                // it could also include another ID, a path, filename or GPS values.
                Text(entry?.preview == nil ? "本地预览不可用，可重试。" : "已返回预览，但请求未完整完成。")
                    .font(.caption)
                    .foregroundStyle(IQStyle.secondary)
                    .accessibilityIdentifier("local-preview-issue-\(mode.rawValue)")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("local-preview-panel-\(mode.rawValue)")
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(IQStyle.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct LocalPreviewComparisonImage: View {
    let preview: IndexingImage
    let displayMode: LocalPreviewComparisonDisplayMode
    let normalizedCrop: CGRect

    var body: some View {
        GeometryReader { geometry in
            let image = Image(uiImage: LocalPreviewComparisonPixels.uiImage(preview)).resizable()
            let fitted = LocalPreviewComparisonPixels.fittedRect(preview, in: geometry.size)
            Group {
                switch displayMode {
                case .square:
                    image.scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                case .full:
                    image.scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                case .detail:
                    // Crop in UPRIGHT normalized coordinates. Clip to the fitted
                    // image rectangle (not the square), so portrait/landscape
                    // letterboxing cannot change the selected field of view.
                    image.scaledToFit()
                        .frame(width: fitted.width / normalizedCrop.width,
                               height: fitted.height / normalizedCrop.height)
                        .offset(x: -normalizedCrop.minX * fitted.width / normalizedCrop.width,
                                y: -normalizedCrop.minY * fitted.height / normalizedCrop.height)
                        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                        .clipped()
                        .position(x: fitted.midX, y: fitted.midY)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(displayMode.rawValue)，本次返回的预览")
    }
}

@MainActor
private struct LocalPreviewComparisonReference: View {
    let preview: IndexingImage
    let normalizedCrop: CGRect
    @Binding var center: CGPoint

    var body: some View {
        GeometryReader { geometry in
            let fitted = LocalPreviewComparisonPixels.fittedRect(preview, in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: LocalPreviewComparisonPixels.uiImage(preview))
                    .resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                Rectangle().strokeBorder(.white, lineWidth: 2)
                    .background(.black.opacity(0.08))
                    .frame(width: fitted.width * normalizedCrop.width,
                           height: fitted.height * normalizedCrop.height)
                    .position(x: fitted.minX + fitted.width * normalizedCrop.midX,
                              y: fitted.minY + fitted.height * normalizedCrop.midY)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { event in
                // Letterbox taps do nothing; never treat the black bars as image pixels.
                guard fitted.width > 0, fitted.height > 0, fitted.contains(event.location) else { return }
                center = CGPoint(x: (event.location.x - fitted.minX) / fitted.width,
                                 y: (event.location.y - fitted.minY) / fitted.height)
            })
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("细节区域参考图")
        .accessibilityHint("轻点画面选择区域，或使用上下左右移动操作。")
        .accessibilityAction(named: Text("向左移动")) { move(x: -0.1, y: 0) }
        .accessibilityAction(named: Text("向右移动")) { move(x: 0.1, y: 0) }
        .accessibilityAction(named: Text("向上移动")) { move(x: 0, y: -0.1) }
        .accessibilityAction(named: Text("向下移动")) { move(x: 0, y: 0.1) }
        .accessibilityIdentifier("local-previews-reference")
    }

    private func move(x: CGFloat, y: CGFloat) {
        let halfWidth = normalizedCrop.width / 2
        let halfHeight = normalizedCrop.height / 2
        center = CGPoint(x: min(max(normalizedCrop.midX + x, halfWidth), 1 - halfWidth),
                         y: min(max(normalizedCrop.midY + y, halfHeight), 1 - halfHeight))
    }
}

/// UIImage carries orientation without redrawing, cropping or resampling the CGImage.
/// Display transforms never replace the pixels used for the metadata above.
private enum LocalPreviewComparisonPixels {
    static func uiImage(_ preview: IndexingImage) -> UIImage {
        let orientation: UIImage.Orientation
        switch preview.orientation {
        case .up: orientation = .up
        case .upMirrored: orientation = .upMirrored
        case .down: orientation = .down
        case .downMirrored: orientation = .downMirrored
        case .left: orientation = .left
        case .leftMirrored: orientation = .leftMirrored
        case .right: orientation = .right
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: orientation = .up
        }
        return UIImage(cgImage: preview.cgImage, scale: 1, orientation: orientation)
    }

    static func uprightSize(_ preview: IndexingImage) -> CGSize {
        let raw = CGSize(width: CGFloat(preview.cgImage.width), height: CGFloat(preview.cgImage.height))
        switch preview.orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: raw.height, height: raw.width)
        default: return raw
        }
    }

    static func fittedRect(_ preview: IndexingImage, in container: CGSize) -> CGRect {
        let size = uprightSize(preview)
        let scale = min(container.width / size.width, container.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (container.width - width) / 2, y: (container.height - height) / 2,
                      width: width, height: height)
    }

    static func dimensions(_ size: CGSize) -> String {
        guard size.width.isFinite, size.height.isFinite else { return "未知" }
        return "\(Double(size.width).formatted(.number.precision(.fractionLength(0...1)))) × \(Double(size.height).formatted(.number.precision(.fractionLength(0...1))))"
    }

    static func orientationText(_ orientation: CGImagePropertyOrientation) -> String {
        switch orientation {
        case .up: return "向上 (1)"
        case .upMirrored: return "向上·镜像 (2)"
        case .down: return "向下 (3)"
        case .downMirrored: return "向下·镜像 (4)"
        case .leftMirrored: return "向左·镜像 (5)"
        case .right: return "向右 (6)"
        case .rightMirrored: return "向右·镜像 (7)"
        case .left: return "向左 (8)"
        @unknown default: return "未知"
        }
    }

    static func sourceText(_ source: IndexingImage.Source) -> String {
        switch source {
        case .localPreview: return "本地预览"
        case .localReducedPreview: return "本地较小/降质"
        case .networkPreview: return "网络预览（非本地）"
        }
    }
}