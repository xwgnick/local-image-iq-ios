import SwiftUI
import UIKit
import ImageIQCore

/// An interactive LEFT-screen-edge return for the retained cleanup detail.
/// This is intentionally not UINavigationController's interactive pop. Keeping
/// the overview mounted preserves its offset and the shared selection footer.
@MainActor
struct CleanupBackNavigation: UIViewRepresentable {
    let routeID: UUID?
    let enabled: Bool
    let canReturn: () -> Bool
    let began: () -> Void
    let changed: (CGFloat) -> Void
    let cancelled: () -> Void
    let returned: () -> Void

    func makeUIView(context: Context) -> CleanupBackNavigationAnchor {
        CleanupBackNavigationAnchor()
    }

    func updateUIView(_ view: CleanupBackNavigationAnchor, context: Context) {
        view.update(self)
    }

    static func dismantleUIView(_ view: CleanupBackNavigationAnchor, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class CleanupBackNavigationAnchor: UIView, UIGestureRecognizerDelegate {
    static let gestureName = "similar-cleanup-left-edge-back"
    private(set) lazy var edgePan: UIScreenEdgePanGestureRecognizer = {
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.edges = .left
        pan.maximumNumberOfTouches = 1
        pan.name = Self.gestureName
        pan.delegate = self
        return pan
    }()
    private var configuration: CleanupBackNavigation?
    private var tracking = true
    private var activeRouteID: UUID?
    private(set) var progress: CGFloat = 0
    private(set) weak var gestureView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ next: CleanupBackNavigation) {
        if activeRouteID != nil && (next.routeID != activeRouteID || !next.enabled || !next.canReturn()) {
            // Updates can occur inside SwiftUI's rendering transaction.
            let cancel = configuration?.cancelled
            activeRouteID = nil
            progress = 0
            edgePan.isEnabled = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeRouteID == nil else { return }
                cancel?()
            }
        }
        configuration = next
        attachIfPossible()
        edgePan.isEnabled = next.enabled && next.routeID != nil && next.canReturn()
        DispatchQueue.main.async { [weak self] in self?.attachIfPossible() }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attachIfPossible() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attachIfPossible() }
    override func layoutSubviews() { super.layoutSubviews(); attachIfPossible() }

    private func attachIfPossible() {
        guard tracking, window != nil else { removeGesture(); return }
        // Public containment only. Never attach to UIWindow (other tabs/sheets)
        // or replace UIKit's navigation/scroll gesture delegates.
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let navigation = (controller as? UINavigationController) ?? controller.navigationController,
               let target = navigation.viewIfLoaded, isDescendant(of: target) {
                if gestureView !== target {
                    removeGesture()
                    gestureView = target
                    target.addGestureRecognizer(edgePan)
                }
                return
            }
            responder = current.next
        }
        removeGesture()
    }

    private func removeGesture() {
        gestureView?.removeGestureRecognizer(edgePan)
        gestureView = nil
    }

    func detach() {
        tracking = false
        cancelInteraction()
        edgePan.isEnabled = false
        removeGesture()
        configuration = nil
    }

    static func accepts(_ velocity: CGPoint) -> Bool { velocity.x > abs(velocity.y) }
    static func shouldFinish(progress: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        // Reverse motion always cancels. Otherwise project a short release
        // velocity onto the remaining distance, as an interaction heuristic.
        velocity >= 0 && width > 0 && progress > 0
            && progress + velocity * 0.15 / width >= 0.5
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === edgePan && configuration?.enabled == true
            && configuration?.routeID != nil && configuration?.canReturn() == true
            && Self.accepts(edgePan.velocity(in: gestureView))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // Edge wins over both the grid's range recognizer and vertical scroll.
        // Away from the physical edge UIScreenEdgePan fails, so neither waits
        // for a made-up horizontal-drag threshold or loses normal selection.
        gestureRecognizer === edgePan && other is UIPanGestureRecognizer
            && !(other is UIScreenEdgePanGestureRecognizer)
    }

    @objc private func panned(_ pan: UIScreenEdgePanGestureRecognizer) {
        let width = pan.view?.bounds.width ?? 0
        switch pan.state {
        case .began:
            guard beginInteraction() else { return }
            updateInteraction(translation: pan.translation(in: pan.view).x, width: width)
        case .changed: updateInteraction(translation: pan.translation(in: pan.view).x, width: width)
        case .ended:
            updateInteraction(translation: pan.translation(in: pan.view).x, width: width)
            endInteraction(velocity: pan.velocity(in: pan.view).x, width: width)
        case .failed, .cancelled: cancelInteraction()
        default: break
        }
    }

    // Shared recognizer path for deterministic native-host cancellation tests.
    // Calling these methods is NOT touch injection; XCUI tests do that separately.
    @discardableResult
    func beginInteraction() -> Bool {
        guard activeRouteID == nil, let configuration, configuration.enabled,
              let route = configuration.routeID, configuration.canReturn() else { return false }
        activeRouteID = route
        progress = 0
        configuration.began()
        return true
    }

    func updateInteraction(translation: CGFloat, width: CGFloat) {
        guard let route = activeRouteID, let configuration, configuration.routeID == route,
              configuration.enabled, configuration.canReturn(), width > 0 else {
            cancelInteraction(); return
        }
        progress = min(1, max(0, translation / width))
        configuration.changed(progress * width)
    }

    func endInteraction(velocity: CGFloat, width: CGFloat) {
        guard let route = activeRouteID, let configuration, configuration.routeID == route,
              configuration.enabled, configuration.canReturn(),
              Self.shouldFinish(progress: progress, velocity: velocity, width: width) else {
            cancelInteraction(); return
        }
        activeRouteID = nil
        progress = 0
        configuration.returned()
    }

    func cancelInteraction() {
        guard activeRouteID != nil else { return }
        activeRouteID = nil
        progress = 0
        configuration?.cancelled()
    }
}

