import XCTest
import CoreML
import ImageIQCore
@testable import LocalImageIQ

final class ModelBoundaryTests: XCTestCase {
    func testManifestAcceptsContractAndAdditionalProvenance() throws {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        try manifest.validate()
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.dimension, 768)
        XCTAssertEqual(manifest.sequenceLength, 64)
        XCTAssertEqual(manifest.imageSize, 224)
        XCTAssertEqual(manifest.imageModel.id, "google/siglip2-base-patch16-224")
        XCTAssertEqual(manifest.imageModel.revision, "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2")
        XCTAssertEqual(manifest.textModel, manifest.imageModel)
        XCTAssertEqual(manifest.textInputs, ["input_ids"])
        let roundTrip = try JSONDecoder().decode(ModelManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(manifest, roundTrip)
    }

    func testManifestRejectsWrongDimensionInputNameAndRevision() throws {
        for dimension in [512, 767, 769] {
            try assertRejectedManifest { $0["dimension"] = dimension }
        }
        try assertRejectedManifest { $0["imageInput"] = "wrong_input" }
        for key in ["imageModel", "textModel"] {
            try assertRejectedManifest {
                $0[key] = ["id": "google/siglip2-base-patch16-224", "revision": "wrong-revision"]
            }
        }
        try assertRejectedManifest {
            let wrong = ["id": "google/siglip2-base-patch16-224", "revision": "wrong-revision"]
            $0["imageModel"] = wrong
            $0["textModel"] = wrong // Matching each other is not sufficient; the revision must be pinned.
        }
    }

    func testManifestRejectsLegacySchemaAndSequenceLength() throws {
        try assertRejectedManifest { $0["schemaVersion"] = 1 }
        for length in [63, 65, 128] {
            try assertRejectedManifest { $0["sequenceLength"] = length }
        }
    }

    func testManifestRejectsLegacyOrMismatchedModelIDs() throws {
        let oldIDs = ["sentence-transformers/clip-ViT-B-32",
                      "sentence-transformers/clip-ViT-B-32-multilingual-v1"]
        // Change each source independently, retaining the valid revision. Matching
        // revision strings must not permit either half of the old CLIP pair.
        for key in ["imageModel", "textModel"] {
            for id in oldIDs {
                try assertRejectedManifest {
                    $0[key] = ["id": id, "revision": "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"]
                }
            }
        }
        try assertRejectedManifest {
            let old = ["id": oldIDs[0], "revision": "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"]
            $0["imageModel"] = old
            $0["textModel"] = old
        }
    }

    func testManifestRejectsAttentionMaskAndAnyOtherTextInputSet() throws {
        let inputs: [[String]] = [["input_ids", "attention_mask"], ["attention_mask"],
                                  [], ["input_ids", "input_ids"], ["wrong_input"]]
        for names in inputs { try assertRejectedManifest { $0["textInputs"] = names } }
    }

    func testManifestRejectsWrongImageSizeOutputAndEmptyVersion() throws {
        try assertRejectedManifest { $0["imageSize"] = 256 }
        try assertRejectedManifest { $0["output"] = "wrong_output" }
        for version in ["", " \t\n"] {
            try assertRejectedManifest { $0["modelVersion"] = version }
        }
    }

