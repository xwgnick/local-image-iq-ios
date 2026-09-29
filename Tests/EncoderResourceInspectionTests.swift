import Foundation
import ImageIO
import XCTest
@testable import LocalImageIQ

final class EncoderResourceInspectionTests: XCTestCase {
    func testInspectionAcceptsMetadataWithoutParsingRuntimePayloadsButPrepareRejectsThem() async throws {
        let expected = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        try expected.validate() // The fixture's nonempty model version is part of the valid contract.
        let encoders: any PhotoEncoding = CoreMLEncoders(bundle: try makeBundle())

        // Empty compiled-model directories and invalid tokenizer JSON must not be parsed here.
        // Use the protocol existential to verify production overrides the compatibility default.
        let inspected = try await encoders.inspectResources()
        XCTAssertEqual(inspected, expected)
        do {
            _ = try await encoders.prepare()
            XCTFail("Metadata inspection must not mark invalid runtime payloads as loaded.")
        } catch {
            guard let failure = error as? AppFailure, case .modelContract = failure else {
                return XCTFail("Expected runtime payload validation to fail with modelContract, got \(error)")
            }
        }
        let reinspected = try await encoders.inspectResources()
        XCTAssertEqual(reinspected, expected, "A failed full load must not poison metadata inspection.")
    }

    func testEachMissingRequiredResourceReturnsModelsMissing() async throws {
        for missing in Self.requiredResources {
            let encoders = CoreMLEncoders(bundle: try makeBundle(omitting: missing))
            do {
                _ = try await encoders.inspectResources()
                XCTFail("Inspection accepted missing \(missing).")
            } catch {
                guard let failure = error as? AppFailure, case .modelsMissing = failure else {
                    XCTFail("Expected modelsMissing for \(missing), got \(error)")
                    continue
                }
            }
            do {
                _ = try await encoders.prepare()
                XCTFail("Full preparation accepted missing \(missing).")
            } catch {
                guard let failure = error as? AppFailure, case .modelsMissing = failure else {
                    XCTFail("Expected modelsMissing from full preparation for \(missing), got \(error)")
                    continue
                }
            }
        }
    }

    func testInspectionRejectsInvalidManifestContract() async throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TestFixtures.manifest.utf8)) as? [String: Any])
        object["dimension"] = 512
        let invalidManifest = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let encoders = CoreMLEncoders(bundle: try makeBundle(manifest: invalidManifest))
        do {
            _ = try await encoders.inspectResources()
            XCTFail("Inspection must validate the manifest's paired-model contract.")
        } catch {
            guard let failure = error as? AppFailure, case .modelContract(let detail) = failure else {
                return XCTFail("Expected modelContract for the invalid manifest, got \(error)")
            }
            XCTAssertTrue(detail.contains("pinned paired-model contract"))
        }
    }

    func testTokenizerFilesMustBeInTheSameDirectory() async throws {
        let encoders = CoreMLEncoders(bundle: try makeBundle(splitTokenizerDirectory: true))
        for fullPreparation in [false, true] {
            do {
                if fullPreparation { _ = try await encoders.prepare() }
                else { _ = try await encoders.inspectResources() }
                XCTFail("Both paths must reject tokenizer resources in different directories.")
            } catch {
                guard let failure = error as? AppFailure, case .modelContract(let message) = failure else {
                    XCTFail("Expected tokenizer colocation failure, got \(error)")
                    continue
                }
                XCTAssertTrue(message.contains("same directory"))
            }
        }
    }

    func testInspectionWrapsMalformedManifestJSONAsModelContract() async throws {
        let encoders = CoreMLEncoders(bundle: try makeBundle(manifest: "not valid manifest JSON"))
        do {
            _ = try await encoders.inspectResources()
            XCTFail("Inspection must decode the manifest.")
        } catch {
            guard let failure = error as? AppFailure, case .modelContract = failure else {
                return XCTFail("Expected modelContract rather than a raw decoding error, got \(error)")
            }
        }
    }

    func testInspectionHonorsPreCancellationBeforeResourceValidation() async throws {
        let bundles = [try makeBundle(),
                       try makeBundle(omitting: "model-manifest.json"),
                       try makeBundle(manifest: "not valid manifest JSON")]
        for bundle in bundles {
            let encoders = CoreMLEncoders(bundle: bundle)
            // Cancel this separate task before inspection, without a scheduler race or
            // cancelling XCTest's own task. Cancellation must win over resource failures.
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await encoders.inspectResources()
            }
            do {
                _ = try await cancelled.value
                XCTFail("Pre-cancelled inspection must not return metadata.")
            } catch is CancellationError {
                // Expected, not a wrapped model contract failure.
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }
    }

    func testDefaultInspectionDelegatesToInjectedPrepare() async throws {
        let expected = try JSONDecoder().decode(ModelManifest.self, from: Data(TestFixtures.manifest.utf8))
        let injected = InspectionCompatibilityEncoder(manifest: expected)
        let encoders: any PhotoEncoding = injected
        let inspected = try await encoders.inspectResources()
        let prepareCallCount = await injected.prepareCallCount
        XCTAssertEqual(inspected, expected)
        XCTAssertEqual(prepareCallCount, 1)
    }

    private static let requiredResources = ["model-manifest.json", "ImageEncoder.mlmodelc",
                                            "TextEncoder.mlmodelc", "tokenizer.json", "tokenizer_config.json"]

    private func makeBundle(omitting omitted: String? = nil,
                            manifest: String = TestFixtures.manifest,
                            splitTokenizerDirectory: Bool = false) throws -> Bundle {
        let directory = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("Inspection.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.localimageiq.inspection.\(UUID().uuidString)",
            "CFBundleName": "Inspection", "CFBundlePackageType": "BNDL"
        ], format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        for name in Self.requiredResources where name != omitted {
            let parent = splitTokenizerDirectory && name == "tokenizer_config.json"
                ? bundleURL.appendingPathComponent("Models", isDirectory: true) : bundleURL
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let url = parent.appendingPathComponent(name)
            if name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                let contents = name == "model-manifest.json" ? manifest : "not valid tokenizer JSON"
                try Data(contents.utf8).write(to: url)
            }
        }
        // Construct only after writing resources; do not depend on Bundle lookup cache invalidation.
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}

/// Implements only the pre-existing protocol requirements, like existing injected mocks.
private actor InspectionCompatibilityEncoder: PhotoEncoding {
    private let manifest: ModelManifest
    private(set) var prepareCallCount = 0

    init(manifest: ModelManifest) { self.manifest = manifest }

    func prepare() async throws -> ModelManifest {
        prepareCallCount += 1
        return manifest
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float] {
        throw AppFailure.modelContract("Unexpected image prediction in an inspection test.")
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        throw AppFailure.modelContract("Unexpected image prediction in an inspection test.")
    }

    func text(_ text: String) async throws -> [Float] {
        throw AppFailure.modelContract("Unexpected text prediction in an inspection test.")
    }
}