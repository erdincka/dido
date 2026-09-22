import Foundation
import NaturalLanguage
import os

enum EmbeddingError: Error, LocalizedError {
    case unavailable
    case assetsUnavailable
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unavailable: return "On-device embeddings are not available on this Mac."
        case .assetsUnavailable: return "The on-device embedding model could not be downloaded. Check the network connection and try again."
        case .emptyResult: return "The embedding model returned no vector."
        }
    }
}

/// Turns text into vectors. Implementations must be safe to call from any actor.
protocol EmbeddingProvider: Sendable {
    /// Stored with every document so vectors from different models are never compared.
    var identifier: String { get }
    var displayName: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Apple's contextual sentence embedding, mean-pooled over tokens. Runs entirely on device.
actor LocalEmbeddingProvider: EmbeddingProvider {
    static let shared = LocalEmbeddingProvider()

    nonisolated let identifier = "apple.contextual.latin.v1"
    nonisolated let displayName = "On device (Apple)"

    private var model: NLContextualEmbedding?
    private let logger = Logger(subsystem: "com.dido", category: "Embedding")

    private init() {}

    private func loadedModel() async throws -> NLContextualEmbedding {
        if let model { return model }
        guard let candidate = NLContextualEmbedding(script: .latin) else { throw EmbeddingError.unavailable }
        if !candidate.hasAvailableAssets {
            logger.info("Requesting on-device embedding assets")
            await AppState.shared.showNotification("Downloading the on-device embedding model…")
            let result = try await candidate.requestAssets()
            guard result == .available else { throw EmbeddingError.assetsUnavailable }
        }
        try candidate.load()
        model = candidate
        return candidate
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let model = try await loadedModel()
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            let result = try model.embeddingResult(for: text, language: nil)
            var sum = [Double](repeating: 0, count: model.dimension)
            var tokens = 0
            result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
                for index in 0..<min(vector.count, sum.count) {
                    sum[index] += vector[index]
                }
                tokens += 1
                return true
            }
            guard tokens > 0 else { throw EmbeddingError.emptyResult }
            vectors.append(sum.map { Float($0 / Double(tokens)) })
        }
        return vectors
    }
}

/// Embeddings from an OpenAI-compatible `/embeddings` endpoint.
struct ServerEmbeddingProvider: EmbeddingProvider {
    let client: OpenAICompatibleClient
    let model: String

    var identifier: String { "server:\(model)" }
    var displayName: String { "Server (\(model))" }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await client.embeddings(for: texts, model: model)
    }
}
