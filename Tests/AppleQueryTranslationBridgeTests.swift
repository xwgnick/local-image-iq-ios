import Combine
import Foundation
import XCTest
@testable import LocalImageIQ

private typealias TranslationBridge = AppleQueryTranslationService
private typealias BridgeJob = AppleQueryTranslationService.Job
private typealias BridgeResult = Result<BridgeJob.Output, Error>

/// Exercises the actual service's session-free continuation bridge, not a fake
/// translator. All strings/errors are synthetic. No TranslationSession, native
/// language availability, download, timing benchmark or offline proof is involved.
@MainActor
final class AppleQueryTranslationBridgeTests: XCTestCase {
    func testMissingHostRejectsBothPurposesWithoutPublishing() async throws {
        let context = makeContext(purpose: nil)
        for kind in [BridgeJob.Kind.translation("SYNTHETIC query"), .preparation] {
            let request = context.submit(kind)
            assertFailure(try await result(of: request), .unavailable)
        }
        XCTAssertNil(context.service.job)
        XCTAssertTrue(context.publishedIDs.isEmpty)
        XCTAssertEqual(context.clearCount, 0)
    }

    func testWrongPurposeHostCannotAcceptTranslationOrPreparation() async throws {
        let context = makeContext(purpose: .preparation)
        assertFailure(try await result(of: context.submit(.translation("SYNTHETIC query"))), .unavailable)
        context.service.unregisterHost(id: context.hostID, purpose: .preparation)
        context.service.registerHost(id: context.hostID, purpose: .search)
        assertFailure(try await result(of: context.submit(.preparation)), .unavailable)
        XCTAssertNil(context.service.job)
        XCTAssertTrue(context.publishedIDs.isEmpty)
    }

