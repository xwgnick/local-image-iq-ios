import CryptoKit
import Darwin
import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

final class SimilarGroupingCheckpointTests: XCTestCase {
    private enum Stop: Error { case interrupted }

    private func directory() throws -> URL {
        let value = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: value) }
        return value
    }

    private func key(threshold: Float = 0.9, signature: UInt8 = 1,
                     authorization: Int? = 3, model: String = "test-model",
                     algorithm: String = SimilarPhotoGroupingPolicy.algorithmVersion,
                     policy: String = IndexImagePolicy.version,
                     revisions: [String: PhotoRevision] = [:]) throws -> SimilarGroupingCacheKey {
        try SimilarGroupingCacheKey(authorized: revisions, imagePayloadSignature: Data(repeating: signature, count: 32),
            modelVersion: model, authorization: authorization, threshold: threshold,
            algorithmVersion: algorithm, policyVersion: policy)
    }

    private func restored(_ cache: SimilarGroupingCache, key: SimilarGroupingCacheKey) throws -> SimilarGroupingCheckpointState {
        guard case .restored(let state) = try cache.readCheckpoint(key: key) else {
            XCTFail("Expected a durable, matching checkpoint")
            throw Stop.interrupted
        }
        return state
    }

    func testColdResumeDoesLessArithmeticAndExactlyMatchesUninterruptedGroupingBits() async throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let identity = try key()
        let photos = (0..<40).flatMap { axis in
            ["a", "b"].map { suffix in
                IndexedPhoto(id: String(format: "%03d-", axis) + suffix, modificationTime: 1,
                    modelVersion: "test-model", imageEmbedding: TestFixtures.vector(axis: axis))
            }
        }
        let prepared = try SimilarGroupingPreparedInput(photos: Array(photos.reversed()))
        let baseline = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: 0.9)
        do {
            _ = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: 0.9,
                saveCheckpoint: { value in
                    try cache.saveCheckpoint(value, key: identity, validate: {})
                    throw Stop.interrupted
                })
            XCTFail("The first committed checkpoint must interrupt this invocation")
        } catch Stop.interrupted {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL.path),
                       "Partial arithmetic must never become a completed cache.")
        let cold = SimilarGroupingCache(directory: root)
        let saved = try restored(cold, key: identity)
        XCTAssertEqual(saved.completed, 32)
        XCTAssertEqual(saved.groups.count, 16)
        try saved.validate(count: prepared.photos.count, threshold: 0.9)
        let resumed = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: 0.9,
            progress: {
                XCTAssertEqual($0.resumed, 32)
                XCTAssertGreaterThanOrEqual($0.completed, 32)
            }, checkpoint: saved)
        XCTAssertEqual(resumed.groups.map { $0.photos.map(\.id) }, baseline.groups.map { $0.photos.map(\.id) })
        XCTAssertEqual(resumed.groups.map { $0.minimumSimilarity.bitPattern },
                       baseline.groups.map { $0.minimumSimilarity.bitPattern })
        XCTAssertEqual(baseline.metrics.matrixMultiplyCount, 40)
        XCTAssertEqual(resumed.metrics.matrixMultiplyCount, 24, "Sixteen finished seeds are NOT recomputed.")
        try cold.removeCheckpoint(validate: {})
        guard case .missing = try cold.readCheckpoint(key: identity) else {
            return XCTFail("Only the separate checkpoint should be removed.")
        }
    }

    func testMissingCheckpointDoesNotCreateStorageAndEveryInputIdentityChangeRejectsResume() throws {
        let root = try directory().appendingPathComponent("absent")
        let cache = SimilarGroupingCache(directory: root)
        let identity = try key()
        guard case .missing = try cache.readCheckpoint(key: identity) else { return XCTFail("Expected missing") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let state = SimilarGroupingCheckpointState(nextSeed: 1, assigned: [true, false], groups: [])
        try cache.saveCheckpoint(state, key: identity, validate: {})
        let changed = [
            try key(threshold: 0.91), try key(signature: 2), try key(authorization: 4),
            try key(model: "other-model"), try key(algorithm: "other-algorithm"), try key(policy: "other-policy"),
            try key(revisions: ["new": .init(id: "new", modificationTime: 1, creationTime: nil)])
        ]
        for identity in changed {
            guard case .stale = try cache.readCheckpoint(key: identity) else {
                return XCTFail("A changed full input key must never reuse partial work")
            }
        }
        XCTAssertEqual(try restored(cache, key: identity).completed, 1)
    }

    func testMalformedStateCannotAssignFutureSingletonsOverlapGroupsOrResumeOutsideInput() throws {
        let invalid: [SimilarGroupingCheckpointState] = [
            .init(nextSeed: 3, assigned: [true, true], groups: []),
            .init(nextSeed: 1, assigned: [false, false], groups: []),
            .init(nextSeed: 1, assigned: [true, true], groups: []),
            .init(nextSeed: 1, assigned: [true, true], groups: [.init(members: [0, 2], minimumBits: Float(1).bitPattern)]),
            .init(nextSeed: 1, assigned: [true, true], groups: [.init(members: [0, 0], minimumBits: Float(1).bitPattern)]),
            .init(nextSeed: 1, assigned: [true, true], groups: [.init(members: [0, 1], minimumBits: Float.nan.bitPattern)]),
            .init(nextSeed: 1, assigned: [true, true], groups: [.init(members: [0, 1], minimumBits: Float(0.8).bitPattern)])
        ]
        for value in invalid { XCTAssertThrowsError(try value.validate(count: 2, threshold: 0.9)) }
        XCTAssertNoThrow(try SimilarGroupingCheckpointState(nextSeed: 1, assigned: [true, true],
            groups: [.init(members: [0, 1], minimumBits: Float(1).bitPattern)]).validate(count: 2, threshold: 0.9))
    }

    func testFailedCancelledAndRevokedAtomicSavesPreserveOldCheckpoint() throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let identity = try key()
        let old = SimilarGroupingCheckpointState(nextSeed: 1, assigned: [true, false], groups: [])
        let replacement = SimilarGroupingCheckpointState(nextSeed: 2, assigned: [true, true], groups: [])
        try cache.saveCheckpoint(old, key: identity, validate: {})
        let url = root.appendingPathComponent("similar-groups-checkpoint-v1.bin")
        let bytes = try Data(contentsOf: url)
        for error in [Stop.interrupted as Error, CancellationError(), AppFailure.permission] {
            let failing = SimilarGroupingCache(directory: root, beforeCommit: { throw error })
            XCTAssertThrowsError(try failing.saveCheckpoint(replacement, key: identity, validate: {}))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(try restored(cache, key: identity).completed, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["similar-groups-checkpoint-v1.bin"], "No staged files should survive rollback.")
    }

    func testCheckpointCannotFollowOrReplaceSymlinkAndCorruptionIsExplicitlyStale() throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let target = root.appendingPathComponent("source")
        let bytes = Data("original source must remain unchanged".utf8)
        try bytes.write(to: target)
        let url = root.appendingPathComponent("similar-groups-checkpoint-v1.bin")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let identity = try key()
        guard case .stale = try cache.readCheckpoint(key: identity) else { return XCTFail("Symlink is not missing") }
        XCTAssertThrowsError(try cache.saveCheckpoint(.init(nextSeed: 0, assigned: [], groups: []),
            key: identity, validate: {}))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        try FileManager.default.removeItem(at: url)
        try Data("corrupt checkpoint".utf8).write(to: url)
        guard case .stale = try cache.readCheckpoint(key: identity) else { return XCTFail("Corruption is not missing") }
    }

    func testCheckpointStorageHasProtectionAndNeverSerializesPhotosOrVectors() throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        try cache.saveCheckpoint(.init(nextSeed: 1, assigned: [true, true],
            groups: [.init(members: [0, 1], minimumBits: Float(1).bitPattern)]), key: key(), validate: {})
        let url = root.appendingPathComponent("similar-groups-checkpoint-v1.bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let envelope = try PropertyListDecoder().decode(SimilarGroupingCheckpointEnvelope.self, from: Data(contentsOf: url))
        XCTAssertEqual(envelope.sha256, Data(SHA256.hash(data: envelope.payload)))
        let payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: envelope.payload, format: nil) as? [String: Any])
        let state = try XCTUnwrap(payload["state"] as? [String: Any])
        XCTAssertEqual(Set(state.keys), ["nextSeed", "assigned", "groups"])
    }
}
