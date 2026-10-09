import Accelerate
import Darwin
import Foundation
import ImageIO
import ImageIQCore
import SQLite3
import XCTest
@testable import LocalImageIQ

final class SimilarGroupingOptimizationTests: XCTestCase {
    func testEverySliderTickAndAdjacentFloatBoundariesMatchLegacyBits() async throws {
        for tick in 50...99 {
            let threshold = Float(tick) / 100
            for similarity in [threshold.nextDown, threshold, threshold.nextUp] {
                let input = [GroupingOptimizationFixtures.photo("b", vector: GroupingOptimizationFixtures.pairVector(similarity)),
                             GroupingOptimizationFixtures.photo("a")]
                let reference = try await GroupingLegacyReference.run(photos: input, threshold: threshold)
                let actual = try await SimilarPhotoGrouper.group(photos: input, threshold: threshold)
                assertGroupingBits(actual, reference.groups)
                let prepared = try SimilarGroupingPreparedInput(photos: input)
                for boundary in [threshold.nextDown, threshold, threshold.nextUp]
                    where SimilarPhotoGroupingPolicy.thresholdRange.contains(boundary) {
                    let expected = try await GroupingLegacyReference.run(photos: input, threshold: boundary)
                    let warm = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: boundary)
                    assertGroupingBits(warm.groups, expected.groups)
                }
            }
        }
    }

    func testDense768TiesNormToleranceChainsAndPermutationsMatchAllThresholds() async throws {
        let dense = GroupingOptimizationFixtures.denseClustered(count: 24)
        let tie = dense[0].imageEmbedding
        let input = dense + [GroupingOptimizationFixtures.photo("tie-a", vector: tie),
                             GroupingOptimizationFixtures.photo("tie-b", vector: tie),
                             GroupingOptimizationFixtures.photo("scaled", vector: tie.map { $0 * 1.000001 })]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(input)
        for permutation in [input, Array(input.reversed()), Array(input[7...]) + Array(input[..<7])] {
            let prepared = try SimilarGroupingPreparedInput(photos: permutation)
            for tick in 50...99 {
                let threshold = Float(tick) / 100
                let expected = try await GroupingLegacyReference.run(photos: permutation, threshold: threshold)
                let actual = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: threshold)
                assertGroupingBits(actual.groups, expected.groups)
                XCTAssertEqual(actual.metrics.seedScoreCount, expected.metrics.seedScoreCount)
                XCTAssertEqual(actual.metrics.memberScoreCount, expected.metrics.memberScoreCount)
                XCTAssertLessThanOrEqual(actual.metrics.sortCandidateCount, expected.metrics.sortCandidateCount)
            }
        }
        XCTAssertEqual(try encoder.encode(input), before)
        // Equal seed scores, but the candidates fail one another: ID ordering
        // still decides admission (not connected components or seed-only links).
        var mirrored = GroupingOptimizationFixtures.pairVector(0.8)
        mirrored[1] = -mirrored[1]
        let chain = [GroupingOptimizationFixtures.photo("c", vector: mirrored),
                     GroupingOptimizationFixtures.photo("b", vector: GroupingOptimizationFixtures.pairVector(0.8)),
                     GroupingOptimizationFixtures.photo("a")]
        let result = try await SimilarPhotoGrouper.group(photos: chain, threshold: 0.75)
        XCTAssertEqual(result.map { $0.photos.map(\.id) }, [["a", "b"]])
    }

    func testNativeMmulVersusSdotBoundariesKeepRankingSeparateFromAdmission() async throws {
        // Both real Accelerate kernels, with dense, nonuniform Float values.
        // Kernel reduction order is architecture-dependent: report observed
        // differences, never fake a gap or require a particular CPU's rounding.
        let input = GroupingOptimizationFixtures.denseClustered(count: 16)
        let prepared = try SimilarGroupingPreparedInput(photos: input)
        var ranking = [Float](repeating: 0, count: input.count)
        var boundaries = Set<UInt32>()
        var differences = 0
        prepared.matrix.withUnsafeBufferPointer { buffer in
            for seed in prepared.photos.indices {
                ranking.withUnsafeMutableBufferPointer { output in
                    vDSP_mmul(buffer.baseAddress!, 1, buffer.baseAddress! + seed * 768, 1,
                              output.baseAddress!, 1, vDSP_Length(input.count), 1, 768)
                }
                for candidate in prepared.photos.indices where candidate != seed {
                    let dot = cblas_sdot(768, buffer.baseAddress! + seed * 768, 1,
                                         buffer.baseAddress! + candidate * 768, 1)
                    let norm = prepared.norms[seed] * prepared.norms[candidate]
                    let exact = GroupingLegacyReference.cosine(dot, norm)
                    let ranked = GroupingLegacyReference.cosine(ranking[candidate], norm)
                    if exact.bitPattern != ranked.bitPattern { differences += 1 }
                    // Testing both sides of every native seed boundary catches
                    // mmul-as-filter and sdot-as-ranking substitutions.
                    for value in [exact.nextDown, exact, exact.nextUp, ranked] {
                        if SimilarPhotoGroupingPolicy.thresholdRange.contains(value) {
                            boundaries.insert(value.bitPattern)
                        }
                    }
                }
            }
        }
        XCTAssertFalse(boundaries.isEmpty)
        for bits in boundaries.sorted() {
            let threshold = Float(bitPattern: bits)
            let expected = try await GroupingLegacyReference.run(photos: input, threshold: threshold)
            let actual = try await SimilarPhotoGrouper.compute(prepared: prepared, threshold: threshold)
            assertGroupingBits(actual.groups, expected.groups)
        }
        let attachment = XCTAttachment(string: "Native mmul/sdot differing pairs: \(differences); exact boundary thresholds: \(boundaries.count). Zero differences means this backend used matching reductions, not evidence of cross-backend equivalence.")
        attachment.name = "similar-grouping-native-rounding-coverage"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSparseRejectsDoNotSortAndDenseSeedScoreIsNeverRecomputed() async throws {
        let sparse = (0..<32).map { GroupingOptimizationFixtures.photo(String($0), vector: TestFixtures.vector(axis: $0)) }
        let expected = try await GroupingLegacyReference.run(photos: sparse, threshold: 0.90)
        let result = try await SimilarPhotoGrouper.compute(prepared: SimilarGroupingPreparedInput(photos: sparse), threshold: 0.90)
        assertGroupingBits(result.groups, expected.groups)
        XCTAssertEqual(result.metrics.matrixMultiplyCount, 32)
        XCTAssertEqual(result.metrics.seedScoreCount, 32 * 31 / 2)
        XCTAssertEqual(result.metrics.memberScoreCount, 0)
        XCTAssertEqual(result.metrics.sortCandidateCount, 0)
        XCTAssertEqual(result.metrics.sortComparisonCount, 0)
        XCTAssertEqual(expected.metrics.sortCandidateCount, 32 * 31 / 2)
        let dense = (0..<12).map { GroupingOptimizationFixtures.photo(String($0)) }
        let all = try await SimilarPhotoGrouper.compute(prepared: SimilarGroupingPreparedInput(photos: dense), threshold: 0.90)
        XCTAssertEqual(all.groups.first?.photos.count, 12)
        XCTAssertEqual(all.metrics.seedScoreCount, 11)
        XCTAssertEqual(all.metrics.memberScoreCount, 10 * 11 / 2)
        XCTAssertEqual(all.metrics.sortCandidateCount, 11)
    }

    func testPreparationRetainsSingletonsMetadataAndOriginalFloatBits() throws {
        let vector = GroupingOptimizationFixtures.pairVector(0.8)
        let input = [GroupingOptimizationFixtures.photo("z", vector: vector), GroupingOptimizationFixtures.photo("a")]
        let prepared = try SimilarGroupingPreparedInput(photos: input)
        XCTAssertEqual(prepared.photos.map(\.id), ["a", "z"])
        XCTAssertEqual(prepared.matrix.map(\.bitPattern), (input[1].imageEmbedding + vector).map(\.bitPattern))
        XCTAssertEqual(prepared.norms[1].bitPattern,
                       vector.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot().bitPattern)
        XCTAssertThrowsError(try SimilarGroupingPreparedInput(photos: [input[0], input[0]]))
        for vector in [[Float](), [Float](repeating: 0, count: 768), [Float](repeating: .nan, count: 768)] {
            XCTAssertThrowsError(try SimilarGroupingPreparedInput(photos: [GroupingOptimizationFixtures.photo("bad", vector: vector)]))
        }
    }

    func testPreparedKeyIncludesCompleteScopeExactBitsAuthModelPolicyAlgorithmAndPayload() throws {
        let a = PhotoRevision(id: "a", modificationTime: 123, creationTime: 100)
        let unindexed = PhotoRevision(id: "unindexed", modificationTime: 0, creationTime: nil)
        let scope = ["a": a, "unindexed": unindexed]
        let bytes = Data(repeating: 1, count: 32)
        func key(_ values: [String: PhotoRevision]? = nil, _ signature: Data? = nil,
                 model: String = "model", auth: Int? = 3,
                 policy: String = IndexImagePolicy.version,
                 algorithm: String = SimilarPhotoGroupingPolicy.algorithmVersion) throws -> SimilarGroupingPreparedKey {
            try SimilarGroupingPreparedKey(authorized: values ?? scope, imagePayloadSignature: signature ?? bytes,
                modelVersion: model, authorization: auth, algorithmVersion: algorithm, policyVersion: policy)
        }
        let original = try key()
        XCTAssertEqual(try key(["unindexed": unindexed, "a": a]), original)
        XCTAssertNotEqual(try key(["a": a]), original)
        XCTAssertNotEqual(try key(["a": a, "unindexed": .init(id: "unindexed", modificationTime: -0.0, creationTime: nil)]), original)
        XCTAssertNotEqual(try key(["a": a, "unindexed": .init(id: "unindexed", modificationTime: 0, creationTime: 0)]), original)
        XCTAssertNotEqual(try key(scope, Data(repeating: 2, count: 32)), original)
        XCTAssertNotEqual(try key(model: "new-model"), original)
        XCTAssertNotEqual(try key(auth: 4), original)
        XCTAssertNotEqual(try key(auth: nil), original)
        XCTAssertNotEqual(try key(policy: "new-policy"), original)
        XCTAssertNotEqual(try key(algorithm: "new-algorithm"), original)
    }

    func testWarmDifferentThresholdIncludesFormerSingletonsAndKeepsThreeFullSnapshots() async throws {
        let f = try fixture(photos: [GroupingOptimizationFixtures.photo("a"),
            GroupingOptimizationFixtures.photo("b", vector: GroupingOptimizationFixtures.pairVector(0.8)),
            GroupingOptimizationFixtures.photo("single", vector: TestFixtures.vector(axis: 4))])
        let sourceBytes = try Data(contentsOf: f.sourceURL)
        let first = try await f.service.group(threshold: 0.90) { _ in }
        XCTAssertTrue(first.groups.isEmpty)
        f.library.update { $0.generation = 1 } // Irrelevant notification: new authority, same data.
        XCTAssertThrowsError(try first.validatePublicationEpoch())
        let progress = GroupingOptimizationLog<SimilarPhotoGroupingProgress>()
        let warm = try await f.service.group(threshold: 0.75) { progress.append($0) }
        let expected = try await GroupingLegacyReference.run(photos: f.photos, threshold: 0.75)
        assertGroupingBits(warm.groups, expected.groups)
        XCTAssertEqual(warm.groups.map { $0.photos.map(\.id) }, [["a", "b"]])
        XCTAssertEqual(warm.candidateCount, 3)
        XCTAssertEqual(warm.staleCount, 0)
        XCTAssertEqual(warm.unindexedCount, 0)
        XCTAssertEqual(progress.values.last, .init(total: 3, completed: 3, groupCount: 1))
        XCTAssertEqual(f.library.snapshot.enumerations, 6)
        let metrics = f.metrics.values
        XCTAssertEqual(metrics.map(\.preparationCount), [1, 0])
        XCTAssertEqual(metrics.map(\.decodedRowCount), [3, 0])
        XCTAssertEqual(metrics.map(\.preparedInputReuseCount), [0, 1])
        XCTAssertEqual(metrics.map(\.sourceSnapshotCount), [3, 3])
        try await warm.prepareForPublication()
        try warm.validatePublicationEpoch()
        XCTAssertThrowsError(try warm.validatePhotos(["single"]))
        XCTAssertEqual(try Data(contentsOf: f.sourceURL), sourceBytes)
    }

    func testWarmSameRevisionPayloadRewriteForcesDecodeAndNewExactResult() async throws {
        let f = try fixture()
        let first = try await f.service.group(threshold: 0.90) { _ in }
        let changed = GroupingOptimizationFixtures.photo("b", vector: TestFixtures.vector(axis: 1))
        try f.write([changed]) // Same ID, model, modification and creation times.
        XCTAssertThrowsError(try first.validatePublicationEpoch())
        let second = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertTrue(second.groups.isEmpty)
        XCTAssertEqual(second.candidateCount, 2)
        XCTAssertEqual(f.metrics.values.map(\.preparationCount), [1, 1])
        XCTAssertEqual(f.metrics.values.map(\.decodedRowCount), [2, 2])
        XCTAssertEqual(f.metrics.values.map(\.preparedInputReuseCount), [0, 0])
    }

    func testThresholdOnlyRestoreMissKeepsPreparedInputButDiskRestoreCannotSupplySingletons() async throws {
        let f = try fixture(photos: [GroupingOptimizationFixtures.photo("a"),
            GroupingOptimizationFixtures.photo("b", vector: GroupingOptimizationFixtures.pairVector(0.8)),
            GroupingOptimizationFixtures.photo("single", vector: TestFixtures.vector(axis: 4))])
        _ = try await f.service.group(threshold: 0.90) { _ in }
        guard case .stale = try await f.service.restore(threshold: 0.75) else {
            return XCTFail("Different-threshold completed results are stale, even though prepared inputs remain reusable")
        }
        let warm = try await f.service.group(threshold: 0.75) { _ in }
        XCTAssertEqual(warm.groups.map { $0.photos.map(\.id) }, [["a", "b"]])
        XCTAssertEqual(f.metrics.values.map(\.preparationCount), [1, 0])
        XCTAssertEqual(f.metrics.values.last?.preparedInputReuseCount, 1)
        XCTAssertEqual(f.library.snapshot.enumerations, 8, "Group 3 + restore 2 + warm group 3")

        let observations = GroupingOptimizationLog<SimilarGroupingWorkMetrics>()
        let coldService = SimilarPhotoGroupingService(library: f.library, directory: f.directory, encoders: f.encoders,
                                                      reportMetrics: { observations.append($0) })
        guard case .restored(let saved) = try await coldService.restore(threshold: 0.75) else {
            return XCTFail("Expected disk-only completed result restore")
        }
        XCTAssertEqual(saved.candidateCount, 3)
        let regrouped = try await coldService.group(threshold: 0.90) { _ in }
        XCTAssertEqual(regrouped.candidateCount, 3)
        XCTAssertTrue(regrouped.groups.isEmpty)
        XCTAssertEqual(observations.values.last?.preparationCount, 1)
        XCTAssertEqual(observations.values.last?.decodedRowCount, 3)
        XCTAssertEqual(observations.values.last?.preparedInputReuseCount, 0)
    }

    func testOptionalPersistenceFailureDoesNotDiscardValidCompletePreparation() async throws {
        let f = try fixture(commit: { _ in throw AppFailure.storage("Synthetic cache write failure") })
        let cold = try await f.service.group(threshold: 0.90) { _ in }
        let warm = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertNotNil(cold.persistenceIssue)
        XCTAssertNotNil(warm.persistenceIssue)
        XCTAssertEqual(f.metrics.values.map(\.preparationCount), [1, 0])
        XCTAssertEqual(f.metrics.values.map(\.decodedRowCount), [2, 0])
        XCTAssertEqual(f.metrics.values.map(\.sourceSnapshotCount), [3, 3])
        try await warm.prepareForPublication()
        try warm.validatePublicationEpoch()
    }

    func testMalformedSameRevisionBlobCannotHideBehindPreparedValidation() async throws {
        let f = try fixture()
        _ = try await f.service.group(threshold: 0.90) { _ in }
        try GroupingOptimizationFixtures.writeMalformedB(f.directory)
        do { _ = try await f.service.group(threshold: 0.80) { _ in }; XCTFail("Malformed current vector must be decoded and rejected") }
        catch { }
        XCTAssertEqual(f.metrics.values.count, 1)
        try f.write([GroupingOptimizationFixtures.photo("b")])
        _ = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertEqual(f.metrics.values.last?.preparationCount, 1)
        XCTAssertEqual(f.metrics.values.last?.decodedRowCount, 2)
    }

    func testWarmNilGenerationZeroGroupPublicationChecksUnindexedAndSingletonRevisions() async throws {
        for changedID in ["single", "unindexed"] {
            let f = try fixture(photos: [GroupingOptimizationFixtures.photo("single")])
            f.library.update {
                $0.generation = nil
                $0.revisions.append(.init(id: "unindexed", modificationTime: 123, creationTime: 100))
            }
            _ = try await f.service.group(threshold: 0.90) { _ in }
            let warm = try await f.service.group(threshold: 0.80) { _ in }
            XCTAssertTrue(warm.groups.isEmpty)
            XCTAssertEqual(f.metrics.values.last?.preparedInputReuseCount, 1)
            f.library.update { state in
                state.revisions = state.revisions.map {
                    $0.id == changedID ? .init(id: $0.id, modificationTime: 123, creationTime: nil) : $0
                }
            }
            do { try await warm.prepareForPublication(); XCTFail("Empty groups still require full-scope publication validation") }
            catch { }
            XCTAssertEqual(f.library.snapshot.enumerations, 7)
        }
    }

    func testAuthScopeSingletonAndUnindexedMetadataChangesInvalidateWarmPreparation() async throws {
        for change in 0..<6 {
            let photos = [GroupingOptimizationFixtures.photo("a"), GroupingOptimizationFixtures.photo("b"),
                          GroupingOptimizationFixtures.photo("single", vector: TestFixtures.vector(axis: 3))]
            let f = try fixture(photos: photos)
            f.library.update { $0.revisions.append(.init(id: "unindexed", modificationTime: 1, creationTime: nil)) }
            _ = try await f.service.group(threshold: 0.90) { _ in }
            f.library.update { state in
                switch change {
                case 0: state.authorization = 4
                case 1: state.authorization = nil
                case 2: state.revisions[2] = .init(id: "single", modificationTime: 124, creationTime: 100)
                case 3: state.revisions[2] = .init(id: "single", modificationTime: 123, creationTime: nil)
                case 4: state.revisions[3] = .init(id: "unindexed", modificationTime: 1, creationTime: 50)
                default: state.revisions[2] = .init(id: "same-count-new-scope", modificationTime: 123, creationTime: 100)
                }
            }
            let result = try await f.service.group(threshold: 0.80) { _ in }
            XCTAssertEqual(f.metrics.values.map(\.preparationCount), [1, 1])
            XCTAssertEqual(f.metrics.values.map(\.preparedInputReuseCount), [0, 0])
            XCTAssertEqual(result.candidateCount, change == 2 || change == 3 || change == 5 ? 2 : 3)
            XCTAssertEqual(result.staleCount, change == 2 || change == 3 ? 1 : 0)
            XCTAssertEqual(result.unindexedCount, change == 5 ? 2 : 1)
        }
    }

    func testModelChangeAndObservedRestoreMismatchClearPreparedDataConservatively() async throws {
        let f = try fixture()
        _ = try await f.service.group(threshold: 0.90) { _ in }
        await f.encoders.setModel("changed-model")
        let changed = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertEqual(changed.candidateCount, 0)
        XCTAssertEqual(changed.unindexedCount, 2)
        await f.encoders.setModel("test-model")
        _ = try await f.service.group(threshold: 0.90) { _ in }
        f.library.update { $0.authorization = 4 }
        guard case .stale = try await f.service.restore(threshold: 0.90) else { return XCTFail("Expected stale auth identity") }
        f.library.update { $0.authorization = 3 }
        _ = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertEqual(f.metrics.values.map(\.preparationCount), [1, 1, 1, 1])
    }

    func testWarmReadRetainsPreAndPostPhotosSnapshotsWithNilGeneration() async throws {
        for enumeration in [5, 6] { // First group 1...3, warm group 4...6.
            let f = try fixture()
            f.library.update { $0.generation = nil }
            _ = try await f.service.group(threshold: 0.90) { _ in }
            f.library.update { state in
                state.onEnumeration = { number in
                    if number == enumeration {
                        f.library.update { $0.revisions.append(.init(id: "new", modificationTime: 1, creationTime: nil)) }
                    }
                }
            }
            defer { f.library.update { $0.onEnumeration = nil } }
            do { _ = try await f.service.group(threshold: 0.80) { _ in }; XCTFail("Changed full scope must fail") }
            catch let error as SimilarCleanupDiagnostic { XCTAssertEqual(error.code, .photoAccessChanged) }
            XCTAssertEqual(f.metrics.values.count, 1, "Failed warm operation must not report success")
            f.library.update { $0.onEnumeration = nil }
            _ = try await f.service.group(threshold: 0.80) { _ in }
            XCTAssertEqual(f.metrics.values.last?.preparationCount, 1)
        }
    }

    func testWarmSourceRewriteAtPreComputePostComputeAndCommitIsFatal() async throws {
        for phase in 0..<3 {
            let action = GroupingOptimizationOnce()
            let f = try fixture(commit: { directory in
                if phase == 2, action.take() {
                    try GroupingOptimizationFixtures.writeChangedB(directory)
                }
            })
            _ = try await f.service.group(threshold: 0.90) { _ in }
            action.arm()
            if phase < 2 {
                f.library.update { state in
                    state.onEnumeration = { number in
                        if number == (phase == 0 ? 5 : 6), action.take() {
                            try GroupingOptimizationFixtures.writeChangedB(f.directory)
                        }
                    }
                }
            }
            defer { f.library.update { $0.onEnumeration = nil } }
            do { _ = try await f.service.group(threshold: 0.80) { _ in }; XCTFail("Source changes are fatal, not persistence warnings") }
            catch let error as SimilarCleanupDiagnostic { XCTAssertTrue(error.isSourceFailure) }
            XCTAssertEqual(f.metrics.values.count, 1)
            f.library.update { $0.onEnumeration = nil }
            let fresh = try await f.service.group(threshold: 0.80) { _ in }
            XCTAssertTrue(fresh.groups.isEmpty)
            XCTAssertEqual(f.metrics.values.last?.preparationCount, 1)
            XCTAssertEqual(f.metrics.values.last?.decodedRowCount, 2)
        }
    }

    func testWarmCancellationDoesNotInstallPreparedDataAndFreshPublicationChecksSource() async throws {
        let f = try fixture()
        _ = try await f.service.group(threshold: 0.90) { _ in }
        let task = Task {
            try await f.service.group(threshold: 0.80) { state in
                if state.completed == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled warm computation returned") }
        catch is CancellationError { }
        XCTAssertEqual(f.metrics.values.count, 1)
        _ = try await f.service.group(threshold: 0.80) { _ in }
        XCTAssertEqual(f.metrics.values.last?.preparationCount, 1)
        let warm = try await f.service.group(threshold: 0.75) { _ in }
        XCTAssertEqual(f.metrics.values.last?.preparedInputReuseCount, 1)
        try await warm.prepareForPublication()
        try GroupingOptimizationFixtures.writeChangedB(f.directory)
        XCTAssertThrowsError(try warm.validatePublicationEpoch())
        XCTAssertThrowsError(try warm.validatePhotos(["a"]))
    }

    private func fixture(photos: [IndexedPhoto]? = nil,
                         commit: (@Sendable (URL) throws -> Void)? = nil) throws -> GroupingOptimizationServiceFixture {
        let fixture = try GroupingOptimizationServiceFixture(photos: photos, commit: commit)
        let directory = fixture.directory
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return fixture
    }
}

// Shared ONLY by these optimization/observational benchmark tests. This is the
// original greedy loop, including sorting ALL unassigned candidates BEFORE the
// exact seed check. Do not delegate preparation/scoring to optimized production.
enum GroupingLegacyReference {
    struct Input {
        let photos: [IndexedPhoto]
        let matrix: [Float]
        let norms: [Double]
        init(_ photos: [IndexedPhoto]) throws {
            let ordered = try photos.sorted { try Task.checkCancellation(); return $0.id < $1.id }
            var matrix: [Float] = []
            matrix.reserveCapacity(ordered.count * 768)
            var norms: [Double] = []
            norms.reserveCapacity(ordered.count)
            var previousID: String?
            for photo in ordered {
                try Task.checkCancellation()
                guard !photo.id.isEmpty, photo.id != previousID,
                      photo.modificationTime.isFinite, photo.creationTime?.isFinite != false else {
                    throw AppFailure.modelContract("Invalid or duplicate similarity candidate metadata.")
                }
                previousID = photo.id
                try EmbeddingValidation.validateUnit(photo.imageEmbedding, dimension: 768)
                norms.append(photo.imageEmbedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot())
                matrix.append(contentsOf: photo.imageEmbedding)
            }
            self.photos = ordered
            self.matrix = matrix
            self.norms = norms
        }
    }

    static func cosine(_ dot: Float, _ normProduct: Double) -> Float {
        min(1, max(-1, Float(Double(dot) / normProduct)))
    }

    static func run(photos: [IndexedPhoto], threshold: Float) async throws -> SimilarGroupingComputation {
        try await run(input: Input(photos), threshold: threshold)
    }

    static func run(input: Input, threshold: Float,
                    progress: @escaping @Sendable (SimilarPhotoGroupingProgress) async -> Void = { _ in }) async throws -> SimilarGroupingComputation {
        try Task.checkCancellation()
        try SimilarPhotoGroupingPolicy.validate(threshold: threshold)
        let ordered = input.photos, matrix = input.matrix, norms = input.norms
        var state = SimilarPhotoGroupingProgress(total: ordered.count)
        await progress(state)
        var metrics = SimilarGroupingComputationMetrics()
        var assigned = [Bool](repeating: false, count: ordered.count)
        var scores = [Float](repeating: 0, count: ordered.count)
        var groups: [SimilarPhotoGroup] = []
        for seed in ordered.indices {
            try Task.checkCancellation()
            guard !assigned[seed] else { continue }
            matrix.withUnsafeBufferPointer { buffer in
                scores.withUnsafeMutableBufferPointer { output in
                    vDSP_mmul(buffer.baseAddress!, 1, buffer.baseAddress! + seed * 768, 1,
                              output.baseAddress!, 1, vDSP_Length(ordered.count), 1, 768)
                }
            }
            metrics.matrixMultiplyCount += 1
            try Task.checkCancellation()
            var candidates: [Int] = []
            for index in ordered.indices {
                try Task.checkCancellation()
                guard index != seed, !assigned[index] else { continue }
                scores[index] = cosine(scores[index], norms[seed] * norms[index])
                candidates.append(index)
            }
            metrics.sortCandidateCount += candidates.count
            try candidates.sort {
                try Task.checkCancellation()
                metrics.sortComparisonCount += 1
                return scores[$0] == scores[$1] ? ordered[$0].id < ordered[$1].id : scores[$0] > scores[$1]
            }
            assigned[seed] = true
            state.completed += 1
            var members = [seed]
            var minimum: Float = 1
            for candidate in candidates {
                try Task.checkCancellation()
                var candidateMinimum: Float = 1
                let accepted = try matrix.withUnsafeBufferPointer { buffer -> Bool in
                    for member in members {
                        try Task.checkCancellation()
                        let dot = cblas_sdot(768, buffer.baseAddress! + member * 768, 1,
                                             buffer.baseAddress! + candidate * 768, 1)
                        if member == seed { metrics.seedScoreCount += 1 } else { metrics.memberScoreCount += 1 }
                        let similarity = cosine(dot, norms[member] * norms[candidate])
                        guard similarity >= threshold else { return false }
                        candidateMinimum = min(candidateMinimum, similarity)
                    }
                    return true
                }
                if accepted {
                    members.append(candidate)
                    assigned[candidate] = true
                    state.completed += 1
                    minimum = min(minimum, candidateMinimum)
                }
            }
            if members.count >= 2 {
                groups.append(.init(id: ordered[seed].id, photos: members.map { ordered[$0] }, minimumSimilarity: minimum))
                state.groupCount += 1
            }
            try Task.checkCancellation()
            await progress(state)
            try Task.checkCancellation()
        }
        try groups.sort {
            try Task.checkCancellation()
            return $0.photos.count == $1.photos.count ? $0.id < $1.id : $0.photos.count > $1.photos.count
        }
        return SimilarGroupingComputation(groups: groups, metrics: metrics)
    }
}

func assertGroupingBits(_ actual: [SimilarPhotoGroup], _ expected: [SimilarPhotoGroup],
                        file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.map(\.id), expected.map(\.id), file: file, line: line)
    XCTAssertEqual(actual.map { $0.minimumSimilarity.bitPattern }, expected.map { $0.minimumSimilarity.bitPattern }, file: file, line: line)
    XCTAssertEqual(actual.map { $0.photos.map(\.id) }, expected.map { $0.photos.map(\.id) }, file: file, line: line)
    for (group, original) in zip(actual, expected) {
        for (photo, old) in zip(group.photos, original.photos) {
            XCTAssertEqual(photo.imageEmbedding.map(\.bitPattern), old.imageEmbedding.map(\.bitPattern), file: file, line: line)
            XCTAssertEqual(photo.modificationTime.bitPattern, old.modificationTime.bitPattern, file: file, line: line)
            XCTAssertEqual(photo.creationTime?.bitPattern, old.creationTime?.bitPattern, file: file, line: line)
            XCTAssertEqual(photo.modelVersion, old.modelVersion, file: file, line: line)
        }
    }
}

enum GroupingOptimizationFixtures {
    static let model = IndexImagePolicy.cacheVersion(modelVersion: "test-model")
    static func photo(_ id: String, vector: [Float] = TestFixtures.vector()) -> IndexedPhoto {
        IndexedPhoto(id: id, modificationTime: 123, modelVersion: model,
                     imageEmbedding: vector, location: nil, creationTime: 100)
    }
    static func pairVector(_ cosine: Float) -> [Float] {
        var vector = TestFixtures.vector()
        vector[0] = cosine
        vector[1] = (1 - cosine * cosine).squareRoot()
        return vector
    }
    static func unit(_ values: [Float]) -> [Float] {
        let norm = values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
        return values.map { Float(Double($0) / norm) }
    }
    static func denseClustered(count: Int) -> [IndexedPhoto] {
        var generator = Generator()
        let centers = (0..<4).map { _ in unit((0..<768).map { _ in generator.next() }) }
        var result: [IndexedPhoto] = []
        for row in 0..<count {
            let center = centers[row % centers.count]
            let noise = unit((0..<768).map { _ in generator.next() })
            let angle = Double(row / centers.count % 6) * 0.14
            let vector = unit(zip(center, noise).map { Float(cos(angle)) * $0.0 + Float(sin(angle)) * $0.1 })
            result.append(photo(String(format: "dense-%05d", row), vector: vector))
        }
        return result
    }
    struct Generator {
        var state: UInt64 = 0x1234abcd5678ef90
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int((state >> 32) & 65535) - 32768) / 32768
        }
    }
    static func writeChangedB(_ directory: URL) throws {
        try TestFixtures.seedRawCache([CachedPhoto(photo: photo("b", vector: TestFixtures.vector(axis: 1)), geographyVersion: "unused")], directory: directory)
    }
    static func writeMalformedB(_ directory: URL) throws {
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                     &pointer, SQLITE_OPEN_READWRITE, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        guard status == SQLITE_OK, let pointer,
              sqlite3_exec(pointer, "UPDATE photos SET image_embedding = X'FF' WHERE id = 'b'", nil, nil, nil) == SQLITE_OK else {
            throw AppFailure.storage("Could not mutate exclusively owned synthetic BLOB fixture")
        }
    }
}

