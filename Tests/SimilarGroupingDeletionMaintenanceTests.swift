import Darwin
import Foundation
import ImageIO
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

/// Real temporary SQLite + completed binary caches. Only Photos metadata and
/// resource inspection are fake; any pixel/model work is a test failure.
final class SimilarGroupingDeletionMaintenanceTests: XCTestCase {
    private func fixture(_ photos: [IndexedPhoto]? = nil, authorized: [PhotoRevision]? = nil,
                         generation: UInt64? = 0) throws -> DeletionMaintenanceFixture {
        let f = try DeletionMaintenanceFixture(photos: photos, authorized: authorized, generation: generation)
        addTeardownBlock { try FileManager.default.removeItem(at: f.directory) }
        return f
    }

    func testOptionalDigestReaderKeepsLegacySnapshotAndDecodeRoundTrip() async throws {
        let f = try fixture([deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("single", axis: 2), deletionPhoto("stale")])
        f.library.setRevision("stale", modification: 999, creation: nil)
        try deletionSQL(f.directory, "UPDATE photos SET image_embedding = X'FFFF' WHERE id = 'stale'")
        let reader = SQLitePhotoStore(directory: f.directory, readOnly: true)
        let ids = Set(f.library.values.map(\.id))
        let old = try await reader.groupingInputSnapshot(modelVersion: deletionModel, accessibleIDs: ids)
        let new = try await reader.groupingDeletionSnapshot(modelVersion: deletionModel, accessibleIDs: ids)
        XCTAssertEqual(old, new.source)
        XCTAssertEqual(new.rowDigests.count, 4)
        let records = try await reader.groupingImageRecords(modelVersion: deletionModel, accessibleIDs: ids,
            eligibleIDs: ["a", "b", "single"], expectedSnapshot: new.source)
        XCTAssertEqual(records.map(\.id), ["a", "b", "single"])
        try deletionSQL(f.directory, "UPDATE photos SET geography_version = 'changed', place_text = NULL")
        let irrelevant = try await reader.groupingDeletionSnapshot(modelVersion: deletionModel, accessibleIDs: ids)
        XCTAssertEqual(irrelevant.source, old)
        XCTAssertEqual(irrelevant.rowDigests, new.rowDigests)
        let emptyOld = try await reader.groupingInputSnapshot(modelVersion: deletionModel, accessibleIDs: [])
        let emptyNew = try await reader.groupingDeletionSnapshot(modelVersion: deletionModel, accessibleIDs: [])
        XCTAssertEqual(emptyOld, emptyNew.source)
        XCTAssertTrue(emptyNew.rowDigests.isEmpty)
    }

