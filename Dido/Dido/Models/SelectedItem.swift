import Foundation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

/// A passage the assistant was given, numbered so replies can cite it as [n].
struct Citation: Codable, Hashable, Sendable {
    let index: Int
    let path: String
    let filename: String
    let ordinal: Int
    let start: Int
    let end: Int
    let score: Float

    var url: URL { URL(fileURLWithPath: path) }
}

/// How the context for an answer was assembled, shown in "Why this answer".
struct AnswerDetails: Codable, Hashable, Sendable {
    enum Mode: String, Codable, Sendable {
        /// Every passage in the scope fitted the model's budget and was sent in document order.
        case whole
        /// The passages were ranked by similarity to the question and the best were sent.
        case search
    }

    let provider: String
    let scope: String
    let mode: Mode
    /// Passages that existed in the scope before selection.
    let candidates: Int
    let contextCharacters: Int
    /// Every passage sent to the model, with its similarity score when `mode` is `.search`.
    let passages: [Citation]
}

/// A chat message as shown in the UI. Persisted through `ChatStore`.
struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    var sources: [Citation]
    var details: AnswerDetails?

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(), sources: [Citation] = [], details: AnswerDetails? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.sources = sources
        self.details = details
    }
}

/// The file, folder or whole library the user is currently talking about.
struct SelectedItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case file, folder, library
    }

    let url: URL
    let name: String
    let kind: Kind

    /// Stable across launches: the path, prefixed for the library so it never collides with the root folder.
    var id: String { kind == .library ? "library:" + url.path : url.path }
    var isDirectory: Bool { kind != .file }
    var isLibrary: Bool { kind == .library }

    var searchScope: SearchScope {
        switch kind {
        case .file: return .file(url.path)
        case .folder: return .folder(url.path)
        case .library: return .all
        }
    }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        self.kind = isDirectory ? .folder : .file
    }

    init(url: URL, name: String, kind: Kind) {
        self.url = url
        self.name = name
        self.kind = kind
    }

    static func library(root: URL) -> SelectedItem {
        SelectedItem(url: root, name: "Whole library", kind: .library)
    }
}
