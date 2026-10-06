import SwiftUI
import UIKit
import ImageIQCore

/// Geometry is independent of Dynamic Type and member count. Only text outside
/// the mosaic/grid grows with the user's font. Thirty is a COVER size, never a
/// selection, loading or group-membership limit.
enum SimilarPhotoGroupGeometry {
    static let previewColumns = 10
    static let columns = 5
    static let gap: CGFloat = 2
    static let edge: CGFloat = 2

    static func previewIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let samples = min(count, 30)
        guard samples > 1 else { return [0] }
        return (0..<samples).map { $0 * (count - 1) / (samples - 1) }
    }

    static func previewHeight(count: Int, width: CGFloat) -> CGFloat {
        let rows = (min(max(0, count), 30) + previewColumns - 1) / previewColumns
        guard rows > 0 else { return 0 }
        let side = max(0, (width - CGFloat(previewColumns - 1) * gap) / CGFloat(previewColumns))
        return CGFloat(rows) * side + CGFloat(rows - 1) * gap
    }

    static func side(width: CGFloat) -> CGFloat {
        max(0, (width - 2 * edge - CGFloat(columns - 1) * gap) / CGFloat(columns))
    }

    static func frame(index: Int, width: CGFloat) -> CGRect {
        let side = side(width: width)
        return CGRect(x: edge + CGFloat(index % columns) * (side + gap),
                      y: edge + CGFloat(index / columns) * (side + gap), width: side, height: side)
    }

    static func height(count: Int, width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        return 2 * edge + CGFloat(rows) * side(width: width) + CGFloat(rows - 1) * gap
    }

    /// During an accepted drag, gaps and the viewport edges resolve to the
    /// nearest row/column. A gesture must START on an actual cell, not a gap.
    static func nearestIndex(point: CGPoint, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 2 * edge else { return nil }
        let stride = side(width: width) + gap
        let column = min(columns - 1, max(0, Int(floor((point.x - edge + gap / 2) / stride))))
        let row = max(0, Int(floor((point.y - edge + gap / 2) / stride)))
        return min(count - 1, row * columns + column)
    }
}

struct SimilarPhotoMosaicLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return CGSize(width: width, height: SimilarPhotoGroupGeometry.previewHeight(count: subviews.count, width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = SimilarPhotoGroupGeometry.previewColumns
        let gap = SimilarPhotoGroupGeometry.gap
        let side = max(0, (bounds.width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (side + gap),
                                     y: bounds.minY + CGFloat(index / columns) * (side + gap)),
                          anchor: .topLeading, proposal: ProposedViewSize(width: side, height: side))
        }
    }
}

struct SimilarPhotoThumbnailCapture {
    let photoID: String
    let image: UIImage
    /// Window coordinates, shared by both UIKit ends of the transition.
    let frame: CGRect
}

/// Readiness belongs to one exact thumbnail request, not to a recycled cover.
/// The keyed child resets both its flag and PhotoThumbnailView's task together,
/// including on rotation/display-scale changes, without an onChange/load race.
@MainActor
struct SimilarPhotoLoadedPreviewTile: View {
    let photo: IndexedPhoto
    let cache: PhotoThumbnailCache
    let networkAllowed: Bool
    let label: String
    let identifier: String
    let selected: Bool
    let enabled: Bool
    let open: (SimilarPhotoThumbnailCapture?) -> Void
    @Environment(\.displayScale) private var displayScale

