import XCTest
import Foundation
import SwiftUI
import UIKit
import ImageIQCore
@testable import LocalImageIQ

#if targetEnvironment(simulator)
/// Five fake-only tests and exactly four native phone-size review attachments.
/// ContentView/SettingsSheet are hosted unchanged; only a TEST watermark is added.
/// No Apple Translation availability/session/download API, encoder, database,
/// asset fetch, image request or network service is exercised by these fixtures.
/// AppState still constructs its concrete Photos wrapper/default image manager
/// and reads authorization. An unreadable simulator library is required so its
/// refresh cannot register a Photos observer. This is not zero PhotoKit API use.
/// Captures are review material, not pixel baselines, XCUI taps or device evidence.
@MainActor
final class QueryTranslationPresentationTests: XCTestCase {
    private let phone = CGSize(width: 393, height: 852)
    private let compactPhone = CGSize(width: 375, height: 667)

    func testTranslatedContentSnapshotAndUseOriginalDoesNotTranslateAgain() async throws {
        let context = try await searchedContext()
        try await translatedSnapshot(context, id: "translated", size: phone)

        // Exercise the exact state action used by the production 使用原文 button,
        // AFTER the one capture. This does not claim to tap that SwiftUI button.
        context.state.search(useOriginal: true)
        await context.state.waitUntilIdle()
        assertResolution(context, effective: QueryTranslationPresentationFixture.original, translated: false)
        assertCalls(context, searches: [QueryTranslationPresentationFixture.english,
                                       QueryTranslationPresentationFixture.original],
                    availability: [context.language], translations: [context.translationRequest])
        XCTAssertTrue(context.state.chineseSearchEnabled, "Use original must not disable the saved preference")
    }

    func testMissingPackFallbackContentSnapshotWithoutTranslateOrDownload() async throws {
        let context = try await searchedContext(availability: .downloadRequired)
        let validate: @MainActor () -> Void = {
            self.assertResolution(context, effective: QueryTranslationPresentationFixture.original,
                                  translated: false, notice: QueryTranslationPresentationFixture.missingPackNotice)
            self.assertCalls(context, searches: [QueryTranslationPresentationFixture.original],
                             availability: [context.language], translations: [])
        }
        validate()
        try await snapshot(ContentView(state: context.state), id: "missing-pack", size: phone,
                           validate: validate)
        validate()
    }

    func testSettingsLanguagePackSectionSnapshotUsesOnlyInjectedAvailabilityTask() async throws {
        let context = try await searchedContext(availability: .downloadRequired)
        XCTAssertEqual(context.state.translationAvailability, .unchecked,
                       "Search resolution does not itself publish Settings availability")
        let checked = expectation(description: "The actual Settings .task checks the fake language pack")
        context.translator.nextAvailability = checked
        let validate: @MainActor () -> Void = {
            self.assertResolution(context, effective: QueryTranslationPresentationFixture.original,
                                  translated: false, notice: QueryTranslationPresentationFixture.missingPackNotice)
            self.assertCalls(context, searches: [QueryTranslationPresentationFixture.original],
                             availability: [context.language, .simplified], translations: [])
            XCTAssertEqual(context.state.translationLanguage, .simplified)
            XCTAssertTrue(context.state.translationSupported, "Simulator support is supplied by the fake only")
            XCTAssertEqual(context.state.translationAvailability, .downloadRequired)
            XCTAssertNil(context.state.translationPreparationIssue)
        }
        try await snapshot(SettingsSheet(state: context.state), id: "settings-language-pack", size: phone,
                           afterLayout: { view in
            await self.fulfillment(of: [checked], timeout: 3)
            await self.settle(view)
            try await self.revealLanguagePackSection(in: view)
        }, validate: validate)
        validate() // Settings disappearance must not trigger translation/preparation/photo work.
    }

    func testTranslatedContentLargeDynamicTypeSnapshot() async throws {
        let context = try await searchedContext()
        try await translatedSnapshot(context, id: "translated-accessibility-large", size: compactPhone,
                                     dynamicTypeSize: .accessibility1)
    }

