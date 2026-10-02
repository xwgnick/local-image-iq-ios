import Foundation
import XCTest
@testable import LocalImageIQ

final class PlacePackMetadataTests: XCTestCase {
    // Exact UTF-8 bytes and final LF shared with Python/Node fixed-vector tests.
    private static let geometry = Data((#"{"type":"FeatureCollection","coverageCountries":["Synthetic"],"features":[{"type":"Feature","properties":{"label":"Square, Synthetic","level":"ADM1"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}]}"# + "\n").utf8)
    private static let version = "raycast-v1-4b2d9ec5135d4ccc"
    private static let coverage = "Offline country coverage: Synthetic. Administrative boundaries may be incomplete or historical; not live GPS or global coverage. 1 features; 0 unsupported/invalid features skipped."
    private var validRuntime: [String: Any] {
        ["schemaVersion": 1, "version": Self.version, "coverageDescription": Self.coverage]
    }
    private var validManifest: [String: Any] {
        ["schemaVersion": 1, "generated": ["file": "Places.geojson"], "runtime": validRuntime]
    }

    func testAccessibleInitializerPreservesInjectedResolverIdentityAndCoverage() {
        let metadata = PlacePackMetadata(version: "injected-resolver", coverageDescription: "Injected coverage")
        XCTAssertEqual(metadata.version, "injected-resolver")
        XCTAssertEqual(metadata.coverageDescription, "Injected coverage")
        let unavailable = PlacePackMetadata.unavailable("No pack for this test")
        XCTAssertEqual(unavailable.version, "places-unavailable")
        XCTAssertEqual(unavailable.coverageDescription, "No pack for this test")
    }

    func testSyntheticManifestExactlyMatchesRealResolverAndFixedFNVVector() throws {
        let bundle = try makeBundle(manifest: data(validManifest))
        let metadata = PlacePackMetadata.bundled(bundle: bundle)
        let resolver = try OfflinePlaceResolver(data: Self.geometry)
        XCTAssertEqual(resolver.version, Self.version, "Must retain the existing raycast-v1 byte identity")
        XCTAssertEqual(resolver.featureCount, 1)
        XCTAssertEqual(resolver.label(longitude: 0.5, latitude: 0.5), "Square, Synthetic")
        XCTAssertEqual(metadata.version, resolver.version)
        XCTAssertEqual(metadata.coverageDescription, resolver.coverageDescription)
    }

    func testManifestOnlyInspectionSucceedsWithInvalidOrEmptyGeoJSON() throws {
        for geometry in [Data("not GeoJSON at all".utf8), Data()] {
            let bundle = try makeBundle(manifest: data(validManifest), geometry: geometry)
            XCTAssertThrowsError(try OfflinePlaceResolver(data: geometry))
            let metadata = PlacePackMetadata.bundled(bundle: bundle)
            XCTAssertEqual(metadata.version, Self.version, "Inspection must not parse or hash geometry")
            XCTAssertEqual(metadata.coverageDescription, Self.coverage)
        }
    }

    func testStaleButWellFormedVersionIsTrustedOnlyAtRuntimeNotAnIntegrityCheck() throws {
        let changed = Self.geometry + Data(" ".utf8)
        let resolver = try OfflinePlaceResolver(data: changed)
        XCTAssertNotEqual(resolver.version, Self.version, "Even whitespace changes the real cache identity")
        let bundle = try makeBundle(manifest: data(validManifest), geometry: changed)
        let metadata = PlacePackMetadata.bundled(bundle: bundle)
        XCTAssertEqual(metadata.version, Self.version, "Packaging, not this lightweight loader, detects stale FNV")
        XCTAssertNotEqual(metadata.version, resolver.version)
    }

    func testMissingOrCorruptManifestNeverFallsBackToValidGeometry() throws {
        let manifests: [Data?] = [nil, Data(), Data("{".utf8), Data("[]".utf8), Data("null".utf8),
                                  Data("not JSON".utf8), Data([0xff, 0xfe])]
        for manifest in manifests {
            let bundle = try makeBundle(manifest: manifest)
            assertUnavailable(PlacePackMetadata.bundled(bundle: bundle))
        }
    }

    func testMissingGeometryOrDirectoryCannotAdvertiseAvailableMetadata() throws {
        let missing = try makeBundle(manifest: data(validManifest), geometry: nil)
        assertUnavailable(PlacePackMetadata.bundled(bundle: missing))
        let directory = try makeBundle(manifest: data(validManifest), geometryIsDirectory: true)
        assertUnavailable(PlacePackMetadata.bundled(bundle: directory))
    }

    func testMissingRequiredTopLevelFieldsAndUnsupportedSchemaAreUnavailable() throws {
        for key in ["schemaVersion", "generated", "runtime"] {
            var manifest = validManifest
            manifest.removeValue(forKey: key)
            assertUnavailable(PlacePackMetadata.bundled(bundle: try makeBundle(manifest: data(manifest))))
        }
        for invalid in [0, 2, "1", true, NSNull()] as [Any] {
            var manifest = validManifest
            manifest["schemaVersion"] = invalid
            assertUnavailable(PlacePackMetadata.bundled(bundle: try makeBundle(manifest: data(manifest))))
        }
        let invalidContainers: [Any] = [NSNull(), "runtime", [Any](), [String: Any]()]
        for invalid in invalidContainers {
            var manifest = validManifest
            manifest["runtime"] = invalid
            assertUnavailable(PlacePackMetadata.bundled(bundle: try makeBundle(manifest: data(manifest))))
        }
    }

    func testGeneratedFilenameMustBindMetadataToExactPackName() throws {
        for generated in [[String: Any](), ["file": "Other.geojson"], ["file": "places.geojson"],
                          ["file": "Places.geojson\n"], ["file": NSNull()]] {
            var manifest = validManifest
            manifest["generated"] = generated
            assertUnavailable(PlacePackMetadata.bundled(bundle: try makeBundle(manifest: data(manifest))))
        }
    }

    func testMissingRuntimeFieldsAndInvalidFieldTypesAreUnavailable() throws {
        for key in ["schemaVersion", "version", "coverageDescription"] {
            var runtime = validRuntime
            runtime.removeValue(forKey: key)
            assertUnavailable(try load(runtime: runtime))
        }
        let invalidChanges: [[String: Any]] = [
            ["schemaVersion": 2], ["schemaVersion": "1"], ["schemaVersion": true],
            ["version": 123], ["version": NSNull()],
            ["coverageDescription": ""], ["coverageDescription": " \n\t"],
            ["coverageDescription": 123], ["coverageDescription": NSNull()]
        ]
        for changes in invalidChanges {
            let runtime = validRuntime.merging(changes) { _, replacement in replacement }
            assertUnavailable(try load(runtime: runtime))
        }
    }

    func testVersionMustBeCanonicalRaycastV1UInt64Hex() throws {
        for version in ["", "places-unavailable", "raycast-v2-abc", "raycast-v1-ABC", "raycast-v1-",
                        "raycast-v1-01", "raycast-v1-0000000000000000", "raycast-v1-10000000000000000",
                        "raycast-v1-abc\n", " raycast-v1-abc", "raycast-v1-+a", "raycast-v1--1",
                        "raycast-v1-0xff", "raycast-v1-g", String(repeating: "a", count: 64)] {
            var runtime = validRuntime
            runtime["version"] = version
            assertUnavailable(try load(runtime: runtime))
        }
        for version in ["raycast-v1-0", "raycast-v1-f", "raycast-v1-8985907b541d342", "raycast-v1-ffffffffffffffff"] {
            var runtime = validRuntime
            runtime["version"] = version
            XCTAssertEqual(try load(runtime: runtime).version, version)
        }
    }

    func testSupportedBundleLayoutsFindColocatedManifest() throws {
        for folder in ["", "Places", "Resources/Places"] {
            let bundle = try makeBundle(manifest: data(validManifest), folder: folder)
            XCTAssertEqual(PlacePackMetadata.bundled(bundle: bundle).version, Self.version, folder)
        }
    }

    func testDifferentBundlesDoNotShareGlobalMetadataCache() throws {
        let first = try makeBundle(manifest: data(validManifest))
        var secondManifest = validManifest
        secondManifest["runtime"] = ["schemaVersion": 1, "version": "raycast-v1-da2e3970db8ea20e",
                                     "coverageDescription": Self.coverage]
        let second = try makeBundle(manifest: data(secondManifest), geometry: Data(Self.geometry.dropLast()))
        XCTAssertEqual(PlacePackMetadata.bundled(bundle: first).version, Self.version)
        XCTAssertEqual(PlacePackMetadata.bundled(bundle: second).version, "raycast-v1-da2e3970db8ea20e")
        XCTAssertEqual(PlacePackMetadata.bundled(bundle: first).version, Self.version)
    }

    func testManifestFromAnotherFolderCannotBePairedWithGeometry() throws {
        for (geometryFolder, manifestFolder) in [("", "Places"), ("Places", ""), ("Resources/Places", "Places")] {
            let bundle = try makeBundle(manifest: data(validManifest), folder: geometryFolder, manifestFolder: manifestFolder)
            assertUnavailable(PlacePackMetadata.bundled(bundle: bundle))
        }
    }

    private func data(_ manifest: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    }

    private func load(runtime: [String: Any]) throws -> PlacePackMetadata {
        var manifest = validManifest
        manifest["runtime"] = runtime
        return PlacePackMetadata.bundled(bundle: try makeBundle(manifest: data(manifest)))
    }

    private func assertUnavailable(_ metadata: PlacePackMetadata, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(metadata.version, "places-unavailable", file: file, line: line)
        XCTAssertFalse(metadata.coverageDescription.isEmpty, file: file, line: line)
    }

    private func makeBundle(manifest: Data?, geometry: Data? = PlacePackMetadataTests.geometry,
                            folder: String = "", manifestFolder: String? = nil,
                            geometryIsDirectory: Bool = false) throws -> Bundle {
        let directory = try TestFixtures.temporaryDirectory()
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let bundleURL = directory.appendingPathComponent("PlacesInspection.bundle", isDirectory: true)
        let geometryFolder = folder.isEmpty ? bundleURL : bundleURL.appendingPathComponent(folder, isDirectory: true)
        let relativeManifestFolder = manifestFolder ?? folder
        let metadataFolder = relativeManifestFolder.isEmpty ? bundleURL
            : bundleURL.appendingPathComponent(relativeManifestFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: geometryFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.localimageiq.places.\(UUID().uuidString)",
            "CFBundleName": "PlacesInspection", "CFBundlePackageType": "BNDL"
        ], format: .xml, options: 0)
        try plist.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let geometryURL = geometryFolder.appendingPathComponent("Places.geojson")
        if geometryIsDirectory {
            try FileManager.default.createDirectory(at: geometryURL, withIntermediateDirectories: true)
        } else if let geometry {
            try geometry.write(to: geometryURL)
        }
        if let manifest {
            try manifest.write(to: metadataFolder.appendingPathComponent("places-manifest.json"))
        }
        // All resources precede Bundle creation; do not depend on Bundle cache invalidation.
        return try XCTUnwrap(Bundle(url: bundleURL))
    }
}