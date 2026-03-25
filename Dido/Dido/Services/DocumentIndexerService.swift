import Foundation
import SwiftData
import os

@Observable @MainActor
final class DocumentIndexerService {
    static let shared = DocumentIndexerService()
    
    private var vectorDB = VectorDatabaseService.shared
    private var parser = DocumentParserService.shared
    private var chunker = DocumentChunkingService.shared
    private var llmService = LLMService.shared
    
    private let logger = Logger(subsystem: "com.dido", category: "Indexer")
    
    var isIndexing: Bool = false
    var currentFile: String = ""
    var indexedCount: Int = 0
    var totalCount: Int = 0
    
    private init() {}
    
    /// Starts indexing the given URL (file or folder).
    /// Safe to call from any context.
    func indexItem(url: URL) async {
        let name = url.lastPathComponent
        
        // Always try to get access to the PKM root first as most files will be inside it
        let rootURL = AppState.shared.getSecurityScopedURL()
        let rootAccess = rootURL?.startAccessingSecurityScopedResource() ?? false
        
        // Also try to access the specific URL provided
        let fileAccess = url.startAccessingSecurityScopedResource()
        
        await MainActor.run {
            self.isIndexing = true
            self.indexedCount = 0
            self.totalCount = 0
            AppState.shared.showNotification("Indexing: \(name)...")
        }
        
        let files = gatherFiles(from: url)
        await MainActor.run {
            self.totalCount = files.count
        }
        
        for file in files {
            await MainActor.run {
                self.currentFile = file.lastPathComponent
            }
            await indexSingleFile(url: file)
            
            await MainActor.run {
                self.indexedCount += 1
            }
        }
        
        if fileAccess { url.stopAccessingSecurityScopedResource() }
        if rootAccess { rootURL?.stopAccessingSecurityScopedResource() }
        
        await MainActor.run {
            self.isIndexing = false
            AppState.shared.updateStats()
            AppState.shared.showNotification("Indexing completed: \(name)", type: .success)
        }
    }
    
    private func gatherFiles(from url: URL) -> [URL] {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if !isDir {
            return [url]
        }
        
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir {
                files.append(fileURL)
            }
        }
        return files
    }
    
    private func indexSingleFile(url: URL) async {
        let path = url.path
        let ext = url.pathExtension.lowercased()
        
        // Allowed extensions
        let validExtensions = ["pdf", "rtf", "md", "txt", "markdown", "csv", "json", "swift", "py", "js", "html", "css", "xml", "yaml"]
        
        guard validExtensions.contains(ext) else {
            logger.info("Skipping \(path): Unsupported extension")
            // Create a skipped document entry
            await updateOrCreateDocument(url: url, isIndexed: false, metadata: "{\"status\":\"skipped_unsupported\"}")
            return
        }
        
        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
        
        let existingDocs = await vectorDB.fetchDocuments(for: path)
        if let existing = existingDocs.first {
            // Already indexed, check modification date
            if existing.dateIndexed >= modDate, existing.isIndexed {
                logger.info("Skipping \(path): Already indexed and not modified")
                return
            }
            // If modified, delete old chunks (Cascade delete handles this if we delete the document or just clear chunks)
            await vectorDB.deleteDocument(existing)
        }
        
        logger.info("Indexing \(path)")
        
        guard let text = await parser.parseText(from: url, type: ext) else {
            logger.error("Failed to parse text for \(path)")
            await updateOrCreateDocument(url: url, isIndexed: false, metadata: "{\"status\":\"error_parsing\"}")
            return
        }
        
        let chunks = chunker.chunkText(text)
        var documentChunks: [DocumentChunk] = []
        
        for chunk in chunks {
            // Optional: Generate embeddings via LLMService
            var vector: [Float] = []
            do {
                if llmService.endpointType == .ollama {
                    // We only use the embedding if model is explicitly provided in LLMService or we default to nomic-embed-text
                    vector = try await llmService.generateEmbeddings(prompt: chunk, model: "nomic-embed-text")
                } else {
                    // Fake vector for now
                    vector = [Float](repeating: 0.0, count: 1536)
                }
            } catch {
                logger.error("Embedding generation failed for chunk: \(error.localizedDescription)")
                // Default zero vector if failed
                vector = [Float](repeating: 0.0, count: 1536)
            }
            
            let docChunk = DocumentChunk(text: chunk, vector: vector)
            documentChunks.append(docChunk)
        }
        
        let newDoc = Document(filename: url.lastPathComponent, path: path, type: ext, dateIndexed: Date(), isIndexed: true, metadataString: "{\"status\":\"indexed\"}")
        newDoc.chunks = documentChunks
        
        await vectorDB.insertDocument(newDoc)
    }
    
    private func updateOrCreateDocument(url: URL, isIndexed: Bool, metadata: String) async {
        let path = url.path
        let existingDocs = await vectorDB.fetchDocuments(for: path)
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        
        await MainActor.run {
            if let existing = existingDocs.first {
                existing.isIndexed = isIndexed
                existing.metadataString = metadata
            } else {
                let newDoc = Document(filename: filename, path: path, type: ext, dateIndexed: Date(), isIndexed: isIndexed, metadataString: metadata)
                vectorDB.insertDocument(newDoc)
            }
        }
    }
}
