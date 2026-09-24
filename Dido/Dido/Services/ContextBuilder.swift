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
    var superseded: [String] = []

    /// The record kept with the reply.
    func details(provider: String, scope: String) -> AnswerDetails {
        AnswerDetails(provider: provider, scope: scope, mode: mode, candidates: candidates, contextCharacters: text.count,
                      passages: citations, retrievalQuery: retrievalQuery, filter: filter.isEmpty ? nil : filter.summary,
                      supersededFiles: superseded.isEmpty ? nil : superseded)
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
        var filter = filter
        var superseded: [String] = []
        let wantsLatest = DocumentVersions.asksForLatest(question)
        if wantsLatest {
            (filter, superseded) = await Self.leavingOutOlderVersions(in: scope, filter: filter)
        }
        var passages = await VectorIndex.shared.entries(in: scope, filter: filter)
        let candidates = passages.count
        let total = passages.reduce(0) { $0 + $1.text.count }
        var mode = AnswerDetails.Mode.whole
        var scores: [UUID: Float] = [:]
        var textMatches: Set<UUID> = []
        var retrievalQuery: String?
        /// Opening passages of the newest documents, sent first and in document order for "latest" questions.
        var openingIDs: Set<UUID> = []

        if passages.isEmpty {
            passages = await fallbackEntries(for: item, indexer: indexer)
        } else if total > budget {
            mode = .search
            // A disputed or outdated earlier answer must not leak into the search query.
            let rewriteHistory = LLMService.distrustsEarlierAnswers(question) ? history.filter { $0.role == .user } : history
            let query = await LLMService.shared.retrievalQuery(for: question, history: rewriteHistory)
            if query != question { retrievalQuery = query }
            var hits = await hybridSearch(query, scope: scope, filter: filter, embedding: embedding)
            if wantsLatest, let newest = Self.newestDocuments(among: hits.map(\.entry)) {
                // Search again inside the newest relevant documents only, so their detail fills the budget,
                // and add their opening passages, where summaries and results usually sit.
                let scopePaths = Set(passages.map(\.path))
                filter.excludedPaths.formUnion(scopePaths.subtracting(newest.kept))
                superseded += newest.leftOut
                hits = await hybridSearch(query, scope: scope, filter: filter, embedding: embedding)
                let opening = Self.openingPassages(of: newest.kept, in: passages, budget: budget / 2)
                openingIDs = Set(opening.map(\.chunkID))
                let found = Set(hits.map(\.entry.chunkID))
                hits += opening.filter { !found.contains($0.chunkID) }.map { RankedHit(entry: $0, score: 0, matchedText: false) }
            }
            passages = hits.map(\.entry)
            for hit in hits {
                scores[hit.entry.chunkID] = hit.score
                if hit.matchedText { textMatches.insert(hit.entry.chunkID) }
            }
        }

        var extracts = mode == .search ? Self.merge(passages, scores: scores, textMatches: textMatches, gap: maxMergeGap) : passages.map { Extract(entry: $0, last: $0.ordinal, score: 1, matchedText: false) }
        if !openingIDs.isEmpty {
            // Opening passages first so the budget never cuts them; the chosen extracts are then put in document order.
            extracts = extracts.filter { openingIDs.contains($0.entry.chunkID) } + extracts.filter { !openingIDs.contains($0.entry.chunkID) }
        }

        var chosen: [(extract: Extract, block: String)] = []
        var used = 0
        for extract in extracts {
            var label = extract.last > extract.entry.ordinal ? "parts \(extract.entry.ordinal + 1)–\(extract.last + 1)" : "part \(extract.entry.ordinal + 1)"
            if let date = DocumentVersions.dateLabel(filename: extract.entry.filename, modified: extract.entry.modified) { label += ", \(date)" }
            let block = "\(extract.entry.filename), \(label)\n\(extract.text)"
            guard used + block.count + 6 <= budget else { break }
            chosen.append((extract, block))
            used += block.count + 6
        }
        if !openingIDs.isEmpty {
            chosen.sort { ($0.extract.entry.path, $0.extract.entry.ordinal) < ($1.extract.entry.path, $1.extract.entry.ordinal) }
        }

        var citations: [Citation] = []
        var lines: [String] = []
        for (offset, item) in chosen.enumerated() {
            let extract = item.extract
            lines.append("[\(offset + 1)] \(item.block)")
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
        return RetrievedContext(text: text, citations: citations, images: images, mode: mode, candidates: candidates, retrievalQuery: retrievalQuery, filter: filter, superseded: superseded)
    }

    /// The first passages of each file, in order, sharing `budget` characters between the files.
    static func openingPassages(of paths: Set<String>, in entries: [IndexEntry], budget: Int) -> [IndexEntry] {
        guard !paths.isEmpty else { return [] }
        let share = budget / paths.count
        var opening: [IndexEntry] = []
        for path in paths.sorted() {
            var used = 0
            for entry in entries.filter({ $0.path == path }).sorted(by: { $0.ordinal < $1.ordinal }) {
                guard used + entry.text.count <= share else { break }
                opening.append(entry)
                used += entry.text.count
            }
        }
        return opening
    }

    /// Days within which documents count as equally recent.
    private static let recencyWindowDays: Double = 3

    /// Among the files that matched, the ones dated within a few days of the newest, and notes on the older ones.
    /// Nil when every matching file is equally recent.
    static func newestDocuments(among entries: [IndexEntry]) -> (kept: Set<String>, leftOut: [String])? {
        var dates: [String: (name: String, date: Date)] = [:]
        for entry in entries where dates[entry.path] == nil {
            guard let date = DocumentVersions.nameDate(entry.filename) ?? entry.modified else { continue }
            dates[entry.path] = (entry.filename, date)
        }
        guard let newest = dates.values.map(\.date).max() else { return nil }
        let cutoff = newest.addingTimeInterval(-recencyWindowDays * 86_400)
        let kept = Set(dates.filter { $0.value.date >= cutoff }.keys)
        let older = dates.filter { $0.value.date < cutoff }
        guard !older.isEmpty else { return nil }
        let notes = older.values.sorted { $0.date > $1.date }.map { file in
            "\(file.name) (\(DocumentVersions.dateLabel(filename: file.name, modified: file.date) ?? "older"))"
        }
        DebugLog.write("context: latest question, kept \(kept.count) newest files, left out \(older.count) older ones")
        return (kept, notes)
    }

    /// Adds the older versions of every document in the scope to the filter's exclusions.
    private static func leavingOutOlderVersions(in scope: SearchScope, filter: RetrievalFilter) async -> (RetrievalFilter, [String]) {
        let entries = await VectorIndex.shared.entries(in: scope, filter: filter)
        var files: [String: Date?] = [:]
        for entry in entries where files[entry.path] == nil { files[entry.path] = entry.modified }
        let older = DocumentVersions.superseded(files.map { (path: $0.key, modified: $0.value) })
        guard !older.isEmpty else { return (filter, []) }
        var narrowed = filter
        narrowed.excludedPaths.formUnion(older.keys)
        let notes = older.map { "\(URL(fileURLWithPath: $0.key).lastPathComponent) → \($0.value)" }.sorted()
        DebugLog.write("context: left out \(older.count) older versions")
        return (narrowed, notes)
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
