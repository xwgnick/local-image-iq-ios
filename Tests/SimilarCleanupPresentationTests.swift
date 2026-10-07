import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Four hosted tests, exactly two UIReview images. Mount the production sheet,
/// not ContentView or a replica of its cards. Only metadata/grouping/deletion
/// services are synthetic; the real thumbnail client must remain unauthorized.
/// No permission requests/resets, Photos pixels/writes, models, files or network.
/// Public UIKit scroll geometry and native captures are presentation evidence,
/// not private SwiftUI AX traversal or proof that every lazy tile is onscreen.
@MainActor
final class SimilarCleanupPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)

    func testRealGroupsAndThreePhotoSelectionDarkSnapshotsNeverDelete() async throws {
        let c = try await context()
        let host = try await mount(c)
        defer { host.close() }
        assertUnscanned(c.cleanup)
        XCTAssertEqual(c.cleanup.threshold, SimilarPhotoGroupingPolicy.defaultThreshold)
        assertServices(c, scans: 0)

        // Only this explicit controller action obtains the fixture groups.
        c.cleanup.scan()
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(c.cleanup.hasScanned)
        XCTAssertEqual(c.cleanup.groups.map { $0.photos.count }, [4, 3, 2])
        XCTAssertTrue(c.cleanup.selectedIDs.isEmpty, "There is no automatic keeper/deletion selection")
        XCTAssertNil(c.cleanup.pendingDeletion)
        _ = try scrollView(in: host)
        let normal = try capture(host)
        attach(normal, name: "UIReview-similar-cleanup-groups-dark")
        assertServices(c, scans: 1)

        let groups = c.grouping.groups
        let selected = [groups[0].photos[0], groups[0].photos[1], groups[1].photos[0]]
        for photo in selected { c.cleanup.toggleSelection(photo.id) }
        XCTAssertEqual(c.cleanup.orderedSelectedPhotos.map(\.id), selected.map(\.id))
        XCTAssertEqual(c.cleanup.selectedCount, 3)
        // Public controller preparation is not a tap on the sheet's private
        // dialog binding. Render the actual "已选3张" / "删除3张" toolbar without
        // opening a confirmation or ever calling confirmDeletion.
        c.cleanup.prepareDeletion()
        let intent = try XCTUnwrap(c.cleanup.pendingDeletion)
        XCTAssertEqual(intent.count, 3)
        XCTAssertEqual(intent.emptiedGroupCount, 0)
        XCTAssertEqual(intent.revisions, selected.map {
            PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime)
        })
        try await settle(host)
        _ = try scrollView(in: host)
        let selection = try capture(host)
        attach(selection, name: "UIReview-similar-cleanup-selection-dark")
        XCTAssertNotEqual(try XCTUnwrap(normal.pngData()), try XCTUnwrap(selection.pngData()),
                          "Selection must change the same real sheet's native rendering")
        XCTAssertEqual(c.cleanup.pendingDeletion?.id, intent.id)
        XCTAssertFalse(c.cleanup.isDeleting)
        assertServices(c, scans: 1)
        // No pixel-perfect round trip: navigation/thumbnail layout is not a golden.
        // The covers are visual previews. This does not assert that every
        // thumbnail/control was captured or that thumbnail taps select photos.
    }

    func testExplicitEmptyResultRendersWithoutAutomaticScanOrDeletion() async throws {
        let c = try await context(empty: true)
        let host = try await mount(c)
        defer { host.close() }
        assertUnscanned(c.cleanup)
        assertServices(c, scans: 0)
        _ = try scrollView(in: host)
        let initial = try capture(host)

        c.cleanup.scan()
        await c.cleanup.waitUntilIdle()
        try await settle(host)
        XCTAssertTrue(c.cleanup.hasScanned, "A completed empty result is different from an unopened scan")
        XCTAssertTrue(c.cleanup.groups.isEmpty)
        XCTAssertTrue(c.cleanup.selectedIDs.isEmpty)
        XCTAssertNil(c.cleanup.pendingDeletion)
        XCTAssertNil(c.cleanup.message)
        _ = try scrollView(in: host)
        let empty = try capture(host)
        XCTAssertNotEqual(try XCTUnwrap(initial.pngData()), try XCTUnwrap(empty.pngData()),
                          "The production empty-result summary must change the initial presentation")
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        assertServices(c, scans: 1)
        // No third review attachment and no private-AX assertion about text.
    }

    func testMaximumFontKeepsRealSheetVerticallyScrollableWithoutHorizontalContentOverflow() async throws {
        // Compact covers intentionally no longer create one long grid per
        // group. Many groups exercise real overview scrolling at maximum font.
        let c = try await context(groupSizes: Array(repeating: 3, count: 12))
        let size = CGSize(width: 320, height: 852)
        let host = try await mount(c, size: size, dynamicType: .accessibility5)
        defer { host.close() }
        c.cleanup.scan()
        await c.cleanup.waitUntilIdle()
        c.cleanup.toggleSelection(c.grouping.groups[0].photos[0].id)
        try await settle(host)

        // Render the real lazy hierarchy before measuring its scrolling extent.
        // Initial layout preferences can still precede realised group rows.
        _ = try capture(host)
        try await settle(host)
        XCTAssertEqual(host.window.bounds.size, size)
        XCTAssertEqual(host.controller.view.bounds.size, size)
        let scroll = try scrollView(in: host)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        let viewport = scroll.convert(scroll.bounds, to: host.controller.view)
        let origin = scroll.contentOffset
        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        let distance = bottom - origin.y
        XCTAssertGreaterThan(distance, 0)
        let beforeGeometry = "bounds=\(scroll.bounds); content=\(scroll.contentSize); inset=\(scroll.adjustedContentInset); origin=\(origin); bottom=\(bottom)"
        scroll.setContentOffset(CGPoint(x: origin.x, y: origin.y + distance), animated: false)
        let immediateOffset = scroll.contentOffset
        try await settle(host)
        let geometry = XCTAttachment(string: "\(beforeGeometry); immediate=\(immediateOffset); settled=\(scroll.contentOffset); contentAfter=\(scroll.contentSize)")
        geometry.name = "Cleanup maximum-font native scroll geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertGreaterThan(scroll.contentOffset.y, origin.y, "\(beforeGeometry); immediate=\(immediateOffset); settled=\(scroll.contentOffset)")
        XCTAssertEqual(scroll.contentOffset.x, origin.x)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertEqual(scroll.convert(scroll.bounds, to: host.controller.view), viewport)
        let advancedOffset = scroll.contentOffset.y
        scroll.setContentOffset(origin, animated: false)
        try await settle(host)
        XCTAssertLessThan(scroll.contentOffset.y, advancedOffset)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertEqual(c.cleanup.selectedCount, 1)
        assertServices(c, scans: 1)
        // This checks actual content <= actual viewport, not host.contains(viewport)
        // (a custom window can differ by a backing pixel). Neither scrolling nor
        // width proves every control/character fits, including the outside toolbar.
    }

    func testSheetSceneLifecycleAndAppLibraryEpochInvalidateAndDrainWithoutRescanning() async throws {
        let c = try await context()
        let host = try await mount(c)
        defer { host.close() }
        c.cleanup.scan()
        await c.cleanup.waitUntilIdle()
        c.cleanup.toggleSelection(c.grouping.groups[0].photos[0].id)
        c.cleanup.prepareDeletion()
        XCTAssertNotNil(c.cleanup.pendingDeletion)
        try await settle(host)

        // Drive the sheet's REAL onChange, not a copied observer or direct pause.
        c.scene.phase = .background
        try await settle(host)
        await c.cleanup.waitUntilIdle()
        assertUnscanned(c.cleanup)
        c.cleanup.scan() // Background rejects even an explicit attempt.
        await c.cleanup.waitUntilIdle()
        assertServices(c, scans: 1)
        c.scene.phase = .active
        try await settle(host)
        assertUnscanned(c.cleanup)
        assertServices(c, scans: 1)

        c.cleanup.scan() // Resume only permits this new explicit scan.
        await c.cleanup.waitUntilIdle()
        c.cleanup.toggleSelection(c.grouping.groups[1].photos[0].id)
        c.cleanup.prepareDeletion()
        try await settle(host)
        XCTAssertNotNil(c.cleanup.pendingDeletion)
        let epoch = c.appState.photoLibraryEpoch
        let authorization = c.appState.authorization
        c.appState.libraryChanged()
        await c.appState.waitUntilIdle()
        try await settle(host)
        XCTAssertNotEqual(c.appState.photoLibraryEpoch, epoch)
        XCTAssertEqual(c.appState.authorization, authorization,
                       "An epoch change, even with unchanged permission, must invalidate the sheet")
        assertUnscanned(c.cleanup)
        assertServices(c, scans: 2, refreshes: 2)

        // An uncooperative fake read returns only when released. The sheet's
        // library observer must cancel it; waitUntilIdle must still drain it.
        let gate = SimilarCleanupReviewGate()
        c.grouping.gate = gate
        c.cleanup.scan()
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5) == .completed else {
            XCTFail("The explicit grouping read did not enter the held service")
            throw SimilarCleanupReviewFailure.layout
        }
        c.appState.libraryChanged()
        await c.appState.waitUntilIdle()
        try await settle(host)
        assertUnscanned(c.cleanup)
        let joining = expectation(description: "Idle waiter entered")
        let finished = expectation(description: "Cancelled grouping read drained")
        var drained = false
        let waiter = Task { @MainActor in
            joining.fulfill()
            await c.cleanup.waitUntilIdle()
            drained = true
            finished.fulfill()
        }
        await fulfillment(of: [joining], timeout: 5)
        XCTAssertFalse(drained, "Cancellation must not pretend the held service has completed")
        gate.release()
        await fulfillment(of: [finished], timeout: 5)
        await waiter.value
        try await settle(host)
        XCTAssertTrue(drained)
        XCTAssertEqual(c.grouping.cancelledReturns, 1)
        assertUnscanned(c.cleanup)
        XCTAssertNil(c.cleanup.message, "The cancelled late result must not publish an error or new groups")
        assertServices(c, scans: 3, refreshes: 3)
    }

    // MARK: Synthetic services, genuine unauthorized thumbnail path

    private func context(empty: Bool = false, groupSizes: [Int] = [4, 3, 2]) async throws -> SimilarCleanupReviewContext {
        let permission = PhotoLibraryClient.authorization
        guard !PhotoLibraryClient.canRead else {
            XCTFail("Use an unauthorized test host; never reset/request Photos permission here")
            throw SimilarCleanupReviewFailure.readablePhotos
        }
        let candidateCount = groupSizes.reduce(0, +)
        let worker = SimilarCleanupReviewWorker(candidateCount: candidateCount)
        let translator = SimilarCleanupReviewTranslator()
        let appState = AppState(worker: worker, authorizationStatus: { .authorized }, queryTranslator: translator)
        let grouping = SimilarCleanupReviewGrouping(empty: empty, sizes: groupSizes)
        let deletion = SimilarCleanupReviewDeletion()
        let cleanup = SimilarPhotoCleanupState(grouping: grouping, deletion: deletion)
        let c = SimilarCleanupReviewContext(appState: appState, cleanup: cleanup, worker: worker,
            translator: translator, grouping: grouping, deletion: deletion,
            scene: SimilarCleanupReviewScene(), permission: permission)
        addTeardownBlock { @MainActor in
            cleanup.pause()
            grouping.gate?.release()
            appState.enterBackground()
            await cleanup.waitUntilIdle()
            await appState.waitUntilIdle()
            appState.thumbnails.clear()
            XCTAssertEqual(PhotoLibraryClient.authorization, permission)
            XCTAssertFalse(PhotoLibraryClient.canRead)
            XCTAssertTrue(deletion.calls.isEmpty)
            XCTAssertEqual(worker.unexpectedCalls, 0)
            XCTAssertEqual(translator.calls, 0)
        }
        assertUnscanned(cleanup)
        XCTAssertTrue(grouping.thresholds.isEmpty, "Constructing the controller must not scan")
        appState.refresh()
        await appState.waitUntilIdle()
        XCTAssertTrue(appState.canRead, "Only the injected AppState permission is authorized")
        XCTAssertTrue(appState.modelsReady)
        XCTAssertTrue(appState.summary.indexStatisticsKnown)
        XCTAssertEqual(appState.summary.indexedCount, candidateCount)

        // Confirm the real cache cannot obtain even a synthetic-ID thumbnail.
        // PhotoThumbnailView will render its production 'No access' placeholder;
        // no fixture image provider or real PhotoKit asset is substituted.
        let photo = SimilarCleanupReviewGrouping.fixtureGroups()[0].photos[0]
        do {
            _ = try await appState.thumbnails.image(id: photo.id, revision: photo.modificationTime,
                targetSize: CGSize(width: 180, height: 225), networkAllowed: false)
            XCTFail("An unauthorized thumbnail unexpectedly resolved")
            throw SimilarCleanupReviewFailure.thumbnailResolved
        } catch {
            guard let failure = error as? AppFailure, case .permission = failure else { throw error }
            XCTAssertEqual(PhotoPreviewIssue(error: error).caption, "No access")
        }
        assertServices(c, scans: 0)
        return c
    }

    private func assertUnscanned(_ state: SimilarPhotoCleanupState,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.hasScanned, file: file, line: line)
        XCTAssertTrue(state.groups.isEmpty, file: file, line: line)
        XCTAssertTrue(state.selectedIDs.isEmpty, file: file, line: line)
        XCTAssertNil(state.pendingDeletion, file: file, line: line)
        XCTAssertFalse(state.isGrouping, file: file, line: line)
        XCTAssertFalse(state.isDeleting, file: file, line: line)
    }

    private func assertServices(_ c: SimilarCleanupReviewContext, scans: Int, refreshes: Int = 1,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.grouping.thresholds, Array(repeating: SimilarPhotoGroupingPolicy.defaultThreshold, count: scans), file: file, line: line)
        XCTAssertTrue(c.deletion.calls.isEmpty, "Rendering/preparing must never submit deletion", file: file, line: line)
        XCTAssertEqual(c.worker.refreshCount, refreshes, file: file, line: line)
        XCTAssertEqual(c.worker.unexpectedCalls, 0, file: file, line: line)
        XCTAssertEqual(c.translator.calls, 0, file: file, line: line)
        XCTAssertNil(c.appState.appleTranslationService, file: file, line: line)
        XCTAssertNil(c.appState.activity, file: file, line: line)
        XCTAssertNil(c.appState.errorMessage, file: file, line: line)
        XCTAssertFalse(c.appState.allowICloudDownload, file: file, line: line)
        XCTAssertFalse(c.appState.library.canReadImages, file: file, line: line)
        XCTAssertFalse(PhotoLibraryClient.canRead, file: file, line: line)
        XCTAssertEqual(PhotoLibraryClient.authorization, c.permission, file: file, line: line)
        XCTAssertTrue(c.appState.results.isEmpty, file: file, line: line)
        XCTAssertEqual(c.appState.progress, IndexProgress(), file: file, line: line)
    }

    // MARK: Existing native-host pattern; top watermark never covers the toolbar

    private func mount(_ c: SimilarCleanupReviewContext, size: CGSize? = nil,
                       dynamicType: DynamicTypeSize = .large) async throws -> SimilarCleanupReviewHost {
        let size = size ?? phone
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        // Like DebugTools/LocalPreviewComparison hosted tests, override the
        // writable scenePhase environment, never the real app/OS scene state.
        let root = SimilarCleanupReviewRoot(context: c, scene: c.scene)
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, dynamicType)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        let host = SimilarCleanupReviewHost(scene: scene, root: AnyView(root), size: size)
        var mounted = false
        defer { if !mounted { host.close() } }
        let laidOut = expectation(description: "Native cleanup sheet laid out at \(size)")
        host.controller.onLayout = { [weak controller = host.controller] in
            guard let controller, controller.view.window != nil, controller.view.bounds.size == size else { return }
            controller.onLayout = nil
            laidOut.fulfill()
        }
        host.window.rootViewController = host.controller
        host.window.makeKeyAndVisible()
        host.layout()
        guard await XCTWaiter.fulfillment(of: [laidOut], timeout: 5) == .completed else {
            XCTFail("Native cleanup host did not lay out")
            throw SimilarCleanupReviewFailure.layout
        }
        try await settle(host)
        XCTAssertEqual(host.controller.view.bounds.size, size)
        mounted = true
        return host
    }

    private func settle(_ host: SimilarCleanupReviewHost) async throws {
        let settled = expectation(description: "Pending native cleanup layout updates completed")
        DispatchQueue.main.async {
            host.layout()
            DispatchQueue.main.async { host.layout(); settled.fulfill() }
        }
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 5) == .completed else {
            XCTFail("Native cleanup layout did not settle")
            throw SimilarCleanupReviewFailure.layout
        }
    }

    private func scrollView(in host: SimilarCleanupReviewHost) throws -> UIScrollView {
        func descendants(_ view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { descendants($0) }
        }
        let candidates = descendants(host.controller.view).filter {
            !$0.isHidden && $0.alpha > 0 && $0.window === host.window && !$0.bounds.isEmpty
                && $0.contentSize.width > 0 && $0.contentSize.height > 0
        }
        XCTAssertEqual(candidates.count, 1, "The real sheet owns one vertical scroll view, not a fixture grid/Form")
        let scroll = try XCTUnwrap(candidates.first)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width)
        let visible = scroll.convert(scroll.bounds, to: host.controller.view).intersection(host.controller.view.bounds)
        XCTAssertFalse(visible.isNull)
        XCTAssertGreaterThan(visible.width, 0)
        XCTAssertGreaterThan(visible.height, 0)
        return scroll
    }

    private func capture(_ host: SimilarCleanupReviewHost) throws -> UIImage {
        let view = host.controller.view!
        let format = UIGraphicsImageRendererFormat()
        format.scale = host.window.screen.scale
        format.opaque = true
        format.preferredRange = .standard
        var drew = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(view.bounds)
            drew = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard drew else {
            XCTFail("UIKit did not draw the real cleanup sheet")
            throw SimilarCleanupReviewFailure.drawing
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.width, Int((view.bounds.width * format.scale).rounded()))
        XCTAssertEqual(cg.height, Int((view.bounds.height * format.scale).rounded()))
        return image
    }

    private func attach(_ image: UIImage, name: String) {
        XCTAssertEqual(image.size, phone)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let review = UIGraphicsImageRenderer(size: phone, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: phone))
        }
        let attachment = XCTAttachment(image: review)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum SimilarCleanupReviewFailure: Error { case readablePhotos, thumbnailResolved, layout, drawing, unexpectedWork }

