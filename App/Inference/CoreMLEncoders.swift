import Foundation
import CoreML
import ImageIO
import ImageIQCore

protocol PhotoImageEncoding: Sendable {
    func image(preview: IndexingImage) async throws -> [Float]
}

protocol PhotoEncoding: PhotoImageEncoding {
    func inspectResources() async throws -> ModelManifest
    func prepare() async throws -> ModelManifest
    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float]
    func text(_ text: String) async throws -> [Float]
    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding]
}

extension PhotoEncoding {
    /// Compatibility for injected mocks; production inspects metadata without loading models.
    func inspectResources() async throws -> ModelManifest { try await prepare() }

    /// Compatibility for injected mocks; production encoders must supply independent actors.
    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        try Task.checkCancellation()
        return [any PhotoImageEncoding](repeating: self, count: PhotoIndexWorker.indexingWorkerCount)
    }
}

/// Model loading, preprocessing and synchronous predictions never run on MainActor.
actor CoreMLEncoders: PhotoEncoding {
    private let bundle: Bundle
    private var loaded: Loaded?
    private var loadingTask: Task<Void, Error>?

    private struct ModelResources {
        let manifest: ModelManifest
        let imageURL: URL
        let textURL: URL
        let tokenizerDirectory: URL
    }

    private struct Loaded {
        let manifest: ModelManifest
        let imageURL: URL
        let image: CoreMLImageEncoder
        let text: MLModel
        let tokenizer: SigLIPTokenizer
    }

    init(bundle: Bundle = .main) { self.bundle = bundle }

    /// Reads only the manifest and checks resource URLs, never runtime model/tokenizer payloads.
    func inspectResources() async throws -> ModelManifest { try modelResources().manifest }

    func prepare() async throws -> ModelManifest { try await load().manifest }

    func image(data: Data, orientation: CGImagePropertyOrientation) async throws -> [Float] {
        try Task.checkCancellation()
        let models = try await load()
        let embedding = try await models.image.image(data: data, orientation: orientation)
        try Task.checkCancellation()
        return embedding
    }

    func image(preview: IndexingImage) async throws -> [Float] {
        try Task.checkCancellation()
        let models = try await load()
        let embedding = try await models.image.image(preview: preview)
        try Task.checkCancellation()
        return embedding
    }

    func makeIndexingImageEncoders() async throws -> [any PhotoImageEncoding] {
        try Task.checkCancellation()
        let models = try await load()
        try Task.checkCancellation()
        // Reuse the already-loaded primary image model for the first slot.
        // Only the returned worker array owns the additional actors. Their models
        // load on first prediction; cache-only indexing loads no extra image models.
        // Each additional slot is a distinct actor with its own MLModel, not another
        // paired encoder: the owner still has just one text model and tokenizer.
        var encoders: [any PhotoImageEncoding] = [models.image]
        for _ in 1..<PhotoIndexWorker.indexingWorkerCount {
            encoders.append(CoreMLImageEncoder(modelURL: models.imageURL, manifest: models.manifest))
        }
        try Task.checkCancellation()
        return encoders
    }

    func text(_ text: String) async throws -> [Float] {
        try Task.checkCancellation()
        let models = try await load()
        let tokens = try models.tokenizer.encode(text)
        guard tokens.inputIDs.count == 64, tokens.attentionMask.count == 64 else {
            throw AppFailure.modelContract("Tokenizer must produce 64 IDs and mask values.")
        }
        try Task.checkCancellation()
        let ids = try Self.int32Tensor(tokens.inputIDs)
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids])
        let output = try predict(model: models.text, input: input)
        try Task.checkCancellation()
        return try Self.projection(output, name: models.manifest.output)
    }

    static func int32Tensor(_ values: [Int32]) throws -> MLMultiArray {
        guard values.count == 64 else { throw AppFailure.modelContract("Expected 64 text input values.") }
        let tensor = try MLMultiArray(shape: [1, 64], dataType: .int32)
        for (index, value) in values.enumerated() { tensor[index] = NSNumber(value: value) }
        return tensor
    }

    /// Keep overload resolution in a synchronous context, even when callers are async.
    private func predict(model: MLModel, input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    fileprivate nonisolated static func projection(_ output: MLFeatureProvider, name: String) throws -> [Float] {
        guard let array = output.featureValue(for: name)?.multiArrayValue else {
            throw AppFailure.modelContract("Prediction did not contain its embedding output.")
        }
        return try Self.normalizedProjection(array)
    }

    nonisolated static func normalizedProjection(_ array: MLMultiArray) throws -> [Float] {
        guard array.dataType == .float32, array.shape.map(\.intValue) == [1, 768] else {
            throw AppFailure.modelContract("Prediction output must be Float32 [1,768].")
        }
        // Coordinate subscripting respects strides; a scalar offset is not assumed
        // to correspond to a contiguous model output buffer.
        let values = (0..<768).map { array[[NSNumber(value: 0), NSNumber(value: $0)]].floatValue }
        return try EmbeddingValidation.normalizeProjection(values)
    }

    private func load() async throws -> Loaded {
        try Task.checkCancellation()
        if let loaded { return loaded }
        let task: Task<Void, Error>
        if let loadingTask {
            task = loadingTask
        } else {
            // Installed before the first suspension: actor reentrancy cannot start a
            // second load. One cancelled caller does not cancel other callers' setup.
            task = Task { try await self.loadBundledModels() }
            loadingTask = task
        }
        try await task.value
        try Task.checkCancellation()
        guard let loaded else { throw AppFailure.modelContract("Model initialization did not complete.") }
        return loaded
    }

    private func modelResources() throws -> ModelResources {
        try Task.checkCancellation()
        guard let manifestURL = BundleResources.url("model-manifest", extension: "json", bundle: bundle),
              let imageURL = BundleResources.url("ImageEncoder", extension: "mlmodelc", bundle: bundle),
              let textURL = BundleResources.url("TextEncoder", extension: "mlmodelc", bundle: bundle),
              let tokenizerURL = BundleResources.url("tokenizer", extension: "json", bundle: bundle),
              let tokenizerConfigURL = BundleResources.url("tokenizer_config", extension: "json", bundle: bundle) else {
            throw AppFailure.modelsMissing("required bundled resources were not found")
        }
        let tokenizerDirectory = tokenizerURL.deletingLastPathComponent()
        guard tokenizerDirectory == tokenizerConfigURL.deletingLastPathComponent() else {
            throw AppFailure.modelContract("Both tokenizer files must be bundled in the same directory.")
        }
        do {
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            try Task.checkCancellation()
            return ModelResources(manifest: manifest, imageURL: imageURL, textURL: textURL,
                                  tokenizerDirectory: tokenizerDirectory)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.modelContract(error.localizedDescription)
        }
    }

    private func loadBundledModels() async throws {
        // Only the initializer clears its task. Waiters must not clear a newer retry.
        defer { loadingTask = nil }
        do {
            let resources = try modelResources()
            let manifest = resources.manifest
            let tokenizer = try await SigLIPTokenizer.load(directory: resources.tokenizerDirectory)
            let image = CoreMLImageEncoder(modelURL: resources.imageURL, manifest: manifest)
            try await image.prepare()
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let text = try MLModel(contentsOf: resources.textURL, configuration: configuration)
            try Self.validate(model: text, inputs: ["input_ids": ([1, 64], .int32)])
            try Task.checkCancellation()
            loaded = Loaded(manifest: manifest, imageURL: resources.imageURL, image: image,
                            text: text, tokenizer: tokenizer)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.modelContract(error.localizedDescription)
        }
    }

    fileprivate nonisolated static func validate(model: MLModel, inputs: [String: ([Int], MLMultiArrayDataType)]) throws {
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
                     name: "output_embedding", shape: [1, 768], type: .float32)
    }

    private nonisolated static func validate(feature: MLFeatureDescription?, name: String,
                                            shape: [Int], type: MLMultiArrayDataType) throws {
        guard let feature, !feature.isOptional, feature.type == .multiArray,
              let constraint = feature.multiArrayConstraint,
              constraint.shape.map(\.intValue) == shape, constraint.dataType == type else {
            throw AppFailure.modelContract("Wrong shape or type for \(name).")
        }
    }
}

