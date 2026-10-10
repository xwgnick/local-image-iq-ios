import Foundation
import Combine
import UIKit

struct PhotoViewerAsset: Sendable, Equatable {
    let snapshot: PhotoViewerSnapshot
    /// PhotoKit's displayed asset dimensions; rendition raster orientation is
    /// applied separately when comparing actual returned pixels.
    let pixelSize: CGSize
}

enum PhotoViewerResolution {
    /// Whole-image aspect fit, physical display scale, and user zoom. The only
    /// ceiling is the asset itself: no 2048/4096 limit or fixed 4x request cap.
    static func target(asset: CGSize, viewport: CGSize, displayScale: CGFloat, zoom: CGFloat) -> CGSize? {
        guard asset.width.isFinite, asset.height.isFinite, asset.width > 0, asset.height > 0,
              zoom.isFinite, zoom >= 1,
              let display = DisplayThumbnailLoader.targetSize(points: viewport, displayScale: displayScale) else { return nil }
        let fit = min(display.width / asset.width, display.height / asset.height)
        // Divide before multiplying, so even an extreme finite zoom cannot overflow.
        let fraction = fit >= 1 / zoom ? CGFloat(1) : fit * zoom
        return CGSize(width: min(asset.width, max(1, (asset.width * fraction).rounded(.up))),
                      height: min(asset.height, max(1, (asset.height * fraction).rounded(.up))))
    }

    static func orientedPixels(_ result: DisplayThumbnailResult) -> CGSize {
        switch result.image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: result.returnedSize.height, height: result.returnedSize.width)
        default: return result.returnedSize
        }
    }

    static func covers(_ result: DisplayThumbnailResult, _ target: CGSize) -> Bool {
        result.degraded != true && DisplayThumbnailResult.displayCoverage(returnedSize: result.returnedSize,
            orientation: result.image.imageOrientation, targetSize: target) >= 1
    }

    /// Never trade away actual detail in either axis merely because a request
    /// was named HQ or a raw degraded flag changed. Readable tiny fallback stays.
    static func prefers(_ candidate: DisplayThumbnailResult, over current: DisplayThumbnailResult) -> Bool {
        let next = orientedPixels(candidate)
        let old = orientedPixels(current)
        guard next.width >= old.width, next.height >= old.height else { return false }
        if candidate.degraded == true, current.degraded != true { return false }
        return next.width > old.width || next.height > old.height
            || (current.degraded == true && candidate.degraded != true)
    }
}

enum PhotoViewerShareQuality: String, Sendable {
    case preview = "分享预览"
    case highDefinition = "分享高清"

    static func classify(_ result: DisplayThumbnailResult, viewportTarget: CGSize?) -> Self {
        guard result.stage == .localHQ || result.stage == .networkHQ,
              let viewportTarget, PhotoViewerResolution.covers(result, viewportTarget),
              min(PhotoViewerResolution.orientedPixels(result).width,
                  PhotoViewerResolution.orientedPixels(result).height) > 224 else { return .preview }
        return .highDefinition
    }
}

/// Pixel-only copy created at the tap, never a later rendition or original file.
struct PhotoViewerShareRendition: Identifiable {
    let id = UUID()
    let snapshot: PhotoViewerSnapshot
    let image: UIImage
    let quality: PhotoViewerShareQuality
}

/// The same object survives UIImage replacement. Zoom changes only through
/// gestures/reset or a new page identity, never through success/failure/cancel.
@MainActor
final class PhotoViewerZoomState: ObservableObject {
    @Published private(set) var scale: CGFloat = 1

    func magnify(by factor: CGFloat) {
        let next = scale * factor
        guard next.isFinite, factor > 0 else { return }
        scale = max(1, next)
    }

    func reset() { scale = 1 }
}

@MainActor
final class PhotoViewerHDState: ObservableObject {
    enum Phase: Equatable {
        case idle, preview, local, cloud, cancelling, cancelled, needsCloud, failed, access
    }

    struct Consent: Identifiable, Equatable {
        let id: UUID
        let session: UUID
        let asset: PhotoViewerAsset
        let target: CGSize
    }

    @Published private(set) var selectedID = ""
    @Published private(set) var photo: PhotoViewerImage?
    @Published private(set) var asset: PhotoViewerAsset?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var issue: PhotoPreviewIssue?
    @Published private(set) var consent: Consent?
    private let source: PhotoViewerImageSource
    private var session = UUID()
    private var token = UUID()
    // Retain a cancelled predecessor until it drains, even across close/reopen.
    private var work: Task<Void, Never>?
    @Published private var viewport = CGSize.zero
    @Published private var displayScale: CGFloat = 1
    @Published private(set) var zoom: CGFloat = 1
    // An unfinished/cancelled request is not evidence that local pixels were
    // exhausted. Keep queued work separate from completed attempts.
    private var pendingLocalTarget: CGSize?
    private var lastCompletedLocalTarget: CGSize?
    private enum AuthorityError: Error { case changed }