@MainActor
private struct SimilarCleanupReviewContext {
    let appState: AppState
    let cleanup: SimilarPhotoCleanupState
    let worker: SimilarCleanupReviewWorker
    let translator: SimilarCleanupReviewTranslator
    let grouping: SimilarCleanupReviewGrouping
    let deletion: SimilarCleanupReviewDeletion
    let scene: SimilarCleanupReviewScene
    let permission: PHAuthorizationStatus
}

@MainActor
private final class SimilarCleanupReviewScene: ObservableObject {
    @Published var phase: ScenePhase = .active
}

@MainActor
private struct SimilarCleanupReviewRoot: View {
    let context: SimilarCleanupReviewContext
    @ObservedObject var scene: SimilarCleanupReviewScene

    var body: some View {
        VStack(spacing: 0) {
            Text("TEST FIXTURE · synthetic groups · no Photos")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).padding(.vertical, 6)
                .frame(maxWidth: .infinity).background(Color.black)
            SimilarPhotoCleanupSheet(state: context.cleanup, appState: context.appState)
        }
        .environment(\.scenePhase, scene.phase)
    }
}

@MainActor
private final class SimilarCleanupReviewGrouping: SimilarPhotoGrouping {
    let groups: [SimilarPhotoGroup]
    let candidateCount: Int
    private(set) var thresholds: [Float] = []
    private(set) var cancelledReturns = 0
    var gate: SimilarCleanupReviewGate?

