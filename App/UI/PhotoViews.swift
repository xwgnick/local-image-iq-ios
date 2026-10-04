import SwiftUI
import Photos
import PhotosUI
import UIKit
import ImageIQCore

@MainActor
struct PhotoThumbnailView: View {
    let photo: IndexedPhoto
    let cache: PhotoThumbnailCache
    let networkAllowed: Bool
    var showDiagnostics = false
    @Environment(\.displayScale) private var displayScale

    private struct Request: Hashable {
        let id: String
        let revision: Double
        let networkAllowed: Bool
        let pixelWidth: CGFloat
        let pixelHeight: CGFloat

        var targetSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    }

    @State private var resolvedRequest: Request?
    @State private var image: UIImage?
    @State private var issue: PhotoPreviewIssue?
    @State private var diagnostic: CachedThumbnail?

    var body: some View {
        // The grid owns the aspect ratio. Constrain scaledToFill to the actual
        // proposal, not the image's intrinsic size or an independent square.
        GeometryReader { geometry in
            let requested = DisplayThumbnailLoader.targetSize(points: geometry.size, displayScale: displayScale).map {
                Request(id: photo.id, revision: photo.modificationTime, networkAllowed: networkAllowed,
                        pixelWidth: $0.width, pixelHeight: $0.height)
            }
            ZStack {
                IQStyle.muted
                if resolvedRequest == requested, let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if resolvedRequest == requested, let issue {
                    VStack(spacing: 6) {
                        Image(systemName: issue.symbol).font(.title3)
                        Text(issue.localizedCaption).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(IQStyle.secondary)
                    .padding(8)
                } else {
                    ProgressView()
                        .tint(IQStyle.secondary)
                        .accessibilityLabel("正在加载照片")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if showDiagnostics, resolvedRequest == requested, let diagnostic {
                    ThumbnailDiagnosticOverlay(thumbnail: diagnostic)
                }
            }
            .task(id: requested) {
                guard !Task.isCancelled else { return }
                image = nil
                issue = nil
                diagnostic = nil
                resolvedRequest = requested
                // A zero/invalid initial layout remains a placeholder, not a
                // default-size request that could later mask the real tile.
                guard let requested else { return }
                do {
                    let loaded = try await cache.thumbnail(id: requested.id, revision: requested.revision,
                                                       targetSize: requested.targetSize,
                                                       networkAllowed: requested.networkAllowed)
                    try Task.checkCancellation()
                    guard resolvedRequest == requested else { return }
                    image = loaded.result.image
                    diagnostic = loaded
                } catch {
                    guard !Task.isCancelled, !(error is CancellationError), resolvedRequest == requested else { return }
                    issue = PhotoPreviewIssue(error: error)
                }
            }
        }
        .clipped()
    }
}

/// Retained for callers that still present a single photo. New result screens
/// pass the complete, ordered hits to PhotoResultsViewer instead.
@MainActor
struct PhotoPreviewView: View {
    let id: String
    let library: PhotoLibraryClient
    let networkAllowed: Bool

    var body: some View {
        PhotoGalleryViewer(ids: [id], initialID: id, library: library, networkAllowed: networkAllowed)
    }
}

/// Display-only messages: do not expose PhotoKit errors or change download policy.
enum PhotoPreviewIssue {
    case cloud, access, unavailable

    init(error: Error) {
        if let failure = error as? AppFailure {
            switch failure {
            case .cloudOnly: self = .cloud; return
            case .permission: self = .access; return
            default: break
            }
        }
        self = PhotoImageRequestInfo.requiresNetwork(error) ? .cloud : .unavailable
    }

    var symbol: String {
        switch self {
        case .cloud: return "icloud"
        case .access: return "lock"
        case .unavailable: return "photo.badge.exclamationmark"
        }
    }

    var caption: String {
        switch self {
        case .cloud: return "In iCloud"
        case .access: return "No access"
        case .unavailable: return "Unavailable"
        }
    }

    var title: String {
        switch self {
        case .cloud: return "This photo is in iCloud"
        case .access: return "Photo access changed"
        case .unavailable: return "Preview unavailable"
        }
    }

    func message(networkAllowed: Bool) -> String {
        switch self {
        case .cloud:
            return networkAllowed
                ? "The photo couldn't be downloaded. Check your connection and try again."
                : "A preview isn't stored on this device. Enable iCloud access in Library to load this photo, then try again."
        case .access:
            return "This photo may have been deleted or removed from your selection. Check Photos access and try again."
        case .unavailable:
            return networkAllowed
                ? "This photo couldn't be loaded. Check your connection and try again."
                : "A local preview isn't available right now. Try again, or enable iCloud access in Library."
        }
    }

    // Localize only at view boundaries. Keep the existing English properties
    // and error classification unchanged for diagnostic/test compatibility.
    var localizedCaption: String {
        switch self {
        case .cloud: return "位于 iCloud"
        case .access: return "无访问权限"
        case .unavailable: return "暂不可用"
        }
    }

    var localizedTitle: String {
        switch self {
        case .cloud: return "这张照片位于 iCloud"
        case .access: return "照片访问权限已更改"
        case .unavailable: return "无法预览照片"
        }
    }

    func localizedMessage(networkAllowed: Bool) -> String {
        switch self {
        case .cloud:
            return networkAllowed
                ? "未能下载这张照片，请检查网络连接后重试。"
                : "此设备上没有这张照片的预览。请在“我的图库”中开启 iCloud 访问后重试。"
        case .access:
            return "这张照片可能已被删除，或已移出允许访问的范围。请检查照片访问权限后重试。"
        case .unavailable:
            return networkAllowed
                ? "未能加载这张照片，请检查网络连接后重试。"
                : "暂时无法获取本地预览。请重试，或在“我的图库”中开启 iCloud 访问。"
        }
    }
}

/// Shares the rendered UIImage, not the original asset/file or its GPS metadata.
/// Saving into Photos is excluded: this app requests read access only.
@MainActor
struct PhotoShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    /// A fresh pixel-only image drops any source metadata and normalizes orientation.
    /// Called only for an explicit Share action, not while paging or loading.
    static func renderedCopy(of image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        controller.excludedActivityTypes = [.saveToCameraRoll]
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

struct LimitedLibraryPicker: UIViewControllerRepresentable {
    let onFinish: @MainActor () -> Void

    func makeUIViewController(context: Context) -> PickerHost {
        let controller = PickerHost()
        controller.onFinish = onFinish
        return controller
    }
    func updateUIViewController(_ controller: PickerHost, context: Context) { }

    final class PickerHost: UIViewController {
        var onFinish: (@MainActor () -> Void)?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            guard PhotoLibraryClient.authorization == .limited else { onFinish?(); return }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onFinish?() }
            }
        }
    }
}