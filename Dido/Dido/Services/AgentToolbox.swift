import Foundation
import os

enum AgentToolError: Error, LocalizedError {
    case outsideLibrary(String)
    case ignored(String)
    case notFound(String)
    case notAFolder(String)
    case notAFile(String)
    case unsupportedFile(String)
    case shellDisabled
    case missingQuery(String)

    var errorDescription: String? {
        switch self {
        case .outsideLibrary(let path): return "“\(path)” is outside the library folder, so it was not accessed."
        case .ignored(let path): return "“\(path)” is excluded by the ignore rules, so it was not accessed."
        case .notFound(let path): return "“\(path)” does not exist in the library."
        case .notAFolder(let path): return "“\(path)” is a file, not a folder."
        case .notAFile(let path): return "“\(path)” is a folder, not a file."
        case .unsupportedFile(let path): return "“\(path)” is not a document type Dido can read."
        case .shellDisabled: return "Shell commands are turned off in Settings › AI."
        case .missingQuery(let what): return "The step has no \(what)."
        }
    }
}

/// What a tool produced: text for the model, passages it can cite, and lines for the step's trace.
struct ToolOutput: Sendable {
    var text: String
    var citations: [Citation] = []
    var trace: [String] = []
}

/// Executes the read-only tools a sub-task may use. Every path is resolved against the library root and refused
/// when it falls outside it or is excluded by the ignore rules.
struct AgentToolbox: Sendable {
    let root: URL
    /// Characters of tool output the model can take alongside the instructions.
    let budget: Int
    let shellAllowed: Bool

    private static let dateFormat = Date.FormatStyle.dateTime.year().month(.abbreviated).day()
    private let logger = Logger(subsystem: "com.dido", category: "AgentTools")

    // MARK: - Paths

