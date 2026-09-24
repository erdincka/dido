import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A prior turn passed to the model.
struct ChatTurn: Sendable {
    let role: ChatRole
    let text: String
}

/// What a provider emits while answering: text as it arrives, and optionally the passages it relied on.
enum AnswerEvent: Sendable {
    case token(String)
    /// Passage numbers the model reported through structured output (the on-device model).
    case citations([Int])
}

/// Generates answers. Implementations are safe to use from any actor.
protocol AnswerProvider: Sendable {
    var name: String { get }
    /// How many characters of retrieved context the model can comfortably take.
    var contextBudget: Int { get }
    var supportsImages: Bool { get }
    func stream(system: String, history: [ChatTurn], prompt: String, images: [String]) -> AsyncThrowingStream<AnswerEvent, Error>
    /// A short, non-streamed reply for helper tasks such as rewriting a query.
    func complete(system: String, prompt: String) async throws -> String
}

extension AnswerProvider {
    func complete(system: String, prompt: String) async throws -> String {
        var text = ""
        for try await event in stream(system: system, history: [], prompt: prompt, images: []) {
            if case .token(let token) = event { text += token }
        }
        return text
    }
}

// MARK: - OpenAI-compatible server

struct ServerAnswerProvider: AnswerProvider {
    let client: OpenAICompatibleClient
    let model: String
    let supportsImages: Bool

    var name: String {
        let host = URL(string: client.baseURL)?.host ?? client.baseURL
        let local = host == "localhost" || host == "127.0.0.1"
        return "\(local ? "Local server" : host) · \(model)"
    }
    var contextBudget: Int { 60_000 }

    func stream(system: String, history: [ChatTurn], prompt: String, images: [String]) -> AsyncThrowingStream<AnswerEvent, Error> {
        guard !model.isEmpty else {
            return AsyncThrowingStream { $0.finish(throwing: LLMServiceError.modelNotSelected) }
        }
        var messages: [APIMessage] = [APIMessage(role: "system", text: system)]
        for turn in history where !turn.text.isEmpty {
            messages.append(APIMessage(role: turn.role.rawValue, text: turn.text))
        }
        var parts: [APIMessage.Part] = [.text(prompt)]
        if supportsImages {
            parts += images.map { .imageURL("data:image/png;base64,\($0)") }
        }
        messages.append(APIMessage(role: "user", parts: parts))
        let tokens = client.streamChat(model: model, messages: messages)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await token in tokens { continuation.yield(.token(token)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String, prompt: String) async throws -> String {
        try await client.complete(model: model, messages: [APIMessage(role: "system", text: system), APIMessage(role: "user", text: prompt)])
    }
}

// MARK: - Apple Intelligence (Foundation Models, macOS 26)

/// Availability of the on-device model as a user-facing status.
enum AppleModelStatus: Sendable, Equatable {
    case available
    case unavailable(String)
    case unsupportedOS

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: return "Apple Intelligence is available on this Mac."
        case .unavailable(let reason): return reason
        case .unsupportedOS: return "Apple Intelligence needs macOS 26 or newer."
        }
    }

    static var current: AppleModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This Mac does not support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is turned off. Enable it in System Settings › Apple Intelligence & Siri.")
                case .modelNotReady: return .unavailable("The Apple Intelligence model is still downloading. Try again in a few minutes.")
                @unknown default: return .unavailable("Apple Intelligence is not available right now.")
                }
            }
        }
        #endif
        return .unsupportedOS
    }
}

#if canImport(FoundationModels)
/// The shape the on-device model fills in, so citations arrive as data rather than as text the model may omit.
@available(macOS 26.0, *)
@Generable
struct CitedAnswer {
    @Guide(description: "The complete answer in Markdown, taken from the passages' text. For a configuration, specification or design, list every component with its count and value. Never answer with only a file name, a passage label or a single number. Cite passages inline as [n] where n is a passage number from the context.")
    var answer: String
    @Guide(description: "Numbers of the context passages the answer relies on, in order of importance. Empty when none apply.")
    var citations: [Int]
}

@available(macOS 26.0, *)
struct AppleAnswerProvider: AnswerProvider {
    let name = "Apple Intelligence"
    /// The on-device model has a small window (about 4,000 tokens), so context stays short.
    let contextBudget = 7_000
    let supportsImages = false

    private static let historyBudget = 1_500

    func stream(system: String, history: [ChatTurn], prompt: String, images: [String]) -> AsyncThrowingStream<AnswerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    var fullPrompt = ""
                    let recent = Self.trimmedHistory(history)
                    if !recent.isEmpty {
                        fullPrompt += "Earlier turns, for reference only (do not summarise them):\n"
                        for turn in recent {
                            fullPrompt += "\(turn.role == .user ? "User" : "Assistant"): \(turn.text)\n"
                        }
                        fullPrompt += "\n"
                    }
                    fullPrompt += prompt
                    var previous = ""
                    var citations: [Int] = []
                    for try await snapshot in session.streamResponse(to: fullPrompt, generating: CitedAnswer.self) {
                        let content = snapshot.content.answer ?? ""
                        if content.hasPrefix(previous) {
                            let delta = String(content.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(.token(delta)) }
                        } else {
                            continuation.yield(.token(content))
                        }
                        previous = content
                        if let latest = snapshot.content.citations { citations = latest }
                    }
                    if !citations.isEmpty { continuation.yield(.citations(citations)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.describe(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(system: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: prompt).content
        } catch {
            throw Self.describe(error)
        }
    }

    private static func trimmedHistory(_ history: [ChatTurn]) -> [ChatTurn] {
        var kept: [ChatTurn] = []
        var used = 0
        for turn in history.reversed() {
            let text = String(turn.text.prefix(600))
            if used + text.count > historyBudget { break }
            kept.insert(ChatTurn(role: turn.role, text: text), at: 0)
            used += text.count
        }
        return kept
    }

    private static func describe(_ error: Error) -> Error {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize:
                return LLMServiceError.apiError(statusCode: 0, body: "The question and context were too long for Apple Intelligence. Ask about a smaller file or switch to a server model in Settings.")
            case .guardrailViolation:
                return LLMServiceError.apiError(statusCode: 0, body: "Apple Intelligence declined to answer this request.")
            case .rateLimited:
                return LLMServiceError.apiError(statusCode: 0, body: "Apple Intelligence is busy. Try again in a moment.")
            default:
                return LLMServiceError.apiError(statusCode: 0, body: generation.localizedDescription)
            }
        }
        return error
    }
}
#endif
