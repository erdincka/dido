import Foundation

/// User-adjustable indexing settings, persisted in `UserDefaults`.
@Observable @MainActor
final class IndexSettings {
    static let shared = IndexSettings()

    var chunkSize: Int = UserDefaults.standard.object(forKey: "chunkSize") as? Int ?? 500 {
        didSet { UserDefaults.standard.set(chunkSize, forKey: "chunkSize") }
    }
    var chunkOverlap: Int = UserDefaults.standard.object(forKey: "chunkOverlap") as? Int ?? 50 {
        didSet { UserDefaults.standard.set(chunkOverlap, forKey: "chunkOverlap") }
    }
    /// Off by default: vectors are not searched yet, and remote embeddings cost time and money.
    var embeddingsEnabled: Bool = UserDefaults.standard.bool(forKey: "embeddingsEnabled") {
        didSet { UserDefaults.standard.set(embeddingsEnabled, forKey: "embeddingsEnabled") }
    }
    var embeddingModel: String = UserDefaults.standard.string(forKey: "embeddingModel").flatMap { $0.isEmpty ? nil : $0 } ?? "text-embedding-3-small" {
        didSet { UserDefaults.standard.set(embeddingModel, forKey: "embeddingModel") }
    }

    private init() {}

    /// A snapshot safe to hand to background actors.
    var configuration: IndexerConfiguration {
        IndexerConfiguration(
            chunker: TextChunker(chunkSize: chunkSize, chunkOverlap: chunkOverlap),
            embeddingsEnabled: embeddingsEnabled,
            embeddingModel: embeddingModel
        )
    }
}

struct IndexerConfiguration: Sendable {
    let chunker: TextChunker
    let embeddingsEnabled: Bool
    let embeddingModel: String
}

/// Splits text into overlapping character windows.
struct TextChunker: Sendable {
    let chunkSize: Int
    let chunkOverlap: Int

    func chunk(_ text: String) -> [String] {
        let size = max(chunkSize, 50)
        let step = max(size - min(chunkOverlap, size - 1), 1)
        let characters = Array(text)
        var chunks: [String] = []
        var start = 0
        while start < characters.count {
            let end = min(start + size, characters.count)
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            if end == characters.count { break }
            start += step
        }
        return chunks
    }
}
