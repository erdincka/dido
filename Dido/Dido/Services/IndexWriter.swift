import Foundation
import SwiftData

/// A parsed file ready to be stored.
struct IndexedFile: Sendable {
    let path: String
    let filename: String
    let type: String
    let status: IndexStatus
    let detail: String?
    let embeddingModel: String?
    let chunks: [IndexedChunk]
}

struct IndexedChunk: Sendable {
    let ordinal: Int
    let text: String
    let start: Int
    let end: Int
    let vector: [Float]
}

/// A stored chunk with its offsets.
struct Passage: Sendable, Hashable {
    let ordinal: Int
    let text: String
    let start: Int
    let end: Int
}

/// What the indexer needs to know about a previously indexed file.
struct ExistingDocument: Sendable {
    let id: PersistentIdentifier
    let dateIndexed: Date
    let isIndexed: Bool
    let embeddingModel: String?
}

/// Background writer for the index. All SwiftData work for indexing happens here, off the main actor.
@ModelActor
actor IndexWriter {
    func existingDocument(at path: String) -> ExistingDocument? {
        guard let document = fetchDocument(path) else { return nil }
        return ExistingDocument(id: document.persistentModelID, dateIndexed: document.dateIndexed, isIndexed: document.isIndexed, embeddingModel: document.embeddingModel)
    }

    func isIndexed(path: String) -> Bool {
        existingDocument(at: path)?.isIndexed ?? false
    }

    /// Replaces whatever is stored for the file's path with `file`. Returns the stored chunks as index entries.
    @discardableResult
    func store(_ file: IndexedFile) throws -> [IndexEntry] {
        let path = file.path
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        for stale in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(stale)
        }
        let document = Document(filename: file.filename, path: file.path, type: file.type, status: file.status, detail: file.detail)
        document.embeddingModel = file.embeddingModel
        document.embeddingDimension = file.chunks.first?.vector.count ?? 0
        let chunks = file.chunks.map { DocumentChunk(ordinal: $0.ordinal, text: $0.text, vector: $0.vector, startOffset: $0.start, endOffset: $0.end) }
        document.chunks = chunks
        modelContext.insert(document)
        try modelContext.save()
        return chunks.compactMap { Self.entry(for: $0, in: document) }
    }

    /// The text of every chunk for a file, in order.
    func textChunks(for path: String) -> [String] {
        guard let document = fetchDocument(path) else { return [] }
        return document.chunks.sorted { $0.ordinal < $1.ordinal }.map(\.text)
    }

    /// Chunks with offsets for the preview pane.
    func passages(for path: String) -> [Passage] {
        guard let document = fetchDocument(path) else { return [] }
        return document.chunks.sorted { $0.ordinal < $1.ordinal }.map { Passage(ordinal: $0.ordinal, text: $0.text, start: $0.startOffset, end: $0.endOffset) }
    }

    func remove(path: String) throws {
        for document in (try? modelContext.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.path == path }))) ?? [] {
            modelContext.delete(document)
        }
        try modelContext.save()
    }

    /// Removes every document at or below a folder path.
    func remove(pathPrefix: String) throws {
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        for document in (try? modelContext.fetch(FetchDescriptor<Document>(predicate: #Predicate { $0.path.starts(with: prefix) }))) ?? [] {
            modelContext.delete(document)
        }
        try modelContext.save()
    }

    func removeAll() throws {
        try modelContext.delete(model: DocumentChunk.self)
        try modelContext.delete(model: Document.self)
        try modelContext.save()
    }

    /// Paths of indexed files that no longer exist on disk.
    func missingPaths() -> [String] {
        let documents = (try? modelContext.fetch(FetchDescriptor<Document>())) ?? []
        return documents.map(\.path).filter { !FileManager.default.fileExists(atPath: $0) }
    }

    /// Every embedded chunk produced with `model`, for loading the vector index at launch.
    func entries(forModel model: String) -> [IndexEntry] {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.isIndexed && $0.embeddingModel == model })
        let documents = (try? modelContext.fetch(descriptor)) ?? []
        return documents.flatMap { document in
            document.chunks.compactMap { Self.entry(for: $0, in: document) }
        }
    }

    private func fetchDocument(_ path: String) -> Document? {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        return (try? modelContext.fetch(descriptor))?.first
    }

    private static func entry(for chunk: DocumentChunk, in document: Document) -> IndexEntry? {
        guard !chunk.vector.isEmpty else { return nil }
        return IndexEntry(chunkID: chunk.id, path: document.path, filename: document.filename, ordinal: chunk.ordinal,
                          start: chunk.startOffset, end: chunk.endOffset, text: chunk.text, vector: chunk.vector)
    }
}
