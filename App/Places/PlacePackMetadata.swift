import Foundation

/// Lightweight readiness/cache identity. Only the small manifest is decoded;
/// geometry is opened by the resolver during explicit indexing/diagnostics.
/// Packaging verifies SHA-256 and the exact raycast-v1 FNV against GeoJSON bytes.
/// A well-formed but stale manifest cannot be detected here without breaking the
/// no-geometry-read contract. Missing/invalid metadata never falls back to parsing.
struct PlacePackMetadata: Sendable {
    let version: String
    let coverageDescription: String

    // Intentionally accessible for an injected resolver's exact metadata.
    init(version: String, coverageDescription: String) {
        self.version = version
        self.coverageDescription = coverageDescription
    }

    static func unavailable(_ reason: String) -> Self {
        Self(version: "places-unavailable", coverageDescription: reason)
    }

    static func bundled(bundle: Bundle = .main) -> Self {
        // Match the resolver's resource selection, then require a colocated
        // manifest rather than pairing metadata from a different resource folder.
        guard let geometryURL = BundleResources.url("Places", extension: "geojson", bundle: bundle)
            ?? bundle.url(forResource: "Places", withExtension: "geojson", subdirectory: "Places")
            ?? bundle.url(forResource: "Places", withExtension: "geojson", subdirectory: "Resources/Places") else {
            return unavailable("No offline boundary pack bundled; location labels are unavailable.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: geometryURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return unavailable("Offline boundary pack file is unavailable.")
        }
        let manifestURL = geometryURL.deletingLastPathComponent().appendingPathComponent("places-manifest.json")
        guard let bytes = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              manifest.schemaVersion == 1, manifest.generated.file == "Places.geojson",
              manifest.runtime.schemaVersion == 1,
              isRuntimeVersion(manifest.runtime.version),
              !manifest.runtime.coverageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable("Offline boundary pack metadata is missing or invalid.")
        }
        return Self(version: manifest.runtime.version, coverageDescription: manifest.runtime.coverageDescription)
    }

    private static func isRuntimeVersion(_ version: String) -> Bool {
        let prefix = "raycast-v1-"
        guard version.hasPrefix(prefix) else { return false }
        let hex = String(version.dropFirst(prefix.count))
        guard let value = UInt64(hex, radix: 16) else { return false }
        // Canonical lowercase, no leading zeros, 1...16 digits (including zero).
        return String(value, radix: 16) == hex
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let generated: Generated
        let runtime: Runtime

        struct Generated: Decodable { let file: String }
        struct Runtime: Decodable {
            let schemaVersion: Int
            let version: String
            let coverageDescription: String
        }
    }
}