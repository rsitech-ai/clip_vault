import Foundation
import NaturalLanguage

public struct EmbeddingAvailability: Hashable, Sendable {
    public var isAvailable: Bool
    public var reason: String?
}

public protocol EmbeddingProvider: Sendable {
    func availability() -> EmbeddingAvailability
    func semanticScore(query: String, text: String) -> Double
}

public struct NaturalLanguageEmbeddingProvider: EmbeddingProvider {
    public init() {}

    public func availability() -> EmbeddingAvailability {
        if NLEmbedding.sentenceEmbedding(for: .english) == nil {
            return EmbeddingAvailability(isAvailable: false, reason: "Local sentence embeddings are unavailable for English.")
        }
        return EmbeddingAvailability(isAvailable: true)
    }

    public func semanticScore(query: String, text: String) -> Double {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return 0
        }

        let distance = embedding.distance(between: query, and: text, distanceType: .cosine)
        guard distance.isFinite else {
            return 0
        }

        return max(0, min(1, 1 - distance))
    }
}
