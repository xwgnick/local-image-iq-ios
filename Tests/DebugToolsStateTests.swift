import XCTest
import Foundation
import CoreGraphics
import Photos
import ImageIQCore
@testable import LocalImageIQ

/// Synthetic services/pixels only; no asset fetches, encoders, database or network.
/// AppState still constructs its normal PhotoKit authorization/observer wrapper.
/// Holds ignore cancellation until explicitly released; no sleeps or polling.
@MainActor
final class DebugToolsStateTests: XCTestCase {
    func testEveryNewStateStartsOffAndDebugFlagNeverPersists() throws {
        let legacyValues: [Any?] = [nil, true, "bogus-enabled"]
        XCTAssertFalse(context().state.debugToolsEnabled)
        for legacy in legacyValues {
            var values: [String: Any] = ["unrelated": "preserve", "chineseSearchEnabled.v1": false]
            if let legacy { values["debugToolsEnabled"] = legacy; values["debugToolsEnabled.v1"] = legacy }
            let (preferences, suite) = try defaults(values)
            let before = try XCTUnwrap(preferences.persistentDomain(forName: suite)) as NSDictionary
            let first = context(preferences: preferences)
            XCTAssertFalse(first.state.debugToolsEnabled)
            XCTAssertFalse(first.state.chineseSearchEnabled, "The injected preferences were actually read")
            for enabled in [true, false, true] {
                first.state.debugToolsEnabled = enabled
                XCTAssertEqual(first.state.debugToolsEnabled, enabled)
                XCTAssertEqual(try XCTUnwrap(preferences.persistentDomain(forName: suite)) as NSDictionary, before)
            }
            let second = context(preferences: preferences)
            XCTAssertFalse(second.state.debugToolsEnabled)
            XCTAssertTrue(first.state.debugToolsEnabled, "Each live session owns its own flag")
            XCTAssertEqual(try XCTUnwrap(preferences.persistentDomain(forName: suite)) as NSDictionary, before)
            XCTAssertTrue(first.calls.calls.isEmpty)
            XCTAssertTrue(second.calls.calls.isEmpty)
        }
    }

    func testDisabledPhotoCheckRejectsValidRequestWithoutCallingWorker() async {
        let c = await ready(searched: true)
        let before = c.calls.calls
        c.state.checkPhoto(id: "debug-b", query: DebugToolsFixture.english)
        await c.state.waitUntilIdle()
        XCTAssertEqual(c.calls.calls, before)
        XCTAssertNil(c.state.activity)
        XCTAssertNil(c.state.photoCheckReport)
        XCTAssertNil(c.state.photoCheckIssue)
        assertVisible(c)
    }

