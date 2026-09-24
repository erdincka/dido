import Foundation
import os

enum LibraryShellError: Error, LocalizedError {
    case emptyCommand
    case notAllowed(String)
    case shellFeature(String)
    case blockedOption(command: String, option: String)
    case outsideLibrary(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "No command was given."
        case .notAllowed(let command):
            return "“\(command)” is not available. Allowed commands: \(LibraryShell.allowedCommands.keys.sorted().joined(separator: ", "))."
        case .shellFeature(let token):
            return "“\(token)” is not available: pipes, redirection, variables and chaining are not supported. Run one command at a time."
        case .blockedOption(let command, let option):
            return "“\(command) \(option)” is not allowed because it could change or run files."
        case .outsideLibrary(let path):
            return "“\(path)” is outside the library folder, so it was not accessed."
        case .launchFailed(let reason):
            return "The command could not be started: \(reason)"
        }
    }
}

/// What a command produced. Output combines standard output and standard error.
struct ShellResult: Sendable {
    let command: String
    let output: String
    let exitCode: Int32
    let truncated: Bool
    let timedOut: Bool
}

/// Runs one read-only command inside the library root without a shell: every argument is checked, paths must
/// resolve inside the root, and there are no pipes, redirection or substitution.
actor LibraryShell {
    static let shared = LibraryShell()

    static let allowedCommands: [String: String] = [
        "ls": "/bin/ls", "pwd": "/bin/pwd", "cat": "/bin/cat", "head": "/usr/bin/head", "tail": "/usr/bin/tail",
        "grep": "/usr/bin/grep", "find": "/usr/bin/find", "wc": "/usr/bin/wc", "stat": "/usr/bin/stat", "file": "/usr/bin/file",
        "du": "/usr/bin/du", "sort": "/usr/bin/sort", "uniq": "/usr/bin/uniq", "basename": "/usr/bin/basename", "dirname": "/usr/bin/dirname",
    ]
    /// Options that write, delete or execute, per command.
    static let blockedOptions: [String: Set<String>] = [
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
        "sort": ["-o", "--output"],
    ]
    static let maxOutputCharacters = 12_000
    static let timeoutSeconds = 20

    private let logger = Logger(subsystem: "com.dido", category: "Shell")

    /// Parses `commandLine`, checks every argument, then runs it with `directory` as the working directory.
    func run(_ commandLine: String, in directory: URL, root: URL) async throws -> ShellResult {
        let tokens = try Self.tokenize(commandLine)
        guard let first = tokens.first else { throw LibraryShellError.emptyCommand }
        guard let executable = Self.allowedCommands[first.text] else { throw LibraryShellError.notAllowed(first.text) }
        let blocked = Self.blockedOptions[first.text] ?? []
        var arguments: [String] = []
        for token in tokens.dropFirst() {
            if token.text.hasPrefix("-") {
                let name = token.text.split(separator: "=").first.map(String.init) ?? token.text
                if blocked.contains(name) { throw LibraryShellError.blockedOption(command: first.text, option: name) }
                arguments.append(token.text)
                continue
            }
            arguments += try Self.expand(token, in: directory, root: root)
        }
        let display = ([first.text] + arguments).joined(separator: " ")
        logger.info("Running \(display, privacy: .public) in \(directory.lastPathComponent, privacy: .public)")
        return try await execute(executable, arguments: arguments, display: display, in: directory)
    }

    // MARK: - Parsing and checks

    struct Token: Equatable {
        let text: String
        let quoted: Bool
    }

    /// Splits a command line the way a shell would, honouring quotes and backslashes, and rejects shell syntax
    /// (pipes, redirection, chaining, variables, substitution) that has no meaning without a shell.
    static func tokenize(_ line: String) throws -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quoted = false
        var inSingle = false
        var inDouble = false
        var escaped = false
        var hasContent = false
        let forbidden: Set<Character> = ["|", ";", "&", "<", ">", "`", "$", "(", ")", "\n"]

        for character in line {
            if escaped {
                current.append(character)
                escaped = false
                hasContent = true
                continue
            }
            if inSingle {
                if character == "'" { inSingle = false } else { current.append(character) }
                continue
            }
            if inDouble {
                if character == "\"" { inDouble = false } else if character == "\\" { escaped = true } else { current.append(character) }
                continue
            }
            switch character {
            case "'": inSingle = true; quoted = true; hasContent = true
            case "\"": inDouble = true; quoted = true; hasContent = true
            case "\\": escaped = true
            case " ", "\t":
                if hasContent { tokens.append(Token(text: current, quoted: quoted)) }
                current = ""; quoted = false; hasContent = false
            case _ where forbidden.contains(character):
                throw LibraryShellError.shellFeature(String(character))
            default:
                current.append(character); hasContent = true
            }
        }
        if inSingle || inDouble { throw LibraryShellError.shellFeature("unterminated quote") }
        if hasContent { tokens.append(Token(text: current, quoted: quoted)) }
        return tokens
    }

    /// Expands wildcards and checks that anything that looks like a path resolves inside the root.
    /// Plain words that match nothing (such as grep patterns) pass through unchanged.
    private static func expand(_ token: Token, in directory: URL, root: URL) throws -> [String] {
        let text = token.text
        if !token.quoted, text.contains(where: { "*?[".contains($0) }) {
            let matches = glob(text, in: directory)
            if !matches.isEmpty {
                return try matches.map { try checked($0, in: directory, root: root) }
            }
        }
        let looksLikePath = text.hasPrefix("/") || text.hasPrefix("~") || text.hasPrefix(".") || text.contains("/")
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(text).path)
        guard looksLikePath else { return [text] }
        return [try checked(text, in: directory, root: root)]
    }

    /// Resolves `path` against `directory` and returns it only when it lies inside `root`.
    static func checked(_ path: String, in directory: URL, root: URL) throws -> String {
        if path.hasPrefix("~") { throw LibraryShellError.outsideLibrary(path) }
        let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw LibraryShellError.outsideLibrary(path)
        }
        return path
    }

    private static func glob(_ pattern: String, in directory: URL) -> [String] {
        let absolute = pattern.hasPrefix("/") ? pattern : directory.appendingPathComponent(pattern).path
        var results = glob_t()
        defer { globfree(&results) }
        guard Darwin.glob(absolute, GLOB_TILDE | GLOB_BRACE, nil, &results) == 0 else { return [] }
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return (0..<Int(results.gl_matchc)).compactMap { index -> String? in
            guard let raw = results.gl_pathv[index] else { return nil }
            let match = String(cString: raw)
            return match.hasPrefix(prefix) && !pattern.hasPrefix("/") ? String(match.dropFirst(prefix.count)) : match
        }
    }

    // MARK: - Execution

    /// `Process` is not Sendable; the box lets the termination handler and the reader share it.
    private final class ProcessBox: @unchecked Sendable {
        let process = Process()
    }

    private func execute(_ executable: String, arguments: [String], display: String, in directory: URL) async throws -> ShellResult {
        let box = ProcessBox()
        let pipe = Pipe()
        let buffer = OSAllocatedUnfairLock(initialState: Data())
        let byteLimit = Self.maxOutputCharacters * 4
        box.process.executableURL = URL(fileURLWithPath: executable)
        box.process.arguments = arguments
        box.process.currentDirectoryURL = directory
        box.process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_GB.UTF-8", "HOME": directory.path]
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = pipe
        box.process.standardError = pipe

        let (exits, exitContinuation) = AsyncStream.makeStream(of: Int32.self)
        box.process.terminationHandler = { process in
            exitContinuation.yield(process.terminationStatus)
            exitContinuation.finish()
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let total = buffer.withLock { $0.append(data); return $0.count }
            if total > byteLimit, box.process.isRunning { box.process.terminate() }
        }
        do {
            try box.process.run()
        } catch {
            throw LibraryShellError.launchFailed(error.localizedDescription)
        }

        let timedOutFlag = OSAllocatedUnfairLock(initialState: false)
        let waiting = Task {
            try await Task.sleep(for: .seconds(Self.timeoutSeconds))
            if box.process.isRunning {
                timedOutFlag.withLock { $0 = true }
                box.process.terminate()
            }
        }
        var status: Int32 = -1
        for await code in exits {
            status = code
            break
        }
        waiting.cancel()
        let timedOut = timedOutFlag.withLock { $0 }

        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = try? pipe.fileHandleForReading.readToEnd()
        let data = buffer.withLock { collected -> Data in
            if let remaining { collected.append(remaining) }
            return collected
        }
        var text = String(decoding: data, as: UTF8.self)
        var truncated = false
        if text.count > Self.maxOutputCharacters {
            let kept = String(text.prefix(Self.maxOutputCharacters))
            let droppedLines = text.dropFirst(Self.maxOutputCharacters).split(separator: "\n").count
            text = kept + "\n… (output truncated, about \(droppedLines) more lines)"
            truncated = true
        }
        if timedOut { text += "\n(stopped after \(Self.timeoutSeconds) seconds)" }
        return ShellResult(command: display, output: text, exitCode: status, truncated: truncated, timedOut: timedOut)
    }
}
