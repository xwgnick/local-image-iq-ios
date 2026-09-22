import XCTest
import Foundation
import CoreML
import CoreGraphics
import ImageIO
import CryptoKit
import ImageIQCore
@testable import LocalImageIQ

/// App-hosted, generated-fixture tests. Never downloads, exports, or compiles models.
final class GeneratedModelParityTests: XCTestCase {
    // Numerical validation criteria, NOT production filters or performance quotas.
    private static let conversionMaxAbs = 1e-3
    private static let conversionMinCosine = 0.999 // Strictly greater than.
    private static let nativeImageMinCosine = 0.995 // Inclusive; interpolation differs.
    private static let solidMaxAbs = 1e-5
    private static let imageShape = [1, 3, 224, 224]
    private static let imageValueCount = 3 * 224 * 224
    // Independent pins: do not derive expected normalization from the implementation.
    private static let pinnedMean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    private static let pinnedStd: [Float] = [0.26862954, 0.26130258, 0.27577711]

    func testGeneratedWordPieceIDsAndMasksMatchAllCases() throws {
        try withReport(computeUnits: "not-used") { report in
            let resources = try self.resources(report: &report)
            let tokenizer = try self.tokenizer(resources)
            for fixture in resources.text.cases {
                autoreleasepool {
                    let native = tokenizer.encode(fixture.text)
                    checkTokens(native, fixture: fixture, report: &report)
                }
            }
        }
    }

    func testTextEncoderCPUReferenceAndNativeTokensParity() throws {
        try withReport(computeUnits: "cpuOnly") { report in
            let resources = try self.resources(report: &report)
            try runText(resources, computeUnits: .cpuOnly, report: &report)
        }
    }

    func testImageEncoderCPUSameFloatInputParity() throws {
        try withReport(computeUnits: "cpuOnly") { report in
            let resources = try self.resources(report: &report)
            try runImages(resources, computeUnits: .cpuOnly, sameInput: true,
                          nativePreprocessing: false, report: &report)
        }
    }

    func testNativeImagePreprocessingCPUParity() throws {
        try withReport(computeUnits: "cpuOnly") { report in
            let resources = try self.resources(report: &report)
            try runImages(resources, computeUnits: .cpuOnly, sameInput: false,
                          nativePreprocessing: true, report: &report)
        }
    }

    func testKnownSolidRGBNormalizationWithoutModels() throws {
        try withReport(computeUnits: "not-used") { report in
            let colors: [(UInt8, UInt8, UInt8)] = [
                (31, 127, 223), (255, 0, 0), (0, 255, 0), (0, 0, 255),
                (0, 0, 0), (255, 255, 255),
            ]
            for (r, g, b) in colors {
                try autoreleasepool {
                    let image = try TestFixtures.image(width: 224, height: 224) { _, _ in (r, g, b) }
                    let native = try ImagePreprocessor.values(image: image)
                    try checkSolid(native, rgb: [r, g, b], id: "solid-\(r)-\(g)-\(b)", report: &report)
                }
            }
        }
    }

    func testGeneratedPairAllComputeUnitsParityWhenRequested() throws {
        try withReport(computeUnits: "all") { report in
            // Validate resource availability BEFORE the optional engine skip. A broken
            // model-enabled bundle must never be disguised as an optional-engine skip.
            let resources = try self.resources(report: &report)
            guard ProcessInfo.processInfo.environment["IMAGEIQ_TEST_ALL_COMPUTE_UNITS"] == "1" else {
                throw XCTSkip("Optional .all comparison: inject IMAGEIQ_TEST_ALL_COMPUTE_UNITS=1 into the test runner/host. CPU gates are separate tests.")
            }
            // Each helper releases its one model before the other role is loaded.
            try runText(resources, computeUnits: .all, report: &report)
            try runImages(resources, computeUnits: .all, sameInput: true,
                          nativePreprocessing: true, report: &report)
        }
    }

