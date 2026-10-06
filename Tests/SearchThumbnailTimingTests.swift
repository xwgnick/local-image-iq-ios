import XCTest
import SwiftUI
import UIKit
import Combine
import ImageIQCore
@testable import LocalImageIQ

/// Real PhotoThumbnailView tasks in a native window, with synthetic pixels and
/// immutable provider metadata. No Photos, AppState, models, network or attachments.
@MainActor
final class SearchThumbnailTimingTests: XCTestCase {
    func testNewSessionIdentityReportsFirstLoadedAgainFromCacheWithoutAnotherPixelRequest() async throws {
        let pixels = CGSize(width: 400, height: 500)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: pixels, format: format).image { context in
            UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: pixels))
        }
        let cg = try XCTUnwrap(image.cgImage)
        let result = DisplayThumbnailResult(image: image, stage: .localHQ, requestedSize: pixels,
            returnedSize: CGSize(width: cg.width, height: cg.height), degraded: false, targetSize: pixels)
        XCTAssertEqual(result.returnedSize, pixels)
        XCTAssertTrue(result.isSufficientForDisplay)
        XCTAssertTrue(result.isReusable, "A reduced/Fast fixture would turn identity changes into cache misses.")
        let provider = ThumbnailTimingProvider(result: result)
        let cache = PhotoThumbnailCache(library: provider)
        let state = ThumbnailTimingFixture()
        let firstSession = state.sessionID
        let firstLoaded = state.expectLoaded(firstSession)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let host = ThumbnailTimingHost(scene: scene, state: state, cache: cache)
        defer { host.close() }

        try await waitFor(firstLoaded)
        let firstFrame = try await renderedFrame(host, state: state)
        XCTAssertEqual(state.events, [firstSession])
        XCTAssertEqual(provider.plans.map(\.targetSize), [pixels])
        let firstHit = try await cache.thumbnail(id: state.photo.id, revision: state.photo.modificationTime,
                                                 targetSize: pixels, networkAllowed: false)
        XCTAssertTrue(firstHit.cacheHit, "The real view's first load must have populated the cache.")
        XCTAssertTrue(firstHit.result.isReusable)

        // Re-render the same identity without changing photo, geometry or cache.
        state.showDiagnostics = true
        let debugFrame = try await renderedFrame(host, state: state)
        XCTAssertEqual(debugFrame, firstFrame)
        XCTAssertEqual(state.events, [firstSession], "An ordinary parent update is not a new first image.")

        let nextSession = UUID()
        XCTAssertNotEqual(nextSession, firstSession)
        let nextLoaded = state.expectLoaded(nextSession)
        state.sessionID = nextSession
        XCTAssertEqual(state.events, [firstSession], "The old callback must not count as the new session's callback.")
        try await waitFor(nextLoaded)
        let nextFrame = try await renderedFrame(host, state: state)
        XCTAssertEqual(nextFrame, firstFrame, "Only session identity changed, not request geometry.")
        XCTAssertEqual(state.events, [firstSession, nextSession], "Check captured UUIDs, not just two callbacks.")
        XCTAssertEqual(provider.plans.count, 1, "The new view task must hit cache, not request more pixels.")
        let nextHit = try await cache.thumbnail(id: state.photo.id, revision: state.photo.modificationTime,
                                                targetSize: pixels, networkAllowed: false)
        XCTAssertTrue(nextHit.cacheHit)
        XCTAssertTrue(nextHit.result.isReusable)
        XCTAssertTrue(nextHit.result.image === firstHit.result.image)

        state.showDiagnostics = false
        let settledFrame = try await renderedFrame(host, state: state)
        XCTAssertEqual(settledFrame, firstFrame)
        XCTAssertEqual(state.events.filter { $0 == firstSession }.count, 1)
        XCTAssertEqual(state.events.filter { $0 == nextSession }.count, 1)
        XCTAssertEqual(state.events, [firstSession, nextSession])
        XCTAssertEqual(provider.plans.map(\.id), [state.photo.id])
        XCTAssertEqual(provider.plans.map(\.targetSize), [pixels])
        XCTAssertEqual(provider.plans.map(\.networkAllowed), [false])
    }

    private func waitFor(_ event: XCTestExpectation) async throws {
        let outcome = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        guard outcome == .completed else {
            XCTFail("Missing synthetic event: \(event.expectationDescription); waiter=\(outcome)")
            throw ThumbnailTimingFailure.eventNotObserved
        }
    }

    /// onLoaded precedes drawing. Wait for this parent revision's exact native
    /// geometry and a red image pixel (not a spinner/placeholder) in an actual
    /// hierarchy capture. Display ticks drive layout; the timeout is only a test
    /// failure bound, never a sleep, minimum delay or production timing assertion.
    private func renderedFrame(_ host: ThumbnailTimingHost, state: ThumbnailTimingFixture) async throws -> CGRect {
        let session = state.sessionID
        let revision = state.renderRevision
        let expected = CGRect(x: 16, y: 16, width: 200, height: 250)
        let rendered = XCTestExpectation(description: "Native thumbnail drawn for \(session), revision \(revision)")
        var active = true
        var sampling = false
        var matched: CGRect?
        var lastObservation = "No current layout"
        let driver = ThumbnailTimingFrameDriver {
            guard active, matched == nil, !sampling else { return }
            sampling = true
            defer { sampling = false }
            host.layout()
            guard let frame = host.frame, frame.sessionID == session, frame.revision == revision else { return }
            lastObservation = "Measured \(frame.rect), expected \(expected)"
            guard frame.rect == expected, let view = host.controller.view,
                  view.window === host.window, view.bounds.contains(frame.rect) else { return }
            let format = UIGraphicsImageRendererFormat()
            format.scale = host.window.screen.scale
            format.opaque = true
            format.preferredRange = .standard
            var drawn = false
            let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
                drawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            // Drawing can trigger layout: never pair a new capture with old geometry.
            guard drawn, host.frame == frame, state.sessionID == session,
                  state.renderRevision == revision else { return }
            lastObservation += "; native hierarchy drawn, waiting for synthetic red pixels"
            guard Self.hasRedCenter(image, frame: frame.rect) else { return }
            matched = frame.rect
            rendered.fulfill()
        }
        let link = CADisplayLink(target: driver, selector: #selector(ThumbnailTimingFrameDriver.tick))
        defer { active = false; link.invalidate() }
        link.add(to: .main, forMode: .common)
        let outcome = await XCTWaiter.fulfillment(of: [rendered], timeout: 5)
        guard outcome == .completed, let matched else {
            XCTFail("Native synthetic thumbnail did not settle: \(lastObservation); waiter=\(outcome)")
            throw ThumbnailTimingFailure.renderNotObserved
        }
        return matched
    }

    private static func hasRedCenter(_ image: UIImage, frame: CGRect) -> Bool {
        let x = frame.midX * image.scale, y = frame.midY * image.scale
        guard x == x.rounded(), y == y.rounded(),
              let pixel = image.cgImage?.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        var rgba = [UInt8](repeating: 0, count: 4)
        let decoded = rgba.withUnsafeMutableBytes { bytes -> Bool in
            let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: info) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return decoded && rgba == [255, 0, 0, 255]
    }
}