    private struct Request: Hashable {
        let photoID: String
        let revision: Double
        let creationTime: Double?
        let cache: ObjectIdentifier
        let networkAllowed: Bool
        let width: CGFloat
        let height: CGFloat
        let displayScale: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            ReadyTile(preview: self, size: geometry.size, displayScale: displayScale)
                .id(Request(photoID: photo.id, revision: photo.modificationTime,
                            creationTime: photo.creationTime, cache: ObjectIdentifier(cache),
                            networkAllowed: networkAllowed, width: geometry.size.width,
                            height: geometry.size.height, displayScale: displayScale))
        }
        .clipped()
    }

    private struct ReadyTile: View {
        let preview: SimilarPhotoLoadedPreviewTile
        let size: CGSize
        let displayScale: CGFloat
        @State private var ready = false

        var body: some View {
            SimilarPhotoPreviewTile(photoID: preview.photo.id, label: preview.label,
                identifier: preview.identifier, selected: preview.selected, enabled: preview.enabled,
                content: AnyView(PhotoThumbnailView(photo: preview.photo, cache: preview.cache,
                    networkAllowed: preview.networkAllowed, onLoaded: { ready = true })
                    // Pin the hosted request to the same geometry/scale as its
                    // readiness identity. There is only one thumbnail loader.
                    .environment(\.displayScale, displayScale)
                    .frame(width: size.width, height: size.height)),
                canCapture: ready, open: preview.open)
                .frame(width: size.width, height: size.height)
        }
    }
}

/// Captures ONLY the tapped, already-rendered cover tile. It neither requests
/// new pixels nor snapshots an entire (potentially very long) collection.
@MainActor
struct SimilarPhotoPreviewTile: UIViewRepresentable {
    let photoID: String
    let label: String
    let identifier: String
    let selected: Bool
    let enabled: Bool
    let content: AnyView
    // Injected synthetic content is immediately available. Production supplies
    // the request-scoped PhotoThumbnailView readiness above explicitly.
    var canCapture = true
    let open: (SimilarPhotoThumbnailCapture?) -> Void

    func makeUIView(context: Context) -> SimilarPhotoPreviewControl { SimilarPhotoPreviewControl() }

    func updateUIView(_ view: SimilarPhotoPreviewControl, context: Context) {
        view.photoID = photoID
        view.canCapture = canCapture
        view.isEnabled = enabled
        view.accessibilityLabel = label
        view.accessibilityIdentifier = identifier
        view.accessibilityValue = selected ? "已勾选待删除" : "未勾选"
        view.accessibilityTraits = selected ? [.button, .selected] : [.button]
        view.accessibilityHint = "打开本组并定位这张照片，不改变选择"
        view.open = open
        view.configure(content: content, selected: selected)
    }
}

@MainActor
final class SimilarPhotoPreviewControl: UIControl {
    var photoID = ""
    var canCapture = false
    var open: ((SimilarPhotoThumbnailCapture?) -> Void)?
    private var hosted: (UIView & UIContentView)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isAccessibilityElement = true
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(content: AnyView, selected: Bool) {
        let configuration = UIHostingConfiguration {
            content.overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(IQStyle.accent)
                        .background(.black.opacity(0.6), in: Circle())
                }
            }
        }.margins(.all, 0).minSize(width: 0, height: 0)
        if let hosted { hosted.configuration = configuration }
        else {
            let hosted = configuration.makeContentView()
            hosted.isUserInteractionEnabled = false
            hosted.accessibilityElementsHidden = true
            addSubview(hosted)
            self.hosted = hosted
        }
        setNeedsLayout()
    }

    override func layoutSubviews() { super.layoutSubviews(); hosted?.frame = bounds }

    func capture() -> SimilarPhotoThumbnailCapture? {
        guard canCapture, let window, !bounds.isEmpty else { return nil }
        let capturedID = photoID
        let capturedBounds = bounds
        layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: capturedBounds, format: format).image { _ in
            // onLoaded updates image state before drawing. Include that pending
            // update rather than capturing the previous spinner/error raster.
            drawn = drawHierarchy(in: capturedBounds, afterScreenUpdates: true)
        }
        // A layout/identity change during drawing, or an incomplete hierarchy,
        // falls back to exact-ID navigation, never a stale layer snapshot.
        guard drawn, canCapture, photoID == capturedID, bounds == capturedBounds,
              self.window === window else { return nil }
        return SimilarPhotoThumbnailCapture(photoID: capturedID, image: image, frame: convert(capturedBounds, to: window))
    }

    @objc private func activate() { guard isEnabled else { return }; open?(capture()) }
    override func accessibilityActivate() -> Bool { guard isEnabled else { return false }; activate(); return true }
}

