import SwiftUI
import UIKit
import ImageIQCore

struct SimilarPhotoGroupRoute: Identifiable, Equatable {
    let id = UUID()
    let sessionID: UUID
    let groupID: String
    let photoID: String
}

struct SimilarPhotoViewerRoute: Identifiable {
    let id: String
    let ids: [String]
}

struct SimilarPhotoZoomFlight: Identifiable {
    let id = UUID()
    let routeID: UUID
    let photoID: String
    let image: UIImage
    let source: CGRect
    var destination: CGRect?
}

/// Presentation only, local to one cleanup sheet. No Photos, selection model,
/// access validation, or deletion authority lives in this object. Tests can
/// inject it to exercise the same route callbacks as the actual cover buttons.
@MainActor
final class SimilarPhotoGroupBrowser: ObservableObject {
    @Published private(set) var detailRoute: SimilarPhotoGroupRoute?
    @Published private(set) var zoomFlight: SimilarPhotoZoomFlight?
    @Published var comparisonGroup: SimilarPhotoGroup?
    @Published var viewer: SimilarPhotoViewerRoute?
    private(set) var targetFrame: CGRect?

    func open(group: SimilarPhotoGroup, photoID: String, sessionID: UUID,
              capture: SimilarPhotoThumbnailCapture? = nil) {
        guard group.photos.contains(where: { $0.id == photoID }) else { return }
        let route = SimilarPhotoGroupRoute(sessionID: sessionID, groupID: group.id, photoID: photoID)
        targetFrame = nil
        comparisonGroup = nil
        viewer = nil
        if let capture, capture.photoID == photoID {
            zoomFlight = SimilarPhotoZoomFlight(routeID: route.id, photoID: photoID,
                                               image: capture.image, source: capture.frame)
        } else { zoomFlight = nil }
        detailRoute = route
    }

    func didLayoutTarget(routeID: UUID, photoID: String, frame: CGRect) {
        guard let route = detailRoute, route.id == routeID, route.photoID == photoID, !frame.isEmpty else { return }
        targetFrame = frame
        guard var flight = zoomFlight, flight.routeID == routeID, flight.photoID == photoID else { return }
        flight.destination = frame
        zoomFlight = flight
    }

    func finishZoom(_ id: UUID) { if zoomFlight?.id == id { zoomFlight = nil } }

    func viewPhoto(_ photoID: String, in group: SimilarPhotoGroup) {
        guard detailRoute?.groupID == group.id, group.photos.contains(where: { $0.id == photoID }) else { return }
        viewer = SimilarPhotoViewerRoute(id: photoID, ids: group.photos.map(\.id))
    }

    func closeDetail() {
        viewer = nil
        comparisonGroup = nil
        zoomFlight = nil
        targetFrame = nil
        detailRoute = nil
    }

    func invalidate(sessionID: UUID?) {
        if detailRoute?.sessionID != sessionID { closeDetail() }
    }

    static func canDelete(selectedCount: Int, isSelecting: Bool, isDeleting: Bool, isGrouping: Bool) -> Bool {
        selectedCount > 0 && !isSelecting && !isDeleting && !isGrouping
    }
}

/// The padded header's natural height, measured inside the vertical scroll
/// content rather than from its capped viewport. Layout observers can read the
/// same preference without creating a second copy of the text or buttons.
struct SimilarPhotoGroupHeaderHeightPreference: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

@MainActor
struct SimilarPhotoGroupDetail: View {
    let group: SimilarPhotoGroup
    let number: Int
    let route: SimilarPhotoGroupRoute
    @ObservedObject var state: SimilarPhotoCleanupState
    @ObservedObject var browser: SimilarPhotoGroupBrowser
    let thumbnail: (IndexedPhoto) -> AnyView
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectionMode = false
    @State private var measuredHeaderHeight: CGFloat = 0

    private var current: Bool { state.selectionSessionID == route.sessionID }
    private var enabled: Bool {
        current && !state.isGrouping && !state.isDeleting && scenePhase != .background
            && browser.comparisonGroup == nil && browser.viewer == nil && browser.zoomFlight == nil
    }
    private var selected: Int { group.photos.filter { state.selectedIDs.contains($0.id) }.count }
    // canSelect is false during an accepted gesture's own validation. Preserve
    // that gesture, but immediately switch pending/stale results to browsing.
    private var selectionAvailable: Bool {
        state.canSelect || (state.isSelecting && !state.hasPendingThresholdChange && !state.needsRegroup)
    }
    private var effectiveSelectionMode: Bool { selectionMode && selectionAvailable }

