import Foundation
import CoreLocation
import XCTest
@testable import LocalImageIQ

final class PlaceAvailabilityTests: XCTestCase {
    private let countries = ["China", "France", "Germany", "Netherlands"]
    private let labels = ["中国·合成行政区", "France · Région synthétique",
                          "Germany · Synthetic region", "Netherlands · Synthetic region"]
    private let sourceNote = "geoBoundaries-style synthetic fixture; historical administrative boundaries, not real geography."

    // Deliberately synthetic rectangles, not actual country boundaries or photo locations.
    private func feature(label: String, country: String, west: Double) -> [String: Any] {
        let ring: [[Double]] = [[west, 0], [west + 4, 0], [west + 4, 4], [west, 4], [west, 0]]
        return ["type": "Feature", "properties": ["label": label, "level": "ADM1", "country": country],
                "geometry": ["type": "Polygon", "coordinates": [ring]]]
    }

    private func pack(features: [Any], metadata: Bool = true) throws -> Data {
        var collection: [String: Any] = ["type": "FeatureCollection", "features": features]
        if metadata {
            collection["coverageCountries"] = countries
            collection["sourceNote"] = sourceNote
        }
        return try JSONSerialization.data(withJSONObject: collection, options: [.sortedKeys])
    }

    private func fixture(metadata: Bool = true) throws -> OfflinePlaceResolver {
        let features = countries.indices.map {
            feature(label: labels[$0], country: countries[$0], west: Double($0) * 10)
        }
        return try OfflinePlaceResolver(data: pack(features: features, metadata: metadata))
    }

