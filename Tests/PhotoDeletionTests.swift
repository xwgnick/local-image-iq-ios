import XCTest
import Photos
@testable import LocalImageIQ

/// Synthetic metadata and an in-memory transaction double ONLY. Never construct
/// PhotoLibraryClient/SystemPhotoDeletionService, query authorization, fetch assets,
/// call PHPhotoLibrary.shared(), or issue a real Photos change request in tests.
final class PhotoDeletionTests: XCTestCase {
    func testPlanDeduplicatesExactCapturesInOrderWithoutRewritingOpaqueIDs() throws {
        let padded = revision(" b/id \n", creation: nil)
        let plain = revision("b/id")
        let other = revision("a/id")
        let plan = try makePlan([padded, other, padded, plain, other],
                                [asset(plain), asset(other), asset(padded)])
        XCTAssertEqual(plan.revisions, [padded, other, plain])
        XCTAssertEqual(plan.assetIDs, [" b/id \n", "a/id", "b/id"])
    }

    func testSinglePhotoAndEntireSelectedGroupAreAllowedWithoutKeepOneBarrier() throws {
        for authorization in [PHAuthorizationStatus.authorized, .limited] {
            for expected in [[revision("only", modification: -100, creation: nil)],
                             [revision("group-a"), revision("group-b"), revision("group-c")]] {
                let plan = try makePlan(expected, expected.map { asset($0) }, authorization: authorization)
                XCTAssertEqual(plan.revisions, expected)
                XCTAssertEqual(plan.assetIDs.count, expected.count)
            }
        }
    }

    func testEmptyBlankAndNonfiniteExpectedRevisionsAreRejected() {
        XCTAssertThrowsError(try PhotoDeletionPlan.orderedUniqueRevisions([])) {
            XCTAssertEqual($0 as? PhotoDeletionError, .emptySelection)
        }
        var invalid = [revision(""), revision(" \t\n")]
        for value in [Double.nan, .infinity, -.infinity] {
            invalid.append(revision("a", modification: value))
            invalid.append(revision("a", creation: value))
        }
        for value in invalid {
            XCTAssertThrowsError(try PhotoDeletionPlan.orderedUniqueRevisions([revision("valid"), value])) {
                XCTAssertEqual($0 as? PhotoDeletionError, .invalidSelection)
            }
        }
    }

    func testConflictingDuplicateCapturesNeverChooseTheNewerRevision() {
        let original = revision("a")
        for conflicting in [revision("a", modification: 21), revision("a", creation: 11),
                            revision("a", creation: nil)] {
            for expected in [[original, conflicting], [conflicting, original]] {
                XCTAssertThrowsError(try makePlan(expected, [asset(original)])) {
                    XCTAssertEqual($0 as? PhotoDeletionError, .invalidSelection)
                }
            }
        }
    }

    func testAnyMissingNonimageOrNondeletableAssetRejectsTheWholePlan() {
        let a = revision("a"), b = revision("b")
        let cases: [([PhotoDeletionAssetState], PhotoDeletionError)] = [
            ([asset(a)], .unavailableAssets),
            ([asset(a), asset(b, isImage: false)], .unavailableAssets),
            ([asset(a), asset(b, canDelete: false)], .notDeletable),
            ([asset(a, canDelete: false), asset(b)], .notDeletable)
        ]
        for (states, error) in cases {
            XCTAssertThrowsError(try makePlan([a, b], states)) {
                XCTAssertEqual($0 as? PhotoDeletionError, error)
            }
        }
    }

    func testMalformedDuplicateAndExpandedAssetSnapshotsAreRejected() {
        let a = revision("a")
        let cases: [[PhotoDeletionAssetState]] = [
            [asset(a), asset(a)],
            [asset(a), asset(revision("a", modification: 21))],
            [asset(a), asset(revision("unselected"))],
            [PhotoDeletionAssetState(id: "a", isImage: true, canDelete: true, revision: revision("other"))],
            [asset(revision("a", modification: .nan))],
            [asset(revision("a", creation: .infinity))]
        ]
        for states in cases {
            XCTAssertThrowsError(try makePlan([a], states)) {
                XCTAssertEqual($0 as? PhotoDeletionError, .invalidSelection)
            }
        }
    }