/// Computes attributes only for requested/visible rows. No full-group image
/// prefetching, cell construction, or array of layout attributes is retained.
@MainActor
final class SimilarPhotoFiveColumnLayout: UICollectionViewLayout {
    private var count: Int {
        guard let collectionView, collectionView.numberOfSections > 0 else { return 0 }
        return collectionView.numberOfItems(inSection: 0)
    }
    private var width: CGFloat { collectionView?.bounds.width ?? 0 }
    override var collectionViewContentSize: CGSize {
        CGSize(width: width, height: SimilarPhotoGroupGeometry.height(count: count, width: width))
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = SimilarPhotoGroupGeometry.frame(index: indexPath.item, width: width)
        return attributes
    }
    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard count > 0, width > 0 else { return [] }
        // UIKit may ask about off-content or unbounded rectangles. Intersect
        // with actual content geometry before converting row coordinates to Int.
        let visible = rect.intersection(CGRect(origin: .zero, size: collectionViewContentSize))
        guard !visible.isNull, !visible.isEmpty else { return [] }
        let stride = SimilarPhotoGroupGeometry.side(width: width) + SimilarPhotoGroupGeometry.gap
        let first = max(0, Int(floor((visible.minY - SimilarPhotoGroupGeometry.edge) / stride))) * 5
        let end = min(count, (max(0, Int(floor((visible.maxY - SimilarPhotoGroupGeometry.edge) / stride))) + 1) * 5)
        guard first < end else { return [] }
        return (first..<end).compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
            .filter { $0.frame.intersects(rect) }
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

@MainActor
struct SimilarPhotoGroupGrid: UIViewControllerRepresentable {
    let photos: [IndexedPhoto]
    let groupNumber: Int
    let sessionID: UUID
    let initialPhotoID: String
    let selectedIDs: Set<String>
    let selectionMode: Bool
    let isSelecting: Bool
    let enabled: Bool
    let hiddenPhotoID: String?
    let thumbnail: (IndexedPhoto) -> AnyView
    let begin: () -> UUID?
    let finish: (UUID, Set<String>) -> Void
    let cancel: () -> Void
    let toggle: (String) -> Void
    let browse: (String) -> Void
    let initialTarget: (String, CGRect) -> Void

