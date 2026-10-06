import Foundation
import ImageIO
import XCTest
import ImageIQCore
@testable import LocalImageIQ

/// Real grouping arithmetic and real SQLite reads; only Photos metadata and the
/// resource inspector are injected. No PhotoKit pixels, models, OCR or network.
final class SimilarPhotoGroupingTests: XCTestCase {
    private let version = IndexImagePolicy.cacheVersion(modelVersion: "test-model")

    private func photo(_ id: String, axis: Int = 0, angle: Double = 0,
                       revision: Double = 123, model: String? = nil,
                       vector: [Float]? = nil, creation: Double? = 100,
                       location: PlaceEmbedding? = nil) -> IndexedPhoto {
        var values = TestFixtures.vector(axis: axis)
        if angle != 0 { values[axis] = Float(cos(angle)); values[axis + 1] = Float(sin(angle)) }
        return IndexedPhoto(id: id, modificationTime: revision, modelVersion: model ?? version,
                            imageEmbedding: vector ?? values, location: location, creationTime: creation)
    }

    private func ids(_ groups: [SimilarPhotoGroup]) -> [[String]] { groups.map { $0.photos.map(\.id) } }

    private func referenceCosine(_ a: IndexedPhoto, _ b: IndexedPhoto) -> Float {
        let x = a.imageEmbedding.map { Double($0) }
        let y = b.imageEmbedding.map { Double($0) }
        let dot = zip(x, y).reduce(0.0) { $0 + $1.0 * $1.1 }
        let norm = (x.reduce(0) { $0 + $1 * $1 } * y.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return min(1, max(-1, Float(dot / norm)))
    }

    private func context(_ accessible: [String], photos: [IndexedPhoto]? = nil,
                         missingDirectory: Bool = false, seed: Bool = true) throws -> GroupingContext {
        let root = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let directory = missingDirectory ? root.appendingPathComponent("not-created", isDirectory: true) : root
        if seed {
            let cached = (photos ?? accessible.map { photo($0) }).map { CachedPhoto(photo: $0, geographyVersion: "unused-places") }
            try TestFixtures.seedRawCache(cached, directory: directory)
        }
        let library = GroupingLibrary(accessible.map { PhotoRevision(id: $0, modificationTime: 123, creationTime: 100) })
        let encoders = try GroupingEncoders()
        let service = SimilarPhotoGroupingService(library: library, directory: directory, encoders: encoders)
        return GroupingContext(service: service, library: library, encoders: encoders, directory: directory)
    }

    private func disk(_ directory: URL) throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    private func failure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure.", file: file, line: line) }
        catch { }
    }

    private func assertMetadataOnly(_ c: GroupingContext, inspections: Int = 1,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let calls = await c.encoders.calls()
        XCTAssertEqual(calls.inspections, inspections, file: file, line: line)
        XCTAssertEqual(calls.forbidden, 0, file: file, line: line)
        XCTAssertEqual(c.library.pixelCalls, 0, file: file, line: line)
        XCTAssertEqual(c.library.placeCalls, 0, file: file, line: line)
    }

    func testPolicyInclusiveEndpointsFiniteValuesAndProgressFraction() throws {
        XCTAssertEqual(SimilarPhotoGroupingPolicy.defaultThreshold, 0.96)
        XCTAssertEqual(SimilarPhotoGroupingPolicy.thresholdRange, Float(0.50)...Float(0.99))
        let valid: [Float] = [0.50, 0.75, 0.90, 0.96, 0.99]
        for value in valid { XCTAssertNoThrow(try SimilarPhotoGroupingPolicy.validate(threshold: value)) }
        let invalid: [Float] = [Float(0.50).nextDown, Float(0.99).nextUp, 0, 1, .nan, .infinity, -.infinity]
        for value in invalid {
            XCTAssertThrowsError(try SimilarPhotoGroupingPolicy.validate(threshold: value)) { error in
                XCTAssertEqual(error.localizedDescription, "相似度设置无效，请重新选择。")
            }
        }
        XCTAssertEqual(SimilarPhotoGroupingProgress().fraction, 1)
        XCTAssertEqual(SimilarPhotoGroupingProgress(total: 8, completed: 3).fraction, 0.375)
        XCTAssertEqual(SimilarPhotoGroupingProgress(total: 8, completed: 8, groupCount: 2).fraction, 1)
        let fixture = SimilarPhotoGroupingResult(groups: [], candidateCount: 0, staleCount: 0, unindexedCount: 0, threshold: 0.96)
        try fixture.validateAccess()
        try fixture.validatePhotos([])
    }

