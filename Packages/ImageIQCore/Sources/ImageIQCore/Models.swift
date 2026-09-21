import Foundation

/// A place-text encoder output, normalized once before storage.
public struct PlaceEmbedding: Codable, Sendable {
    public let text: String
    public let vector: [Float]

    public init(text: String, vector: [Float]) {
        self.text = text
        self.vector = vector
    }
}

/// PhotoKit authorization and cache invalidation are the caller's responsibility.
public struct IndexedPhoto: Codable, Sendable, Identifiable {
    public let id: String
    /// Seconds since Unix epoch.
    public let modificationTime: Double
    public let modelVersion: String
    public let imageEmbedding: [Float]
    public let location: PlaceEmbedding?
    /// Seconds since Unix epoch, if known.
    public let creationTime: Double?

    public init(
        id: String,
        modificationTime: Double,
        modelVersion: String,
        imageEmbedding: [Float],
        location: PlaceEmbedding? = nil,
        creationTime: Double? = nil
    ) {
        self.id = id
        self.modificationTime = modificationTime
        self.modelVersion = modelVersion
        self.imageEmbedding = imageEmbedding
        self.location = location
        self.creationTime = creationTime
    }
}

public struct SearchHit: Codable, Sendable, Identifiable {
    public let photo: IndexedPhoto
    public let score: Float
    public var id: String { photo.id }

    public init(photo: IndexedPhoto, score: Float) {
        self.photo = photo
        self.score = score
    }
}

public struct TokenizedText: Codable, Sendable {
    public let inputIDs: [Int32]
    public let attentionMask: [Int32]

    public init(inputIDs: [Int32], attentionMask: [Int32]) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
    }
}