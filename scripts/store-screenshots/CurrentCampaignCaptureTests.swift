import XCTest
import SwiftUI
import UIKit
import ImageIQCore
@testable import LocalImageIQ

// Screenshot-only project: production views, synthetic metadata, public CC0
// cleanup pixels. Never authorizes Photos, loads models, or changes real data.
@MainActor
final class CurrentCampaignCaptureTests: XCTestCase {
    func testCaptureCurrentCampaignViews() async throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let size = isPad ? CGSize(width: 1032, height: 1376) : CGSize(width: 440, height: 956)
        let width = isPad ? 2064 : 1320
        let height = isPad ? 2752 : 2868
        let fixture = try await controlsFixture(in: self, sizes: [6, 6])
        var records: [[String: Any]] = []
        for (name, query, count, ocr, location) in [
            ("memory", "猫猫跳起来扑玩具", 6, false, false),
            ("identity", "身份证", 9, false, false),
            ("text", "北门值班室", 1, true, false),
            ("location", "三亚的海", 6, false, true),
        ] {
            let suite = "CurrentCampaign.\(UUID().uuidString)"
            let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
            preferences.set(ocr, forKey: "photoTextSearchEnabled.v1")
            preferences.set(location, forKey: "locationSearchEnabled.v1")
            defer { preferences.removePersistentDomain(forName: suite) }
            let worker = CampaignWorker(count: count)
            let state = AppState(worker: worker, authorizationStatus: { .authorized },
                queryTranslator: CampaignNoTranslation(), textSearchPreferences: preferences,
                locationSearchPreferences: preferences)
            state.chineseSearchEnabled = false
            state.refresh()
            await state.waitUntilIdle()
            state.query = query
            state.submitSearchQuery()
            await state.waitUntilIdle()
            XCTAssertNil(state.errorMessage)
            XCTAssertEqual(state.results.count, count)
            XCTAssertEqual(state.textSearchEnabled, ocr)
            XCTAssertEqual(state.locationSearchEnabled, location)
            let measurements = CampaignMeasurements()
            let content = ContentView(state: state, similarCleanupState: fixture.cleanup,
                navigation: fixture.navigation, cleanupPreferences: nil)
                .onPreferenceChange(MinimalSearchFrames.self) { measurements.frames = $0 }
                .onPreferenceChange(SearchPhotoTextFrames.self) { measurements.tools = $0 }
            let host = try ControlsNativeHost(content: AnyView(content),
                size: size, appearance: .light)
            try await host.wait {
                measurements.frames[.resultsHeading] != nil
                    && measurements.tools[.locationToggle] != nil && host.tabs.count == 2
            }
            let heading = host.controller.view.convert(
                try XCTUnwrap(measurements.frames[.resultsHeading]), from: host.window)
            let contentWidth = min(size.width, 800)
            XCTAssertEqual(heading.minX, (size.width - contentWidth) / 2 + 20, accuracy: host.pixel)
            XCTAssertEqual(heading.width, contentWidth - 40, accuracy: host.pixel)
            let image = try host.capture()
            XCTAssertEqual(image.cgImage?.width, width)
            XCTAssertEqual(image.cgImage?.height, height)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Current-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            records.append([
                "name": name, "query": query, "width": width, "height": height,
                "gridColumns": 3, "gridGap": 3 * image.scale, "gridX": heading.minX * image.scale,
                "gridY": (heading.maxY + 18) * image.scale, "gridWidth": heading.width * image.scale,
                "resultCount": count, "ocr": ocr, "location": location,
            ])
            host.close()
            state.enterBackground()
            await state.waitUntilIdle()
            state.thumbnails.clear()
        }

