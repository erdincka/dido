import Foundation
import os

/// Decides whether a question needs several sub-tasks and writes or revises the plan.
struct AgentPlanner: Sendable {
    let provider: any AnswerProvider
    let shellAllowed: Bool

    static let maxSteps = 6
    private static let maxListingEntries = 40
    private let logger = Logger(subsystem: "com.dido", category: "Planner")

    // MARK: - Routing

    /// Words that hint at browsing, dates, counting or several places. Without one the question goes straight to search.
    private static let planningSignals = [
        "latest", "recent", "newest", "oldest", "last ", "first ", "modified", "created", "updated", "date", "when did", "how many",
        "count", "number of", "which files", "which folders", "which documents", "what files", "what folders", "list ", "each ",
        "every ", "all the", "all of", "across", "compare", "folder", "directory", "top-level", "top level", "file names", "filenames",
        "projects", "timeline", "chronolog", "history",
    ]

    /// True when one retrieval pass is unlikely to answer the question: browsing, dates, counting, several places.
    /// A question without any planning signal is searched directly, without asking the model.
    func shouldPlan(question: String, item: SelectedItem) async -> Bool {
        let words = question.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard words.count >= 3 else { return false }
        let lowered = question.lowercased()
        guard Self.planningSignals.contains(where: { lowered.contains($0) }) else {
            logger.info("Routing: no planning signal → search")
            return false
        }
        let scope = item.isLibrary ? "the whole library" : "the folder “\(item.name)”"
        let prompt = """
        Question: \(question)
        Scope: \(scope).

        Answer SEARCH, the default, when one search over the indexed text can answer it: a fact, a summary, an explanation, \
        what a document or project says or recommends.
        Answer PLAN only when the question is about the files and folders themselves and needs several steps: which files exist \
        or are newest, dates in file names, counting files, listing every item, comparing several documents one by one, \
        or combining a folder listing with document contents.
        Reply with exactly one word: SEARCH or PLAN.
        """
        do {
            let reply = try await withTimeout(seconds: 10) {
                try await provider.complete(system: "You route questions about a person's document library.", prompt: prompt)
            }
            let decision = reply.uppercased().contains("PLAN") && !reply.uppercased().contains("SEARCH")
            logger.info("Routing: \(reply.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public) → \(decision ? "plan" : "search")")
            return decision
        } catch {
            logger.info("Routing skipped: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Planning

    /// Writes the sub-tasks for `question`. With `completed` findings and `hints`, it rewrites only the steps still to run.
    func plan(question: String, item: SelectedItem, toolbox: AgentToolbox, hints: [String], completed: [AgentStep], remaining: [AgentStep], history: [ChatMessage]) async throws -> [AgentStep] {
        let listingRoot = item.isLibrary ? toolbox.root : item.url
        // The catalogue and instructions take about 2,500 characters; the listing and history share what is left.
        let spare = provider.contextBudget - 2_500 - question.count - hints.reduce(0) { $0 + $1.count } - completed.reduce(0) { $0 + min($1.finding.count, 500) + 120 }
        let listing = await Self.listing(of: listingRoot, toolbox: toolbox, characterBudget: max(spare * 2 / 3, 600))
        var prompt = "Library root: \(toolbox.root.lastPathComponent)\n"
        if !item.isLibrary {
            prompt += "The user is asking about the folder “\(toolbox.relativePath(of: item.url))”; stay inside it unless the question needs more.\n"
        }
        prompt += "\(item.isLibrary ? "Top-level contents" : "Contents of that folder") (paths relative to the root, newest first):\n\(listing)\n\n"
        let recent = spare > 4_000 ? history.suffix(4).filter { !$0.content.isEmpty } : []
        if !recent.isEmpty {
            prompt += "Recent conversation:\n" + recent.map { "\($0.role == .user ? "User" : "Assistant"): \($0.content.prefix(300))" }.joined(separator: "\n") + "\n\n"
        }
        prompt += "Question: \(question)\n"
        if !hints.isEmpty {
            prompt += "\nSteering from the user, which overrides everything else:\n" + hints.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        if !completed.isEmpty {
            prompt += "\nSteps already run and their findings (do not repeat them):\n"
            for (offset, step) in completed.enumerated() {
                let outcome = step.status == .done ? step.finding : "(\(step.status.label.lowercased())\(step.error.map { ": " + $0 } ?? ""))"
                prompt += "\(offset + 1). \(step.title) — \(step.tool.summary)\n   \(outcome.prefix(500).replacingOccurrences(of: "\n", with: " "))\n"
            }
        }
        if !remaining.isEmpty {
            prompt += "\nSteps not yet run, which you may keep, change or replace:\n" + remaining.map { "- \($0.title): \($0.tool.summary)" }.joined(separator: "\n") + "\n"
        }
        prompt += "\n" + Self.toolCatalogue(shellAllowed: shellAllowed)
        prompt += """


        Write \(completed.isEmpty ? "2 to \(Self.maxSteps)" : "up to \(Self.maxSteps)") sub-tasks that together answer the question. \
        Each sub-task is exactly one tool call that the user will review before it runs. Use paths from the listing. \
        Prefer listFolder or shell to learn what exists and when it changed; use search or readFile to learn what documents say. \
        Never propose two steps with the same tool and path, and no step that only sorts, filters or counts an earlier step's output: \
        the answer is written afterwards from every finding, so do not add a final "combine the results" step either.
        Reply with a JSON array only, no prose, in this shape:
        [{"title": "Short title", "instruction": "What this step must find out", "tool": "listFolder", "path": "", "query": ""}]
        """
        let finalPrompt = prompt
        let reply = try await withTimeout(seconds: 90) {
            try await provider.complete(system: "You plan how to answer a question about a person's document library by splitting it into sub-tasks. You reply with JSON only.", prompt: finalPrompt)
        }
        let steps = Self.parse(reply, root: toolbox.root, shellAllowed: shellAllowed)
        logger.info("Planned \(steps.count) steps")
        return Array(steps.prefix(Self.maxSteps))
    }

    static func toolCatalogue(shellAllowed: Bool) -> String {
        var lines = [
            "Tools (all read-only, all limited to the library folder):",
            "- listFolder: \"path\" is a folder relative to the root (\"\" for the root). Lists every entry with its kind and modification date, newest first, so one call already answers what exists and what is newest.",
            "- search: finds the passages most relevant to \"query\" in the indexed text under \"path\" (a folder or a file; \"\" for the whole library). Returns numbered passages.",
            "- readFile: reads the whole text of the document at \"path\".",
        ]
        if shellAllowed {
            lines.append("- shell: runs one command in the folder \"path\" with \"query\" as the command line. Available: ls, find, grep, cat, head, tail, wc, stat, du, file, sort, uniq. Wildcards work; pipes, redirection and variables do not. Each command receives no input from other steps, so it must name the files or folders it works on (for example `head -n 5 *.md`, `grep -l 2026 *.txt`, `find . -maxdepth 1 -name '2026*'`).")
        }
        lines.append("- askUser: asks the user \"query\" when the question is ambiguous. At most one such step, and only when the listing cannot settle it.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    private struct PlannedStep: Decodable {
        var title: String?
        var instruction: String?
        var tool: String?
        var path: String?
        var query: String?
        var command: String?
        var question: String?
    }

    /// Reads the planner's JSON leniently: code fences and prose around the array are ignored, unknown tools dropped.
    static func parse(_ text: String, root: URL, shellAllowed: Bool) -> [AgentStep] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        let json = String(text[start...end])
        guard let planned = try? JSONDecoder().decode([PlannedStep].self, from: Data(json.utf8)) else { return [] }
        return planned.compactMap { item in
            guard let kind = AgentToolKind(planned: item.tool ?? ""), kind != .shell || shellAllowed else { return nil }
            let query = (item.query ?? item.command ?? item.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let path = AgentToolbox.normalise(item.path ?? "", root: root)
            let instruction = (item.instruction ?? item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (item.title ?? instruction).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return AgentStep(title: title, instruction: instruction.isEmpty ? title : instruction, tool: AgentToolCall(kind: kind, path: path, query: query))
        }
    }

    // MARK: - Listing for the planner

    /// The folder's entries, newest first, cut to `characterBudget` so small models still get a prompt that fits.
    static func listing(of folder: URL, toolbox: AgentToolbox, characterBudget: Int = .max) async -> String {
        guard let children = try? await FileSystemScanner.shared.children(of: folder) else { return "(the folder could not be read)" }
        let sorted = children.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        var lines: [String] = []
        var used = 0
        for child in sorted.prefix(maxListingEntries) {
            let date = child.modificationDate.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) } ?? "unknown date"
            let line = "- \(child.isDirectory ? "[folder]" : "[file]") \(toolbox.relativePath(of: child.url))\(child.isDirectory ? "/" : "")  (\(date))"
            guard used + line.count + 1 <= characterBudget else { break }
            lines.append(line)
            used += line.count + 1
        }
        if children.count > lines.count { lines.append("- … \(children.count - lines.count) more entries (use listFolder to see them all)") }
        return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
    }
}
