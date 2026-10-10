import XCTest
import SwiftUI
import UIKit
import Photos
import Combine
@testable import LocalImageIQ

/// Native same-host pixel/identity checks, not simulated pinch or device Photos
/// acceptance. No network, credentials, original photo files or Photos writes.
@MainActor
final class PhotoViewerHDPresentationTests: XCTestCase {
    func testHDControlReservationSizeIsInvariantAcrossEligibilityAndStatus() throws {
        let phases: [PhotoViewerHDState.Phase] = [.idle, .preview, .local, .cloud, .cancelling,
                                                 .cancelled, .needsCloud, .failed, .access]
        let widths: [CGFloat] = [300, 600]
        let typeSizes: [DynamicTypeSize] = [.large, .accessibility3]
        for width in widths {
            for typeSize in typeSizes {
                var baseline: CGSize?
                for phase in phases {
                    for eligible in [false, true] {
                        for selected in [false, true] {
                            let controls = PhotoViewerHDControls(phase: phase, canRequestCloud: eligible,
                                isCurrentSelection: selected, onCancel: {}, onRequest: {})
                                .frame(width: width)
                                .fixedSize(horizontal: false, vertical: true)
                                .environment(\.dynamicTypeSize, typeSize)
                            let renderer = ImageRenderer(content: controls)
                            renderer.scale = 3
                            let raster = try XCTUnwrap(renderer.uiImage?.cgImage)
                            let size = CGSize(width: raster.width, height: raster.height)
                            XCTAssertGreaterThan(size.height, 0)
                            if let baseline {
                                XCTAssertEqual(size, baseline, "HD visibility/status must not change the reserved viewport")
                            } else { baseline = size }
                        }
                    }
                }
            }
        }
    }

    func testIntermediatePortraitWithRealHDInsetSettlesWithoutDemandPublicationLoop() async throws {
        let source = HDGalleryPresentationSource(onUpgrade: {})
        source.holdUpgrades = false
        source.autoImage = HDZoomPresentationModel.pattern(width: 860)
        let state = PhotoViewerHDState(source: source.source)
        state.updateViewport(CGSize(width: 300, height: 600), displayScale: 3)
        state.open(id: "a")
        await state.waitForCurrentWork()
        XCTAssertTrue(state.canRequestCloud, "860x1720 does not cover the uninset 900x1800 target")
        let recorder = HDControlViewportRecorder()
        let host = try HDZoomHost(content: HDControlCoverageHarness(state: state, recorder: recorder))
        defer { host.close(); state.stop(); source.drain() }
        await layoutFrames(host, count: 3) { !recorder.sizes.isEmpty && !state.canRequestCloud }
        let viewport = try XCTUnwrap(recorder.sizes.last)
        XCTAssertLessThan(viewport.height, 600)
        XCTAssertFalse(state.canRequestCloud, "The intermediate raster covers the stable reserved viewport")
        XCTAssertEqual(source.upgradeNetworks, [false])

        // Show/hide the real controls through pixel demand, not a mock flag.
        let zooms: [CGFloat] = [1, 2, 1]
        for zoom in zooms {
            state.updateDemand(viewport: viewport, displayScale: 3, zoom: zoom)
            await state.waitForCurrentWork()
            await layoutFrames(host, count: 3) { state.canRequestCloud == (zoom == 2) }
            XCTAssertEqual(recorder.sizes.last, viewport)
            XCTAssertTrue(recorder.sizes.allSatisfy { $0 == viewport })
            var publications = 0
            let subscription = state.objectWillChange.sink { publications += 1 }
            let requestCount = source.upgradeNetworks.count
            for _ in 0..<10 { state.updateDemand(viewport: viewport, displayScale: 3, zoom: zoom) }
            await layoutFrames(host, count: 12) { true }
            subscription.cancel()
            XCTAssertEqual(publications, 0, "Settled layout must not feed new published demands back into itself")
            XCTAssertEqual(source.upgradeNetworks.count, requestCount)
        }
        XCTAssertEqual(source.upgradeNetworks, [false, false], "Only the deliberate zoom may request more local pixels")
    }