    func makeUIViewController(context: Context) -> SimilarPhotoGroupGridController {
        let controller = SimilarPhotoGroupGridController()
        controller.configure(self)
        return controller
    }
    func updateUIViewController(_ controller: SimilarPhotoGroupGridController, context: Context) {
        controller.configure(self)
    }
    static func dismantleUIViewController(_ controller: SimilarPhotoGroupGridController, coordinator: ()) {
        controller.shutdown()
    }
}

@MainActor
private final class SimilarPhotoDisplayLinkTarget: NSObject {
    weak var owner: SimilarPhotoGroupGridController?
    @objc func tick(_ link: CADisplayLink) {
        owner?.advanceAutoScroll(elapsed: link.targetTimestamp - link.timestamp)
    }
}

/// The deterministic interaction methods below are the recognizer's real path,
/// also exercised in hosted tests. They are not synthetic UITouch/XCUI events.
@MainActor
final class SimilarPhotoGroupGridController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegate, UIGestureRecognizerDelegate {
    let collectionView = UICollectionView(frame: .zero, collectionViewLayout: SimilarPhotoFiveColumnLayout())
    private(set) lazy var rangePan = UIPanGestureRecognizer(target: self, action: #selector(rangePanned(_:)))
    private var configuration: SimilarPhotoGroupGrid?
    private var range: SimilarPhotoRangeSelection?
    private var token: UUID?
    private(set) var provisionalIDs: Set<String>?
    private(set) var awaitingValidation = false
    private var displayLink: CADisplayLink?
    private let linkTarget = SimilarPhotoDisplayLinkTarget()
    private var fingerInViewport: CGPoint?
    private var initialScrollPending = true
    private var initialTargetReported = false
    private var reportingTarget = false
    private var isLayingOut = false
    private(set) var initialScrollPhotoID: String?
    private(set) var isShutdown = false
    var hasActiveDisplayLink: Bool { displayLink != nil }
    var displayedSelection: Set<String> { provisionalIDs ?? configuration?.selectedIDs ?? [] }

    override func loadView() {
        view = collectionView
        collectionView.backgroundColor = UIColor(IQStyle.background)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "photo")
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.isPrefetchingEnabled = false
        collectionView.accessibilityIdentifier = "similar-cleanup-five-column-grid"
        rangePan.minimumNumberOfTouches = 1
        rangePan.maximumNumberOfTouches = 1
        rangePan.delegate = self
        collectionView.addGestureRecognizer(rangePan)
        // The horizontal-start recognizer fails immediately for a vertical
        // start, allowing native inertial scrolling instead of stealing it.
        collectionView.panGestureRecognizer.require(toFail: rangePan)
        linkTarget.owner = self
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        updateGestureAvailability()
    }

    func configure(_ next: SimilarPhotoGroupGrid) {
        let replaced = configuration?.sessionID != next.sessionID
            || configuration?.photos.map(\.id) != next.photos.map(\.id)
        if replaced {
            cancelInteraction()
            initialScrollPending = true
            initialTargetReported = false
        }
        configuration = next
        if !next.enabled || !next.selectionMode { cancelInteraction() }
        if token != nil && !next.isSelecting {
            // The state publishes selectedIDs before it lowers isSelecting.
            // Do not remove the local preview on finger-up / async submission.
            discardPreview()
        }
        guard isViewLoaded else { return }
        if replaced { collectionView.reloadData(); view.setNeedsLayout() }
        refreshVisibleCells()
        updateGestureAvailability()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isLayingOut, !isShutdown, let configuration,
              collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        if initialScrollPending,
           let index = configuration.photos.firstIndex(where: { $0.id == configuration.initialPhotoID }) {
            initialScrollPending = false
            initialScrollPhotoID = configuration.photos[index].id
            collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
            collectionView.layoutIfNeeded()
        }
        reportInitialTargetIfReady()
    }