    func testSliderPolicyBoundsAndDefaultThumbPositionMatchThresholds() throws {
        let ticks: ClosedRange<Double> = SimilarPhotoGroupingPolicy.sliderTicks
        XCTAssertEqual(ticks, 50.0...99.0)
        XCTAssertEqual(Float(ticks.lowerBound.rounded()) / 100, SimilarPhotoGroupingPolicy.thresholdRange.lowerBound)
        XCTAssertEqual(Float(ticks.upperBound.rounded()) / 100, SimilarPhotoGroupingPolicy.thresholdRange.upperBound)
        for tick in stride(from: ticks.lowerBound, through: ticks.upperBound, by: 1.0) {
            // Match the real slider binding: round Double ticks, then convert to Float.
            let threshold = Float(tick.rounded()) / 100
            XCTAssertNoThrow(try SimilarPhotoGroupingPolicy.validate(threshold: threshold))
            XCTAssertEqual((Double(threshold) * 100).rounded(), tick)
        }
        let defaultTick = (Double(SimilarPhotoGroupingPolicy.defaultThreshold) * 100).rounded()
        XCTAssertEqual(defaultTick, 96)
        XCTAssertEqual(Float(defaultTick) / 100, SimilarPhotoGroupingPolicy.defaultThreshold)
        let position = (defaultTick - ticks.lowerBound) / (ticks.upperBound - ticks.lowerBound)
        XCTAssertEqual(position, 46.0 / 49.0, accuracy: 0.000000000001)
    }

    func testCosinePointEightIsAbsentAtPointNineAndPresentAtPointSevenFive() async throws {
        let a = photo("a"), b = photo("b", angle: acos(0.8))
        let similarity = referenceCosine(a, b)
        XCTAssertGreaterThan(similarity, 0.75)
        XCTAssertLessThan(similarity, 0.90)
        let strict = try await SimilarPhotoGrouper.group(photos: [b, a], threshold: 0.90)
        XCTAssertTrue(strict.isEmpty)
        let broad = try await SimilarPhotoGrouper.group(photos: [b, a], threshold: 0.75)
        XCTAssertEqual(ids(broad), [["a", "b"]])
        XCTAssertEqual(try XCTUnwrap(broad.first).minimumSimilarity, similarity, accuracy: 0.0000002)
    }

    func testLowestThresholdStillRequiresEveryPairAndRejectsSimilarityChains() async throws {
        let threshold: Float = 0.50
        // Cosine 0.6 leaves a clear margin above the physical Float boundary.
        let angle = acos(0.6)
        let a = photo("a"), b = photo("b", angle: angle), c = photo("c", angle: 2 * angle)
        XCTAssertGreaterThan(referenceCosine(a, b), threshold)
        XCTAssertGreaterThan(referenceCosine(b, c), threshold)
        XCTAssertLessThan(referenceCosine(a, c), threshold)
        // Mirroring c makes both candidates pass the seed but fail each other,
        // so checking only the seed is also insufficient at the lower endpoint.
        let mirroredC = photo("c", angle: -angle)
        XCTAssertGreaterThan(referenceCosine(a, mirroredC), threshold)
        XCTAssertLessThan(referenceCosine(b, mirroredC), threshold)
        for input in [[c, b, a], [mirroredC, b, a]] {
            let groups = try await SimilarPhotoGrouper.group(photos: input, threshold: threshold)
            XCTAssertEqual(ids(groups), [["a", "b"]])
            for group in groups {
                XCTAssertGreaterThanOrEqual(group.minimumSimilarity, threshold)
                for i in group.photos.indices {
                    for j in group.photos.indices where j > i {
                        XCTAssertGreaterThanOrEqual(referenceCosine(group.photos[i], group.photos[j]), threshold)
                    }
                }
            }
        }
    }

    func testStaticGroupingInvalidThresholdUsesGenericChineseMessage() async {
        do {
            _ = try await SimilarPhotoGrouper.group(photos: [], threshold: .nan)
            XCTFail("Expected invalid threshold failure.")
        } catch {
            XCTAssertEqual(error.localizedDescription, "相似度设置无效，请重新选择。")
        }
    }

    func testEmptyAndSingletonHaveNoGroupsAndCompleteTheirActualTotals() async throws {
        let inputs: [[IndexedPhoto]] = [[], [photo("only")]]
        for input in inputs {
            let trace = GroupingProgressTrace()
            let groups = try await SimilarPhotoGrouper.group(photos: input, threshold: 0.96) { await trace.append($0) }
            let states = await trace.values()
            XCTAssertTrue(groups.isEmpty)
            XCTAssertEqual(states.last, SimilarPhotoGroupingProgress(total: input.count, completed: input.count))
            XCTAssertEqual(states.last?.fraction, 1)
        }
    }

