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
    private static let pinnedMean: [Float] = [0.5, 0.5, 0.5]
    private static let pinnedStd: [Float] = [0.5, 0.5, 0.5]
    // Pin the source strings as well as IDs: replacing a Unicode/whitespace case
    // with an easier query must not silently preserve nominal fixture coverage.
    private static let queryCases: [String: String] = [
        "english": "A red square beside a blue checkerboard.",
        "chinese": "上海的蓝色天空，北京街道上的红色汽车。",
        "case": "Apple apple APPLE iPhone Straße STRASSE",
        "diacritics": "Café naïve résumé Ångström München İstanbul",
        "combining": "Cafe\u{0301} nai\u{0308}ve A\u{030A}ngstro\u{0308}m I\u{0307}stanbul",
        "punctuation": "Hello—world… (a/b), isn't it? ￥１２３！。",
        "special-tokens": "<eos> red <bos> <unk> <pad> <mask> blue",
        "empty": "",
        "whitespace-controls": " \tred\nblue\r\n绿色\u{00A0}sky\u{0000} ",
        "unknown-unicode": "🧩 🦄 𠀀",
        "long-word": String(repeating: "a", count: 130),
        "long-truncation": String(repeating: "red square 蓝色天空 café ", count: 80),
        "greek-sigma": "ΟΣ ΟΣΑ Σ σ ς ΟΣ\u{0301} Ελληνικά",
        "turkish-unicode-chinese": "I İ ı i I\u{0307} İSTANBUL 中文大小写 Straße ẞ",
        "gemma-turn-tokens": "<start_of_turn>USER\n你好<end_of_turn><eos><bos>",
        "literal-pad": "<pad>",
        "whitespace-only": " \t\r\n\u{00A0}\u{2003} ",
    ]
    private static let imageCases: [String: (size: [Int], orientation: UInt32)] = [
        "solid-rgb": ([224, 224], 1),
        "checker-nonsquare": ([319, 231], 1),
        "exif-rotate-6": ([321, 197], 6),
        "exif-mirror-2": ([197, 321], 2),
        "lowres-68x120": ([68, 120], 1),
        "lowres-112-portrait": ([112, 199], 1),
    ]

    func testGeneratedGemmaIDsAndMasksMatchAllCases() async throws {
        try await withAsyncReport(computeUnits: "not-used") { report in
            let resources = try self.resources(report: &report)
            let tokenizer = try await self.tokenizer(resources)
            for fixture in resources.text.cases {
                try autoreleasepool {
                    let native = try tokenizer.encode(fixture.text)
                    checkTokens(native, fixture: fixture, report: &report)
                }
            }
            try require(report.tokens.count == 17, "Expected exact IDs and masks for all 17 Gemma cases.")
        }
    }

    func testTextEncoderCPUReferenceAndNativeTokensParity() async throws {
        try await withAsyncReport(computeUnits: "cpuOnly") { report in
            let resources = try self.resources(report: &report)
            try await runText(resources, computeUnits: .cpuOnly, report: &report)
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

    func testGeneratedPairAllComputeUnitsParityWhenRequested() async throws {
        try await withAsyncReport(computeUnits: "all") { report in
            // Validate resource availability BEFORE the optional engine skip. A broken
            // model-enabled bundle must never be disguised as an optional-engine skip.
            let resources = try self.resources(report: &report)
            guard ProcessInfo.processInfo.environment["IMAGEIQ_TEST_ALL_COMPUTE_UNITS"] == "1" else {
                throw XCTSkip("Optional .all comparison: inject IMAGEIQ_TEST_ALL_COMPUTE_UNITS=1 into the test runner/host. CPU gates are separate tests.")
            }
            // Each helper releases its one model before the other role is loaded.
            try await runText(resources, computeUnits: .all, report: &report)
            try runImages(resources, computeUnits: .all, sameInput: true,
                          nativePreprocessing: true, report: &report)
        }
    }

    func testAppEncodersModelSizedPreviewAndAllTextReferenceParity() async throws {
        // The production actor uses .all. Unlike the optional engine comparison,
        // this app-API gate runs in EVERY model-enabled build, without MainActor.
        try await withAsyncReport(computeUnits: "all") { report in
            report.coverageNote = "Synthetic ImageIO raw CGImages, including actual 68x120 and 112x199 inputs, plus ImageIO EXIF -> app actor's 224x224 warp. No preview pre-resize. Not PhotoKit pixel identity, iCloud availability, or real-device quality."
            report.expectedAppPredictions = ["image.preview": 6, "text": 17]
            let fixtures = try self.resources(report: &report)
            try require(fixtures.images.cases.count == 6 && fixtures.text.cases.count == 17,
                        "App API parity requires exactly six image patterns and all seventeen text cases.")
            let encoders: any PhotoEncoding = CoreMLEncoders(bundle: fixtures.bundle)
            // Exercise actual coordinator coalescing without another model pair.
            // Scheduling can let a late caller see cached rather than shared;
            // exactly one caller may initialize, regardless of completion order.
            let preparations = try await withThrowingTaskGroup(of: (ModelManifest, LaunchTimingReport).self) { group in
                for _ in 0..<3 {
                    group.addTask {
                        let timing = LaunchTimingRecorder(kind: .cold)
                        let manifest = try await encoders.prepare(timing: timing)
                        return (manifest, try XCTUnwrap(timing.finish(.ready)))
                    }
                }
                var results: [(ModelManifest, LaunchTimingReport)] = []
                for try await result in group { results.append(result) }
                return results
            }
            XCTAssertEqual(preparations.count, 3)
            XCTAssertTrue(preparations.allSatisfy { $0.0.modelVersion == fixtures.manifest.modelVersion })
            let initializers = preparations.filter { !$0.1.components.isEmpty }
            XCTAssertEqual(initializers.count, 1, "Concurrent callers must share exactly one model initialization.")
            let (manifest, preparation) = try XCTUnwrap(initializers.first)
            for (_, report) in preparations where report.components.isEmpty {
                XCTAssertTrue(report.rows.map(\.stage) == [.entry, .sharedModels]
                              || report.rows.map(\.stage) == [.entry, .cachedModels])
            }
            try require(manifest.modelVersion == fixtures.manifest.modelVersion,
                        "The app actor must load the fixture owner's model pair.")
            XCTAssertEqual(preparation.rows.map(\.stage), [.entry, .resources, .parallelModels, .modelAssembly],
                           "The production protocol witness must record the parallel readiness barrier.")
            XCTAssertTrue(preparation.rows.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 })
            XCTAssertEqual(preparation.components.map(\.stage), [.tokenizer, .imageModel, .textModel])
            XCTAssertEqual(preparation.components.map(\.outcome), [.completed, .completed, .completed])
            XCTAssertTrue(preparation.components.allSatisfy {
                $0.startOffsetSeconds >= 0 && $0.seconds.isFinite && $0.seconds >= 0
                    && $0.startOffsetSeconds + $0.seconds <= preparation.totalSeconds + 0.000001
            })
            XCTAssertEqual(preparation.rows.reduce(0) { $0 + $1.seconds }, preparation.totalSeconds,
                           accuracy: 0.000001, "Overlapping child durations must never inflate the total.")
            let reused = LaunchTimingRecorder(kind: .retry)
            let reusedManifest = try await encoders.prepare(timing: reused)
            XCTAssertEqual(reusedManifest.modelVersion, manifest.modelVersion)
            let reusedReport = try XCTUnwrap(reused.finish(.ready))
            XCTAssertEqual(reusedReport.rows.map(\.stage), [.entry, .cachedModels],
                           "Already-loaded models must not be reported as newly loaded.")
            XCTAssertTrue(reusedReport.components.isEmpty)

            for fixture in fixtures.images.cases {
                let preview = try modelSizedPreview(fixture, resources: fixtures, report: &report)
                let projection = try await encoders.image(preview: preview)
                report.completedAppPredictions["image.preview", default: 0] += 1
                try checkAppProjection(projection, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
                                       id: fixture.id, stage: "image.appModelSizedPreview",
                                       minCosine: Self.nativeImageMinCosine, strictCosine: false, report: &report)
            }
            for fixture in fixtures.text.cases {
                let projection = try await encoders.text(fixture.text)
                report.completedAppPredictions["text", default: 0] += 1
                try checkAppProjection(projection, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
                                       id: fixture.id, stage: "text.appNativeTokens",
                                       minCosine: Self.conversionMinCosine, strictCosine: true, report: &report)
            }
            try require(report.completedAppPredictions == report.expectedAppPredictions
                        && report.previews.count == 6 && report.measurements.count == 58,
                        "Incomplete app API parity: expected 23 predictions and 58 comparisons (12 tensor comparisons, 46 normalized embedding gates).")
        }
    }

    func testIndexingImageFactoryAllSlotsConcurrentPreviewParity() async throws {
        // Exercise the production .all factory in every model-enabled build, not
        // the optional engine-comparison gate. No timing/hardware-overlap claim.
        try await withAsyncReport(computeUnits: "all") { report in
            let workerCount = PhotoIndexWorker.indexingWorkerCount
            try require(workerCount == 20, "Production indexing must use twenty image slots.")
            report.coverageNote = "Actual indexing factory, \(workerCount) retained image actors, six raw CGImage fixtures. Every slot predicts every fixture concurrently (120 predictions, 240 normalized embedding gates plus 12 tensor comparisons). Numerical coverage is not proof of physical GPU/ANE overlap or PhotoKit pixel identity."
            report.expectedAppPredictions = ["image.indexingPreview": workerCount * 6]
            let fixtures = try self.resources(report: &report)
            try require(fixtures.images.cases.count == 6,
                        "Indexing factory parity requires all six generated image cases.")
            // One owner loads one text model/tokenizer, not twenty paired encoders.
            let owner: any PhotoEncoding = CoreMLEncoders(bundle: fixtures.bundle)
            let encoders = try await owner.makeIndexingImageEncoders()
            try require(encoders.count == 20 && encoders.count == workerCount,
                        "The production indexing factory must return twenty image encoders.")
            try require(Set(encoders.map { ObjectIdentifier($0 as AnyObject) }).count == workerCount,
                        "Every production image slot must retain a distinct actor.")

            for fixture in fixtures.images.cases {
                try Task.checkCancellation()
                // Decode/inspect once per fixture, retaining its actual raw dimensions.
                let preview = try modelSizedPreview(fixture, resources: fixtures, report: &report)
                let outputs = try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
                    for (slot, encoder) in encoders.enumerated() {
                        group.addTask { [slot, encoder, preview] in
                            try Task.checkCancellation()
                            return (slot, try await encoder.image(preview: preview))
                        }
                    }
                    var outputs: [(Int, [Float])] = []
                    for try await output in group { outputs.append(output) }
                    return outputs
                }
                try Task.checkCancellation()
                // The first completed group has opened all twenty real image models;
                // reuse these same actors for the remaining five fixtures.
                try require(outputs.count == workerCount && Set(outputs.map { $0.0 }) == Set(encoders.indices),
                            "\(fixture.id): expected exactly one output from each of the \(workerCount) factory slots.")
                // Only the parent touches XCTest/helpers/report; children capture
                // just their slot, Sendable encoder and immutable preview.
                for (slot, projection) in outputs.sorted(by: { $0.0 < $1.0 }) {
                    report.completedAppPredictions["image.indexingPreview", default: 0] += 1
                    try checkAppProjection(projection, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
                                           id: fixture.id, stage: "image.appIndexingSlot\(slot)",
                                           minCosine: Self.nativeImageMinCosine, strictCosine: false, report: &report)
                }
            }
            try require(report.completedAppPredictions == report.expectedAppPredictions
                        && report.completedAppPredictions["image.indexingPreview"] == 120
                        && report.previews.count == 6 && report.measurements.count == 252
                        && report.measurements.filter { $0.stage.hasPrefix("image.appIndexingSlot") }.count == 240
                        && report.measurements.filter { $0.stage.hasPrefix("image.previewVs") }.count == 12,
                        "Incomplete indexing factory parity: expected 120 predictions and 252 comparisons (12 tensor comparisons, 240 normalized embedding gates).")
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
            let swapped = (5...8).contains(orientation.rawValue)
            let orientedSize = swapped ? [raw.height, raw.width] : [raw.width, raw.height]
            try require(orientedSize == fixture.orientedSize,
                        "Preview metadata must describe actual retained pixels: \(fixture.id)")
            // ModelSizedPreview names the app's model-input path, NOT an upscaled
            // test bitmap. In particular, keep 68x120 and 112x199 until the actor
            // preprocesses them. Source labels are synthetic, not PhotoKit callbacks.
            let preview = IndexingImage(cgImage: raw, orientation: orientation,
                                        source: min(raw.width, raw.height) < 224 ? .localReducedPreview : .localPreview)
            report.previews.append(PreviewMeasurement(id: fixture.id, sourceSize: [raw.width, raw.height],
                                                      previewSize: [preview.cgImage.width, preview.cgImage.height],
                                                      orientedPreviewSize: orientedSize,
                                                      exifOrientation: orientation.rawValue,
                                                      source: preview.source.rawValue,
                                                      resampling: "none; original raw CGImage retained"))
            // Independent byte-decoding path reads EXIF itself; the direct CGImage
            // tensor must be exactly equal, not merely have similar embeddings.
            let original = try ImagePreprocessor.values(data: data)
            let candidate = try imageValues(ImagePreprocessor.tensor(image: preview.cgImage, orientation: preview.orientation))
            try record(reference: original, candidate: candidate, id: fixture.id,
                       stage: "image.previewVsOriginalTensor", target: "native original-data preprocessing",
                       maxAbs: 0, report: &report)
            XCTAssertEqual(candidate, original, "\(fixture.id): direct raw CGImage and values(data:) must match exactly.")
            try record(reference: referenceTensor(fixture, resources: resources), candidate: candidate, id: fixture.id,
                       stage: "image.previewVsHFTensor", target: "HF/Pillow full NCHW tensor", report: &report)
            // Only HF/native tensor deltas are diagnostic. Actual app image
            // embeddings must still match both raw references at cosine >= .995.
            return preview
        }
    }

    private func checkAppProjection(_ projection: [Float], reference: [Float], exported: [Float],
                                    id: String, stage: String, minCosine: Double, strictCosine: Bool,
                                    report: inout Report) throws {
        try require(projection.count == 768 && projection.allSatisfy(\.isFinite),
                    "\(stage)/\(id): app output must contain 768 finite Float values.")
        let norm = sqrt(projection.reduce(0.0) { $0 + Double($1) * Double($1) })
        try require(abs(norm - 1) <= 1e-5, "\(stage)/\(id): app output must already be normalized; norm=\(norm).")
        // Do not normalize the candidate again and hide an app normalization bug.
        // Raw-output conversion gates remain in the direct model tests.
        for (target, reference) in [("referenceRaw", reference), ("coreMLRaw", exported)] {
            try record(reference: EmbeddingValidation.normalizeProjection(reference), candidate: projection,
                       id: id, stage: stage + ".normalized", target: target,
                       minCosine: minCosine, strictCosine: strictCosine, report: &report)
        }
    }

    private func runText(_ resources: Resources, computeUnits: MLComputeUnits,
                         report: inout Report) async throws {
        // Load asynchronously BEFORE entering any synchronous autoreleasepool.
        let tokenizer = try await self.tokenizer(resources)
        try autoreleasepool {
            let model = try loadModel(resources.textModel, computeUnits: computeUnits, inputs: [
                "input_ids": ([1, 64], .int32),
            ])
            for fixture in resources.text.cases {
                try autoreleasepool {
                    let native = try tokenizer.encode(fixture.text)
                    checkTokens(native, fixture: fixture, report: &report)
                    // Do BOTH predictions even when IDs disagree. The fixed input is
                    // the conversion control; a mismatch must not suppress that control.
                    let fixed = try predictText(model, ids: fixture.inputIDs)
                    try compareProjection(fixed, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
                                          id: fixture.id, stage: "text.fixedReferenceIDs",
                                          conversion: true, report: &report)
                    let generated = try predictText(model, ids: native.inputIDs)
                    try compareProjection(generated, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
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
                        try compareProjection(prediction, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
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
                        try compareProjection(prediction, reference: fixture.referenceRaw, exported: fixture.coreMLRaw,
                                              id: fixture.id, stage: "image.nativePreprocessing",
                                              conversion: false, report: &report)
                    }
                }
            }
        }
    }

    private func predictText(_ model: MLModel, ids: [Int32]) throws -> Prediction {
        // attentionMask is a golden-tokenizer assertion only, never a model input.
        try predict(model, inputs: ["input_ids": CoreMLEncoders.int32Tensor(ids)])
    }

    private func predict(_ model: MLModel, inputs: [String: MLMultiArray]) throws -> Prediction {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
        let output = try model.prediction(from: provider)
        let array = try XCTUnwrap(output.featureValue(for: "output_embedding")?.multiArrayValue)
        try require(array.dataType == .float32 && array.shape.map(\.intValue) == [1, 768],
                "Prediction must be Float32 [1,768].")
        // Coordinate subscripts honor non-contiguous output strides.
        let raw = (0..<768).map { array[[NSNumber(value: 0), NSNumber(value: $0)]].floatValue }
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
        try checkFeature(description.outputDescriptionsByName["output_embedding"], shape: [1, 768], type: .float32)
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
        // missing production models/tokenizer resources in the host app.
        guard let owner = bundles.first(where: {
            BundleResources.url(manifestName, extension: "json", bundle: $0) != nil
        }) else {
            let partial = bundles.contains { bundle in
                [("ImageEncoder", "mlmodelc"), ("TextEncoder", "mlmodelc"),
                 ("ImageEncoder", "mlpackage"), ("TextEncoder", "mlpackage"),
                 ("tokenizer", "json"), ("tokenizer_config", "json"),
                 ("tokenizer-parity", "json"), ("image-preprocess-parity", "json")].contains {
                    BundleResources.url($0.0, extension: $0.1, bundle: bundle) != nil
                }
            }
            if report.requireModels || partial {
                throw ParityError.invalid("Model-enabled/incomplete bundle has no model-manifest.json. IMAGEIQ_REQUIRE_MODELS=1 requires both bundled .mlmodelc encoders, tokenizer.json, tokenizer_config.json, and generated fixtures; absence is a failure.")
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
        let tokenizerURL = try required("tokenizer", "json", in: [owner])
        let configURL = try required("tokenizer_config", "json", in: [owner])
        let tokenizerDirectory = tokenizerURL.deletingLastPathComponent()
        try require(tokenizerDirectory == configURL.deletingLastPathComponent(),
                "Both tokenizer resources must be in the same directory, as required by the app loader.")
        // Test-only fixtures may be copied into the test bundle. Models and tokenizer
        // must belong to the selected manifest bundle; never mix two model pairs.
        let fixtureBundles = [owner] + bundles.filter { $0.bundleURL != owner.bundleURL }
        let textURL = try required("tokenizer-parity", "json", in: fixtureBundles)
        let imageURL = try required("image-preprocess-parity", "json", in: fixtureBundles)
        let text = try JSONDecoder().decode(TextDocument.self, from: Data(contentsOf: textURL))
        let images = try JSONDecoder().decode(ImageDocument.self, from: Data(contentsOf: imageURL))
        try require(text.schemaVersion == 2 && images.schemaVersion == 2
                    && text.modelVersion == manifest.modelVersion && images.modelVersion == manifest.modelVersion
                    && text.embeddingDimension == 768 && images.embeddingDimension == 768
                    && text.embeddingsAreRaw && images.embeddingsAreRaw && text.sequenceLength == 64
                    && text.textModel == manifest.textModel && images.imageModel == manifest.imageModel,
                    "Fixture header/source identity differs from the app manifest.")
        try require(text.tokenizerFile == "tokenizer.json" && text.tokenizerConfigFile == "tokenizer_config.json"
                    && text.tokenizerClass == "GemmaTokenizerFast",
                    "Expected the pinned Gemma fast-tokenizer JSON resources.")
        let options = text.tokenizerOptions
        let preprocessing = text.preprocessing
        try require(options.padding == "max_length" && options.truncation && options.max_length == 64
                    && options.add_special_tokens && options.return_attention_mask && !options.return_token_type_ids
                    && preprocessing.doLowerCase && !preprocessing.addBOSToken && preprocessing.addEOSToken
                    && preprocessing.sequenceLength == 64
                    && preprocessing.tokenizerFile == text.tokenizerFile
                    && preprocessing.tokenizerConfigFile == text.tokenizerConfigFile,
                    "Gemma lowercasing/EOS/padding/tokenizer fixture contract drifted.")
        // Check both hashes even in app-actor/image-only tests and before the optional
        // .all skip. Missing or mismatched runtime JSONs are failures, never fallbacks.
        _ = try checkedData(tokenizerURL, sha256: text.tokenizerSHA256)
        _ = try checkedData(configURL, sha256: text.configSHA256)
        try require(images.preprocessing.mean == Self.pinnedMean && images.preprocessing.std == Self.pinnedStd
                    && images.preprocessing.layout == "NCHW" && images.preprocessing.rescale == 1.0 / 255.0
                    && images.preprocessing.resample == 2
                    && images.preprocessing.resize == "warp directly to 224x224; do not preserve aspect ratio"
                    && images.preprocessing.crop == "none; cropXYWH [0,0,224,224] describes the full resized image",
                    "Image fixture bilinear warp/normalization contract drifted.")
        try requireCaseIDs(text.cases.map(\.id), matching: Set(Self.queryCases.keys))
        try requireCaseIDs(images.cases.map(\.id), matching: Set(Self.imageCases.keys))
        for fixture in text.cases {
            let expectedText = try XCTUnwrap(Self.queryCases[fixture.id])
            // String equality is canonically equivalent in Swift; UTF-8 equality
            // also pins decomposed accents and every whitespace/control scalar.
            try require(Array(fixture.text.utf8) == Array(expectedText.utf8),
                        "Generated query text changed: \(fixture.id)")
            try require(fixture.inputIDs.count == 64 && fixture.attentionMask.count == 64
                        && fixture.inputIDs.allSatisfy { (0..<256000).contains(Int($0)) }
                        && fixture.attentionMask.allSatisfy { $0 == 0 || $0 == 1 },
                        "Malformed token fixture: \(fixture.id)")
            let valid = fixture.attentionMask.reduce(0) { $0 + Int($1) }
            try require((1...64).contains(valid), "Expected at least the appended EOS: \(fixture.id)")
            let expectedMask = [Int32](repeating: 1, count: valid) + [Int32](repeating: 0, count: 64 - valid)
            try require(fixture.attentionMask == expectedMask && fixture.inputIDs[valid - 1] == 1
                        && fixture.inputIDs.dropFirst(valid).allSatisfy { $0 == 0 },
                        "Expected appended EOS and contiguous right padding: \(fixture.id)")
            if fixture.id == "empty" {
                try require(valid == 1 && fixture.inputIDs[0] == 1, "Empty input must be EOS plus 63 PADs.")
            }
            if fixture.id == "literal-pad" {
                try require(valid == 2 && fixture.inputIDs[0] == 0,
                            "Literal PAD is content with mask=1; it must precede appended EOS.")
            }
            if fixture.id == "long-truncation" {
                try require(valid == 64, "The long query must exercise the full 64-position truncation boundary.")
            }
            try checkRawVectors(fixture.referenceRaw, fixture.coreMLRaw)
        }
        let result = Resources(bundle: owner, manifest: manifest, imageModel: imageModel, textModel: textModel,
                               tokenizerDirectory: tokenizerDirectory, imageDocumentURL: imageURL, fixtureBundles: fixtureBundles,
                               text: text, images: images)
        for fixture in images.cases {
            let expected = try XCTUnwrap(Self.imageCases[fixture.id])
            try require(fixture.shape == Self.imageShape && fixture.layout == "NCHW"
                        && fixture.dtype == "float32-little-endian" && fixture.tensorBytes == Self.imageValueCount * 4
                        && fixture.sourceSize == expected.size && fixture.exifOrientation == expected.orientation
                        && fixture.resizedSize == [224, 224] && fixture.cropXYWH == [0, 0, 224, 224]
                        && fixture.pillowVsHFMaxAbs.isFinite && (0...1e-6).contains(fixture.pillowVsHFMaxAbs),
                        "Malformed image tensor fixture: \(fixture.id)")
            try checkRawVectors(fixture.referenceRaw, fixture.coreMLRaw)
            _ = try result.fixtureURL(fixture.image)
            _ = try result.fixtureURL(fixture.tensor)
        }
        report.modelVersion = manifest.modelVersion
        report.exportNativeMarkers = ["tokenizer": text.nativeParity, "imagePreprocessing": images.nativeParity]
        report.fixtureCounts = ["text": text.cases.count, "image": images.cases.count]
        return result
    }

    private func requireCaseIDs(_ ids: [String], matching required: Set<String>) throws {
        try require(Set(ids).count == ids.count && Set(ids) == required,
                    "Generated fixture IDs must match exactly; missing, extra, or duplicate Unicode/orientation/low-resolution cases cannot pass.")
    }

    private func tokenizer(_ resources: Resources) async throws -> SigLIPTokenizer {
        // Resource ownership, colocated files and both SHA-256s were gated above.
        // No network loader, compatibility tokenizer, or error-to-skip conversion.
        try await SigLIPTokenizer.load(directory: resources.tokenizerDirectory)
    }

    private struct Resources {
        let bundle: Bundle
        let manifest: ModelManifest
        let imageModel: URL
        let textModel: URL
        let tokenizerDirectory: URL
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
        let tokenizerFile: String
        let tokenizerConfigFile: String
        let tokenizerSHA256: String
        let configSHA256: String
        let tokenizerClass: String
        let tokenizerOptions: TokenizerOptions
        let preprocessing: TextPreprocessing
        let nativeParity: String
        let cases: [TextCase]
    }

    private struct TokenizerOptions: Decodable {
        let padding: String
        let truncation: Bool
        let max_length: Int
        let add_special_tokens: Bool
        let return_attention_mask: Bool
        let return_token_type_ids: Bool
    }

    private struct TextPreprocessing: Decodable {
        let tokenizerFile: String
        let tokenizerConfigFile: String
        let doLowerCase: Bool
        let addBOSToken: Bool
        let addEOSToken: Bool
        let sequenceLength: Int
    }

    private struct TextCase: Decodable {
        let id: String
        let text: String
        let inputIDs: [Int32]
        let attentionMask: [Int32]
        let referenceRaw: [Float]
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
        let resample: Int
        let resize: String
        let crop: String
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
        let referenceRaw: [Float]
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
        try require(fixture.resizedSize == [224, 224] && fixture.cropXYWH == [0, 0, 224, 224],
                "Fixture full-image 224x224 warp/no-crop geometry drifted: \(fixture.id)")
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
        XCTAssertEqual(native.inputIDs, fixture.inputIDs, "\(fixture.id): exact Gemma IDs; mismatched positions \(ids)")
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
            try require(vector.count == 768 && vector.allSatisfy(\.isFinite)
                        && vector.contains { $0 != 0 }, "Expected finite, nonzero raw 768D fixture vectors.")
        }
    }

    private func compareProjection(_ prediction: Prediction, reference: [Float], exported: [Float],
                                   id: String, stage: String, conversion: Bool, report: inout Report) throws {
        for (target, reference) in [("referenceRaw", reference), ("coreMLRaw", exported)] {
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
        let schemaVersion = 2
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

    /// Async inout access belongs to this local report, never to a synchronous
    /// closure or autoreleasepool. All errors still attach diagnostics and rethrow.
    private func withAsyncReport(computeUnits: String, body: (inout Report) async throws -> Void) async throws {
        var report = Report(test: name, requestedComputeUnits: computeUnits)
        defer { attach(report) }
        do {
            try await body(&report)
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