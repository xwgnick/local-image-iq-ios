import SwiftUI
import UIKit

/// Present one immutable share per sheet identity. The parent prepares it and
/// validates access immediately before presentation (never in this view).
/// The parent must also retain it until .onDismiss, call cleanup() there/on access
/// loss, and clear its presentation state. This covers interactive dismissal when
/// UIKit supplies no completion. Already-shared external copies cannot be revoked.
@MainActor
struct BatchPhotoShareSheet: UIViewControllerRepresentable {
    let share: PreparedPhotoShare
    let validate: () -> Bool
    let finished: (UUID) -> Void

    init(share: PreparedPhotoShare, validate: @escaping () -> Bool = { true },
         finished: @escaping (UUID) -> Void = { _ in }) {
        self.share = share
        self.validate = validate
        self.finished = finished
    }

    func makeCoordinator() -> Coordinator { Coordinator(share: share, validate: validate, finished: finished) }

    func makeUIViewController(context: Context) -> UIViewController {
        guard context.coordinator.validate() else {
            let blocked = UIViewController()
            DispatchQueue.main.async { context.coordinator.finished(share.id) }
            return blocked
        }
        return context.coordinator.makeController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        // Re-rendering must not replace in-use URLs or remove files still being read.
    }

    @MainActor
    final class Coordinator {
        let share: PreparedPhotoShare
        let validate: () -> Bool
        let finished: (UUID) -> Void

        init(share: PreparedPhotoShare, validate: @escaping () -> Bool = { true },
             finished: @escaping (UUID) -> Void = { _ in }) {
            self.share = share; self.validate = validate; self.finished = finished
        }

        func makeController() -> UIActivityViewController {
            let controller = UIActivityViewController(activityItems: share.urls, applicationActivities: nil)
            controller.excludedActivityTypes = [.saveToCameraRoll]
            controller.completionWithItemsHandler = { [share, finished] _, _, _, _ in
                // UIKit invokes this after the activity finishes/cancels, not on
                // selection or update. Parent dismissal cleanup is idempotent.
                share.cleanup()
                finished(share.id)
            }
            return controller
        }
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.share.cleanup()
        let id = coordinator.share.id
        DispatchQueue.main.async { coordinator.finished(id) }
    }
}