    func testSimilarityChainIsNotAConnectedComponent() async throws {
        let a = photo("a"), b = photo("b", angle: 0.2), c = photo("c", angle: 0.4)
        XCTAssertGreaterThanOrEqual(referenceCosine(a, b), 0.96)
        XCTAssertGreaterThanOrEqual(referenceCosine(b, c), 0.96)
        XCTAssertLessThan(referenceCosine(a, c), 0.96)
        let groups = try await SimilarPhotoGrouper.group(photos: [c, b, a], threshold: 0.96)
        XCTAssertEqual(ids(groups), [["a", "b"]])
    }

    func testAdmissionChecksEveryMemberNotJustTheSeed() async throws {
        let a = photo("a"), b = photo("b", angle: 0.2), c = photo("c", angle: -0.2)
        XCTAssertGreaterThan(referenceCosine(a, b), 0.96)
        XCTAssertGreaterThan(referenceCosine(a, c), 0.96)
        XCTAssertLessThan(referenceCosine(b, c), 0.96)
        let groups = try await SimilarPhotoGrouper.group(photos: [c, a, b], threshold: 0.96)
        XCTAssertEqual(ids(groups), [["a", "b"]], "Equal seed similarity must use the opaque ID tie-break.")
    }

    func testGreedyAdmissionVisitsMostSimilarBeforeIDOrder() async throws {
        let groups = try await SimilarPhotoGrouper.group(photos: [photo("a"), photo("b", angle: 0.22),
                                                               photo("c", angle: -0.1)], threshold: 0.96)
        XCTAssertEqual(ids(groups), [["a", "c"]], "Admitting b first would wrongly exclude the closer c.")
    }

    func testGroupsAreDisjointLargestFirstThenStableIDWithoutDateWindows() async throws {
        let input = [photo("a", creation: nil), photo("a2", creation: -9_000_000_000),
                     photo("b", axis: 2), photo("b2", axis: 2), photo("b3", axis: 2),
                     photo("c", axis: 4), photo("c2", axis: 4), photo("singleton", axis: 6)]
        let groups = try await SimilarPhotoGrouper.group(photos: input, threshold: 0.96)
        XCTAssertEqual(ids(groups), [["b", "b2", "b3"], ["a", "a2"], ["c", "c2"]])
        XCTAssertEqual(groups.map(\.id), ["b", "a", "c"])
        let members = groups.flatMap { $0.photos.map(\.id) }
        XCTAssertEqual(members.count, Set(members).count)
        XCTAssertTrue(groups.allSatisfy { $0.photos.count >= 2 })
    }

    func testInputPermutationsAndSimilarityTiesProduceIdenticalGroupsAndMinima() async throws {
        let input = [photo("a"), photo("b", angle: 0.2), photo("c", angle: -0.2),
                     photo("d", axis: 2), photo("e", axis: 2), photo("f", axis: 2)]
        let expected = try await SimilarPhotoGrouper.group(photos: input, threshold: 0.96)
        for offset in input.indices {
            let rotated = Array(input[offset...]) + Array(input[..<offset])
            for permutation in [rotated, Array(rotated.reversed())] {
                let actual = try await SimilarPhotoGrouper.group(photos: permutation, threshold: 0.96)
                XCTAssertEqual(ids(actual), ids(expected))
                XCTAssertEqual(actual.map(\.id), expected.map(\.id))
                XCTAssertEqual(actual.map { $0.minimumSimilarity.bitPattern }, expected.map { $0.minimumSimilarity.bitPattern })
            }
        }
    }

    func testExactThresholdAcceptedButOneFloatBelowRejectedAtAllPolicyBoundaries() async throws {
        let thresholds: [Float] = [0.90, 0.96, 0.99]
        for threshold in thresholds {
            for similarity in [threshold.nextDown, threshold, threshold.nextUp] {
                var vector = TestFixtures.vector()
                vector[0] = similarity
                vector[1] = (1 - similarity * similarity).squareRoot()
                let input = [photo("a"), photo("b", vector: vector)]
                XCTAssertEqual(referenceCosine(input[0], input[1]), similarity)
                let groups = try await SimilarPhotoGrouper.group(photos: input, threshold: threshold)
                if similarity < threshold {
                    XCTAssertTrue(groups.isEmpty, "No threshold epsilon may admit even one Float step below the boundary.")
                } else {
                    XCTAssertEqual(ids(groups), [["a", "b"]])
                    XCTAssertEqual(groups.first?.minimumSimilarity, similarity)
                }
            }
        }
    }

