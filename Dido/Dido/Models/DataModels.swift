import Foundation
import SwiftData

@Model
final class Document {
    var id: UUID
    var filename: String
    var path: String
    var type: String
    var dateIndexed: Date
    var isIndexed: Bool
    var metadataString: String? // JSON serialized metadata
    
    @Relationship(deleteRule: .cascade, inverse: \DocumentChunk.document)
    var chunks: [DocumentChunk] = []
    
    init(id: UUID = UUID(), filename: String, path: String, type: String, dateIndexed: Date = Date(), isIndexed: Bool = false, metadataString: String? = nil) {
        self.id = id
        self.filename = filename
        self.path = path
        self.type = type
        self.dateIndexed = dateIndexed
        self.isIndexed = isIndexed
        self.metadataString = metadataString
    }
}

@Model
final class DocumentChunk {
    var id: UUID
    var text: String
    var vector: [Float] // The embedding vector
    
    var document: Document?
    
    init(id: UUID = UUID(), text: String, vector: [Float]) {
        self.id = id
        self.text = text
        self.vector = vector
    }
}
