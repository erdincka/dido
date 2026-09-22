import Foundation
import os

enum AnswerSource: String, CaseIterable, Sendable {
    case appleIntelligence
    case server

    var label: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence (on device)"
        case .server: return "OpenAI-compatible server"
        }
    }
}

enum EmbeddingSource: String, CaseIterable, Sendable {
    case onDevice
    case server

    var label: String {
        switch self {
        case .onDevice: return "On device (Apple)"
        case .server: return "OpenAI-compatible server"
        }
    }
}

/// Model settings and the entry point for asking questions. Work is delegated to providers.
@Observable @MainActor
final class LLMService {
    static let shared = LLMService()

    static let defaultBaseURL = "http://localhost:11434/v1"
    static let defaultSystemPrompt = """
    You are a precise assistant that answers questions using only the provided context (documents, folders and files).
    - Format your response in clear, valid Markdown.
    - The context is a numbered list of passages. Cite the passages you use as [1], [2] and so on, right after the fact they support.
    - If the answer is in the context, answer clearly and concisely.
    - If the answer is not in the context, say so rather than guessing.
    - Do not use outside knowledge.
    """

    // MARK: - Settings

    /// Stored choice; nil means "Apple Intelligence when available, otherwise the server".
    var answerSourceChoice: AnswerSource? = UserDefaults.standard.string(forKey: "answerSource").flatMap(AnswerSource.init) {
        didSet { UserDefaults.standard.set(answerSourceChoice?.rawValue, forKey: "answerSource") }
    }

    var embeddingSource: EmbeddingSource = UserDefaults.standard.string(forKey: "embeddingSource").flatMap(EmbeddingSource.init) ?? .onDevice {
        didSet { UserDefaults.standard.set(embeddingSource.rawValue, forKey: "embeddingSource") }
    }

    var serverEmbeddingModel: String = UserDefaults.standard.string(forKey: "embeddingModel").flatMap { $0.isEmpty ? nil : $0 } ?? "nomic-embed-text" {
        didSet { UserDefaults.standard.set(serverEmbeddingModel, forKey: "embeddingModel") }
    }

    var externalBaseURL: String = UserDefaults.standard.string(forKey: "externalBaseURL").flatMap { $0.isEmpty ? nil : $0 } ?? LLMService.defaultBaseURL {
        didSet { UserDefaults.standard.set(externalBaseURL, forKey: "externalBaseURL") }
    }

    var externalApiToken: String {
        get {
            guard let data = KeychainHelper.shared.read(service: "com.dido", account: "externalApiToken") else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            KeychainHelper.shared.save(Data(newValue.utf8), service: "com.dido", account: "externalApiToken")
        }
    }

    var selectedModel: String = UserDefaults.standard.string(forKey: "selectedModel") ?? "" {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: "selectedModel")
            detectVisionSupport()
        }
    }

    var systemPrompt: String = UserDefaults.standard.string(forKey: "systemPrompt").flatMap { $0.isEmpty ? nil : $0 } ?? LLMService.defaultSystemPrompt {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }

    private(set) var availableModels: [String] = []
    private(set) var supportsVision = false
    let appleModelStatus = AppleModelStatus.current

    private let logger = Logger(subsystem: "com.dido", category: "LLMService")

    private init() {
        detectVisionSupport()
    }

    // MARK: - Providers

    /// The source actually in use once availability is taken into account.
    var effectiveAnswerSource: AnswerSource {
        switch answerSourceChoice {
        case .appleIntelligence: return appleModelStatus.isAvailable ? .appleIntelligence : .server
        case .server: return .server
        case nil: return appleModelStatus.isAvailable ? .appleIntelligence : .server
        }
    }

    func makeClient() -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: externalBaseURL, token: externalApiToken)
    }

    func makeAnswerProvider() -> any AnswerProvider {
        #if canImport(FoundationModels)
        if effectiveAnswerSource == .appleIntelligence, #available(macOS 26.0, *) {
            return AppleAnswerProvider()
        }
        #endif
        return ServerAnswerProvider(client: makeClient(), model: selectedModel, supportsImages: supportsVision)
    }

    func makeEmbeddingProvider() -> any EmbeddingProvider {
        switch embeddingSource {
        case .onDevice: return LocalEmbeddingProvider.shared
        case .server: return ServerEmbeddingProvider(client: makeClient(), model: serverEmbeddingModel)
        }
    }

    var answerProviderName: String { makeAnswerProvider().name }

    /// Refreshes the model list. Returns the number of models found.
    @discardableResult
    func fetchAvailableModels() async -> Int {
        do {
            let models = try await makeClient().models().sorted()
            availableModels = models
            if !models.contains(selectedModel), let first = models.first {
                selectedModel = first
            }
            return models.count
        } catch {
            logger.error("Model list failed: \(error.localizedDescription)")
            availableModels = []
            return 0
        }
    }

    private func detectVisionSupport() {
        let keywords = ["vision", "vlm", "multimodal", "llava", "gpt-4o", "gpt-4.1", "gpt-5", "gemini", "claude", "gemma3", "gemma4", "minicpm-v", "-vl", "pixtral"]
        let name = selectedModel.lowercased()
        supportsVision = keywords.contains { name.contains($0) }
    }

    // MARK: - Asking

    /// Streams an answer to `question` given prior turns and the retrieved context.
    func streamAnswer(question: String, history: [ChatMessage], context: RetrievedContext) -> AsyncThrowingStream<String, Error> {
        let provider = makeAnswerProvider()
        let turns = history.suffix(20).map { ChatTurn(role: $0.role, text: $0.content) }
        let prompt = "Context (numbered passages; cite as [n]):\n\(context.text)\n\nQuestion:\n\(question)"
        return provider.stream(system: systemPrompt, history: turns, prompt: prompt, images: context.images)
    }
}
