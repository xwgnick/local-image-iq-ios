import Foundation
import XCTest
@testable import ImageIQCore

final class ModelsTests: XCTestCase {
    private func requireSendable<T: Sendable>(_ value: T) {}

    func testPlaceEmbeddingCodableRoundTripAndSendable() throws {
        let place = PlaceEmbedding(text: "Synthetic 中 Café", vector: [0.6, 0.8])
        requireSendable(place)
        let decoded = try JSONDecoder().decode(
            PlaceEmbedding.self, from: JSONEncoder().encode(place)
        )
        XCTAssertEqual(decoded.text, place.text)
        XCTAssertEqual(decoded.vector, place.vector)
    }

    func testIndexedPhotoDefaultsAndDecodingMissingOptionals() throws {
        let photo = IndexedPhoto(
            id: "synthetic-default", modificationTime: 1_700_000_000.25,
            modelVersion: "test-pair", imageEmbedding: [1, 0]
        )
        requireSendable(photo)
        XCTAssertNil(photo.location)
        XCTAssertNil(photo.creationTime)
        let json = Data("""
        {"id":"synthetic-old","modificationTime":1700000000.25,
         "modelVersion":"test-pair","imageEmbedding":[1,0]}
        """.utf8)
        let decoded = try JSONDecoder().decode(IndexedPhoto.self, from: json)
        XCTAssertEqual(decoded.modificationTime, 1_700_000_000.25)
        XCTAssertNil(decoded.location)
        XCTAssertNil(decoded.creationTime)
    }

    func testIndexedPhotoFullCodableRoundTrip() throws {
        let photo = IndexedPhoto(
            id: "synthetic-full", modificationTime: 1_700_000_000.25,
            modelVersion: "test-pair", imageEmbedding: [-1, 0],
            location: PlaceEmbedding(text: "Synthetic A", vector: [0, 1]),
            creationTime: 1_600_000_000.5
        )
        let data = try JSONEncoder().encode(photo)
        let decoded = try JSONDecoder().decode(IndexedPhoto.self, from: data)
        XCTAssertEqual(decoded.id, photo.id)
        XCTAssertEqual(decoded.modificationTime, photo.modificationTime)
        XCTAssertEqual(decoded.modelVersion, photo.modelVersion)
        XCTAssertEqual(decoded.imageEmbedding, photo.imageEmbedding)
        XCTAssertEqual(decoded.location?.text, photo.location?.text)
        XCTAssertEqual(decoded.location?.vector, photo.location?.vector)
        XCTAssertEqual(decoded.creationTime, photo.creationTime)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set([
            "id", "modificationTime", "modelVersion", "imageEmbedding", "location", "creationTime"
        ]))
    }

    func testSearchHitIdentityCodableAndSendable() throws {
        let hit = SearchHit(
            photo: IndexedPhoto(
                id: "synthetic-hit", modificationTime: 0,
                modelVersion: "test-pair", imageEmbedding: [1, 0]
            ),
            score: -0.25
        )
        requireSendable(hit)
        XCTAssertEqual(hit.id, hit.photo.id)
        let decoded = try JSONDecoder().decode(SearchHit.self, from: JSONEncoder().encode(hit))
        XCTAssertEqual(decoded.id, hit.id)
        XCTAssertEqual(decoded.score, hit.score)
    }

    func testTokenizedTextCodableAndSendable() throws {
        let text = TokenizedText(inputIDs: [4, 2, 3], attentionMask: [1, 1, 0])
        requireSendable(text)
        let decoded = try JSONDecoder().decode(TokenizedText.self, from: JSONEncoder().encode(text))
        XCTAssertEqual(decoded.inputIDs, text.inputIDs)
        XCTAssertEqual(decoded.attentionMask, text.attentionMask)
    }
}