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
    You are Dido, an assistant that answers questions about a person's own documents: notes, meeting minutes, reports, proposals, contracts, spreadsheets and scanned papers.

    Rules:
    - Use only the numbered passages in the context. Never add outside knowledge or guesses.
    - Cite the passages you rely on as [1], [2] and so on, immediately after the fact they support. Cite only numbers that appear in the context.
    - Copy names, figures, dates, amounts, identifiers and quotations exactly as they appear in the passages.
    - If the passages do not contain the answer, say so plainly and name what is missing. Do not speculate.
    - If passages disagree, say which document says what.
    - Answer in the language of the question. Lead with the answer, then the supporting detail. Use Markdown lists, tables and headings only when they make the answer clearer.
    - Answer only the latest question. Earlier turns are context, not material to summarise again.
    - Be concise. No introductions, recaps, closing summaries or "Conclusion" sections.
    """

    /// Prompts shipped by earlier versions; a stored copy of one is replaced by the current default.
    private static let legacyPromptMarkers = [
        "intelligent and precise assistant specialized in extracting",
        "You are a precise assistant that answers questions using only the provided context",
    ]

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
        if Self.legacyPromptMarkers.contains(where: { systemPrompt.contains($0) }) {
            systemPrompt = Self.defaultSystemPrompt
        }
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

    // MARK: - Retrieval query

    private static let followUpOpeners = ["and ", "what about", "how about", "also ", "then ", "it ", "its ", "that ", "those ", "these ", "this ", "they ", "them ", "he ", "she ", "why", "when was that", "same "]

    /// Rewrites a follow-up question into a standalone search query using the recent turns.
    /// Returns the question itself when it already stands alone or the rewrite fails.
    func retrievalQuery(for question: String, history: [ChatMessage]) async -> String {
        let recent = history.suffix(6).filter { !$0.content.isEmpty }
        guard !recent.isEmpty else { return question }
        let lowered = question.lowercased().trimmingCharacters(in: .whitespaces)
        let looksLikeFollowUp = lowered.count < 60 || Self.followUpOpeners.contains { lowered.hasPrefix($0) }
        guard looksLikeFollowUp else { return question }

        let transcript = recent.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(400))" }.joined(separator: "\n")
        let prompt = """
        Conversation so far:
        \(transcript)

        Latest question: \(question)

        Rewrite the latest question as one standalone search query that keeps its meaning and resolves references such as "it", "that" or "the same" using the conversation. Output only the query, nothing else.
        """
        do {
            let rewritten = try await withTimeout(seconds: 12) {
                try await self.makeAnswerProvider().complete(system: "You rewrite follow-up questions into standalone search queries.", prompt: prompt)
            }
            let cleaned = rewritten.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !cleaned.isEmpty, cleaned.count < 400, !cleaned.contains("\n\n") else { return question }
            logger.info("Retrieval query rewritten: \(cleaned)")
            return cleaned
        } catch {
            logger.info("Query rewrite skipped: \(error.localizedDescription)")
            return question
        }
    }

    private func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw LLMServiceError.apiError(statusCode: 0, body: "timed out")
            }
            guard let result = try await group.next() else { throw LLMServiceError.decodingError }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Asking

    /// Streams an answer to `question` given prior turns and the retrieved context.
    func streamAnswer(question: String, history: [ChatMessage], context: RetrievedContext) -> AsyncThrowingStream<AnswerEvent, Error> {
        let provider = makeAnswerProvider()
        let turns = history.suffix(20).map { ChatTurn(role: $0.role, text: $0.content) }
        let prompt = "Context (numbered passages; cite as [n]):\n\(context.text)\n\nQuestion:\n\(question)\n\nAnswer this question directly and concisely, citing passages. Do not add an introduction, a recap of earlier answers or a conclusion."
        return provider.stream(system: systemPrompt, history: turns, prompt: prompt, images: context.images)
    }
}
