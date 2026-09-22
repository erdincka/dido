import Foundation
import os

/// Model settings and the entry point for asking questions. Network work is delegated to `OpenAICompatibleClient`.
@Observable @MainActor
final class LLMService {
    static let shared = LLMService()

    static let defaultSystemPrompt = """
    You are a precise assistant that answers questions using only the provided context (documents, folders and files).
    - Format your response in clear, valid Markdown.
    - When you state a fact from the context, say which document it came from.
    - If the answer is in the context, answer clearly and concisely.
    - If the answer is not in the context, say so rather than guessing.
    - Do not use outside knowledge.
    """

    static let defaultBaseURL = "http://localhost:11434/v1"

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

    private let logger = Logger(subsystem: "com.dido", category: "LLMService")

    private init() {
        detectVisionSupport()
    }

    /// A snapshot of the endpoint settings, safe to use from any actor.
    func makeClient() -> OpenAICompatibleClient {
        OpenAICompatibleClient(baseURL: externalBaseURL, token: externalApiToken)
    }

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
        let keywords = ["vision", "vlm", "multimodal", "llava", "gpt-4o", "gpt-4.1", "gpt-5", "gemini", "claude", "gemma3", "minicpm-v", "-vl", "pixtral"]
        let name = selectedModel.lowercased()
        supportsVision = keywords.contains { name.contains($0) }
    }

    /// Streams an answer to `question` given prior turns and the document context.
    func streamAnswer(question: String, history: [ChatMessage], context: String, images: [String]) -> AsyncThrowingStream<String, Error> {
        guard !externalBaseURL.isEmpty else { return failed(LLMServiceError.endpointNotConfigured) }
        guard !selectedModel.isEmpty else { return failed(LLMServiceError.modelNotSelected) }

        var messages: [APIMessage] = [APIMessage(role: "system", text: systemPrompt)]
        for turn in history.suffix(20) where !turn.content.isEmpty {
            messages.append(APIMessage(role: turn.role.rawValue, text: turn.content))
        }

        var parts: [APIMessage.Part] = [.text("Context:\n\(context)\n\nQuestion:\n\(question)")]
        if supportsVision {
            parts += images.map { .imageURL("data:image/png;base64,\($0)") }
        } else if !images.isEmpty {
            logger.info("Images available but \(self.selectedModel) is not a vision model; sending text only.")
        }
        messages.append(APIMessage(role: "user", parts: parts))

        return makeClient().streamChat(model: selectedModel, messages: messages)
    }

    private func failed(_ error: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
