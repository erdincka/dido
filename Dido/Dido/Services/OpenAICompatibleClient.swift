import Foundation

enum LLMServiceError: Error, LocalizedError {
    case invalidURL
    case apiError(statusCode: Int, body: String)
    case decodingError
    case unauthorized
    case endpointNotConfigured
    case modelNotSelected

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The API base URL is not a valid URL."
        case .apiError(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "The API returned status \(status)." : "The API returned status \(status): \(detail.prefix(300))"
        case .decodingError: return "The API response could not be read."
        case .unauthorized: return "The API rejected the token. Check it in Settings."
        case .endpointNotConfigured: return "No API base URL is configured. Open Settings."
        case .modelNotSelected: return "No model is selected. Open Settings and pick one."
        }
    }
}

/// One message in an OpenAI-style chat request. Plain text encodes as a string, mixed content as parts.
struct APIMessage: Encodable, Sendable {
    enum Part: Encodable, Sendable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(["url": url], forKey: .imageURL)
            }
        }
    }

    let role: String
    let parts: [Part]

    init(role: String, text: String) {
        self.role = role
        self.parts = [.text(text)]
    }

    init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if parts.count == 1, case .text(let text) = parts[0] {
            try container.encode(text, forKey: .content)
        } else {
            try container.encode(parts, forKey: .content)
        }
    }
}

/// A stateless client for any OpenAI-compatible server (OpenAI, Ollama, LiteLLM, LM Studio).
struct OpenAICompatibleClient: Sendable {
    let baseURL: String
    let token: String

    private struct ModelsResponse: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
    private struct EmbeddingResponse: Decodable { struct Item: Decodable { let embedding: [Double]; let index: Int? }; let data: [Item] }
    private struct StreamChunk: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
        let choices: [Choice]?
    }
    private struct ChatRequest: Encodable { let model: String; let messages: [APIMessage]; let stream: Bool }
    private struct EmbeddingRequest: Encodable { let model: String; let input: [String] }

    private func request(path: String, timeout: TimeInterval) throws -> URLRequest {
        guard !baseURL.isEmpty else { throw LLMServiceError.endpointNotConfigured }
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmed + path) else { throw LLMServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else { throw LLMServiceError.decodingError }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw LLMServiceError.unauthorized
        default:
            let data = (try? await body()) ?? Data()
            throw LLMServiceError.apiError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    func models() async throws -> [String] {
        let request = try request(path: "/models", timeout: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        try await check(response) { data }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else { throw LLMServiceError.decodingError }
        return decoded.data.map(\.id)
    }

    func embedding(for text: String, model: String) async throws -> [Float] {
        try await embeddings(for: [text], model: model).first ?? []
    }

    /// Embeds several texts in one request, returned in input order.
    func embeddings(for texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = try request(path: "/embeddings", timeout: 120)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: model, input: texts))
        let (data, response) = try await URLSession.shared.data(for: request)
        try await check(response) { data }
        guard let decoded = try? JSONDecoder().decode(EmbeddingResponse.self, from: data), decoded.data.count == texts.count else {
            throw LLMServiceError.decodingError
        }
        let ordered = decoded.data.enumerated().sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }
        return ordered.map { $0.element.embedding.map(Float.init) }
    }

    /// Streams the assistant's reply token by token using server-sent events.
    func streamChat(model: String, messages: [APIMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = try request(path: "/chat/completions", timeout: 600)
                    request.httpMethod = "POST"
                    request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, stream: true))
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try await check(response) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        return data
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                              let text = chunk.choices?.first?.delta?.content, !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