    func testExactRevisionComparisonIncludesBothTimesAndNilCreationTime() {
        let original = revision("a")
        let pairs: [(PhotoRevision, PhotoRevision)] = [
            (original, revision("a", modification: Double(20).nextUp)),
            (original, revision("a", creation: Double(10).nextUp)),
            (original, revision("a", creation: nil)),
            (revision("a", creation: nil), original)
        ]
        for (expected, current) in pairs {
            XCTAssertThrowsError(try makePlan([expected], [asset(current)])) {
                XCTAssertEqual($0 as? PhotoDeletionError, .revisionChanged)
            }
        }
    }

    func testOnlyFullAndLimitedAuthorizationCanProduceAPlan() {
        let a = revision("a")
        for authorization in [PHAuthorizationStatus.authorized, .limited] {
            XCTAssertNoThrow(try makePlan([a], [asset(a)], authorization: authorization))
        }
        for authorization in [PHAuthorizationStatus.denied, .restricted, .notDetermined] {
            XCTAssertThrowsError(try makePlan([a], [asset(a)], authorization: authorization)) {
                XCTAssertEqual($0 as? PhotoDeletionError, .permissionDenied)
            }
        }
    }

    func testErrorsAreFixedChineseMessagesAndNeverForwardPrivateDetails() {
        let messages: [(PhotoDeletionError, String)] = [
            (.emptySelection, "请先选择要删除的照片。"),
            (.invalidSelection, "所选照片信息无效，请重新选择。"),
            (.permissionDenied, "请先允许访问照片。"),
            (.accessChanged, "照片访问权限或图库状态已更改，请重新选择。"),
            (.unavailableAssets, "部分照片已不存在或无法访问，请重新选择。"),
            (.revisionChanged, "部分照片已更改，请重新选择并确认。"),
            (.notDeletable, "部分照片不允许删除。"),
            (.cancelled, "已取消删除照片。"),
            (.mutationFailed, "未能完成照片删除，请检查照片状态。")
        ]
        for (error, message) in messages {
            XCTAssertEqual(error.localizedDescription, message)
            let sanitized = PhotoDeletionError.sanitized(error)
            if error == .cancelled { XCTAssertTrue(sanitized is CancellationError) }
            else { XCTAssertEqual(sanitized as? PhotoDeletionError, error) }
        }
        let shared: [(PhotoLibraryActionError, PhotoDeletionError)] = [
            (.emptySelection, .emptySelection), (.invalidIdentifier, .invalidSelection),
            (.permissionDenied, .permissionDenied), (.accessChanged, .accessChanged),
            (.unavailableAssets, .unavailableAssets), (.mutationFailed, .mutationFailed),
            (.favoriteUnavailable, .mutationFailed)
        ]
        for (error, expected) in shared {
            XCTAssertEqual(PhotoDeletionError.sanitized(error) as? PhotoDeletionError, expected)
        }
        let raw = privateError()
        let sanitized = PhotoDeletionError.sanitized(raw)
        XCTAssertEqual(sanitized as? PhotoDeletionError, .mutationFailed)
        XCTAssertFalse(sanitized.localizedDescription.contains("synthetic-private"))
        XCTAssertNil((sanitized as NSError).userInfo[NSUnderlyingErrorKey])
        // Codes from an unrelated domain must not be misclassified as Photos errors.
        XCTAssertEqual(PhotoDeletionError.sanitized(NSError(domain: "synthetic-private",
            code: PHPhotosError.Code.accessRestricted.rawValue)) as? PhotoDeletionError, .mutationFailed)
    }

    func testInvalidCapturedInputNeverReadsEpochFetchesOrSubmits() async {
        let a = revision("a")
        let cases: [([PhotoRevision], PhotoDeletionError)] = [
            ([], .emptySelection), ([revision(" \n")], .invalidSelection),
            ([a, revision("a", modification: 21)], .invalidSelection),
            ([revision("a", creation: .nan)], .invalidSelection)
        ]
        for (expected, failure) in cases {
            let transaction = DeletionTransactionDouble(assets: [asset(a)], automaticallyComplete: true)
            await assertFailure(start(transaction, expected: expected), failure)
            XCTAssertEqual(transaction.observation.epochReads, 0)
            XCTAssertTrue(transaction.observation.preflights.isEmpty)
            XCTAssertEqual(transaction.observation.submissions, 0)
            XCTAssertTrue(transaction.observation.requests.isEmpty)
        }
    }

