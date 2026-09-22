import Foundation
import SwiftData

/// A parsed file ready to be stored.
struct IndexedFile: Sendable {
    let path: String
    let filename: String
    let type: String
    let status: IndexStatus
    let detail: String?
    let chunks: [IndexedChunk]
}

struct IndexedChunk: Sendable {
    let ordinal: Int
    let text: String
    let vector: [Float]
}

/// What the indexer needs to know about a previously indexed file.
struct ExistingDocument: Sendable {
    let id: PersistentIdentifier
    let dateIndexed: Date
    let isIndexed: Bool
}

/// Background writer for the index. All SwiftData work for indexing happens here, off the main actor.
@ModelActor
actor IndexWriter {
    func existingDocument(at path: String) -> ExistingDocument? {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        guard let document = (try? modelContext.fetch(descriptor))?.first else { return nil }
        return ExistingDocument(id: document.persistentModelID, dateIndexed: document.dateIndexed, isIndexed: document.isIndexed)
    }

    func isIndexed(path: String) -> Bool {
        existingDocument(at: path)?.isIndexed ?? false
    }

    /// Replaces whatever is stored for the file's path with `file`.
    func store(_ file: IndexedFile) throws {
        let path = file.path
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        for stale in (try? modelContext.fetch(descriptor)) ?? [] {
            modelContext.delete(stale)
        }
        let document = Document(filename: file.filename, path: file.path, type: file.type, status: file.status, detail: file.detail)
        document.chunks = file.chunks.map { DocumentChunk(ordinal: $0.ordinal, text: $0.text, vector: $0.vector) }
        modelContext.insert(document)
        try modelContext.save()
    }

    /// The text of every chunk for a file, in order.
    func textChunks(for path: String) -> [String] {
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        guard let document = (try? modelContext.fetch(descriptor))?.first else { return [] }
        return document.chunks.sorted { $0.ordinal < $1.ordinal }.map(\.text)
    }
}
