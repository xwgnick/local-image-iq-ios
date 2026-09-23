import Foundation

/// Optional WGS84 GeoJSON only. No nearest-place guess, CLGeocoder or network.
/// Planar ray casting uses longitude unwrapping for date-line crossing rings;
/// boundaries are administrative approximations, not addresses or spherical GIS.
struct OfflinePlaceResolver: Sendable {
    let version: String
    let coverageDescription: String
    let featureCount: Int
    let coverageCountries: [String]
    let sourceNote: String?
    private let regions: [Region]

    static func bundled(bundle: Bundle = .main) -> OfflinePlaceResolver {
        guard let url = BundleResources.url("Places", extension: "geojson", bundle: bundle)
            ?? bundle.url(forResource: "Places", withExtension: "geojson", subdirectory: "Places")
            ?? bundle.url(forResource: "Places", withExtension: "geojson", subdirectory: "Resources/Places") else {
            return unavailable("No offline boundary pack bundled; location labels are unavailable.")
        }
        do { return try OfflinePlaceResolver(data: Data(contentsOf: url)) }
        catch { return unavailable("Offline boundary pack could not be read: \(error.localizedDescription)") }
    }

    static func unavailable(_ reason: String) -> OfflinePlaceResolver {
        OfflinePlaceResolver(version: "places-unavailable", coverageDescription: reason, featureCount: 0, regions: [])
    }

    private init(version: String, coverageDescription: String, featureCount: Int,
                 coverageCountries: [String] = [], sourceNote: String? = nil, regions: [Region]) {
        self.version = version
        self.coverageDescription = coverageDescription
        self.featureCount = featureCount
        self.coverageCountries = coverageCountries
        self.sourceNote = sourceNote
        self.regions = regions
    }

    init(data: Data) throws {
        let collection = try JSONDecoder().decode(Collection.self, from: data)
        guard collection.type == "FeatureCollection" else { throw AppFailure.places("Expected a FeatureCollection.") }
        var regions: [Region] = []
        var skipped = 0
        for entry in collection.features {
            guard let feature = entry.feature, let shapes = feature.geometry.polygons else {
                skipped += 1
                continue
            }
            let hasLabel = !feature.properties.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard feature.type == "Feature", hasLabel, !feature.properties.level.isEmpty else {
                skipped += 1
                continue
            }
            let polygons = shapes.compactMap(Polygon.init)
            // Never use a partial polygon with a missing/invalid hole.
            guard polygons.count == shapes.count, !polygons.isEmpty else { skipped += 1; continue }
            regions.append(Region(label: feature.properties.label, level: feature.properties.level, polygons: polygons))
        }
        // Stable cache identity, not a security/signature hash. Includes all pack bytes.
        let fingerprint = data.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let countries = collection.coverageCountries ?? []
        let coverage = countries.isEmpty ? "Offline coverage: this pack only."
            : "Offline country coverage: \(countries.joined(separator: ", "))."
        self.init(version: "raycast-v1-\(String(fingerprint, radix: 16))",
                  coverageDescription: "\(coverage) Administrative boundaries may be incomplete or historical; not live GPS or global coverage. \(regions.count) features; \(skipped) unsupported/invalid features skipped.",
                  featureCount: regions.count, coverageCountries: countries,
                  sourceNote: collection.sourceNote, regions: regions)
    }

    func label(longitude: Double, latitude: Double) -> String? {
        guard longitude.isFinite, latitude.isFinite, (-180...180).contains(longitude), (-90...90).contains(latitude) else { return nil }
        // Smaller contained polygon breaks ties at the same administrative level.
        var best: (label: String, rank: Int, area: Double)?
        for region in regions {
            for polygon in region.polygons where polygon.contains(longitude: longitude, latitude: latitude) {
                let candidate = (region.label, region.rank, polygon.areaEstimate)
                if let previous = best {
                    if candidate.1 > previous.rank ||
                        (candidate.1 == previous.rank && candidate.2 < previous.area) ||
                        (candidate.1 == previous.rank && candidate.2 == previous.area && candidate.0 < previous.label) {
                        best = candidate
                    }
                } else { best = candidate }
            }
        }
        return best?.label
    }