struct GroupingOptimizationServiceFixture: Sendable {
    let directory: URL
    let photos: [IndexedPhoto]
    let library: GroupingOptimizationLibrary
    let encoders: GroupingOptimizationEncoders
    let metrics: GroupingOptimizationLog<SimilarGroupingWorkMetrics>
    let service: SimilarPhotoGroupingService
    var sourceURL: URL { directory.appendingPathComponent("index.sqlite3") }
    init(photos: [IndexedPhoto]? = nil, commit: (@Sendable (URL) throws -> Void)? = nil) throws {
        let raw = try TestFixtures.temporaryDirectory()
        let pointer = try XCTUnwrap(raw.path.withCString { Darwin.realpath($0, nil) })
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        let input = photos ?? [GroupingOptimizationFixtures.photo("a"), GroupingOptimizationFixtures.photo("b")]
        try TestFixtures.seedRawCache(input.map { CachedPhoto(photo: $0, geographyVersion: "unused") }, directory: root)
        let library = GroupingOptimizationLibrary(input.map { PhotoRevision(id: $0.id, modificationTime: $0.modificationTime, creationTime: $0.creationTime) })
        let encoders = GroupingOptimizationEncoders()
        let metrics = GroupingOptimizationLog<SimilarGroupingWorkMetrics>()
        self.directory = root
        self.photos = input
        self.library = library
        self.encoders = encoders
        self.metrics = metrics
        self.service = SimilarPhotoGroupingService(library: library, directory: root, encoders: encoders,
            cache: SimilarGroupingCache(directory: root, beforeCommit: { try commit?(root) }),
            reportMetrics: { metrics.append($0) })
    }
    func write(_ photos: [IndexedPhoto]) throws {
        try TestFixtures.seedRawCache(photos.map { CachedPhoto(photo: $0, geographyVersion: "unused") }, directory: directory)
    }
}

