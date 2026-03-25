import Foundation

@Observable @MainActor
final class DocumentChunkingService {
    static let shared = DocumentChunkingService()
    
    // Configuration
    var chunkSize: Int = 500 {
        didSet { UserDefaults.standard.set(chunkSize, forKey: "chunkSize") }
    }
    var chunkOverlap: Int = 50 {
        didSet { UserDefaults.standard.set(chunkOverlap, forKey: "chunkOverlap") }
    }
    
    private init() {
        if let storedChunkSize = UserDefaults.standard.object(forKey: "chunkSize") as? Int {
            self.chunkSize = storedChunkSize
        }
        if let storedChunkOverlap = UserDefaults.standard.object(forKey: "chunkOverlap") as? Int {
            self.chunkOverlap = storedChunkOverlap
        }
    }
    
    /// Splits text into overlapping chunks based on character length
    /// A more advanced implementation would use `NaturalLanguage` tokenizer for sentences
    func chunkText(_ text: String) -> [String] {
        var chunks: [String] = []
        let characters = Array(text)
        let totalLength = characters.count
        
        var currentIndex = 0
        
        while currentIndex < totalLength {
            let endIndex = min(currentIndex + chunkSize, totalLength)
            let chunkChars = characters[currentIndex..<endIndex]
            chunks.append(String(chunkChars))
            
            currentIndex += (chunkSize - chunkOverlap)
        }
        
        return chunks
    }
}
