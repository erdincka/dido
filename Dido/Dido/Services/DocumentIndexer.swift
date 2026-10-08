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
    /// Number of embedded chunks currently searchable, across every library.
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

/// Walks files, parses, chunks, embeds and stores them in the index of the library they belong to.
/// One run at a time; cancellable.
actor DocumentIndexer {
    static let shared = DocumentIndexer()

    private let logger = Logger(subsystem: "com.dido", category: "Indexer")
    private var currentRun: Task<Void, Never>?
    /// The library the running scan started in.
    private var currentLibraryID: UUID?
    /// The embedding model each library's vector index was loaded for.
    private var loadedModels: [UUID: String] = [:]
    private var loads: [UUID: Task<Void, Never>] = [:]
    /// Files that must be handled before the running scan continues, with the callers waiting for them.
    private var priority: [URL] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let embeddingBatchSize = 16

    private init() {}

    // MARK: - Libraries

    private func library(containing path: String) async -> LibraryIndex? {
        await LibraryManager.shared.index(containing: path)
    }

    private func library(id: UUID) async -> LibraryIndex? {
        await LibraryManager.shared.index(for: id)
    }

    /// Forgets a removed library's loaded index and stops its scan if one is running.
    func libraryRemoved(_ id: UUID) {
        loadedModels[id] = nil
        if currentLibraryID == id { cancel() }
    }

    // MARK: - Queries used by the context builder

    func isIndexed(path: String) async -> Bool {
        await library(containing: path)?.writer?.isIndexed(path: path) ?? false
    }

    enum Freshness: Sendable { case current, stale, missing }

    /// Whether the file's index is usable as is, usable but out of date, or absent.
    func freshness(of url: URL, embeddingModel: String, chunkProfile: String) async -> Freshness {
        guard let writer = await library(containing: url.path)?.writer,
              let existing = await writer.existingDocument(at: url.path), existing.isIndexed else { return .missing }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let current = existing.dateIndexed >= modified && existing.embeddingModel == embeddingModel && existing.chunkProfile == chunkProfile
        return current ? .current : .stale
    }

    var isRunning: Bool { currentRun != nil }

    func textChunks(for url: URL) async -> [String] {
        await library(containing: url.path)?.writer?.textChunks(for: url.path) ?? []
    }

    func passages(for url: URL) async -> [Passage] {
        await library(containing: url.path)?.writer?.passages(for: url.path) ?? []
    }

    // MARK: - Loading the indexes

    /// Loads every active library's vector index for the current embedding model: at launch and when the model changes.
    func loadIndexes() async {
        let ids = await LibraryManager.shared.active.map(\.id)
        for id in ids {
            await loadIndex(id)
        }
        await publishVectorCount()
    }

    /// Loads one library's index, from its file when that matches the model, else from its store. Concurrent callers share one load.
    func loadIndex(_ id: UUID) async {
        if let load = loads[id] {
            await load.value
            return
        }
        let load = Task { await self.performLoad(id) }
        loads[id] = load
        await load.value
        loads[id] = nil
    }

    private func performLoad(_ id: UUID) async {
        guard let library = await library(id: id), let writer = library.writer else { return }
        let provider = await LLMService.shared.makeEmbeddingProvider()
        let started = Date()
        var source = "file"
        var loaded = await library.vectors.load(expectedModel: provider.identifier)
        if loaded {
            // Files saved by earlier builds could bring back passages of re-indexed or removed files.
            let stored = await writer.chunkCount(forModel: provider.identifier)
            let rows = await library.vectors.count
            if rows > stored {
                logger.notice("Vector index of \(library.name) has \(rows) rows but the store has \(stored) chunks; rebuilding it")
                DebugLog.write("vector index \(library.name): file has \(rows) rows, store \(stored); rebuilding")
                loaded = false
            }
        }
        if !loaded {
            source = "store"
            let entries = await writer.entries(forModel: provider.identifier)
            await library.vectors.replaceAll(entries, model: provider.identifier)
            await library.vectors.save()
        }
        let count = await library.vectors.count
        if await library.fullText.count == 0, count > 0 {
            await library.fullText.rebuild(from: library.vectors.entries(in: .all))
        }
        loadedModels[id] = provider.identifier
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        logger.notice("Vector index of \(library.name) loaded from \(source): \(count) chunks for \(provider.identifier) in \(seconds)s")
        DebugLog.write("vector index \(library.name): \(count) chunks loaded from \(source) in \(seconds)s")
    }

    /// Loads a library's index once, so a question asked right after launch still sees every passage.
    func ensureLoaded(_ id: UUID) async {
        guard loadedModels[id] == nil else { return }
        await loadIndex(id)
        await publishVectorCount()
    }

    private func publishVectorCount() async {
        var total = 0
        for library in await LibraryManager.shared.openIndexes {
            total += await library.vectors.count
        }
        await IndexProgress.shared.setVectorCount(total)
    }

    // MARK: - Maintenance

    func remove(path: String) async {
        guard let library = await library(containing: path) else { return }
        try? await library.writer?.remove(path: path)
        await library.vectors.remove(path: path)
        await library.fullText.remove(path: path)
        await refreshCounts()
    }

    func remove(pathPrefix: String) async {
        guard let library = await library(containing: pathPrefix) else { return }
        try? await library.writer?.remove(pathPrefix: pathPrefix)
        await library.vectors.remove(pathPrefix: pathPrefix)
        await library.fullText.remove(pathPrefix: pathPrefix)
        await refreshCounts()
    }

    /// Clears one library's index: every document, passage and vector. Chat history is kept.
    func removeAll(in id: UUID) async {
        if currentLibraryID == id { cancel() }
        guard let library = await library(id: id) else { return }
        try? await library.writer?.removeAll()
        await library.vectors.removeAll()
        await library.fullText.removeAll()
        await refreshCounts()
    }

    /// Clears a library's index and scans its folder again from scratch.
    func rebuild(_ id: UUID) async {
        await removeAll(in: id)
        guard let root = await LibraryManager.shared.root(of: id) else { return }
        await index(root)
    }

    /// Drops index entries of a library for files that were deleted outside the app. Returns how many were removed.
    func removeMissing(in id: UUID) async -> Int {
        guard let library = await library(id: id), let writer = library.writer else { return 0 }
        let missing = await writer.missingPaths()
        for path in missing {
            try? await writer.remove(path: path)
            await library.vectors.remove(path: path)
            await library.fullText.remove(path: path)
        }
        await refreshCounts()
        return missing.count
    }

    /// Applies file-system changes reported by the watchers: reindex what exists, drop what is gone.
    func applyChanges(paths: [String]) async {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }
            if await FileSystemScanner.shared.isIgnored(url) { continue }
            guard let writer = await library(containing: path)?.writer else { continue }
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

    /// Recounts passages and documents across every library, for the status bar.
    func refreshCounts() async {
        await publishVectorCount()
        await AppState.shared.updateStats()
    }

    // MARK: - Runs

    enum RunReason: Sendable { case manual, background, onDemand }

    /// Scans every active library in turn, with the usual toasts.
    func indexAllLibraries() async {
        for root in await LibraryManager.shared.activeRoots {
            await index(root)
        }
    }

    /// Indexes a file or every file below a folder, in the index of the library that contains it.
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
        currentLibraryID = nil
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
        guard let library = await library(containing: url.path) else {
            DebugLog.write("index: \(url.path) is not inside any library")
            if !quiet {
                await AppState.shared.showNotification("\(url.lastPathComponent) is not inside any of your libraries.", type: .error)
            }
            return
        }
        guard library.writer != nil else {
            await AppState.shared.showNotification("Indexing is unavailable because the database of \(library.name) could not be opened.", type: .error)
            return
        }
        currentLibraryID = library.id
        let chunker = await IndexSettings.shared.chunker
        let parserOptions = await IndexSettings.shared.parserOptions
        let maxBytes = await Int64(IndexSettings.shared.maxFileSizeMB) * 1_048_576
        let provider = await LLMService.shared.makeEmbeddingProvider()
        if loadedModels[library.id] != provider.identifier {
            await loadIndex(library.id)
        }
        let name = url.lastPathComponent

        let files = await FileSystemScanner.shared.regularFiles(under: url)
        await IndexProgress.shared.begin(total: files.count)
        DebugLog.write("index: \(name) in library \(library.name), \(files.count) files, reason \(reason)")
        if !quiet {
            await AppState.shared.showNotification("Indexing \(name)…")
        }

        var embeddingsAvailable = true
        var stored = 0
        var failed = 0
        /// Every library written to during this run, so each vector index is saved at the end.
        var touched: [UUID: LibraryIndex] = [library.id: library]
        var remaining = files[...]
        while let file = nextFile(from: &remaining) {
            if Task.isCancelled { break }
            await IndexProgress.shared.advance(to: file.lastPathComponent)
            var target = library
            if !library.contains(file.path) {
                // A priority request from another library while this scan runs.
                guard let other = await self.library(containing: file.path) else {
                    resumeWaiters(for: file.path)
                    await IndexProgress.shared.fileDone()
                    continue
                }
                if loadedModels[other.id] != provider.identifier {
                    await loadIndex(other.id)
                }
                touched[other.id] = other
                target = other
            }
            let outcome = await indexFile(file, library: target, chunker: chunker, parserOptions: parserOptions, provider: provider, maxBytes: maxBytes, embeddingsAvailable: &embeddingsAvailable)
            switch outcome {
            case .stored: stored += 1
            case .failed: failed += 1
            case .skipped: break
            }
            resumeWaiters(for: file.path)
            await IndexProgress.shared.fileDone()
        }

        let cancelled = Task.isCancelled
        for index in touched.values {
            await index.vectors.save()
        }
        await IndexProgress.shared.end()
        await refreshCounts()
        let summary = cancelled
            ? "Indexing cancelled after \(stored) file\(stored == 1 ? "" : "s")."
            : "Indexed \(stored) file\(stored == 1 ? "" : "s") in \(name)." + (failed > 0 ? " \(failed) could not be read." : "")
        DebugLog.write("index: \(summary)")
        if !quiet {
            await AppState.shared.showNotification(summary, type: cancelled || failed > 0 ? .info : .success)
        }
        if reason != .onDemand, stored > 0 || failed > 0 {
            await LibraryNotifier.shared.notify(title: cancelled ? "Dido stopped indexing" : "Dido finished indexing", body: summary)
        }
    }

    private enum FileOutcome { case stored, skipped, failed }

    private func indexFile(_ url: URL, library: LibraryIndex, chunker: TextChunker, parserOptions: ParserOptions, provider: any EmbeddingProvider, maxBytes: Int64, embeddingsAvailable: inout Bool) async -> FileOutcome {
        guard let writer = library.writer else { return .failed }
        let path = url.path
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? Date()

        func record(_ status: IndexStatus, detail: String? = nil) async {
            _ = try? await writer.store(IndexedFile(path: path, filename: filename, type: ext, status: status, detail: detail, embeddingModel: nil, chunkProfile: nil, fileModified: modified, chunks: []))
            await library.vectors.remove(path: path)
            await library.fullText.remove(path: path)
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
            DebugLog.write("index: parse failed for \(filename): \(error.localizedDescription)")
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
                    DebugLog.write("index: embeddings unavailable: \(error.localizedDescription)")
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
                await library.vectors.replace(path: path, with: entries, model: provider.identifier)
            } else {
                await library.vectors.remove(path: path)
            }
            await library.fullText.replace(path: path, passages: entries.map { ($0.chunkID, $0.ordinal, $0.text) })
            logger.info("Indexed \(path) (\(chunks.count) chunks, embedded: \(embedded))")
            return .stored
        } catch {
            logger.error("Store failed for \(path): \(error.localizedDescription)")
            DebugLog.write("index: store failed for \(filename): \(error.localizedDescription)")
            return .failed
        }
    }
}
