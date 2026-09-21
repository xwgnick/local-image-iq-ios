import XCTest
import CoreML
import ImageIQCore
@testable import LocalImageIQ

final class ModelBoundaryTests: XCTestCase {
    func testManifestAcceptsContractAndAdditionalProvenance() throws {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        try manifest.validate()
        let roundTrip = try JSONDecoder().decode(ModelManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(manifest, roundTrip)
    }

    func testManifestRejectsWrongDimensionInputNameAndRevision() throws {
        for mutation in [TestFixtures.manifest.replacingOccurrences(of: "\"dimension\":512", with: "\"dimension\":768"),
                         TestFixtures.manifest.replacingOccurrences(of: "pixel_values", with: "wrong_input"),
                         TestFixtures.manifest.replacingOccurrences(of: "327ab6726d33c0e22f920c83f2ff9e4bd38ca37f", with: "wrong-revision")] {
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(mutation.utf8))
            XCTAssertThrowsError(try manifest.validate())
        }
    }

    func testProjectionRequires512FiniteNonzeroValuesAndNormalizesOnce() throws {
        var raw = [Float](repeating: 0, count: 512)
        raw[0] = 3; raw[1] = 4
        let normalized = try EmbeddingValidation.normalizeProjection(raw)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.000001)
        XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection([1]))
        XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection([Float](repeating: 0, count: 512)))
        raw[0] = .nan
        XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection(raw))
    }

    func testCoreTokenizerFeedsInt32IDsAndAttentionMask() throws {
        let tokenizer = try WordPieceTokenizer(vocabulary: ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "Photo", "中"])
        let tokens = tokenizer.encode("Photo 中")
        let ids = try CoreMLEncoders.int32Tensor(tokens.inputIDs)
        let mask = try CoreMLEncoders.int32Tensor(tokens.attentionMask)
        XCTAssertEqual(ids.shape.map(\.intValue), [1, 128])
        XCTAssertEqual(ids.dataType, .int32)
        XCTAssertEqual((0..<5).map { ids[$0].int32Value }, [2, 4, 5, 3, 0])
        XCTAssertEqual((0..<5).map { mask[$0].int32Value }, [1, 1, 1, 1, 0])
        XCTAssertThrowsError(try CoreMLEncoders.int32Tensor([1, 2]))
    }

    func testProjectionFlatteningRespectsStridesAndRejectsWrongOutputType() throws {
        let backing = try MLMultiArray(shape: [1, 1024], dataType: .float32)
        for index in 0..<1024 { backing[index] = NSNumber(value: index.isMultiple(of: 2) ? Float(0) : Float(100)) }
        backing[0] = 3
        backing[2] = 4
        try withExtendedLifetime(backing) {
            let strided = try MLMultiArray(dataPointer: backing.dataPointer, shape: [1, 512], dataType: .float32,
                                           strides: [1024, 2], deallocator: nil)
            let vector = try CoreMLEncoders.normalizedProjection(strided)
            XCTAssertEqual(vector[0], 0.6, accuracy: 0.000001)
            XCTAssertEqual(vector[1], 0.8, accuracy: 0.000001)
            XCTAssertEqual(vector[511], 0)
        }
        let wrongType = try MLMultiArray(shape: [1, 512], dataType: .double)
        XCTAssertThrowsError(try CoreMLEncoders.normalizedProjection(wrongType))
        XCTAssertThrowsError(try CoreMLEncoders.normalizedProjection(backing))
    }

    func testMissingResourcesReturnsActionableModelUnavailable() async throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("Empty.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.localimageiq.empty", "CFBundleName": "Empty"], format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let encoders = CoreMLEncoders(bundle: bundle)
        do { _ = try await encoders.prepare(); XCTFail("An empty bundle must not produce a model.") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Models unavailable"))
            XCTAssertTrue(error.localizedDescription.contains("Photo authorization remains available"))
        }
    }
}