    init(source: PhotoViewerImageSource) { self.source = source }

    var isWorking: Bool { phase == .preview || phase == .local || phase == .cloud || phase == .cancelling }
    var canRequestCloud: Bool {
        guard asset != nil, source.upgrade != nil, let target, !isWorking, phase != .access else { return false }
        return photo.map { !PhotoViewerResolution.covers($0.result, target) } ?? true
    }
    var shareQuality: PhotoViewerShareQuality {
        guard let photo else { return .preview }
        return .classify(photo.result, viewportTarget: viewportTarget)
    }
    private var target: CGSize? { resolution(zoom: zoom) }
    private var viewportTarget: CGSize? { resolution(zoom: 1) }
    private func resolution(zoom: CGFloat) -> CGSize? {
        guard let asset else { return nil }
        return PhotoViewerResolution.target(asset: asset.pixelSize, viewport: viewport, displayScale: displayScale, zoom: zoom)
    }

    func open(id: String) {
        session = UUID()
        selectedID = id
        photo = nil
        asset = nil
        issue = nil
        consent = nil
        zoom = 1
        lastCompletedLocalTarget = nil
        guard !id.isEmpty else { stop(); return }
        phase = .preview
        enqueue { owner, ticket in
            do {
                owner.asset = try owner.source.asset?(id)
                if let asset = owner.asset { try owner.validate(asset.snapshot, id: id) }
                // The legacy loader is unchanged; this progressive UI always
                // starts offline, regardless of the global indexing option.
                let first = try await owner.source.load(id, false)
                try owner.check(ticket)
                try owner.validate(first.snapshot, id: id)
                if let asset = owner.asset {
                    guard owner.same(first.snapshot, asset.snapshot) else { throw AuthorityError.changed }
                }
                owner.photo = first
                owner.issue = nil
                owner.phase = .idle
                await owner.loadLocalIfNeeded(ticket: ticket)
            } catch {
                owner.handle(error, ticket: ticket, initial: true)
                // A valid metadata snapshot allows explicit single-photo cloud
                // consent even if HQ224 and Fast both supplied no local pixels.
            }
        }
    }

    func updateViewport(_ viewport: CGSize, displayScale: CGFloat) {
        updateDemand(viewport: viewport, displayScale: displayScale, zoom: zoom)
    }

    func updateDemand(viewport: CGSize, displayScale: CGFloat, zoom: CGFloat) {
        guard DisplayThumbnailLoader.targetSize(points: viewport, displayScale: displayScale) != nil,
              zoom.isFinite, zoom >= 1 else { return }
        if self.viewport != viewport { self.viewport = viewport }
        if self.displayScale != displayScale { self.displayScale = displayScale }
        if self.zoom != zoom { self.zoom = zoom }
        guard photo != nil, phase != .preview, phase != .cloud, phase != .cancelling,
              phase != .access, consent == nil, needsLocalRequest,
              pendingLocalTarget != target else {
            return
        }
        if phase != .local {
            phase = .local
        }
        enqueue { owner, ticket in await owner.loadLocalIfNeeded(ticket: ticket) }
        pendingLocalTarget = target
    }

    private var needsLocalRequest: Bool {
        guard source.upgrade != nil, let target else { return false }
        if let photo, PhotoViewerResolution.covers(photo.result, target) { return false }
        if let previous = lastCompletedLocalTarget, previous.width >= target.width, previous.height >= target.height { return false }
        return true
    }

    private func loadLocalIfNeeded(ticket: UUID) async {
        guard needsLocalRequest, let asset, let target else {
            pendingLocalTarget = nil
            if phase != .idle { phase = .idle }
            return
        }
        pendingLocalTarget = target
        if phase != .local { phase = .local }
        let completed = await loadUpgrade(asset: asset, target: target, cloud: false, ticket: ticket)
        guard ticket == token, !Task.isCancelled else { return }
        pendingLocalTarget = nil
        // Success (including undersized pixels) and ordinary failure exhaust
        // this attempt; cancellation/access invalidation never do.
        if completed { lastCompletedLocalTarget = target }
    }

    /// Opening/cancelling the dialog performs no request and grants no permission.
    func requestCloudConfirmation() {
        guard canRequestCloud, let asset, let target, recheckAccess() else { return }
        consent = Consent(id: UUID(), session: session, asset: asset, target: target)
    }

    func dismissCloudConfirmation() { consent = nil }

