import Combine
import Foundation
import XCTest
@testable import LocalImageIQ

/// Fake services, held continuations, and tiny synthetic temporary files only.
/// No Photos API, source image data, downloads, AppState, or index/history writes.
@MainActor
final class ResultPhotoActionsStateTests: XCTestCase {
    private var gates: [ResultActionsGate] = []
    private var completions: [ResultActionsCompletion] = []
    private var roots: [URL] = []
    private var cleanupInstalled = false

    func testDefaultsAndReadOnlyFilterDialogLifecycleNeverWrite() async {
        let album = PhotoAlbum(id: "filter", title: "Filter", canAdd: false)
        let service = ResultActionsService(albums: { _ in [album] })
        let state = ResultPhotoActionsState(service: service)
        XCTAssertEqual(state.albums, [])
        XCTAssertFalse(state.albumsLoading)
        XCTAssertNil(state.albumIssue)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.message)
        XCTAssertNil(state.share)
        XCTAssertFalse(state.sharingPresented)
        XCTAssertEqual(service.calls.albumCount, 0)
        for _ in 0..<2 {
            let read = track { state.loadAlbums() }
            XCTAssertTrue(state.albumsLoading)
            XCTAssertFalse(state.isBusy)
            state.cancelPreparation()
            state.pause()
            state.invalidateSelection()
            state.libraryChanged()
            await finish(read)
            XCTAssertEqual(state.albums, [album])
            XCTAssertFalse(state.albumsLoading)
        }
        XCTAssertEqual(service.calls.albumCount, 2)
        XCTAssertTrue(service.calls.actions.isEmpty)
        XCTAssertTrue(service.calls.shares.isEmpty)
        XCTAssertTrue(service.calls.validations.isEmpty)
    }

    func testAlbumReplacementDoesNotDrainAndRejectsLateSuccessAndFailure() async {
        for failOld in [false, true] {
            let old = hold(), new = hold()
            let latest = PhotoAlbum(id: "new", title: "New", canAdd: true)
            let service = ResultActionsService(albums: { index in
                if index == 0 {
                    await old.wait()
                    if failOld { throw PhotoLibraryActionError.permissionDenied }
                    return [PhotoAlbum(id: "old", title: "Old", canAdd: true)]
                }
                await new.wait()
                return [latest]
            })
            let state = ResultPhotoActionsState(service: service)
            let first = track { state.loadAlbums() }
            await entered(old)
            let second = track { state.loadAlbums() }
            await entered(new) // Must enter while old is still held.
            XCTAssertTrue(old.cancelled)
            XCTAssertTrue(state.albumsLoading)
            XCTAssertFalse(state.isBusy)
            new.open()
            await finish(second)
            old.open()
            await finish(first)
            XCTAssertEqual(state.albums, [latest])
            XCTAssertFalse(state.albumsLoading)
            XCTAssertNil(state.albumIssue)
            XCTAssertNil(state.message)
            XCTAssertTrue(service.calls.actions.isEmpty)
        }
    }

    func testAlbumErrorsStaySeparateAndExposeOnlySafeText() async {
        let errors: [Error] = [PhotoLibraryActionError.permissionDenied, privateError()]
        for (index, error) in errors.enumerated() {
            let service = ResultActionsService(albums: { call in
                if call == 0 { return [PhotoAlbum(id: "old", title: "Old", canAdd: true)] }
                throw error
            })
            let state = ResultPhotoActionsState(service: service)
            await finish(track { state.perform(.favorite(true), ids: ["a"]) })
            await finish(track { state.loadAlbums() })
            await finish(track { state.loadAlbums() })
            XCTAssertTrue(state.albums.isEmpty)
            XCTAssertEqual(state.albumIssue, index == 0
                ? PhotoLibraryActionError.permissionDenied.localizedDescription : "未能读取相册，请重试。")
            XCTAssertEqual(state.message, "已加入收藏")
            XCTAssertFalse(state.albumsLoading)
            XCTAssertFalse(state.isBusy)
            XCTAssertEqual(service.calls.actions.count, 1)
        }
    }

    func testEmptyInvalidAndInaccessibleSelectionsNeverSubmitMutations() async {
        let service = ResultActionsService()
        let state = ResultPhotoActionsState(service: service)
        for action in [PhotoBatchAction.favorite(true), .addToAlbum("album"), .createAlbum("New")] {
            await finish(track { state.perform(action, ids: []) })
        }
        state.prepareShare(ids: [], networkAllowed: false)
        XCTAssertNil(state.message)
        XCTAssertTrue(service.calls.validations.isEmpty)
        for (action, ids, expected) in [
            (PhotoBatchAction.favorite(true), ["a", " \n"], PhotoLibraryActionError.invalidIdentifier),
            (.addToAlbum(" "), ["a"], .invalidIdentifier),
            (.createAlbum("\n\t"), ["a"], .emptyAlbumTitle)
        ] {
            await finish(track { state.perform(action, ids: ids) })
            XCTAssertEqual(state.message, expected.localizedDescription)
        }
        service.accessError = PhotoLibraryActionError.unavailableAssets
        await finish(track { state.perform(.createAlbum("New"), ids: ["a", "missing"]) })
        XCTAssertEqual(state.message, PhotoLibraryActionError.unavailableAssets.localizedDescription)
        XCTAssertTrue(service.calls.actions.isEmpty)
        XCTAssertTrue(service.calls.shares.isEmpty)
        XCTAssertFalse(state.isBusy)
    }

    func testExplicitActionsUseImmutableOrderedSnapshotAndCorrectSuccessMessages() async {
        let service = ResultActionsService()
        let state = ResultPhotoActionsState(service: service)
        let actions: [(PhotoBatchAction, String)] = [
            (.favorite(true), "已加入收藏"), (.favorite(false), "已取消收藏"),
            (.addToAlbum("opaque/album"), "已加入相册"),
            (.createAlbum("  假日 \n"), "已创建相册并加入照片")
        ]
        for (action, message) in actions {
            var ids = ["b", "a", "b"]
            let work = track { state.perform(action, ids: ids) }
            ids.removeAll()
            XCTAssertTrue(state.isBusy)
            await finish(work)
            XCTAssertEqual(state.message, message)
            XCTAssertFalse(state.isBusy)
        }
        XCTAssertEqual(service.calls.selections, Array(repeating: ["b", "a"], count: 4))
        XCTAssertEqual(service.calls.validations, service.calls.selections)
          guard service.calls.actions.count == 4 else { return XCTFail("Expected exactly four explicit writes") }
        guard case .favorite(true) = service.calls.actions[0],
              case .favorite(false) = service.calls.actions[1],
              case .addToAlbum("opaque/album") = service.calls.actions[2],
              case .createAlbum("假日") = service.calls.actions[3] else {
            return XCTFail("Action intent was changed")
        }
        XCTAssertEqual(service.calls.albumCount, 0, "No automatic album read/creation or refresh")
        XCTAssertTrue(service.calls.shares.isEmpty)
    }

    func testDuplicateBulkGuardAndReadCancellationCannotCancelSubmittedMutation() async {
        let mutation = hold(), album = hold()
        let service = ResultActionsService(albums: { _ in await album.wait(); return [] },
            apply: { _, _ in await mutation.wait() })
        let state = ResultPhotoActionsState(service: service)
        let work = track { state.perform(.createAlbum("New"), ids: ["a"]) }
        await entered(mutation)
        let read = track { state.loadAlbums() }
        await entered(album)
        state.perform(.createAlbum("Duplicate"), ids: ["b"])
        state.prepareShare(ids: ["b"], networkAllowed: true)
        state.cancelPreparation()
        state.invalidateSelection()
        state.pause()
        state.libraryChanged()
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.albumsLoading)
        XCTAssertFalse(mutation.cancelled)
        XCTAssertFalse(album.cancelled)
        album.open()
        await finish(read)
        XCTAssertTrue(state.isBusy, "Album completion cannot finish a write")
        mutation.open()
        await finish(work)
        XCTAssertEqual(service.calls.actions.count, 1)
        XCTAssertTrue(service.calls.shares.isEmpty)
        XCTAssertFalse(mutation.cancelled)
        XCTAssertEqual(state.message, "已创建相册并加入照片")
        XCTAssertFalse(state.isBusy)
    }

    func testMutationFailuresAreSanitizedAndNeverClaimRollback() async {
        let errors: [Error] = [PhotoLibraryActionError.albumNotEditable, privateError(), CancellationError()]
        for (index, error) in errors.enumerated() {
            let service = ResultActionsService(apply: { _, _ in throw error })
            let state = ResultPhotoActionsState(service: service)
            await finish(track { state.perform(.addToAlbum("album"), ids: ["a"]) })
            XCTAssertEqual(state.message, index == 0 ? PhotoLibraryActionError.albumNotEditable.localizedDescription
                : PhotoLibraryActionError.mutationFailed.localizedDescription)
            XCTAssertFalse(state.isBusy)
            XCTAssertEqual(service.calls.actions.count, 1, "No retry")
            XCTAssertNil(state.albumIssue)
        }
    }

    func testShareValidatesBeforeFetchingAndAgainBeforePublication() async throws {
        let gate = hold()
        let prepared = try await makeShare(ids: ["a"])
        let service = ResultActionsService(prepare: { _, _ in await gate.wait(); return prepared })
        let state = ResultPhotoActionsState(service: service)
        service.accessError = PhotoLibraryActionError.permissionDenied
        await finish(track { state.prepareShare(ids: ["a"], networkAllowed: false) })
        XCTAssertTrue(service.calls.shares.isEmpty)
        XCTAssertEqual(state.message, PhotoLibraryActionError.permissionDenied.localizedDescription)
        service.accessError = nil
        let work = track { state.prepareShare(ids: ["a"], networkAllowed: false) }
        await entered(gate)
        XCTAssertEqual(service.calls.validations, [["a"], ["a"]])
        XCTAssertEqual(service.calls.validationCountsAtFetch, [2])
        service.accessError = PhotoLibraryActionError.unavailableAssets
        gate.open()
        await finish(work)
        XCTAssertEqual(service.calls.validations, [["a"], ["a"], ["a"]])
        XCTAssertNil(state.share)
        XCTAssertFalse(filesExist(prepared))
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.message, PhotoLibraryActionError.unavailableAssets.localizedDescription)
    }

    func testSharePublishesAutomaticallyWithExactNetworkOptInAndBlocksDuplicates() async throws {
        for networkAllowed in [false, true] {
            let gate = hold()
            let prepared = try await makeShare(ids: ["b", "a"])
            let service = ResultActionsService(prepare: { _, _ in await gate.wait(); return prepared })
            let state = ResultPhotoActionsState(service: service)
            var ids = ["b", "a", "b"]
            let work = track { state.prepareShare(ids: ids, networkAllowed: networkAllowed) }
            ids.removeAll()
            await entered(gate)
            state.prepareShare(ids: ["other"], networkAllowed: !networkAllowed)
            state.perform(.favorite(true), ids: ["other"])
            XCTAssertTrue(state.isBusy)
            gate.open()
            await finish(work)
            XCTAssertTrue(state.share === prepared)
            XCTAssertFalse(state.isBusy)
            XCTAssertFalse(state.sharingPresented)
            XCTAssertNil(state.message)
            XCTAssertEqual(service.calls.shares.map(\.ids), [["b", "a"]])
            XCTAssertEqual(service.calls.shares.map(\.networkAllowed), [networkAllowed])
            XCTAssertEqual(service.calls.validationCountsAtFetch, [1])
            XCTAssertEqual(service.calls.validations, [["b", "a"], ["b", "a"]])
            XCTAssertTrue(service.calls.actions.isEmpty)
            state.prepareShare(ids: ["other"], networkAllowed: false)
            XCTAssertEqual(service.calls.shares.count, 1, "Do not replace files used by a ready sheet")
            XCTAssertTrue(state.canPresent(prepared))
            XCTAssertTrue(state.validateShare(prepared))
            XCTAssertTrue(state.markSharingPresented())
            XCTAssertTrue(state.sharingPresented)
            state.dismissShare()
            XCTAssertFalse(filesExist(prepared))
        }
    }

    func testCancelledLateShareCleansItsFilesWithoutDrainingOrClearingNewShare() async throws {
        let gate = hold()
        let old = try await makeShare(ids: ["old"]), new = try await makeShare(ids: ["new"])
        let service = ResultActionsService(prepare: { ids, _ in
            if ids == ["old"] { await gate.wait(); return old }
            return new
        })
        let state = ResultPhotoActionsState(service: service)
        let first = track { state.prepareShare(ids: ["old"], networkAllowed: false) }
        await entered(gate)
        state.cancelPreparation()
        XCTAssertTrue(gate.cancelled)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.share)
        let second = track { state.prepareShare(ids: ["new"], networkAllowed: false) }
        await finish(second) // Old service still held: replacement must not drain.
        XCTAssertTrue(state.share === new)
        gate.open()
        await finish(first)
        XCTAssertFalse(filesExist(old), "Late successful read must be explicitly cleaned")
        XCTAssertTrue(filesExist(new))
        XCTAssertTrue(state.share === new)
        XCTAssertNil(state.message)
        XCTAssertFalse(state.isBusy)
        state.dismissShare()
    }

    func testShareErrorsAndCancelledLateErrorsCannotOverwriteNewPreparation() async throws {
        let errors: [Error] = [PhotoLibraryActionError.cloudOnly, privateError(), CancellationError()]
        for (index, error) in errors.enumerated() {
            let service = ResultActionsService(prepare: { _, _ in throw error })
            let state = ResultPhotoActionsState(service: service)
            await finish(track { state.prepareShare(ids: ["a"], networkAllowed: false) })
            let expected: String? = index == 0 ? PhotoLibraryActionError.cloudOnly.localizedDescription
                : (index == 1 ? PhotoLibraryActionError.sharePreparationFailed.localizedDescription : nil)
            XCTAssertEqual(state.message, expected)
            XCTAssertNil(state.share)
            XCTAssertFalse(state.isBusy)
            XCTAssertEqual(service.calls.shares.count, 1)
        }
        let oldGate = hold(), newGate = hold()
        let prepared = try await makeShare(ids: ["new"])
        let service = ResultActionsService(prepare: { ids, _ in
            if ids == ["old"] {
                await oldGate.wait()
                throw PhotoLibraryActionError.permissionDenied
            }
            await newGate.wait()
            return prepared
        })
        let state = ResultPhotoActionsState(service: service)
        let old = track { state.prepareShare(ids: ["old"], networkAllowed: false) }
        await entered(oldGate)
        state.pause()
        let new = track { state.prepareShare(ids: ["new"], networkAllowed: false) }
        await entered(newGate)
        oldGate.open()
        await finish(old)
        XCTAssertTrue(state.isBusy)
        XCTAssertNil(state.share)
        XCTAssertNil(state.message)
        newGate.open()
        await finish(new)
        XCTAssertTrue(state.share === prepared)
        state.dismissShare()
    }

    func testPresentedShareSurvivesBackgroundAndUnrelatedChangesButRejectsAccessLoss() async throws {
        let prepared = try await makeShare(ids: ["a"])
        let service = ResultActionsService(prepare: { _, _ in prepared })
        let state = ResultPhotoActionsState(service: service)
        await finish(track { state.prepareShare(ids: ["a"], networkAllowed: false) })
        state.pause() // Even ready but not yet marked must survive background.
        XCTAssertTrue(filesExist(prepared))
        XCTAssertTrue(state.markSharingPresented())
        state.pause()
        state.invalidateSelection()
        await finish(track { state.perform(.favorite(true), ids: ["a"]) })
        state.libraryChanged() // Our successful mutation is not an access loss.
        XCTAssertTrue(state.share === prepared)
        XCTAssertTrue(state.sharingPresented)
        XCTAssertTrue(filesExist(prepared))
        service.accessError = PhotoLibraryActionError.unavailableAssets
        XCTAssertFalse(state.canPresent(prepared))
        XCTAssertTrue(state.share === prepared, "Pure body check must not mutate published state")
        XCTAssertEqual(state.message, "已加入收藏")
        XCTAssertTrue(filesExist(prepared))
        XCTAssertFalse(state.validateShare(prepared))
        XCTAssertNil(state.share)
        XCTAssertFalse(state.sharingPresented)
        XCTAssertFalse(filesExist(prepared))
        XCTAssertEqual(state.message, PhotoLibraryActionError.unavailableAssets.localizedDescription)
        XCTAssertFalse(state.canPresent(prepared))
        XCTAssertFalse(state.markSharingPresented())

        let second = try await makeShare(ids: ["b"])
        let secondService = ResultActionsService(prepare: { _, _ in second })
        let secondState = ResultPhotoActionsState(service: secondService)
        await finish(track { secondState.prepareShare(ids: ["b"], networkAllowed: false) })
        secondService.accessError = PhotoLibraryActionError.permissionDenied
        secondState.libraryChanged()
        XCTAssertNil(secondState.share)
        XCTAssertFalse(filesExist(second))
        XCTAssertEqual(secondState.message, PhotoLibraryActionError.permissionDenied.localizedDescription)
    }

    func testIdentityDismissIgnoresOldShareAndUsesOwnershipAfterBindingClears() async throws {
        let old = try await makeShare(ids: ["old"]), new = try await makeShare(ids: ["new"])
        let service = ResultActionsService(prepare: { ids, _ in ids == ["old"] ? old : new })
        let state = ResultPhotoActionsState(service: service)
        await finish(track { state.prepareShare(ids: ["old"], networkAllowed: false) })
        XCTAssertTrue(state.beginPresentation(old))
        state.share = nil // SwiftUI can clear the binding before the identity callback.
        XCTAssertTrue(filesExist(old))
        state.dismissShare(id: old.id)
        XCTAssertFalse(filesExist(old))
        XCTAssertFalse(state.sharingPresented)

        await finish(track { state.prepareShare(ids: ["new"], networkAllowed: false) })
        let validations = service.calls.validations
        XCTAssertTrue(state.beginPresentation(new))
        XCTAssertEqual(service.calls.validations, validations + [["new"]])
        state.dismissShare(id: old.id)
        XCTAssertFalse(state.beginPresentation(old), "A stale presenter cannot validate or mark a replacement")
        XCTAssertEqual(service.calls.validations, validations + [["new"]])
        XCTAssertTrue(state.share === new)
        XCTAssertTrue(state.sharingPresented)
        XCTAssertTrue(filesExist(new))
        XCTAssertNil(state.message)

        state.share = nil
        state.dismissShare(id: old.id)
        XCTAssertTrue(state.sharingPresented)
        XCTAssertTrue(filesExist(new), "An old callback cannot clean the current owned share even with a nil binding")
        state.dismissShare(id: new.id)
        state.dismissShare(id: new.id)
        XCTAssertNil(state.share)
        XCTAssertFalse(state.sharingPresented)
        XCTAssertTrue(new.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(service.calls.actions.isEmpty)
    }

    func testBeginPresentationRechecksLostAccessBeforeMarkingAndCleansOwnedFiles() async throws {
        let cases: [(Error, String)] = [
            (PhotoLibraryActionError.permissionDenied, PhotoLibraryActionError.permissionDenied.localizedDescription),
            (PhotoLibraryActionError.unavailableAssets, PhotoLibraryActionError.unavailableAssets.localizedDescription),
            (privateError(), PhotoLibraryActionError.sharePreparationFailed.localizedDescription)
        ]
        for (error, expectedMessage) in cases {
            let prepared = try await makeShare(ids: ["a", "b"])
            let service = ResultActionsService(prepare: { _, _ in prepared })
            let state = ResultPhotoActionsState(service: service)
            await finish(track { state.prepareShare(ids: ["a", "b"], networkAllowed: false) })
            XCTAssertTrue(state.canPresent(prepared)) // Access changes after the read-only body check.
            XCTAssertFalse(state.sharingPresented)
            let validations = service.calls.validations
            var presentationChanges: [Bool] = []
            let observation = state.$sharingPresented.dropFirst().sink { presentationChanges.append($0) }
            defer { observation.cancel() }
            service.accessError = error

            XCTAssertFalse(state.beginPresentation(prepared))
            XCTAssertEqual(service.calls.validations, validations + [["a", "b"]])
            XCTAssertFalse(presentationChanges.contains(true), "Rejected access must never publish a presented state")
            XCTAssertNil(state.share)
            XCTAssertFalse(state.sharingPresented)
            XCTAssertFalse(state.isBusy)
            XCTAssertEqual(state.message, expectedMessage)
            XCTAssertTrue(prepared.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            service.accessError = nil
            XCTAssertFalse(state.beginPresentation(prepared), "Access restoration cannot resurrect cleaned ownership")
            XCTAssertEqual(service.calls.validations, validations + [["a", "b"]])
            XCTAssertTrue(service.calls.actions.isEmpty)
        }
    }

    func testCanPresentBodyChecksNeverPublishOrCleanOnSuccessDenialOrStaleIdentity() async throws {
        for alreadyPresented in [false, true] {
            let prepared = try await makeShare(ids: ["a"]), unowned = try await makeShare(ids: ["a"])
            let service = ResultActionsService(prepare: { _, _ in prepared })
            let state = ResultPhotoActionsState(service: service)
            await finish(track { state.prepareShare(ids: ["a"], networkAllowed: false) })
            if alreadyPresented { XCTAssertTrue(state.beginPresentation(prepared)) }
            let validations = service.calls.validations
            var publications = 0
            let observation = state.objectWillChange.sink { _ in publications += 1 }
            defer { observation.cancel() }

            XCTAssertFalse(state.canPresent(unowned))
            XCTAssertEqual(service.calls.validations, validations, "Reject unowned identity before checking access")
            XCTAssertTrue(state.canPresent(prepared))
            service.accessError = PhotoLibraryActionError.permissionDenied
            XCTAssertFalse(state.canPresent(prepared))
            XCTAssertFalse(state.canPresent(prepared)) // Repeated SwiftUI body evaluation.
            XCTAssertEqual(publications, 0)
            XCTAssertTrue(state.share === prepared)
            XCTAssertEqual(state.sharingPresented, alreadyPresented)
            XCTAssertNil(state.message)
            XCTAssertFalse(state.isBusy)
            XCTAssertTrue(filesExist(prepared))
            XCTAssertTrue(filesExist(unowned))
            service.accessError = nil
            XCTAssertTrue(state.canPresent(prepared))
            XCTAssertEqual(service.calls.validations, validations + Array(repeating: ["a"], count: 4))
            XCTAssertEqual(publications, 0)
            XCTAssertTrue(service.calls.actions.isEmpty)
        }
    }

    func testDismissBindingNilSelectionInvalidationAndDeinitCleanOwnedShare() async throws {
        for mode in 0..<3 {
            let prepared = try await makeShare(ids: ["a"])
            let service = ResultActionsService(prepare: { _, _ in prepared })
            var state: ResultPhotoActionsState? = ResultPhotoActionsState(service: service)
            await finish(track { state?.prepareShare(ids: ["a"], networkAllowed: false) })
            weak var weakState = state
            if mode == 0 {
                XCTAssertEqual(state?.markSharingPresented(), true)
                state?.share = nil // SwiftUI clears binding before onDismiss.
                XCTAssertTrue(filesExist(prepared))
                state?.pause()
                XCTAssertTrue(filesExist(prepared))
                state?.dismissShare()
                state?.dismissShare()
                XCTAssertEqual(state?.sharingPresented, false)
            } else if mode == 1 {
                state?.invalidateSelection()
                XCTAssertNil(state?.share)
            }
            state = nil
            XCTAssertNil(weakState)
            XCTAssertFalse(filesExist(prepared))
        }
    }

    func testDeinitCancelsReadsAndCleansLateSuccessButDoesNotCancelMutation() async throws {
        let album = hold(), preparation = hold(), mutation = hold()
        let prepared = try await makeShare(ids: ["a"])
        let service = ResultActionsService(albums: { _ in await album.wait(); return [] },
            apply: { _, _ in await mutation.wait() },
            prepare: { _, _ in await preparation.wait(); return prepared })
        var reader: ResultPhotoActionsState? = ResultPhotoActionsState(service: service)
        let albumWork = track { reader?.loadAlbums() }
        let shareWork = track { reader?.prepareShare(ids: ["a"], networkAllowed: false) }
        await entered(album, preparation)
        weak var weakReader = reader
        reader = nil
        XCTAssertNil(weakReader, "Read tasks must not hold the controller across await")
        XCTAssertTrue(album.cancelled)
        XCTAssertTrue(preparation.cancelled)
        var writer: ResultPhotoActionsState? = ResultPhotoActionsState(service: service)
        let writeWork = track { writer?.perform(.favorite(true), ids: ["a"]) }
        await entered(mutation)
        weak var weakWriter = writer
        writer = nil
        XCTAssertNil(weakWriter, "Submitted writes retain only the service")
        XCTAssertFalse(mutation.cancelled)
        album.open()
        preparation.open()
        mutation.open()
        await finish(albumWork, shareWork, writeWork)
        XCTAssertFalse(filesExist(prepared))
        XCTAssertFalse(mutation.cancelled)
        XCTAssertEqual(service.calls.actions.count, 1)
    }

    // MARK: Test-only lifetime fences, not sleeps/polling or production timeouts

    private func installCleanup() {
        guard !cleanupInstalled else { return }
        cleanupInstalled = true
        addTeardownBlock { @MainActor [self] in
            for gate in gates { gate.open() }
            let joins = completions.map { $0.expectation() }
            if !joins.isEmpty { await fulfillment(of: joins, timeout: 3) }
            for root in roots { try FileManager.default.removeItem(at: root) }
        }
    }

    private func hold() -> ResultActionsGate {
        installCleanup()
        let gate = ResultActionsGate()
        gates.append(gate)
        return gate
    }

    private func track(_ operation: () -> Void) -> ResultActionsCompletion {
        installCleanup()
        let completion = ResultActionsCompletion()
        completions.append(completion)
        ResultActionsTaskScope.$lifetime.withValue(ResultActionsTaskLifetime(completion)) { operation() }
        return completion
    }

    private func entered(_ gates: ResultActionsGate...) async {
        await fulfillment(of: gates.map(\.started), timeout: 3)
    }

    private func finish(_ values: ResultActionsCompletion...) async {
        await fulfillment(of: values.map { $0.expectation() }, timeout: 3)
    }

    private func makeShare(ids: [String]) async throws -> PreparedPhotoShare {
        installCleanup()
        let root = try TestFixtures.temporaryDirectory()
        roots.append(root)
        return try await PhotoSharePreparer.prepare(ids: ids, temporaryRoot: root,
            validate: { _ in }, write: { _, url in try Data([1, 2, 3]).write(to: url) })
    }

    private func filesExist(_ share: PreparedPhotoShare) -> Bool {
        share.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func privateError() -> Error {
        NSError(domain: "synthetic-private-path", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "private asset ID /private/photo.jpg secret album"])
    }
}

private final class ResultActionsService: PhotoLibraryActions, @unchecked Sendable {
    struct ShareCall {
        let ids: [String]
        let networkAllowed: Bool
    }
    struct Calls {
        var albumCount = 0
        var actions: [PhotoBatchAction] = []
        var selections: [[String]] = []
        var shares: [ShareCall] = []
        var validations: [[String]] = []
        var validationCountsAtFetch: [Int] = []
    }

    private let lock = NSLock()
    private var recorded = Calls()
    private var denied: Error?
    private let readAlbums: @Sendable (Int) async throws -> [PhotoAlbum]
    private let mutate: @Sendable (PhotoBatchAction, [String]) async throws -> Void
    private let prepare: @Sendable ([String], Bool) async throws -> PreparedPhotoShare

    init(albums: @escaping @Sendable (Int) async throws -> [PhotoAlbum] = { _ in [] },
         apply: @escaping @Sendable (PhotoBatchAction, [String]) async throws -> Void = { _, _ in },
         prepare: @escaping @Sendable ([String], Bool) async throws -> PreparedPhotoShare = { _, _ in
             throw PhotoLibraryActionError.sharePreparationFailed
         }) {
        readAlbums = albums
        mutate = apply
        self.prepare = prepare
    }

    var calls: Calls { locked { recorded } }
    var accessError: Error? {
        get { locked { denied } }
        set { locked { denied = newValue } }
    }

    func albums() async throws -> [PhotoAlbum] {
        let index = locked { let index = recorded.albumCount; recorded.albumCount += 1; return index }
        return try await readAlbums(index)
    }

    func apply(_ action: PhotoBatchAction, to ids: [String]) async throws {
        locked { recorded.actions.append(action); recorded.selections.append(ids) }
        try await mutate(action, ids)
    }

    func prepareShare(ids: [String], networkAllowed: Bool) async throws -> PreparedPhotoShare {
        locked {
            recorded.shares.append(ShareCall(ids: ids, networkAllowed: networkAllowed))
            recorded.validationCountsAtFetch.append(recorded.validations.count)
        }
        return try await prepare(ids, networkAllowed)
    }

    func validateAccess(ids: [String]) throws {
        let error = locked { recorded.validations.append(ids); return denied }
        if let error { throw error }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

/// Noncooperative service callback: cancellation is recorded, not used to open
/// the gate. This forces the controller to reject/clean a real late success.
private final class ResultActionsGate: @unchecked Sendable {
    let started = XCTestExpectation(description: "Service reached held callback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var cancellationObserved = false

    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationObserved
    }

    func wait() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { install($0) }
        }, onCancel: { self.recordCancellation() })
    }

    func open() {
        lock.lock()
        opened = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }

    private func install(_ value: CheckedContinuation<Void, Never>) {
        lock.lock()
        let alreadyOpen = opened
        if !alreadyOpen { continuation = value }
        lock.unlock()
        started.fulfill()
        if alreadyOpen { value.resume() }
    }

    private func recordCancellation() {
        lock.lock(); defer { lock.unlock() }
        cancellationObserved = true
    }
}

/// Inherited by unstructured Tasks, released only when their full body finishes
/// (including stale-result cleanup). No test-only API is added to the controller.
private enum ResultActionsTaskScope {
    @TaskLocal static var lifetime: ResultActionsTaskLifetime?
}

private final class ResultActionsTaskLifetime: @unchecked Sendable {
    let completion: ResultActionsCompletion
    init(_ completion: ResultActionsCompletion) { self.completion = completion }
    deinit { completion.complete() }
}

/// Independent subscribers allow both the test and teardown to join completion.
private final class ResultActionsCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var subscribers: [XCTestExpectation] = []

    func expectation() -> XCTestExpectation {
        let value = XCTestExpectation(description: "Controller task completed")
        value.assertForOverFulfill = true
        lock.lock()
        let alreadyCompleted = completed
        if !alreadyCompleted { subscribers.append(value) }
        lock.unlock()
        if alreadyCompleted { value.fulfill() }
        return value
    }

    func complete() {
        lock.lock()
        completed = true
        let pending = subscribers
        subscribers.removeAll()
        lock.unlock()
        for value in pending { value.fulfill() }
    }
}