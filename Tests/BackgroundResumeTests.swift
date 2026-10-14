import Combine
import Foundation
import Photos
import XCTest
@testable import LocalImageIQ

@MainActor
final class BackgroundResumeTests: XCTestCase {
    func testLateExpirationFromPreviousLeaseCannotCancelNewBackgroundContinuation() async throws {
        let saved = expectation(description: "image held across two background periods")
        let gate = ResumeGate()
        let worker = ResumeWorker(imageHold: gate, imageSaved: saved)
        let lease = ResumeLease()
        let state = self.state(worker, lease: lease)
        state.start()
        await state.waitUntilIdle()
        state.index()
        await fulfillment(of: [saved], timeout: 3)
        state.enterBackground()
        let previousExpiration = try XCTUnwrap(lease.expirationHandler)
        state.enterForeground()
        XCTAssertEqual(state.activity, .indexing)
        state.enterBackground()
        XCTAssertEqual(lease.begins, 2)
        previousExpiration()
        XCTAssertTrue(state.backgroundExecutionAllowed)
        await gate.open()
        await state.waitUntilIdle()
        let counts = await worker.counts()
        XCTAssertEqual(counts.indexCalls, 1)
        XCTAssertEqual(counts.imageWrites, 3)
        XCTAssertEqual(lease.ends, 2)
    }

    private func preferences() throws -> UserDefaults {
        let suite = "BackgroundResumeTests.\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    private func state(_ worker: ResumeWorker, preferences: UserDefaults? = nil,
                       lease: ResumeLease? = nil) -> AppState {
        AppState(worker: worker, authorizationStatus: { .authorized },
                 textSearchPreferences: preferences, workPreferences: preferences, backgroundLease: lease)
    }

    func testFiniteLeaseFinishesAdmittedIndexWithoutForegroundRestartAndEndsWhenIdle() async throws {
        let saved = expectation(description: "first real image commit")
        let gate = ResumeGate()
        let worker = ResumeWorker(imageHold: gate, imageSaved: saved)
        let preferences = try self.preferences()
        let lease = ResumeLease()
        let state = self.state(worker, preferences: preferences, lease: lease)
        state.start()
        await state.waitUntilIdle()
        state.index()
        await fulfillment(of: [saved], timeout: 3)
        state.enterBackground()
        XCTAssertTrue(state.backgroundExecutionAllowed)
        XCTAssertFalse(state.isForeground)
        XCTAssertEqual(state.activity, .indexing)
        XCTAssertEqual(lease.begins, 1)
        await gate.open()
        await state.waitUntilIdle()
        let counts = await worker.counts()
        XCTAssertEqual(counts.indexCalls, 1)
        XCTAssertEqual(counts.imageWrites, 3)
        XCTAssertFalse(state.backgroundExecutionAllowed)
        XCTAssertEqual(lease.ends, 1)
        XCTAssertFalse(preferences.bool(forKey: "interruptedImageIndex.v1"))
        state.enterForeground()
        await state.waitUntilIdle()
        let after = await worker.counts()
        XCTAssertEqual(after.indexCalls, 1)
        XCTAssertEqual(state.summary.indexedCount, 3)
    }

    func testExpirationThenImmediateForegroundDrainsBeforeContinuingAndNeverReencodesCommit() async throws {
        let saved = expectation(description: "first real image commit")
        let gate = ResumeGate()
        let worker = ResumeWorker(imageHold: gate, imageSaved: saved)
        let preferences = try self.preferences()
        let lease = ResumeLease()
        let state = self.state(worker, preferences: preferences, lease: lease)
        state.start()
        await state.waitUntilIdle()
        state.index()
        await fulfillment(of: [saved], timeout: 3)
        state.enterBackground()
        lease.expire()
        XCTAssertFalse(state.backgroundExecutionAllowed)
        XCTAssertTrue(preferences.bool(forKey: "interruptedImageIndex.v1"))
        state.enterForeground()
        let before = await worker.counts()
        XCTAssertEqual(before.indexCalls, 1, "Cancellation is not completion of the held predecessor.")
        await gate.open()
        await state.waitUntilIdle()
        let after = await worker.counts()
        XCTAssertEqual(after.indexCalls, 2)
        XCTAssertEqual(after.imageWrites, 3, "The first committed image is reused, not reencoded.")
        XCTAssertEqual(after.clears, 0)
        XCTAssertEqual(state.progress.reused, 1)
        XCTAssertEqual(state.progress.encoded, 2)
        XCTAssertTrue(state.imageIndexResuming)
        XCTAssertEqual(state.summary.indexedCount, 3)
        XCTAssertFalse(preferences.bool(forKey: "interruptedImageIndex.v1"))
    }

