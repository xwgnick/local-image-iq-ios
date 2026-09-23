import Foundation
import CoreGraphics
import SQLite3
import XCTest
import ImageIQCore
@testable import LocalImageIQ

enum TestFixtures {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImageIQTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Synthetic unit vectors for model-free tests only. Never used by app code.
    static func vector(axis: Int = 0, dimension: Int = 768) -> [Float] {
        var values = [Float](repeating: 0, count: dimension)
        values[axis] = 1
        return values
    }

    static func photo(id: String = "synthetic-asset", revision: Double = 123, model: String = "test-model",
                      location: PlaceEmbedding? = nil) -> CachedPhoto {
        CachedPhoto(photo: IndexedPhoto(id: id, modificationTime: revision, modelVersion: model,
                                        imageEmbedding: vector(), location: location, creationTime: 100),
                    geographyVersion: "test-places")
    }

    static func image(width: Int, height: Int, shouldInterpolate: Bool = false,
                      pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let rgb = pixel(x, y)
                bytes.append(contentsOf: [rgb.0, rgb.1, rgb.2, 255])
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: space,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: shouldInterpolate, intent: .defaultIntent))
    }

    static let legacyModelVersion = "clip-pair-v1-test-legacy"

    /// Creates only synthetic test databases. Bypass save/validation deliberately:
    /// old 512-D rows and malformed read fixtures cannot be written by today's API.
    /// SQLite user_version stays 1; it is unrelated to the model manifest's schema 2.
    static func seedRawCache(_ rows: [CachedPhoto], directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(directory.appendingPathComponent("index.sqlite3").path,
                                     &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let database = handle else {
            throw AppFailure.storage("Unable to open synthetic SQLite fixture (\(status)).")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func check(_ status: Int32, expected: Int32 = SQLITE_OK) throws {
            guard status == expected else {
                throw AppFailure.storage("Synthetic SQLite fixture: \(String(cString: sqlite3_errmsg(database)))")
            }
        }
        func exec(_ sql: String) throws { try check(sqlite3_exec(database, sql, nil, nil, nil)) }
        func statement(_ sql: String, bind: (OpaquePointer) throws -> Void) throws {
            var pointer: OpaquePointer?
            let prepared = sqlite3_prepare_v2(database, sql, -1, &pointer, nil)
            defer { if let pointer { sqlite3_finalize(pointer) } }
            try check(prepared)
            let query = try XCTUnwrap(pointer)
            try bind(query)
            try check(sqlite3_step(query), expected: SQLITE_DONE)
        }
        func text(_ value: String?, _ index: Int32, _ query: OpaquePointer) throws {
            if let value {
                try check(value.withCString { sqlite3_bind_text(query, index, $0, -1, transient) })
            } else { try check(sqlite3_bind_null(query, index)) }
        }
        func embedding(_ vector: [Float], _ index: Int32, _ query: OpaquePointer) throws {
            let data = try JSONEncoder().encode(vector)
            try check(data.withUnsafeBytes { sqlite3_bind_blob(query, index, $0.baseAddress, Int32(data.count), transient) })
        }
        try exec("BEGIN IMMEDIATE")
        do {
            try exec("""
                CREATE TABLE IF NOT EXISTS photos (
                    id TEXT PRIMARY KEY NOT NULL, revision REAL NOT NULL, model_version TEXT NOT NULL,
                    image_embedding BLOB NOT NULL, creation_time REAL, place_text TEXT,
                    geography_version TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS places (
                    text TEXT NOT NULL, model_version TEXT NOT NULL, embedding BLOB NOT NULL,
                    PRIMARY KEY (text, model_version));
                PRAGMA user_version = 1;
                """)
            for cached in rows {
                let photo = cached.photo
                if let place = photo.location {
                    try statement("INSERT OR REPLACE INTO places (text, model_version, embedding) VALUES (?, ?, ?)") { query in
                        try text(place.text, 1, query)
                        try text(photo.modelVersion, 2, query)
                        try embedding(place.vector, 3, query)
                    }
                }
                try statement("""
                    INSERT OR REPLACE INTO photos
                    (id, revision, model_version, image_embedding, creation_time, place_text, geography_version)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """) { query in
                    try text(photo.id, 1, query)
                    try check(sqlite3_bind_double(query, 2, photo.modificationTime))
                    try text(photo.modelVersion, 3, query)
                    try embedding(photo.imageEmbedding, 4, query)
                    if let created = photo.creationTime { try check(sqlite3_bind_double(query, 5, created)) }
                    else { try check(sqlite3_bind_null(query, 5)) }
                    try text(photo.location?.text, 6, query)
                    try text(cached.geographyVersion, 7, query)
                }
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    static let manifest = """
    {
      "schemaVersion":2,"modelVersion":"test-model","dimension":768,"sequenceLength":64,"imageSize":224,
      "imageModel":{"id":"google/siglip2-base-patch16-224","revision":"75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"},
      "textModel":{"id":"google/siglip2-base-patch16-224","revision":"75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"},
      "imageInput":"pixel_values","textInputs":["input_ids"],"output":"output_embedding",
      "extraProvenance":"Allowed extension field"
    }
    """
}