/// Each actor owns one image model. No prediction or preprocessing suspends, and
/// separate indexing actors can predict without serializing through the coordinator.
private actor CoreMLImageEncoder: PhotoImageEncoding {
    private let modelURL: URL
    private let manifest: ModelManifest
    private var model: MLModel?

    init(modelURL: URL, manifest: ModelManifest) {
        self.modelURL = modelURL
        self.manifest = manifest
    }

    func prepare() throws {
        _ = try load()
    }

    func image(data: Data, orientation: CGImagePropertyOrientation) throws -> [Float] {
        let model = try load()
        let tensor = try autoreleasepool {
            try ImagePreprocessor.tensor(data: data, orientation: orientation)
        }
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.imageInput: tensor])
        let output = try model.prediction(from: input)
        try Task.checkCancellation()
        return try CoreMLEncoders.projection(output, name: manifest.output)
    }

    func image(preview: IndexingImage) throws -> [Float] {
        let model = try load()
        let tensor = try autoreleasepool {
            try ImagePreprocessor.tensor(image: preview.cgImage, orientation: preview.orientation)
        }
        try Task.checkCancellation()
        let input = try MLDictionaryFeatureProvider(dictionary: [manifest.imageInput: tensor])
        let output = try model.prediction(from: input)
        try Task.checkCancellation()
        return try CoreMLEncoders.projection(output, name: manifest.output)
    }

    private func load() throws -> MLModel {
        try Task.checkCancellation()
        if let model { return model }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: configuration)
            try CoreMLEncoders.validate(model: model, inputs: ["pixel_values": ([1, 3, 224, 224], .float32)])
            try Task.checkCancellation()
            self.model = model
            return model
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AppFailure {
            throw error
        } catch {
            throw AppFailure.modelContract(error.localizedDescription)
        }
    }
}