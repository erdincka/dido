import Foundation
import NaturalLanguage

/// User-adjustable chunking settings, persisted in `UserDefaults`.
@Observable @MainActor
final class IndexSettings {
    static let shared = IndexSettings()

    var chunkSize: Int = UserDefaults.standard.object(forKey: "chunkSize") as? Int ?? 600 {
        didSet { UserDefaults.standard.set(chunkSize, forKey: "chunkSize") }
    }
    var chunkOverlap: Int = UserDefaults.standard.object(forKey: "chunkOverlap") as? Int ?? 80 {
        didSet { UserDefaults.standard.set(chunkOverlap, forKey: "chunkOverlap") }
    }

    private init() {}

    var chunker: TextChunker {
        TextChunker(chunkSize: chunkSize, chunkOverlap: chunkOverlap)
    }
}

/// A piece of a document with its UTF-16 offsets in the extracted text.
struct TextChunk: Sendable {
    let text: String
    let start: Int
    let end: Int
}

/// Packs whole sentences into chunks of roughly `chunkSize` characters with a sentence-aligned overlap.
/// A single sentence longer than a chunk is split into character windows.
struct TextChunker: Sendable {
    let chunkSize: Int
    let chunkOverlap: Int

    func chunk(_ text: String) -> [TextChunk] {
        let size = max(chunkSize, 100)
        let overlap = min(max(chunkOverlap, 0), size / 2)
        let sentences = Self.sentences(in: text).flatMap { split($0, size: size) }
        guard !sentences.isEmpty else { return [] }

        var chunks: [TextChunk] = []
        var current: [TextChunk] = []
        var currentLength = 0

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let joined = current.map(\.text).joined(separator: " ")
            chunks.append(TextChunk(text: joined, start: first.start, end: last.end))
        }

        for sentence in sentences {
            if currentLength + sentence.text.count > size, !current.isEmpty {
                flush()
                var carried: [TextChunk] = []
                var carriedLength = 0
                for previous in current.reversed() where carriedLength + previous.text.count <= overlap {
                    carried.insert(previous, at: 0)
                    carriedLength += previous.text.count
                }
                current = carried
                currentLength = carriedLength
            }
            current.append(sentence)
            currentLength += sentence.text.count
        }
        flush()
        return chunks
    }

    private static func sentences(in text: String) -> [TextChunk] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [TextChunk] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                let utf16 = NSRange(range, in: text)
                result.append(TextChunk(text: sentence, start: utf16.location, end: utf16.location + utf16.length))
            }
            return true
        }
        return result
    }

    private func split(_ sentence: TextChunk, size: Int) -> [TextChunk] {
        guard sentence.text.count > size else { return [sentence] }
        var pieces: [TextChunk] = []
        var offset = sentence.start
        var remaining = Substring(sentence.text)
        while !remaining.isEmpty {
            let piece = remaining.prefix(size)
            let length = piece.utf16.count
            pieces.append(TextChunk(text: String(piece), start: offset, end: offset + length))
            offset += length
            remaining = remaining.dropFirst(piece.count)
        }
        return pieces
    }
}