    private func location(latitude: Double = 2, longitude: Double = 2,
                          accuracy: Double = 5) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                   timestamp: Date(timeIntervalSince1970: 0))
    }

    func testReadableEntryWithoutLocationIsNoGPS() throws {
        let resolver = try fixture()
        XCTAssertEqual(PhotoLibraryClient.classify(location: nil, resolver: resolver, isAvailable: true), .noGPS)
    }

    func testInaccessibleOrDeletedEntryIsUnavailableNotNoGPS() throws {
        let resolver = try fixture()
        XCTAssertEqual(PhotoLibraryClient.classify(location: nil, resolver: resolver, isAvailable: false), .unavailable)
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(), resolver: resolver, isAvailable: false), .unavailable)
        XCTAssertEqual(PhotoLibraryClient.classify(location: nil, resolver: nil, isAvailable: false), .unavailable)
    }

    func testMissingLocationTakesPrecedenceOverMissingPack() {
        XCTAssertEqual(PhotoLibraryClient.classify(location: nil, resolver: nil), .noGPS)
        XCTAssertEqual(PhotoLibraryClient.classify(location: nil, resolver: .unavailable("No pack")), .noGPS)
    }

    func testInvalidCoordinatesAreUnavailableEvenWithoutPack() throws {
        let resolvers: [OfflinePlaceResolver?] = [try fixture(), .unavailable("No pack"), nil]
        let invalid: [(latitude: Double, longitude: Double)] = [
            (.nan, 2), (.infinity, 2), (-.infinity, 2), (91, 2), (-91, 2),
            (2, .nan), (2, .infinity), (2, -.infinity), (2, 181), (2, -181)
        ]
        for coordinate in invalid {
            for resolver in resolvers {
                XCTAssertEqual(PhotoLibraryClient.classify(
                    location: location(latitude: coordinate.latitude, longitude: coordinate.longitude),
                    resolver: resolver), .unavailable)
            }
        }
    }

    func testUnknownAccuracyDoesNotDiscardValidHistoricalPhotoCoordinates() throws {
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(accuracy: -1), resolver: try fixture()), .resolved(labels[0]))
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(accuracy: -1), resolver: nil), .noPack)
    }

    func testValidLocationWithAbsentOrEmptyPackIsNoPack() throws {
        let empty = try OfflinePlaceResolver(data: pack(features: []))
        let resolvers: [OfflinePlaceResolver?] = [nil, .unavailable("No pack"), empty]
        for resolver in resolvers {
            XCTAssertEqual(PhotoLibraryClient.classify(location: location(), resolver: resolver), .noPack)
        }
    }

    func testValidLocationsResolveSyntheticChineseAndEuropeanLabels() throws {
        let resolver = try fixture()
        for index in labels.indices {
            XCTAssertEqual(PhotoLibraryClient.classify(
                location: location(longitude: Double(index) * 10 + 2), resolver: resolver), .resolved(labels[index]))
        }
    }

    func testZeroCoordinatesAndZeroAccuracyAreNotMissingGPS() throws {
        let resolver = try fixture()
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(latitude: 0, longitude: 0, accuracy: 0),
                                                   resolver: resolver), .resolved(labels[0]))
    }

    func testGapAndDistantLocationsAreOutsideCoverage() throws {
        let resolver = try fixture()
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(longitude: 7), resolver: resolver), .outsideCoverage)
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(latitude: 40, longitude: -100),
                                                   resolver: resolver), .outsideCoverage)
    }

    func testValidCoordinateLimitsAreOutsideCoverageNotUnavailable() throws {
        let resolver = try fixture()
        for latitude in [-90.0, 90.0] {
            for longitude in [-180.0, 180.0] {
                XCTAssertEqual(PhotoLibraryClient.classify(location: location(latitude: latitude, longitude: longitude),
                                                           resolver: resolver), .outsideCoverage)
            }
        }
    }

    func testMetadataDescribesOfflineCountryCoverageAndPreservesSource() throws {
        let resolver = try fixture()
        XCTAssertEqual(resolver.featureCount, 4)
        XCTAssertEqual(resolver.coverageCountries, countries)
        XCTAssertEqual(resolver.sourceNote, sourceNote)
        XCTAssertTrue(resolver.coverageDescription.contains("Offline country coverage"))
        for country in countries { XCTAssertTrue(resolver.coverageDescription.contains(country)) }
        XCTAssertTrue(resolver.coverageDescription.contains("historical"))
        XCTAssertTrue(resolver.coverageDescription.contains("not live GPS or global coverage"))
    }

    func testLegacyFixturesDoNotRequireMetadata() throws {
        let resolver = try fixture(metadata: false)
        XCTAssertEqual(resolver.featureCount, 4)
        XCTAssertEqual(resolver.coverageCountries, [])
        XCTAssertNil(resolver.sourceNote)
        XCTAssertTrue(resolver.coverageDescription.contains("this pack only"))
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(), resolver: resolver), .resolved(labels[0]))
    }

    func testMalformedFeaturesAreCountedWithoutDiscardingReadableEntries() throws {
        let missingLabel: [String: Any] = [
            "type": "Feature", "properties": ["level": "ADM1"],
            "geometry": ["type": "Polygon", "coordinates": []]
        ]
        let wrongCoordinates: [String: Any] = [
            "type": "Feature", "properties": ["label": "Malformed", "level": "ADM1"],
            "geometry": ["type": "Polygon", "coordinates": "not an array"]
        ]
        let unsupported: [String: Any] = [
            "type": "Feature", "properties": ["label": "Not a boundary", "level": "ADM1"],
            "geometry": ["type": "Point", "coordinates": [2, 2]]
        ]
        let invalidHole: [String: Any] = [
            "type": "Feature", "properties": ["label": "Invalid hole", "level": "ADM2"],
            "geometry": ["type": "Polygon", "coordinates": [
                [[0, 0], [4, 0], [4, 4], [0, 4], [0, 0]], [[1, 1], [2, 2]]
            ]]
        ]
        let data = try pack(features: [
            NSNull(), missingLabel, wrongCoordinates, unsupported, invalidHole,
            feature(label: labels[0], country: countries[0], west: 0)
        ])
        let resolver = try OfflinePlaceResolver(data: data)
        XCTAssertEqual(resolver.featureCount, 1)
        XCTAssertTrue(resolver.coverageDescription.contains("5 unsupported/invalid features skipped"))
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(), resolver: resolver), .resolved(labels[0]))
    }

    func testPackWithOnlyInvalidEntriesIsNoPackNotOutsideCoverage() throws {
        let resolver = try OfflinePlaceResolver(data: pack(features: [NSNull()]))
        XCTAssertEqual(resolver.featureCount, 0)
        XCTAssertTrue(resolver.coverageDescription.contains("1 unsupported/invalid features skipped"))
        XCTAssertEqual(PhotoLibraryClient.classify(location: location(), resolver: resolver), .noPack)
    }

    func testInvalidCollectionStillFailsRatherThanPretendingToBeReadable() throws {
        let collection: [String: Any] = ["type": "Feature", "features": []]
        let wrongType = try JSONSerialization.data(withJSONObject: collection)
        XCTAssertThrowsError(try OfflinePlaceResolver(data: wrongType))
        XCTAssertThrowsError(try OfflinePlaceResolver(data: Data("not JSON".utf8)))
    }

    func testLegacyProtocolDefaultMapsEveryNonNilLabelToResolved() {
        let resolver = OfflinePlaceResolver.unavailable("No pack")
        for label in [labels[0], ""] {
            let library: any PhotoLibraryIndexing = LabelOnlyLibrary(label: label)
            XCTAssertEqual(library.placeResult(id: "synthetic", resolver: resolver), .resolved(label))
        }
    }

    func testLegacyProtocolDefaultDoesNotInferNoGPSFromNilLabel() {
        let library: any PhotoLibraryIndexing = LabelOnlyLibrary(label: nil)
        XCTAssertEqual(library.placeResult(id: "synthetic", resolver: .unavailable("No pack")), .unavailable)
    }

    private struct LabelOnlyLibrary: PhotoLibraryIndexing {
        let label: String?
        var canReadImages: Bool { true }
        func enumerateAuthorizedImages() throws -> [PhotoRevision] { [] }
        func currentRevision(id: String) -> PhotoRevision? { nil }
        func placeLabel(id: String, resolver: OfflinePlaceResolver) -> String? { label }
        func indexImage(id: String, networkAllowed: Bool) async throws -> IndexingImage {
            throw FixtureFailure.unexpectedImageRequest
        }
    }

    private enum FixtureFailure: Error { case unexpectedImageRequest }
}