    func testPersistedInterruptionSurvivesNewAppStateButUserCancelDoesNot() async throws {
        for userCancelled in [false, true] {
            let saved = expectation(description: "committed image \(userCancelled)")
            let gate = ResumeGate()
            let worker = ResumeWorker(imageHold: gate, imageSaved: saved)
            let preferences = try self.preferences()
            let old = state(worker, preferences: preferences)
            old.start()
            await old.waitUntilIdle()
            old.index()
            await fulfillment(of: [saved], timeout: 3)
            old.enterBackground() // No lease: safe immediate pause.
            if userCancelled { old.cancel() }
            await gate.open()
            await old.waitUntilIdle()
            let relaunched = state(worker, preferences: preferences)
            relaunched.start()
            await relaunched.waitUntilIdle()
            let counts = await worker.counts()
            XCTAssertEqual(counts.indexCalls, userCancelled ? 1 : 2)
            XCTAssertEqual(counts.imageWrites, userCancelled ? 1 : 3)
            XCTAssertEqual(counts.clears, 0)
            XCTAssertFalse(preferences.bool(forKey: "interruptedImageIndex.v1"))
        }
    }

    func testIndexFailureNeverBecomesAutomaticResumeOrSuccess() async throws {
        let preferences = try self.preferences()
        let worker = ResumeWorker(failIndex: true)
        let state = self.state(worker, preferences: preferences)
        state.start()
        await state.waitUntilIdle()
        state.index()
        await state.waitUntilIdle()
        XCTAssertNotNil(state.errorMessage)
        XCTAssertFalse(preferences.bool(forKey: "interruptedImageIndex.v1"))
        state.enterBackground()
        state.enterForeground()
        await state.waitUntilIdle()
        let counts = await worker.counts()
        XCTAssertEqual(counts.indexCalls, 1)
    }

    func testOCRExpirationRestoresQualityPolicyAndReusesSavedRecognitionAcrossNewState() async throws {
        let saved = expectation(description: "first real OCR commit")
        let gate = ResumeGate()
        let worker = ResumeWorker(initialImages: 3, textHold: gate, textSaved: saved)
        let preferences = try self.preferences()
        preferences.set(true, forKey: "photoTextSearchEnabled.v1")
        let lease = ResumeLease()
        let old = state(worker, preferences: preferences, lease: lease)
        old.start()
        await old.waitUntilIdle()
        let initial = await worker.counts()
        XCTAssertTrue(initial.textPolicies.isEmpty, "A restored ON preference alone does not start OCR.")
        old.indexPhotoText()
        await fulfillment(of: [saved], timeout: 3)
        old.enterBackground()
        XCTAssertTrue(old.backgroundExecutionAllowed)
        lease.expire()
        await gate.open()
        await old.waitUntilIdle()
        XCTAssertTrue(old.ocrSync.lifecyclePaused)
        XCTAssertEqual(old.ocrSync.progress.recognized, 1)
        XCTAssertTrue(preferences.bool(forKey: "interruptedTextIndex.v1"))
        let relaunched = state(worker, preferences: preferences)
        relaunched.start()
        await relaunched.waitUntilIdle()
        let counts = await worker.counts()
        XCTAssertEqual(counts.textPolicies, [true, true])
        XCTAssertEqual(counts.textWrites, 3)
        XCTAssertEqual(counts.clears, 0)
        XCTAssertEqual(relaunched.ocrSync.phase, .completed)
        XCTAssertTrue(relaunched.ocrSync.isResuming)
        XCTAssertEqual(relaunched.ocrSync.progress.reused, 1)
        XCTAssertEqual(relaunched.ocrSync.progress.recognized, 2)
        XCTAssertFalse(preferences.bool(forKey: "interruptedTextIndex.v1"))
    }

    func testOCRFinishesWithinLeaseAndProtectedDataLossExpiresLease() async throws {
        for losesProtection in [false, true] {
            let saved = expectation(description: "OCR commit \(losesProtection)")
            let gate = ResumeGate()
            let worker = ResumeWorker(initialImages: 3, textHold: gate, textSaved: saved)
            let lease = ResumeLease()
            let state = self.state(worker, lease: lease)
            state.start()
            await state.waitUntilIdle()
            state.textSearchEnabled = true
            await fulfillment(of: [saved], timeout: 3)
            state.enterBackground()
            if losesProtection { state.protectedDataBecameUnavailable() }
            await gate.open()
            await state.waitUntilIdle()
            let counts = await worker.counts()
            XCTAssertEqual(counts.textWrites, losesProtection ? 1 : 3)
            XCTAssertEqual(state.ocrSync.phase, losesProtection ? .waiting : .completed)
            XCTAssertEqual(lease.ends, 1)
            XCTAssertFalse(state.backgroundExecutionAllowed)
        }
    }

