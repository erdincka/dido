import Foundation
import SwiftData

@Observable @MainActor
final class VectorDatabaseService {
    static let shared = VectorDatabaseService()
    
    var modelContainer: ModelContainer?
    
    private init() {
        do {
            let schema = Schema([
                Document.self,
                DocumentChunk.self
            ])
            let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            print("Failed to initialize SwiftData container: \(error)")
        }
    }
    
    @MainActor
    func insertDocument(_ document: Document) {
        guard let context = modelContainer?.mainContext else { return }
        context.insert(document)
        try? context.save()
    }
    
    @MainActor
    func fetchDocuments() -> [Document] {
        guard let context = modelContainer?.mainContext else { return [] }
        let fetchDescriptor = FetchDescriptor<Document>(sortBy: [SortDescriptor(\.dateIndexed, order: .reverse)])
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    @MainActor
    func fetchDocuments(for path: String) -> [Document] {
        guard let context = modelContainer?.mainContext else { return [] }
        let fetchDescriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        return (try? context.fetch(fetchDescriptor)) ?? []
    }
    
    @MainActor
    func deleteDocument(_ document: Document) {
        guard let context = modelContainer?.mainContext else { return }
        context.delete(document)
        try? context.save()
    }
    
    @MainActor
    func getStats() -> (count: Int, size: String) {
        let docs = fetchDocuments()
        let count = docs.filter { $0.isIndexed }.count
        // Rough estimate of size (in real app we'd check file size or context size)
        let size = "\(docs.count * 2) MB" 
        return (count, size)
    }
}