@MainActor
fileprivate final class ThumbnailTimingFixture: ObservableObject {
    @Published var sessionID = UUID() { didSet { renderRevision += 1 } }
    @Published var showDiagnostics = false { didSet { renderRevision += 1 } }
    private(set) var renderRevision = 0
    private(set) var events: [UUID] = []
    private var expectations: [UUID: XCTestExpectation] = [:]
    let photo = IndexedPhoto(id: "synthetic-session-thumbnail", modificationTime: 1,
                             modelVersion: "synthetic-thumbnail-timing", imageEmbedding: [1, 0])

    func expectLoaded(_ session: UUID) -> XCTestExpectation {
        let event = XCTestExpectation(description: "Actual onLoaded for session \(session)")
        event.assertForOverFulfill = true
        expectations[session] = event
        return event
    }

    func loaded(_ session: UUID) {
        events.append(session)
        expectations[session]?.fulfill()
    }
}

@MainActor
fileprivate struct ThumbnailTimingTile: View {
    @ObservedObject var state: ThumbnailTimingFixture
    let cache: PhotoThumbnailCache
    let onFrame: (ThumbnailTimingFrame?) -> Void

    var body: some View {
        // Same binding as ContentView: capture the UUID value, never read the
        // fixture's mutable current session from inside an old task's callback.
        let sessionID = state.sessionID
        let revision = state.renderRevision
        PhotoThumbnailView(photo: state.photo, cache: cache, networkAllowed: false,
                           showDiagnostics: state.showDiagnostics, onLoaded: { state.loaded(sessionID) })
            .id(sessionID)
            .frame(width: 200, height: 250)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ThumbnailTimingFrameKey.self, value:
                        ThumbnailTimingFrame(sessionID: sessionID, revision: revision,
                            rect: geometry.frame(in: .named("thumbnail-timing-host"))))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(name: "thumbnail-timing-host")
            .onPreferenceChange(ThumbnailTimingFrameKey.self, perform: onFrame)
            .ignoresSafeArea()
    }
}

