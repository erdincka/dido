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
    /// Files that must be handled before the running scan continues, with the callers waiting for them.
    private var priority: [URL] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var indexLoad: Task<Void, Never>?
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

    enum Freshness: Sendable { case current, stale, missing }

    /// Whether the file's index is usable as is, usable but out of date, or absent.
    func freshness(of url: URL, embeddingModel: String, chunkProfile: String) async -> Freshness {
        guard let existing = await indexWriter()?.existingDocument(at: url.path), existing.isIndexed else { return .missing }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let current = existing.dateIndexed >= modified && existing.embeddingModel == embeddingModel && existing.chunkProfile == chunkProfile
        return current ? .current : .stale
    }

    var isRunning: Bool { currentRun != nil }

    func textChunks(for url: URL) async -> [String] {
        await indexWriter()?.textChunks(for: url.path) ?? []
    }

    func passages(for url: URL) async -> [Passage] {
        await indexWriter()?.passages(for: url.path) ?? []
    }

    /// Loads every chunk embedded with the current model into the in-memory vector index. Concurrent callers share one load.
    func loadVectorIndex() async {
        if let indexLoad {
            await indexLoad.value
            return
        }
        let load = Task { await self.performLoad() }
        indexLoad = load
        await load.value
        indexLoad = nil
    }

    private func performLoad() async {
        let provider = await LLMService.shared.makeEmbeddingProvider()
        guard let writer = await indexWriter() else { return }
        let started = Date()
        var source = "file"
        var loaded = await VectorIndex.shared.load(expectedModel: provider.identifier)
        if loaded {
            // Files saved by earlier builds could bring back passages of re-indexed or removed files.
            let stored = await writer.chunkCount(forModel: provider.identifier)
            let rows = await VectorIndex.shared.count
            if rows > stored {
                logger.notice("Vector index file has \(rows) rows but the store has \(stored) chunks; rebuilding it")
                DebugLog.write("vector index: file has \(rows) rows, store \(stored); rebuilding")
                loaded = false
            }
        }
        if !loaded {
            source = "store"
            let entries = await writer.entries(forModel: provider.identifier)
            await VectorIndex.shared.replaceAll(entries, model: provider.identifier)
            await VectorIndex.shared.save()
        }
        let count = await VectorIndex.shared.count
        if await FullTextIndex.shared.count == 0, count > 0 {
            await FullTextIndex.shared.rebuild(from: VectorIndex.shared.entries(in: .all))
        }
        await IndexProgress.shared.setVectorCount(count)
        indexLoaded = true
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        logger.notice("Vector index loaded from \(source): \(count) chunks for \(provider.identifier) in \(seconds)s")
        DebugLog.write("vector index: \(count) chunks loaded from \(source) in \(seconds)s")
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
        await FullTextIndex.shared.remove(path: path)
        await refreshCounts()
    }

    func remove(pathPrefix: String) async {
        try? await indexWriter()?.remove(pathPrefix: pathPrefix)
        await VectorIndex.shared.remove(pathPrefix: pathPrefix)
        await FullTextIndex.shared.remove(pathPrefix: pathPrefix)
        await refreshCounts()
    }

    func removeAll() async {
        cancel()
        try? await indexWriter()?.removeAll()
        await VectorIndex.shared.removeAll()
        await FullTextIndex.shared.removeAll()
        await refreshCounts()
    }

    /// Drops index entries for files that were deleted outside the app. Returns how many were removed.
    func removeMissing() async -> Int {
        guard let writer = await indexWriter() else { return 0 }
        let missing = await writer.missingPaths()
        for path in missing {
            try? await writer.remove(path: path)
            await VectorIndex.shared.remove(path: path)
            await FullTextIndex.shared.remove(path: path)
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
            if await FileSystemScanner.shared.isIgnored(url) { continue }
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

    enum RunReason: Sendable { case manual, background, onDemand }

    /// Indexes a file or every file below a folder.
    /// While a scan is running, the files are pushed to the front of its queue and this call returns when they are done.
    /// - Parameter quiet: suppresses the start and finish toasts (used for on-demand indexing during chat).
    func index(_ url: URL, quiet: Bool = false, reason: RunReason? = nil) async {
        if currentRun != nil {
            let files = await FileSystemScanner.shared.regularFiles(under: url)
            guard !files.isEmpty else { return }
            for file in files.reversed() where !priority.contains(file) {
                priority.insert(file, at: 0)
            }
            for file in files {
                await withCheckedContinuation { continuation in
                    if currentRun == nil {
                        continuation.resume()
                    } else {
                        waiters[file.path, default: []].append(continuation)
                    }
                }
            }
            return
        }
        let run = Task { await self.perform(url, quiet: quiet, reason: reason ?? (quiet ? .onDemand : .manual)) }
        currentRun = run
        await run.value
        currentRun = nil
        resumeAllWaiters()
    }

    private func resumeWaiters(for path: String) {
        for continuation in waiters.removeValue(forKey: path) ?? [] { continuation.resume() }
    }

    private func resumeAllWaiters() {
        for continuations in waiters.values { for continuation in continuations { continuation.resume() } }
        waiters.removeAll()
    }

    /// The next file to handle: a priority request first, otherwise the scan's own list.
    private func nextFile(from files: inout ArraySlice<URL>) -> URL? {
        if !priority.isEmpty { return priority.removeFirst() }
        return files.popFirst()
    }

    func cancel() {
        currentRun?.cancel()
    }

    private func perform(_ url: URL, quiet: Bool, reason: RunReason) async {
        guard let writer = await indexWriter() else {
            await AppState.shared.showNotification("Indexing is unavailable because the database could not be opened.", type: .error)
            return
        }
        let chunker = await IndexSettings.shared.chunker
        let parserOptions = await IndexSettings.shared.parserOptions
        let maxBytes = await Int64(IndexSettings.shared.maxFileSizeMB) * 1_048_576
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
        var failed = 0
        var remaining = files[...]
        while let file = nextFile(from: &remaining) {
            if Task.isCancelled { break }
            await IndexProgress.shared.advance(to: file.lastPathComponent)
            let outcome = await indexFile(file, writer: writer, chunker: chunker, parserOptions: parserOptions, provider: provider, maxBytes: maxBytes, embeddingsAvailable: &embeddingsAvailable)
            switch outcome {
            case .stored: stored += 1
            case .failed: failed += 1
            case .skipped: break
            }
            resumeWaiters(for: file.path)
            await IndexProgress.shared.fileDone()
        }

        let cancelled = Task.isCancelled
        await VectorIndex.shared.save()
        await IndexProgress.shared.end()
        await IndexProgress.shared.setVectorCount(VectorIndex.shared.count)
        await AppState.shared.updateStats()
        let summary = cancelled
            ? "Indexing cancelled after \(stored) file\(stored == 1 ? "" : "s")."
            : "Indexed \(stored) file\(stored == 1 ? "" : "s") in \(name)." + (failed > 0 ? " \(failed) could not be read." : "")
        if !quiet {
            await AppState.shared.showNotification(summary, type: cancelled || failed > 0 ? .info : .success)
        }
        if reason != .onDemand, stored > 0 || failed > 0 {
            await LibraryNotifier.shared.notify(title: cancelled ? "Dido stopped indexing" : "Dido finished indexing", body: summary)
        }
    }

    private enum FileOutcome { case stored, skipped, failed }

    private func indexFile(_ url: URL, writer: IndexWriter, chunker: TextChunker, parserOptions: ParserOptions, provider: any EmbeddingProvider, maxBytes: Int64, embeddingsAvailable: inout Bool) async -> FileOutcome {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? Date()

        func record(_ status: IndexStatus, detail: String? = nil) async {
            _ = try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: status, detail: detail, embeddingModel: nil, chunkProfile: nil, fileModified: modified, chunks: []))
            await VectorIndex.shared.remove(path: path)
            await FullTextIndex.shared.remove(path: path)
        }

        guard DocumentParser.supportedExtensions.contains(ext) else {
            await record(.skippedUnsupported)
            return .skipped
        }
        if let size = values?.fileSize, Int64(size) > maxBytes {
            await record(.skippedTooLarge, detail: "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) exceeds the limit in Settings")
            return .skipped
        }

        if let existing = await writer.existingDocument(at: path), existing.isIndexed, existing.dateIndexed >= modified,
           existing.chunkProfile == chunker.profile, existing.embeddingModel == provider.identifier || !embeddingsAvailable {
            return .skipped
        }

        let text: String
        do {
            text = try await DocumentParser.shared.text(of: url, options: parserOptions)
        } catch {
            logger.error("Parse failed for \(path): \(error.localizedDescription)")
            await record(.parseFailed, detail: error.localizedDescription)
            return .failed
        }

        let kind: TextKind = ext == "csv" ? .csv : (DocumentParser.converterExtensions.contains(ext) ? .markdownWithTables : .prose)
        let pieces = chunker.chunk(text, kind: kind)
        guard !pieces.isEmpty else {
            await record(.empty)
            return .skipped
        }

        var vectors: [[Float]] = []
        if embeddingsAvailable {
            for batchStart in stride(from: 0, to: pieces.count, by: embeddingBatchSize) {
                if Task.isCancelled { return .skipped }
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
                                                             embeddingModel: embedded ? provider.identifier : nil, chunkProfile: chunker.profile, fileModified: modified, chunks: chunks))
            if embedded {
                await VectorIndex.shared.replace(path: path, with: entries, model: provider.identifier)
            } else {
                await VectorIndex.shared.remove(path: path)
            }
            await FullTextIndex.shared.replace(path: path, passages: entries.map { ($0.chunkID, $0.ordinal, $0.text) })
            logger.info("Indexed \(path) (\(chunks.count) chunks, embedded: \(embedded))")
            return .stored
        } catch {
            logger.error("Store failed for \(path): \(error.localizedDescription)")
            return .failed
        }
    }
}