    func testEveryPairMeetsThresholdMinimumIsActualAndOriginalVectorsAreUnchanged() async throws {
        let place = PlaceEmbedding(text: "Unused location", vector: TestFixtures.vector(axis: 7))
        let input = [photo("a", angle: -0.1, location: place), photo("b"), photo("c", angle: 0.12),
                     photo("d", axis: 2), photo("e", axis: 2, angle: 0.1)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(input)
        let groups = try await SimilarPhotoGrouper.group(photos: input, threshold: 0.96)
        XCTAssertEqual(groups.map { $0.photos.count }, [3, 2])
        for group in groups {
            var minimum: Float = 1
            for i in group.photos.indices {
                for j in group.photos.indices where j > i {
                    let similarity = referenceCosine(group.photos[i], group.photos[j])
                    XCTAssertGreaterThanOrEqual(similarity, 0.96)
                    minimum = min(minimum, similarity)
                }
                let original = try XCTUnwrap(input.first { $0.id == group.photos[i].id })
                XCTAssertEqual(group.photos[i].imageEmbedding.map(\.bitPattern), original.imageEmbedding.map(\.bitPattern))
                XCTAssertEqual(group.photos[i].location?.text, original.location?.text)
                XCTAssertEqual(group.photos[i].location?.vector, original.location?.vector)
                XCTAssertEqual(group.photos[i].creationTime, original.creationTime)
            }
            XCTAssertEqual(group.minimumSimilarity, minimum, accuracy: 0.0000002)
        }
        XCTAssertEqual(try encoder.encode(input), before)
    }

    func testMalformedDimensionsNonfiniteNonunitAndDuplicateIDsFailEvenForSingleton() async {
        var nan = TestFixtures.vector(); nan[20] = .nan
        var infinity = TestFixtures.vector(); infinity[20] = .infinity
        var nonunit = TestFixtures.vector(); nonunit[0] = 2
        let vectors: [[Float]] = [[], [1], TestFixtures.vector(dimension: 512),
                                  TestFixtures.vector(dimension: 769), [Float](repeating: 0, count: 768), nan, infinity, nonunit]
        for vector in vectors {
            await failure { _ = try await SimilarPhotoGrouper.group(photos: [photo("a", vector: vector)], threshold: 0.96) }
        }
        await failure { _ = try await SimilarPhotoGrouper.group(photos: [photo("a"), photo("a")], threshold: 0.96) }
        await failure { _ = try await SimilarPhotoGrouper.group(photos: [photo("a", revision: .nan)], threshold: 0.96) }
        await failure { _ = try await SimilarPhotoGrouper.group(photos: [photo("a", creation: .infinity)], threshold: 0.96) }
        await failure { _ = try await SimilarPhotoGrouper.group(photos: [], threshold: .nan) }
    }

    func testCancellationBeforeEntryDoesNotPublishEvenEmptySuccess() async {
        let gate = GroupingGate()
        let trace = GroupingProgressTrace()
        let task = Task {
            await gate.block()
            return try await SimilarPhotoGrouper.group(photos: [], threshold: 0.96) { await trace.append($0) }
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled task returned groups.") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, got \(error).") }
        let states = await trace.values()
        XCTAssertTrue(states.isEmpty)
    }

    func testCancellationDuringInitialMiddleAndFinalProgressNeverReturnsSuccess() async {
        let input = [photo("a"), photo("b"), photo("c", axis: 2)]
        for pauseAt in [0, 2, 3] {
            let gate = GroupingGate()
            let task = Task {
                try await SimilarPhotoGrouper.group(photos: input, threshold: 0.96) { state in
                    if state.completed == pauseAt { await gate.block() }
                }
            }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.release()
            do { _ = try await task.value; XCTFail("Progress await swallowed cancellation.") }
            catch is CancellationError { }
            catch { XCTFail("Expected cancellation, got \(error).") }
        }
    }