    private struct Collection: Decodable {
        let type: String
        let coverageCountries: [String]?
        let sourceNote: String?
        let features: [FeatureEntry]
    }
    private struct FeatureEntry: Decodable {
        let feature: Feature?
        init(from decoder: Decoder) throws {
            // A malformed feature is counted as skipped, not a reason to discard valid siblings.
            feature = try? Feature(from: decoder)
        }
    }
    private struct Feature: Decodable {
        let type: String
        let properties: Properties
        let geometry: Geometry
    }
    private struct Properties: Decodable {
        let label: String
        let level: String
        // Country and other provenance fields are allowed, not required or invented.
    }
    private struct Geometry: Decodable {
        let polygons: [[[[Double]]]]?
        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "Polygon": polygons = [try container.decode([[[Double]]].self, forKey: .coordinates)]
            case "MultiPolygon": polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
            default: polygons = nil
            }
        }
    }
    private struct Region: Sendable {
        let label: String
        let level: String
        let polygons: [Polygon]
        var rank: Int {
            let value = level.uppercased()
            if value.hasPrefix("ADM"), let number = Int(value.dropFirst(3)) { return number }
            switch value {
            case "COUNTRY": return 0
            case "REGION", "STATE", "PROVINCE": return 1
            case "COUNTY", "DISTRICT": return 2
            case "CITY", "MUNICIPALITY": return 3
            default: return 0 // Unknown hierarchy falls back to the smaller containing area.
            }
        }
    }
    private struct Polygon: Sendable {
        let outer: Ring
        let holes: [Ring]
        var areaEstimate: Double { outer.area }
        init?(_ coordinates: [[[Double]]]) {
            guard let first = coordinates.first, let shell = Ring(first) else { return nil }
            let inner = coordinates.dropFirst().compactMap(Ring.init)
            guard inner.count == coordinates.count - 1 else { return nil }
            outer = shell
            holes = inner
        }
        func contains(longitude: Double, latitude: Double) -> Bool {
            outer.contains(longitude: longitude, latitude: latitude) &&
                !holes.contains { $0.contains(longitude: longitude, latitude: latitude) }
        }
    }
    private struct Point: Sendable { let x: Double; let y: Double }
    private struct Ring: Sendable {
        let points: [Point]
        let minX: Double
        let maxX: Double
        let minY: Double
        let maxY: Double
        let area: Double

        init?(_ coordinates: [[Double]]) {
            guard coordinates.count >= 4, let first = coordinates.first, let last = coordinates.last,
                  first.count >= 2, last.count >= 2, first[0] == last[0], first[1] == last[1] else { return nil }
            var points: [Point] = []
            for position in coordinates {
                guard position.count >= 2, position[0].isFinite, position[1].isFinite,
                      (-180...180).contains(position[0]), (-90...90).contains(position[1]) else { return nil }
                var x = position[0]
                if let previous = points.last {
                    while x - previous.x > 180 { x -= 360 }
                    while x - previous.x < -180 { x += 360 }
                }
                points.append(Point(x: x, y: position[1]))
            }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX, maxY > minY else { return nil }
            var twiceArea = 0.0
            for index in 1..<points.count {
                twiceArea += points[index - 1].x * points[index].y - points[index].x * points[index - 1].y
            }
            guard abs(twiceArea) > 0 else { return nil }
            self.points = points
            self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY
            area = abs(twiceArea) * 0.5
        }

        func contains(longitude: Double, latitude y: Double) -> Bool {
            var x = longitude
            let center = (minX + maxX) / 2
            while x - center > 180 { x -= 360 }
            while x - center < -180 { x += 360 }
            guard x >= minX, x <= maxX, y >= minY, y <= maxY else { return false }
            var inside = false
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let cross = (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x)
                if abs(cross) < 1e-10, x >= min(a.x, b.x), x <= max(a.x, b.x), y >= min(a.y, b.y), y <= max(a.y, b.y) {
                    return true // Outer edge included; a hole edge is excluded by Polygon.
                }
                if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            }
            return inside
        }
    }
}