    func testConfirmedDeleteSurvivesActualSyncPruneAndWarmAndColdRestore() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(result.groups.map { $0.photos.map(\.id) }, [["a", "c", "d"]])
        XCTAssertEqual(result.candidateCount, 4) // Includes an ungrouped singleton.
        XCTAssertThrowsError(try old.validatePublicationEpoch())
        try await result.prepareForPublication()
        try result.validatePhotos(["a", "c"])
        try result.validatePublicationEpoch()
        XCTAssertNotEqual(result.deletionBaselineID, old.deletionBaselineID)
        assertMaintenance(f.metrics.values, pairs: 3)
        let cacheBytes = try Data(contentsOf: f.cacheURL)
        let warm = try deletionRestored(await f.service.restore(threshold: 0.95))
        let cold = try deletionRestored(await f.newService().restore(threshold: 0.95))
        XCTAssertEqual(warm.groups.map(\.id), result.groups.map(\.id))
        XCTAssertEqual(cold.groups.map { $0.photos.map(\.id) }, result.groups.map { $0.photos.map(\.id) })
        XCTAssertEqual(try Data(contentsOf: f.cacheURL), cacheBytes)
        XCTAssertEqual(f.metrics.values.count, 2, "No hidden global computation on the next entry")
    }

    func testDeletionBeforeSyncPruneRemainsReusableAfterPruneAndIrrelevantMetadataWrite() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        let maintained = try deletionRestored(await f.service.restore(threshold: 0.95))
        try await f.prune(["b"])
        try deletionSQL(f.directory, "UPDATE photos SET geography_version = 'different'")
        XCTAssertThrowsError(try maintained.validatePublicationEpoch())
        let latest = try deletionRestored(await f.service.restore(threshold: 0.95))
        try latest.validatePublicationEpoch()
        XCTAssertEqual(latest.candidateCount, 4)
        assertMaintenance(f.metrics.values, pairs: 3)
    }

    func testDeletedSeedIsReplacedAndMinimumRecomputedOnlyWithinRetainedGroup() async throws {
        let photos = [deletionPhoto("a", angle: 0), deletionPhoto("b", angle: 0.1),
                      deletionPhoto("c", angle: 0.2), deletionPhoto("d", angle: 0.3)]
        let f = try fixture(photos)
        let old = try await f.group()
        try await f.confirm(["a"], from: old)
        f.library.remove(["a"])
        try await f.prune(["a"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        let retained = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(retained.id, "b")
        XCTAssertEqual(retained.photos.first?.id, "b")
        XCTAssertGreaterThan(retained.minimumSimilarity, try XCTUnwrap(old.groups.first).minimumSimilarity)
        let reference = try await SimilarPhotoGrouper.group(photos: Array(photos.dropFirst()), threshold: 0.95)
        XCTAssertEqual(retained.minimumSimilarity.bitPattern, reference.first?.minimumSimilarity.bitPattern)
        assertMaintenance(f.metrics.values, pairs: 3)
    }

    func testMultipleSuccessfulDeletionsThenLastPairProducePersistedZero() async throws {
        let f = try fixture([deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c"), deletionPhoto("d")])
        var result = try await f.group()
        for ids: [String] in [["a"], ["b"], ["c", "d"]] {
            try await f.confirm(ids, from: result)
            f.library.remove(Set(ids))
            try await f.prune(ids)
            result = try deletionRestored(await f.service.restore(threshold: 0.95))
            try await result.prepareForPublication()
        }
        XCTAssertEqual(result.candidateCount, 0)
        XCTAssertEqual(result.staleCount, 0)
        XCTAssertEqual(result.unindexedCount, 0)
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(f.metrics.values.count, 4)
        XCTAssertTrue(f.metrics.values.dropFirst().allSatisfy { $0.computation.matrixMultiplyCount == 0 && $0.computation.seedScoreCount == 0 })
        let restored = try deletionRestored(await f.newService().restore(threshold: 0.95))
        XCTAssertEqual(restored.candidateCount, 0)
        XCTAssertTrue(restored.groups.isEmpty)
    }

    func testSeveralConfirmedRequestsCoalesceAgainstOneBaseline() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["a"], from: old)
        try await f.confirm(["b"], from: old)
        f.library.remove(["a", "b"])
        try await f.prune(["a", "b"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(result.groups.map { $0.photos.map(\.id) }, [["c", "d"]])
        assertMaintenance(f.metrics.values, pairs: 1)
    }

    func testWholeGroupRemovalDropsSingletonsButKeepsCoverageCounts() async throws {
        let photos = [deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c", axis: 1),
                      deletionPhoto("d", axis: 1), deletionPhoto("single", axis: 2), deletionPhoto("stale", axis: 3)]
        var authorized = photos.map(deletionRevision)
        authorized[5] = PhotoRevision(id: "stale", modificationTime: 999, creationTime: 100)
        authorized.append(PhotoRevision(id: "unindexed", modificationTime: 123, creationTime: nil))
        let f = try fixture(photos, authorized: authorized)
        let old = try await f.group()
        try await f.confirm(["a", "b", "c"], from: old)
        f.library.remove(["a", "b", "c"])
        try await f.prune(["a", "b", "c"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertEqual(result.candidateCount, 2)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.unindexedCount, 1)
        assertMaintenance(f.metrics.values, pairs: 0)
    }

    func testMaintainedSubsetIntentionallyDoesNotRediscoverUnlockedPairUntilExplicitGroup() async throws {
        let f = try fixture([deletionPhoto("a", angle: 0), deletionPhoto("b", angle: 0.25), deletionPhoto("c", angle: -0.26)])
        let old = try await f.group()
        XCTAssertEqual(old.groups.first?.photos.map(\.id), ["a", "b"])
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let maintained = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertTrue(maintained.groups.isEmpty)
        XCTAssertEqual(maintained.candidateCount, 2)
        let cached = try deletionRestored(await f.newService().restore(threshold: 0.95))
        XCTAssertTrue(cached.groups.isEmpty)
        let discovered = try await f.group()
        XCTAssertEqual(discovered.groups.first?.photos.map(\.id), ["a", "c"])
        XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
    }

    func testColdRestoreReconstructsFullBaselineNotJustGroupMembers() async throws {
        let f = try fixture()
        _ = try await f.group()
        let cold = f.newService()
        let old = try deletionRestored(await cold.restore(threshold: 0.95))
        let deleted = try XCTUnwrap(f.library.values.first { $0.id == "b" })
        await cold.confirmedDeletion(revisions: [deleted], baselineID: old.deletionBaselineID)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let maintained = try deletionRestored(await cold.restore(threshold: 0.95))
        XCTAssertEqual(maintained.candidateCount, 4)
        assertMaintenance(f.metrics.values, pairs: 3)
    }

    func testSameRevisionBLOBRewriteForMemberSingletonAndStaleRowRejectsFastPath() async throws {
        for id in ["c", "single", "stale"] {
            let photos = [deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c"),
                          deletionPhoto("single", axis: 2), deletionPhoto("stale", axis: 3)]
            let f = try fixture(photos)
            f.library.setRevision("stale", modification: 999, creation: 100)
            _ = try await f.group()
            // Cold restore has no preparedResident with which to accidentally
            // mask a missing singleton/stale-row digest.
            let cold = f.newService()
            let old = try deletionRestored(await cold.restore(threshold: 0.95))
            let revision = try XCTUnwrap(f.library.values.first { $0.id == "b" })
            await cold.confirmedDeletion(revisions: [revision], baselineID: old.deletionBaselineID)
            f.library.remove(["b"])
            try await f.prune(["b"])
            // Identical metadata, valid but DIFFERENT vector bytes.
            try TestFixtures.seedRawCache([CachedPhoto(photo: deletionPhoto(id, axis: 4), geographyVersion: "geo")], directory: f.directory)
            assertStale(try await cold.restore(threshold: 0.95))
            XCTAssertEqual(f.metrics.values.count, 1)
            _ = try await cold.group(threshold: 0.95) { _ in }
            XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
        }
    }

    func testAuthLimitedScopeMissingIsNotAnAppDeletion() async throws {
        for changesAuthorization in [false, true] {
            let f = try fixture()
            if !changesAuthorization { f.library.setAuthorization(4) }
            let old = try await f.group()
            try await f.confirm(["b"], from: old)
            f.library.remove(changesAuthorization ? ["b"] : ["b", "single"])
            if changesAuthorization { f.library.setAuthorization(4) }
            assertStale(try await f.service.restore(threshold: 0.95))
            XCTAssertEqual(f.metrics.values.count, 1)
            _ = try await f.group()
            XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
        }
    }

    func testNewPhotoEditCreationThresholdAndModelChangesUseNormalFullPath() async throws {
        for change in ["new", "edit", "creation", "threshold", "model", "new-indexed-row"] {
            let f = try fixture()
            if change == "new-indexed-row" { f.library.append(PhotoRevision(id: "new", modificationTime: 123, creationTime: 100)) }
            let old = try await f.group()
            try await f.confirm(["b"], from: old)
            f.library.remove(["b"])
            try await f.prune(["b"])
            var threshold: Float = 0.95
            switch change {
            case "new": f.library.append(PhotoRevision(id: "new", modificationTime: 123, creationTime: 100))
            case "edit": f.library.setRevision("single", modification: 124, creation: 100)
            case "creation": f.library.setRevision("single", modification: 123, creation: 101)
            case "threshold": threshold = 0.96
            case "model": await f.encoders.setModel("changed-model")
            default: try TestFixtures.seedRawCache([CachedPhoto(photo: deletionPhoto("new", axis: 4), geographyVersion: "geo")], directory: f.directory)
            }
            assertStale(try await f.service.restore(threshold: threshold))
            XCTAssertEqual(f.metrics.values.count, 1)
            _ = try await f.service.group(threshold: threshold) { _ in }
            XCTAssertEqual(f.metrics.values.count, 2)
            XCTAssertEqual(f.metrics.values.last?.preparationCount, 1)
        }
    }

    func testPartialOrNotYetVisibleDeletionGrantsNoResultAndDoesNotConsumeEvidence() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["a", "b"], from: old)
        assertWaiting(try await f.service.restore(threshold: 0.95))
        f.library.remove(["a"])
        try await f.prune(["a"])
        assertWaiting(try await f.service.restore(threshold: 0.95))
        XCTAssertEqual(f.metrics.values.count, 1)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(result.groups.first?.photos.map(\.id), ["c", "d"])
        assertMaintenance(f.metrics.values, pairs: 1)
    }

    func testSyncPruneBeforePhotosEnumerationWaitsWithoutConsumingConfirmedEvidence() async throws {
        let f = try fixture()
        let old = try await f.group()
        let cacheBytes = try Data(contentsOf: f.cacheURL)
        try await f.confirm(["a", "b"], from: old)
        try await f.prune(["b"])
        // Both confirmed IDs remain visible: a has its exact old row, b has none.
        XCTAssertEqual(Set(f.library.values.map(\.id)), ["a", "b", "c", "d", "single"])
        assertWaiting(try await f.service.restore(threshold: 0.95))
        assertWaiting(try await f.service.restore(threshold: 0.95))
        XCTAssertEqual(f.metrics.values.count, 1, "Waiting must not compute or report maintenance work")
        XCTAssertEqual(try Data(contentsOf: f.cacheURL), cacheBytes)
        f.library.remove(["a"])
        try await f.prune(["a"])
        assertWaiting(try await f.service.restore(threshold: 0.95))
        XCTAssertEqual(f.metrics.values.count, 1)
        XCTAssertEqual(try Data(contentsOf: f.cacheURL), cacheBytes)
        f.library.remove(["b"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(result.groups.map { $0.photos.map(\.id) }, [["c", "d"]])
        XCTAssertEqual(result.candidateCount, 3)
        XCTAssertEqual(result.staleCount, 0)
        XCTAssertEqual(result.unindexedCount, 0)
        XCTAssertNotEqual(result.deletionBaselineID, old.deletionBaselineID)
        try await result.prepareForPublication()
        try result.validatePublicationEpoch()
        assertMaintenance(f.metrics.values, pairs: 1)
    }

    func testNondeletedBLOBRewriteRejectsEvenWhileConfirmedPrunedPhotoIsVisible() async throws {
        for id in ["c", "single", "stale"] {
            let f = try fixture([deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c"),
                                 deletionPhoto("single", axis: 2), deletionPhoto("stale", axis: 3)])
            f.library.setRevision("stale", modification: 999, creation: 100)
            let old = try await f.group()
            try await f.confirm(["b"], from: old)
            try await f.prune(["b"])
            // Combine the permitted prune with an unrelated same-revision
            // rewrite BEFORE the first restore; awaiting must not mask it.
            try TestFixtures.seedRawCache([CachedPhoto(photo: deletionPhoto(id, axis: 4), geographyVersion: "geo")], directory: f.directory)
            XCTAssertNotNil(f.library.values.first { $0.id == "b" })
            assertStale(try await f.service.restore(threshold: 0.95))
            XCTAssertEqual(f.metrics.values.count, 1)
            _ = try await f.group()
            XCTAssertEqual(f.metrics.values.count, 2)
            XCTAssertGreaterThan(try XCTUnwrap(f.metrics.values.last).computation.matrixMultiplyCount, 0)
        }
    }

    func testConfirmedVisibleBLOBRewriteOrReinsertionRejectsAwaitingDeletion() async throws {
        for pruned in [false, true] {
            let f = try fixture()
            let old = try await f.group()
            try await f.confirm(["b"], from: old)
            if pruned { try await f.prune(["b"]) }
            assertWaiting(try await f.service.restore(threshold: 0.95))
            // A new/different row is not deletion evidence, even at the exact
            // captured Photos revision and even after an earlier awaiting read.
            try TestFixtures.seedRawCache([CachedPhoto(photo: deletionPhoto("b", axis: 4), geographyVersion: "geo")], directory: f.directory)
            assertStale(try await f.service.restore(threshold: 0.95))
            XCTAssertEqual(f.metrics.values.count, 1)
        }
    }

    func testConfirmedVisibleSameIDRevisionChangeRejectsWithPresentOrPrunedRow() async throws {
        for pruned in [false, true] {
            for creationOnly in [false, true] {
                let f = try fixture()
                let old = try await f.group()
                try await f.confirm(["b"], from: old)
                if pruned { try await f.prune(["b"]) }
                assertWaiting(try await f.service.restore(threshold: 0.95))
                f.library.setRevision("b", modification: creationOnly ? 123 : 124,
                                      creation: creationOnly ? 101 : 100)
                assertStale(try await f.service.restore(threshold: 0.95))
                XCTAssertEqual(f.metrics.values.count, 1)
            }
        }
    }

    func testUnboundWrongRevisionDuplicateAndSupersededProvenanceDoNotGrantDeletion() async throws {
        for kind in ["unbound", "wrong-revision", "duplicate", "superseded", "foreign-token"] {
            let f = try fixture()
            let old = try await f.group()
            let revision = try XCTUnwrap(f.library.values.first { $0.id == "b" })
            switch kind {
            case "unbound": await f.service.confirmedDeletion(revisions: [revision])
            case "wrong-revision": await f.service.confirmedDeletion(revisions: [PhotoRevision(id: "b", modificationTime: 999, creationTime: 100)], baselineID: old.deletionBaselineID)
            case "duplicate": await f.service.confirmedDeletion(revisions: [revision, revision], baselineID: old.deletionBaselineID)
            case "superseded":
                _ = try deletionRestored(await f.service.restore(threshold: 0.95))
                await f.service.confirmedDeletion(revisions: [revision], baselineID: old.deletionBaselineID)
            default: await f.service.confirmedDeletion(revisions: [revision], baselineID: UUID())
            }
            f.library.remove(["b"])
            try await f.prune(["b"])
            assertStale(try await f.service.restore(threshold: 0.95))
            XCTAssertEqual(f.metrics.values.count, 1)
        }
    }

    func testCreationAndGenerationRacesDuringMaintenanceNeverPublishOrSave() async throws {
        for kind in ["creation", "generation", "source"] {
            let f = try fixture(generation: kind == "creation" ? nil : 0)
            let old = try await f.group()
            try await f.confirm(["b"], from: old)
            f.library.remove(["b"])
            try await f.prune(["b"])
            let bytes = try Data(contentsOf: f.cacheURL)
            let finalCall = f.library.enumerations + 3
            f.library.onEnumeration { call in
                guard call == finalCall else { return }
                switch kind {
                case "creation": f.library.setRevision("single", modification: 123, creation: 101)
                case "generation": f.library.bumpGeneration()
                default: try deletionSQL(f.directory, "UPDATE photos SET geography_version = 'raced'")
                }
            }
            do { _ = try await f.service.restore(threshold: 0.95); XCTFail("Raced authority must reject publication") }
            catch { }
            f.library.onEnumeration(nil)
            XCTAssertEqual(try Data(contentsOf: f.cacheURL), bytes)
            XCTAssertEqual(f.metrics.values.count, 1)
        }
    }

    func testFreshNilGenerationValidatorIncludesUngroupedAndUnindexedRevisions() async throws {
        let f = try fixture(generation: nil)
        f.library.append(PhotoRevision(id: "unindexed", modificationTime: 123, creationTime: nil))
        let old = try await f.group()
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        try await result.prepareForPublication()
        f.library.setRevision("unindexed", modification: 123, creation: 101)
        do { try await result.prepareForPublication(); XCTFail("Full fresh scope must reject the change") }
        catch { }
    }

    func testCancelledRestoreRetainsCompletedDeletionEvidenceForNextFreshRead() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let gate = DeletionMaintenanceGate()
        addTeardownBlock { gate.open() }
        await f.encoders.onInspection { await gate.wait() }
        let task = Task { try await f.service.restore(threshold: 0.95) }
        await fulfillment(of: [gate.entered], timeout: 5)
        task.cancel()
        gate.open()
        do { _ = try await task.value; XCTFail("Cancelled read must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        await f.encoders.onInspection(nil)
        _ = try deletionRestored(await f.service.restore(threshold: 0.95))
        assertMaintenance(f.metrics.values, pairs: 3)
    }

    func testMaintenanceCacheFailureKeepsValidatedResidentButSourceFailureIsFatal() async throws {
        for sourceRace in [false, true] {
            let f = try fixture()
            _ = try await f.group()
            let cache = SimilarGroupingCache(directory: f.directory, beforeCommit: {
                if sourceRace { try deletionSQL(f.directory, "UPDATE photos SET geography_version = 'commit-race'") }
                else { throw DeletionMaintenanceFailure.fixture }
            })
            let service = f.newService(cache: cache)
            let old = try deletionRestored(await service.restore(threshold: 0.95))
            let revision = try XCTUnwrap(f.library.values.first { $0.id == "b" })
            await service.confirmedDeletion(revisions: [revision], baselineID: old.deletionBaselineID)
            f.library.remove(["b"])
            try await f.prune(["b"])
            let bytes = try Data(contentsOf: f.cacheURL)
            if sourceRace {
                do { _ = try await service.restore(threshold: 0.95); XCTFail("Cannot downgrade source failure to cache warning") }
                catch let error as SimilarCleanupDiagnostic { XCTAssertTrue(error.isSourceFailure) }
                catch { XCTFail("Expected typed source failure") }
            } else {
                let result = try deletionRestored(await service.restore(threshold: 0.95))
                XCTAssertNotNil(result.persistenceIssue)
                let resident = try deletionRestored(await service.restore(threshold: 0.95))
                XCTAssertEqual(resident.candidateCount, 4)
                XCTAssertNotNil(resident.persistenceIssue)
                assertMaintenance(f.metrics.values, pairs: 3)
            }
            XCTAssertEqual(try Data(contentsOf: f.cacheURL), bytes)
        }
    }

    func testCancelledFullRediscoveryDoesNotEraseCompletedDeletionEvidence() async throws {
        let f = try fixture()
        let old = try await f.group()
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        let gate = DeletionMaintenanceGate()
        addTeardownBlock { gate.open() }
        await f.encoders.onInspection { await gate.wait() }
        let task = Task { try await f.group() }
        await fulfillment(of: [gate.entered], timeout: 5)
        task.cancel()
        gate.open()
        do { _ = try await task.value; XCTFail("Cancelled full read must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        await f.encoders.onInspection(nil)
        _ = try deletionRestored(await f.service.restore(threshold: 0.95))
        assertMaintenance(f.metrics.values, pairs: 3)
    }

    func testLateSupersededReadCannotReplaceNewMaintainedBaseline() async throws {
        let f = try fixture()
        let old = try await f.group()
        let gate = DeletionMaintenanceGate()
        addTeardownBlock { gate.open() }
        await f.encoders.onInspection { await gate.wait() }
        let staleRead = Task { try await f.service.restore(threshold: 0.95) }
        await fulfillment(of: [gate.entered], timeout: 5)
        // Confirmation arrived after that read captured the old Photos scope.
        try await f.confirm(["b"], from: old)
        f.library.remove(["b"])
        try await f.prune(["b"])
        await f.encoders.onInspection(nil)
        let current = try deletionRestored(await f.service.restore(threshold: 0.95))
        gate.open()
        do { _ = try await staleRead.value; XCTFail("Superseded scope must not publish") }
        catch { }
        assertMaintenance(f.metrics.values, pairs: 3)
        try await f.confirm(["c"], from: current)
        f.library.remove(["c"])
        try await f.prune(["c"])
        let next = try deletionRestored(await f.service.restore(threshold: 0.95))
        XCTAssertEqual(next.groups.first?.photos.map(\.id), ["a", "d"])
        XCTAssertEqual(f.metrics.values.count, 3)
        XCTAssertEqual(f.metrics.values.last?.computation.matrixMultiplyCount, 0)
    }

    func testUnchangedGroupsPreserveMemberOrderAndMinimumBitsWithoutRescoring() async throws {
        let f = try fixture([deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c"),
            deletionPhoto("x", axis: 3), deletionPhoto("y", axis: 3), deletionPhoto("z", axis: 3)])
        let old = try await f.group()
        let unchanged = try XCTUnwrap(old.groups.first { $0.id == "x" })
        try await f.confirm(["a"], from: old)
        f.library.remove(["a"])
        try await f.prune(["a"])
        let result = try deletionRestored(await f.service.restore(threshold: 0.95))
        let kept = try XCTUnwrap(result.groups.first { $0.id == "x" })
        XCTAssertEqual(kept.photos.map(\.id), unchanged.photos.map(\.id))
        XCTAssertEqual(kept.minimumSimilarity.bitPattern, unchanged.minimumSimilarity.bitPattern)
        assertMaintenance(f.metrics.values, pairs: 1)
    }

    func testDefaultApplicationSupportAliasMaintainsAfterCanonicalSourcePrune() async throws {
        let f = try fixture()
        let physical = f.directory.appendingPathComponent("physical", isDirectory: true)
        let base = physical.appendingPathComponent("ApplicationSupport", isDirectory: true)
        let source = base.appendingPathComponent("LocalImageIQIndex", isDirectory: true)
        let alias = f.directory.appendingPathComponent("ancestor-alias", isDirectory: true)
        let photos = f.library.values.map { deletionPhoto($0.id, axis: $0.id == "single" ? 2 : 0) }
        try TestFixtures.seedRawCache(photos.map { CachedPhoto(photo: $0, geographyVersion: "geo") }, directory: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let recorder = f.metrics
        let service = SimilarPhotoGroupingService(library: f.library, encoders: f.encoders,
            reportMetrics: { recorder.append($0) }, defaultLocation: {
                try SimilarGroupingLocation.applicationSupport(alias.appendingPathComponent("ApplicationSupport"))
            })
        let old = try await service.group(threshold: 0.95) { _ in }
        let revision = try XCTUnwrap(f.library.values.first { $0.id == "b" })
        await service.confirmedDeletion(revisions: [revision], baselineID: old.deletionBaselineID)
        f.library.remove(["b"])
        let writer = SQLitePhotoStore(directory: source)
        _ = try await writer.remove(recordIDs: ["b"])
        await writer.close()
        let result = try deletionRestored(await service.restore(threshold: 0.95))
        try result.validatePublicationEpoch()
        XCTAssertEqual(result.candidateCount, 4)
        assertMaintenance(f.metrics.values, pairs: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent(SimilarGroupingCache.fileName).path))
    }

    private func assertMaintenance(_ metrics: [SimilarGroupingWorkMetrics], pairs: Int,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(metrics.count, 2, file: file, line: line)
        guard metrics.count == 2 else { return }
        XCTAssertGreaterThan(metrics[0].computation.matrixMultiplyCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].sourceSnapshotCount, 3, file: file, line: line)
        XCTAssertEqual(metrics[1].decodedRowCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].preparationCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].computation.matrixMultiplyCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].computation.seedScoreCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].computation.sortCandidateCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].computation.sortComparisonCount, 0, file: file, line: line)
        XCTAssertEqual(metrics[1].computation.memberScoreCount, pairs, file: file, line: line)
    }

    private func assertStale(_ result: SimilarPhotoGroupingRestore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .stale = result else { return XCTFail("Expected normal full-path fallback", file: file, line: line) }
    }

    private func assertWaiting(_ result: SimilarPhotoGroupingRestore, file: StaticString = #filePath, line: UInt = #line) {
        guard case .awaitingDeletion = result else { return XCTFail("Must not grant partial deletion authority", file: file, line: line) }
    }
}

// Shared synthetic fixtures for the real-service controller tests in the second
// file. No production Photos client is constructed by either suite.
let deletionModel = IndexImagePolicy.cacheVersion(modelVersion: "test-model")

func deletionPhoto(_ id: String, axis: Int = 0, angle: Double? = nil) -> IndexedPhoto {
    var vector = TestFixtures.vector(axis: axis)
    if let angle { vector[0] = Float(cos(angle)); vector[1] = Float(sin(angle)) }
    return IndexedPhoto(id: id, modificationTime: 123, modelVersion: deletionModel,
        imageEmbedding: vector, location: nil, creationTime: 100)
}

func deletionRevision(_ photo: IndexedPhoto) -> PhotoRevision {
    PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
}

func deletionRestored(_ result: SimilarPhotoGroupingRestore, file: StaticString = #filePath,
                      line: UInt = #line) throws -> SimilarPhotoGroupingResult {
    guard case .restored(let value) = result else {
        XCTFail("Expected validated restored result", file: file, line: line)
        throw DeletionMaintenanceFailure.fixture
    }
    return value
}

enum DeletionMaintenanceFailure: Error { case fixture }

struct DeletionMaintenanceFixture: Sendable {
    let directory: URL
    let library: DeletionMaintenanceLibrary
    let encoders: DeletionMaintenanceEncoders
    let metrics: DeletionMaintenanceMetrics
    let service: SimilarPhotoGroupingService
    var cacheURL: URL { directory.appendingPathComponent(SimilarGroupingCache.fileName) }

    init(photos: [IndexedPhoto]? = nil, authorized: [PhotoRevision]? = nil, generation: UInt64? = 0) throws {
        let temporary = try TestFixtures.temporaryDirectory()
        // SourceAuthority intentionally rejects symlink ancestors; use a real
        // canonical temporary root rather than relying on simulator /var aliases.
        let resolved = try XCTUnwrap(temporary.path.withCString { Darwin.realpath($0, nil) })
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let input = photos ?? [deletionPhoto("a"), deletionPhoto("b"), deletionPhoto("c"),
                              deletionPhoto("d"), deletionPhoto("single", axis: 2)]
        try TestFixtures.seedRawCache(input.map { CachedPhoto(photo: $0, geographyVersion: "geo") }, directory: directory)
        library = DeletionMaintenanceLibrary(authorized ?? input.map(deletionRevision), generation: generation)
        encoders = DeletionMaintenanceEncoders()
        let recorder = DeletionMaintenanceMetrics()
        metrics = recorder
        service = SimilarPhotoGroupingService(library: library, directory: directory, encoders: encoders,
            reportMetrics: { recorder.append($0) })
    }

    func newService(cache: SimilarGroupingCache? = nil) -> SimilarPhotoGroupingService {
        let recorder = metrics
        return SimilarPhotoGroupingService(library: library, directory: directory, encoders: encoders,
            cache: cache, reportMetrics: { recorder.append($0) })
    }
    func group() async throws -> SimilarPhotoGroupingResult { try await service.group(threshold: 0.95) { _ in } }
    func confirm(_ ids: [String], from result: SimilarPhotoGroupingResult) async throws {
        let captured = try ids.map { id in try XCTUnwrap(library.values.first { $0.id == id }) }
        await service.confirmedDeletion(revisions: captured, baselineID: result.deletionBaselineID)
    }
    func prune(_ ids: [String]) async throws {
        let writer = SQLitePhotoStore(directory: directory)
        do { _ = try await writer.remove(recordIDs: ids); await writer.close() }
        catch { await writer.close(); throw error }
    }
}

final class DeletionMaintenanceMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SimilarGroupingWorkMetrics] = []
    var values: [SimilarGroupingWorkMetrics] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ metrics: SimilarGroupingWorkMetrics) { lock.lock(); defer { lock.unlock() }; recorded.append(metrics) }
}