    func testProjectionRequires768FiniteNonzeroValuesAndNormalizesOnce() throws {
        var raw = [Float](repeating: 0, count: 768)
        raw[0] = 3; raw[1] = 4
        let normalized = try EmbeddingValidation.normalizeProjection(raw)
        XCTAssertEqual(normalized.count, 768)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.000001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.000001)
        XCTAssertTrue(normalized.dropFirst(2).allSatisfy { $0 == 0 })
        XCTAssertEqual(try EmbeddingMath.dot(normalized, normalized), 1, accuracy: 0.000001)
        try EmbeddingValidation.validateUnit(normalized)
        let normalizedAgain = try EmbeddingValidation.normalizeProjection(normalized)
        for (actual, expected) in zip(normalizedAgain, normalized) {
            XCTAssertEqual(actual, expected, accuracy: 0.000001)
        }
        let lastAxis = try EmbeddingValidation.normalizeProjection(TestFixtures.vector(axis: 767))
        XCTAssertEqual(lastAxis, TestFixtures.vector(axis: 767), "Do not drop the new projection dimensions.")
        XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection([1]))
        for dimension in [512, 767, 769] {
            XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection(TestFixtures.vector(dimension: dimension)))
        }
        XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection([Float](repeating: 0, count: 768)))
        for invalid in [Float.nan, .infinity, -.infinity] {
            raw[0] = invalid
            XCTAssertThrowsError(try EmbeddingValidation.normalizeProjection(raw))
        }
    }

    func testCachedUnitValidationRequires768FiniteUnitValuesByDefault() throws {
        try EmbeddingValidation.validateUnit(TestFixtures.vector(axis: 767))
        let legacy = TestFixtures.vector(dimension: 512)
        XCTAssertThrowsError(try EmbeddingValidation.validateUnit(legacy))
        // Only the legacy read path may opt into the old dimension.
        try EmbeddingValidation.validateUnit(legacy, dimension: 512)
        for dimension in [767, 769] {
            XCTAssertThrowsError(try EmbeddingValidation.validateUnit(TestFixtures.vector(dimension: dimension)))
        }
        for value in [Float(0), 2, .nan, .infinity, -.infinity] {
            var invalid = [Float](repeating: 0, count: 768)
            invalid[0] = value
            XCTAssertThrowsError(try EmbeddingValidation.validateUnit(invalid))
        }
    }

    func testInt32TensorPreservesExplicit64IDsIncludingEOSAndPadding() throws {
        // Tensor transport only, NOT a fake Gemma tokenizer or compatibility test.
        // Real text/tokenizer parity belongs to the generated-model fixtures.
        let values: [Int32] = [
            123, 255999, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]
        XCTAssertEqual(values.count, 64)
        let ids = try CoreMLEncoders.int32Tensor(values)
        XCTAssertEqual(ids.shape.map(\.intValue), [1, 64])
        XCTAssertEqual(ids.count, 64)
        XCTAssertEqual(ids.dataType, .int32)
        XCTAssertEqual((0..<64).map { ids[[0, NSNumber(value: $0)]].int32Value }, values)
        XCTAssertEqual(ids[2].int32Value, 1, "EOS must be copied without conversion.")
        XCTAssertTrue((3..<64).allSatisfy { ids[$0].int32Value == 0 }, "Padding must remain zero.")
        for count in [0, 2, 63, 65, 128] {
            XCTAssertThrowsError(try CoreMLEncoders.int32Tensor([Int32](repeating: 0, count: count)))
        }
    }

    func testProjectionFlatteningRespectsStridesAndRejectsWrongOutputType() throws {
        let backing = try MLMultiArray(shape: [1, 1536], dataType: .float32)
        for index in 0..<1536 { backing[index] = NSNumber(value: index.isMultiple(of: 2) ? Float(0) : Float(100)) }
        backing[0] = 3
        backing[1534] = 4 // Last logical coordinate (767), beyond the old 512-D boundary.
        try withExtendedLifetime(backing) {
            let strided = try MLMultiArray(dataPointer: backing.dataPointer, shape: [1, 768], dataType: .float32,
                                           strides: [1536, 2], deallocator: nil)
            let vector = try CoreMLEncoders.normalizedProjection(strided)
            XCTAssertEqual(vector.count, 768)
            XCTAssertEqual(vector[0], 0.6, accuracy: 0.000001)
            XCTAssertEqual(vector[767], 0.8, accuracy: 0.000001)
            XCTAssertTrue(vector.dropFirst().dropLast().allSatisfy { $0 == 0 })
            XCTAssertEqual(try EmbeddingMath.dot(vector, vector), 1, accuracy: 0.000001)
        }
        let wrongType = try MLMultiArray(shape: [1, 768], dataType: .double)
        wrongType[0] = 1
        XCTAssertThrowsError(try CoreMLEncoders.normalizedProjection(wrongType))
        XCTAssertThrowsError(try CoreMLEncoders.normalizedProjection(backing))
    }

    func testProjectionRejectsWrongShapeEvenWith768UnitElements() throws {
        let shapes: [[Int]] = [[768], [768, 1], [2, 384], [1, 1, 768], [1, 512]]
        for shape in shapes {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            for index in 0..<array.count { array[index] = NSNumber(value: index == 0 ? 1 : 0) }
            XCTAssertEqual(array.count, shape == [1, 512] ? 512 : 768)
            XCTAssertThrowsError(try CoreMLEncoders.normalizedProjection(array), "Shape \(shape)") { error in
                guard let failure = error as? AppFailure, case .modelContract(let detail) = failure else {
                    return XCTFail("Expected a tensor contract failure, got \(error)")
                }
                XCTAssertTrue(detail.contains("Float32 [1,768]"), "Reject the shape, not just the norm/count.")
            }
        }
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

    private func assertRejectedManifest(_ mutate: (inout [String: Any]) -> Void,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TestFixtures.manifest.utf8)) as? [String: Any])
        mutate(&object)
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try manifest.validate(), file: file, line: line) { error in
            guard let failure = error as? AppFailure, case .modelContract = failure else {
                return XCTFail("Expected model contract rejection, got \(error)", file: file, line: line)
            }
        }
    }
}