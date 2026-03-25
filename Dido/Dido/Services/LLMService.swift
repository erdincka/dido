import Foundation
import os
import SwiftData

enum APIEndpointType: String, CaseIterable, Identifiable {
    case ollama = "Ollama"
    case openAICompatible = "OpenAI API Compatible"
    var id: String { self.rawValue }
}

enum LLMServiceError: Error, LocalizedError {
    case invalidURL
    case networkFailure(Error)
    case apiError(statusCode: Int)
    case decodingError
    case unauthorized
    case unknown
    case endpointNotConfigured
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The URL provided is invalid."
        case .networkFailure(let error):
            return "Network failure occurred: \(error.localizedDescription)"
        case .apiError(let statusCode):
            return "API returned an error with status code \(statusCode)."
        case .decodingError:
            return "Failed to decode the response from the API."
        case .unauthorized:
            return "Unauthorized access to the API."
        case .unknown:
            return "An unknown error occurred."
        case .endpointNotConfigured:
            return "The external API endpoint is not configured."
        }
    }
}

@Observable @MainActor
final class LLMService {
    static let shared = LLMService()
    
    // Configuration
    var endpointType: APIEndpointType = .ollama {
        didSet { UserDefaults.standard.set(endpointType.rawValue, forKey: "endpointType") }
    }
    var externalBaseURL: String = "http://127.0.0.1:11434" {
        didSet { UserDefaults.standard.set(externalBaseURL, forKey: "externalBaseURL") }
    }
    var externalApiToken: String {
        get {
            if let data = KeychainHelper.shared.read(service: "com.dido", account: "externalApiToken"),
               let token = String(data: data, encoding: .utf8) {
                return token
            }
            return ""
        }
        set {
            if let data = newValue.data(using: .utf8) {
                KeychainHelper.shared.save(data, service: "com.dido", account: "externalApiToken")
            } else {
                KeychainHelper.shared.delete(service: "com.dido", account: "externalApiToken")
            }
        }
    }
    var selectedModel: String = "" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }
    var systemPrompt: String = """
    You are an intelligent and precise assistant specialized in extracting and synthesizing information from the provided context (which includes documents, folders, and files).
    Your task is to answer the user's questions based ONLY on the provided context.
    - Format your response using clear, valid Markdown.
    - Whenever you state a fact or provide information derived from the context, you MUST include a reference or citation indicating which document or chunk the information came from.
    - If the answer is found in the context, provide a clear, concise, and accurate response.
    - If the answer is not contained within the context, politely inform the user that you cannot answer based on the available information.
    - Do not make up information or use outside knowledge.
    """ {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    
    var availableModels: [String] = []
    
    private let logger = Logger(subsystem: "com.dido", category: "LLMService")
    
    private init() {
        if let storedTypeStr = UserDefaults.standard.string(forKey: "endpointType"),
           let storedType = APIEndpointType(rawValue: storedTypeStr) {
            self.endpointType = storedType
        }
        if let storedURL = UserDefaults.standard.string(forKey: "externalBaseURL") {
            self.externalBaseURL = storedURL
        }
        // Removed direct assignment of externalApiToken from UserDefaults
        if let storedModel = UserDefaults.standard.string(forKey: "selectedModel") {
            self.selectedModel = storedModel
        }
        if let storedPrompt = UserDefaults.standard.string(forKey: "systemPrompt") {
            self.systemPrompt = storedPrompt
        }
    }
    
    // MARK: - Public interface
    
    /// Full contextual generation using project-specific types.
    func generateResponse(
        prompt: String,
        messages: [ChatMessage],
        selectedItem: SelectedItem,
        vectorDB: VectorDatabaseService,
        parser: DocumentParserService
    ) async throws -> String {
        
        let (context, images) = await buildContext(
            messages: messages,
            selectedItem: selectedItem,
            vectorDB: vectorDB,
            parser: parser,
            fullFileForEndpoint: true
        )
        
        return try await generateResponse(prompt: prompt, context: context, images: images)
    }
    
    /// Core generation logic (overloaded for simple calls).
    func generateResponse(prompt: String, context: String, images: [String] = []) async throws -> String {
        guard !externalBaseURL.isEmpty else {
            logger.error("External API endpoint is not configured.")
            throw LLMServiceError.endpointNotConfigured
        }
        
        if endpointType == .ollama {
            return try await generateViaExternalAPI(prompt: prompt, context: context, images: images)
        } else {
            // Placeholder for OpenAI API compatible
            return "OpenAI API Compatible endpoint is planned for future releases. Please switch to Ollama in Settings."
        }
    }
    
    func fetchAvailableModels() async {
        guard endpointType == .ollama else {
            await MainActor.run { self.availableModels = [] }
            return
        }
        
        guard let url = URL(string: "\(externalBaseURL)/api/tags") else {
            logger.error("Invalid URL for tags: \(self.externalBaseURL)/api/tags")
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15.0
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelsArray = json["models"] as? [[String: Any]] else {
                return
            }
            
            let models = modelsArray.compactMap { $0["name"] as? String }
            
            await MainActor.run {
                if !models.contains(self.selectedModel) && !models.isEmpty {
                    self.selectedModel = models.first!
                }
                self.availableModels = models
            }
        } catch {
            logger.error("Failed to fetch available models: \(error.localizedDescription)")
            await MainActor.run { self.availableModels = [] }
        }
    }
    
    // MARK: - Helper Methods
    
    private let textExtensions = ["txt", "md", "markdown", "html", "xml", "json", "yaml", "yml", "csv", "swift", "py", "js", "css"]
    private let imageExtensions = ["jpg", "png", "jpeg", "webp", "gif"]
    
    /// Builds the context string used for prompt generation.
    func buildContext(
        messages: [ChatMessage],
        selectedItem: SelectedItem,
        vectorDB: VectorDatabaseService,
        parser: DocumentParserService,
        fullFileForEndpoint: Bool
    ) async -> (String, [String]) {
        
        // Ensure access to the PKM root and the specific item
        let rootURL = AppState.shared.getSecurityScopedURL()
        let rootAccess = rootURL?.startAccessingSecurityScopedResource() ?? false
        let itemAccess = selectedItem.url.startAccessingSecurityScopedResource()
        
        defer {
            if itemAccess { selectedItem.url.stopAccessingSecurityScopedResource() }
            if rootAccess { rootURL?.stopAccessingSecurityScopedResource() }
        }
        
        var contextParts: [String] = []
        var imagesBase64: [String] = []
        
        // 1. Format recent messages
        let limitedMessages = messages.suffix(20)
        for message in limitedMessages {
            let roleName = message.role == .user ? "User" : "Assistant"
            contextParts.append("\(roleName): \(message.content)")
        }
        
        // 2. Add selected item context
        if selectedItem.isDirectory {
            logger.info("Building context for folder: \(selectedItem.url.path)")
            contextParts.append("[Folder Context: \(selectedItem.url.path)]")
            
            if fullFileForEndpoint {
                let fileManager = FileManager.default
                do {
                    let contents = try fileManager.contentsOfDirectory(at: selectedItem.url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    contextParts.append("First-level text files:")
                    
                    for url in contents {
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                        let ext = url.pathExtension.lowercased()
                        
                        // Only text-based files for folder context, no recursion
                        if !isDir && textExtensions.contains(ext) {
                            let isIndexed = await MainActor.run {
                                vectorDB.fetchDocuments(for: url.path).first?.isIndexed ?? false
                            }
                            
                            if !isIndexed {
                                logger.info("Indexing missing text file in folder: \(url.lastPathComponent)")
                                await DocumentIndexerService.shared.indexItem(url: url)
                            }
                            
                            let chunks = await vectorDB.fetchTextChunks(for: url)
                            if !chunks.isEmpty {
                                contextParts.append("--- \(url.lastPathComponent) ---")
                                contextParts.append(contentsOf: chunks)
                            }
                        }
                    }
                } catch {
                    logger.error("Failed to read folder contents: \(error.localizedDescription)")
                    contextParts.append("Error: Failed to read folder contents.")
                }
            }
        } else {
            logger.info("Building context for file: \(selectedItem.name)")
            contextParts.append("[File Context: \(selectedItem.name)]")
            
            if fullFileForEndpoint {
                let ext = selectedItem.url.pathExtension.lowercased()
                
                // For files, index if supported and missing
                let isIndexed = await MainActor.run {
                    vectorDB.fetchDocuments(for: selectedItem.url.path).first?.isIndexed ?? false
                }
                
                let isSupportedText = textExtensions.contains(ext) || ["pdf", "rtf", "doc", "docx"].contains(ext)
                
                if !isIndexed && isSupportedText {
                    logger.info("Indexing supported file on demand: \(selectedItem.name)")
                    await DocumentIndexerService.shared.indexItem(url: selectedItem.url)
                }
                
                // Get chunks (for text/pdf/rtf)
                let chunks = await vectorDB.fetchTextChunks(for: selectedItem.url)
                if !chunks.isEmpty {
                    contextParts.append(contentsOf: chunks)
                }
                
                // Special handling for non-plain text files or visual models
                if ext == "pdf" {
                    logger.info("Extracting PDF pages for VLM context.")
                    if let extractedImages = await parser.extractImagesAsBase64(from: selectedItem.url) {
                        imagesBase64.append(contentsOf: extractedImages)
                    }
                } else if imageExtensions.contains(ext) {
                    logger.info("Converting image for VLM context.")
                    if let base64 = await parser.parseImage(url: selectedItem.url) {
                        imagesBase64.append(base64)
                    }
                }
            }
        }
        
        return (contextParts.joined(separator: "\n"), imagesBase64)
    }
    
    // MARK: - API Calls
    
    private func generateViaExternalAPI(prompt: String, context: String, images: [String]) async throws -> String {
        guard let url = URL(string: "\(externalBaseURL)/api/generate") else {
            logger.error("Invalid URL: \(self.externalBaseURL)/api/generate")
            throw LLMServiceError.invalidURL
        }
        
        let fullPrompt = "\(systemPrompt)\n\nContext:\n\(context)\n\nQuestion:\n\(prompt)"
        var payload: [String: Any] = [
            "model": selectedModel,
            "prompt": fullPrompt,
            "stream": false
        ]
        
        if !images.isEmpty {
            payload["images"] = images
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 900.0
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !externalApiToken.isEmpty {
            request.setValue("Bearer \(externalApiToken)", forHTTPHeaderField: "Authorization")
        }
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            throw LLMServiceError.unknown
        }
        request.httpBody = httpBody
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { 
            AppState.shared.showNotification("Network error occurred", type: .error)
            throw LLMServiceError.unknown 
        }
        
        switch httpResponse.statusCode {
        case 200: break
        case 401: 
            AppState.shared.showNotification("Unauthorized access to API", type: .error)
            throw LLMServiceError.unauthorized
        default: 
            AppState.shared.showNotification("API Error: \(httpResponse.statusCode)", type: .error)
            throw LLMServiceError.apiError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            AppState.shared.showNotification("Failed to decode AI response", type: .error)
            throw LLMServiceError.decodingError
        }
        
        return responseText
    }
    
    func generateEmbeddings(prompt: String, model: String = "nomic-embed-text") async throws -> [Float] {
        guard let url = URL(string: "\(externalBaseURL)/api/embeddings") else {
            throw LLMServiceError.invalidURL
        }
        
        let payload: [String: Any] = [
            "model": model,
            "prompt": prompt
        ]
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 900.0
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else {
            throw LLMServiceError.unknown
        }
        request.httpBody = httpBody
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw LLMServiceError.unknown
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [Double] else {
            throw LLMServiceError.decodingError
        }
        
        return embedding.map { Float($0) }
    }
}
