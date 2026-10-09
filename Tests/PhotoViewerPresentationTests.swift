import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Native layout and task-lifecycle checks with synthetic pixels only. These are
/// not physical-phone/PhotoKit-quality or XCUI gesture/VoiceOver acceptance tests.
@MainActor
final class PhotoViewerPresentationTests: XCTestCase {
    func testDefaultGridIsFiveSquareColumnsWithThreePointGapsAt320And393() async throws {
        let widths: [CGFloat] = [320, 393]
        let types: [DynamicTypeSize] = [.large, .accessibility5]
        for width in widths {
            for type in types {
                try await checkGrid(width: width, type: type, compact: nil, columns: 5, gap: 3, aspect: 1)
            }
        }
    }

    func testExplicitCompactCallerKeepsSignatureAndUsesFiveColumns() async throws {
        try await checkGrid(width: 320, type: .large, compact: true, columns: 5, gap: 3, aspect: 1)
    }

    func testExplicitNoncompactLegacyCallerKeepsTwoColumnAspect() async throws {
        try await checkGrid(width: 393, type: .large, compact: false, columns: 2, gap: 6, aspect: 4.0 / 5.0)
    }

    func testPageChangeCancelsOldRequestAndLateOldPixelsCannotReplaceCurrentHQ224() async throws {
        let first = expectation(description: "First page requested")
        let second = expectation(description: "Second page requested")
        let requests = ViewerPresentationRequests(onRequest: { id in
            if id == "a" { first.fulfill() } else if id == "b" { second.fulfill() }
        })
        let model = ViewerPresentationModel()
        let host = try mount(ViewerPresentationHarness(model: model, source: requests.source), width: 393)
        defer { requests.clear(); host.close() }
        try await wait(first)
        model.ids = ["b"] // Real viewer selection reconciliation; not a simulated swipe claim.
        try await wait(second)
        requests.complete("b", image: solid(.blue))
        try await rendered(host, blue: true)
        XCTAssertEqual(requests.cancelledPhotoIDs, ["a"])
        requests.complete("a", image: solid(.red))
        try await rendered(host, blue: true)
        XCTAssertEqual(requests.requestedPhotoIDs, ["a", "b"])
        XCTAssertEqual(requests.plans.map(\.delivery), [.highQualityFormat, .highQualityFormat])
        XCTAssertEqual(requests.plans.map(\.network), [false, false])
        XCTAssertEqual(requests.plans.map(\.size), [CGSize(width: 224, height: 448), CGSize(width: 224, height: 448)])
    }

    func testRemovingViewerCancelsPendingRequestAndLateCallbackDoesNotRestorePixels() async throws {
        let entered = expectation(description: "Viewer request started")
        let cancelled = expectation(description: "Viewer request cancelled on removal")
        let requests = ViewerPresentationRequests(onRequest: { _ in entered.fulfill() }, onCancel: { cancelled.fulfill() })
        let model = ViewerPresentationModel()
        let host = try mount(ViewerPresentationHarness(model: model, source: requests.source), width: 393)
        defer { requests.clear(); host.close() }
        try await wait(entered)
        model.shown = false
        try await wait(cancelled)
        requests.complete("a", image: solid(.red))
        try await rendered(host, blue: false)
        XCTAssertEqual(requests.requestedPhotoIDs, ["a"])
        XCTAssertEqual(requests.cancelledPhotoIDs, ["a"])
    }

