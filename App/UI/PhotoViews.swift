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

    private struct Request: Hashable {
        let id: String
        let revision: Double
        let networkAllowed: Bool
    }

    @State private var resolvedRequest: Request?
    @State private var image: UIImage?
    @State private var issue: PhotoPreviewIssue?

    private var request: Request {
        Request(id: photo.id, revision: photo.modificationTime, networkAllowed: networkAllowed)
    }

    var body: some View {
        // The grid owns the aspect ratio. Constrain scaledToFill to the actual
        // proposal, not the image's intrinsic size or an independent square.
        GeometryReader { geometry in
            ZStack {
                Color(red: 22 / 255, green: 23 / 255, blue: 34 / 255)
                if resolvedRequest == request, let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else if resolvedRequest == request, let issue {
                    VStack(spacing: 6) {
                        Image(systemName: issue.symbol).font(.title3)
                        Text(issue.caption).font(.caption2).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(8)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.7))
                        .accessibilityLabel("Loading photo")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipped()
        .task(id: request) {
            let requested = request
            guard !Task.isCancelled else { return }
            resolvedRequest = requested
            image = nil
            issue = nil
            do {
                let loaded = try await cache.image(id: requested.id, revision: requested.revision,
                                                   networkAllowed: requested.networkAllowed)
                try Task.checkCancellation()
                guard resolvedRequest == requested else { return }
                image = loaded
            } catch {
                guard !Task.isCancelled, resolvedRequest == requested else { return }
                issue = PhotoPreviewIssue(error: error)
            }
        }
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