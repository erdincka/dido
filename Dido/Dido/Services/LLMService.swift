import Foundation
import os
import SwiftData

// API Endpoint type is now strictly OpenAI API Compatible as per user request.

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
    var externalBaseURL: String = "https://api.openai.com/v1" {
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
        didSet { 
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
            detectVisionSupport()
        }
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
    var supportsVision: Bool = false
    
    private let logger = Logger(subsystem: "com.dido", category: "LLMService")
    
    private init() {
        if let storedURL = UserDefaults.standard.string(forKey: "externalBaseURL") {
            self.externalBaseURL = storedURL
        }
        // Removed direct assignment of externalApiToken from UserDefaults
        if let storedModel = UserDefaults.standard.string(forKey: "selectedModel") {
            self.selectedModel = storedModel
            detectVisionSupport()
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
        
        return try await generateViaOpenAICompatibleAPI(prompt: prompt, context: context, images: images)
    }
    
    func fetchAvailableModels() async {
        guard let url = URL(string: "\(externalBaseURL)/models") else {
            logger.error("Invalid URL for models: \(self.externalBaseURL)/models")
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15.0
            if !externalApiToken.isEmpty {
                request.setValue("Bearer \(externalApiToken)", forHTTPHeaderField: "Authorization")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modelsArray = json["data"] as? [[String: Any]] else {
                return
            }
            
            let models = modelsArray.compactMap { $0["id"] as? String }
            
            await MainActor.run {
                if !models.contains(self.selectedModel) && !models.isEmpty {
                    self.selectedModel = models.first!
                }
                self.availableModels = models
                self.detectVisionSupport()
            }
        } catch {
            logger.error("Failed to fetch available models: \(error.localizedDescription)")
            await MainActor.run { self.availableModels = [] }
        }
    }
    
    private func detectVisionSupport() {
        let visionKeywords = ["vision", "vlm", "multimodal", "llava", "gpt-4o", "gpt-4-turbo", "gemini", "claude-3"]
        let lowercasedModel = selectedModel.lowercased()
        self.supportsVision = visionKeywords.contains { lowercasedModel.contains($0) }
        logger.info("Vision support detected: \(self.supportsVision) for model: \(self.selectedModel)")
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
    
    private func generateViaOpenAICompatibleAPI(prompt: String, context: String, images: [String]) async throws -> String {
        guard let url = URL(string: "\(externalBaseURL)/chat/completions") else {
            logger.error("Invalid URL: \(self.externalBaseURL)/chat/completions")
            throw LLMServiceError.invalidURL
        }
        
        let fullPrompt = "Context:\n\(context)\n\nQuestion:\n\(prompt)"
        
        var messageContent: [[String: Any]] = [
            ["type": "text", "text": fullPrompt]
        ]
        
        // Use images only if supported or if we should attempt it
        if !images.isEmpty && supportsVision {
            for base64 in images {
                messageContent.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
                ])
            }
        } else if !images.isEmpty && !supportsVision {
            logger.warning("Images provided but vision support not detected for model \(self.selectedModel). Sending text only.")
        }
        
        let payload: [String: Any] = [
            "model": selectedModel,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": messageContent]
            ],
            "stream": false
        ]
        
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
            let errorBody = String(data: data, encoding: .utf8) ?? "No error body"
            logger.error("API Error: \(httpResponse.statusCode), Body: \(errorBody)")
            AppState.shared.showNotification("API Error: \(httpResponse.statusCode)", type: .error)
            throw LLMServiceError.apiError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let responseText = message["content"] as? String else {
            AppState.shared.showNotification("Failed to decode AI response", type: .error)
            throw LLMServiceError.decodingError
        }
        
        return responseText
    }
    
    func generateEmbeddings(prompt: String, model: String = "text-embedding-3-small") async throws -> [Float] {
        guard let url = URL(string: "\(externalBaseURL)/embeddings") else {
            throw LLMServiceError.invalidURL
        }
        
        let payload: [String: Any] = [
            "model": model,
            "input": prompt
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
              let dataArray = json["data"] as? [[String: Any]],
              let firstData = dataArray.first,
              let embedding = firstData["embedding"] as? [Double] else {
            throw LLMServiceError.decodingError
        }
        
        return embedding.map { Float($0) }
    }
}