    func testAppEncodersModelSizedPreviewAndAllTextReferenceParity() async throws {
        // The production actor uses .all. Unlike the optional engine comparison,
        // this app-API gate runs in EVERY model-enabled build, without MainActor.
        var report = Report(test: name, requestedComputeUnits: "all")
        report.coverageNote = "Synthetic ImageIO raw pixels -> CGContext.high aspect-preserving model-sized preview -> app actor. Not PhotoKit pixel identity, iCloud availability, or real-device quality."
        report.expectedAppPredictions = ["image.preview": 4, "text": 12]
        // withReport is synchronous: never place an await inside its inout closure.
        defer { self.attach(report) }
        do {
            let fixtures = try self.resources(report: &report)
            try require(fixtures.images.cases.count == 4 && fixtures.text.cases.count == 12,
                        "App API parity requires exactly four image patterns and all twelve text cases.")
            let encoders: any PhotoEncoding = CoreMLEncoders(bundle: fixtures.bundle)
            let manifest = try await encoders.prepare()
            try require(manifest.modelVersion == fixtures.manifest.modelVersion,
                        "The app actor must load the fixture owner's model pair.")

            for fixture in fixtures.images.cases {
                let preview = try modelSizedPreview(fixture, resources: fixtures, report: &report)
                let projection = try await encoders.image(preview: preview)
                report.completedAppPredictions["image.preview", default: 0] += 1
                try checkAppProjection(projection, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                       id: fixture.id, stage: "image.appModelSizedPreview",
                                       minCosine: Self.nativeImageMinCosine, strictCosine: false, report: &report)
            }
            for fixture in fixtures.text.cases {
                let projection = try await encoders.text(fixture.text)
                report.completedAppPredictions["text", default: 0] += 1
                try checkAppProjection(projection, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                       id: fixture.id, stage: "text.appNativeTokens",
                                       minCosine: Self.conversionMinCosine, strictCosine: true, report: &report)
            }
            try require(report.completedAppPredictions == report.expectedAppPredictions
                        && report.previews.count == 4 && report.measurements.count == 40,
                        "Incomplete app API parity: expected 16 predictions and 40 comparisons (8 tensor diagnostics, 32 normalized embedding gates).")
            report.completed = true // Completion is NOT a claim that assertions passed.
        } catch {
            report.skipped = error is XCTSkip
            report.error = String(describing: error)
            throw error
        }
    }

    // MARK: - Actual native pipelines, one model load per role per test

