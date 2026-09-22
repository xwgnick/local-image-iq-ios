import Foundation
import CoreML
import ImageIO
import ImageIQCore

protocol PhotoEncoding: Sendable {
    func prepare() async throws -> ModelManifest
    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float]
    func image(preview: IndexingImage) async throws -> [Float]
    func text(_ text: String) async throws -> [Float]
}

/// Model loading, preprocessing and synchronous predictions never run on MainActor.
actor CoreMLEncoders: PhotoEncoding {
    private let bundle: Bundle
    private var loaded: Loaded?

    private struct Loaded {
        let manifest: ModelManifest
        let image: MLModel
        let text: MLModel
        let tokenizer: WordPieceTokenizer
    }

    init(bundle: Bundle = .main) { self.bundle = bundle }

    func prepare() throws -> ModelManifest { try load().manifest }

    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        try Task.checkCancellation()
        let models = try load()
        let tensor = try autoreleasepool { try ImagePreprocessor.tensor(data: data, orientation: orientation) }
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [models.manifest.imageInput: tensor])
        let output = try models.image.prediction(from: input)
        try Task.checkCancellation()
        return try projection(output, name: models.manifest.output)
    }

    func image(preview: IndexingImage) throws -> [Float] {
        try Task.checkCancellation()
        let models = try load()
        let tensor = try autoreleasepool {
            try ImagePreprocessor.tensor(image: preview.cgImage, orientation: preview.orientation)
        }
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [models.manifest.imageInput: tensor])
        let output = try models.image.prediction(from: input)
        try Task.checkCancellation()
        return try projection(output, name: models.manifest.output)
    }

    func text(_ text: String) throws -> [Float] {
        try Task.checkCancellation()
        let models = try load()
        let tokens = models.tokenizer.encode(text)
        guard tokens.inputIDs.count == 128, tokens.attentionMask.count == 128 else {
            throw AppFailure.modelContract("Tokenizer must produce 128 IDs and mask values.")
        }
        let ids = try Self.int32Tensor(tokens.inputIDs)
        let mask = try Self.int32Tensor(tokens.attentionMask)
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
        let output = try models.text.prediction(from: input)
        try Task.checkCancellation()
        return try projection(output, name: models.manifest.output)
    }

    static func int32Tensor(_ values: [Int32]) throws -> MLMultiArray {
        guard values.count == 128 else { throw AppFailure.modelContract("Expected 128 text input values.") }
        let tensor = try MLMultiArray(shape: [1, 128], dataType: .int32)
        for (index, value) in values.enumerated() { tensor[index] = NSNumber(value: value) }
        return tensor
    }

    private func projection(_ output: MLFeatureProvider, name: String) throws -> [Float] {
        guard let array = output.featureValue(for: name)?.multiArrayValue else {
            throw AppFailure.modelContract("Prediction did not contain its embedding output.")
        }
        return try Self.normalizedProjection(array)
    }

    static func normalizedProjection(_ array: MLMultiArray) throws -> [Float] {
        guard array.dataType == .float32, array.shape.map(\.intValue) == [1, 512] else {
            throw AppFailure.modelContract("Prediction output must be Float32 [1,512].")
        }
        // Coordinate subscripting respects strides; a scalar offset is not assumed
        // to correspond to a contiguous model output buffer.
        let values = (0..<512).map { array[[NSNumber(value: 0), NSNumber(value: $0)]].floatValue }
        return try EmbeddingValidation.normalizeProjection(values)
    }

    private func load() throws -> Loaded {
        if let loaded { return loaded }
        guard let manifestURL = BundleResources.url("model-manifest", extension: "json", bundle: bundle),
              let imageURL = BundleResources.url("ImageEncoder", extension: "mlmodelc", bundle: bundle),
              let textURL = BundleResources.url("TextEncoder", extension: "mlmodelc", bundle: bundle),
              let vocabURL = BundleResources.url("vocab", extension: "txt", bundle: bundle) else {
            throw AppFailure.modelsMissing("required bundled resources were not found")
        }
        do {
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            let vocabularyText = try String(contentsOf: vocabURL, encoding: .utf8)
            var vocabulary = vocabularyText.components(separatedBy: "\n").map {
                $0.hasSuffix("\r") ? String($0.dropLast()) : $0
            }
            if vocabulary.last == "" { vocabulary.removeLast() }
            let tokenizer = try WordPieceTokenizer(vocabulary: vocabulary, sequenceLength: manifest.sequenceLength)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let image = try MLModel(contentsOf: imageURL, configuration: configuration)
            let text = try MLModel(contentsOf: textURL, configuration: configuration)
            try Self.validate(model: image, inputs: ["pixel_values": ([1, 3, 224, 224], .float32)])
            try Self.validate(model: text, inputs: ["input_ids": ([1, 128], .int32), "attention_mask": ([1, 128], .int32)])
            try Task.checkCancellation()
            let result = Loaded(manifest: manifest, image: image, text: text, tokenizer: tokenizer)
            loaded = result
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.modelContract(error.localizedDescription)
        }
    }

    private static func validate(model: MLModel, inputs: [String: ([Int], MLMultiArrayDataType)]) throws {
        let description = model.modelDescription
        guard Set(description.inputDescriptionsByName.keys) == Set(inputs.keys),
              Set(description.outputDescriptionsByName.keys) == ["output_embedding"] else {
            throw AppFailure.modelContract("Unexpected model input or output names.")
        }
        for (name, specification) in inputs {
            try validate(feature: description.inputDescriptionsByName[name], name: name,
                         shape: specification.0, type: specification.1)
        }
        try validate(feature: description.outputDescriptionsByName["output_embedding"],
                     name: "output_embedding", shape: [1, 512], type: .float32)
    }

    private static func validate(feature: MLFeatureDescription?, name: String,
                                 shape: [Int], type: MLMultiArrayDataType) throws {
        guard let feature, !feature.isOptional, feature.type == .multiArray,
              let constraint = feature.multiArrayConstraint,
              constraint.shape.map(\.intValue) == shape, constraint.dataType == type else {
            throw AppFailure.modelContract("Wrong shape or type for \(name).")
        }
    }
}