    var body: some View {
        GeometryReader { geometry in
            let availableHeaderHeight = geometry.size.height * 0.45
            VStack(spacing: 0) {
                // Scroll content gets an unbounded vertical proposal, even
                // before its viewport has a height. Short headers fit exactly;
                // accessibility text can scroll without consuming the grid.
                ScrollView {
                    header
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(key: SimilarPhotoGroupHeaderHeightPreference.self,
                                                       value: content.size.height)
                            }
                        }
                }
                .frame(height: min(measuredHeaderHeight, availableHeaderHeight), alignment: .top)
                .scrollDisabled(measuredHeaderHeight <= availableHeaderHeight)
                .layoutPriority(1)
                .onPreferenceChange(SimilarPhotoGroupHeaderHeightPreference.self) { height in
                    if measuredHeaderHeight != height { measuredHeaderHeight = height }
                }
                // Initial scrolling and zoom targeting are one-shot UIKit
                // operations: never run them against a zero-header viewport.
                if measuredHeaderHeight > 0 {
                    SimilarPhotoGroupGrid(
                        photos: group.photos, groupNumber: number, sessionID: route.sessionID,
                        initialPhotoID: route.photoID, selectedIDs: state.selectedIDs,
                        selectionMode: effectiveSelectionMode, isSelecting: state.isSelecting, enabled: enabled,
                        hiddenPhotoID: browser.zoomFlight?.photoID,
                        thumbnail: thumbnail,
                        begin: { guard enabled && state.canSelect else { return nil }; return state.beginRangeSelection(groupID: group.id) },
                        finish: { token, ids in
                            guard current else { return }
                            state.finishRangeSelection(token: token, selectedInGroup: ids)
                        },
                        cancel: { if current { state.cancelRangeSelection() } },
                        toggle: { id in if enabled && state.canSelect { state.toggleSelection(id) } },
                        browse: { id in if enabled && !state.isSelecting { browser.viewPhoto(id, in: group) } },
                        initialTarget: { id, frame in browser.didLayoutTarget(routeID: route.id, photoID: id, frame: frame) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(IQStyle.background)
        .onChange(of: selectionAvailable) { _, available in
            if !available { selectionMode = false }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("第\(number)组 · \(group.photos.count)张").font(.headline)
                    if selected > 0 {
                        Text("已选\(selected)张").font(.caption).foregroundStyle(IQStyle.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(effectiveSelectionMode ? "完成选择" : "选择") {
                    state.cancelRangeSelection()
                    selectionMode.toggle()
                }
                .frame(minHeight: 44)
                .disabled(!enabled || !state.canSelect)
                .accessibilityIdentifier("similar-cleanup-selection-mode")
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 16))
            layout {
                Button("全选本组") { selectWholeGroup(Set(group.photos.map(\.id))) }
                    .frame(minHeight: 44)
                    .disabled(!state.canSelect)
                    .accessibilityIdentifier("similar-cleanup-group-\(number)-select-group")
                Button("清空本组") { selectWholeGroup([]) }
                    .frame(minHeight: 44)
                    .disabled(!state.canSelect)
                    .accessibilityIdentifier("similar-cleanup-clear-group")
                Button("对比", systemImage: "rectangle.split.2x1") { browser.comparisonGroup = group }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("similar-cleanup-group-\(number)-compare")
            }
            .disabled(!enabled || state.isSelecting)
            if state.hasPendingThresholdChange || state.needsRegroup {
                Text("当前结果仅供浏览，更新分组后再选片清理。")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
            }
            if effectiveSelectionMode {
                Text("横向起拖可连续勾选或取消；纵向起拖仍可滚动。仅在下方确认后删除。")
                    .font(.caption).foregroundStyle(IQStyle.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(IQStyle.surface)
    }

    private func selectWholeGroup(_ ids: Set<String>) {
        guard enabled, state.canSelect, let token = state.beginRangeSelection(groupID: group.id) else { return }
        // Whole-group operations use the same off-main batch validation as a
        // drag. Never run hundreds of synchronous toggle/selectGroup checks.
        state.finishRangeSelection(token: token, selectedInGroup: ids)
    }
}

@MainActor
struct SimilarPhotoZoomOverlay: UIViewRepresentable {
    let flight: SimilarPhotoZoomFlight?
    let reduceMotion: Bool
    let completion: (UUID) -> Void

    func makeUIView(context: Context) -> SimilarPhotoZoomView { SimilarPhotoZoomView() }
    func updateUIView(_ view: SimilarPhotoZoomView, context: Context) {
        view.update(flight: flight, reduceMotion: reduceMotion, completion: completion)
    }
    static func dismantleUIView(_ view: SimilarPhotoZoomView, coordinator: ()) { view.clear() }
}

/// Animate one fixed raster, not PhotoThumbnailView's request size at every
/// animation frame. Both endpoints are measured from real UIKit views.
@MainActor
final class SimilarPhotoZoomView: UIView {
    private let imageView = UIImageView()
    private var flight: SimilarPhotoZoomFlight?
    private var reduceMotion = false
    private var completion: ((UUID) -> Void)?
    private var animator: UIViewPropertyAnimator?
    private var animatingID: UUID?
    private(set) var sourceFrame: CGRect?
    private(set) var destinationFrame: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(flight: SimilarPhotoZoomFlight?, reduceMotion: Bool, completion: @escaping (UUID) -> Void) {
        if self.flight?.id != flight?.id { clear() }
        self.flight = flight
        self.reduceMotion = reduceMotion
        self.completion = completion
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let flight, let window, animatingID != flight.id else { return }
        imageView.image = flight.image
        imageView.alpha = 1
        let source = convert(flight.source, from: window)
        sourceFrame = source
        imageView.frame = source
        guard let destination = flight.destination else { return }
        let target = convert(destination, from: window)
        destinationFrame = target
        animatingID = flight.id
        if reduceMotion { imageView.frame = target }
        let animator = reduceMotion
            ? UIViewPropertyAnimator(duration: 0.18, curve: .easeOut)
            : UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.86)
        animator.addAnimations { [weak self] in
            guard let self else { return }
            if self.reduceMotion { self.imageView.alpha = 0 }
            else { self.imageView.frame = target }
        }
        animator.addCompletion { [weak self] _ in
            guard let self, self.flight?.id == flight.id else { return }
            self.completion?(flight.id)
        }
        self.animator = animator
        animator.startAnimation()
    }

    func clear() {
        animator?.stopAnimation(true)
        animator = nil
        animatingID = nil
        flight = nil
        imageView.image = nil
        sourceFrame = nil
        destinationFrame = nil
    }
}