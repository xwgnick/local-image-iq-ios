import XCTest
import SwiftUI
import UIKit
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Four native review attachments, not pixel/text-visibility assertions. Real
/// AppState and sheets; test-only service, labels and generated 768-D vectors.
/// No image/model requests, Photos authorization/imports or index writes. These
/// tests verify presentation of service results, NOT the worker's backfill logic.
@MainActor
final class IndexPlacesPresentationTests: XCTestCase {
    func testOpeningSavedIndexLibraryDoesNotScanRefreshAgainOrClearSnapshot() async throws {
        let worker = IndexPlacesTestWorker(photos: IndexPlacesFixtures.photos(count: 3, located: 0),
                                          progress: IndexProgress())
        let state = await readyState(worker)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertEqual(LibrarySheet(state: state).storedCountText, "已索引 3 张")
        XCTAssertEqual(LibrarySheet(state: state).authorizedCountSnapshotText, "未扫描")
        XCTAssertFalse(state.debugToolsEnabled)
        try await snapshot(LibrarySheet(state: state), id: "saved-index-unscanned")
        await state.waitUntilIdle()
        let refreshes = await worker.refreshCount
        let requests = await worker.indexRequests
        XCTAssertEqual(refreshes, 1, "Opening the sheet must not refresh or scan the library")
        XCTAssertTrue(requests.isEmpty, "Rendering must not update or rebuild the index")
        XCTAssertEqual(state.summary.indexedCount, 3)
        XCTAssertFalse(state.summary.authorizedCountKnown)
        XCTAssertNil(state.errorMessage)
        // The worker fails immediately if clear/search is requested. Rebuild
        // confirmation taps require separate authorized XCUI/device coverage.
    }

