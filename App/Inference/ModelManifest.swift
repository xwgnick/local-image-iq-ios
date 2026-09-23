import Foundation
import ImageIQCore

struct ModelManifest: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        let id: String
        let revision: String
    }

    let schemaVersion: Int
    /// The exporter supplies siglip2-b16-224-v1-<hash>; fixtures may use any nonempty version.
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
        guard schemaVersion == 2, !modelVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              dimension == 768, sequenceLength == 64, imageSize == 224,
              imageInput == "pixel_values", textInputs == ["input_ids"],
              output == "output_embedding",
              imageModel.id == "google/siglip2-base-patch16-224",
              imageModel.revision == "75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2",
              textModel == imageModel else {
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
            return "Models unavailable: \(detail). Install an app build containing both compiled encoders, model-manifest.json, tokenizer.json and tokenizer_config.json. Photo authorization remains available."
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
        guard values.count == 768, values.allSatisfy(\.isFinite) else {
            throw AppFailure.modelContract("Expected 768 finite projection values.")
        }
        let normalized = try EmbeddingMath.normalized(values)
        try validateUnit(normalized)
        return normalized
    }

    /// Only legacy cache reads explicitly override the active model dimension.
    static func validateUnit(_ values: [Float], dimension: Int = 768) throws {
        guard values.count == dimension, values.allSatisfy(\.isFinite) else {
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