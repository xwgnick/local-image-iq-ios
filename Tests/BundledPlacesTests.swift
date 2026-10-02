import Foundation
import CryptoKit
import XCTest
@testable import LocalImageIQ

/// The app-host bundle is the subject, not synthetic rectangles or a source-tree
/// fallback. CI builds this pack even without models: missing resources MUST fail.
final class BundledPlacesTests: XCTestCase {
    private let countries = ["China", "France", "Germany", "Netherlands"]

    func testBundledPackMatchesManifestBytesHashAndAcceptedFeatureCount() throws {
        let packURL = try resource("Places", extension: "geojson")
        let manifestURL = try resource("places-manifest", extension: "json")
        let bytes = try Data(contentsOf: packURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let metadata = try JSONDecoder().decode(PackMetadata.self, from: bytes)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.generated.file, "Places.geojson")
        XCTAssertEqual(manifest.generated.bytes, bytes.count)
        XCTAssertEqual(manifest.generated.sha256.count, 64)
        XCTAssertEqual(sha, manifest.generated.sha256.lowercased(), "Hash the artifact bytes, not reserialized JSON")
        XCTAssertEqual(metadata.type, "FeatureCollection")
        XCTAssertEqual(metadata.coverageCountries.sorted(), countries)
        XCTAssertEqual(manifest.coverageCountries.sorted(), countries)
        XCTAssertGreaterThan(manifest.generated.featureCount, 0)
        XCTAssertEqual(metadata.features.count, manifest.generated.featureCount)

        let resolver = OfflinePlaceResolver.bundled()
        let sameBytes = try OfflinePlaceResolver(data: bytes)
        let lightweight = PlacePackMetadata.bundled()
        XCTAssertEqual(resolver.version, sameBytes.version, "Production lookup must parse the verified artifact")
        XCTAssertEqual(manifest.runtime.schemaVersion, 1)
        XCTAssertEqual(manifest.runtime.version, sameBytes.version,
                   "Manifest identity must retain the exact raycast-v1 FNV of artifact bytes")
        XCTAssertEqual(manifest.runtime.coverageDescription, sameBytes.coverageDescription)
        XCTAssertEqual(lightweight.version, sameBytes.version, "Lightweight cache filtering must not invalidate existing geography")
        XCTAssertEqual(lightweight.coverageDescription, sameBytes.coverageDescription)
        XCTAssertEqual(resolver.coverageCountries.sorted(), countries)
        XCTAssertGreaterThan(resolver.featureCount, 0, resolver.coverageDescription)
        XCTAssertEqual(resolver.featureCount, manifest.generated.featureCount,
                       "A readable JSON pack with skipped geometry must not silently pass")
        XCTAssertTrue(resolver.coverageDescription.contains("0 unsupported/invalid features skipped."))
        XCTAssertTrue(resolver.coverageDescription.contains("historical"))
        XCTAssertTrue(resolver.coverageDescription.contains("not live GPS or global coverage"))
    }

    func testPublicCityCoordinatesResolveCountriesButNewYorkIsOutsideCoverage() throws {
        let resolver = OfflinePlaceResolver.bundled()
        XCTAssertGreaterThan(resolver.featureCount, 0, resolver.coverageDescription)
        // Public reference points only; never sourced from Photos. Administrative
        // names/case can be historical, so assert the country rather than a city.
        let examples: [(city: String, longitude: Double, latitude: Double, country: String)] = [
            ("Paris", 2.3522, 48.8566, "France"),
            ("Berlin", 13.405, 52.52, "Germany"),
            ("Amsterdam", 4.9041, 52.3676, "Netherlands"),
            ("Beijing", 116.4074, 39.9042, "China")
        ]
        for example in examples {
            let label = try XCTUnwrap(resolver.label(longitude: example.longitude, latitude: example.latitude),
                                      "Missing bundled coverage for public reference point: \(example.city)")
            XCTAssertNotNil(label.range(of: example.country, options: .caseInsensitive), example.city)
        }
        XCTAssertNil(resolver.label(longitude: -74, latitude: 40.7), "No nearest-place or global-coverage fallback")
    }

    private func resource(_ name: String, extension ext: String) throws -> URL {
        let directories: [String?] = [nil, "Places", "Resources/Places"]
        let url = directories.lazy.compactMap {
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: $0)
        }.first
        return try XCTUnwrap(url, "Required bundled \(name).\(ext) missing, including in model-free CI")
    }

    private struct Manifest: Decodable {
        let schemaVersion: Int
        let coverageCountries: [String]
        let generated: Artifact
        let runtime: Runtime
        struct Runtime: Decodable {
            let schemaVersion: Int
            let version: String
            let coverageDescription: String
        }
        struct Artifact: Decodable {
            let file: String
            let bytes: Int
            let sha256: String
            let featureCount: Int
        }
    }

    private struct PackMetadata: Decodable {
        let type: String
        let coverageCountries: [String]
        let features: [Feature]
        // Count entries without retaining a second copy of every coordinate.
        struct Feature: Decodable {}
    }
}