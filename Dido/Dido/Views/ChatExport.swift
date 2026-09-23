import AppKit

/// Turns an answer and its sources into Markdown for the clipboard or a file.
enum ChatExport {
    static func markdown(question: String?, message: ChatMessage) -> String {
        var text = ""
        if let question { text += "**Question:** \(question)\n\n" }
        text += message.content
        if !message.sources.isEmpty {
            text += "\n\n## Sources\n\n"
            for source in message.sources {
                text += "[\(source.index)] \(source.filename), \(source.partLabel) — `\(source.path)`\n"
            }
        }
        if let details = message.details {
            text += "\n_Answered by \(details.provider) on \(message.createdAt.formatted(date: .abbreviated, time: .shortened))._\n"
        }
        return text
    }

    /// Copies the answer with `[n]` markers expanded to file names and a footnote-style source list.
    static func copyWithSources(question: String?, message: ChatMessage) {
        var content = message.content
        for source in message.sources {
            content = content.replacingOccurrences(of: "[\(source.index)]", with: "[\(source.index): \(source.filename), \(source.partLabel)]")
        }
        let copy = ChatMessage(id: message.id, role: message.role, content: content, createdAt: message.createdAt, sources: message.sources, details: message.details)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(question: question, message: copy), forType: .string)
    }

    @MainActor
    static func save(question: String?, message: ChatMessage, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try markdown(question: question, message: message).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                AppState.shared.showNotification("Could not save the answer: \(error.localizedDescription)", type: .error)
            }
        }
    }
}