    func testTurningOffClearsCompletedPhotoReportOrIssueWithoutChangingSearch() async {
        for failure in [false, true] {
            let c = await ready(searched: true)
            c.worker.failCheck = failure
            c.state.debugToolsEnabled = true
            let before = c.calls.calls
            c.state.checkPhoto(id: "debug-b", query: DebugToolsFixture.english)
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.calls.calls, before + [.check])
            if failure {
                XCTAssertNotNil(c.state.photoCheckIssue)
                XCTAssertNil(c.state.photoCheckReport)
            } else {
                XCTAssertEqual(c.state.photoCheckReport?.photoID, "debug-b")
                XCTAssertEqual(c.state.photoCheckReport?.query, DebugToolsFixture.english)
                XCTAssertEqual(c.state.photoCheckReport?.locationWeight, Float(0.37))
                XCTAssertNil(c.state.photoCheckIssue)
            }
            assertVisible(c)
            c.state.debugToolsEnabled = false
            XCTAssertNil(c.state.photoCheckReport)
            XCTAssertNil(c.state.photoCheckIssue)
            assertVisible(c)
            XCTAssertEqual(c.calls.calls, before + [.check])
            XCTAssertTrue(c.calls.cancelled.isEmpty)
        }
    }

    func testHeldPhotoSuccessAndFailureStayDiscardedEvenAfterReenabling() async {
        for failure in [false, true] {
            for reenable in [false, true] {
                let c = await ready(searched: true)
                c.worker.failCheck = failure
                c.state.debugToolsEnabled = true
                let started = hold(c.calls, .check)
                let before = c.calls.calls
                c.state.checkPhoto(id: "debug-b", query: DebugToolsFixture.english)
                await fulfillment(of: [started], timeout: 3)
                XCTAssertEqual(c.state.activity, .checkingPhoto)
                c.state.debugToolsEnabled = false
                XCTAssertNil(c.state.photoCheckReport)
                XCTAssertNil(c.state.photoCheckIssue)
                if reenable { c.state.debugToolsEnabled = true }
                assertVisible(c)
                c.calls.release()
                await c.state.waitUntilIdle()
                XCTAssertEqual(c.calls.calls, before + [.check])
                XCTAssertEqual(c.calls.finished, c.calls.calls)
                XCTAssertEqual(c.calls.cancelled, [.check])
                XCTAssertNil(c.state.photoCheckReport)
                XCTAssertNil(c.state.photoCheckIssue)
                XCTAssertNil(c.state.errorMessage)
                XCTAssertNil(c.state.actionHint)
                XCTAssertNil(c.state.activity)
                assertVisible(c)
            }
        }
    }

    func testOffOnDoesNotCancelIndexSearchRefreshOrClear() async {
        let cases: [(DebugToolsCall, AppState.Activity)] = [
            (.index, .indexing), (.search, .searching), (.refresh, .refreshing), (.clear, .clearing)
        ]
        for (call, activity) in cases {
            let c = await ready()
            let started = hold(c.calls, call)
            switch call {
            case .index: c.state.index()
            case .search: c.state.search()
            case .refresh: c.state.refresh()
            default: c.state.clearIndex()
            }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertEqual(c.state.activity, activity)
            let entered = c.calls.calls, progress = c.state.progress
            toggle(c.state)
            XCTAssertEqual(c.state.activity, activity)
            XCTAssertEqual(c.state.progress, progress)
            c.calls.release()
            await c.state.waitUntilIdle()
            XCTAssertEqual(c.calls.calls, entered, "Toggling must not enqueue replacement work")
            XCTAssertEqual(c.calls.finished, entered)
            XCTAssertTrue(c.calls.cancelled.isEmpty, "Normal work was cancelled: \(call)")
            XCTAssertNil(c.state.activity)
            XCTAssertNil(c.state.errorMessage)
            XCTAssertEqual(c.state.summary.indexedCount, call == .clear ? 0 : 2)
            if call == .search { XCTAssertEqual(c.state.completedSearchQuery?.effective, DebugToolsFixture.english) }
            if call == .index {
                XCTAssertEqual(c.worker.networkFlags, [true])
                XCTAssertEqual(c.state.progress.encoded, 1)
            }
        }
    }

    func testOffOnDoesNotCancelSearchTranslationOrLanguagePreparation() async {
        for preparing in [false, true] {
            let phases: [DebugToolsCall] = preparing ? [.prepare, .availability] : [.availability, .translate]
            for phase in phases {
                let c = await ready()
                let before = c.calls.calls
                let started = hold(c.calls, phase)
                if preparing { c.state.prepareTranslation() } else { c.state.search() }
                await fulfillment(of: [started], timeout: 3)
                toggle(c.state)
                XCTAssertEqual(c.state.activity, preparing ? .preparingTranslation : .searching)
                c.calls.release()
                await c.state.waitUntilIdle()
                let expected: [DebugToolsCall] = preparing ? [.prepare, .availability] : [.availability, .translate, .search]
                XCTAssertEqual(c.calls.calls, before + expected)
                XCTAssertEqual(c.calls.finished, c.calls.calls)
                XCTAssertTrue(c.calls.cancelled.isEmpty)
                XCTAssertNil(c.state.translationPreparationIssue)
                XCTAssertNil(c.state.activity)
                XCTAssertTrue(c.state.allowICloudDownload)
                if preparing { XCTAssertEqual(c.state.translationAvailability, .installed) }
                else { XCTAssertEqual(c.state.completedSearchQuery?.effective, DebugToolsFixture.english) }
            }
        }
    }

    func testOffOnPreservesHeldSettingsAvailabilityRefresh() async {
        let c = context()
        let started = hold(c.calls, .availability)
        let task = Task { @MainActor in await c.state.checkTranslationAvailability() }
        addTeardownBlock { @MainActor in c.calls.release(); await task.value }
        await fulfillment(of: [started], timeout: 3)
        toggle(c.state)
        c.calls.release()
        await task.value
        XCTAssertEqual(c.state.translationAvailability, .installed)
        XCTAssertEqual(c.calls.calls, [.availability])
        XCTAssertEqual(c.calls.finished, [.availability])
        XCTAssertTrue(c.calls.cancelled.isEmpty)
    }

    func testRegistrationWhileOffRejectsWithoutAutostartAndClearsResultOrError() async throws {
        for failure in [false, true] {
            let c = context(), p = try preview(failure: failure)
            XCTAssertFalse(c.state.registerDebugPreview(p.state))
            await p.state.waitUntilIdle()
            XCTAssertTrue(p.service.calls.calls.isEmpty)
            p.state.start()
            await p.state.waitUntilIdle()
            if failure { XCTAssertNotNil(p.state.errorMessage) }
            else { XCTAssertNotNil(p.state.result?.entries.first?.preview) }
            XCTAssertFalse(c.state.registerDebugPreview(p.state))
            assertEmpty(p.state)
            XCTAssertEqual(p.service.calls.calls, [.preview])
            XCTAssertTrue(c.calls.calls.isEmpty)
        }
    }

    func testRegistrationWhileOffCancelsRunningPreviewAndRejectsLateSuccess() async throws {
        let c = context(), p = try preview()
        let started = hold(p.service.calls, .preview)
        p.state.start()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(c.state.registerDebugPreview(p.state))
        assertEmpty(p.state)
        p.service.calls.release()
        await p.state.waitUntilIdle()
        XCTAssertEqual(p.service.calls.cancelled, [.preview])
        XCTAssertEqual(p.service.calls.finished, [.preview])
        assertEmpty(p.state)
    }

    func testEnabledRegistrationDoesNotAutostartOrCancelSameIdentity() async throws {
        let c = context(), p = try preview()
        c.state.debugToolsEnabled = true
        XCTAssertTrue(c.state.registerDebugPreview(p.state))
        await p.state.waitUntilIdle()
        XCTAssertTrue(p.service.calls.calls.isEmpty)
        let started = hold(p.service.calls, .preview)
        p.state.start()
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(c.state.registerDebugPreview(p.state))
        c.state.debugToolsEnabled = true // Same-value didSet must not clear anything.
        XCTAssertTrue(p.state.isRunning)
        p.service.calls.release()
        await p.state.waitUntilIdle()
        XCTAssertEqual(p.state.result?.entries.count, 3)
        XCTAssertEqual(p.service.calls.calls, [.preview])
        XCTAssertTrue(p.service.calls.cancelled.isEmpty)
        XCTAssertTrue(c.state.registerDebugPreview(p.state))
        XCTAssertNotNil(p.state.result)
    }

    func testReplacingIdentityCancelsOldAndUnregisteringOldCannotDetachNew() async throws {
        let c = context(), old = try preview(), new = try preview()
        c.state.debugToolsEnabled = true
        XCTAssertTrue(c.state.registerDebugPreview(old.state))
        let oldStarted = hold(old.service.calls, .preview)
        old.state.start()
        await fulfillment(of: [oldStarted], timeout: 3)
        XCTAssertTrue(c.state.registerDebugPreview(new.state))
        assertEmpty(old.state)
        XCTAssertTrue(new.service.calls.calls.isEmpty)
        let newStarted = hold(new.service.calls, .preview)
        new.state.start()
        await fulfillment(of: [newStarted], timeout: 3)
        c.state.unregisterDebugPreview(old.state)
        old.service.calls.release()
        await old.state.waitUntilIdle()
        XCTAssertEqual(old.service.calls.cancelled, [.preview])
        assertEmpty(old.state)
        XCTAssertTrue(new.state.isRunning)
        c.state.debugToolsEnabled = false // Must still find and cancel the NEW registration.
        assertEmpty(new.state)
        new.service.calls.release()
        await new.state.waitUntilIdle()
        XCTAssertEqual(new.service.calls.cancelled, [.preview])
        XCTAssertEqual(new.service.calls.calls, [.preview])
        assertEmpty(new.state)
    }

    func testTurningOffClearsCompletedPreviewAndPreservesVisibleSearch() async throws {
        let c = await ready(searched: true), p = try preview()
        c.state.debugToolsEnabled = true
        XCTAssertTrue(c.state.registerDebugPreview(p.state))
        p.state.start()
        await p.state.waitUntilIdle()
        XCTAssertNotNil(p.state.result?.entries.first?.preview)
        let before = c.calls.calls
        c.state.debugToolsEnabled = false
        assertEmpty(p.state)
        assertVisible(c)
        c.state.debugToolsEnabled = true
        await p.state.waitUntilIdle()
        assertEmpty(p.state)
        XCTAssertEqual(p.service.calls.calls, [.preview])
        XCTAssertEqual(c.calls.calls, before)
    }

    func testTurningOffRejectsRunningPreviewLateSuccessOrFailureAfterReenable() async throws {
        for failure in [false, true] {
            let c = context(), p = try preview(failure: failure)
            c.state.debugToolsEnabled = true
            XCTAssertTrue(c.state.registerDebugPreview(p.state))
            let started = hold(p.service.calls, .preview)
            p.state.start()
            await fulfillment(of: [started], timeout: 3)
            c.state.debugToolsEnabled = false
            assertEmpty(p.state)
            c.state.debugToolsEnabled = true
            p.service.calls.release()
            await p.state.waitUntilIdle()
            XCTAssertEqual(p.service.calls.calls, [.preview])
            XCTAssertEqual(p.service.calls.finished, [.preview])
            XCTAssertEqual(p.service.calls.cancelled, [.preview])
            assertEmpty(p.state)
        }
    }

    func testRegistrationDoesNotRetainPreviewOrItsService() throws {
        let c = context()
        c.state.debugToolsEnabled = true
        var service: DebugToolsPreview? = try DebugToolsPreview()
        var state: LocalPreviewComparisonState? = LocalPreviewComparisonState(service: try XCTUnwrap(service), photoID: "debug-b")
        weak var weakState = state
        weak var weakService = service
        XCTAssertTrue(c.state.registerDebugPreview(try XCTUnwrap(state)))
        state = nil
        service = nil
        XCTAssertNil(weakState)
        XCTAssertNil(weakService)
        c.state.debugToolsEnabled = false // Safe with an expired registration.
    }

    private func context(preferences: UserDefaults? = nil) -> DebugToolsContext {
        let c = DebugToolsContext(preferences: preferences)
        addTeardownBlock { @MainActor in c.calls.release(); await c.state.waitUntilIdle() }
        return c
    }
    private func ready(searched: Bool = false) async -> DebugToolsContext {
        let c = context()
        c.state.query = DebugToolsFixture.original
        c.state.locationWeight = 0.37
        c.state.resultLimit = 12
        c.state.allowICloudDownload = true
        c.state.translationLanguage = .traditional
        c.state.refresh()
        await c.state.waitUntilIdle()
        XCTAssertTrue(c.state.canSearch)
        XCTAssertNil(c.state.appleTranslationService)
        if searched {
            c.state.search()
            await c.state.waitUntilIdle()
            c.state.selection = AppState.Selection(id: "debug-b")
            assertVisible(c)
        }
        return c
    }
    private func preview(failure: Bool = false) throws -> (state: LocalPreviewComparisonState, service: DebugToolsPreview) {
        let service = try DebugToolsPreview(failure: failure)
        let state = LocalPreviewComparisonState(service: service, photoID: "debug-b")
        addTeardownBlock { @MainActor in
            state.cancelAndClear(); service.calls.release(); await state.waitUntilIdle()
        }
        return (state, service)
    }
    private func hold(_ calls: DebugToolsCalls, _ phase: DebugToolsCall) -> XCTestExpectation {
        let started = expectation(description: "Fake suspended in \(phase)")
        calls.hold(phase, started: started)
        return started
    }
    private func toggle(_ state: AppState) {
        state.debugToolsEnabled = true
        state.debugToolsEnabled = false
        state.debugToolsEnabled = true
    }
    private func defaults(_ values: [String: Any]) throws -> (UserDefaults, String) {
        let suite = "DebugToolsStateTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.setPersistentDomain(values, forName: suite)
        addTeardownBlock { preferences.removePersistentDomain(forName: suite) }
        return (preferences, suite)
    }
    private func assertEmpty(_ state: LocalPreviewComparisonState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(state.isRunning, file: file, line: line)
        XCTAssertNil(state.result, file: file, line: line)
        XCTAssertNil(state.errorMessage, file: file, line: line)
    }
    private func assertVisible(_ c: DebugToolsContext, file: StaticString = #filePath, line: UInt = #line) {
        let s = c.state
        XCTAssertEqual(s.query, DebugToolsFixture.original, file: file, line: line)
        XCTAssertEqual(s.completedQuery, DebugToolsFixture.original, file: file, line: line)
        XCTAssertEqual(s.completedSearchQuery, SearchQueryResolution(original: DebugToolsFixture.original,
            effective: DebugToolsFixture.english, translated: true, notice: nil), file: file, line: line)
        XCTAssertEqual(s.photoCheckInitialQuery, DebugToolsFixture.english, file: file, line: line)
        XCTAssertEqual(s.selection?.id, "debug-b", file: file, line: line)
        XCTAssertEqual(s.locationWeight, 0.37, file: file, line: line)
        XCTAssertEqual(s.resultLimit, 12, file: file, line: line)
        XCTAssertTrue(s.allowICloudDownload, file: file, line: line)
        XCTAssertTrue(s.chineseSearchEnabled, file: file, line: line)
        XCTAssertEqual(s.translationLanguage, .traditional, file: file, line: line)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(s.results), try encoder.encode(c.worker.response.hits), file: file, line: line)
        XCTAssertEqual(s.summary.indexedCount, 2, file: file, line: line)
    }
}

