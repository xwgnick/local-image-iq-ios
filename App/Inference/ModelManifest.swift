import Foundation
import ImageIQCore

struct ModelManifest: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        let id: String
        let revision: String
    }

    let schemaVersion: Int
    let modelVersion: String
    let dimension: Int
    let sequenceLength: Int
    let imageSize: Int
    let imageModel: Source
    let textModel: Source
    let imageInput: String
    let textInputs: [String]
    let output: String

    func validate() throws {
        guard schemaVersion == 1, !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              dimension == 512, sequenceLength == 128, imageSize == 224,
              imageInput == "pixel_values", textInputs == ["input_ids", "attention_mask"],
              output == "output_embedding",
              imageModel.id == "sentence-transformers/clip-ViT-B-32",
              imageModel.revision == "327ab6726d33c0e22f920c83f2ff9e4bd38ca37f",
              textModel.id == "sentence-transformers/clip-ViT-B-32-multilingual-v1",
              textModel.revision == "58edf8cada9e398793dca955574a48cbb7f18be2" else {
            throw AppFailure.modelContract("The manifest does not match the pinned paired-model contract.")
        }
    }
}

enum AppFailure: LocalizedError {
    case modelsMissing(String)
    case modelContract(String)
    case storage(String)
    case photo(String)
    case cloudOnly
    case permission
    case places(String)

    var errorDescription: String? {
        switch self {
        case .modelsMissing(let detail):
            return "Models unavailable: \(detail). Install an app build containing both compiled encoders, model-manifest.json and vocab.txt. Photo authorization remains available."
        case .modelContract(let detail): return "Model contract mismatch: \(detail) Install a matching model-enabled build."
        case .storage(let detail): return "Local cache error: \(detail) Retry, or clear the local index and rebuild it."
        case .photo(let detail): return "Photo unavailable: \(detail)"
        case .cloudOnly: return "No local preview is available for this photo. On-demand iCloud access is required for this item; the rest of the library does not need to be downloaded first."
        case .permission: return "Allow access to photos, or select photos using Limited Access."
        case .places(let detail): return "Offline places unavailable: \(detail) Image search still works without place labels."
        }
    }
}

enum EmbeddingValidation {
    static func normalizeProjection(_ values: [Float]) throws -> [Float] {
        guard values.count == 512, values.allSatisfy(\.isFinite) else {
            throw AppFailure.modelContract("Expected 512 finite projection values.")
        }
        let normalized = try EmbeddingMath.normalized(values)
        try validateUnit(normalized)
        return normalized
    }

    static func validateUnit(_ values: [Float]) throws {
        guard values.count == 512, values.allSatisfy(\.isFinite) else {
            throw AppFailure.modelContract("Invalid cached embedding dimensions or values.")
        }
        let normSquared = try EmbeddingMath.dot(values, values)
        guard normSquared.isFinite, abs(normSquared - 1) < 0.001 else {
            throw AppFailure.modelContract("Expected a normalized, nonzero embedding.")
        }
    }
}

enum BundleResources {
    static func url(_ name: String, extension ext: String, bundle: Bundle = .main) -> URL? {
        for directory in [Optional<String>.none, "Models", "Resources/Models", "Resources"] {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: directory) {
                return url
            }
        }
        return nil
    }
}