#if DEBUG
/// Explicit opt-in XCUI seam. Release builds contain neither the entry nor
/// these services. It never creates a Photos grouping/deletion service, requests
/// pixels, changes authorization, or uses a persistent preference/index.
@MainActor
struct CleanupNavigationUITestHost: View {
    @ObservedObject var appState: AppState
    let isPageActive: Bool
    let accessibilityActive: Bool
    let onPresentedSurfaceChanged: (Bool) -> Void
    @StateObject private var cleanup = SimilarPhotoCleanupState(
        grouping: CleanupNavigationFixtureGroups(), deletion: CleanupNavigationFixtureDeletion())
    @StateObject private var browser = SimilarPhotoGroupBrowser()
    @State private var started = false

    var body: some View {
        // Fail closed on any readable real library. This seam is not an excuse
        // to give an automated test access to a user's photos.
        if PhotoLibraryClient.canRead {
            Text("TEST requires an unreadable Photos library")
        } else {
            SimilarPhotoCleanupSheet(state: cleanup, appState: appState, browser: browser,
                thumbnailContent: { photo in AnyView(
                    Color.orange.overlay(Text(photo.id.components(separatedBy: "-").last ?? "")
                        .font(.caption).foregroundStyle(.black))
                ) }, isPageActive: isPageActive,
                accessibilityActive: accessibilityActive && isPageActive,
                onPresentedSurfaceChanged: onPresentedSurfaceChanged)
                .task {
                    guard !started else { return }
                    started = true
                    cleanup.scan()
                }
                .onChange(of: isPageActive) { _, active in
                    if !active { cleanup.cancelRangeSelection() }
                }
        }
    }
}

private struct CleanupNavigationFixtureGroups: SimilarPhotoGrouping {
    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        var groups: [SimilarPhotoGroup] = []
        var vector = [Float](repeating: 0, count: 768)
        vector[0] = 1
        for ordinal in 0..<12 {
            var photos: [IndexedPhoto] = []
            for index in 0..<(ordinal == 0 ? 300 : 35) {
                photos.append(IndexedPhoto(id: "TEST-edge-\(ordinal)-\(index + 1)", modificationTime: 1,
                    modelVersion: "TEST-edge", imageEmbedding: vector,
                    creationTime: Double(100_000 - ordinal * 1_000 + index)))
            }
            groups.append(SimilarPhotoGroup(id: "TEST-edge-group-\(ordinal)", photos: photos, minimumSimilarity: 1))
        }
        return SimilarPhotoGroupingResult(groups: groups,
            candidateCount: groups.reduce(0) { $0 + $1.photos.count }, staleCount: 0, unindexedCount: 0,
            threshold: threshold)
    }
}

private struct CleanupNavigationFixtureDeletion: PhotoDeleting {
    func delete(revisions: [PhotoRevision]) async throws {
        // Even an accidental confirm in this fixture cannot reach PhotoKit.
        throw CancellationError()
    }
}
#endif