import Foundation
import SwiftData

/// Outcome of the last indexing attempt for a file.
enum IndexStatus: String, Codable, Sendable {
    case indexed
    case skippedUnsupported
    case parseFailed
    case empty
    case cancelled

    var label: String {
        switch self {
        case .indexed: return "Indexed"
        case .skippedUnsupported: return "Unsupported type"
        case .parseFailed: return "Could not read"
        case .empty: return "No text found"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Index

@Model
final class Document {
    var id: UUID
    var filename: String
    var path: String
    var type: String
    var dateIndexed: Date
    var isIndexed: Bool
    var statusRaw: String
    /// Human-readable detail for failures, for example the parser's error message.
    var detail: String?
    /// Identifier of the embedding model used for this document's chunks, nil when none were generated.
    var embeddingModel: String?
    var embeddingDimension: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \DocumentChunk.document)
    var chunks: [DocumentChunk] = []

    var status: IndexStatus {
        get { IndexStatus(rawValue: statusRaw) ?? .parseFailed }
        set { statusRaw = newValue.rawValue }
    }

    init(filename: String, path: String, type: String, dateIndexed: Date = Date(), status: IndexStatus, detail: String? = nil) {
        self.id = UUID()
        self.filename = filename
        self.path = path
        self.type = type
        self.dateIndexed = dateIndexed
        self.isIndexed = status == .indexed
        self.statusRaw = status.rawValue
        self.detail = detail
    }
}

@Model
final class DocumentChunk {
    var id: UUID
    /// Position of the chunk within its document, starting at zero.
    var ordinal: Int
    var text: String
    /// Embedding vector; empty when embeddings were not generated.
    var vector: [Float]
    /// UTF-16 offsets of the chunk within the document's extracted text.
    var startOffset: Int = 0
    var endOffset: Int = 0

    var document: Document?

    init(ordinal: Int, text: String, vector: [Float], startOffset: Int, endOffset: Int) {
        self.id = UUID()
        self.ordinal = ordinal
        self.text = text
        self.vector = vector
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

// MARK: - Chat history

@Model
final class ChatThread {
    var id: UUID
    var path: String
    var name: String
    var isDirectory: Bool
    var isLibrary: Bool = false
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessageRecord.thread)
    var messages: [ChatMessageRecord] = []

    init(path: String, name: String, kind: SelectedItem.Kind) {
        self.id = UUID()
        self.path = path
        self.name = name
        self.isDirectory = kind != .file
        self.isLibrary = kind == .library
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var item: SelectedItem {
        SelectedItem(url: URL(fileURLWithPath: path), name: name, kind: isLibrary ? .library : (isDirectory ? .folder : .file))
    }
}

@Model
final class ChatMessageRecord {
    var id: UUID
    var roleRaw: String
    var content: String
    var createdAt: Date
    /// JSON-encoded `[Citation]` for assistant replies.
    var sourcesJSON: String?

    var thread: ChatThread?

    init(id: UUID, role: ChatRole, content: String, createdAt: Date) {
        self.id = id
        self.roleRaw = role.rawValue
        self.content = content
        self.createdAt = createdAt
    }
}