    func confirmCloud(_ approved: Consent) {
        guard consent == approved, approved.session == session, let asset,
              same(asset.snapshot, approved.asset.snapshot),
              selectedID.utf8.elementsEqual(approved.asset.snapshot.revision.id.utf8) else { return }
        consent = nil // Consume once. Retry, page change, zoom and reopen need a NEW approval.
        guard recheckAccess() else { return }
        phase = .cloud
        enqueue { owner, ticket in
            _ = await owner.loadUpgrade(asset: approved.asset, target: approved.target, cloud: true, ticket: ticket)
            // A zoom during this request cannot expand its cloud permission.
            // If it needs more pixels, only a new LOCAL request may follow.
            if ticket == owner.token, !Task.isCancelled, owner.phase != .access,
               let current = owner.target,
               (current.width > approved.target.width || current.height > approved.target.height),
               owner.needsLocalRequest {
                await owner.loadLocalIfNeeded(ticket: ticket)
            }
        }
    }

    private func loadUpgrade(asset: PhotoViewerAsset, target: CGSize, cloud: Bool, ticket: UUID) async -> Bool {
        guard let upgrade = source.upgrade else { return false }
        do {
            try check(ticket)
            try validate(asset.snapshot, id: selectedID)
            let next = try await upgrade(asset, target, cloud)
            try check(ticket)
            try validate(asset.snapshot, id: selectedID)
            try validate(next.snapshot, id: selectedID)
            guard same(next.snapshot, asset.snapshot) else { throw AuthorityError.changed }
            if let current = photo {
                if PhotoViewerResolution.prefers(next.result, over: current.result) { photo = next }
            } else { photo = next }
            issue = nil
            phase = photo.map { PhotoViewerResolution.covers($0.result, target) } == true ? .idle : .needsCloud
            return true
        } catch {
            handle(error, ticket: ticket, initial: false)
            return ticket == token && !Task.isCancelled && !(error is CancellationError) && phase != .access
        }
    }

    /// Cancellation revokes publication immediately, but retains a drain task.
    /// Neither cancellation nor a download error resets image/zoom or starts retry.
    func cancelUpgrade() {
        guard isWorking, phase != .cancelling else { return }
        consent = nil
        work?.cancel()
        phase = .cancelling
        enqueue { owner, _ in owner.phase = .cancelled }
    }

    func stop() {
        session = UUID()
        token = UUID()
        work?.cancel()
        pendingLocalTarget = nil
        lastCompletedLocalTarget = nil
        consent = nil
        photo = nil
        asset = nil
        issue = nil
        phase = .idle
    }

    @discardableResult
    func recheckAccess() -> Bool {
        guard let snapshot = asset?.snapshot ?? photo?.snapshot else { return phase != .access }
        do { try validate(snapshot, id: selectedID); return true }
        catch { invalidateAccess(); return false }
    }

    func makeShareRendition() -> PhotoViewerShareRendition? {
        guard let photo, recheckAccess() else { return nil }
        let quality = shareQuality
        let rendered = PhotoShareSheet.renderedCopy(of: photo.result.image)
        guard recheckAccess(), same(photo.snapshot, self.photo?.snapshot) else { return nil }
        return PhotoViewerShareRendition(snapshot: photo.snapshot, image: rendered, quality: quality)
    }

    func isCurrent(_ snapshot: PhotoViewerSnapshot) -> Bool {
        do { try validate(snapshot, id: selectedID); return true }
        catch { return false }
    }

    func waitForCurrentWork() async { await work?.value }

    private func invalidateAccess() {
        stop()
        phase = .access
        issue = .access
    }

    private func validate(_ snapshot: PhotoViewerSnapshot, id: String) throws {
        guard snapshot.revision.id.utf8.elementsEqual(id.utf8) else { throw AuthorityError.changed }
        try source.validate(snapshot)
    }

    private func same(_ lhs: PhotoViewerSnapshot, _ rhs: PhotoViewerSnapshot?) -> Bool {
        guard let rhs else { return false }
        return lhs == rhs && lhs.revision.id.utf8.elementsEqual(rhs.revision.id.utf8)
    }

    private func check(_ ticket: UUID) throws {
        try Task.checkCancellation()
        guard ticket == token else { throw CancellationError() }
    }

    private func handle(_ error: Error, ticket: UUID, initial: Bool) {
        guard ticket == token, !Task.isCancelled else { return }
        guard recheckAccess() else { return }
        if let failure = error as? AppFailure, case .permission = failure { invalidateAccess(); return }
        if error is AuthorityError {
            invalidateAccess()
            return
        }
        if error is CancellationError {
            phase = .cancelled
            if initial { issue = .unavailable }
            return
        }
        if initial { issue = PhotoPreviewIssue(error: error) }
        if let failure = error as? AppFailure, case .cloudOnly = failure { phase = .needsCloud }
        else { phase = .failed }
    }

    private func enqueue(_ operation: @escaping @MainActor (PhotoViewerHDState, UUID) async -> Void) {
        work?.cancel()
        pendingLocalTarget = nil
        let previous = work
        let ticket = UUID()
        token = ticket
        work = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.token == ticket else { return }
            await operation(self, ticket)
            if self.token == ticket { self.work = nil }
        }
    }
}