    func testServiceInitIsIdleAndMissingDirectoryOrDatabaseIsNeverCreated() async throws {
        for missingDirectory in [false, true] {
            let c = try context(["new"], missingDirectory: missingDirectory, seed: false)
            XCTAssertEqual(c.library.enumerationCount, 0)
            await assertMetadataOnly(c, inspections: 0)
            let before = try disk(c.directory)
            let trace = GroupingProgressTrace()
            let result = try await c.service.group(threshold: 0.96) { await trace.append($0) }
            XCTAssertTrue(result.groups.isEmpty)
            XCTAssertEqual(result.candidateCount, 0)
            XCTAssertEqual(result.staleCount, 0)
            XCTAssertEqual(result.unindexedCount, 1)
            XCTAssertEqual(c.library.enumerationCount, 3)
            XCTAssertEqual(try disk(c.directory), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.appendingPathComponent("index.sqlite3").path))
            if missingDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path)) }
            let states = await trace.values()
            XCTAssertEqual(states, [SimilarPhotoGroupingProgress()])
            try result.validateAccess()
            try result.validatePhotos([])
            XCTAssertThrowsError(try result.validatePhotos(["new"]))
            await assertMetadataOnly(c)
        }
    }

    func testServiceFiltersStaleCorruptVectorsBeforeDecodingAndCountsOnlyAccessibleActiveIndex() async throws {
        let malformedPlace = PlaceEmbedding(text: "Must not decode", vector: [])
        let c = try context(["a", "b", "stale", "old", "new"], photos: [
            photo("a"), photo("b"), photo("stale", revision: 122, vector: [], location: malformedPlace),
            photo("old", model: "old-model", vector: []), photo("hidden", vector: [])
        ])
        // These malformed unrelated files must not even be opened by grouping.
        try Data("not an OCR database".utf8).write(to: c.directory.appendingPathComponent("text-index.sqlite3"))
        try Data("not a place pack".utf8).write(to: c.directory.appendingPathComponent("Places.geojson"))
        let before = try disk(c.directory)
        let result = try await c.service.group(threshold: 0.97) { _ in }
        XCTAssertEqual(ids(result.groups), [["a", "b"]])
        XCTAssertEqual(result.candidateCount, 2)
        XCTAssertEqual(result.staleCount, 1, "Only an accessible active-model row with an old revision is stale.")
        XCTAssertEqual(result.unindexedCount, 2, "Old-model-only and absent rows are unindexed, not stale.")
        XCTAssertEqual(result.candidateCount + result.staleCount + result.unindexedCount, 5)
        XCTAssertEqual(result.threshold, 0.97)
        XCTAssertEqual(c.library.enumerationCount, 3)
        try result.validateAccess()
        XCTAssertEqual(try disk(c.directory), before, "No pruning, migration, sidecars, index or OCR writes.")
        await assertMetadataOnly(c)
    }

    func testFullRevisionReaderIsMetadataOnlyAndPreservesLegacyRevisionAPI() async throws {
        let malformedPlace = PlaceEmbedding(text: "Must not decode", vector: [])
        let c = try context(["dated", "undated", "zero", "old", "new"], photos: [
            photo("dated", revision: 122, vector: [], creation: 101, location: malformedPlace),
            photo("undated", vector: [], creation: nil), photo("zero", vector: [], creation: 0),
            photo("old", model: "old-model", vector: []), photo("hidden", vector: [])
        ])
        let before = try disk(c.directory)
        let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
        let accessible: Set<String> = ["dated", "undated", "zero", "old", "new"]
        let revisions = try await reader.searchPhotoRevisions(modelVersion: version, accessibleIDs: accessible)
        XCTAssertEqual(revisions, [
            "dated": PhotoRevision(id: "dated", modificationTime: 122, creationTime: 101),
            "undated": PhotoRevision(id: "undated", modificationTime: 123, creationTime: nil),
            "zero": PhotoRevision(id: "zero", modificationTime: 123, creationTime: 0)
        ])
        let legacy = try await reader.searchRevisions(modelVersion: version, accessibleIDs: accessible)
        XCTAssertEqual(legacy, ["dated": 122, "undated": 123, "zero": 123])
        let empty = try await reader.searchPhotoRevisions(modelVersion: version, accessibleIDs: [])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try disk(c.directory), before)
        XCTAssertEqual(c.library.enumerationCount, 0)
        await assertMetadataOnly(c, inspections: 0)
    }

    func testFullRevisionReaderRequiresReadOnlyAndNeverCreatesMissingCache() async throws {
        for missingDirectory in [false, true] {
            let c = try context(["a"], missingDirectory: missingDirectory, seed: false)
            let before = try disk(c.directory)
            let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
            let revisions = try await reader.searchPhotoRevisions(modelVersion: version, accessibleIDs: ["a"])
            XCTAssertTrue(revisions.isEmpty)
            let writer = SQLitePhotoStore(directory: c.directory)
            await failure { _ = try await writer.searchPhotoRevisions(modelVersion: version, accessibleIDs: ["a"]) }
            XCTAssertEqual(try disk(c.directory), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.appendingPathComponent("index.sqlite3").path))
            if missingDirectory { XCTAssertFalse(FileManager.default.fileExists(atPath: c.directory.path)) }
            XCTAssertEqual(c.library.enumerationCount, 0)
            await assertMetadataOnly(c, inspections: 0)
        }
    }

    func testCreationOnlyChangesIncludingNilExcludeCorruptVectorsBeforeDecodeWithAccurateCounts() async throws {
        let changes: [(cached: Double?, current: Double?)] = [(100, 101), (nil, 100), (100, nil), (nil, 0), (0, nil)]
        for change in changes {
            let malformedPlace = PlaceEmbedding(text: "Must not decode", vector: [])
            let c = try context(["a", "b", "creation-stale", "modification-stale", "old", "new"], photos: [
                photo("a"), photo("b", creation: nil),
                photo("creation-stale", vector: [], creation: change.cached, location: malformedPlace),
                photo("modification-stale", revision: 122, vector: []),
                photo("old", model: "old-model", vector: []), photo("hidden", vector: [])
            ])
            c.library.setRevision("b", modification: 123, creation: nil)
            c.library.setRevision("creation-stale", modification: 123, creation: change.current)
            let before = try disk(c.directory)
            let reader = SQLitePhotoStore(directory: c.directory, readOnly: true)
            let legacy = try await reader.searchRevisions(modelVersion: version, accessibleIDs: ["creation-stale"])
            let current = try XCTUnwrap(c.library.currentRevision(id: "creation-stale"))
            XCTAssertEqual(legacy["creation-stale"], current.modificationTime, "Modification-only eligibility would wrongly admit this row.")
            let trace = GroupingProgressTrace()
            let result = try await c.service.group(threshold: 0.96) { await trace.append($0) }
            XCTAssertEqual(ids(result.groups), [["a", "b"]])
            XCTAssertEqual(result.candidateCount, 2)
            XCTAssertEqual(result.staleCount, 2, "Both creation-only and modification-only changes are stale.")
            XCTAssertEqual(result.unindexedCount, 2, "Old-model-only and absent rows remain unindexed.")
            XCTAssertEqual(result.candidateCount + result.staleCount + result.unindexedCount, 6)
            let states = await trace.values()
            XCTAssertEqual(states, [SimilarPhotoGroupingProgress(total: 2),
                                    SimilarPhotoGroupingProgress(total: 2, completed: 2, groupCount: 1)])
            for photo in result.groups.flatMap({ $0.photos }) {
                let cached = PhotoRevision(id: photo.id, modificationTime: photo.modificationTime, creationTime: photo.creationTime)
                XCTAssertEqual(cached, c.library.currentRevision(id: photo.id))
            }
            try result.validateAccess()
            try result.validatePhotos(["a", "b"])
            XCTAssertThrowsError(try result.validatePhotos(["creation-stale"]))
            XCTAssertEqual(c.library.enumerationCount, 3)
            XCTAssertEqual(try disk(c.directory), before, "Creation-only stale rows must not trigger decoding or writes.")
            await assertMetadataOnly(c)
        }
    }

    func testServiceStillRejectsMalformedCurrentVectorsWithoutReindexingOrWrites() async throws {
        for vector in [[], TestFixtures.vector(dimension: 512), [Float](repeating: 0, count: 768)] {
            let c = try context(["a"], photos: [photo("a", vector: vector)])
            let before = try disk(c.directory)
            await failure { _ = try await c.service.group(threshold: 0.96) { _ in } }
            XCTAssertEqual(try disk(c.directory), before)
            await assertMetadataOnly(c)
        }
    }

    func testServiceRejectsPermissionAndInvalidThresholdBeforeInspectionOrEnumeration() async throws {
        let c = try context(["a"], seed: false)
        c.library.setReadable(false)
        do { _ = try await c.service.group(threshold: 0.96) { _ in }; XCTFail("Permission must be required.") }
        catch AppFailure.permission { }
        c.library.setReadable(true)
        await failure { _ = try await c.service.group(threshold: Float(0.50).nextDown) { _ in } }
        XCTAssertEqual(c.library.enumerationCount, 0)
        await assertMetadataOnly(c, inspections: 0)
    }

    func testServiceRechecksAuthorizationGenerationAndNilGenerationRevisionAfterInspection() async throws {
        for change in ["permission", "authorization", "generation", "revision"] {
            let c = try context(["a", "b"])
            let library = c.library
            if change == "revision" { library.setGeneration(nil) }
            await c.encoders.onInspection {
                switch change {
                case "permission": library.setReadable(false)
                case "authorization": library.setAuthorization(4)
                case "generation": library.setGeneration(1)
                default: library.setRevision("b", modification: 124)
                }
            }
            let before = try disk(c.directory)
            await failure { _ = try await c.service.group(threshold: 0.96) { _ in } }
            XCTAssertEqual(try disk(c.directory), before)
            XCTAssertEqual(library.enumerationCount, change == "revision" ? 2 : 1)
            await assertMetadataOnly(c)
        }
    }

    func testPrecomputeAndFinalSnapshotsDetectUnindexedEditsWithoutGeneration() async throws {
        for snapshotNumber in [2, 3] {
            let c = try context(["a", "b", "unindexed"], photos: [photo("a"), photo("b")])
            let library = c.library
            library.setGeneration(nil)
            library.onEnumeration { number in
                if number == snapshotNumber { library.setRevision("unindexed", modification: 124) }
            }
            await failure { _ = try await c.service.group(threshold: 0.96) { _ in } }
            XCTAssertEqual(library.enumerationCount, snapshotNumber)
            // Break the test hook's strong reference cycle after the assertion.
            library.onEnumeration(nil)
        }
    }

    func testResultGuardsCheckAllReturnedRevisionsOrOnlySelectedGroupSubsetWithoutGeneration() async throws {
        let c = try context(["a", "b", "c", "d", "single", "new"], photos: [
            photo("a"), photo("b"), photo("c", axis: 2), photo("d", axis: 2), photo("single", axis: 4)
        ])
        c.library.setGeneration(nil)
        let result = try await c.service.group(threshold: 0.96) { _ in }
        try result.validateAccess()
        try result.validatePhotos(["a", "b"])
        for id in ["single", "new", "unknown"] { XCTAssertThrowsError(try result.validatePhotos([id])) }
        c.library.setRevision("c", modification: 124)
        XCTAssertThrowsError(try result.validateAccess())
        XCTAssertNoThrow(try result.validatePhotos(["a", "b"]))
        XCTAssertNoThrow(try result.validatePhotos([]))
        // Creation-time changes are also part of the captured PhotoRevision.
        c.library.setRevision("a", modification: 123, creation: 101)
        XCTAssertThrowsError(try result.validatePhotos(["a"]))
        c.library.remove("b")
        XCTAssertThrowsError(try result.validatePhotos(["b"]))
        XCTAssertEqual(c.library.enumerationCount, 3, "Publication guards use synchronous member revisions, not new full snapshots.")
    }

    func testResultGuardsRecheckEpochBeforeAndAfterSynchronousRevisionReads() async throws {
        for change in ["permission", "authorization", "generation"] {
            for duringRead in [false, true] {
                let c = try context(["a", "b"])
                let result = try await c.service.group(threshold: 0.96) { _ in }
                let library = c.library
                let mutate: @Sendable () -> Void = {
                    switch change {
                    case "permission": library.setReadable(false)
                    case "authorization": library.setAuthorization(4)
                    default: library.setGeneration(1)
                    }
                }
                if duringRead { library.afterRevisionRead(mutate) } else { mutate() }
                XCTAssertThrowsError(try result.validatePhotos(["a"]))
                XCTAssertThrowsError(try result.validateAccess())
                XCTAssertThrowsError(try result.validatePhotos([]))
                library.afterRevisionRead(nil)
            }
        }
    }

    func testServiceCancellationAfterInspectionOrFinalProgressDoesNotPublishOrWrite() async throws {
        for atInspection in [true, false] {
            let c = try context(["a", "b"])
            let before = try disk(c.directory)
            let gate = GroupingGate()
            if atInspection { await c.encoders.onInspection { await gate.block() } }
            let service = c.service
            let task = Task {
                try await service.group(threshold: 0.96) { state in
                    if !atInspection, state.completed == state.total { await gate.block() }
                }
            }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.release()
            do { _ = try await task.value; XCTFail("Cancelled service returned a result.") }
            catch is CancellationError { }
            catch { XCTFail("Expected cancellation, got \(error).") }
            XCTAssertEqual(try disk(c.directory), before)
            await assertMetadataOnly(c)
        }
    }

    func testServiceProgressCountsAssignedMembersAndSingletonsNotOnlySeedIterations() async throws {
        let c = try context(["a", "b", "c", "d", "e", "f", "stale", "new"], photos: [
            photo("a"), photo("b"), photo("c", axis: 2), photo("d", axis: 2),
            photo("e", axis: 2), photo("f", axis: 4), photo("stale", revision: 122)
        ])
        let trace = GroupingProgressTrace()
        let result = try await c.service.group(threshold: 0.96) { await trace.append($0) }
        let states = await trace.values()
        XCTAssertEqual(states.map(\.total), [6, 6, 6, 6])
        XCTAssertEqual(states.map(\.completed), [0, 2, 5, 6])
        XCTAssertEqual(states.map(\.groupCount), [0, 1, 2, 2])
        XCTAssertEqual(states.last?.fraction, 1)
        XCTAssertEqual(result.candidateCount, 6)
        XCTAssertEqual(result.staleCount, 1)
        XCTAssertEqual(result.unindexedCount, 1)
        XCTAssertEqual(ids(result.groups), [["c", "d", "e"], ["a", "b"]])
        await assertMetadataOnly(c)
    }
}

