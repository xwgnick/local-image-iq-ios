import SwiftUI
import Photos
import UIKit
import ImageIQCore

@MainActor
struct PhotoThumbnailView: View {
    let photo: IndexedPhoto
    let cache: PhotoThumbnailCache
    let networkAllowed: Bool
    @State private var image: UIImage?
    @State private var unavailable = false

    var body: some View {
        Color.black.opacity(0.3)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else if unavailable { Image(systemName: "icloud.slash").foregroundStyle(.secondary) }
                else { ProgressView() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: "\(photo.id)|\(photo.modificationTime)|\(networkAllowed)") {
                image = nil
                unavailable = false
                do {
                    let loaded = try await cache.image(id: photo.id, revision: photo.modificationTime, networkAllowed: networkAllowed)
                    try Task.checkCancellation()
                    image = loaded
                } catch is CancellationError { }
                catch { unavailable = true }
            }
    }
}

@MainActor
struct PhotoPreviewView: View {
    let id: String
    let library: PhotoLibraryClient
    let networkAllowed: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Selected photo") }
                else if let error {
                    ContentUnavailableView("Preview unavailable", systemImage: "photo.badge.exclamationmark", description: Text(error))
                } else { ProgressView("Loading authorized photo…") }
            }
            .navigationTitle("Photo preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if image != nil {
                        Button("Share preview", systemImage: "square.and.arrow.up") {
                            guard library.currentRevision(id: id) != nil else {
                                image = nil; error = "Photo access was removed."; return
                            }
                            showShare = true
                        }
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let image { PhotoShareSheet(image: image) }
            }
            .task(id: id) {
                do {
                    let loaded = try await library.displayImage(id: id, targetSize: PHImageManagerMaximumSize, networkAllowed: networkAllowed)
                    try Task.checkCancellation()
                    guard library.currentRevision(id: id) != nil else { throw AppFailure.permission }
                    image = loaded
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

/// Shares the rendered UIImage, not the original asset/file or its GPS metadata.
/// Saving into Photos is excluded: this app requests read access only.
private struct PhotoShareSheet: UIViewControllerRepresentable {
    let image: UIImage
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