    func testPrivateTranslationAndPreparationErrorsAreRedactedWithoutCapture() async throws {
        let error = QueryTranslationPresentationFixture.privateError
        let context = try await searchedContext(translation: .failure(error))
        assertResolution(context, effective: QueryTranslationPresentationFixture.original,
                         translated: false, notice: QueryTranslationPresentationFixture.failureNotice)
        assertCalls(context, searches: [QueryTranslationPresentationFixture.original],
                    availability: [context.language], translations: [context.translationRequest])

        // Explicitly request only the FAKE preparation failure, never a real pack.
        // Cover both user-visible error surfaces without adding a fifth image.
        context.translator.preparationError = error
        context.state.prepareTranslation()
        await context.state.waitUntilIdle()
        XCTAssertEqual(context.state.translationPreparationIssue,
                       "语言包准备未完成。请检查网络和设备空间后重试；原文搜索仍然可用。")
        XCTAssertEqual(context.state.translationAvailability, .unchecked)
        assertResolution(context, effective: QueryTranslationPresentationFixture.original,
                         translated: false, notice: QueryTranslationPresentationFixture.failureNotice)
        assertCalls(context, searches: [QueryTranslationPresentationFixture.original],
                    availability: [context.language], translations: [context.translationRequest],
                    preparations: [.simplified])
    }

    // MARK: Preload through real state APIs, never assign private published results

    private func searchedContext(availability: QueryTranslationAvailability = .installed,
                                 translation: Result<String, Error> = .success(QueryTranslationPresentationFixture.english))
        async throws -> QueryTranslationPresentationContext {
        guard #available(iOS 18.0, *) else { throw XCTSkip("Native review requires an iOS 18+ simulator") }
        // No permission request or reset. This concrete AppState seam cannot
        // replace synchronizeObservation; skip readable libraries rather than
        // registering against any real Photos collection during refresh.
        guard !PhotoLibraryClient.canRead else {
            throw XCTSkip("Use a simulator test host without Photos read access; no permission changes are made")
        }
        let language = try XCTUnwrap(ChineseQueryRouter.sourceLanguage(for: QueryTranslationPresentationFixture.original))
        let context = QueryTranslationPresentationContext(language: language, availability: availability,
                                                          translation: translation)
        addTeardownBlock { await context.cancelAndDrain() }
        XCTAssertNil(context.state.appleTranslationService, "Never mount the Apple translation task host")
        XCTAssertTrue(context.translator.availabilityRequests.isEmpty)
        XCTAssertTrue(context.translator.translationRequests.isEmpty)
        XCTAssertTrue(context.translator.prepareRequests.isEmpty)
        XCTAssertEqual(context.worker.refreshCount, 0)
        context.state.refresh()
        await context.state.waitUntilIdle()
        XCTAssertTrue(context.state.canRead, "Ready authorization comes only from the injected closure")
        XCTAssertTrue(context.state.modelsReady)
        XCTAssertNil(context.state.completedQuery)
        XCTAssertNil(context.state.completedSearchQuery)
        context.state.query = QueryTranslationPresentationFixture.original
        XCTAssertTrue(context.state.canSearch)
        context.state.search()
        await context.state.waitUntilIdle()
        return context
    }