private struct GroupingContext: Sendable {
    let service: SimilarPhotoGroupingService
    let library: GroupingLibrary
    let encoders: GroupingEncoders
    let directory: URL
}

private actor GroupingProgressTrace {
    private var states: [SimilarPhotoGroupingProgress] = []
    func append(_ state: SimilarPhotoGroupingProgress) { states.append(state) }
    func values() -> [SimilarPhotoGroupingProgress] { states }
}

private actor GroupingGate {
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { blocked?.resume(); blocked = nil }
}

private final class GroupingLibrary: PhotoLibraryIndexing, @unchecked Sendable {
    private let lock = NSLock()
    private var revisions: [PhotoRevision]
    private var readable = true
    private var authorization: Int? = 3
    private var generation: UInt64? = 0
    private var enumerations = 0
    private var pixels = 0
    private var places = 0
    private var enumerationAction: (@Sendable (Int) -> Void)?
    private var revisionAction: (@Sendable () -> Void)?

    init(_ revisions: [PhotoRevision]) { self.revisions = revisions }
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
    var canReadImages: Bool { locked { readable } }
    var authorizationStatusRawValue: Int? { locked { authorization } }
    var changeGeneration: UInt64? { locked { generation } }
    var enumerationCount: Int { locked { enumerations } }
    var pixelCalls: Int { locked { pixels } }
    var placeCalls: Int { locked { places } }
    func setReadable(_ value: Bool) { locked { readable = value } }
    func setAuthorization(_ value: Int?) { locked { authorization = value } }
    func setGeneration(_ value: UInt64?) { locked { generation = value } }
    func setRevision(_ id: String, modification: Double, creation: Double? = 100) {
        locked {
            if let index = revisions.firstIndex(where: { $0.id == id }) {
                revisions[index] = PhotoRevision(id: id, modificationTime: modification, creationTime: creation)
            }
        }
    }
    func remove(_ id: String) { locked { revisions.removeAll { $0.id == id } } }
    func onEnumeration(_ action: (@Sendable (Int) -> Void)?) { locked { enumerationAction = action } }
    func afterRevisionRead(_ action: (@Sendable () -> Void)?) { locked { revisionAction = action } }
    func enumerateAuthorizedImages() throws -> [PhotoRevision] {
        let (number, action) = locked { enumerations += 1; return (enumerations, enumerationAction) }
        action?(number)
        return try locked {
            guard readable else { throw AppFailure.permission }
            // Deliberately vary ordering; snapshots compare identities/revisions.
            return number.isMultiple(of: 2) ? Array(revisions.reversed()) : revisions
        }
    }
    func currentRevision(id: String) -> PhotoRevision? {
        let (revision, action) = locked { (readable ? revisions.first { $0.id == id } : nil, revisionAction) }
        action?()
        return revision
    }
    func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? {
        locked { places += 1 }
        XCTFail("Grouping must not resolve geography.")
        return nil
    }
    func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
        locked { pixels += 1 }
        XCTFail("Grouping must never request pixels, even with networking disabled.")
        throw AppFailure.photo("Unexpected pixel request in grouping test.")
    }
}

private actor GroupingEncoders: PhotoEncoding {
    struct Calls: Sendable { var inspections = 0; var forbidden = 0 }
    private let manifest: ModelManifest
    private var count = Calls()
    private var inspectionAction: (@Sendable () async -> Void)?
    init() throws { manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8)) }
    func calls() -> Calls { count }
    func onInspection(_ action: @escaping @Sendable () async -> Void) { inspectionAction = action }
    func inspectResources() async throws -> ModelManifest {
        count.inspections += 1
        await inspectionAction?() // Deliberately allow late success after cancellation.
        return manifest
    }
    private func unexpected() -> AppFailure {
        count.forbidden += 1
        XCTFail("Grouping may inspect metadata only; no prepare, inference, or encoder factory.")
        return .modelContract("Unexpected encoder operation in grouping test.")
    }
    func prepare() throws -> ModelManifest { throw unexpected() }
    func image(preview: IndexingImage) throws -> [Float] { throw unexpected() }
    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] { throw unexpected() }
    func text(_ text: String) throws -> [Float] { throw unexpected() }
    func makeIndexingImageEncoders() throws -> [any PhotoImageEncoding] { throw unexpected() }
}