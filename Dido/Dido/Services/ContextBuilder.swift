import Foundation
import os

/// What the model receives alongside a question.
struct RetrievedContext: Sendable {
    let text: String
    let citations: [Citation]
    let images: [String]

    static let empty = RetrievedContext(text: "", citations: [], images: [])
}

/// Finds the passages most relevant to a question within the selected file or folder.
/// Small scopes are sent whole; larger ones go through vector search with a keyword boost.
struct ContextBuilder: Sendable {
    var topK = 8
    var minimumScore: Float = 0.1

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
    private let logger = Logger(subsystem: "com.dido", category: "Context")

    func build(for item: SelectedItem, question: String, budget: Int, includeImages: Bool) async -> RetrievedContext {
        let indexer = DocumentIndexer.shared
        let embedding = await LLMService.shared.makeEmbeddingProvider()
        await ensureIndexed(item, indexer: indexer, model: embedding.identifier)

        let scope: SearchScope = item.isDirectory ? .folder(item.url.path) : .file(item.url.path)
        var passages = await VectorIndex.shared.entries(in: scope)
        let total = passages.reduce(0) { $0 + $1.text.count }

        if passages.isEmpty {
            passages = await fallbackEntries(for: item, indexer: indexer)
        } else if total > budget {
            passages = await search(question, scope: scope, embedding: embedding)
        }

        var citations: [Citation] = []
        var lines: [String] = []
        var used = 0
        for (offset, passage) in passages.enumerated() {
            let block = "[\(offset + 1)] \(passage.filename), part \(passage.ordinal + 1)\n\(passage.text)"
            guard used + block.count <= budget else { break }
            lines.append(block)
            used += block.count
            citations.append(Citation(index: offset + 1, path: passage.path, filename: passage.filename, ordinal: passage.ordinal,
                                      start: passage.start, end: passage.end, score: 0))
        }

        var images: [String] = []
        if includeImages, !item.isDirectory {
            let ext = item.url.pathExtension.lowercased()
            if ext == "pdf" {
                images = await DocumentParser.shared.pageImagesBase64(of: item.url)
            } else if Self.imageExtensions.contains(ext), let image = await DocumentParser.shared.imageBase64(of: item.url) {
                images = [image]
            }
        }

        let header = item.isDirectory ? "[Folder: \(item.name)]" : "[File: \(item.name)]"
        let text = lines.isEmpty ? "\(header)\n(No text could be extracted.)" : "\(header)\n\n" + lines.joined(separator: "\n\n")
        logger.info("Context for \(item.name): \(citations.count) passages, \(used) characters, \(images.count) images")
        return RetrievedContext(text: text, citations: citations, images: images)
    }

    private func ensureIndexed(_ item: SelectedItem, indexer: DocumentIndexer, model: String) async {
        if item.isDirectory {
            let children = (try? await FileSystemScanner.shared.children(of: item.url)) ?? []
            for child in children where !child.isDirectory && DocumentParser.supportedExtensions.contains(child.url.pathExtension.lowercased()) {
                if await !indexer.isCurrent(url: child.url, embeddingModel: model) {
                    await indexer.index(child.url, quiet: true)
                }
            }
        } else if DocumentParser.supportedExtensions.contains(item.url.pathExtension.lowercased()) {
            if await !indexer.isCurrent(url: item.url, embeddingModel: model) {
                await indexer.index(item.url, quiet: true)
            }
        }
    }

    private func search(_ question: String, scope: SearchScope, embedding: any EmbeddingProvider) async -> [IndexEntry] {
        let keywords = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        do {
            guard let vector = try await embedding.embed([question]).first else { return [] }
            let hits = await VectorIndex.shared.search(query: vector, scope: scope, limit: topK, minimumScore: minimumScore, keywords: keywords)
            return hits.map(\.entry)
        } catch {
            logger.error("Question embedding failed, using document order: \(error.localizedDescription)")
            return await VectorIndex.shared.entries(in: scope)
        }
    }

    /// Text chunks without vectors, for files whose embeddings failed.
    private func fallbackEntries(for item: SelectedItem, indexer: DocumentIndexer) async -> [IndexEntry] {
        var urls: [URL] = []
        if item.isDirectory {
            let children = (try? await FileSystemScanner.shared.children(of: item.url)) ?? []
            urls = children.filter { !$0.isDirectory }.map(\.url)
        } else {
            urls = [item.url]
        }
        var entries: [IndexEntry] = []
        for url in urls {
            let chunks = await indexer.textChunks(for: url)
            for (ordinal, text) in chunks.enumerated() {
                entries.append(IndexEntry(chunkID: UUID(), path: url.path, filename: url.lastPathComponent, ordinal: ordinal, start: 0, end: 0, text: text, vector: []))
            }
        }
        return entries
    }
}