final class GroupingOptimizationLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return entries }
    func append(_ value: Value) { lock.lock(); defer { lock.unlock() }; entries.append(value) }
}

private final class GroupingOptimizationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = armed; armed = false; return value }
}

final class GroupingOptimizationLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    struct State {
        var revisions: [PhotoRevision]
        var authorization: Int? = 3
        var generation: UInt64? = 0
        var readable = true
        var enumerations = 0
        var onEnumeration: (@Sendable (Int) throws -> Void)?
    }
    private let lock = NSLock()
    private var state: State
    init(_ revisions: [PhotoRevision]) { state = State(revisions: revisions) }
    var snapshot: State { lock.lock(); defer { lock.unlock() }; return state }
    func update(_ body: (inout State) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    var canReadImages: Bool { snapshot.readable }
    var authorizationStatusRawValue: Int? { snapshot.authorization }
    var changeGeneration: UInt64? { snapshot.generation }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        update { $0.enumerations += 1 }
        let current = snapshot
        try current.onEnumeration?(current.enumerations)
        return snapshot.revisions
    }
    func currentRevision(id: String) -> PhotoRevision? { snapshot.revisions.first { $0.id == id } }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { XCTFail("No place reads"); return nil }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        XCTFail("No Photos pixels or network"); throw AppFailure.permission
    }
}

actor GroupingOptimizationEncoders: PhotoEncoding {
    private var model = "test-model"
    func setModel(_ model: String) { self.model = model }
    func inspectResources() throws -> ModelManifest {
        try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.replacingOccurrences(of: "test-model", with: model).utf8))
    }
    private func forbidden() -> AppFailure { XCTFail("No model loading, inference or worker creation"); return .modelContract("Unexpected inference") }
    func prepare() throws -> ModelManifest { throw forbidden() }
    func image(preview: IndexingImage) throws -> [Float] { throw forbidden() }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] { throw forbidden() }
    func text(_ text: String) throws -> [Float] { throw forbidden() }
    func makeIndexingImageEncoders() throws -> [any PhotoImageEncoding] { throw forbidden() }
}