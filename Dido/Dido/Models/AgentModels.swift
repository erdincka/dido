import Foundation

/// What one sub-task is allowed to do. Every tool is read-only and confined to the library root.
enum AgentToolKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case listFolder
    case search
    case readFile
    case shell
    case askUser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .listFolder: return "List folder"
        case .search: return "Search"
        case .readFile: return "Read file"
        case .shell: return "Shell"
        case .askUser: return "Ask me"
        }
    }

    var symbol: String {
        switch self {
        case .listFolder: return "folder"
        case .search: return "magnifyingglass"
        case .readFile: return "doc.text"
        case .shell: return "terminal"
        case .askUser: return "questionmark.bubble"
        }
    }

    var usesPath: Bool { self != .askUser }
    /// Listings and command output are kept verbatim as the finding instead of being summarised by the model.
    var findingIsToolOutput: Bool { self == .listFolder || self == .shell }
    var usesQuery: Bool { self == .search || self == .shell || self == .askUser }

    /// Label for the query field in the step editor.
    var queryLabel: String {
        switch self {
        case .search: return "Search for"
        case .shell: return "Command"
        case .askUser: return "Question"
        case .listFolder, .readFile: return ""
        }
    }

    /// Lenient mapping from whatever name the planner used.
    init?(planned name: String) {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        switch key {
        case "listfolder", "list", "ls", "listdirectory", "browse": self = .listFolder
        case "search", "retrieve", "find", "lookup": self = .search
        case "readfile", "read", "open", "cat": self = .readFile
        case "shell", "command", "bash", "terminal", "run": self = .shell
        case "askuser", "ask", "question", "clarify": self = .askUser
        default: return nil
        }
    }
}

/// One tool invocation as the planner proposed it and the user may edit it.
struct AgentToolCall: Codable, Hashable, Sendable {
    var kind: AgentToolKind
    /// Folder or file relative to the library root; empty means the root itself.
    var path: String = ""
    /// The search text, the shell command line or the question, depending on the tool.
    var query: String = ""

    var pathLabel: String { path.isEmpty ? "the library root" : path }

    /// One line describing the call, shown beside the step title.
    var summary: String {
        switch kind {
        case .listFolder: return "list \(pathLabel)"
        case .search: return "search “\(query)” in \(pathLabel)"
        case .readFile: return "read \(path.isEmpty ? "(no file)" : path)"
        case .shell: return "\(query) — in \(pathLabel)"
        case .askUser: return "ask: \(query)"
        }
    }
}

enum AgentStepStatus: String, Codable, Sendable {
    case pending
    case running
    case waitingForUser
    case done
    case stopped
    case failed

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .running: return "Running"
        case .waitingForUser: return "Waiting for you"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    /// True once the step will not run further unless the user re-runs it.
    var isTerminal: Bool { self == .done || self == .stopped || self == .failed }
    var isActive: Bool { self == .running || self == .waitingForUser }
}

/// One line of a step's execution log.
struct AgentTraceEntry: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let time: Date
    let text: String

    init(_ text: String) {
        self.id = UUID()
        self.time = Date()
        self.text = text
    }
}

/// A sub-task: what to find out, which tool to use, and what happened when it ran.
struct AgentStep: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var instruction: String
    var tool: AgentToolCall
    var status: AgentStepStatus
    /// The model's report on the tool output, or the user's reply for an `askUser` step.
    var finding: String
    var trace: [AgentTraceEntry]
    /// Passages the step retrieved, numbered from 1 within the step until the run consolidates them.
    var citations: [Citation]
    var error: String?

    init(id: UUID = UUID(), title: String, instruction: String, tool: AgentToolCall, status: AgentStepStatus = .pending) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.tool = tool
        self.status = status
        self.finding = ""
        self.trace = []
        self.citations = []
        self.error = nil
    }

    /// A step with no content yet, for the "Add step" editor.
    static var blank: AgentStep {
        AgentStep(title: "", instruction: "", tool: AgentToolCall(kind: .search))
    }

    /// Resets the outcome so the step can run again.
    mutating func resetForRun() {
        status = .pending
        finding = ""
        trace = []
        citations = []
        error = nil
    }
}

/// Kept with a planned reply so the sub-tasks can be reviewed later.
struct AgentTrace: Codable, Hashable, Sendable {
    var steps: [AgentStep]
    var hints: [String]
    var note: String?
}
