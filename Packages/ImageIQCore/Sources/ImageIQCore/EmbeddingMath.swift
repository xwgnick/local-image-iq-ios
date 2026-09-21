import Foundation

public enum EmbeddingError: Error, Equatable, Sendable {
    case emptyVector
    case dimensionMismatch(expected: Int, actual: Int)
    case nonFiniteValue(index: Int)
    case zeroNorm
    case nonFiniteResult
}

public enum EmbeddingMath {
    /// Normalize raw encoder output exactly once. General nonempty dimensions
    /// support synthetic tests; the paired production models have 512 outputs.
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        try validate(vector)
        // Double can hold squares of every finite Float, including subnormals.
        // Squaring in Float would overflow/underflow valid raw projections.
        var squaredNorm: Double = 0
        for value in vector {
            let wide = Double(value)
            squaredNorm += wide * wide
        }
        guard squaredNorm > 0 else { throw EmbeddingError.zeroNorm }
        let norm = squaredNorm.squareRoot()
        guard norm.isFinite else { throw EmbeddingError.nonFiniteResult }
        return vector.map { Float(Double($0) / norm) }
    }

    /// Exhaustive inner product, not cosine similarity; never normalizes inputs.
    public static func dot(_ lhs: [Float], _ rhs: [Float]) throws -> Float {
        try validate(lhs)
        try validate(rhs, dimension: lhs.count)
        return try checkedFloat(dotValidated(lhs, rhs))
    }

    static func validate(_ vector: [Float], dimension: Int? = nil) throws {
        guard !vector.isEmpty else { throw EmbeddingError.emptyVector }
        if let dimension, vector.count != dimension {
            throw EmbeddingError.dimensionMismatch(expected: dimension, actual: vector.count)
        }
        for (index, value) in vector.enumerated() where !value.isFinite {
            throw EmbeddingError.nonFiniteValue(index: index)
        }
    }

    /// Only call after both arrays have been validated for shape and finiteness.
    static func dotValidated(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var result: Double = 0
        for index in lhs.indices {
            result += Double(lhs[index]) * Double(rhs[index])
        }
        return result
    }

    static func checkedFloat(_ value: Double) throws -> Float {
        let result = Float(value)
        guard value.isFinite, result.isFinite else { throw EmbeddingError.nonFiniteResult }
        return result
    }
}