    func testNoIdleLeaseAndDeniedLeasePausesWithoutLosingIntent() async throws {
        let lease = ResumeLease()
        let state = self.state(ResumeWorker(), lease: lease)
        state.start()
        await state.waitUntilIdle()
        state.enterBackground()
        XCTAssertEqual(lease.begins, 0)
        let saved = expectation(description: "commit before denied lease")
        let gate = ResumeGate()
        let worker = ResumeWorker(imageHold: gate, imageSaved: saved)
        let denied = ResumeLease()
        denied.allowed = false
        let active = self.state(worker, lease: denied)
        active.start()
        await active.waitUntilIdle()
        active.index()
        await fulfillment(of: [saved], timeout: 3)
        active.enterBackground()
        XCTAssertFalse(active.backgroundExecutionAllowed)
        await gate.open()
        await active.waitUntilIdle()
        active.enterForeground()
        await active.waitUntilIdle()
        let counts = await worker.counts()
        XCTAssertEqual(counts.imageWrites, 3)
        XCTAssertEqual(counts.indexCalls, 2)
    }
}

@MainActor
private final class ResumeLease: BackgroundWorkLeasing {
    var allowed = true
    private(set) var begins = 0
    private(set) var ends = 0
    private var expiration: (@MainActor () -> Void)?
    var expirationHandler: (@MainActor () -> Void)? { expiration }
    func begin(expiration: @escaping @MainActor () -> Void) -> Bool {
        begins += 1
        if allowed { self.expiration = expiration }
        return allowed
    }
    func end() {
        if expiration != nil { ends += 1; expiration = nil }
    }
    func expire() { expiration?() }
}

private actor ResumeGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ResumeWorker: PhotoWorkServicing {
    private var images: Set<Int>
    private var texts = Set<Int>()
    private let imageHold: ResumeGate?
    private let imageSaved: XCTestExpectation?
    private let textHold: ResumeGate?
    private let textSaved: XCTestExpectation?
    private let failIndex: Bool
    private var heldImage = false
    private var heldText = false
    private var indexCalls = 0
    private var textPolicies: [Bool] = []
    private var clears = 0

    init(initialImages: Int = 0, imageHold: ResumeGate? = nil, imageSaved: XCTestExpectation? = nil,
         textHold: ResumeGate? = nil, textSaved: XCTestExpectation? = nil, failIndex: Bool = false) {
        images = Set(0..<initialImages)
        self.imageHold = imageHold
        self.imageSaved = imageSaved
        self.textHold = textHold
        self.textSaved = textSaved
        self.failIndex = failIndex
    }
    func counts() -> (indexCalls: Int, imageWrites: Int, textWrites: Int, textPolicies: [Bool], clears: Int) {
        (indexCalls, images.count, texts.count, textPolicies, clears)
    }
    func refresh() async throws -> LibrarySummary {
        try Task.checkCancellation()
        return LibrarySummary(authorizedCount: 3, authorizedCountKnown: true,
                              indexedCount: images.count, modelVersion: "resume-test-model")
    }
    func index(networkAllowed: Bool, progress: @escaping @Sendable (IndexProgress) async -> Void) async throws -> LibrarySummary {
        indexCalls += 1
        var value = IndexProgress(total: 3)
        for id in 0..<3 {
            try Task.checkCancellation()
            if images.insert(id).inserted { value.encoded += 1 } else { value.reused += 1 }
            value.completed += 1
            await progress(value)
            if let imageHold, !heldImage {
                heldImage = true
                imageSaved?.fulfill()
                await imageHold.wait()
                try Task.checkCancellation()
            }
            if failIndex { throw AppFailure.storage("TEST index failure") }
        }
        return try await refresh()
    }
    func indexText(networkAllowed: Bool, retryReducedPreviews: Bool,
                   progress: @escaping @Sendable (TextIndexProgress) async -> Void) async throws -> LibrarySummary {
        textPolicies.append(retryReducedPreviews)
        var value = TextIndexProgress(total: 3)
        for id in 0..<3 {
            try Task.checkCancellation()
            if texts.insert(id).inserted { value.recognized += 1 } else { value.reused += 1 }
            value.completed += 1
            await progress(value)
            if let textHold, !heldText {
                heldText = true
                textSaved?.fulfill()
                await textHold.wait()
                try Task.checkCancellation()
            }
        }
        return try await refresh()
    }
    func search(text: String, limit: Int, locationWeight: Float) async throws -> SearchResponse {
        XCTFail("Lifecycle recovery must not submit a search")
        throw AppFailure.photo("Unexpected test search")
    }
    func clear() async throws -> LibrarySummary {
        clears += 1
        XCTFail("Recovery must never clear or rebuild the saved index")
        throw AppFailure.storage("Unexpected destructive recovery")
    }
}