    private func checkGrid(width: CGFloat, type: DynamicTypeSize, compact: Bool?, columns: Int,
                           gap: CGFloat, aspect: CGFloat) async throws {
        let count = compact == false ? 6 : 12
        let hits = (0..<count).map { index in
            SearchHit(photo: IndexedPhoto(id: "grid-\(index)", modificationTime: 10, modelVersion: "viewer-test",
                                         imageEmbedding: TestFixtures.vector(), creationTime: 5), score: Float(12 - index))
        }
        let layout = ViewerGridLayout()
        let content = ViewerGridHarness(hits: hits, compact: compact, layout: layout)
            .environment(\.dynamicTypeSize, type)
        let host = try mount(content, width: width)
        defer { host.close() }
        try await onFrames(host) { layout.frames.count == hits.count }
        let first = try XCTUnwrap(layout.frames[hits[0].id])
        let tolerance = 1 / host.window.screen.scale
        XCTAssertEqual(Set(layout.frames.keys), Set(hits.map(\.id)))
        for (index, hit) in hits.enumerated() {
            let frame = try XCTUnwrap(layout.frames[hit.id])
            XCTAssertGreaterThanOrEqual(frame.width, 44, "Entire tile remains the selection target, not only its marker")
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertEqual(frame.width / frame.height, aspect, accuracy: 0.01)
            XCTAssertEqual(frame.minX, first.minX + CGFloat(index % columns) * (first.width + gap), accuracy: tolerance)
            XCTAssertEqual(frame.minY, first.minY + CGFloat(index / columns) * (first.height + gap), accuracy: tolerance)
            XCTAssertGreaterThanOrEqual(frame.minX, -tolerance)
            XCTAssertLessThanOrEqual(frame.maxX, width - 40 + tolerance)
        }
        // The production thumbnail closure/order is retained; selection markers
        // are overlays and must not enlarge or clip the five-column layout.
        let image = try host.capture()
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-search-grid-\(columns)-\(Int(width))-\(String(describing: type))"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rendered(_ host: ViewerNativeHost, blue: Bool) async throws {
        try await onFrames(host) {
            let counts = try self.colorCounts(host.capture())
            return counts.red == 0 && (blue ? counts.blue > 1000 : counts.blue == 0)
        }
    }

    private func colorCounts(_ image: UIImage) throws -> (red: Int, blue: Int) {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var red = 0
        var blue = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[i] > 240, bytes[i + 1] < 16, bytes[i + 2] < 16 { red += 1 }
            if bytes[i + 2] > 240, bytes[i] < 16, bytes[i + 1] < 16 { blue += 1 }
        }
        return (red, blue)
    }

    private func solid(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: 224, height: 448), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 224, height: 448))
        }
    }

    private func mount<V: View>(_ content: V, width: CGFloat) throws -> ViewerNativeHost {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let root = content.environment(\.scenePhase, .active)
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        return ViewerNativeHost(scene: scene, root: AnyView(root), width: width)
    }

    private func wait(_ event: XCTestExpectation) async throws {
        guard await XCTWaiter.fulfillment(of: [event], timeout: 5) == .completed else {
            XCTFail("Native fixture event not reached: \(event.expectationDescription)")
            throw ViewerPresentationFailure.event
        }
    }

    private func onFrames(_ host: ViewerNativeHost, predicate: @escaping () throws -> Bool) async throws {
        let event = expectation(description: "Native viewer/grid rendered expected state")
        var output: Result<Void, Error>?
        var sampling = false
        let driver = ViewerFrameDriver {
            guard output == nil, !sampling else { return }
            sampling = true
            defer { sampling = false }
            do {
                host.layout()
                guard try predicate() else { return }
                output = .success(())
                event.fulfill()
            } catch { output = .failure(error); event.fulfill() }
        }
        let link = CADisplayLink(target: driver, selector: #selector(ViewerFrameDriver.tick))
        defer { link.invalidate() }
        link.add(to: .main, forMode: .common)
        try await wait(event)
        try XCTUnwrap(output).get()
    }
}

private enum ViewerPresentationFailure: Error { case event }

@MainActor
private final class ViewerGridLayout {
    var frames: [String: CGRect] = [:]
}

private struct ViewerGridFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

@MainActor
private struct ViewerGridHarness: View {
    let hits: [SearchHit]
    let compact: Bool?
    let layout: ViewerGridLayout

    var body: some View {
        ScrollView {
            Group {
                if let compact {
                    PhotoResultsGrid(hits: hits, compact: compact, onSelect: { _ in },
                                     selectionMode: true, selectedIDs: [hits[0].id], thumbnail: thumbnail)
                } else {
                    PhotoResultsGrid(hits: hits, onSelect: { _ in },
                                     selectionMode: true, selectedIDs: [hits[0].id], thumbnail: thumbnail)
                }
            }
            .coordinateSpace(name: "viewer-grid")
            .onPreferenceChange(ViewerGridFrames.self) { if !$0.isEmpty { layout.frames = $0 } }
            .padding(.horizontal, 20)
        }
    }