    func testTranslationPublishesImmutableJobAndPreservesInputAndOutputBytes() async throws {
        let context = makeContext()
        let source = " \t合成查询 with e\u{301} 🖊️\r\n "
        let target = " \tSYNTHETIC translated e\u{301} 🖊️\n "
        let (request, job) = try await start(context, .translation(source), language: .traditional)
        XCTAssertEqual(job.hostID, context.hostID)
        XCTAssertEqual(job.language, .traditional)
        XCTAssertEqual(job.purpose, .search)
        guard case .translation(let submitted) = job.kind else {
            return XCTFail("Expected a translation job")
        }
        XCTAssertEqual(Array(submitted.utf8), Array(source.utf8))
        XCTAssertThrowsError(try context.service.checkActiveJob(job.id)) { assertError($0, .unavailable) }
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated(target)))
        assertTranslated(try await result(of: request), target)
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.publishedIDs, [job.id])
        XCTAssertEqual(context.clearCount, 1)
    }

    func testPreparationUsesItsOwnHostAndReturnsPrepared() async throws {
        let context = makeContext()
        let preparationHost = UUID()
        context.service.registerHost(id: preparationHost, purpose: .preparation)
        let (request, job) = try await start(context, .preparation, language: .traditional)
        XCTAssertEqual(job.hostID, preparationHost)
        XCTAssertEqual(job.purpose, .preparation)
        XCTAssertEqual(job.language, .traditional)
        guard case .preparation = job.kind else { return XCTFail("Expected preparation") }
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: preparationHost))
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        context.service.finishAfterClosure(id: job.id, result: .success(.prepared))
        guard case .success(.prepared) = try await result(of: request) else {
            return XCTFail("Expected the prepared output")
        }
        XCTAssertNil(context.service.job)
    }

    func testPendingBridgeRejectsNewSubmissionsRatherThanQueuingThem() async throws {
        let context = makeContext()
        context.service.registerHost(id: UUID(), purpose: .preparation)
        let (first, job) = try await start(context)
        for kind in [BridgeJob.Kind.translation("SYNTHETIC rejected"), .preparation] {
            assertFailure(try await result(of: context.submit(kind)), .unavailable)
            assertHeld(context, first, job)
        }
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("first only")))
        assertTranslated(try await result(of: first), "first only")
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.publishedIDs, [job.id], "Rejected calls must never be queued")
    }

    func testCancellationBeforeTaskStartsRegistersNoJob() async throws {
        let context = makeContext()
        let request = context.submit(.translation("SYNTHETIC pre-registration cancellation"))
        // Both caller and child are MainActor. There is no suspension between
        // creating and cancelling the child, so submit cannot register an ID yet.
        request.task?.cancel()
        assertCancelled(try await result(of: request))
        XCTAssertNil(context.service.job)
        XCTAssertTrue(context.publishedIDs.isEmpty)
        XCTAssertEqual(context.clearCount, 0)
    }

    func testPendingCancellationAfterRegistrationCompletesWithoutBeginOrFinish() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        request.task?.cancel()
        assertCancelled(try await result(of: request))
        XCTAssertNil(context.service.job)
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertEqual(context.clearCount, 1)
    }

    func testCancellationAtPublicationHandoffDoesNotStrandContinuation() async throws {
        let context = makeContext()
        // Cancel synchronously from the publication, while submit is still
        // installing its continuation. Do not mutate @Published reentrantly.
        let (request, job) = try await start(context, cancelOnPublication: true)
        assertCancelled(try await result(of: request))
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.publishedIDs, [job.id])
        XCTAssertEqual(context.clearCount, 1)
    }

    func testCancelledPendingJobCannotBeginBeforeCancellationActorHop() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        request.task?.cancel()
        // No await: the cancellation handler's MainActor task cannot run first.
        // beginJob must see the synchronously written cancellation token itself.
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertNil(context.service.job)
        assertCancelled(try await result(of: request))
        XCTAssertEqual(context.clearCount, 1)
    }

    func testActiveCancellationRetainsSlotDiscardsOldSuccessAndAdmitsNextOnlyAfterFinish() async throws {
        let context = makeContext()
        context.service.registerHost(id: UUID(), purpose: .preparation)
        let (oldRequest, oldJob) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: oldJob.id, hostID: oldJob.hostID))
        oldRequest.task?.cancel()
        XCTAssertThrowsError(try context.service.checkActiveJob(oldJob.id)) { XCTAssertTrue($0 is CancellationError) }
        assertHeld(context, oldRequest, oldJob)
        assertFailure(try await result(of: context.submit(.preparation)), .unavailable)
        assertHeld(context, oldRequest, oldJob)
        XCTAssertEqual(context.clearCount, 0, "An active closure still owns the slot")

        context.service.finishAfterClosure(id: oldJob.id, result: .success(.translated("SYNTHETIC stale result")))
        assertHeld(context, oldRequest, oldJob)
        assertCancelled(try await result(of: oldRequest))
        XCTAssertNil(context.service.job)

        let (next, nextJob) = try await start(context)
        XCTAssertNotEqual(nextJob.id, oldJob.id)
        XCTAssertTrue(context.service.beginJob(id: nextJob.id, hostID: nextJob.hostID))
        XCTAssertNoThrow(try context.service.checkActiveJob(nextJob.id))
        context.service.finishAfterClosure(id: nextJob.id, result: .success(.translated("SYNTHETIC fresh result")))
        assertTranslated(try await result(of: next), "SYNTHETIC fresh result")
        XCTAssertEqual(context.publishedIDs, [oldJob.id, nextJob.id])
        XCTAssertEqual(context.clearCount, 2)
    }

    func testActiveCancellationDiscardsLateFailureToo() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        request.task?.cancel()
        context.service.finishAfterClosure(id: job.id, result: .failure(privateNSError()))
        assertHeld(context, request, job)
        assertCancelled(try await result(of: request))
        XCTAssertNil(context.service.job)
    }

    func testCancellationAfterFinishIsScheduledStillSuppressesSuccess() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("SYNTHETIC stale")))
        request.task?.cancel()
        assertHeld(context, request, job)
        assertCancelled(try await result(of: request))
        XCTAssertNil(context.service.job)
    }

    func testFinishDefersPublicationAndContinuationUntilClosureReturns() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("SYNTHETIC finished")))
        // These assertions run in the same non-suspending MainActor turn as
        // the simulated closure's final action, before its deferred callback.
        assertHeld(context, request, job)
        XCTAssertEqual(context.clearCount, 0)
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertThrowsError(try context.service.checkActiveJob(job.id)) { assertError($0, .unavailable) }
        assertTranslated(try await result(of: request), "SYNTHETIC finished")
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.clearCount, 1)
    }

    func testSuccessfulFinishAllowsNextJobOnSameRegisteredHost() async throws {
        let context = makeContext()
        var ids: [UUID] = []
        for output in ["SYNTHETIC first", "SYNTHETIC second"] {
            let (request, job) = try await start(context)
            XCTAssertEqual(job.hostID, context.hostID)
            XCTAssertFalse(ids.contains(job.id))
            ids.append(job.id)
            XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
            context.service.finishAfterClosure(id: job.id, result: .success(.translated(output)))
            assertTranslated(try await result(of: request), output)
            XCTAssertNil(context.service.job)
        }
        XCTAssertEqual(context.publishedIDs, ids)
        XCTAssertEqual(context.clearCount, 2)
    }

    func testWrongIDsAndDuplicateBeginCannotClaimOrInvalidateJob() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        let wrongID = UUID()
        XCTAssertFalse(context.service.beginJob(id: wrongID, hostID: job.hostID))
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: UUID()))
        XCTAssertThrowsError(try context.service.checkActiveJob(wrongID)) { XCTAssertTrue($0 is CancellationError) }
        assertHeld(context, request, job)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("claimed once")))
        assertTranslated(try await result(of: request), "claimed once")
    }

    func testFinishForPendingOrUnknownJobIsIgnored() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("premature")))
        assertHeld(context, request, job)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: UUID(), result: .failure(privateNSError()))
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        assertHeld(context, request, job)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("correct finish")))
        assertTranslated(try await result(of: request), "correct finish")
        XCTAssertEqual(context.clearCount, 1)
    }

    func testDuplicateFinishKeepsFirstOutcomeAndPublishesOneClear() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("first outcome")))
        context.service.finishAfterClosure(id: job.id, result: .failure(privateNSError()))
        assertHeld(context, request, job)
        assertTranslated(try await result(of: request), "first outcome")
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("late duplicate")))
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertNil(context.service.job)
        XCTAssertEqual(request.completionCount, 1)
        XCTAssertEqual(context.clearCount, 1)
    }

    func testOldJobCallbacksAndWrongHostLossCannotAffectNextActiveJob() async throws {
        let context = makeContext()
        let (oldRequest, oldJob) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: oldJob.id, hostID: oldJob.hostID))
        context.service.finishAfterClosure(id: oldJob.id, result: .success(.translated("old")))
        assertTranslated(try await result(of: oldRequest), "old")

        let (next, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertFalse(context.service.beginJob(id: oldJob.id, hostID: oldJob.hostID))
        XCTAssertThrowsError(try context.service.checkActiveJob(oldJob.id)) { XCTAssertTrue($0 is CancellationError) }
        context.service.finishAfterClosure(id: oldJob.id, result: .failure(privateNSError()))
        context.service.jobHostDisappeared(id: oldJob.id, hostID: oldJob.hostID)
        context.service.jobHostDisappeared(id: UUID(), hostID: job.hostID)
        context.service.jobHostDisappeared(id: job.id, hostID: UUID())
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        assertHeld(context, next, job)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("new")))
        assertTranslated(try await result(of: next), "new")
        XCTAssertEqual(context.publishedIDs, [oldJob.id, job.id])
        XCTAssertEqual(context.clearCount, 2)
    }

    func testPendingHostReplacementFailsOldJobAndOldUnregisterCannotRemoveNewHost() async throws {
        let context = makeContext()
        let (oldRequest, oldJob) = try await start(context)
        let replacement = UUID()
        context.service.registerHost(id: replacement, purpose: .search)
        XCTAssertNil(context.service.job)
        context.service.unregisterHost(id: oldJob.hostID, purpose: .search)
        assertFailure(try await result(of: oldRequest), .unavailable)
        XCTAssertFalse(context.service.beginJob(id: oldJob.id, hostID: oldJob.hostID))

        let (next, job) = try await start(context)
        XCTAssertEqual(job.hostID, replacement)
        context.service.unregisterHost(id: oldJob.hostID, purpose: .search)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: replacement))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("replacement")))
        assertTranslated(try await result(of: next), "replacement")
    }

    func testActiveHostReplacementWaitsForClosureAndOldUnregisterPreservesReplacement() async throws {
        let context = makeContext()
        let (oldRequest, oldJob) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: oldJob.id, hostID: oldJob.hostID))
        let replacement = UUID()
        context.service.registerHost(id: replacement, purpose: .search)
        context.service.unregisterHost(id: oldJob.hostID, purpose: .search)
        XCTAssertThrowsError(try context.service.checkActiveJob(oldJob.id)) { assertError($0, .unavailable) }
        assertFailure(try await result(of: context.submit(.translation("not queued"))), .unavailable)
        assertHeld(context, oldRequest, oldJob)
        XCTAssertEqual(context.clearCount, 0)
        context.service.finishAfterClosure(id: oldJob.id, result: .success(.translated("invalid session result")))
        assertHeld(context, oldRequest, oldJob)
        assertFailure(try await result(of: oldRequest), .unavailable)

        let (next, job) = try await start(context)
        XCTAssertEqual(job.hostID, replacement)
        context.service.unregisterHost(id: oldJob.hostID, purpose: .search)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: replacement))
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("new host result")))
        assertTranslated(try await result(of: next), "new host result")
        XCTAssertEqual(context.publishedIDs, [oldJob.id, job.id])
    }

    func testSameHostRegistrationAndOtherPurposeUnregisterDoNotLoseActiveJob() async throws {
        let context = makeContext()
        context.service.registerHost(id: context.hostID, purpose: .preparation)
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.registerHost(id: context.hostID, purpose: .search)
        context.service.unregisterHost(id: context.hostID, purpose: .preparation)
        XCTAssertNoThrow(try context.service.checkActiveJob(job.id))
        assertHeld(context, request, job)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("still registered")))
        assertTranslated(try await result(of: request), "still registered")
    }

    func testPendingJobHostLossCompletesWithoutClosureCallback() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        context.service.jobHostDisappeared(id: job.id, hostID: job.hostID)
        XCTAssertNil(context.service.job)
        assertFailure(try await result(of: request), .unavailable)
        context.service.jobHostDisappeared(id: job.id, hostID: job.hostID)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("too late")))
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        XCTAssertEqual(context.clearCount, 1)
        XCTAssertEqual(request.completionCount, 1)
    }

    func testPendingPresenterUnregisterCompletesAndLeavesNoAcceptingHost() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        context.service.unregisterHost(id: job.hostID, purpose: .search)
        assertFailure(try await result(of: request), .unavailable)
        assertFailure(try await result(of: context.submit(.translation("no presenter"))), .unavailable)
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.publishedIDs, [job.id])
    }

    func testActiveJobHostLossCannotFinishUntilClosureCallback() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.jobHostDisappeared(id: job.id, hostID: job.hostID)
        context.service.jobHostDisappeared(id: job.id, hostID: job.hostID)
        XCTAssertThrowsError(try context.service.checkActiveJob(job.id)) { assertError($0, .unavailable) }
        XCTAssertFalse(context.service.beginJob(id: job.id, hostID: job.hostID))
        assertFailure(try await result(of: context.submit(.translation("must not queue"))), .unavailable)
        assertHeld(context, request, job)
        XCTAssertEqual(context.clearCount, 0)
        context.service.finishAfterClosure(id: job.id, result: .success(.translated("lost host output")))
        assertHeld(context, request, job)
        assertFailure(try await result(of: request), .unavailable)
        XCTAssertNil(context.service.job)
        XCTAssertEqual(context.clearCount, 1)
    }

    func testActiveCancellationTakesPrecedenceOverHostLossAndPrivateError() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.unregisterHost(id: job.hostID, purpose: .search)
        request.task?.cancel()
        assertHeld(context, request, job)
        context.service.finishAfterClosure(id: job.id, result: .failure(privateNSError()))
        assertCancelled(try await result(of: request))
        XCTAssertNil(context.service.job)
    }

    func testTypedFailurePreservesDomainFailuresAndCancellation() {
        for failure in [QueryTranslationFailure.notInstalled, .unsupported, .unavailable, .emptyResult] {
            assertError(TranslationBridge.typedFailure(failure), failure)
        }
        XCTAssertTrue(TranslationBridge.typedFailure(CancellationError()) is CancellationError)
    }

    func testTypedFailureRedactsPrivateNSErrorAndLocalizedError() {
        let errors: [Error] = [privateNSError(), BridgePrivateError()]
        for error in errors {
            XCTAssertTrue(error.localizedDescription.contains(BridgePrivateError.marker))
            let sanitized = TranslationBridge.typedFailure(error)
            assertError(sanitized, .unavailable)
            assertRedacted(sanitized)
        }
    }

    func testBridgeRedactsUntypedClosureFailureBeforeResumingCaller() async throws {
        let context = makeContext()
        let (request, job) = try await start(context)
        XCTAssertTrue(context.service.beginJob(id: job.id, hostID: job.hostID))
        context.service.finishAfterClosure(id: job.id, result: .failure(privateNSError()))
        let outcome = try await result(of: request)
        assertFailure(outcome, .unavailable)
        guard case .failure(let error) = outcome else { return XCTFail("Expected sanitized failure") }
        assertRedacted(error)
        XCTAssertNil(context.service.job)
    }

    func testInstalledAvailabilityIsAllowedForSearchAndPreparation() {
        for purpose in [TranslationBridge.Purpose.search, .preparation] {
            XCTAssertNoThrow(try TranslationBridge.requireAvailability(.installed, for: purpose))
        }
    }

    func testDownloadRequiredAvailabilityIsAllowedOnlyForExplicitPreparation() {
        XCTAssertNoThrow(try TranslationBridge.requireAvailability(.downloadRequired, for: .preparation))
        XCTAssertThrowsError(try TranslationBridge.requireAvailability(.downloadRequired, for: .search)) {
            assertError($0, .notInstalled)
        }
    }

    func testOtherAvailabilityStatesRejectBothPurposesWithTypedFailures() {
        let cases: [(QueryTranslationAvailability, QueryTranslationFailure)] = [
            (.unchecked, .unavailable), (.unavailable, .unavailable), (.unsupported, .unsupported)
        ]
        for purpose in [TranslationBridge.Purpose.search, .preparation] {
            for (availability, failure) in cases {
                XCTAssertThrowsError(try TranslationBridge.requireAvailability(availability, for: purpose)) {
                    assertError($0, failure)
                }
            }
        }
    }

    func testSimulatorActualPublicServiceGuardsUnsupportedWithoutNativeCalls() async throws {
        #if targetEnvironment(simulator)
        let context = makeContext()
        context.service.registerHost(id: UUID(), purpose: .preparation)
        let translator: any QueryTranslating = context.service
        XCTAssertFalse(translator.isSupported)
        for language in QueryTranslationLanguage.allCases {
            let availability = await translator.availability(for: language)
            XCTAssertEqual(availability, .unsupported)
            for text in ["SYNTHETIC 中文 query", "", " \t\n "] {
                do {
                    _ = try await translator.translate(text, from: language)
                    XCTFail("Simulator translation must be rejected before native APIs")
                } catch {
                    assertError(error, .unsupported)
                }
            }
            do {
                try await translator.prepare(language)
                XCTFail("Simulator preparation must be rejected before native APIs")
            } catch {
                assertError(error, .unsupported)
            }
        }
        XCTAssertNil(context.service.job)
        XCTAssertTrue(context.publishedIDs.isEmpty)
        XCTAssertEqual(context.clearCount, 0)
        #else
        throw XCTSkip("Public API guard test is Simulator-only; never call native translation here")
        #endif
    }

    // MARK: Deterministic MainActor harness

    private func makeContext(purpose: TranslationBridge.Purpose? = .search) -> BridgeTestContext {
        let context = BridgeTestContext(purpose: purpose)
        // Runs even after a failed assertion/throw. Release pending requests and
        // explicitly simulate the final callback for any held active closure.
        addTeardownBlock { await context.releaseAndDrain() }
        return context
    }

    private func start(
        _ context: BridgeTestContext,
        _ kind: BridgeJob.Kind = .translation("SYNTHETIC query"),
        language: QueryTranslationLanguage = .simplified,
        cancelOnPublication: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (BridgeSubmission, BridgeJob) {
        XCTAssertNil(context.service.job, "Only start an expected accepted job here", file: file, line: line)
        let published = expectation(description: "Actual service published the accepted job")
        let request = BridgeSubmission()
        var emitted: BridgeJob?
        let observation = context.service.$job.compactMap { $0 }.prefix(1).sink { job in
            // @Published emits in willSet; use this value rather than reading
            // service.job from inside its publication callback.
            emitted = job
            if cancelOnPublication { request.task?.cancel() }
            published.fulfill()
        }
        defer { observation.cancel() }
        context.launch(request, kind, language: language)
        await fulfillment(of: [published], timeout: 3)
        return (request, try XCTUnwrap(emitted, "No job was published", file: file, line: line))
    }

    private func result(
        of request: BridgeSubmission, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> BridgeResult {
        // The timeout only diagnoses a missing test event. No sleeps, polling,
        // inverted timing windows or production deadlines drive these tests.
        await fulfillment(of: [request.completed], timeout: 3)
        XCTAssertEqual(request.completionCount, 1, file: file, line: line)
        return try XCTUnwrap(request.result, "Submit did not resume", file: file, line: line)
    }

    private func assertHeld(
        _ context: BridgeTestContext, _ request: BridgeSubmission, _ job: BridgeJob,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(context.service.job?.id, job.id, file: file, line: line)
        XCTAssertEqual(context.service.job?.hostID, job.hostID, file: file, line: line)
        XCTAssertNil(request.result, "Caller must still be suspended", file: file, line: line)
        XCTAssertEqual(request.completionCount, 0, file: file, line: line)
    }

    private func assertTranslated(
        _ result: BridgeResult, _ expected: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .success(.translated(let text)) = result else {
            return XCTFail("Expected translated output", file: file, line: line)
        }
        XCTAssertEqual(Array(text.utf8), Array(expected.utf8), file: file, line: line)
    }

    private func assertCancelled(
        _ result: BridgeResult, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("Cancelled request returned a result", file: file, line: line)
        }
        XCTAssertTrue(error is CancellationError, "Expected cancellation", file: file, line: line)
    }

    private func assertFailure(
        _ result: BridgeResult, _ expected: QueryTranslationFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .failure(let error) = result else {
            return XCTFail("Expected typed failure", file: file, line: line)
        }
        assertError(error, expected, file: file, line: line)
    }

    private func assertError(
        _ error: Error, _ expected: QueryTranslationFailure,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual = error as? QueryTranslationFailure else {
            return XCTFail("Expected QueryTranslationFailure", file: file, line: line)
        }
        switch (actual, expected) {
        case (.notInstalled, .notInstalled), (.unsupported, .unsupported),
             (.unavailable, .unavailable), (.emptyResult, .emptyResult): break
        default: XCTFail("Wrong typed failure: \(actual), expected \(expected)", file: file, line: line)
        }
    }

    private func assertRedacted(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let bridged = error as NSError
        let visible = [String(describing: error), String(reflecting: error), error.localizedDescription,
                       bridged.domain, String(describing: bridged.userInfo),
                       (error as? QueryTranslationFailure)?.fallbackMessage ?? ""].joined(separator: "\n")
        XCTAssertFalse(visible.contains(BridgePrivateError.marker), file: file, line: line)
    }

    private func privateNSError() -> NSError {
        NSError(domain: BridgePrivateError.marker, code: 71, userInfo: [
            NSLocalizedDescriptionKey: BridgePrivateError.marker,
            NSLocalizedFailureReasonErrorKey: BridgePrivateError.marker,
            NSLocalizedRecoverySuggestionErrorKey: BridgePrivateError.marker,
            NSUnderlyingErrorKey: BridgePrivateError(),
            "sourceText": BridgePrivateError.marker,
            "targetText": BridgePrivateError.marker
        ])
    }
}