    func testInitialPreflightFailureNeverSubmitsAnyTransaction() async {
        let a = revision("a"), b = revision("b")
        let cases: [(PHAuthorizationStatus, [PhotoDeletionAssetState], PhotoDeletionError)] = [
            (.denied, [asset(a), asset(b)], .permissionDenied),
            (.authorized, [asset(a)], .unavailableAssets),
            (.limited, [asset(a), asset(b, isImage: false)], .unavailableAssets),
            (.authorized, [asset(a), asset(b, canDelete: false)], .notDeletable),
            (.authorized, [asset(a), asset(revision("b", creation: nil))], .revisionChanged)
        ]
        for (authorization, states, failure) in cases {
            let transaction = DeletionTransactionDouble(assets: states,
                epoch: PhotoDeletionEpoch(authorization: authorization, generation: 7),
                automaticallyComplete: true)
            await assertFailure(start(transaction, expected: [a, b]), failure)
            XCTAssertEqual(transaction.observation.submissions, 0)
            XCTAssertTrue(transaction.observation.requests.isEmpty)
            if authorization == .denied { XCTAssertTrue(transaction.observation.preflights.isEmpty) }
        }
    }

    func testOneTransactionUsesExactCapturedOrderAndRefetchesInsideQueuedBlock() async {
        let a = revision("a"), b = revision(" b/id ", creation: nil), c = revision("c")
        let transaction = DeletionTransactionDouble(assets: [asset(a), asset(b), asset(c)])
        // Construction is inert. This double never constructs the system service.
        XCTAssertEqual(transaction.observation.submissions, 0)
        XCTAssertTrue(transaction.observation.preflights.isEmpty)
        let task = start(transaction, expected: [b, a, b, c, a])
        guard await submitted(transaction) else { return }
        XCTAssertEqual(transaction.observation.preflights, [[b, a, c]])
        XCTAssertTrue(transaction.observation.requests.isEmpty)
        transaction.setAssets([asset(c), asset(b), asset(a)])
        XCTAssertTrue(transaction.executeQueuedChanges())
        XCTAssertEqual(transaction.observation.preflights, [[b, a, c], [b, a, c]])
        XCTAssertEqual(transaction.observation.requests, [[b.id, a.id, c.id]])
        XCTAssertEqual(transaction.observation.epochReads, 4)
        XCTAssertFalse(transaction.observation.returned)
        transaction.finish(success: true)
        await assertSuccess(task)
        XCTAssertEqual(transaction.observation.submissions, 1)
    }

    func testEpochChangeDuringInitialPreflightPreventsSubmission() async {
        let a = revision("a")
        for (changed, failure) in changedEpochs() {
            let transaction = DeletionTransactionDouble(assets: [asset(a)], automaticallyComplete: true)
            transaction.setAfterPreflight { [weak transaction] count in
                if count == 1 { transaction?.setEpoch(changed) }
            }
            await assertFailure(start(transaction, expected: [a]), failure)
            XCTAssertEqual(transaction.observation.preflights.count, 1)
            XCTAssertEqual(transaction.observation.submissions, 0)
            XCTAssertTrue(transaction.observation.requests.isEmpty)
        }
    }

    func testQueuedPermissionOrGenerationChangePreventsRefetchAndRequests() async {
        let a = revision("a")
        for (changed, failure) in changedEpochs() {
            let transaction = DeletionTransactionDouble(assets: [asset(a)])
            let task = start(transaction, expected: [a])
            guard await submitted(transaction) else { return }
            transaction.setEpoch(changed)
            XCTAssertTrue(transaction.executeQueuedChanges())
            XCTAssertEqual(transaction.observation.preflights.count, 1)
            XCTAssertTrue(transaction.observation.requests.isEmpty)
            // A successful no-op Photos callback cannot hide our queued failure.
            transaction.finish(success: true)
            await assertFailure(task, failure)
            XCTAssertEqual(transaction.observation.submissions, 1)
        }
    }

