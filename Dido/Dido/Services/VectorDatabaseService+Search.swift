import Foundation
import Accelerate
import SwiftData

extension VectorDatabaseService {
    
    /// Performs cosine similarity search using Accelerate framework
    @MainActor
    func searchSimilar(queryVector: [Float], limit: Int = 5) -> [(chunk: DocumentChunk, score: Float)] {
        guard let context = modelContainer?.mainContext else { return [] }
        
        let fetchDescriptor = FetchDescriptor<DocumentChunk>()
        guard let allChunks = try? context.fetch(fetchDescriptor) else { return [] }
        
        var results: [(chunk: DocumentChunk, score: Float)] = []
        
        for chunk in allChunks {
            let score = cosineSimilarity(a: queryVector, b: chunk.vector)
            results.append((chunk: chunk, score: score))
        }
        
        results.sort { $0.score > $1.score }
        return Array(results.prefix(limit))
    }
    
    /// Fetches all text chunks for a specific file path
    @MainActor
    func fetchTextChunks(for url: URL) -> [String] {
        guard let context = modelContainer?.mainContext else { return [] }
        
        let path = url.path
        let fetchDescriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        
        do {
            let docs = try context.fetch(fetchDescriptor)
            if let doc = docs.first {
                return doc.chunks.map { $0.text }
            }
        } catch {
            print("Failed to fetch chunks for \(path): \(error)")
        }
        return []
    }
    
    private func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        
        var dotProduct: Float = 0.0
        var normA: Float = 0.0
        var normB: Float = 0.0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let magnitude = sqrt(normA) * sqrt(normB)
        if magnitude == 0 { return 0 }
        return dotProduct / magnitude
    }
}