private enum DebugToolsCall: Equatable { case refresh, index, search, check, clear, availability, translate, prepare, preview }
private enum DebugToolsFailure: Error { case synthetic }
private enum DebugToolsFixture {
    static let original = " \t白色的笔和小狗\n "
    static let english = "TEST FIXTURE a white pen and a dog"
    static var response: SearchResponse {
        let hits = [SearchHit(photo: TestFixtures.photo(id: "debug-b").photo, score: 0.8125),
                    SearchHit(photo: TestFixtures.photo(id: "debug-a").photo, score: -0.125)]
        return SearchResponse(summary: LibrarySummary(authorizedCount: 2, indexedCount: 2, modelVersion: "test-model"), hits: hits)
    }
}

@MainActor
private final class DebugToolsCalls {
    var calls: [DebugToolsCall] = [], finished: [DebugToolsCall] = [], cancelled: [DebugToolsCall] = []
    private var held: DebugToolsCall?
    private var started: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    func hold(_ call: DebugToolsCall, started: XCTestExpectation) {
        precondition(held == nil && continuation == nil, "Release the previous fake hold before rearming")
        held = call; self.started = started
    }
    func enter(_ call: DebugToolsCall) async {
        calls.append(call)
        if held == call {
            held = nil
            await withCheckedContinuation { continuation = $0; started?.fulfill(); started = nil }
        }
        // Cancellation is sticky: observing it after the hold detects any cancellation
        // during that work, without making the fake throw or suppress its late result.
        if Task.isCancelled { cancelled.append(call) }
        finished.append(call)
    }
    func release() { held = nil; started = nil; let pending = continuation; continuation = nil; pending?.resume() }
}

