import XCTest
@testable import LocalImageIQ

final class OfflinePlaceResolverTests: XCTestCase {
    private let outer: [[Double]] = [[0, 0], [10, 0], [10, 10], [0, 10], [0, 0]]

    private func pack(_ features: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features], options: [.sortedKeys])
    }

    private func feature(_ label: String, _ level: String, rings: [[[Double]]]) -> [String: Any] {
        ["type": "Feature", "properties": ["label": label, "level": level, "country": "Synthetic"],
         "geometry": ["type": "Polygon", "coordinates": rings]]
    }

    func testPolygonBoundingBoxAndHolesIncludingHoleBoundary() throws {
        let hole: [[Double]] = [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]]
        let resolver = try OfflinePlaceResolver(data: pack([feature("Test Region", "ADM1", rings: [outer, hole])]))
        XCTAssertEqual(resolver.label(longitude: 2, latitude: 2), "Test Region")
        XCTAssertEqual(resolver.label(longitude: 0, latitude: 5), "Test Region")
        XCTAssertNil(resolver.label(longitude: 5, latitude: 5))
        XCTAssertNil(resolver.label(longitude: 4, latitude: 5))
        XCTAssertNil(resolver.label(longitude: 12, latitude: 2))
    }

    func testMostSpecificAdministrativeLevelWins() throws {
        let city: [[Double]] = [[1, 1], [3, 1], [3, 3], [1, 3], [1, 1]]
        let resolver = try OfflinePlaceResolver(data: pack([
            feature("Region", "ADM1", rings: [outer]), feature("District", "ADM2", rings: [city])
        ]))
        XCTAssertEqual(resolver.label(longitude: 2, latitude: 2), "District")
        XCTAssertEqual(resolver.label(longitude: 8, latitude: 8), "Region")
    }

    func testMultiPolygonAndAntimeridianLookup() throws {
        let crossing: [[Double]] = [[170, -10], [-170, -10], [-170, 10], [170, 10], [170, -10]]
        let feature: [String: Any] = ["type": "Feature", "properties": ["label": "Islands", "level": "ADM2"],
                                      "geometry": ["type": "MultiPolygon", "coordinates": [[outer], [crossing]]]]
        let resolver = try OfflinePlaceResolver(data: pack([feature]))
        XCTAssertEqual(resolver.label(longitude: 2, latitude: 2), "Islands")
        XCTAssertEqual(resolver.label(longitude: 179, latitude: 0), "Islands")
        XCTAssertEqual(resolver.label(longitude: -179, latitude: 0), "Islands")
        XCTAssertNil(resolver.label(longitude: 90, latitude: 0))
    }

    func testInvalidHoleSkipsWholeFeatureInsteadOfInventingCoverage() throws {
        let resolver = try OfflinePlaceResolver(data: pack([feature("Invalid", "ADM2", rings: [outer, [[1, 1], [2, 2]]])]))
        XCTAssertEqual(resolver.featureCount, 0)
        XCTAssertNil(resolver.label(longitude: 1, latitude: 1))
        XCTAssertTrue(resolver.coverageDescription.contains("1 unsupported/invalid"))
    }

    func testAbsentPackAndInvalidCoordinatesNeverInventPlace() throws {
        let resolver = OfflinePlaceResolver.unavailable("No pack")
        XCTAssertNil(resolver.label(longitude: 0, latitude: 0))
        let available = try OfflinePlaceResolver(data: pack([feature("Region", "ADM1", rings: [outer])]))
        XCTAssertNil(available.label(longitude: .nan, latitude: 0))
        XCTAssertNil(available.label(longitude: 1, latitude: 91))
    }

    func testPackContentChangeInvalidatesPlaceCacheVersion() throws {
        let first = try OfflinePlaceResolver(data: pack([feature("Old Label", "ADM1", rings: [outer])]))
        let second = try OfflinePlaceResolver(data: pack([feature("New Label", "ADM1", rings: [outer])]))
        XCTAssertNotEqual(first.version, second.version)
    }
}