actor DeletionMaintenanceEncoders: PhotoEncoding {
    private var model = "test-model"
    private var inspection: (@Sendable () async -> Void)?
    func setModel(_ value: String) { model = value }
    func onInspection(_ action: (@Sendable () async -> Void)?) { inspection = action }
    func inspectResources() async throws -> ModelManifest {
        await inspection?()
        let text = TestFixtures.manifest.replacingOccurrences(of: "test-model", with: model)
        return try JSONDecoder().decode(ModelManifest.self, from: Data(text.utf8))
    }
    private func forbidden() -> DeletionMaintenanceFailure { XCTFail("No inference/model preparation allowed"); return .fixture }
    func prepare() throws -> ModelManifest { throw forbidden() }
    func image(preview: IndexingImage) throws -> [Float] { throw forbidden() }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] { throw forbidden() }
    func text(_ text: String) throws -> [Float] { throw forbidden() }
}

final class DeletionMaintenanceLibrary: PhotoLibraryIndexing, PhotoRevisionBatchReading, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [PhotoRevision]
    private var generation: UInt64?
    private var authorization: Int? = 3
    private var readable = true
    private var fullReads = 0
    private var action: (@Sendable (Int) throws -> Void)?
    init(_ rows: [PhotoRevision], generation: UInt64?) { self.rows = rows; self.generation = generation }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var values: [PhotoRevision] { locked { rows } }
    var enumerations: Int { locked { fullReads } }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { generation } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func bumpGeneration() { locked { if let old = generation { generation = old + 1 } } }
    func append(_ revision: PhotoRevision) { locked { rows.append(revision) }; bumpGeneration() }
    func remove(_ ids: Set<String>) { locked { rows.removeAll { ids.contains($0.id) } }; bumpGeneration() }
    func setRevision(_ id: String, modification: Double, creation: Double?) {
        locked {
            if let index = rows.firstIndex(where: { $0.id == id }) {
                rows[index] = PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
            }
        }
    }
    func onEnumeration(_ action: (@Sendable (Int) throws -> Void)?) { locked { self.action = action } }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let (number, hook) = locked { fullReads += 1; return (fullReads, action) }
        try hook?(number)
        return try locked { guard readable else { throw AppFailure.permission }; return rows }
    }
    func currentRevision(id: String) -> PhotoRevision? { locked { readable ? rows.first { $0.id == id } : nil } }
    func currentRevisions(ids: [String]) throws -> [PhotoRevision] {
        try locked { guard readable else { throw AppFailure.permission }; return rows.filter { ids.contains($0.id) } }
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { XCTFail("No places requested"); return nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        XCTFail("No photo pixels requested"); throw DeletionMaintenanceFailure.fixture
    }
}

final class DeletionMaintenanceGate: @unchecked Sendable {
    let entered = XCTestExpectation(description: "Deterministic deletion/read milestone")
    private let lock = NSLock()
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { install($0) } }
    private func install(_ value: CheckedContinuation<Void, Never>) {
        lock.lock()
        let ready = opened
        if !ready { continuation = value }
        lock.unlock()
        entered.fulfill()
        if ready { value.resume() }
    }
    func open() {
        lock.lock()
        opened = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

func deletionSQL(_ directory: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path, &handle,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    defer { if let handle { sqlite3_close(handle) } }
    guard status == SQLITE_OK, let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DeletionMaintenanceFailure.fixture
    }
}