@MainActor
private final class DebugToolsWorker: PhotoWorkServicing {
    let calls: DebugToolsCalls
    let response = DebugToolsFixture.response
    var failCheck = false
    var networkFlags: [Bool] = []
    init(_ calls: DebugToolsCalls) { self.calls = calls }
    func refresh() async throws -> LibrarySummary { await calls.enter(.refresh); return response.summary }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        await calls.enter(.search); return response
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        networkFlags.append(networkAllowed)
        await progress(IndexProgress(total: 2, completed: 1, encoded: 1))
        await calls.enter(.index); return response.summary
    }
    func clear() async throws -> LibrarySummary { await calls.enter(.clear); return LibrarySummary(modelVersion: "test-model") }
    func checkPhoto(id: String, query: String, locationWeight: Float) async throws -> PhotoDiagnosticReport {
        let failure = failCheck
        await calls.enter(.check)
        if failure { throw DebugToolsFailure.synthetic }
        return PhotoDiagnosticReport(photoID: id, query: query, locationWeight: locationWeight, galleryCount: 2,
                                     cachedRank: 2, freshRank: 1, modelVersion: "test-model", cachedStatus: "current")
    }
}

@MainActor
private final class DebugToolsTranslator: QueryTranslating {
    let isSupported = true
    let calls: DebugToolsCalls
    init(_ calls: DebugToolsCalls) { self.calls = calls }
    func availability(for language: QueryTranslationLanguage) async -> QueryTranslationAvailability {
        await calls.enter(.availability); return .installed
    }
    func translate(_ text: String, from language: QueryTranslationLanguage) async throws -> String {
        await calls.enter(.translate); return DebugToolsFixture.english
    }
    func prepare(_ language: QueryTranslationLanguage) async throws { await calls.enter(.prepare) }
}

