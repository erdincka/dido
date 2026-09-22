import Foundation

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
}

/// A chat message as shown in the UI. Persisted through `ChatStore`.
struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

/// The file or folder the user is currently talking about.
struct SelectedItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Stable across launches: the path itself.
    var id: String { url.path }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
    }
}