    private func assertResolution(_ context: QueryTranslationPresentationContext, effective: String,
                                  translated: Bool, notice: String? = nil,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let state = context.state
        let original = QueryTranslationPresentationFixture.original
        XCTAssertEqual(state.completedSearchQuery,
                       SearchQueryResolution(original: original, effective: effective, translated: translated, notice: notice),
                       file: file, line: line)
        XCTAssertEqual(Array(state.query.utf8), Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedQuery.map { Array($0.utf8) }, Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery.map { Array($0.original.utf8) }, Array(original.utf8), file: file, line: line)
        XCTAssertEqual(state.completedSearchQuery.map { Array($0.effective.utf8) }, Array(effective.utf8), file: file, line: line)
        XCTAssertEqual(state.photoCheckInitialQuery, effective, file: file, line: line)
        XCTAssertNil(state.activity, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
        XCTAssertNil(state.actionHint, file: file, line: line)
        XCTAssertTrue(state.canSearch, file: file, line: line)
        XCTAssertTrue(state.results.isEmpty, "Zero hits prevent all production thumbnail tasks", file: file, line: line)
        XCTAssertNil(state.selection, file: file, line: line)
        assertRedacted(state, file: file, line: line)
    }

    private func assertCalls(_ context: QueryTranslationPresentationContext, searches: [String],
                             availability: [QueryTranslationLanguage],
                             translations: [QueryTranslationPresentationTranslator.Request],
                             preparations: [QueryTranslationLanguage] = [],
                             file: StaticString = #filePath, line: UInt = #line) {
        let state = context.state, worker = context.worker, translator = context.translator
        XCTAssertNil(state.appleTranslationService, file: file, line: line)
        XCTAssertEqual(translator.availabilityRequests, availability, file: file, line: line)
        XCTAssertEqual(translator.translationRequests, translations, file: file, line: line)
        XCTAssertEqual(translator.prepareRequests, preparations, file: file, line: line)
        XCTAssertEqual(worker.searchRequests.map(\.text), searches, file: file, line: line)
        XCTAssertEqual(worker.searchRequests.map(\.limit), searches.map { _ in 3 }, file: file, line: line)
        XCTAssertEqual(worker.searchRequests.map { $0.weight.bitPattern },
                       searches.map { _ in Float(0.6).bitPattern }, file: file, line: line)
        XCTAssertEqual(worker.refreshCount, 1, "Rendering/translation must not refresh again", file: file, line: line)
        XCTAssertEqual(worker.indexCount, 0, file: file, line: line)
        XCTAssertEqual(worker.clearCount, 0, file: file, line: line)
        XCTAssertEqual(worker.checkCount, 0, file: file, line: line)
        XCTAssertTrue(worker.indexNetworkFlags.isEmpty, file: file, line: line)
        XCTAssertFalse(state.allowICloudDownload, file: file, line: line)
        XCTAssertEqual(state.progress, IndexProgress(), file: file, line: line)
        XCTAssertNil(state.photoCheckReport, file: file, line: line)
        XCTAssertNil(state.photoCheckIssue, file: file, line: line)
        XCTAssertEqual(state.summary.authorizedCount, worker.summary.authorizedCount, file: file, line: line)
        XCTAssertEqual(state.summary.indexedCount, worker.summary.indexedCount, file: file, line: line)
        XCTAssertEqual(state.summary.locatedCount, worker.summary.locatedCount, file: file, line: line)
        XCTAssertEqual(state.summary.modelVersion, worker.summary.modelVersion, file: file, line: line)
        XCTAssertNil(state.summary.modelIssue, file: file, line: line)
        XCTAssertEqual(state.summary.placesDescription, worker.summary.placesDescription, file: file, line: line)
    }

    private func assertRedacted(_ state: AppState, file: StaticString, line: UInt) {
        let visibleText = [state.completedSearchQuery?.notice, state.translationPreparationIssue,
                           state.errorMessage, state.actionHint, state.photoCheckIssue, state.progress.lastFailure,
                           state.status].compactMap { $0 }.joined(separator: "\n")
        for marker in QueryTranslationPresentationFixture.privateMarkers {
            XCTAssertFalse(visibleText.contains(marker), "Synthetic private error metadata must not be published",
                           file: file, line: line)
        }
    }

    // MARK: Actual native views; no reconstructed search or language-pack UI

    private func translatedSnapshot(_ context: QueryTranslationPresentationContext, id: String, size: CGSize,
                                    dynamicTypeSize: DynamicTypeSize = .large) async throws {
        let validate: @MainActor () -> Void = {
            self.assertResolution(context, effective: QueryTranslationPresentationFixture.english, translated: true)
            self.assertCalls(context, searches: [QueryTranslationPresentationFixture.english],
                             availability: [context.language], translations: [context.translationRequest])
        }
        validate()
        try await snapshot(ContentView(state: context.state), id: id, size: size,
                           dynamicTypeSize: dynamicTypeSize, validate: validate)
        validate()
    }

    /// iOS 18 Form uses a UICollectionView. Scroll the real second section, not a
    /// copied translationSection or a screenshot of a taller offscreen canvas.
    /// Fail clearly if that UIKit structure changes instead of capturing the wrong section.
    private func revealLanguagePackSection(in view: UIView) async throws {
        let collection = try XCTUnwrap(descendants(of: view).compactMap { $0 as? UICollectionView }.first,
                                       "Expected the actual Settings Form collection view on iOS 18")
        guard collection.numberOfSections > 1, collection.numberOfItems(inSection: 1) >= 4 else {
            XCTFail("Settings language-pack section must contain toggle, picker, availability and preparation rows")
            throw QueryTranslationPresentationFixture.HarnessFailure.missingLanguageSection
        }
        let rows = (0..<4).map { IndexPath(item: $0, section: 1) }
        collection.scrollToItem(at: rows[0], at: .top, animated: false)
        await settle(view)
        for row in rows {
            let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: row))
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(row), "Capture the real language-pack controls")
            let viewport = collection.bounds.inset(by: collection.adjustedContentInset)
            XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(attributes.frame),
                          "Each language-pack control row must fit within the captured phone viewport")
        }
        // The potentially long section footer and all other settings are NOT
        // guaranteed visible. Row visibility does not prove text never truncates.
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func settle(_ view: UIView) async {
        let settled = expectation(description: "Pending native SwiftUI layout updates completed")
        DispatchQueue.main.async {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            DispatchQueue.main.async {
                view.layoutIfNeeded()
                settled.fulfill()
            }
        }
        await fulfillment(of: [settled], timeout: 5)
    }

    /// File-private adaptation of LocalPreviewComparisonPresentationTests' native
    /// UIWindow/UIHostingController helper; no existing helper visibility changes.
    private func snapshot<Content: View>(_ content: Content, id: String, size: CGSize,
                                         dynamicTypeSize: DynamicTypeSize = .large,
                                         afterLayout: @MainActor (UIView) async throws -> Void = { _ in },
                                         validate: @MainActor () -> Void) async throws {
        XCTAssertTrue(size == phone || size == compactPhone)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
                                  "Native captures require the iOS app test host")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        let root = VStack(spacing: 0) {
            Text("TEST FIXTURE · fake translation · no photos")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.black)
                .accessibilityIdentifier("query-translation-test-watermark")
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Locale(identifier: "en_US"))
        .environment(\.layoutDirection, .leftToRight)
        .environment(\.dynamicTypeSize, dynamicTypeSize)
        .environment(\.scenePhase, .active)
        let host = QueryTranslationPresentationHostingController(rootView: root)
        host.overrideUserInterfaceStyle = .dark
        let laidOut = expectation(description: "\(id): native phone-size layout")
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
        await settle(host.view)
        try await afterLayout(host.view)
        await settle(host.view)
        validate() // Includes exact request counts after any real SwiftUI .task.
        XCTAssertTrue(host.view.window === window)
        XCTAssertTrue(window.rootViewController === host)
        XCTAssertFalse(window.isHidden)
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
        XCTAssertTrue(drewHierarchy, "Draw the actual hosted production hierarchy")
        XCTAssertEqual(image.size, size)
        let pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, Int(size.width))
        XCTAssertEqual(pixels.height, Int(size.height))
        validate() // Drawing can service pending UI work too.
        let attachment = XCTAttachment(image: image)
        attachment.name = "UIReview-query-translation-\(id)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // No fifth capture, full-scroll stitching, copied UI or real image. Human
        // review is still needed for clipping, button legibility and large fonts.
    }
}

