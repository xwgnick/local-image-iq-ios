import SwiftUI
import UIKit
import ImageIQCore

@MainActor
final class SimilarPhotoHoldInteraction: NSObject, UIGestureRecognizerDelegate {
    private(set) lazy var recognizer: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(changed(_:)))
        gesture.minimumPressDuration = 0.35
        gesture.allowableMovement = 8
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        return gesture
    }()
    var photoAtPoint: (CGPoint) -> String? = { _ in nil }
    var present: (String?) -> Void = { _ in }
    private(set) var activePhotoID: String?

    func attach(to view: UIView) { view.addGestureRecognizer(recognizer) }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        photoAtPoint(recognizer.location(in: recognizer.view)) != nil
    }

    @objc private func changed(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            if let id = photoAtPoint(gesture.location(in: gesture.view)) { begin(id) }
        case .ended, .failed, .cancelled: end()
        default: break
        }
    }

    func begin(_ id: String) {
        guard activePhotoID == nil else { return }
        activePhotoID = id
        present(id)
    }

    func end() {
        guard activePhotoID != nil else { return }
        activePhotoID = nil
        present(nil)
    }
}

/// A noninteractive cover leaves the original finger with its recognizer.
/// Only the held photo is requested; releasing destroys/cancels this task.
@MainActor
struct SimilarPhotoHoldPreview: View {
    let photo: IndexedPhoto
    @ObservedObject var appState: AppState
    let imageSource: SimilarComparisonImageSource
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var issue: PhotoPreviewIssue?

    private struct Request: Hashable {
        let id: String
        let modificationTime: Double
        let creationTime: Double?
        let width: CGFloat
        let height: CGFloat
        let authorization: Int
        let generation: UInt64?
        let epoch: UUID
        let networkAllowed: Bool

        var revision: PhotoRevision {
            PhotoRevision(id: id, modificationTime: modificationTime, creationTime: creationTime)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let pixels = DisplayThumbnailLoader.targetSize(points: geometry.size, displayScale: displayScale)
            let request = pixels.map {
                Request(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime,
                    width: $0.width, height: $0.height, authorization: appState.authorization.rawValue,
                    generation: appState.library.changeGeneration, epoch: appState.photoLibraryEpoch,
                    networkAllowed: appState.allowICloudDownload)
            }
            VStack(spacing: 16) {
                ZStack {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if let issue {
                        VStack(spacing: 8) {
                            Image(systemName: issue.symbol)
                            Text(issue.localizedCaption)
                            Text(issue.localizedMessage(networkAllowed: appState.allowICloudDownload))
                                .font(.caption)
                        }
                        .multilineTextAlignment(.center)
                    } else { ProgressView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("松手收起 · 不改变选择").font(.footnote)
            }
            .padding(16)
            .background(IQStyle.viewerBackground.opacity(0.97))
            .task(id: request) { await load(request) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .accessibilityIdentifier("similar-cleanup-held-photo")
    }

    private func load(_ request: Request?) async {
        image = nil
        issue = nil
        guard let request else { return }
        do {
            try imageSource.validate([request.revision], request.authorization, request.generation)
            let loaded = try await imageSource.load(request.id,
                CGSize(width: request.width, height: request.height), request.networkAllowed)
            try Task.checkCancellation()
            guard appState.canRead, appState.photoLibraryEpoch == request.epoch,
                  appState.allowICloudDownload == request.networkAllowed else { return }
            try imageSource.validate([request.revision], request.authorization, request.generation)
            image = loaded.image
        } catch {
            guard !Task.isCancelled else { return }
            issue = PhotoPreviewIssue(error: error)
        }
    }
}