        let bundle = Bundle(for: Self.self)
        let cat = try XCTUnwrap(UIImage(contentsOfFile: try XCTUnwrap(
            bundle.url(forResource: "chelsea", withExtension: "png", subdirectory: "store-source-photos")).path))
        let coffee = try XCTUnwrap(UIImage(contentsOfFile: try XCTUnwrap(
            bundle.url(forResource: "coffee", withExtension: "png", subdirectory: "store-source-photos")).path))
        // Retained search pages deliberately attach real, unreadable browsing
        // access to their cleanup controller. Do not reuse it for pixel fixtures.
        let cleanup = try await controlsFixture(in: self, sizes: [6, 6])
        cleanup.cleanup.scan()
        await cleanup.cleanup.waitUntilIdle()
        XCTAssertEqual(cleanup.cleanup.groups.count, 2)
        let content = SimilarPhotoCleanupSheet(state: cleanup.cleanup, appState: cleanup.app,
            browser: cleanup.browser, thumbnailContent: { photo in
                AnyView(Image(uiImage: photo.id.hasPrefix("TEST-controls-0-") ? cat : coffee)
                    .resizable().scaledToFill())
            })
        let host = try ControlsNativeHost(content: AnyView(content),
            size: size, appearance: .light)
        defer { host.close() }
        try await host.wait { cleanup.cleanup.groups.count == 2 && host.controls[.disclosure] != nil }
        try host.attach(to: self, name: "Current-cleanup")
        records.append(["name": "cleanup", "width": width, "height": height])
        let group = try XCTUnwrap(cleanup.cleanup.groups.first)
        let session = try XCTUnwrap(cleanup.cleanup.selectionSessionID)
        cleanup.browser.open(group: group, photoID: group.photos[0].id, sessionID: session)
        for photo in group.photos.dropFirst() { cleanup.cleanup.toggleSelection(photo.id) }
        try await host.wait { cleanup.browser.detailRoute != nil && cleanup.cleanup.selectedCount == 5 }
        try host.attach(to: self, name: "Current-selection")
        records.append(["name": "selection", "width": width, "height": height])
        let metadata = XCTAttachment(data: try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]),
            uniformTypeIdentifier: "public.json")
        metadata.name = "Current-layout"
        metadata.lifetime = .keepAlways
        add(metadata)
        XCTAssertFalse(PhotoLibraryClient.canRead)
    }
}

@MainActor
private final class CampaignMeasurements {
    var frames: [MinimalSearchPart: CGRect] = [:]
    var tools: [SearchPhotoTextElement: CGRect] = [:]
}

@MainActor
private final class CampaignWorker: PhotoWorkServicing {
    private let count: Int
    private let summary = LibrarySummary(indexedCount: 12, modelVersion: "TEST-campaign",
        textIndexCounts: TextIndexCounts(records: 12, withText: 1), textIndexStatisticsKnown: true)
    init(count: Int) { self.count = count }
    func refresh() async throws -> LibrarySummary { summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        response(ocr: false)
    }
    func search(text: String, originalText: String, limit: Int, locationWeight: Float,
                filters: PhotoSearchFilters, textSearchEnabled: Bool) async throws -> SearchResponse {
        try filters.validate()
        return response(ocr: textSearchEnabled)
    }
    private func response(ocr: Bool) -> SearchResponse {
        let hits = (0..<count).map {
            SearchHit(photo: TestFixtures.photo(id: "TEST-campaign-\($0)").photo, score: Float(count - $0) / Float(count))
        }
        return SearchResponse(summary: summary, hits: hits,
            textMatchedIDs: ocr ? Set(hits.map(\.id)) : [], textSearchUsed: ocr)
    }
    func index(networkAllowed: Bool,
               progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func indexText(networkAllowed: Bool,
                   progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        throw unexpected()
    }
    func clear() async throws -> LibrarySummary { throw unexpected() }
    private func unexpected() -> ControlsPresentationFailure {
        XCTFail("Campaign capture must not index, recognize, or clear photos")
        return .unexpectedWork
    }
}

@MainActor
private final class CampaignNoTranslation: QueryTranslating {
    let isSupported = false
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability { .unsupported }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        throw QueryTranslationFailure.unsupported
    }
    func prepare(_ language: QueryTranslationLanguage) async throws { throw QueryTranslationFailure.unsupported }
}