@MainActor
private final class QueryTranslationPresentationHostingController<Content: View>: UIHostingController<Content> {
    var onLayout: (() -> Void)?
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }
}

private enum QueryTranslationPresentationFixture {
    // These short synthetic queries belong ONLY to the test target.
    static let original = "雨中的小狗"
    static let english = "a dog in the rain"
    static let missingPackNotice = "离线语言包未就绪，本次使用原文。可在设置中下载。"
    static let failureNotice = "离线翻译未完成，本次使用原文。"
    static let privateMarkers = ["TEST_PRIVATE_TRANSLATION_DOMAIN", "TEST_PRIVATE_ASSET",
                                 "/TEST_PRIVATE/IMG_TEST.JPG", "TEST_GPS_12.34_56.78"]
    static var privateError: NSError {
        NSError(domain: privateMarkers[0], code: 7,
                userInfo: [NSLocalizedDescriptionKey: privateMarkers.joined(separator: " | ")])
    }
    enum HarnessFailure: Error { case unexpectedWork, missingLanguageSection }
}

@MainActor
private final class QueryTranslationPresentationTranslator: QueryTranslating {
    struct Request: Equatable {
        let text: String
        let language: QueryTranslationLanguage
    }
    let isSupported = true // Deliberately fake: no claim about Apple support on Simulator.
    let availabilityResult: QueryTranslationAvailability
    let translationResult: Result<String, Error>
    var preparationError: Error?
    var nextAvailability: XCTestExpectation?
    private(set) var availabilityRequests: [QueryTranslationLanguage] = []
    private(set) var translationRequests: [Request] = []
    private(set) var prepareRequests: [QueryTranslationLanguage] = []

