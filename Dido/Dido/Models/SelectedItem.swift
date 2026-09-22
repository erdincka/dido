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

/// A chat message as shown in the UI. Persisted through `ChatStore`.
struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date
    var sources: [Citation]

    init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date(), sources: [Citation] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.sources = sources
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