@MainActor
private final class DebugToolsContext {
    let calls = DebugToolsCalls()
    let worker: DebugToolsWorker
    let state: AppState
    init(preferences: UserDefaults?) {
        worker = DebugToolsWorker(calls)
        state = AppState(worker: worker, authorizationStatus: { .authorized },
                         queryTranslator: DebugToolsTranslator(calls), translationPreferences: preferences)
    }
}

@MainActor
private final class DebugToolsPreview: LocalPreviewComparing {
    let calls = DebugToolsCalls()
    let report: LocalPreviewComparison
    let failure: Bool
    init(failure: Bool = false) throws {
        self.failure = failure
        let pixels = try TestFixtures.image(width: 2, height: 2) { x, y in (UInt8(x * 80), UInt8(y * 80), 40) }
        let image = IndexingImage(cgImage: pixels, orientation: .up, source: .localReducedPreview)
        report = LocalPreviewComparison(photoID: "debug-b", revision: PhotoRevision(id: "debug-b", modificationTime: 123),
            authorizationRawValue: PHAuthorizationStatus.authorized.rawValue,
            entries: LocalPreviewMode.allCases.map {
                LocalPreviewEntry(mode: $0, requestedSize: CGSize(width: CGFloat($0.shortEdge), height: CGFloat($0.shortEdge)), preview: image, issue: nil)
            })
    }
    func compareLocalPreviews(id: String) async throws -> LocalPreviewComparison {
        XCTAssertEqual(id, report.photoID)
        await calls.enter(.preview)
        if failure { throw DebugToolsFailure.synthetic }
        return report
    }
    nonisolated func isCurrent(_ comparison: LocalPreviewComparison) -> Bool { comparison.photoID == "debug-b" }
}