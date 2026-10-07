import CryptoKit
import Darwin
import Foundation
import ImageIQCore
import XCTest
@testable import LocalImageIQ

final class SimilarGroupingCacheTests: XCTestCase {
    private let model = IndexImagePolicy.cacheVersion(modelVersion: "test-model")

    private func directory() throws -> URL {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func photo(_ id: String, vector: [Float]? = nil, creation: Double? = 100) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: 123, modelVersion: model,
                     imageEmbedding: vector ?? TestFixtures.vector(),
                     location: PlaceEmbedding(text: "Never persist this place", vector: TestFixtures.vector(axis: 7)),
                     creationTime: creation)
    }

    private func revisions(_ photos: [IndexedPhoto]) -> [String: PhotoRevision] {
        var values: [String: PhotoRevision] = [:]
        for photo in photos {
            values[photo.id] = PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
        }
        return values
    }

    private func key(_ authorized: [String: PhotoRevision], threshold: Float = 0.80,
                     model: String? = nil, algorithm: String = SimilarPhotoGroupingPolicy.algorithmVersion,
                     policy: String = IndexImagePolicy.version, authorization: Int? = 3,
                     signature: Data? = nil) throws -> SimilarGroupingCacheKey {
        try SimilarGroupingCacheKey(authorized: authorized,
            imagePayloadSignature: signature ?? Data(SHA256.hash(data: Data("synthetic opaque source".utf8))),
            modelVersion: model ?? self.model, authorization: authorization, threshold: threshold,
            algorithmVersion: algorithm, policyVersion: policy)
    }

    @discardableResult
    private func savePair(_ cache: SimilarGroupingCache) throws -> [String: PhotoRevision] {
        let photos = [photo("a"), photo("b")]
        let input = revisions(photos)
        try cache.save(groups: [SimilarPhotoGroup(id: "a", photos: photos, minimumSimilarity: 1)],
                       candidateCount: 2, staleCount: 0, unindexedCount: 0, key: key(input), authorized: input, indexed: input)
        return input
    }

    private func restored(_ read: SimilarGroupingCacheRead, file: StaticString = #filePath,
                          line: UInt = #line) throws -> SimilarGroupingCachedResult {
        guard case .restored(let value) = read else {
            XCTFail("Expected a completed cache, including zero groups.", file: file, line: line)
            throw SimilarGroupingCacheError.invalid
        }
        return value
    }

    private func assertStale(_ read: SimilarGroupingCacheRead, file: StaticString = #filePath, line: UInt = #line) {
        guard case .stale = read else { XCTFail("Must be stale, never first-use missing.", file: file, line: line); return }
    }

    /// Native test-only mutation, recomputing SHA deliberately to exercise
    /// structural validation separately from accidental-corruption detection.
    private func mutatePayload(_ cache: SimilarGroupingCache, _ edit: (inout [String: Any]) throws -> Void) throws {
        let bytes = try Data(contentsOf: cache.fileURL)
        let envelope = try PropertyListDecoder().decode(SimilarGroupingCacheEnvelope.self, from: bytes)
        var payload = try XCTUnwrap(PropertyListSerialization.propertyList(from: envelope.payload, format: nil) as? [String: Any])
        try edit(&payload)
        let changed = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(SimilarGroupingCacheEnvelope(payload: changed)).write(to: cache.fileURL)
    }

    func testInitializationAndMissingReadNeverCreateFolderOrFile() throws {
        let root = try directory().appendingPathComponent("absent", isDirectory: true)
        let cache = SimilarGroupingCache(directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let value = try cache.read(key: key([:]), authorized: [:], indexed: [:])
        guard case .missing = value else { return XCTFail("An absent completed cache is first use.") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testBinaryRoundTripPreservesEveryFloatBitGroupOrderCountsAndMetadataWithoutLocations() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        var vector = TestFixtures.vector()
        vector[0] = 0.6
        vector[1] = 0.8
        vector[2] = Float(bitPattern: 0x80000000) // Negative zero survives binary packing.
        vector[3] = Float.leastNonzeroMagnitude
        let a = photo("a", vector: vector, creation: nil)
        let b = photo("b", vector: vector, creation: 0)
        let c = photo("c", vector: vector, creation: 100.125)
        let d = photo("d"), e = photo("e"), single = photo("single")
        var authorized = revisions([a, b, c, d, e, single])
        authorized["stale"] = PhotoRevision(id: "stale", modificationTime: 124, creationTime: 100)
        authorized["new"] = PhotoRevision(id: "new", modificationTime: 123, creationTime: nil)
        var indexed = revisions([a, b, c, d, e, single])
        indexed["stale"] = PhotoRevision(id: "stale", modificationTime: 123, creationTime: 100)
        let groups: [SimilarPhotoGroup] = [
            SimilarPhotoGroup(id: "a", photos: [a, c, b], minimumSimilarity: Float(0.91).nextUp),
            SimilarPhotoGroup(id: "d", photos: [d, e], minimumSimilarity: 1)
        ]
        let identity = try key(authorized)
        try cache.save(groups: groups, candidateCount: 6, staleCount: 1, unindexedCount: 1,
                       key: identity, authorized: authorized, indexed: indexed)
        let bytes = try Data(contentsOf: cache.fileURL)
        XCTAssertTrue(bytes.starts(with: Data("bplist00".utf8)))
        let envelope = try PropertyListDecoder().decode(SimilarGroupingCacheEnvelope.self, from: bytes)
        let payload = try PropertyListDecoder().decode(SimilarGroupingCachePayload.self, from: envelope.payload)
        XCTAssertEqual(payload.groups[0].photos[0].image.count, 768 * 4)
        XCTAssertNil(bytes.range(of: Data("Never persist this place".utf8)))
        let cold = SimilarGroupingCache(directory: cache.directory)
        let result = try restored(cold.read(key: identity, authorized: authorized, indexed: indexed))
        XCTAssertEqual(result.groups.map(\.id), ["a", "d"])
        XCTAssertEqual(result.groups[0].photos.map(\.id), ["a", "c", "b"], "Preserve score admission order, not a new ID sort.")
        XCTAssertEqual(result.groups.map { $0.minimumSimilarity.bitPattern }, groups.map { $0.minimumSimilarity.bitPattern })
        XCTAssertEqual(result.candidateCount, 6)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.unindexedCount, 1)
        XCTAssertEqual(result.threshold.bitPattern, Float(0.80).bitPattern)
        for (actual, expected) in zip(result.groups.flatMap(\.photos), groups.flatMap(\.photos)) {
            XCTAssertEqual(actual.imageEmbedding.map(\.bitPattern), expected.imageEmbedding.map(\.bitPattern))
            XCTAssertEqual(actual.modificationTime.bitPattern, expected.modificationTime.bitPattern)
            XCTAssertEqual(actual.creationTime?.bitPattern, expected.creationTime?.bitPattern)
            XCTAssertEqual(actual.modelVersion, expected.modelVersion)
            XCTAssertNil(actual.location)
        }
    }

    func testSuccessfulZeroGroupsAreCompletedAcrossRestartForEmptySingletonAndStaleLibraries() throws {
        for mode in 0..<3 {
            let cache = SimilarGroupingCache(directory: try directory())
            let authorized: [String: PhotoRevision] = mode == 0 ? [:] : revisions([photo("single")])
            let indexed: [String: PhotoRevision]
            if mode == 2 { indexed = ["single": PhotoRevision(id: "single", modificationTime: 122, creationTime: 100)] }
            else { indexed = authorized }
            let candidates = mode == 1 ? 1 : 0
            let identity = try key(authorized)
            try cache.save(groups: [], candidateCount: candidates, staleCount: mode == 2 ? 1 : 0,
                           unindexedCount: 0, key: identity, authorized: authorized, indexed: indexed)
            let result = try restored(SimilarGroupingCache(directory: cache.directory).read(key: identity, authorized: authorized, indexed: indexed))
            XCTAssertTrue(result.groups.isEmpty)
            XCTAssertEqual(result.candidateCount, candidates)
        }
    }

    func testThresholdFloatBitsModelPolicyAlgorithmAuthorizationAndImageSignatureMismatchAreStale() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        let keys: [SimilarGroupingCacheKey] = try [
            key(input, threshold: Float(0.80).nextUp), key(input, threshold: 0.99),
            key(input, model: "different-model"), key(input, algorithm: "next-algorithm"),
            key(input, policy: "next-input-policy"), key(input, authorization: 4), key(input, authorization: nil),
            key(input, signature: Data(SHA256.hash(data: Data("rewritten image".utf8))))
        ]
        let before = try Data(contentsOf: cache.fileURL)
        for identity in keys { assertStale(try cache.read(key: identity, authorized: input, indexed: input)) }
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before, "Stale lookup never repairs/deletes/replaces a cache.")
    }

    func testFullScopeDigestDetectsEqualCountSwapModificationCreationNilAndUnindexedChanges() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        var changes: [[String: PhotoRevision]] = []
        changes.append(["a": input["a"]!, "c": PhotoRevision(id: "c", modificationTime: 123, creationTime: 100)])
        for revision in [PhotoRevision(id: "b", modificationTime: 124, creationTime: 100),
                         PhotoRevision(id: "b", modificationTime: 123, creationTime: 101),
                         PhotoRevision(id: "b", modificationTime: 123, creationTime: nil)] {
            changes.append(["a": input["a"]!, "b": revision])
        }
        var expanded = input
        expanded["new"] = PhotoRevision(id: "new", modificationTime: 1, creationTime: nil)
        changes.append(expanded)
        for authorized in changes {
            assertStale(try cache.read(key: key(authorized), authorized: authorized, indexed: input))
        }
    }

    func testDigestUsesDeterministicLengthFramedUTF8AndNullableFullRevisionBits() throws {
        let ids = ["b|c", "a", "é", "中", "a\u{0000}b"]
        var forward: [String: PhotoRevision] = [:]
        var reverse: [String: PhotoRevision] = [:]
        for id in ids { forward[id] = PhotoRevision(id: id, modificationTime: 1, creationTime: nil) }
        for id in ids.reversed() { reverse[id] = PhotoRevision(id: id, modificationTime: 1, creationTime: nil) }
        XCTAssertEqual(try key(forward), try key(reverse))
        let left = revisions([photo("a"), photo("bc")])
        let right = revisions([photo("ab"), photo("c")])
        XCTAssertNotEqual(try key(left), try key(right))
        let nilDate = revisions([photo("a", creation: nil)])
        let zeroDate = revisions([photo("a", creation: 0)])
        let negativeZero = revisions([photo("a", creation: -Double.zero)])
        XCTAssertNotEqual(try key(nilDate), try key(zeroDate))
        XCTAssertNotEqual(try key(zeroDate), try key(negativeZero))
    }

    func testMissingIndexedRowAndWrongCountsCannotPublishEvenWithMatchingKey() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        assertStale(try cache.read(key: key(input), authorized: input, indexed: ["a": input["a"]!]))
        for field in ["candidateCount", "staleCount", "unindexedCount"] {
            try savePair(cache)
            try mutatePayload(cache) { $0[field] = -1 }
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
        }
    }

    func testCorruptTruncatedAndUnknownSchemaCachesNeverBecomeMissingOrGetDeleted() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        let valid = try Data(contentsOf: cache.fileURL)
        var variants: [Data] = [Data(), Data("not a plist".utf8), Data(valid.prefix(valid.count / 2))]
        for field in ["schema", "magic", "payloadSHA256", "payload"] {
            var envelope = try XCTUnwrap(PropertyListSerialization.propertyList(from: valid, format: nil) as? [String: Any])
            switch field {
            case "schema": envelope[field] = 99
            case "magic": envelope[field] = "unrecognized"
            default: envelope[field] = Data("corrupt".utf8)
            }
            variants.append(try PropertyListSerialization.data(fromPropertyList: envelope, format: .binary, options: 0))
        }
        for bytes in variants {
            try bytes.write(to: cache.fileURL)
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
            XCTAssertEqual(try Data(contentsOf: cache.fileURL), bytes)
        }
    }

    func testMemberScopeRevisionModelAndSeedAreValidatedAfterIntegrityCheck() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        for field in ["id", "modificationTime", "creationTime", "modelVersion"] {
            try savePair(cache)
            try mutatePayload(cache) { payload in
                var groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
                var photos = try XCTUnwrap(groups[0]["photos"] as? [[String: Any]])
                switch field {
                case "id": photos[1][field] = "outside-scope"
                case "modelVersion": photos[1][field] = "other-model"
                default: photos[1][field] = 999.0
                }
                groups[0]["photos"] = photos
                payload["groups"] = groups
            }
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
        }
        try savePair(cache)
        try mutatePayload(cache) { payload in
            var groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
            groups[0]["id"] = "b"
            payload["groups"] = groups
        }
        assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
    }

    func testSingletonDuplicateAndOverlappingGroupsAreRejected() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        for variant in 0..<3 {
            try savePair(cache)
            try mutatePayload(cache) { payload in
                var groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
                var photos = try XCTUnwrap(groups[0]["photos"] as? [[String: Any]])
                if variant == 0 { photos.removeLast() }
                if variant == 1 { photos[1] = photos[0] }
                groups[0]["photos"] = photos
                if variant == 2 { groups.append(groups[0]) }
                payload["groups"] = groups
            }
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
        }
    }

    func testNonfiniteOutOfBoundsAndBelowThresholdMinimumScoresAreRejected() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        let values: [Float] = [.nan, .infinity, -.infinity, Float(1).nextUp, Float(0.80).nextDown, -1]
        for value in values {
            try savePair(cache)
            try mutatePayload(cache) { payload in
                var groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
                groups[0]["minimumBits"] = NSNumber(value: value.bitPattern)
                payload["groups"] = groups
            }
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
        }
    }

    func testBinaryVectorsRejectWrongLengthNaNInfinityAndNonunitWithoutSourceJSON() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        var nan = TestFixtures.vector(); nan[1] = .nan
        var infinity = TestFixtures.vector(); infinity[1] = .infinity
        var nonunit = TestFixtures.vector(); nonunit[0] = 2
        let vectors: [[Float]] = [[], TestFixtures.vector(dimension: 512), nan, infinity, nonunit, [Float](repeating: 0, count: 768)]
        for vector in vectors {
            try savePair(cache)
            let bad = SimilarGroupingCachePhoto(photo("b", vector: vector)).image
            try mutatePayload(cache) { payload in
                var groups = try XCTUnwrap(payload["groups"] as? [[String: Any]])
                var photos = try XCTUnwrap(groups[0]["photos"] as? [[String: Any]])
                photos[1]["image"] = bad
                groups[0]["photos"] = photos
                payload["groups"] = groups
            }
            assertStale(try cache.read(key: key(input), authorized: input, indexed: input))
        }
    }

    func testGroupRankingMustBeDescendingSizeThenStableID() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let photos = [photo("a"), photo("b"), photo("c"), photo("d"), photo("e")]
        let input = revisions(photos)
        let big = SimilarPhotoGroup(id: "c", photos: Array(photos[2...]), minimumSimilarity: 1)
        let small = SimilarPhotoGroup(id: "a", photos: Array(photos[..<2]), minimumSimilarity: 1)
        XCTAssertThrowsError(try cache.save(groups: [small, big], candidateCount: 5, staleCount: 0, unindexedCount: 0,
                                           key: key(input), authorized: input, indexed: input))
        try cache.save(groups: [big, small], candidateCount: 5, staleCount: 0, unindexedCount: 0,
                       key: key(input), authorized: input, indexed: input)
        let read = try restored(cache.read(key: key(input), authorized: input, indexed: input))
        XCTAssertEqual(read.groups.map(\.id), ["c", "a"])
        let four = revisions(Array(photos[..<4]))
        let other = SimilarPhotoGroup(id: "c", photos: Array(photos[2..<4]), minimumSimilarity: 1)
        XCTAssertThrowsError(try cache.save(groups: [other, small], candidateCount: 4, staleCount: 0, unindexedCount: 0,
                                           key: key(four), authorized: four, indexed: four))
    }

    func testGroupSeedMustBeLowestIDButScoreOrderedMembersNeedNotBeIDSorted() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let photos = [photo("a"), photo("b"), photo("c")]
        let input = revisions(photos)
        let good = SimilarPhotoGroup(id: "a", photos: [photos[0], photos[2], photos[1]], minimumSimilarity: 1)
        try cache.save(groups: [good], candidateCount: 3, staleCount: 0, unindexedCount: 0,
                       key: key(input), authorized: input, indexed: input)
        let bad = SimilarPhotoGroup(id: "b", photos: [photos[1], photos[0], photos[2]], minimumSimilarity: 1)
        XCTAssertThrowsError(try cache.save(groups: [bad], candidateCount: 3, staleCount: 0, unindexedCount: 0,
                                           key: key(input), authorized: input, indexed: input))
    }

    func testLargeCompletedGroupRestoresAllMembersWithoutCapacityLimit() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        var photos: [IndexedPhoto] = []
        for index in 0..<1024 { photos.append(photo(String(format: "asset-%05d", index))) }
        let input = revisions(photos)
        try cache.save(groups: [SimilarPhotoGroup(id: photos[0].id, photos: photos, minimumSimilarity: 1)],
                       candidateCount: photos.count, staleCount: 0, unindexedCount: 0,
                       key: key(input), authorized: input, indexed: input)
        let value = try restored(cache.read(key: key(input), authorized: input, indexed: input))
        XCTAssertEqual(value.groups[0].photos.count, 1024)
        XCTAssertEqual(value.groups[0].photos.last?.id, photos.last?.id)
    }

    func testCacheFileAndDirectorySymlinksAreStaleNeverFollowedOrUnlinked() throws {
        let root = try directory()
        let target = root.appendingPathComponent("source.bin")
        let source = Data("protected source".utf8)
        try source.write(to: target)
        let cache = SimilarGroupingCache(directory: root)
        try FileManager.default.createSymbolicLink(at: cache.fileURL, withDestinationURL: target)
        assertStale(try cache.read(key: key([:]), authorized: [:], indexed: [:]))
        XCTAssertThrowsError(try savePair(cache))
        XCTAssertEqual(try Data(contentsOf: target), source)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: cache.fileURL.path)[.type] as? FileAttributeType, .typeSymbolicLink)
        let link = root.appendingPathComponent("linked-directory")
        let real = root.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let linked = SimilarGroupingCache(directory: link)
        assertStale(try linked.read(key: key([:]), authorized: [:], indexed: [:]))
        XCTAssertThrowsError(try savePair(linked))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path), [])
    }

    func testDanglingCacheSymlinkAndNonregularDestinationAreNotMissing() throws {
        for symlink in [true, false] {
            let cache = SimilarGroupingCache(directory: try directory())
            if symlink {
                try FileManager.default.createSymbolicLink(at: cache.fileURL, withDestinationURL: cache.directory.appendingPathComponent("absent"))
            } else {
                try FileManager.default.createDirectory(at: cache.fileURL, withIntermediateDirectories: false)
            }
            assertStale(try cache.read(key: key([:]), authorized: [:], indexed: [:]))
            XCTAssertThrowsError(try savePair(cache))
        }
    }

    func testUnreadableExistingCacheThrowsInsteadOfMissing() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        XCTAssertEqual(cache.fileURL.path.withCString { chmod($0, 0) }, 0)
        defer { _ = cache.fileURL.path.withCString { chmod($0, 0o600) } }
        XCTAssertThrowsError(try cache.read(key: key(input), authorized: input, indexed: input))
    }

    func testAtomicWriteFailurePreservesOldCacheAndCleansOnlyItsOwnTemporaryFile() throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let input = try savePair(cache)
        let before = try Data(contentsOf: cache.fileURL)
        let unknown = root.appendingPathComponent(".similar-groups-other-writer.tmp")
        try Data("untouched".utf8).write(to: unknown)
        let failing = SimilarGroupingCache(directory: root, beforeCommit: { throw SimilarGroupingCacheError.unavailable })
        XCTAssertThrowsError(try failing.save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                                              key: key(input), authorized: input, indexed: input))
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [SimilarGroupingCache.fileName, unknown.lastPathComponent])
    }

    func testReplacedStagingSymlinkIsNeitherPublishedNorUnlinked() throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let input = try savePair(cache)
        let before = try Data(contentsOf: cache.fileURL)
        let target = root.appendingPathComponent("protected-source")
        try Data("keep source".utf8).write(to: target)
        let replaced = SimilarGroupingCache(directory: root, beforeCommit: {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            let temp = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(".similar-groups-") })
            try FileManager.default.removeItem(at: temp)
            try FileManager.default.createSymbolicLink(at: temp, withDestinationURL: target)
        })
        XCTAssertThrowsError(try replaced.save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                                               key: key(input), authorized: input, indexed: input))
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep source".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let temp = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix(".similar-groups-") })
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: temp.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testCancellationBeforeAtomicRenamePreservesOldFileAndRemovesOwnPartial() async throws {
        let root = try directory()
        let cache = SimilarGroupingCache(directory: root)
        let input = try savePair(cache)
        let identity = try key(input)
        let before = try Data(contentsOf: cache.fileURL)
        let cancelling = SimilarGroupingCache(directory: root, beforeCommit: { withUnsafeCurrentTask { $0?.cancel() } })
        let task = Task {
            try cancelling.save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                                key: identity, authorized: input, indexed: input)
        }
        do { try await task.value; XCTFail("Cancelled staging must not commit.") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error).") }
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [SimilarGroupingCache.fileName])
    }

    func testPrecommitAccessFailurePreservesPreviousCompletedCache() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        let before = try Data(contentsOf: cache.fileURL)
        XCTAssertThrowsError(try cache.save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                                           key: key(input), authorized: input, indexed: input,
                                           validate: { throw AppFailure.permission }))
        XCTAssertEqual(try Data(contentsOf: cache.fileURL), before)
    }

    func testAtomicReplacementCommitsZeroGroupsAndDoesNotDeleteUnrelatedSourceFiles() throws {
        let cache = SimilarGroupingCache(directory: try directory())
        let input = try savePair(cache)
        let unrelatedNames = ["index.sqlite3", "text-index.sqlite3", "Places.geojson", "search-vectors-v1.bin"]
        for name in unrelatedNames { try Data(name.utf8).write(to: cache.directory.appendingPathComponent(name)) }
        try cache.save(groups: [], candidateCount: 2, staleCount: 0, unindexedCount: 0,
                       key: key(input), authorized: input, indexed: input)
        XCTAssertTrue(try restored(cache.read(key: key(input), authorized: input, indexed: input)).groups.isEmpty)
        for name in unrelatedNames { XCTAssertEqual(try Data(contentsOf: cache.directory.appendingPathComponent(name)), Data(name.utf8)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).count, unrelatedNames.count + 1)
    }

    func testSavedDirectoryAndCacheAreBackupExcludedAndDeviceProtectedWithoutSimulatorSkip() throws {
        let root = try directory().appendingPathComponent("new-index-folder", isDirectory: true)
        let cache = SimilarGroupingCache(directory: root)
        try savePair(cache)
        for url in [root, cache.fileURL] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            #if !targetEnvironment(simulator)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
            #endif
        }
    }
}