fileprivate struct ThumbnailTimingFrame: Equatable {
    let sessionID: UUID
    let revision: Int
    let rect: CGRect
}

fileprivate struct ThumbnailTimingFrameKey: PreferenceKey {
    static let defaultValue: ThumbnailTimingFrame? = nil
    static func reduce(value: inout ThumbnailTimingFrame?, nextValue: () -> ThumbnailTimingFrame?) {
        if let next = nextValue() { value = next }
    }
}

/// Only the request log is mutable; synchronous access metadata stays immutable.
fileprivate final class ThumbnailTimingProvider: PhotoThumbnailProviding, @unchecked Sendable {
    struct Plan: Sendable {
        let id: String
        let targetSize: CGSize
        let networkAllowed: Bool
    }
    let canReadImages = true
    let changeGeneration: UInt64? = 0
    private let result: DisplayThumbnailResult
    private let lock = NSLock()
    private var recorded: [Plan] = []

    init(result: DisplayThumbnailResult) { self.result = result }
    var plans: [Plan] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    private func record(_ plan: Plan) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(plan)
    }
    func currentRevision(id: String) -> PhotoRevision? { PhotoRevision(id: id, modificationTime: 1) }
    func thumbnailImage(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> UIImage {
        throw ThumbnailTimingFailure.unexpectedImageOnlyRequest
    }
    func thumbnailResult(id: String, targetSize: CGSize, networkAllowed: Bool) async throws -> DisplayThumbnailResult {
        record(Plan(id: id, targetSize: targetSize, networkAllowed: networkAllowed))
        return result
    }
}

fileprivate enum ThumbnailTimingFailure: Error {
    case unexpectedImageOnlyRequest, eventNotObserved, renderNotObserved
}

@MainActor
fileprivate final class ThumbnailTimingFrameDriver: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func tick() { action() }
}

@MainActor
fileprivate final class ThumbnailTimingHost {
    let window: UIWindow
    let controller: UIHostingController<AnyView>
    private(set) var frame: ThumbnailTimingFrame?
    private weak var previousKeyWindow: UIWindow?

    init(scene: UIWindowScene, state: ThumbnailTimingFixture, cache: PhotoThumbnailCache) {
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .light
        controller = UIHostingController(rootView: AnyView(EmptyView()))
        controller.safeAreaRegions = []
        let root = ThumbnailTimingTile(state: state, cache: cache, onFrame: { [weak self] in self?.frame = $0 })
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            .environment(\.layoutDirection, .leftToRight)
            .transaction { $0.animation = nil }
        controller.rootView = AnyView(root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        layout()
    }

    func layout() {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        controller.rootView = AnyView(EmptyView())
        previousKeyWindow?.makeKey()
    }
}