@MainActor
private final class BridgeSubmission {
    let completed = XCTestExpectation(description: "Actual bridge submit returned")
    var task: Task<Void, Never>?
    var result: BridgeResult?
    var completionCount = 0
}

/// Only event recording and task ownership are test helpers; the complete
/// registration/cancellation/state machine is the real production service.
@MainActor
private final class BridgeTestContext {
    let service = TranslationBridge()
    let hostID = UUID()
    private(set) var publishedIDs: [UUID] = []
    private(set) var clearCount = 0
    private var requests: [BridgeSubmission] = []
    private var observation: AnyCancellable?

    init(purpose: TranslationBridge.Purpose?) {
        if let purpose { service.registerHost(id: hostID, purpose: purpose) }
        observation = service.$job.dropFirst().sink { [weak self] job in
            if let job {
                self?.publishedIDs.append(job.id)
            } else {
                self?.clearCount += 1
            }
        }
    }

    func submit(_ kind: BridgeJob.Kind) -> BridgeSubmission {
        let request = BridgeSubmission()
        launch(request, kind, language: .simplified)
        return request
    }

    func launch(_ request: BridgeSubmission, _ kind: BridgeJob.Kind, language: QueryTranslationLanguage) {
        requests.append(request)
        request.task = Task { @MainActor [service] in
            do {
                request.result = .success(try await service.submit(kind, from: language))
            } catch {
                request.result = .failure(error)
            }
            request.completionCount += 1
            request.completed.fulfill()
        }
    }

    func releaseAndDrain() async {
        for request in requests { request.task?.cancel() }
        if let job = service.job {
            // Pending host loss resumes immediately. Active host loss does NOT:
            // teardown must also supply its synthetic closure completion. A
            // finishing job already has its deferred callback on the main queue.
            service.jobHostDisappeared(id: job.id, hostID: job.hostID)
            service.finishAfterClosure(id: job.id, result: .failure(CancellationError()))
        }
        for request in requests {
            if let task = request.task { await task.value }
            request.task = nil
        }
        observation?.cancel()
        observation = nil
        requests.removeAll()
        XCTAssertNil(service.job, "Teardown must release every bridge continuation")
    }
}

private struct BridgePrivateError: LocalizedError {
    static let marker = "SYNTHETIC_PRIVATE_QUERY_AND_APPLE_ERROR_DETAIL"
    var errorDescription: String? { Self.marker }
}