    func testQueuedRevisionMissingImageAndCapabilityChangesBlockEntireRequest() async {
        let a = revision("a"), b = revision("b")
        let cases: [([PhotoDeletionAssetState], PhotoDeletionError)] = [
            ([asset(a)], .unavailableAssets),
            ([asset(a), asset(b, isImage: false)], .unavailableAssets),
            ([asset(a), asset(b, canDelete: false)], .notDeletable),
            ([asset(a), asset(revision("b", modification: 21))], .revisionChanged),
            ([asset(a), asset(revision("b", creation: 11))], .revisionChanged),
            ([asset(a), asset(revision("b", creation: nil))], .revisionChanged),
            ([asset(a), asset(b), asset(revision("unselected"))], .invalidSelection)
        ]
        for (states, failure) in cases {
            let transaction = DeletionTransactionDouble(assets: [asset(a), asset(b)])
            let task = start(transaction, expected: [a, b])
            guard await submitted(transaction) else { return }
            transaction.setAssets(states)
            XCTAssertTrue(transaction.executeQueuedChanges())
            XCTAssertEqual(transaction.observation.preflights, [[a, b], [a, b]])
            XCTAssertTrue(transaction.observation.requests.isEmpty)
            // Neither system success nor a different system failure may overwrite
            // the exact sanitized preflight failure recorded by the gate.
            transaction.finish(success: false, error: privateError())
            await assertFailure(task, failure)
            XCTAssertEqual(transaction.observation.submissions, 1)
        }
    }

    func testLastPrecommitEpochCheckCatchesChangesDuringQueuedAssetValidation() async {
        let a = revision("a")
        for (changed, failure) in changedEpochs() {
            let transaction = DeletionTransactionDouble(assets: [asset(a)])
            transaction.setAfterPreflight { [weak transaction] count in
                if count == 2 { transaction?.setEpoch(changed) }
            }
            let task = start(transaction, expected: [a])
            guard await submitted(transaction) else { return }
            XCTAssertTrue(transaction.executeQueuedChanges())
            XCTAssertEqual(transaction.observation.preflights.count, 2)
            XCTAssertTrue(transaction.observation.requests.isEmpty)
            transaction.finish(success: true)
            await assertFailure(task, failure)
        }
    }

