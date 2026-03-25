import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    let role: ChatRole
    let content: String
}

struct SelectedItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var messages: [ChatMessage] = []
    
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
}