    func testGalleryPublishesPreviewWhileAutomaticLocalViewportRequestIsHeld() async throws {
        let entered = expectation(description: "Actual gallery requested local viewport pixels")
        let source = HDGalleryPresentationSource(onUpgrade: { entered.fulfill() })
        let host = try HDZoomHost(content: PhotoGalleryViewer(ids: ["a"], initialID: "a",
            library: PhotoLibraryClient(), networkAllowed: true, imageSource: source.source))
        defer { host.close(); source.drain() }
        await fulfillment(of: [entered], timeout: 5)
        let preview = try await sample(host) { $0 > 1000 }
        XCTAssertEqual(source.initialNetworks, [false], "Global opt-in is not single-photo HD consent")
        XCTAssertEqual(source.upgradeNetworks, [false])
        let target = try XCTUnwrap(source.target)
        XCTAssertGreaterThan(target.width, 224)
        XCTAssertLessThanOrEqual(target.width, 1200)
        XCTAssertLessThanOrEqual(target.height, 2400)
        source.complete()
        _ = try await sample(host) { $0 > preview * 2 }
        XCTAssertEqual(source.upgradeNetworks, [false])
    }

    func testHigherResolutionUIImageReplacementRetainsActualZoomedRendering() async throws {
        let model = HDZoomPresentationModel()
        let originalZoom = model.proposedZoom
        let host = try HDZoomHost(content: HDZoomHarness(model: model))
        defer { host.close() }

        let initial = try await sample(host) { $0 > 1000 }
        originalZoom.magnify(by: 2)
        let zoomed = try await sample(host) { $0 > initial * 3 / 2 }
        // A newly constructed view proposes a fresh zoom object. StateObject
        // must retain the already mounted object's 2x scale at the SAME identity.
        model.proposedZoom = PhotoViewerZoomState()
        model.image = HDZoomPresentationModel.pattern(width: 448, background: .green)
        model.revision += 1
        _ = try await sample(host, requiresGreen: true) { $0 > initial * 3 / 2 }
        XCTAssertEqual(originalZoom.scale, 2)
        XCTAssertEqual(model.proposedZoom.scale, 1)
        originalZoom.reset()
        let reset = try await sample(host, requiresGreen: true) { $0 > 1000 && $0 < zoomed * 3 / 4 }
        XCTAssertEqual(Double(reset), Double(initial), accuracy: Double(initial) * 0.02,
                       "Explicit reset restores fit; rendition replacement did not reset it")
    }

    func testFailureCancelAndShareRebuildsKeepZoomWithoutReplacingTheImage() async throws {
        let model = HDZoomPresentationModel()
        let zoom = model.proposedZoom
        let host = try HDZoomHost(content: HDZoomHarness(model: model))
        defer { host.close() }
        let fit = try await sample(host) { $0 > 1000 }
        zoom.magnify(by: 2)
        _ = try await sample(host) { $0 > fit * 3 / 2 }
        let pixels = model.image
        for _ in 0..<3 {
            model.revision += 1 // Same view recomputation as status/share updates.
            _ = try await sample(host) { $0 > fit * 3 / 2 }
            XCTAssertTrue(model.image === pixels)
            XCTAssertEqual(zoom.scale, 2)
        }
    }

    private func layoutFrames(_ host: HDZoomHost, count: Int, matching: @escaping () -> Bool) async {
        let ready = expectation(description: "Native HD layout settled across display frames")
        var consecutive = 0
        var finished = false
        let driver = HDZoomFrameDriver {
            guard !finished else { return }
            host.layout()
            consecutive = matching() ? consecutive + 1 : 0
            if consecutive == count { finished = true; ready.fulfill() }
        }
        let link = CADisplayLink(target: driver, selector: #selector(HDZoomFrameDriver.tick))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        await fulfillment(of: [ready], timeout: 5)
    }

    private func sample(_ host: HDZoomHost, requiresGreen: Bool = false,
                        matching: @escaping (Int) -> Bool) async throws -> Int {
        let ready = expectation(description: "Native zoom rendering settled")
        var result: Result<Int, Error>?
        var sampling = false
        let driver = HDZoomFrameDriver {
            guard result == nil, !sampling else { return }
            sampling = true
            defer { sampling = false }
            do {
                host.layout()
                let image = host.capture()
                if requiresGreen, try self.colorPixels(image, channel: 1) < 1000 { return }
                let count = try self.colorPixels(image, channel: 0)
                if matching(count) { result = .success(count); ready.fulfill() }
            } catch { result = .failure(error); ready.fulfill() }
        }
        let link = CADisplayLink(target: driver, selector: #selector(HDZoomFrameDriver.tick))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func colorPixels(_ image: UIImage, channel: Int) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let otherChannel = (channel + 1) % 3
        let lastChannel = (channel + 2) % 3
        var matchingPixels = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let strongPrimary = bytes[index + channel] > 240
            let weakOther = bytes[index + otherChannel] < 16
            let weakLast = bytes[index + lastChannel] < 16
            if strongPrimary && weakOther && weakLast { matchingPixels += 1 }
        }
        return matchingPixels
    }
}

@MainActor
private final class HDControlViewportRecorder {
    var sizes: [CGSize] = []
}

@MainActor
private struct HDControlCoverageHarness: View {
    @ObservedObject var state: PhotoViewerHDState
    let recorder: HDControlViewportRecorder

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                Color.black
                    .task(id: [geometry.size.width, geometry.size.height]) {
                        recorder.sizes.append(geometry.size)
                        state.updateViewport(geometry.size, displayScale: 3)
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PhotoViewerHDControls(phase: state.phase, canRequestCloud: state.canRequestCloud,
                isCurrentSelection: true, onCancel: { state.cancelUpgrade() },
                onRequest: { state.requestCloudConfirmation() })
        }
        .frame(width: 300, height: 600)
    }
}