    /// The URL for a path relative to the root, checked to lie inside the root and not be ignored.
    func resolve(_ relative: String, mustExist: Bool = true) throws -> URL {
        let cleaned = Self.normalise(relative, root: root)
        let url = cleaned.isEmpty ? root : URL(fileURLWithPath: cleaned, relativeTo: root).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw AgentToolError.outsideLibrary(relative)
        }
        if mustExist, !FileManager.default.fileExists(atPath: url.path) { throw AgentToolError.notFound(relative) }
        return url
    }

    /// Strips "./", a leading slash, a trailing slash and the root's own path or name from a planner-written path.
    static func normalise(_ path: String, root: URL) -> String {
        var text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(root.path) { text = String(text.dropFirst(root.path.count)) }
        while text.hasPrefix("./") { text = String(text.dropFirst(2)) }
        while text.hasPrefix("/") { text = String(text.dropFirst()) }
        while text.hasSuffix("/") { text = String(text.dropLast()) }
        if text == "." || text == root.lastPathComponent { text = "" }
        if text.hasPrefix(root.lastPathComponent + "/") { text = String(text.dropFirst(root.lastPathComponent.count + 1)) }
        return text
    }

    func relativePath(of url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    // MARK: - Running

    /// Runs every tool except `askUser`, which the runner handles because it waits on the user.
    func run(_ call: AgentToolCall) async throws -> ToolOutput {
        switch call.kind {
        case .listFolder:
            return try await listFolder(try resolve(call.path), label: call.pathLabel)
        case .readFile:
            guard !call.path.isEmpty else { throw AgentToolError.missingQuery("file path") }
            return try await readFile(try resolve(call.path), label: call.path)
        case .search:
            guard !call.query.isEmpty else { throw AgentToolError.missingQuery("search text") }
            return await search(try resolve(call.path), query: call.query, label: call.pathLabel)
        case .shell:
            guard shellAllowed else { throw AgentToolError.shellDisabled }
            guard !call.query.isEmpty else { throw AgentToolError.missingQuery("command") }
            return try await shell(call.query, in: try resolve(call.path), label: call.pathLabel)
        case .askUser:
            return ToolOutput(text: "")
        }
    }

    private func listFolder(_ url: URL, label: String) async throws -> ToolOutput {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { throw AgentToolError.notAFolder(label) }
        if await FileSystemScanner.shared.isIgnored(url) { throw AgentToolError.ignored(label) }
        let children = try await FileSystemScanner.shared.children(of: url)
        let sorted = children.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        let shown = Array(sorted.prefix(200))
        var lines = ["\(label) (\(children.count) entries, newest first):"]
        for child in shown {
            let modified = child.modificationDate.map { "modified " + $0.formatted(Self.dateFormat) } ?? "modification date unknown"
            if child.isDirectory {
                lines.append("  [folder] \(relativePath(of: child.url))/  \(modified)")
            } else {
                let size = child.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
                lines.append("  [file]   \(relativePath(of: child.url))  \(size)  \(modified)")
            }
        }
        if children.count > shown.count { lines.append("  … \(children.count - shown.count) more entries not shown") }
        return ToolOutput(text: lines.joined(separator: "\n"), trace: ["Listed \(children.count) entries in \(label)"])
    }

    private func readFile(_ url: URL, label: String) async throws -> ToolOutput {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { throw AgentToolError.notAFile(label) }
        if await FileSystemScanner.shared.isIgnored(url) { throw AgentToolError.ignored(label) }
        guard DocumentParser.supportedExtensions.contains(url.pathExtension.lowercased()) else { throw AgentToolError.unsupportedFile(label) }
        let text = try await DocumentParser.shared.text(of: url)
        var body = text
        var trace = ["Read \(label): \(text.count.formatted()) characters"]
        if text.count > budget {
            body = String(text.prefix(budget)) + "\n… (the file continues; \(text.count - budget) characters were not sent)"
            trace.append("Sent the first \(budget.formatted()) characters; the model's budget is smaller than the file")
        }
        let citation = Citation(index: 1, path: url.path, filename: url.lastPathComponent, ordinal: 0, start: 0, end: min(text.utf16.count, body.utf16.count), score: 1)
        return ToolOutput(text: "[1] \(url.lastPathComponent), whole file\n\(body)", citations: [citation], trace: trace)
    }

    private func search(_ url: URL, query: String, label: String) async -> ToolOutput {
        let item: SelectedItem = url == root ? .library(root: root) : SelectedItem(url: url)
        let context = await ContextBuilder().build(for: item, question: query, budget: budget, includeImages: false)
        let mode = context.mode == .whole ? "everything in scope fitted" : "ranked by meaning and exact words"
        return ToolOutput(text: context.text, citations: context.citations,
                          trace: ["Searched \(label) for “\(query)”: \(context.citations.count) extracts from \(context.candidates) passages (\(mode))"])
    }

    private func shell(_ command: String, in directory: URL, label: String) async throws -> ToolOutput {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "cd" || trimmed.hasPrefix("cd ") {
            let target = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let url = try resolve(target.isEmpty ? "" : (directory == root ? target : relativePath(of: directory) + "/" + target))
            var output = try await listFolder(url, label: relativePath(of: url).isEmpty ? "the library root" : relativePath(of: url))
            output.trace.append("cd only shows the folder; set the step's path to run commands there")
            return output
        }
        let result = try await LibraryShell.shared.run(trimmed, in: directory, root: root)
        var text = "$ \(result.command)\n"
        text += result.output.isEmpty ? "(no output)" : result.output
        if result.exitCode != 0 { text += "\n(exit status \(result.exitCode))" }
        var trace = ["Ran `\(result.command)` in \(label): exit status \(result.exitCode), \(result.output.count.formatted()) characters"]
        if result.truncated { trace.append("Output was truncated to \(LibraryShell.maxOutputCharacters.formatted()) characters") }
        if result.timedOut { trace.append("The command was stopped after \(LibraryShell.timeoutSeconds) seconds") }
        if text.count > budget {
            text = String(text.prefix(budget)) + "\n… (truncated to the model's budget)"
        }
        return ToolOutput(text: text, trace: trace)
    }
}
