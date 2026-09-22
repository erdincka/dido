import Foundation
import os

/// Live progress of the indexer, for the status bar and Settings.
@Observable @MainActor
final class IndexProgress {
    static let shared = IndexProgress()

    var isIndexing = false
    var currentFile = ""
    var completed = 0
    var total = 0
    /// Number of embedded chunks currently searchable.
    var vectorCount = 0

    private init() {}

    func begin(total: Int) {
        isIndexing = true
        completed = 0
        self.total = total
        currentFile = ""
    }

    func advance(to file: String) { currentFile = file }
    func fileDone() { completed += 1 }
    func setVectorCount(_ count: Int) { vectorCount = count }

    func end() {
        isIndexing = false
        currentFile = ""
    }
}

/// Walks files, parses, chunks, embeds and stores them, keeping the vector index current. One run at a time; cancellable.
actor DocumentIndexer {
    static let shared = DocumentIndexer()

    private let logger = Logger(subsystem: "com.dido", category: "Indexer")
    private var writer: IndexWriter?
    private var currentRun: Task<Void, Never>?
    private var indexLoaded = false
    private let embeddingBatchSize = 16

    private init() {}

    private func indexWriter() async -> IndexWriter? {
        if let writer { return writer }
        guard let container = await DataStore.shared.container else { return nil }
        let created = IndexWriter(modelContainer: container)
        writer = created
        return created
    }

    // MARK: - Queries used by the context builder

    func isIndexed(path: String) async -> Bool {
        await indexWriter()?.isIndexed(path: path) ?? false
    }

    /// True when the file has been indexed with the current embedding model since it was last modified.
    func isCurrent(url: URL, embeddingModel: String) async -> Bool {
        guard let existing = await indexWriter()?.existingDocument(at: url.path), existing.isIndexed else { return false }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return existing.dateIndexed >= modified && existing.embeddingModel == embeddingModel
    }

    func textChunks(for url: URL) async -> [String] {
        await indexWriter()?.textChunks(for: url.path) ?? []
    }

    func passages(for url: URL) async -> [Passage] {
        await indexWriter()?.passages(for: url.path) ?? []
    }

    /// Loads every chunk embedded with the current model into the in-memory vector index.
    func loadVectorIndex() async {
        let provider = await LLMService.shared.makeEmbeddingProvider()
        guard let writer = await indexWriter() else { return }
        let entries = await writer.entries(forModel: provider.identifier)
        await VectorIndex.shared.replaceAll(entries, model: provider.identifier)
        await IndexProgress.shared.setVectorCount(entries.count)
        indexLoaded = true
        logger.notice("Vector index loaded: \(entries.count) chunks for \(provider.identifier)")
    }

    /// Loads the index once, so a question asked right after launch still sees every passage.
    func ensureVectorIndexLoaded() async {
        if !indexLoaded {
            await loadVectorIndex()
        }
    }

    // MARK: - Maintenance

    func remove(path: String) async {
        try? await indexWriter()?.remove(path: path)
        await VectorIndex.shared.remove(path: path)
        await refreshCounts()
    }

    func remove(pathPrefix: String) async {
        try? await indexWriter()?.remove(pathPrefix: pathPrefix)
        await VectorIndex.shared.remove(pathPrefix: pathPrefix)
        await refreshCounts()
    }

    func removeAll() async {
        cancel()
        try? await indexWriter()?.removeAll()
        await VectorIndex.shared.removeAll()
        await refreshCounts()
    }

    /// Drops index entries for files that were deleted outside the app. Returns how many were removed.
    func removeMissing() async -> Int {
        guard let writer = await indexWriter() else { return 0 }
        let missing = await writer.missingPaths()
        for path in missing {
            try? await writer.remove(path: path)
            await VectorIndex.shared.remove(path: path)
        }
        await refreshCounts()
        return missing.count
    }

    /// Applies file-system changes reported by the watcher: reindex what exists, drop what is gone.
    func applyChanges(paths: [String]) async {
        guard let writer = await indexWriter() else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                if isDirectory.boolValue || DocumentParser.supportedExtensions.contains(url.pathExtension.lowercased()) {
                    await index(url, quiet: true)
                }
            } else if await writer.existingDocument(at: path) != nil {
                await remove(path: path)
            } else {
                await remove(pathPrefix: path)
            }
        }
    }

    private func refreshCounts() async {
        await IndexProgress.shared.setVectorCount(VectorIndex.shared.count)
        await AppState.shared.updateStats()
    }

    // MARK: - Runs

    /// Indexes a file or every file below a folder. Waits for any run already in progress.
    /// - Parameter quiet: suppresses the start and finish toasts (used for on-demand indexing during chat).
    func index(_ url: URL, quiet: Bool = false) async {
        while let running = currentRun {
            await running.value
        }
        let run = Task { await self.perform(url, quiet: quiet) }
        currentRun = run
        await run.value
        currentRun = nil
    }

    func cancel() {
        currentRun?.cancel()
    }

    private func perform(_ url: URL, quiet: Bool) async {
        guard let writer = await indexWriter() else {
            await AppState.shared.showNotification("Indexing is unavailable because the database could not be opened.", type: .error)
            return
        }
        let chunker = await IndexSettings.shared.chunker
        let parserOptions = await IndexSettings.shared.parserOptions
        let provider = await LLMService.shared.makeEmbeddingProvider()
        let loadedModel = await VectorIndex.shared.modelIdentifier
        if !indexLoaded || loadedModel != provider.identifier {
            await loadVectorIndex()
        }
        let name = url.lastPathComponent

        let files = await FileSystemScanner.shared.regularFiles(under: url)
        await IndexProgress.shared.begin(total: files.count)
        if !quiet {
            await AppState.shared.showNotification("Indexing \(name)…")
        }

        var embeddingsAvailable = true
        var stored = 0
        for file in files {
            if Task.isCancelled { break }
            await IndexProgress.shared.advance(to: file.lastPathComponent)
            if await indexFile(file, writer: writer, chunker: chunker, parserOptions: parserOptions, provider: provider, embeddingsAvailable: &embeddingsAvailable) {
                stored += 1
            }
            await IndexProgress.shared.fileDone()
        }

        let cancelled = Task.isCancelled
        await IndexProgress.shared.end()
        await IndexProgress.shared.setVectorCount(VectorIndex.shared.count)
        await AppState.shared.updateStats()
        if !quiet {
            if cancelled {
                await AppState.shared.showNotification("Indexing cancelled after \(stored) file\(stored == 1 ? "" : "s").")
            } else {
                await AppState.shared.showNotification("Indexed \(stored) file\(stored == 1 ? "" : "s") in \(name).", type: .success)
            }
        }
    }

    /// Returns true when the file's text was stored.
    private func indexFile(_ url: URL, writer: IndexWriter, chunker: TextChunker, parserOptions: ParserOptions, provider: any EmbeddingProvider, embeddingsAvailable: inout Bool) async -> Bool {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent

        func record(_ status: IndexStatus, detail: String? = nil) async {
            _ = try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: status, detail: detail, embeddingModel: nil, chunks: []))
            await VectorIndex.shared.remove(path: path)
        }

        guard DocumentParser.supportedExtensions.contains(ext) else {
            await record(.skippedUnsupported)
            return false
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        if let existing = await writer.existingDocument(at: path), existing.isIndexed, existing.dateIndexed >= modified,
           existing.embeddingModel == provider.identifier || !embeddingsAvailable {
            return false
        }

        let text: String
        do {
            text = try await DocumentParser.shared.text(of: url, options: parserOptions)
        } catch {
            logger.error("Parse failed for \(path): \(error.localizedDescription)")
            await record(.parseFailed, detail: error.localizedDescription)
            return false
        }

        let pieces = chunker.chunk(text)
        guard !pieces.isEmpty else {
            await record(.empty)
            return false
        }

        var vectors: [[Float]] = []
        if embeddingsAvailable {
            for batchStart in stride(from: 0, to: pieces.count, by: embeddingBatchSize) {
                if Task.isCancelled { return false }
                let batch = Array(pieces[batchStart..<min(batchStart + embeddingBatchSize, pieces.count)])
                do {
                    vectors.append(contentsOf: try await provider.embed(batch.map(\.text)))
                } catch {
                    embeddingsAvailable = false
                    vectors = []
                    logger.error("Embeddings disabled for this run: \(error.localizedDescription)")
                    await AppState.shared.showNotification("Embeddings unavailable: \(error.localizedDescription) Indexing text only.", type: .error)
                    break
                }
            }
        }
        let embedded = vectors.count == pieces.count
        let chunks = pieces.enumerated().map { offset, piece in
            IndexedChunk(ordinal: offset, text: piece.text, start: piece.start, end: piece.end, vector: embedded ? vectors[offset] : [])
        }

        do {
            let entries = try await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: .indexed, detail: nil,
                                                             embeddingModel: embedded ? provider.identifier : nil, chunks: chunks))
            if embedded {
                await VectorIndex.shared.replace(path: path, with: entries, model: provider.identifier)
            } else {
                await VectorIndex.shared.remove(path: path)
            }
            logger.info("Indexed \(path) (\(chunks.count) chunks, embedded: \(embedded))")
            return true
        } catch {
            logger.error("Store failed for \(path): \(error.localizedDescription)")
            return false
        }
    }
}