    func testCancellationBeforeRunDoesNotReadOrSubmit() async {
        let a = revision("a")
        let transaction = DeletionTransactionDouble(assets: [asset(a)], automaticallyComplete: true)
        let task = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            try await transaction.run(expected: [a])
        }
        await assertCancellation(task)
        XCTAssertEqual(transaction.observation.epochReads, 0)
        XCTAssertTrue(transaction.observation.preflights.isEmpty)
        XCTAssertEqual(transaction.observation.submissions, 0)
        XCTAssertTrue(transaction.observation.requests.isEmpty)
    }

    func testCancellationWhileQueuedMakesChangesNoOpAndWaitsForCallback() async {
        let a = revision("a")
        let transaction = DeletionTransactionDouble(assets: [asset(a)])
        let task = start(transaction, expected: [a])
        guard await submitted(transaction) else { return }
        task.cancel()
        // Executed by THIS test task, not the cancelled originating task. Testing
        // Task.isCancelled inside the changes block instead of the gate is wrong.
        XCTAssertFalse(Task.isCancelled)
        XCTAssertTrue(transaction.executeQueuedChanges())
        XCTAssertEqual(transaction.observation.preflights.count, 1)
        XCTAssertTrue(transaction.observation.requests.isEmpty)
        XCTAssertFalse(transaction.observation.returned)
        transaction.finish(success: true)
        await assertCancellation(task)
        XCTAssertEqual(transaction.observation.submissions, 1)
    }

    func testCancellationDuringQueuedPreflightPreventsBeginMutation() async {
        let a = revision("a")
        let transaction = DeletionTransactionDouble(assets: [asset(a)])
        let task = start(transaction, expected: [a])
        guard await submitted(transaction) else { return }
        transaction.setAfterPreflight { count in
            if count == 2 { task.cancel() }
        }
        XCTAssertTrue(transaction.executeQueuedChanges())
        XCTAssertEqual(transaction.observation.preflights.count, 2)
        XCTAssertTrue(transaction.observation.requests.isEmpty)
        transaction.finish(success: true)
        await assertCancellation(task)
    }

    func testCancellationAfterBeginWaitsForRealSuccessWithoutClaimingRollback() async {
        let a = revision("a"), b = revision("b")
        let transaction = DeletionTransactionDouble(assets: [asset(a), asset(b)])
        let task = start(transaction, expected: [b, a])
        guard await submitted(transaction) else { return }
        XCTAssertTrue(transaction.executeQueuedChanges())
        XCTAssertEqual(transaction.observation.requests, [[b.id, a.id]])
        task.cancel()
        XCTAssertFalse(transaction.observation.returned)
        // Success is authoritative even with an inconsistent incidental error.
        transaction.finish(success: true, error: NSError(domain: PHPhotosErrorDomain,
            code: PHPhotosError.Code.userCancelled.rawValue))
        await assertSuccess(task)
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(transaction.observation.submissions, 1)
        XCTAssertEqual(transaction.observation.requests.count, 1)
    }

    func testCancellationAfterBeginWaitsForRealFailureAndNeverRetries() async {
        let a = revision("a")
        // A nil error is also a genuine failure, not success or task cancellation.
        for error in [nil, privateError()] as [Error?] {
            let transaction = DeletionTransactionDouble(assets: [asset(a)])
            let task = start(transaction, expected: [a])
            guard await submitted(transaction) else { return }
            XCTAssertTrue(transaction.executeQueuedChanges())
            task.cancel()
            XCTAssertFalse(transaction.observation.returned)
            transaction.finish(success: false, error: error)
            await assertFailure(task, .mutationFailed)
            XCTAssertEqual(transaction.observation.submissions, 1)
            XCTAssertEqual(transaction.observation.requests, [[a.id]])
        }
    }

    func testSystemCancellationPermissionAndOpaqueFailuresAreSanitizedAtCallback() async {
        let a = revision("a")
        // nil expected failure means CancellationError, regardless of task status.
        let cases: [(Error, PhotoDeletionError?)] = [
            (CancellationError(), nil), (PhotoDeletionError.cancelled, nil),
            (NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.userCancelled.rawValue), nil),
            (NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError), nil),
            (NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), nil),
            (NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessUserDenied.rawValue), .permissionDenied),
            (NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.Code.accessRestricted.rawValue), .permissionDenied),
            (privateError(), .mutationFailed)
        ]
        for (error, failure) in cases {
            let transaction = DeletionTransactionDouble(assets: [asset(a)])
            let task = start(transaction, expected: [a])
            guard await submitted(transaction) else { return }
            XCTAssertTrue(transaction.executeQueuedChanges())
            XCTAssertFalse(task.isCancelled)
            transaction.finish(success: false, error: error)
            if let failure { await assertFailure(task, failure) }
            else { await assertCancellation(task) }
            XCTAssertEqual(transaction.observation.submissions, 1)
            XCTAssertEqual(transaction.observation.requests, [[a.id]])
        }
    }

    private func revision(_ id: String, modification: Double = 20, creation: Double? = 10) -> PhotoRevision {
        PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
    }

    private func asset(_ revision: PhotoRevision, isImage: Bool = true,
                       canDelete: Bool = true) -> PhotoDeletionAssetState {
        PhotoDeletionAssetState(id: revision.id, isImage: isImage, canDelete: canDelete, revision: revision)
    }

    private func makePlan(_ expected: [PhotoRevision], _ assets: [PhotoDeletionAssetState],
                          authorization: PHAuthorizationStatus = .authorized) throws -> PhotoDeletionPlan {
        try PhotoDeletionPlan(revisions: expected, assets: assets, authorization: authorization)
    }

    private func privateError() -> NSError {
        NSError(domain: "synthetic-private-domain", code: 999, userInfo: [
            NSLocalizedDescriptionKey: "synthetic-private-id /synthetic-private-path",
            NSUnderlyingErrorKey: NSError(domain: "synthetic-private-underlying", code: 1)
        ])
    }

    private func changedEpochs() -> [(PhotoDeletionEpoch, PhotoDeletionError)] {
        [
            (PhotoDeletionEpoch(authorization: .limited, generation: 7), .accessChanged),
            (PhotoDeletionEpoch(authorization: .denied, generation: 7), .permissionDenied),
            (PhotoDeletionEpoch(authorization: .authorized, generation: 8), .accessChanged),
            (PhotoDeletionEpoch(authorization: .authorized, generation: nil), .accessChanged)
        ]
    }

    private func start(_ transaction: DeletionTransactionDouble,
                       expected: [PhotoRevision]) -> Task<Void, Error> {
        let task = Task { try await transaction.run(expected: expected) }
        addTeardownBlock {
            task.cancel()
            transaction.finish(success: false)
            _ = try? await task.value
        }
        return task
    }

    private func submitted(_ transaction: DeletionTransactionDouble,
                           file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        // Positive-event escape for a broken test only; no sleeps, polling, latency
        // assertions, or production timeouts. Teardown drains even a late submit.
        let result = await XCTWaiter.fulfillment(of: [transaction.submitted], timeout: 5)
        XCTAssertEqual(result, .completed, file: file, line: line)
        return result == .completed
    }

    private func assertFailure(_ task: Task<Void, Error>, _ expected: PhotoDeletionError,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected deletion failure", file: file, line: line) }
        catch { XCTAssertEqual(error as? PhotoDeletionError, expected, file: file, line: line) }
    }

    private func assertCancellation(_ task: Task<Void, Error>,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("Expected cancellation", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }

    private func assertSuccess(_ task: Task<Void, Error>,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value }
        catch { XCTFail("Expected actual transaction success", file: file, line: line) }
    }
}

