import SwiftUI
import UIKit

@MainActor
struct SimilarPhotoOverviewSelection: UIViewRepresentable {
    let sessionID: UUID?
    let photoIDs: [String]
    let selectedIDs: Set<String>
    let enabled: Bool
    let isSelecting: Bool
    let begin: () -> UUID?
    let finish: (UUID, Set<String>) -> Void
    let cancel: () -> Void

    func makeUIView(context: Context) -> SimilarPhotoOverviewSelectionAnchor {
        SimilarPhotoOverviewSelectionAnchor()
    }
    func updateUIView(_ view: SimilarPhotoOverviewSelectionAnchor, context: Context) { view.update(self) }
    static func dismantleUIView(_ view: SimilarPhotoOverviewSelectionAnchor, coordinator: ()) { view.detach() }
}

@MainActor
private final class OverviewSelectionTick: NSObject {
    weak var owner: SimilarPhotoOverviewSelectionAnchor?
    @objc func tick(_ link: CADisplayLink) {
        owner?.autoScroll(elapsed: link.targetTimestamp - link.timestamp)
    }
}

/// Adds range selection to the retained overview scroll view, not a second
/// scroll container. Hidden group members and +N covers are not in its scope.
@MainActor
final class SimilarPhotoOverviewSelectionAnchor: UIView, UIGestureRecognizerDelegate {
    private(set) lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private weak var scroll: UIScrollView?
    private var configuration: SimilarPhotoOverviewSelection?
    private var range: SimilarPhotoRangeSelection?
    private var token: UUID?
    private var provisionalIDs: Set<String>?
    private var finger: CGPoint?
    private var link: CADisplayLink?
    private let tick = OverviewSelectionTick()
    private var detached = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        tick.owner = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ next: SimilarPhotoOverviewSelection) {
        if configuration?.sessionID != next.sessionID || configuration?.photoIDs != next.photoIDs || !next.enabled {
            cancelInteraction()
        }
        configuration = next
        if token != nil && !next.isSelecting { discardPreview() }
        attach()
        pan.isEnabled = next.enabled && (!next.isSelecting || range != nil)
        DispatchQueue.main.async { [weak self] in self?.attach(); self?.refreshMarks() }
    }

    override func didMoveToWindow() { super.didMoveToWindow(); attach() }
    override func layoutSubviews() { super.layoutSubviews(); attach() }

    private func attach() {
        guard !detached, window != nil else { return }
        var candidate = superview
        while let view = candidate {
            if let target = view as? UIScrollView {
                if scroll !== target {
                    scroll?.removeGestureRecognizer(pan)
                    scroll = target
                    target.addGestureRecognizer(pan)
                    target.panGestureRecognizer.require(toFail: pan)
                }
                return
            }
            candidate = view.superview
        }
    }

    private func tiles() -> [SimilarPhotoPreviewControl] {
        guard let scroll else { return [] }
        var result: [SimilarPhotoPreviewControl] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            if let tile = view as? SimilarPhotoPreviewControl {
                if tile.convert(tile.bounds, to: scroll).intersects(scroll.bounds) { result.append(tile) }
            } else { view.subviews.forEach(visit) }
        }
        visit(scroll)
        return result
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scroll, let configuration, configuration.enabled, !configuration.isSelecting,
              SimilarPhotoGroupGridController.acceptsHorizontalStart(pan.velocity(in: scroll)) else { return false }
        let translation = pan.translation(in: scroll)
        let point = pan.location(in: scroll)
        let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
        return tiles().contains {
            configuration.photoIDs.contains($0.photoID) && $0.convert($0.bounds, to: scroll).contains(origin)
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let scroll else { return }
        let point = gesture.location(in: scroll)
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: scroll)
            let origin = CGPoint(x: point.x - translation.x, y: point.y - translation.y)
            guard let configuration, let tile = tiles().first(where: {
                configuration.photoIDs.contains($0.photoID) && $0.convert($0.bounds, to: scroll).contains(origin)
            }), let range = SimilarPhotoRangeSelection(photoIDs: configuration.photoIDs,
                selectedIDs: configuration.selectedIDs, anchorID: tile.photoID),
                let token = configuration.begin() else { return }
            self.range = range
            self.token = token
            provisionalIDs = range.selection(throughID: tile.photoID)
            let link = CADisplayLink(target: tick, selector: #selector(OverviewSelectionTick.tick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
            updateRange(at: point)
        case .changed: updateRange(at: point)
        case .ended:
            updateRange(at: point)
            link?.invalidate(); link = nil; finger = nil
            range = nil
            if let token, let provisionalIDs { configuration?.finish(token, provisionalIDs) }
        case .cancelled, .failed: cancelInteraction()
        default: break
        }
    }

    private func updateRange(at point: CGPoint) {
        guard let range, let scroll, let configuration else { return }
        finger = CGPoint(x: point.x - scroll.bounds.minX, y: point.y - scroll.bounds.minY)
        let candidates = tiles().filter { configuration.photoIDs.contains($0.photoID) }
        // Nearest visible ordinary tile bridges gutters/headers without giving
        // the overflow representative any selection authority.
        let nearest = candidates.min { lhs, rhs in
            func distance(_ tile: SimilarPhotoPreviewControl) -> CGFloat {
                let rect = tile.convert(tile.bounds, to: scroll)
                let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
                let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
                return dx * dx + dy * dy
            }
            return distance(lhs) < distance(rhs)
        }
        guard let nearest else { return }
        provisionalIDs = range.selection(throughID: nearest.photoID)
        refreshMarks()
    }

    private func refreshMarks() {
        guard let provisionalIDs, let configuration else { return }
        for tile in tiles() where configuration.photoIDs.contains(tile.photoID) {
            tile.updateSelectionMark(selected: provisionalIDs.contains(tile.photoID))
        }
    }

    func autoScroll(elapsed: TimeInterval) {
        guard range != nil, let scroll, let finger, elapsed > 0 else { return }
        let bounds = scroll.bounds
        let zone = min(bounds.height / 4, SimilarPhotoGroupGeometry.side(width: bounds.width))
        guard zone > 0 else { return }
        let penetration = finger.y < zone ? -min(1, (zone - finger.y) / zone)
            : finger.y > bounds.height - zone ? min(1, (finger.y - bounds.height + zone) / zone) : 0
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum, scroll.contentSize.height - bounds.height + scroll.adjustedContentInset.bottom)
        let distance = min(zone, CGFloat(elapsed) * bounds.height) * penetration
        let y = min(maximum, max(minimum, bounds.minY + distance))
        guard y != bounds.minY else { return }
        scroll.setContentOffset(CGPoint(x: bounds.minX, y: y), animated: false)
        scroll.layoutIfNeeded()
        updateRange(at: CGPoint(x: bounds.minX + finger.x, y: y + finger.y))
    }

    private func discardPreview() {
        link?.invalidate(); link = nil; finger = nil
        range = nil; token = nil; provisionalIDs = nil
        for tile in tiles() { tile.updateSelectionMark(selected: configuration?.selectedIDs.contains(tile.photoID) == true) }
    }
    private func cancelInteraction() {
        let active = token != nil
        discardPreview()
        if active { configuration?.cancel() }
    }
    func detach() {
        detached = true
        cancelInteraction()
        scroll?.removeGestureRecognizer(pan)
        scroll = nil
        configuration = nil
    }
}