    private func thumbnail(_ photo: IndexedPhoto) -> some View {
        Color.gray.background {
            GeometryReader { geometry in
                Color.clear.preference(key: ViewerGridFrames.self,
                                       value: [photo.id: geometry.frame(in: .named("viewer-grid"))])
            }
        }
    }
}

@MainActor
private final class ViewerPresentationModel: ObservableObject {
    @Published var ids = ["a", "b"]
    @Published var shown = true
}

@MainActor
private struct ViewerPresentationHarness: View {
    @ObservedObject var model: ViewerPresentationModel
    let source: PhotoViewerImageSource
    // Construction only; all image/validation calls use source. Do not claim
    // this spies on PHImageManager.default() initialization itself.
    private let library = PhotoLibraryClient()

    var body: some View {
        if model.shown {
            PhotoGalleryViewer(ids: model.ids, initialID: "a", library: library,
                               networkAllowed: true, imageSource: source)
        } else { Color.black }
    }
}

private final class ViewerPresentationRequests: @unchecked Sendable {
    struct Plan {
        let size: CGSize
        let delivery: PHImageRequestOptionsDeliveryMode
        let network: Bool
    }
    private let lock = NSLock()
    private let onRequest: @Sendable (String) -> Void
    private let onCancel: @Sendable () -> Void
    private var callbacks: [String: DisplayThumbnailLoader.Callback] = [:]
    private var requested: [String] = []
    private var cancelled: [String] = []
    private var storedPlans: [Plan] = []
    var requestedPhotoIDs: [String] { locked { requested } }
    var cancelledPhotoIDs: [String] { locked { cancelled } }
    var plans: [Plan] { locked { storedPlans } }

    init(onRequest: @escaping @Sendable (String) -> Void, onCancel: @escaping @Sendable () -> Void = {}) {
        self.onRequest = onRequest
        self.onCancel = onCancel
    }

    var source: PhotoViewerImageSource {
        PhotoViewerImageSource(load: { [self] id, network in
            let snapshot = PhotoViewerSnapshot(revision: PhotoRevision(id: id, modificationTime: 10, creationTime: 5),
                                               authorization: .authorized, generation: 3)
            let result = try await PhotoViewerImageLoader.load(pixelWidth: 1200, pixelHeight: 2400,
                networkAllowed: network, request: { [self] size, mode, options, callback in
                    XCTAssertEqual(mode, .aspectFit)
                    let requestID = locked {
                        requested.append(id)
                        callbacks[id] = callback
                        storedPlans.append(Plan(size: size, delivery: options.deliveryMode, network: options.isNetworkAccessAllowed))
                        return PHImageRequestID(requested.count)
                    }
                    onRequest(id)
                    return requestID
                }, cancel: { [self] requestID in
                    locked { cancelled.append(requested[Int(requestID) - 1]) }
                    onCancel()
                }, validate: {})
            return PhotoViewerImage(snapshot: snapshot, result: result)
        }, validate: { snapshot in
            try snapshot.validate(id: snapshot.revision.id, authorization: { .authorized },
                                  generation: { 3 }, currentRevision: { _ in snapshot.revision })
        })
    }

    func complete(_ id: String, image: UIImage) {
        let callback = locked { callbacks[id] }
        XCTAssertNotNil(callback)
        callback?(image, [PHImageResultIsDegradedKey: false])
    }

    func clear() { locked { callbacks.removeAll() } }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

@MainActor
private final class ViewerNativeHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private weak var previous: UIWindow?
    init(scene: UIWindowScene, root: AnyView, width: CGFloat) {
        previous = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 852)
        controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }
    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }
    func capture() throws -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds, format: format).image { _ in
            drawn = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        return image
    }
}

@MainActor
private final class ViewerFrameDriver: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}