    init(empty: Bool, sizes: [Int] = [4, 3, 2]) {
        candidateCount = sizes.reduce(0, +)
        groups = empty ? [] : Self.fixtureGroups(sizes: sizes)
    }

    static func fixtureGroups(sizes: [Int] = [4, 3, 2]) -> [SimilarPhotoGroup] {
        // Already ordered like the real grouping result: sizes 4, 3, 2. No
        // attempt to retest grouping math here (covered by the pure-state suite).
        var result: [SimilarPhotoGroup] = []
        for (groupIndex, count) in sizes.enumerated() {
            var vector = [Float](repeating: 0, count: 768)
            vector[groupIndex] = 1
            var photos: [IndexedPhoto] = []
            for index in 0..<count {
                let ordinal: Int = groupIndex * 10 + index
                let id = "TEST-cleanup-\(groupIndex + 1)-\(index + 1)"
                let photo = IndexedPhoto(id: id, modificationTime: Double(200 + ordinal),
                    modelVersion: "TEST-cleanup-presentation", imageEmbedding: vector,
                    creationTime: Double(100 + ordinal))
                photos.append(photo)
            }
            result.append(SimilarPhotoGroup(id: photos[0].id, photos: photos, minimumSimilarity: 1))
        }
        return result
    }

    func group(threshold: Float,
               progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void) async throws -> SimilarPhotoGroupingResult {
        thresholds.append(threshold)
        if let gate { await gate.wait() }
        if Task.isCancelled { cancelledReturns += 1 }
        let photos = groups.flatMap(\.photos)
        // Synthetic CURRENT metadata only. Never fetch a PHAsset to validate it.
        let revisions = Dictionary(uniqueKeysWithValues: photos.map {
            ($0.id, PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime))
        })
        await progress(SimilarPhotoGroupingProgress(total: candidateCount, completed: candidateCount, groupCount: groups.count))
        return SimilarPhotoGroupingResult(groups: groups, candidateCount: candidateCount,
            staleCount: 0, unindexedCount: 0, threshold: threshold,
            validatePhotos: { ids in
                guard ids.allSatisfy({ revisions[$0] != nil }) else { throw PhotoDeletionError.accessChanged }
            })
        // Intentionally return late success after cancellation; the real
        // controller, not this fake, must reject its publication.
    }
}