    private func modelSizedPreview(_ fixture: ImageCase, resources: Resources,
                                   report: inout Report) throws -> IndexingImage {
        try autoreleasepool {
            let data = try checkedData(resources.fixtureURL(fixture.image), sha256: fixture.imageSHA256)
            let orientation = try inspectOrientation(data, fixture: fixture)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            // Decode RAW pixels: no ImageIO thumbnail transform, UIKit orientation,
            // PNG/JPEG re-encoding, or orientation copied from fixture expectations.
            let raw = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            try require([raw.width, raw.height] == fixture.sourceSize, "Unexpected decoded raw dimensions: \(fixture.id)")
            let shortest = min(raw.width, raw.height)
            let size = ImagePreprocessor.size
            let scale = Double(size) / Double(shortest)
            let width = max(size, Int(Double(raw.width) * scale))
            let height = max(size, Int(Double(raw.height) * scale))
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                bytesPerRow: width * 4, space: colorSpace,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                    CGBitmapInfo.byteOrder32Big.rawValue))
            let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(rect)
            context.interpolationQuality = .high
            context.draw(raw, in: rect) // Keep the full aspect ratio, not a stretched 224x224 square.
            let pixels = try XCTUnwrap(context.makeImage())
            let swapped = (5...8).contains(orientation.rawValue)
            let orientedSize = swapped ? [height, width] : [width, height]
            try require(min(width, height) == size && orientedSize == fixture.resizedSize,
                        "Preview must preserve oriented resize geometry: \(fixture.id)")
            // Only checker-nonsquare is genuinely downsampled by these fixtures;
            // the solid is already 224, and the 197-short-edge EXIF cases grow.
            // These source labels are synthetic metadata, not PhotoKit callbacks.
            let preview = IndexingImage(cgImage: pixels, orientation: orientation, source: .localPreview)
            report.previews.append(PreviewMeasurement(id: fixture.id, sourceSize: [raw.width, raw.height],
                                                      previewSize: [pixels.width, pixels.height],
                                                      orientedPreviewSize: orientedSize,
                                                      exifOrientation: orientation.rawValue,
                                                      source: preview.source.rawValue,
                                                      resampling: shortest > size ? "downsample" : (shortest < size ? "upsample" : "same-size")))
            let original = try ImagePreprocessor.values(data: data, orientation: orientation)
            let candidate = try imageValues(ImagePreprocessor.tensor(image: preview.cgImage, orientation: preview.orientation))
            try record(reference: original, candidate: candidate, id: fixture.id,
                       stage: "image.previewVsOriginalTensor", target: "native original-data preprocessing",
                       report: &report)
            try record(reference: referenceTensor(fixture, resources: resources), candidate: candidate, id: fixture.id,
                       stage: "image.previewVsHFTensor", target: "HF/Pillow full NCHW tensor", report: &report)
            // Tensor deltas are diagnostic. The async test gates actual app embeddings
            // against ST at >= .995 even when pre-resizing changes the pixels.
            return preview
        }
    }

    private func checkAppProjection(_ projection: [Float], st: [Float], exported: [Float],
                                    id: String, stage: String, minCosine: Double, strictCosine: Bool,
                                    report: inout Report) throws {
        try require(projection.count == 512 && projection.allSatisfy(\.isFinite),
                    "\(stage)/\(id): app output must contain 512 finite Float values.")
        let norm = sqrt(projection.reduce(0.0) { $0 + Double($1) * Double($1) })
        try require(abs(norm - 1) <= 1e-5, "\(stage)/\(id): app output must already be normalized; norm=\(norm).")
        // Do not normalize the candidate again and hide an app normalization bug.
        // Raw-output conversion gates remain in the existing synchronous tests.
        for (target, reference) in [("sentenceTransformerRaw", st), ("coreMLRaw", exported)] {
            try record(reference: EmbeddingValidation.normalizeProjection(reference), candidate: projection,
                       id: id, stage: stage + ".normalized", target: target,
                       minCosine: minCosine, strictCosine: strictCosine, report: &report)
        }
    }

    private func runText(_ resources: Resources, computeUnits: MLComputeUnits,
                         report: inout Report) throws {
        try autoreleasepool {
            let model = try loadModel(resources.textModel, computeUnits: computeUnits, inputs: [
                "input_ids": ([1, 128], .int32), "attention_mask": ([1, 128], .int32),
            ])
            let tokenizer = try self.tokenizer(resources)
            for fixture in resources.text.cases {
                try autoreleasepool {
                    let native = tokenizer.encode(fixture.text)
                    checkTokens(native, fixture: fixture, report: &report)
                    // Do BOTH predictions even when IDs disagree. The fixed input is
                    // the conversion control; a mismatch must not suppress that control.
                    let fixed = try predictText(model, ids: fixture.inputIDs, mask: fixture.attentionMask)
                    try compareProjection(fixed, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                          id: fixture.id, stage: "text.fixedReferenceIDs",
                                          conversion: true, report: &report)
                    let generated = try predictText(model, ids: native.inputIDs, mask: native.attentionMask)
                    try compareProjection(generated, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                          id: fixture.id, stage: "text.nativeGeneratedIDs",
                                          conversion: true, report: &report)
                }
            }
        }
    }

    private func runImages(_ resources: Resources, computeUnits: MLComputeUnits, sameInput: Bool,
                           nativePreprocessing: Bool, report: inout Report) throws {
        try autoreleasepool {
            let model = try loadModel(resources.imageModel, computeUnits: computeUnits,
                                      inputs: ["pixel_values": (Self.imageShape, .float32)])
            for fixture in resources.images.cases {
                try autoreleasepool {
                    let reference = try referenceTensor(fixture, resources: resources)
                    if sameInput {
                        // The full exported Float32 LE tensor, NOT a re-decoded image.
                        let tensor = try imageTensor(reference)
                        let prediction = try predict(model, inputs: ["pixel_values": tensor])
                        try compareProjection(prediction, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                              id: fixture.id, stage: "image.sameFloatInput",
                                              conversion: true, report: &report)
                    }
                    if nativePreprocessing {
                        let data = try checkedData(resources.fixtureURL(fixture.image), sha256: fixture.imageSHA256)
                        let orientation = try inspectOrientation(data, fixture: fixture)
                        // Intentionally omit orientation: this function must read EXIF
                        // from the source bytes itself, not from fixture expectations.
                        let native = try ImagePreprocessor.values(data: data)
                        try record(reference: reference, candidate: native, id: fixture.id,
                                   stage: "image.nativeTensor", target: "HF/Pillow full NCHW tensor",
                                   report: &report) // Pixel max/MAE are diagnostic, not bit-exact gates.
                        if fixture.id == "solid-rgb" {
                            try checkSolid(native, rgb: [31, 127, 223], id: fixture.id, report: &report)
                            try checkSolid(reference, rgb: [31, 127, 223], id: fixture.id + ".reference", report: &report)
                        }
                        // The app tensor API requires an explicit orientation. Derive it
                        // independently with ImageIO, NEVER substitute metadata's expected value.
                        let tensor = try ImagePreprocessor.tensor(data: data, orientation: orientation)
                        try record(reference: native, candidate: imageValues(tensor), id: fixture.id,
                                   stage: "image.implicitVsImageIOOrientation", target: "native values(data:)",
                                   maxAbs: 0, report: &report)
                        let prediction = try predict(model, inputs: ["pixel_values": tensor])
                        try compareProjection(prediction, st: fixture.sentenceTransformerRaw, exported: fixture.coreMLRaw,
                                              id: fixture.id, stage: "image.nativePreprocessing",
                                              conversion: false, report: &report)
                    }
                }
            }
        }
    }

    private func predictText(_ model: MLModel, ids: [Int32], mask: [Int32]) throws -> Prediction {
        try predict(model, inputs: ["input_ids": CoreMLEncoders.int32Tensor(ids),
                                    "attention_mask": CoreMLEncoders.int32Tensor(mask)])
    }

    private func predict(_ model: MLModel, inputs: [String: MLMultiArray]) throws -> Prediction {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let output = try model.prediction(from: provider)
        let array = try XCTUnwrap(output.featureValue(for: "output_embedding")?.multiArrayValue)
        try require(array.dataType == .float32 && array.shape.map(\.intValue) == [1, 512],
                    "Prediction must be Float32 [1,512].")
        // Coordinate subscripts honor non-contiguous output strides.
        let raw = (0..<512).map { array[[NSNumber(value: 0), NSNumber(value: $0)]].floatValue }
        return Prediction(raw: raw, normalized: try CoreMLEncoders.normalizedProjection(array))
    }

    private func loadModel(_ url: URL, computeUnits: MLComputeUnits,
                           inputs: [String: ([Int], MLMultiArrayDataType)]) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let description = model.modelDescription
        try require(Set(description.inputDescriptionsByName.keys) == Set(inputs.keys)
                    && Set(description.outputDescriptionsByName.keys) == ["output_embedding"],
                    "Unexpected model feature names: \(url.lastPathComponent)")
        for (name, specification) in inputs {
            try checkFeature(description.inputDescriptionsByName[name], shape: specification.0, type: specification.1)
        }
        try checkFeature(description.outputDescriptionsByName["output_embedding"], shape: [1, 512], type: .float32)
        return model
    }

    private func checkFeature(_ feature: MLFeatureDescription?, shape: [Int], type: MLMultiArrayDataType) throws {
        try require(feature?.type == .multiArray && feature?.isOptional == false
                    && feature?.multiArrayConstraint?.shape.map(\.intValue) == shape
                    && feature?.multiArrayConstraint?.dataType == type, "Unexpected model feature shape/type.")
    }

    // MARK: - Bundle gating and exact exporter schemas

    private func resources(report: inout Report) throws -> Resources {
        let main = Bundle.main
        let test = Bundle(for: type(of: self))
        let bundles = main.bundleURL == test.bundleURL ? [main] : [main, test]
        let manifestName = "model-manifest"
        let appManifest = BundleResources.url(manifestName, extension: "json", bundle: main)
        // A present app manifest always wins: a complete test bundle cannot conceal
        // missing production models/vocabulary in the host app.
        guard let owner = bundles.first(where: {
            BundleResources.url(manifestName, extension: "json", bundle: $0) != nil
        }) else {
            let partial = bundles.contains { bundle in
                [("ImageEncoder", "mlmodelc"), ("TextEncoder", "mlmodelc"), ("vocab", "txt"),
                 ("tokenizer-parity", "json"), ("image-preprocess-parity", "json")].contains {
                    BundleResources.url($0.0, extension: $0.1, bundle: bundle) != nil
                }
            }
            if report.requireModels || partial {
                throw ParityError.invalid("Model-enabled/incomplete bundle has no model-manifest.json. IMAGEIQ_REQUIRE_MODELS=1 requires both bundled .mlmodelc encoders, vocabulary, and generated fixtures; absence is a failure.")
            }
            throw XCTSkip("Model-free build: neither app nor test bundle contains generated model resources. Native model/tokenizer fixture parity was NOT run. Inject IMAGEIQ_REQUIRE_MODELS=1 into the runner/host to make absence fail.")
        }
        report.resourceGate = appManifest != nil ? "app-bundle-manifest" : "test-bundle-manifest"
        report.modelBundle = owner.bundleURL.lastPathComponent
        func required(_ name: String, _ ext: String, in candidates: [Bundle]) throws -> URL {
            for bundle in candidates {
                if let url = BundleResources.url(name, extension: ext, bundle: bundle) { return url }
            }
            throw ParityError.invalid("Missing bundled \(name).\(ext); model-enabled parity cannot skip.")
        }
        let manifestURL = try required(manifestName, "json", in: [owner])
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let imageModel = try required("ImageEncoder", "mlmodelc", in: [owner])
        let textModel = try required("TextEncoder", "mlmodelc", in: [owner])
        let vocabulary = try required("vocab", "txt", in: [owner])
        // Test-only fixtures may be copied into the test bundle. Models and vocab
        // must belong to the selected manifest bundle; never mix two model pairs.
        let fixtureBundles = [owner] + bundles.filter { $0.bundleURL != owner.bundleURL }
        let textURL = try required("tokenizer-parity", "json", in: fixtureBundles)
        let imageURL = try required("image-preprocess-parity", "json", in: fixtureBundles)
        let text = try JSONDecoder().decode(TextDocument.self, from: Data(contentsOf: textURL))
        let images = try JSONDecoder().decode(ImageDocument.self, from: Data(contentsOf: imageURL))
        try require(text.schemaVersion == 1 && images.schemaVersion == 1
                    && text.modelVersion == manifest.modelVersion && images.modelVersion == manifest.modelVersion
                    && text.embeddingDimension == 512 && images.embeddingDimension == 512
                    && text.embeddingsAreRaw && images.embeddingsAreRaw && text.sequenceLength == 128
                    && text.textModel == manifest.textModel && images.imageModel == manifest.imageModel,
                    "Fixture header/source identity differs from the app manifest.")
        try require(text.backendNormalizer.type == "BertNormalizer" && !text.backendNormalizer.lowercase
                    && text.backendNormalizer.strip_accents != true && text.backendNormalizer.handle_chinese_chars
                    && text.backendNormalizer.clean_text, "Expected the cased HF BertNormalizer contract.")
        try require(images.preprocessing.mean == Self.pinnedMean && images.preprocessing.std == Self.pinnedStd
                    && images.preprocessing.layout == "NCHW" && images.preprocessing.rescale == 1.0 / 255.0,
                    "Image fixture normalization contract drifted.")
        try requireCaseIDs(text.cases.map(\.id), containing: [
            "english", "chinese", "case", "diacritics", "combining", "punctuation", "special-tokens",
            "empty", "whitespace-controls", "unknown-unicode", "long-word", "long-truncation",
        ])
        try requireCaseIDs(images.cases.map(\.id), containing: [
            "solid-rgb", "checker-nonsquare", "exif-rotate-6", "exif-mirror-2",
        ])
        try require(images.cases.contains { $0.id == "exif-rotate-6" && $0.exifOrientation == 6 }
                    && images.cases.contains { $0.id == "exif-mirror-2" && $0.exifOrientation == 2 },
                    "Both nontrivial EXIF rotation and reflection examples are required.")
        for fixture in text.cases {
            try require(fixture.inputIDs.count == 128 && fixture.attentionMask.count == 128
                        && fixture.inputIDs.allSatisfy { (0..<119547).contains(Int($0)) }
                        && fixture.attentionMask.allSatisfy { $0 == 0 || $0 == 1 },
                        "Malformed token fixture: \(fixture.id)")
            try checkRawVectors(fixture.sentenceTransformerRaw, fixture.coreMLRaw)
        }
        let result = Resources(bundle: owner, manifest: manifest, imageModel: imageModel, textModel: textModel,
                               vocabulary: vocabulary, imageDocumentURL: imageURL, fixtureBundles: fixtureBundles,
                               text: text, images: images)
        for fixture in images.cases {
            try require(fixture.shape == Self.imageShape && fixture.layout == "NCHW"
                        && fixture.dtype == "float32-little-endian" && fixture.tensorBytes == Self.imageValueCount * 4,
                        "Malformed image tensor fixture: \(fixture.id)")
            try checkRawVectors(fixture.sentenceTransformerRaw, fixture.coreMLRaw)
            _ = try result.fixtureURL(fixture.image)
            _ = try result.fixtureURL(fixture.tensor)
        }
        report.modelVersion = manifest.modelVersion
        report.exportNativeMarkers = ["tokenizer": text.nativeParity, "imagePreprocessing": images.nativeParity]
        report.fixtureCounts = ["text": text.cases.count, "image": images.cases.count]
        return result
    }

    private func requireCaseIDs(_ ids: [String], containing required: Set<String>) throws {
        try require(Set(ids).count == ids.count && required.isSubset(of: Set(ids)),
                    "Missing or duplicated generated fixture IDs; Unicode/orientation coverage must not silently shrink.")
    }

    private func tokenizer(_ resources: Resources) throws -> WordPieceTokenizer {
        let data = try checkedData(resources.vocabulary, sha256: resources.text.vocabularySHA256)
        let string = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Match the app's newline handling; never trim/normalize individual tokens.
        var vocabulary = string.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        if vocabulary.last == "" { vocabulary.removeLast() }
        try require(vocabulary.count == 119547, "Pinned vocabulary must contain 119547 entries.")
        return try WordPieceTokenizer(vocabulary: vocabulary, sequenceLength: resources.manifest.sequenceLength)
    }

    private struct Resources {
        let bundle: Bundle
        let manifest: ModelManifest
        let imageModel: URL
        let textModel: URL
        let vocabulary: URL
        let imageDocumentURL: URL
        let fixtureBundles: [Bundle]
        let text: TextDocument
        let images: ImageDocument

        func fixtureURL(_ relative: String) throws -> URL {
            // Exporter uses fixtures/<id>.<extension>, relative to the JSON directory.
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "fixtures", !parts[1].isEmpty, parts[1] != "..",
                  !relative.contains("\\") else {
                throw ParityError.invalid("Unexpected generated fixture path: \(relative)")
            }
            let adjacent = imageDocumentURL.deletingLastPathComponent().appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: adjacent.path) { return adjacent }
            // Xcode may flatten copied file resources; hashes below still pin bytes.
            let leaf = URL(fileURLWithPath: String(parts[1]))
            for bundle in fixtureBundles {
                for name in [relative as NSString, leaf.lastPathComponent as NSString] {
                    if let url = BundleResources.url(name.deletingPathExtension, extension: leaf.pathExtension, bundle: bundle) {
                        return url
                    }
                }
            }
            throw ParityError.invalid("Missing bundled fixture \(relative); model-enabled parity cannot skip.")
        }
    }

    private struct TextDocument: Decodable {
        let schemaVersion: Int
        let modelVersion: String
        let embeddingDimension: Int
        let embeddingsAreRaw: Bool
        let sequenceLength: Int
        let textModel: ModelManifest.Source
        let vocabularySHA256: String
        let backendNormalizer: BertNormalizer
        let nativeParity: String
        let cases: [TextCase]
    }

    private struct BertNormalizer: Decodable {
        let type: String
        let lowercase: Bool
        let strip_accents: Bool?
        let handle_chinese_chars: Bool
        let clean_text: Bool
    }

    private struct TextCase: Decodable {
        let id: String
        let text: String
        let inputIDs: [Int32]
        let attentionMask: [Int32]
        let sentenceTransformerRaw: [Float]
        let coreMLRaw: [Float]
    }

    private struct ImageDocument: Decodable {
        let schemaVersion: Int
        let modelVersion: String
        let embeddingDimension: Int
        let embeddingsAreRaw: Bool
        let imageModel: ModelManifest.Source
        let preprocessing: ImageNormalization
        let nativeParity: String
        let cases: [ImageCase]
    }

    private struct ImageNormalization: Decodable {
        let mean: [Float]
        let std: [Float]
        let rescale: Double
        let layout: String
    }

    private struct ImageCase: Decodable {
        let id: String
        let image: String
        let imageSHA256: String
        let sourceSize: [Int]
        let exifOrientation: UInt32
        let orientedSize: [Int]
        let resizedSize: [Int]
        let cropXYWH: [Int]
        let tensor: String
        let tensorSHA256: String
        let tensorBytes: Int
        let dtype: String
        let shape: [Int]
        let layout: String
        let spotChecks: [SpotCheck]
        let pillowVsHFMaxAbs: Double
        let sentenceTransformerRaw: [Float]
        let coreMLRaw: [Float]
    }

    private struct SpotCheck: Decodable {
        let channel: Int
        let y: Int
        let x: Int
        let value: Float
    }

    // MARK: - Image bytes, orientation and Float32 little-endian decoding

    private func checkedData(_ url: URL, sha256 expected: String) throws -> Data {
        let data = try Data(contentsOf: url)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try require(actual == expected, "SHA-256 mismatch: \(url.lastPathComponent)")
        return data
    }

    private func referenceTensor(_ fixture: ImageCase, resources: Resources) throws -> [Float] {
        let data = try checkedData(resources.fixtureURL(fixture.tensor), sha256: fixture.tensorSHA256)
        try require(data.count == fixture.tensorBytes && data.count == Self.imageValueCount * 4,
                    "Incorrect full tensor byte count: \(fixture.id)")
        // Byte assembly avoids assuming Data alignment or host endianness.
        let values: [Float] = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            stride(from: 0, to: bytes.count, by: 4).map { offset in
                let bits = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
                return Float(bitPattern: bits)
            }
        }
        try require(values.allSatisfy(\.isFinite), "Non-finite reference tensor: \(fixture.id)")
        try require(!fixture.spotChecks.isEmpty, "Missing reference spot checks: \(fixture.id)")
        for spot in fixture.spotChecks {
            try require((0..<3).contains(spot.channel) && (0..<224).contains(spot.x) && (0..<224).contains(spot.y),
                        "Invalid NCHW spot coordinate: \(fixture.id)")
            try require(values[spot.channel * 224 * 224 + spot.y * 224 + spot.x] == spot.value,
                        "Full tensor/JSON spot mismatch: \(fixture.id)")
        }
        return values
    }

    private func inspectOrientation(_ data: Data, fixture: ImageCase) throws -> CGImagePropertyOrientation {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let raw = try XCTUnwrap(properties[kCGImagePropertyOrientation] as? NSNumber).uint32Value
        let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? NSNumber).intValue
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? NSNumber).intValue
        try require(raw == fixture.exifOrientation && [width, height] == fixture.sourceSize,
                    "ImageIO must read the fixture's real EXIF/source dimensions: \(fixture.id)")
        let oriented = (5...8).contains(raw) ? [height, width] : [width, height]
        try require(oriented == fixture.orientedSize && oriented.allSatisfy { $0 > 0 },
                    "Unexpected oriented image dimensions: \(fixture.id)")
        let shortest = min(oriented[0], oriented[1])
        let resized = oriented.map { Int(224.0 * Double($0) / Double(shortest)) }
        try require(resized == fixture.resizedSize
                    && fixture.cropXYWH == [(resized[0] - 224) / 2, (resized[1] - 224) / 2, 224, 224],
                    "Fixture shortest-side/center-crop geometry drifted: \(fixture.id)")
        return orientation
    }

    private func imageTensor(_ values: [Float]) throws -> MLMultiArray {
        try require(values.count == Self.imageValueCount && values.allSatisfy(\.isFinite), "Invalid image values.")
        let array = try MLMultiArray(shape: Self.imageShape.map { NSNumber(value: $0) }, dataType: .float32)
        for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
        return array
    }

    private func imageValues(_ tensor: MLMultiArray) throws -> [Float] {
        try require(tensor.dataType == .float32 && tensor.shape.map(\.intValue) == Self.imageShape,
                    "Native image tensor must be Float32 NCHW [1,3,224,224].")
        var result: [Float] = []
        result.reserveCapacity(Self.imageValueCount)
        for channel in 0..<3 {
            for y in 0..<224 {
                for x in 0..<224 {
                    result.append(tensor[[0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]].floatValue)
                }
            }
        }
        return result
    }

    private func checkSolid(_ values: [Float], rgb: [UInt8], id: String, report: inout Report) throws {
        try require(rgb.count == 3 && values.count == Self.imageValueCount, "Invalid solid RGB tensor.")
        let expected = (0..<3).flatMap { channel in
            [Float](repeating: (Float(rgb[channel]) / 255 - Self.pinnedMean[channel]) / Self.pinnedStd[channel],
                    count: 224 * 224)
        }
        try record(reference: expected, candidate: values, id: id, stage: "image.pinnedSolidRGB",
                   target: "independent RGB/NCHW constants", maxAbs: Self.solidMaxAbs, report: &report)
    }

    // MARK: - Exact tokens, numerical comparisons, xcresult-only reports

    private func checkTokens(_ native: TokenizedText, fixture: TextCase, report: inout Report) {
        let ids = differingIndices(native.inputIDs, fixture.inputIDs)
        let mask = differingIndices(native.attentionMask, fixture.attentionMask)
        report.tokens.append(TokenMeasurement(id: fixture.id, text: fixture.text,
                                             unicodeScalars: fixture.text.unicodeScalars.map(\.value),
                                             inputIDMismatchIndices: ids, attentionMaskMismatchIndices: mask,
                                             nativeIDs: native.inputIDs, referenceIDs: fixture.inputIDs,
                                             nativeMask: native.attentionMask, referenceMask: fixture.attentionMask))
        XCTAssertEqual(native.inputIDs, fixture.inputIDs, "\(fixture.id): exact WordPiece IDs; mismatched positions \(ids)")
        XCTAssertEqual(native.attentionMask, fixture.attentionMask, "\(fixture.id): exact attention mask; mismatched positions \(mask)")
    }

    private func differingIndices(_ lhs: [Int32], _ rhs: [Int32]) -> [Int] {
        (0..<max(lhs.count, rhs.count)).filter { $0 >= lhs.count || $0 >= rhs.count || lhs[$0] != rhs[$0] }
    }

    private struct Prediction {
        let raw: [Float]
        let normalized: [Float]
    }

    private func checkRawVectors(_ vectors: [Float]...) throws {
        for vector in vectors {
            try require(vector.count == 512 && vector.allSatisfy(\.isFinite)
                        && vector.contains { $0 != 0 }, "Expected finite, nonzero raw 512D fixture vectors.")
        }
    }

    private func compareProjection(_ prediction: Prediction, st: [Float], exported: [Float],
                                   id: String, stage: String, conversion: Bool, report: inout Report) throws {
        for (target, reference) in [("sentenceTransformerRaw", st), ("coreMLRaw", exported)] {
            try record(reference: reference, candidate: prediction.raw, id: id, stage: stage + ".raw",
                       target: target, maxAbs: conversion ? Self.conversionMaxAbs : nil,
                       minCosine: conversion ? Self.conversionMinCosine : Self.nativeImageMinCosine,
                       strictCosine: conversion, report: &report)
            let normalized = try EmbeddingValidation.normalizeProjection(reference)
            try record(reference: normalized, candidate: prediction.normalized, id: id, stage: stage + ".normalized",
                       target: target, minCosine: conversion ? Self.conversionMinCosine : Self.nativeImageMinCosine,
                       strictCosine: conversion, report: &report)
        }
    }

    private func record(reference: [Float], candidate: [Float], id: String, stage: String, target: String,
                        maxAbs: Double? = nil, minCosine: Double? = nil, strictCosine: Bool = false,
                        report: inout Report) throws {
        try require(!reference.isEmpty && reference.count == candidate.count
                    && reference.allSatisfy(\.isFinite) && candidate.allSatisfy(\.isFinite),
                    "\(stage)/\(id): vectors must have equal nonzero lengths and finite components.")
        var maximum = 0.0, total = 0.0, dot = 0.0, leftSquared = 0.0, rightSquared = 0.0
        for (left, right) in zip(reference, candidate) {
            let a = Double(left), b = Double(right)
            let error = abs(a - b)
            maximum = max(maximum, error)
            total += error
            dot += a * b
            leftSquared += a * a
            rightSquared += b * b
        }
        let cosine: Double? = leftSquared > 0 && rightSquared > 0 ? dot / sqrt(leftSquared * rightSquared) : nil
        let absolutePassed = maxAbs.map { maximum <= $0 } ?? true
        let cosinePassed = minCosine.map { floor in
            cosine.map { strictCosine ? $0 > floor : $0 >= floor } ?? false
        } ?? true
        let measurement = Measurement(id: id, stage: stage, reference: target, count: reference.count,
                                      maxAbs: maximum, meanAbs: total / Double(reference.count), cosine: cosine,
                                      referenceNorm: sqrt(leftSquared), candidateNorm: sqrt(rightSquared),
                                      maxAbsInclusive: maxAbs, minCosine: minCosine, cosineExclusive: strictCosine,
                                      accepted: absolutePassed && cosinePassed)
        report.measurements.append(measurement)
        XCTAssertTrue(absolutePassed && cosinePassed,
                      "\(stage)/\(id) vs \(target): maxAbs=\(maximum), MAE=\(measurement.meanAbs), cosine=\(String(describing: cosine)); maxAbs<=\(String(describing: maxAbs)), cosine\(strictCosine ? ">" : ">=")\(String(describing: minCosine)). See JSON attachment.")
    }

    private enum ParityError: Error, CustomStringConvertible {
        case invalid(String)
        var description: String { switch self { case .invalid(let message): return message } }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ParityError.invalid(message) }
    }

    private struct TokenMeasurement: Encodable {
        let id: String
        let text: String
        let unicodeScalars: [UInt32]
        let inputIDMismatchIndices: [Int]
        let attentionMaskMismatchIndices: [Int]
        let nativeIDs: [Int32]
        let referenceIDs: [Int32]
        let nativeMask: [Int32]
        let referenceMask: [Int32]
    }

    private struct Measurement: Encodable {
        let id: String
        let stage: String
        let reference: String
        let count: Int
        let maxAbs: Double
        let meanAbs: Double
        let cosine: Double?
        let referenceNorm: Double
        let candidateNorm: Double
        let maxAbsInclusive: Double?
        let minCosine: Double?
        let cosineExclusive: Bool
        let accepted: Bool
    }

    private struct Summary: Encodable {
        let group: String
        let comparisons: Int
        let rejected: Int
        let worstMaxAbs: Double
        let meanCaseMAE: Double
        let minimumCosine: Double?
    }

    private struct PreviewMeasurement: Encodable {
        let id: String
        let sourceSize: [Int]
        let previewSize: [Int]
        let orientedPreviewSize: [Int]
        let exifOrientation: UInt32
        let source: String
        let resampling: String
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let test: String
        let requestedComputeUnits: String
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let requireModels = ProcessInfo.processInfo.environment["IMAGEIQ_REQUIRE_MODELS"] == "1"
        var resourceGate: String?
        var modelBundle: String?
        var modelVersion: String?
        var exportNativeMarkers: [String: String] = [:]
        var fixtureCounts: [String: Int] = [:]
        var coverageNote: String?
        var expectedAppPredictions: [String: Int] = [:]
        var completedAppPredictions: [String: Int] = [:]
        var previews: [PreviewMeasurement] = []
        var tokens: [TokenMeasurement] = []
        var measurements: [Measurement] = []
        var summaries: [Summary] = []
        var completed = false
        var skipped = false
        var error: String?
    }

    private func withReport(computeUnits: String, body: (inout Report) throws -> Void) throws {
        var report = Report(test: name, requestedComputeUnits: computeUnits)
        defer { attach(report) }
        do {
            try body(&report)
            report.completed = true // Completion is NOT a claim that assertions passed.
        } catch {
            report.skipped = error is XCTSkip
            report.error = String(describing: error)
            throw error
        }
    }

    private func attach(_ original: Report) {
        var report = original
        let groups = Dictionary(grouping: report.measurements) { $0.stage + " / " + $0.reference }
        report.summaries = groups.keys.sorted().map { key in
            let values = groups[key] ?? []
            return Summary(group: key, comparisons: values.count, rejected: values.filter { !$0.accepted }.count,
                           worstMaxAbs: values.map(\.maxAbs).max() ?? 0,
                           meanCaseMAE: values.reduce(0) { $0 + $1.meanAbs } / Double(values.count),
                           minimumCosine: values.compactMap(\.cosine).min())
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let attachment = XCTAttachment(data: try encoder.encode(report), uniformTypeIdentifier: "public.json")
            attachment.name = "GeneratedModelParity-\(report.test)-\(report.requestedComputeUnits).json"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Could not attach native parity JSON: \(error)")
        }
    }
}