    private func reportInitialTargetIfReady() {
        guard !initialTargetReported, !reportingTarget, let configuration,
              let index = configuration.photos.firstIndex(where: { $0.id == configuration.initialPhotoID }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)),
              let window = cell.window, !cell.bounds.isEmpty else { return }
        let frame = cell.convert(cell.bounds, to: window)
        guard collectionView.convert(collectionView.bounds, to: window).intersects(frame) else { return }
        let session = configuration.sessionID
        let id = configuration.initialPhotoID
        reportingTarget = true
        // Layout, not a guessed animation/request delay, makes the target ready.
        // Defer publication out of UIViewRepresentable's update transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportingTarget = false
            guard !self.isShutdown, !self.initialTargetReported,
                  self.configuration?.sessionID == session,
                  self.configuration?.initialPhotoID == id,
                                    self.collectionView.indexPath(for: cell)?.item == index,
                                    let window = cell.window,
                                    self.collectionView.convert(self.collectionView.bounds, to: window)
                                        .intersects(cell.convert(cell.bounds, to: window)) else { return }
            self.initialTargetReported = true
            self.configuration?.initialTarget(id, cell.convert(cell.bounds, to: window))
        }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        configuration?.photos.count ?? 0
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "photo", for: indexPath)
        configureCell(cell, at: indexPath)
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        configureCell(cell, at: indexPath)
    }
    private func configureCell(_ cell: UICollectionViewCell, at index: IndexPath) {
        guard let configuration, configuration.photos.indices.contains(index.item) else { return }
        let photo = configuration.photos[index.item]
        let selected = displayedSelection.contains(photo.id)
        cell.contentConfiguration = UIHostingConfiguration {
            configuration.thumbnail(photo)
                .overlay(alignment: .bottomTrailing) {
                    if configuration.selectionMode {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(selected ? IQStyle.accent : .white)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(3)
                    }
                }
                .clipped()
        }.margins(.all, 0).minSize(width: 0, height: 0)
        cell.clipsToBounds = true
        cell.contentView.alpha = configuration.hiddenPhotoID == photo.id ? 0 : 1
        cell.contentView.accessibilityElementsHidden = true
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = "第\(configuration.groupNumber)组，照片\(index.item + 1)"
        cell.accessibilityValue = selected ? "已勾选待删除" : "未勾选"
        cell.accessibilityHint = configuration.selectionMode ? "轻点切换待删除选择" : "查看完整照片"
        cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
        cell.accessibilityIdentifier = "similar-cleanup-detail-photo-\(index.item + 1)"
    }
    private func refreshVisibleCells() {
        for index in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: index) { configureCell(cell, at: index) }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        // UIKit's own single-selection state is not the cleanup selection model.
        // Clear it so repeated taps on the same cell always reach this callback.
        collectionView.deselectItem(at: indexPath, animated: false)
        activateItem(at: indexPath.item)
    }
    func activateItem(at index: Int) {
        guard let configuration, configuration.enabled, !configuration.isSelecting,
              configuration.photos.indices.contains(index), !isShutdown else { return }
        let id = configuration.photos[index].id
        if configuration.selectionMode { configuration.toggle(id) }
        else { configuration.browse(id) }
    }

    static func acceptsHorizontalStart(_ velocity: CGPoint) -> Bool { abs(velocity.x) > abs(velocity.y) }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === rangePan, let configuration, configuration.enabled,
              configuration.selectionMode, !configuration.isSelecting, !isShutdown,
              Self.acceptsHorizontalStart(rangePan.velocity(in: collectionView)) else { return false }
        let translation = rangePan.translation(in: collectionView)
        let current = rangePan.location(in: collectionView)
        let origin = CGPoint(x: current.x - translation.x, y: current.y - translation.y)
        return collectionView.indexPathForItem(at: origin) != nil
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    @objc private func rangePanned(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: collectionView)
        switch pan.state {
        case .began:
            let translation = pan.translation(in: collectionView)
            let start = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard let index = collectionView.indexPathForItem(at: start)?.item,
                  beginInteraction(at: index) else { return }
            updateInteraction(at: point)
        case .changed: updateInteraction(at: point)
        case .ended: updateInteraction(at: point); endInteraction()
        case .cancelled, .failed: cancelInteraction()
        default: break
        }
    }

    @discardableResult
    func beginInteraction(at index: Int) -> Bool {
        guard let configuration, !isShutdown, configuration.enabled, configuration.selectionMode,
              !configuration.isSelecting, token == nil, configuration.photos.indices.contains(index),
              let range = SimilarPhotoRangeSelection(photoIDs: configuration.photos.map(\.id),
                  selectedIDs: configuration.selectedIDs.intersection(configuration.photos.map(\.id)),
                  anchorID: configuration.photos[index].id),
              let token = configuration.begin() else { return false }
        self.range = range
        self.token = token
        awaitingValidation = false
        provisionalIDs = range.selection(throughID: configuration.photos[index].id)
        refreshVisibleCells()
        let link = CADisplayLink(target: linkTarget, selector: #selector(SimilarPhotoDisplayLinkTarget.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
        return true
    }

    func updateInteraction(at contentPoint: CGPoint) {
        guard range != nil else { return }
        fingerInViewport = CGPoint(x: contentPoint.x - collectionView.bounds.minX,
                                   y: contentPoint.y - collectionView.bounds.minY)
        updateRange(at: contentPoint)
    }
    private func updateRange(at point: CGPoint) {
        guard let configuration, let range,
              let index = SimilarPhotoGroupGeometry.nearestIndex(point: point, width: collectionView.bounds.width,
                                                                 count: configuration.photos.count) else { return }
        let desired = range.selection(throughID: configuration.photos[index].id)
        if desired != provisionalIDs { provisionalIDs = desired; refreshVisibleCells() }
    }

    func endInteraction() {
        guard let configuration, let token, let provisionalIDs, range != nil else { return }
        stopDisplayLink()
        range = nil
        awaitingValidation = true
        configuration.finish(token, provisionalIDs)
        updateGestureAvailability()
        // Keep both token and provisional image selection until the matching
        // state validation completes, or cancel/session invalidation discards it.
    }

    func cancelInteraction() {
        let hadToken = token != nil
        discardPreview()
        if hadToken { configuration?.cancel() }
    }
    private func discardPreview() {
        stopDisplayLink()
        range = nil; token = nil; provisionalIDs = nil; awaitingValidation = false
        if isViewLoaded {
            // Also end the active recognizer if clear/session invalidation
            // arrives while a finger remains down. Late changed/ended is inert.
            rangePan.isEnabled = false
            refreshVisibleCells()
        }
    }
    private func stopDisplayLink() { displayLink?.invalidate(); displayLink = nil; fingerInViewport = nil }

    /// Rate is proportional to edge penetration and the actual viewport. Each
    /// tick is bounded to one native row so a stalled frame cannot jump pages.
    /// This is gesture geometry, not a photo/batch/time capacity limit.
    func advanceAutoScroll(elapsed: TimeInterval) {
        guard range != nil, let finger = fingerInViewport, elapsed > 0 else { return }
        let bounds = collectionView.bounds
        let zone = min(bounds.height / 4, SimilarPhotoGroupGeometry.side(width: bounds.width))
        guard zone > 0 else { return }
        let penetration: CGFloat
        if finger.y < zone { penetration = -min(1, max(0, (zone - finger.y) / zone)) }
        else if finger.y > bounds.height - zone { penetration = min(1, (finger.y - bounds.height + zone) / zone) }
        else { return }
        let stride = SimilarPhotoGroupGeometry.side(width: bounds.width) + SimilarPhotoGroupGeometry.gap
        let distance = min(stride, CGFloat(elapsed) * bounds.height) * penetration
        let minimum = -collectionView.adjustedContentInset.top
        let maximum = max(minimum, collectionView.contentSize.height - bounds.height + collectionView.adjustedContentInset.bottom)
        let y = min(maximum, max(minimum, bounds.minY + distance))
        guard y != bounds.minY else { return }
        collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        collectionView.layoutIfNeeded()
        updateRange(at: CGPoint(x: min(bounds.width - 2, max(2, finger.x)),
                               y: y + min(bounds.height - 2, max(2, finger.y))))
    }

    private func updateGestureAvailability() {
        guard isViewLoaded else { return }
        let enabled = !isShutdown && configuration?.enabled == true && configuration?.selectionMode == true
            && ((configuration?.isSelecting == false && token == nil) || range != nil)
        if rangePan.isEnabled != enabled { rangePan.isEnabled = enabled }
    }
    @objc private func backgrounded() { suspendInteraction() }
    func suspendInteraction() { cancelInteraction(); if isViewLoaded { rangePan.isEnabled = false } }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); cancelInteraction() }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateGestureAvailability()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        reportInitialTargetIfReady()
    }
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        cancelInteraction()
        if isViewLoaded { rangePan.isEnabled = false; collectionView.removeGestureRecognizer(rangePan) }
        NotificationCenter.default.removeObserver(self)
        configuration = nil
    }
    deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }
}