    init(availability: QueryTranslationAvailability, translation: Result<String, Error>) {
        availabilityResult = availability
        translationResult = translation
    }
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        availabilityRequests.append(language)
        let checked = nextAvailability
        nextAvailability = nil
        checked?.fulfill()
        return availabilityResult
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        translationRequests.append(Request(text: text, language: language))
        return try translationResult.get()
    }
    func prepare(_ language: QueryTranslationLanguage) async throws {
        prepareRequests.append(language)
        if let preparationError { throw preparationError }
        XCTFail("Presentation must never implicitly request preparation, even from the fake")
        throw QueryTranslationPresentationFixture.HarnessFailure.unexpectedWork
    }
}

/// MainActor isolation satisfies the Sendable worker boundary without unchecked
/// sharing. Unexpected work fails here; no method can fall through to Photos.
@MainActor
private final class QueryTranslationPresentationWorker: PhotoWorkServicing {
    struct SearchRequest {
        let text: String
        let limit: Int
        let weight: Float
    }
    let summary = LibrarySummary(authorizedCount: 8, indexedCount: 8, locatedCount: 0,
                                 modelVersion: "TEST-query-translation-no-model",
                                 placesDescription: "TEST FIXTURE: no place data")
    private(set) var refreshCount = 0
    private(set) var indexCount = 0
    private(set) var clearCount = 0
    private(set) var checkCount = 0
    private(set) var indexNetworkFlags: [Bool] = []
    private(set) var searchRequests: [SearchRequest] = []

    func refresh() async throws -> LibrarySummary {
        refreshCount += 1
        return summary
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        searchRequests.append(SearchRequest(text: text, limit: limit, weight: locationWeight))
        return SearchResponse(summary: summary, hits: [])
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        indexCount += 1
        indexNetworkFlags.append(networkAllowed)
        XCTFail("Query presentation must not index images")
        throw QueryTranslationPresentationFixture.HarnessFailure.unexpectedWork
    }
    func clear() async throws -> LibrarySummary {
        clearCount += 1
        XCTFail("Query presentation must not clear an index")
        throw QueryTranslationPresentationFixture.HarnessFailure.unexpectedWork
    }
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        checkCount += 1
        XCTFail("Zero-hit presentation must not inspect a photo")
        throw QueryTranslationPresentationFixture.HarnessFailure.unexpectedWork
    }
}

@MainActor
private final class QueryTranslationPresentationContext {
    let language: QueryTranslationLanguage
    let translator: QueryTranslationPresentationTranslator
    let worker: QueryTranslationPresentationWorker
    let state: AppState
    var translationRequest: QueryTranslationPresentationTranslator.Request {
        .init(text: QueryTranslationPresentationFixture.original, language: language)
    }

    init(language: QueryTranslationLanguage, availability: QueryTranslationAvailability, translation: Result<String, Error>) {
        self.language = language
        let translator = QueryTranslationPresentationTranslator(availability: availability, translation: translation)
        let worker = QueryTranslationPresentationWorker()
        self.translator = translator
        self.worker = worker
        state = AppState(worker: worker, authorizationStatus: { .authorized },
                         queryTranslator: translator, translationPreferences: nil)
    }
    func cancelAndDrain() async {
        state.cancel()
        await state.waitUntilIdle()
        translator.nextAvailability = nil
    }
}
#endif