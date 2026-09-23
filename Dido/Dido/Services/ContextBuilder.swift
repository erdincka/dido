import Foundation
import os

/// What the model receives alongside a question.
struct RetrievedContext: Sendable {
    let text: String
    let citations: [Citation]
    let images: [String]
    let mode: AnswerDetails.Mode
    let candidates: Int
    let retrievalQuery: String?
    let filter: RetrievalFilter

    /// The record kept with the reply.
    func details(provider: String, scope: String) -> AnswerDetails {
        AnswerDetails(provider: provider, scope: scope, mode: mode, candidates: candidates, contextCharacters: text.count,
                      passages: citations, retrievalQuery: retrievalQuery, filter: filter.isEmpty ? nil : filter.summary)
    }
}

/// Finds the passages most relevant to a question within the selected file, folder or library.
/// Small scopes are sent whole; larger ones go through hybrid retrieval: vectors and full text fused by
/// reciprocal rank, adjacent passages merged into extracts.
struct ContextBuilder: Sendable {
    var topK = 10
    var minimumScore: Float = 0.15
    /// Extracts that overlap by this much of their text are considered duplicates.
    var maxMergeGap = 1

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
    private let logger = Logger(subsystem: "com.dido", category: "Context")

    func build(for item: SelectedItem, question: String, history: [ChatMessage] = [], budget: Int, includeImages: Bool, filter: RetrievalFilter = RetrievalFilter()) async -> RetrievedContext {
        let indexer = DocumentIndexer.shared
        let embedding = await LLMService.shared.makeEmbeddingProvider()
        let chunkProfile = await IndexSettings.shared.chunker.profile
        let started = Date()
        await indexer.ensureVectorIndexLoaded()
        await ensureIndexed(item, indexer: indexer, model: embedding.identifier, chunkProfile: chunkProfile)
        DebugLog.write("context: item indexed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        let scope = item.searchScope
        var passages = await VectorIndex.shared.entries(in: scope, filter: filter)
        let candidates = passages.count
        let total = passages.reduce(0) { $0 + $1.text.count }
        var mode = AnswerDetails.Mode.whole
        var scores: [UUID: Float] = [:]
        var textMatches: Set<UUID> = []
        var retrievalQuery: String?

        if passages.isEmpty {
            passages = await fallbackEntries(for: item, indexer: indexer)
        } else if total > budget {
            mode = .search
            let query = await LLMService.shared.retrievalQuery(for: question, history: history)
            if query != question { retrievalQuery = query }
            let hits = await hybridSearch(query, scope: scope, filter: filter, embedding: embedding)
            passages = hits.map(\.entry)
            for hit in hits {
                scores[hit.entry.chunkID] = hit.score
                if hit.matchedText { textMatches.insert(hit.entry.chunkID) }
            }
        }

        let extracts = mode == .search ? Self.merge(passages, scores: scores, textMatches: textMatches, gap: maxMergeGap) : passages.map { Extract(entry: $0, last: $0.ordinal, score: 1, matchedText: false) }

        var citations: [Citation] = []
        var lines: [String] = []
        var used = 0
        for (offset, extract) in extracts.enumerated() {
            let label = extract.last > extract.entry.ordinal ? "parts \(extract.entry.ordinal + 1)–\(extract.last + 1)" : "part \(extract.entry.ordinal + 1)"
            let block = "[\(offset + 1)] \(extract.entry.filename), \(label)\n\(extract.text)"
            guard used + block.count <= budget else { break }
            lines.append(block)
            used += block.count
            citations.append(Citation(index: offset + 1, path: extract.entry.path, filename: extract.entry.filename, ordinal: extract.entry.ordinal,
                                      start: extract.entry.start, end: extract.end, score: extract.score,
                                      ordinalEnd: extract.last > extract.entry.ordinal ? extract.last : nil,
                                      matchedText: extract.matchedText ? true : nil))
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
        logger.notice("Context for \(item.name): \(citations.count) extracts (\(mode.rawValue)) from \(candidates) candidates, \(used) characters")
        DebugLog.write("context: \(citations.count) extracts (\(mode)) from \(candidates) candidates after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        return RetrievedContext(text: text, citations: citations, images: images, mode: mode, candidates: candidates, retrievalQuery: retrievalQuery, filter: filter)
    }

    // MARK: - Indexing on demand

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

    // MARK: - Hybrid search

    private struct RankedHit {
        let entry: IndexEntry
        let score: Float
        let matchedText: Bool
    }

    /// Vector and full-text results fused by reciprocal rank (k = 60); the displayed score stays the cosine.
    private func hybridSearch(_ query: String, scope: SearchScope, filter: RetrievalFilter, embedding: any EmbeddingProvider) async -> [RankedHit] {
        let keywords = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
        var vectorHits: [SearchHit] = []
        do {
            if let vector = try await embedding.embed([query]).first {
                vectorHits = await VectorIndex.shared.search(query: vector, scope: scope, limit: topK * 3, minimumScore: minimumScore, keywords: keywords, filter: filter)
            }
        } catch {
            logger.error("Question embedding failed: \(error.localizedDescription)")
        }
        let textHits = await FullTextIndex.shared.search(query, limit: topK * 3)

        var fused: [UUID: (score: Double, entry: IndexEntry?, cosine: Float, text: Bool)] = [:]
        for (rank, hit) in vectorHits.enumerated() {
            fused[hit.entry.chunkID] = (1 / Double(60 + rank + 1), hit.entry, hit.score, false)
        }
        for (rank, hit) in textHits.enumerated() {
            let contribution = 1 / Double(60 + rank + 1)
            if var existing = fused[hit.chunkID] {
                existing.score += contribution
                existing.text = true
                fused[hit.chunkID] = existing
            } else if let entry = await VectorIndex.shared.entry(chunkID: hit.chunkID), scope.contains(entry.path), filter.allows(entry) {
                fused[hit.chunkID] = (contribution, entry, 0, true)
            }
        }
        if vectorHits.isEmpty && textHits.isEmpty {
            return await VectorIndex.shared.entries(in: scope, filter: filter).prefix(topK).map { RankedHit(entry: $0, score: 0, matchedText: false) }
        }
        return fused.values
            .compactMap { value in value.entry.map { RankedHit(entry: $0, score: value.cosine, matchedText: value.text) }.map { ($0, value.score) } }
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map(\.0)
    }

    // MARK: - Merging

    struct Extract {
        let entry: IndexEntry
        var last: Int
        var text: String
        var end: Int
        var score: Float
        var matchedText: Bool

        init(entry: IndexEntry, last: Int, score: Float, matchedText: Bool) {
            self.entry = entry
            self.last = last
            self.text = entry.text
            self.end = entry.end
            self.score = score
            self.matchedText = matchedText
        }
    }

    /// Joins passages from the same file whose ordinals are adjacent, trimming the chunk overlap, and drops
    /// passages whose text is already contained in another extract. Order is by best score.
    static func merge(_ passages: [IndexEntry], scores: [UUID: Float], textMatches: Set<UUID>, gap: Int) -> [Extract] {
        let ordered = passages.sorted { ($0.path, $0.ordinal) < ($1.path, $1.ordinal) }
        var extracts: [Extract] = []
        for passage in ordered {
            let score = scores[passage.chunkID] ?? 0
            let matched = textMatches.contains(passage.chunkID)
            if var current = extracts.last, current.entry.path == passage.path, passage.ordinal - current.last <= gap, passage.ordinal > current.last {
                current.text = join(current.text, passage.text)
                current.last = passage.ordinal
                current.end = passage.end
                current.score = max(current.score, score)
                current.matchedText = current.matchedText || matched
                extracts[extracts.count - 1] = current
            } else {
                extracts.append(Extract(entry: passage, last: passage.ordinal, score: score, matchedText: matched))
            }
        }
        var kept: [Extract] = []
        for extract in extracts.sorted(by: { $0.score > $1.score }) {
            if kept.contains(where: { $0.text.contains(extract.text) }) { continue }
            kept.append(extract)
        }
        return kept
    }

    /// Joins two consecutive chunks, removing the longest shared boundary text (the chunk overlap).
    private static func join(_ first: String, _ second: String) -> String {
        let limit = min(first.count, second.count, 400)
        var overlap = 0
        var length = limit
        while length >= 20 {
            if first.hasSuffix(String(second.prefix(length))) { overlap = length; break }
            length -= 1
        }
        return first + (overlap > 0 ? String(second.dropFirst(overlap)) : "\n" + second)
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
                entries.append(IndexEntry(chunkID: UUID(), path: url.path, filename: url.lastPathComponent, ordinal: ordinal, start: 0, end: 0, text: text, vector: [], modified: nil))
            }
        }
        return entries
    }
}
