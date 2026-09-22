import Foundation
import os

/// What the model receives alongside a question.
struct RetrievedContext: Sendable {
    let text: String
    let citations: [Citation]
    let images: [String]
    let mode: AnswerDetails.Mode
    let candidates: Int

    /// The record kept with the reply.
    func details(provider: String, scope: String) -> AnswerDetails {
        AnswerDetails(provider: provider, scope: scope, mode: mode, candidates: candidates, contextCharacters: text.count, passages: citations)
    }
}

/// Finds the passages most relevant to a question within the selected file or folder.
/// Small scopes are sent whole; larger ones go through vector search with a keyword boost.
struct ContextBuilder: Sendable {
    var topK = 10
    var minimumScore: Float = 0.15

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
    private let logger = Logger(subsystem: "com.dido", category: "Context")

    func build(for item: SelectedItem, question: String, budget: Int, includeImages: Bool) async -> RetrievedContext {
        let indexer = DocumentIndexer.shared
        let embedding = await LLMService.shared.makeEmbeddingProvider()
        let chunkProfile = await IndexSettings.shared.chunker.profile
        let started = Date()
        await indexer.ensureVectorIndexLoaded()
        DebugLog.write("context: index ready after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        await ensureIndexed(item, indexer: indexer, model: embedding.identifier, chunkProfile: chunkProfile)
        DebugLog.write("context: item indexed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        let scope = item.searchScope
        var passages = await VectorIndex.shared.entries(in: scope)
        let indexed = await VectorIndex.shared.count
        logger.notice("Scope \(item.name): \(passages.count) passages in scope, \(indexed) in index")
        let total = passages.reduce(0) { $0 + $1.text.count }
        let candidates = passages.count
        var mode = AnswerDetails.Mode.whole
        var scores: [UUID: Float] = [:]

        if passages.isEmpty {
            passages = await fallbackEntries(for: item, indexer: indexer)
        } else if total > budget {
            mode = .search
            let hits = await search(question, scope: scope, embedding: embedding)
            passages = hits.map(\.entry)
            for hit in hits { scores[hit.entry.chunkID] = hit.score }
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
                                      start: passage.start, end: passage.end, score: scores[passage.chunkID] ?? 1))
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

        let header: String
        switch item.kind {
        case .file: header = "[File: \(item.name)]"
        case .folder: header = "[Folder: \(item.name)]"
        case .library: header = "[Whole library]"
        }
        let empty = item.isLibrary ? "(Nothing is indexed yet. Index the library from Settings or wait for the background scan.)" : "(No text could be extracted.)"
        let text = lines.isEmpty ? "\(header)\n\(empty)" : "\(header)\n\n" + lines.joined(separator: "\n\n")
        logger.notice("Context for \(item.name): \(citations.count) passages, \(used) characters, \(images.count) images")
        DebugLog.write("context: \(citations.count) passages (\(mode)) from \(candidates) candidates after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return RetrievedContext(text: text, citations: citations, images: images, mode: mode, candidates: candidates)
    }

    /// Indexes on demand only what has no usable index. Stale files are answered from what is stored and
    /// refreshed by the background scan, so a question never waits behind a long re-index.
    private func ensureIndexed(_ item: SelectedItem, indexer: DocumentIndexer, model: String, chunkProfile: String) async {
        if item.isLibrary {
            return // the background indexer keeps the whole library current
        }
        var urls: [URL] = []
        if item.isDirectory {
            let children = (try? await FileSystemScanner.shared.children(of: item.url)) ?? []
            urls = children.filter { !$0.isDirectory }.map(\.url)
        } else {
            urls = [item.url]
        }
        for url in urls where DocumentParser.supportedExtensions.contains(url.pathExtension.lowercased()) {
            let freshness = await indexer.freshness(of: url, embeddingModel: model, chunkProfile: chunkProfile)
            switch freshness {
            case .missing:
                await indexer.index(url, quiet: true)
            case .stale where !(await indexer.isRunning):
                await indexer.index(url, quiet: true)
            default:
                break
            }
        }
    }

    private func search(_ question: String, scope: SearchScope, embedding: any EmbeddingProvider) async -> [SearchHit] {
        let keywords = question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        do {
            guard let vector = try await embedding.embed([question]).first else { return [] }
            return await VectorIndex.shared.search(query: vector, scope: scope, limit: topK, minimumScore: minimumScore, keywords: keywords)
        } catch {
            logger.error("Question embedding failed, using document order: \(error.localizedDescription)")
            return await VectorIndex.shared.entries(in: scope).map { SearchHit(entry: $0, score: 0) }
        }
    }

    /// Text chunks without vectors, for files whose embeddings failed.
    private func fallbackEntries(for item: SelectedItem, indexer: DocumentIndexer) async -> [IndexEntry] {
        var urls: [URL] = []
        if item.isLibrary {
            return []
        } else if item.isDirectory {
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