/// Payloads are only synthetic IDs. Queued changes and completion are independently
/// driven by tests so they can change metadata/epochs or cancel at exact boundaries.
private final class DeletionTransactionDouble: @unchecked Sendable {
    struct Observation {
        let epochReads: Int
        let preflights: [[PhotoRevision]]
        let submissions: Int
        let requests: [[String]]
        let returned: Bool
    }

    let submitted = XCTestExpectation(description: "Synthetic deletion transaction queued")
    private let lock = NSLock()
    private let automaticallyComplete: Bool
    private var epoch: PhotoDeletionEpoch
    private var assets: [PhotoDeletionAssetState]
    private var epochReads = 0
    private var preflights: [[PhotoRevision]] = []
    private var submissions = 0
    private var requests: [[String]] = []
    private var returned = false
    private var closed = false
    private var changes: PhotoDeletionExecutor.Changes?
    private var completion: PhotoDeletionExecutor.Completion?
    private var afterPreflight: (@Sendable (Int) -> Void)?

    init(assets: [PhotoDeletionAssetState],
         epoch: PhotoDeletionEpoch = PhotoDeletionEpoch(authorization: .authorized, generation: 7),
         automaticallyComplete: Bool = false) {
        self.assets = assets
        self.epoch = epoch
        self.automaticallyComplete = automaticallyComplete
    }

    var observation: Observation {
        locked {
            Observation(epochReads: epochReads, preflights: preflights, submissions: submissions,
                        requests: requests, returned: returned)
        }
    }

    func setAssets(_ value: [PhotoDeletionAssetState]) { locked { assets = value } }
    func setEpoch(_ value: PhotoDeletionEpoch) { locked { epoch = value } }
    func setAfterPreflight(_ hook: @escaping @Sendable (Int) -> Void) { locked { afterPreflight = hook } }

    func run(expected: [PhotoRevision]) async throws {
        defer { locked { returned = true } }
        try await PhotoDeletionExecutor.run(expected: expected, currentEpoch: { [self] in
            locked { epochReads += 1; return epoch }
        }, preflight: { [self] expected, authorization in
            let (states, count, hook) = locked {
                preflights.append(expected)
                return (assets, preflights.count, afterPreflight)
            }
            let plan = try PhotoDeletionPlan(revisions: expected, assets: states, authorization: authorization)
            hook?(count)
            return plan.assetIDs
        }, request: { [self] selected in
            locked { requests.append(selected) }
        }, submit: { [self] changes, completion in
            let alreadyClosed = locked {
                submissions += 1
                guard !closed else { return true }
                self.changes = changes
                self.completion = completion
                return false
            }
            submitted.fulfill()
            if alreadyClosed { completion(false, nil) }
            else if automaticallyComplete {
                // Initial-rejection tests must fail assertions, not hang forever,
                // if a regression accidentally reaches submission. Still fake IDs.
                _ = executeQueuedChanges()
                finish(success: true)
            }
        })
    }

    func executeQueuedChanges() -> Bool {
        let block = locked {
            let block = changes
            changes = nil
            return block
        }
        guard let block else { return false }
        block()
        return true
    }

    func finish(success: Bool, error: Error? = nil) {
        let callback = locked {
            closed = true
            let callback = completion
            completion = nil
            changes = nil
            afterPreflight = nil
            return callback
        }
        callback?(success, error)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}