    func testBackfillPublishesAllPlaceCountersAndReadyLibrarySnapshot() async throws {
        let photos = IndexPlacesFixtures.photos(count: 11, located: 4)
        try assertGeneratedRecords(photos)
        let scan = IndexProgress(total: 12, completed: 12, reused: 11, cloudSkipped: 1,
                                 placeChecked: 12, gpsCount: 8, placeResolved: 5, noGPS: 3,
                                 noPlacePack: 1, outsidePlaceCoverage: 2, placeUnavailable: 1, placeUpdated: 4)
        let published = expectation(description: "Place progress accepted before index completion")
        let worker = IndexPlacesTestWorker(photos: photos, progress: scan, started: published)
        let state = await readyState(worker)
        XCTAssertTrue(state.canIndex)
        XCTAssertEqual(state.summary.locatedCount, 0)
        state.index()
        await fulfillment(of: [published], timeout: 3)

        // No throwing work while the fake is held: always release its continuation.
        XCTAssertEqual(state.activity, .indexing)
        XCTAssertFalse(state.canIndex)
        XCTAssertEqual(state.progress, scan, "All new counters must survive the progress callback")
        XCTAssertEqual(state.summary.locatedCount, 0, "Saved totals change only on completion")
        XCTAssertEqual(state.progress.placeChecked, state.progress.placeResolved + state.progress.noGPS
                       + state.progress.noPlacePack + state.progress.outsidePlaceCoverage + state.progress.placeUnavailable)
        XCTAssertEqual(state.progress.gpsCount, state.progress.placeResolved
                       + state.progress.noPlacePack + state.progress.outsidePlaceCoverage)
        state.index() // Busy guard must not schedule a second request.
        await worker.release()
        await state.waitUntilIdle()

        XCTAssertTrue(state.canIndex)
        XCTAssertNil(state.activity)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.progress, scan)
        XCTAssertEqual(state.progress.encoded, 0)
        XCTAssertEqual(state.summary.authorizedCount, 12)
        XCTAssertEqual(state.summary.indexedCount, 11)
        XCTAssertEqual(state.summary.locatedCount, 4)
        XCTAssertGreaterThan(state.progress.placeResolved, state.summary.locatedCount,
                             "A label observed on a missing preview is not a saved label")
        XCTAssertTrue(state.status.contains("Images reused: 11."))
        XCTAssertTrue(state.status.contains("Saved place updates: 4."))
        XCTAssertFalse(state.allowICloudDownload)
        XCTAssertTrue(state.results.isEmpty)
        XCTAssertNil(state.completedQuery)
        try await snapshot(LibrarySheet(state: state), id: "library-after-backfill")
        let calls = await worker.indexRequests
        XCTAssertEqual(calls, [false], "One fake index request, with cloud access still off")
    }

    func testCheckedZeroGPSIsDistinctFromNotCheckedLibrarySnapshot() async throws {
        let photos = IndexPlacesFixtures.photos(count: 3, located: 0)
        try assertGeneratedRecords(photos)
        let scan = IndexProgress(total: 3, completed: 3, reused: 3, placeChecked: 3, noGPS: 3)
        let worker = IndexPlacesTestWorker(photos: photos, progress: scan)
        let state = await readyState(worker)
        let unchecked = state.progress
        XCTAssertEqual(unchecked.placeChecked, 0)
        XCTAssertEqual(unchecked.gpsCount, 0)
        XCTAssertTrue(state.canIndex)
        state.index()
        await state.waitUntilIdle()

        XCTAssertEqual(state.progress, scan)
        XCTAssertNotEqual(state.progress, unchecked)
        XCTAssertGreaterThan(state.progress.placeChecked, 0,
                             "Library must choose the checked-zero branch, not 'Photo locations not checked'")
        XCTAssertEqual(state.progress.gpsCount, 0)
        XCTAssertEqual(state.progress.placeResolved, 0)
        XCTAssertEqual(state.progress.noGPS, 3)
        XCTAssertEqual(state.progress.placeUnavailable, 0)
        XCTAssertEqual(state.progress.noPlacePack, 0)
        XCTAssertEqual(state.progress.outsidePlaceCoverage, 0)
        XCTAssertEqual(state.summary.locatedCount, 0)
        XCTAssertTrue(state.canIndex, "No GPS must not block image indexing")
        XCTAssertNil(state.errorMessage)
        try await snapshot(LibrarySheet(state: state), id: "library-checked-zero-gps")
        let calls = await worker.indexRequests
        XCTAssertEqual(calls, [false])
    }

    func testReadinessGuardsAndUncheckedSettingsSnapshot() async throws {
        let photos = IndexPlacesFixtures.photos(count: 3, located: 0)
        try assertGeneratedRecords(photos)
        let cases: [(access: PHAuthorizationStatus, modelIssue: String?, canIndex: Bool)] = [
            (.authorized, nil, true), (.limited, nil, true),
            (.authorized, "Models unavailable: TEST FIXTURE", false), (.denied, nil, false)
        ]
        for entry in cases {
            let worker = IndexPlacesTestWorker(photos: photos, progress: IndexProgress(), modelIssue: entry.modelIssue)
            let state = await readyState(worker, access: entry.access)
            XCTAssertEqual(state.canIndex, entry.canIndex)
            XCTAssertEqual(state.modelsReady, entry.modelIssue == nil)
            XCTAssertEqual(state.progress.placeChecked, 0)
            XCTAssertEqual(state.progress.gpsCount, 0, "Zero without observations remains unknown")
            XCTAssertEqual(state.locationWeight, 0.6)
            XCTAssertEqual(state.resultLimit, 12)
            XCTAssertFalse(state.allowICloudDownload)
            if !entry.canIndex {
                state.index()
                await state.waitUntilIdle()
                XCTAssertNil(state.activity)
            }
            if entry.access == .authorized && entry.modelIssue == nil {
                try await snapshot(SettingsSheet(state: state), id: "settings-unchecked")
            }
            let calls = await worker.indexRequests
            XCTAssertTrue(calls.isEmpty, "Rendering or a blocked action must not start indexing")
            let refreshes = await worker.refreshCount
            XCTAssertEqual(refreshes, 1)
        }
    }

    private func readyState(_ worker: IndexPlacesTestWorker, access: PHAuthorizationStatus = .authorized) async -> AppState {
        let state = AppState(worker: worker, authorizationStatus: { access })
        state.refresh()
        await state.waitUntilIdle()
        return state
    }

    private func assertGeneratedRecords(_ photos: [IndexedPhoto]) throws {
        for photo in photos {
            XCTAssertEqual(photo.imageEmbedding.count, 768)
            try EmbeddingValidation.validateUnit(photo.imageEmbedding)
            if let place = photo.location {
                try EmbeddingValidation.validateUnit(place.vector)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(place)) as? [String: Any])
                XCTAssertEqual(Set(object.keys), Set(["text", "vector"]), "Place fixtures carry labels/vectors, not raw GPS")
            }
        }
    }

    private func snapshot<Content: View>(_ content: Content, id: String) async throws {
        let size = CGSize(width: 393, height: 852)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native review captures require the app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        let root = content.preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.layoutDirection, .leftToRight)
            .environment(\.dynamicTypeSize, .large)
        let host = IndexPlacesHostingController(rootView: root)
        let laidOut = expectation(description: "\(id): native layout")
        host.onLayout = { [weak host] in
            guard let host, host.view.window != nil, host.view.bounds.size == size else { return }
            host.onLayout = nil
            laidOut.fulfill()
        }
        defer {
            host.onLayout = nil
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 5)
        let settled = expectation(description: "\(id): SwiftUI updates settled")
        DispatchQueue.main.async {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            DispatchQueue.main.async {
                host.view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
        XCTAssertEqual(host.view.bounds.size, size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        var drewHierarchy = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            drewHierarchy = host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int(size.width))
        XCTAssertEqual(pixels.height, Int(size.height))
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-index-places-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Production disclosures remain collapsed: Library exposes GPS/label
        // summary counts, not every detail row. Settings keeps its normal state.
        // Rendering/dimensions do NOT prove text visibility, clipping or that all
        // rows were read; expanded disclosure interaction requires XCUI coverage.
    }
}