@MainActor
private final class SimilarCleanupReviewGate {
    let entered = XCTestExpectation(description: "Grouping service installed its continuation")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

@MainActor
private final class SimilarCleanupReviewDeletion: PhotoDeleting {
    private(set) var calls: [[PhotoRevision]] = []
    func delete(revisions: [PhotoRevision]) async throws {
        calls.append(revisions)
        XCTFail("Presentation tests must never submit even a fake deletion")
        throw SimilarCleanupReviewFailure.unexpectedWork
    }
}

@MainActor
private final class SimilarCleanupReviewWorker: PhotoWorkServicing {
    let candidateCount: Int
    init(candidateCount: Int = 9) { self.candidateCount = candidateCount }
    private(set) var refreshCount = 0
    private(set) var unexpectedCalls = 0
    func refresh() async throws -> LibrarySummary {
        refreshCount += 1
        return LibrarySummary(indexedCount: candidateCount, modelVersion: "TEST-cleanup-presentation")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func indexText(networkAllowed: Bool, progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse { throw unexpected() }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> SimilarCleanupReviewFailure {
        unexpectedCalls += 1
        XCTFail("Presenting cleanup must not index, search or clear storage")
        return .unexpectedWork
    }
}

@MainActor
private final class SimilarCleanupReviewTranslator: QueryTranslating {
    let isSupported = false
    private(set) var calls = 0
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        calls += 1; XCTFail("Cleanup must not check translation availability"); return .unsupported
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        calls += 1; XCTFail("Cleanup must not translate"); throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        calls += 1; XCTFail("Cleanup must not prepare translation"); throw QueryTranslationFailure.unsupported
    }
}

@MainActor
private final class SimilarCleanupReviewController: UIHostingController<AnyView> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); onLayout?() }
}

@MainActor
private final class SimilarCleanupReviewHost {
    let window: UIWindow
    let controller: SimilarCleanupReviewController
    private weak var previousKey: UIWindow?

    init(scene: UIWindowScene, root: AnyView, size: CGSize) {
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        controller = SimilarCleanupReviewController(rootView: root)
        controller.overrideUserInterfaceStyle = .dark
    }

    func layout() {
        window.setNeedsLayout(); window.layoutIfNeeded()
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
    }

    func close() {
        controller.onLayout = nil
        window.isHidden = true
        window.rootViewController = nil
        previousKey?.makeKey()
    }
}