@MainActor
private final class HDZoomPresentationModel: ObservableObject {
    @Published var image = HDZoomPresentationModel.pattern(width: 224)
    @Published var proposedZoom = PhotoViewerZoomState()
    @Published var revision = 0

    static func pattern(width: Int, background: UIColor = .blue) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let width = CGFloat(width)
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: width * 2), format: format).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: width * 2))
            UIColor.red.setFill()
            context.fill(CGRect(x: width * 3 / 8, y: 0, width: width / 4, height: width * 2))
        }
    }
}

@MainActor
private struct HDZoomHarness: View {
    @ObservedObject var model: HDZoomPresentationModel

    var body: some View {
        PhotoFitZoomView(image: model.image, zoomState: model.proposedZoom)
            .accessibilityValue("Rendition \(model.revision)")
            .frame(width: 300, height: 600)
            .background(.black)
    }
}

@MainActor
private final class HDZoomHost {
    private let window: UIWindow
    private let controller: UIHostingController<AnyView>
    private weak var previous: UIWindow?

    init<V: View>(content: V) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        controller = UIHostingController(rootView: AnyView(content.environment(\.scenePhase, .active)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }

    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    func capture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
        }
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }
}

@MainActor
private final class HDZoomFrameDriver: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

@MainActor
private final class HDGalleryPresentationSource {
    let onUpgrade: () -> Void
    var holdUpgrades = true
    var autoImage: UIImage?
    private(set) var initialNetworks: [Bool] = []
    private(set) var upgradeNetworks: [Bool] = []
    private(set) var target: CGSize?
    private var pending: CheckedContinuation<PhotoViewerImage, Error>?
    private let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(id: "a", modificationTime: 1),
                                               authorization: .authorized, generation: 1)

    init(onUpgrade: @escaping () -> Void) { self.onUpgrade = onUpgrade }

    var source: PhotoViewerImageSource {
        PhotoViewerImageSource(load: { [self] _, network in
            await first(network: network)
        }, validate: { _ in }, asset: { [self] _ in
            MainActor.assumeIsolated {
                PhotoViewerAsset(snapshot: snapshot, pixelSize: CGSize(width: 1200, height: 2400))
            }
        }, upgrade: { [self] _, target, network in
            try await hold(target: target, network: network)
        })
    }

    private func first(network: Bool) -> PhotoViewerImage {
        initialNetworks.append(network)
        return rendition(HDZoomPresentationModel.pattern(width: 224), stage: .localHQ224)
    }

    private func hold(target: CGSize, network: Bool) async throws -> PhotoViewerImage {
        upgradeNetworks.append(network)
        self.target = target
        if !holdUpgrades {
            onUpgrade()
            return rendition(autoImage ?? HDZoomPresentationModel.pattern(width: 224), stage: .localHQ)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            onUpgrade()
        }
    }

    func complete() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 2400), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 2400))
        }
        let continuation = pending
        pending = nil
        XCTAssertNotNil(continuation)
        continuation?.resume(returning: rendition(image, stage: .localHQ))
    }

    func drain() {
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func rendition(_ image: UIImage, stage: DisplayThumbnailStage) -> PhotoViewerImage {
        let pixels = image.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        return PhotoViewerImage(snapshot: snapshot, result: DisplayThumbnailResult(image: image, stage: stage,
            requestedSize: target ?? pixels, returnedSize: pixels, degraded: false, targetSize: target ?? pixels))
    }
}