@MainActor
private final class IndexPlacesHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private enum IndexPlacesFixtures {
    static let version = "index-places-presentation-test-only"
    static let coverage = "Offline country coverage: China, France, Germany, Netherlands. Administrative boundaries may be incomplete or historical; not live GPS or global coverage. TEST FIXTURE."

    static func photos(count: Int, located: Int) -> [IndexedPhoto] {
        let labels = ["TEST FIXTURE region, China", "TEST FIXTURE region, France",
                      "TEST FIXTURE region, Germany", "TEST FIXTURE region, Netherlands"]
        return (0..<count).map { index in
            let place = index < located
                ? PlaceEmbedding(text: "Photo taken in \(labels[index % labels.count]).", vector: TestFixtures.vector(axis: 1)) : nil
            return IndexedPhoto(id: "index-places-test-only-\(index)", modificationTime: 123,
                                modelVersion: version, imageEmbedding: TestFixtures.vector(), location: place)
        }
    }
}

/// No PhotoLibraryIndexing or PhotoEncoding dependency: all observations and
/// generated records are supplied, never inferred from an actual image or GPS.
private actor IndexPlacesTestWorker: PhotoWorkServicing {
    private let photos: [IndexedPhoto]
    private let scan: IndexProgress
    private let modelIssue: String?
    private let started: XCTestExpectation?
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var indexRequests: [Bool] = []
    private(set) var refreshCount = 0

    init(photos: [IndexedPhoto], progress: IndexProgress, started: XCTestExpectation? = nil, modelIssue: String? = nil) {
        self.photos = photos
        scan = progress
        self.started = started
        self.modelIssue = modelIssue
    }

    private func summary(located: Int) -> LibrarySummary {
        LibrarySummary(authorizedCount: max(photos.count, scan.total), indexedCount: photos.count, locatedCount: located,
                       modelVersion: modelIssue == nil ? IndexPlacesFixtures.version : nil, modelIssue: modelIssue,
                       placesDescription: IndexPlacesFixtures.coverage)
    }

    func refresh() async throws -> LibrarySummary {
        refreshCount += 1
        return summary(located: 0)
    }

    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        indexRequests.append(networkAllowed)
        await progress(scan)
        if let started {
            started.fulfill()
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        return summary(located: photos.filter { $0.location != nil }.count)
    }

    func release() {
        released = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        XCTFail("Place presentation must not request a search or model inference")
        throw AppFailure.storage("TEST FIXTURE: unexpected search")
    }

    func clear() async throws -> LibrarySummary {
        XCTFail("Place presentation must not clear storage")
        throw AppFailure.storage("TEST FIXTURE: unexpected clear")
    }
}