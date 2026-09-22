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

    private init() {}

    func begin(total: Int) {
        isIndexing = true
        completed = 0
        self.total = total
        currentFile = ""
    }

    func advance(to file: String) {
        currentFile = file
    }

    func fileDone() {
        completed += 1
    }

    func end() {
        isIndexing = false
        currentFile = ""
    }
}

/// Walks files, parses, chunks, optionally embeds, and stores them. One run at a time; cancellable.
actor DocumentIndexer {
    static let shared = DocumentIndexer()

    private let logger = Logger(subsystem: "com.dido", category: "Indexer")
    private var writer: IndexWriter?
    private var currentRun: Task<Void, Never>?

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

    func textChunks(for url: URL) async -> [String] {
        await indexWriter()?.textChunks(for: url.path) ?? []
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
        let configuration = await IndexSettings.shared.configuration
        let client = await LLMService.shared.makeClient()
        let name = url.lastPathComponent

        let files = await FileSystemScanner.shared.regularFiles(under: url)
        await IndexProgress.shared.begin(total: files.count)
        if !quiet {
            await AppState.shared.showNotification("Indexing \(name)…")
        }

        var embeddingsAvailable = configuration.embeddingsEnabled
        var stored = 0
        for file in files {
            if Task.isCancelled { break }
            await IndexProgress.shared.advance(to: file.lastPathComponent)
            let result = await indexFile(file, writer: writer, configuration: configuration, client: client, embeddingsAvailable: &embeddingsAvailable)
            if result { stored += 1 }
            await IndexProgress.shared.fileDone()
        }

        let cancelled = Task.isCancelled
        await IndexProgress.shared.end()
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
    private func indexFile(_ url: URL, writer: IndexWriter, configuration: IndexerConfiguration, client: OpenAICompatibleClient, embeddingsAvailable: inout Bool) async -> Bool {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent

        guard DocumentParser.supportedExtensions.contains(ext) else {
            try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: .skippedUnsupported, detail: nil, chunks: []))
            return false
        }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        if let existing = await writer.existingDocument(at: path), existing.isIndexed, existing.dateIndexed >= modified {
            return false
        }

        let text: String
        do {
            text = try await DocumentParser.shared.text(of: url)
        } catch {
            logger.error("Parse failed for \(path): \(error.localizedDescription)")
            try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: .parseFailed, detail: error.localizedDescription, chunks: []))
            return false
        }

        let pieces = configuration.chunker.chunk(text)
        guard !pieces.isEmpty else {
            try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: .empty, detail: nil, chunks: []))
            return false
        }

        var chunks: [IndexedChunk] = []
        for (ordinal, piece) in pieces.enumerated() {
            if Task.isCancelled { return false }
            var vector: [Float] = []
            if embeddingsAvailable {
                do {
                    vector = try await client.embedding(for: piece, model: configuration.embeddingModel)
                } catch {
                    embeddingsAvailable = false
                    logger.error("Embeddings disabled for this run: \(error.localizedDescription)")
                    await AppState.shared.showNotification("Embeddings unavailable (\(error.localizedDescription)). Indexing text only.", type: .error)
                }
            }
            chunks.append(IndexedChunk(ordinal: ordinal, text: piece, vector: vector))
        }

        do {
            try await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: .indexed, detail: nil, chunks: chunks))
            logger.info("Indexed \(path) (\(chunks.count) chunks)")
            return true
        } catch {
            logger.error("Store failed for \(path): \(error.localizedDescription)")
            return false
        }
    }
}
