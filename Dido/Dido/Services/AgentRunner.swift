import Foundation
import os

/// Plans a question as sub-tasks, runs them one after another while the user watches, edits, stops or steers them,
/// then writes one answer from the findings. Lives on the main actor so the views observe it directly; tools and
/// models do their work on their own actors.
@Observable @MainActor
final class AgentRunner {
    enum Phase: Equatable {
        case planning
        case reviewing
        case running
        case consolidating
        case finished
        case cancelled
        case failed(String)
    }

    /// The answer and everything needed to persist it.
    struct Outcome: Sendable {
        let text: String
        let citations: [Citation]
        let trace: AgentTrace
        let details: AnswerDetails
    }

    let question: String
    let item: SelectedItem
    private(set) var phase: Phase = .planning
    private(set) var steps: [AgentStep] = []
    private(set) var hints: [String] = []
    /// A remark about the plan itself, such as a fallback or a re-plan.
    private(set) var note: String?
    /// The consolidated answer as it streams.
    private(set) var answerText = ""
    private(set) var isReplanning = false
    /// Skips the review pause (debug launches).
    var autoApprove = false

    private let root: URL
    private let history: [ChatMessage]
    private let provider: any AnswerProvider
    private let planner: AgentPlanner
    private let toolbox: AgentToolbox
    private let logger = Logger(subsystem: "com.dido", category: "Agent")

    private var approval: CheckedContinuation<Bool, Never>?
    private var reply: CheckedContinuation<String?, Never>?
    private var stepTask: Task<Void, Never>?
    private var consolidation: Task<String?, Never>?
    private var replanTask: Task<Void, Never>?

    init(question: String, item: SelectedItem, root: URL, history: [ChatMessage]) {
        self.question = question
        self.item = item
        self.root = root
        self.history = history
        let llm = LLMService.shared
        provider = llm.makeAnswerProvider()
        planner = AgentPlanner(provider: provider, shellAllowed: llm.allowShellSteps)
        toolbox = AgentToolbox(root: root, budget: max(provider.contextBudget - 1_500, 2_000), shellAllowed: llm.allowShellSteps)
    }

    // MARK: - Derived state

    var providerName: String { provider.name }
    var isActive: Bool { phase == .running || phase == .consolidating }
    /// True once any step has run, so a stopped run is worth keeping in the transcript.
    var hasStarted: Bool { steps.contains { !$0.trace.isEmpty } }
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// True when a step reaches beyond the folder this chat is about (the library root still bounds it).
    func isOutsideScope(_ step: AgentStep) -> Bool {
        guard !item.isLibrary, step.tool.kind.usesPath else { return false }
        let scope = toolbox.relativePath(of: item.url)
        return !(step.tool.path == scope || step.tool.path.hasPrefix(scope + "/"))
    }

    // MARK: - Running

    /// Plans, waits for approval, runs the steps and writes the answer. Returns nil when cancelled or failed.
    func run() async -> Outcome? {
        await withTaskCancellationHandler {
            await perform()
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
    }

    private func perform() async -> Outcome? {
        DebugLog.write("agent: planning")
        do {
            steps = try await planner.plan(question: question, item: item, toolbox: toolbox, hints: [], completed: [], remaining: [], history: history)
        } catch {
            guard phase != .cancelled else { return nil }
            phase = .failed("The plan could not be written: \(error.localizedDescription)")
            return nil
        }
        guard phase != .cancelled else { return nil }
        steps = Self.withoutRepeats(steps)
        if steps.isEmpty {
            steps = [AgentStep(title: "Search the whole scope", instruction: question, tool: AgentToolCall(kind: .search, path: item.isLibrary ? "" : toolbox.relativePath(of: item.url), query: question))]
            note = "The model did not return a usable plan, so a single search step was proposed instead."
        }
        DebugLog.write("agent: plan with \(steps.count) steps")
        phase = .reviewing
        if !autoApprove {
            let approved = await withCheckedContinuation { approval = $0 }
            approval = nil
            guard approved, phase != .cancelled else {
                phase = .cancelled
                return nil
            }
        }
        while phase != .cancelled {
            phase = .running
            await runPendingSteps()
            guard phase != .cancelled else { break }
            phase = .consolidating
            answerText = ""
            let task = Task { await consolidate() }
            consolidation = task
            let text = await task.value
            consolidation = nil
            guard phase != .cancelled else { break }
            if let text, !steps.contains(where: { $0.status == .pending }) {
                phase = .finished
                DebugLog.write("agent: finished")
                return outcome(text: text)
            }
        }
        return nil
    }

    /// Small models like to list the same folder several times; one call already answers all of them.
    static func withoutRepeats(_ steps: [AgentStep]) -> [AgentStep] {
        var seen: Set<AgentToolCall> = []
        return steps.filter { step in
            guard step.tool.kind != .askUser else { return true }
            var call = step.tool
            if !call.kind.usesQuery { call.query = "" }
            return seen.insert(call).inserted
        }
    }

    private func runPendingSteps() async {
        while phase != .cancelled, let next = steps.first(where: { $0.status == .pending }) {
            let task = Task { await execute(next.id) }
            stepTask = task
            await task.value
            stepTask = nil
        }
    }

    // MARK: - Controls

    func approve() {
        approval?.resume(returning: true)
    }

    /// Stops everything; the runner then returns nil from `run()`.
    func cancel() {
        guard phase != .cancelled, phase != .finished else { return }
        phase = .cancelled
        approval?.resume(returning: false)
        approval = nil
        reply?.resume(returning: nil)
        reply = nil
        stepTask?.cancel()
        consolidation?.cancel()
        replanTask?.cancel()
        for index in steps.indices where steps[index].status.isActive || steps[index].status == .pending {
            steps[index].status = .stopped
        }
    }

    func stopStep(_ id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        switch steps[index].status {
        case .waitingForUser:
            reply?.resume(returning: nil)
            reply = nil
        case .running:
            stepTask?.cancel()
        case .pending:
            steps[index].status = .stopped
            log(id, "Skipped at your request")
        default:
            break
        }
    }

    func rerunStep(_ id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }), !steps[index].status.isActive else { return }
        steps[index].resetForRun()
        resumeIfIdle()
    }

    /// Saves an edited step. A step that already ran is reset so it runs again with the new settings.
    func updateStep(_ step: AgentStep) {
        guard let index = steps.firstIndex(where: { $0.id == step.id }), !steps[index].status.isActive else { return }
        var updated = step
        updated.tool.path = AgentToolbox.normalise(step.tool.path, root: root)
        updated.resetForRun()
        steps[index] = updated
        resumeIfIdle()
    }

    func addStep(_ step: AgentStep) {
        var added = step
        added.tool.path = AgentToolbox.normalise(step.tool.path, root: root)
        added.resetForRun()
        steps.append(added)
        resumeIfIdle()
    }

    func removeStep(_ id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }), !steps[index].status.isActive else { return }
        steps.remove(at: index)
    }

    /// Delivers the user's reply to a waiting `askUser` step.
    func answer(_ text: String, for id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }), steps[index].status == .waitingForUser else { return }
        reply?.resume(returning: text)
        reply = nil
    }

    /// Re-plans the steps that have not run yet with a hint from the user. Finished steps are kept.
    func steer(_ hint: String) {
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .cancelled, phase != .finished else { return }
        hints.append(trimmed)
        isReplanning = true
        replanTask = Task {
            defer { isReplanning = false }
            let completed = steps.filter { $0.status.isTerminal }
            let remaining = steps.filter { $0.status == .pending }
            do {
                let replacement = try await planner.plan(question: question, item: item, toolbox: toolbox, hints: hints, completed: completed, remaining: remaining, history: history)
                guard !Task.isCancelled, phase != .cancelled else { return }
                steps.removeAll { $0.status == .pending }
                steps = Self.withoutRepeats(steps + replacement)
                note = replacement.isEmpty ? "The hint left no further steps to run." : "Re-planned after your hint: \(replacement.count) step\(replacement.count == 1 ? "" : "s") to run."
                resumeIfIdle()
            } catch {
                guard !Task.isCancelled else { return }
                note = "The plan could not be updated: \(error.localizedDescription)"
            }
        }
    }

    /// Interrupts a consolidation in progress so the main loop picks up new or re-run steps.
    private func resumeIfIdle() {
        if phase == .consolidating { consolidation?.cancel() }
    }

    // MARK: - One step

    private static let stepSystemPrompt = """
    You carry out one sub-task of a larger question about a person's document library. Use only the tool output you are given. \
    Report what it shows that matters for the sub-task: concrete names, paths, dates, figures and quotations exactly as they appear. \
    When the output contains numbered passages, cite them as [n]. If the output does not answer the sub-task, say so and say what was seen instead. \
    Be brief: a few sentences or a short list. No introduction or conclusion.
    """

    private func execute(_ id: UUID) async {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].resetForRun()
        steps[index].status = .running
        let step = steps[index]
        log(id, "Started: \(step.tool.summary)")
        DebugLog.write("agent: step '\(step.title)' \(step.tool.summary)")
        if step.tool.kind == .askUser {
            await askUser(step)
            return
        }
        do {
            let output = try await toolbox.run(step.tool)
            try Task.checkCancellation()
            for line in output.trace { log(id, line) }
            if step.tool.kind.findingIsToolOutput {
                // Listings and command output are already the facts; a model summary would only lose entries.
                update(id) { $0.finding = Self.asCodeBlock(output.text); $0.status = .done }
                log(id, "Kept the output as the finding")
                return
            }
            log(id, "Asking \(provider.name) what the output shows")
            let prompt = "Overall question: \(question)\nSub-task: \(step.instruction)\nTool: \(step.tool.summary)\n\nTool output:\n\(output.text)"
            var text = ""
            for try await event in provider.stream(system: Self.stepSystemPrompt, history: [], prompt: prompt, images: []) {
                if case .token(let token) = event {
                    text += token
                    update(id) { $0.finding = text }
                }
            }
            try Task.checkCancellation()
            update(id) {
                $0.finding = text.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.citations = output.citations
                $0.status = .done
            }
            log(id, "Done")
        } catch {
            if Task.isCancelled || error is CancellationError {
                update(id) { $0.status = .stopped }
                log(id, "Stopped")
            } else {
                update(id) { $0.status = .failed; $0.error = error.localizedDescription }
                log(id, "Failed: \(error.localizedDescription)")
                logger.error("Step '\(step.title)' failed: \(error.localizedDescription)")
            }
        }
    }

    private static func asCodeBlock(_ text: String) -> String {
        let fence = text.contains("```") ? "````" : "```"
        return "\(fence)text\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\(fence)"
    }

    private func askUser(_ step: AgentStep) async {
        update(step.id) { $0.status = .waitingForUser }
        log(step.id, "Waiting for your reply")
        let answer = await withCheckedContinuation { reply = $0 }
        reply = nil
        if let answer, phase != .cancelled {
            update(step.id) { $0.finding = answer; $0.status = .done }
            log(step.id, "Reply received")
        } else {
            update(step.id) { $0.status = .stopped }
            log(step.id, "Stopped without a reply")
        }
    }

    private func update(_ id: UUID, _ change: (inout AgentStep) -> Void) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        change(&steps[index])
    }

    private func log(_ id: UUID, _ text: String) {
        update(id) { $0.trace.append(AgentTraceEntry(text)) }
    }

    // MARK: - Consolidation

    /// Steps with their citations renumbered across the whole run, so one sources list covers the answer.
    private func renumbered() -> [AgentStep] {
        var offset = 0
        return steps.map { step in
            guard step.status == .done, !step.citations.isEmpty else { return step }
            var copy = step
            copy.finding = Self.shiftCitations(in: step.finding, by: offset)
            copy.citations = step.citations.map {
                Citation(index: $0.index + offset, path: $0.path, filename: $0.filename, ordinal: $0.ordinal, start: $0.start, end: $0.end, score: $0.score, ordinalEnd: $0.ordinalEnd, matchedText: $0.matchedText)
            }
            offset += step.citations.count
            return copy
        }
    }

    static func shiftCitations(in text: String, by offset: Int) -> String {
        guard offset > 0, let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]"#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text) else { continue }
            let shifted = text[group].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { String($0 + offset) }
            output.replaceSubrange(whole, with: "[" + shifted.joined(separator: ", ") + "]")
        }
        return output
    }

    /// Every finding, trimmed to a fair share when together they exceed what the model can take.
    /// Drops [n] markers that match no gathered passage, which models add when they number a list.
    static func removingUnknownCitations(from text: String, valid: Set<Int>) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\s?\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()"#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text) else { continue }
            let numbers = text[group].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let kept = numbers.filter { valid.contains($0) }
            if kept.count == numbers.count { continue }
            output.replaceSubrange(whole, with: kept.isEmpty ? "" : " [" + kept.map(String.init).joined(separator: ", ") + "]")
        }
        return output
    }

    private func findingsText(_ ordered: [AgentStep]) -> String {
        var outcomes = ordered.map { step -> String in
            switch step.status {
            case .done: return step.finding.isEmpty ? "(no finding)" : step.finding
            case .failed: return "(failed: \(step.error ?? "unknown error"))"
            default: return "(\(step.status.label.lowercased()) by the user, no finding)"
            }
        }
        let available = max(provider.contextBudget - question.count - 1_200, 1_500)
        let total = outcomes.reduce(0) { $0 + $1.count }
        if total > available {
            outcomes = outcomes.map { text in
                let share = max(available * text.count / total, 200)
                guard text.count > share else { return text }
                return String(text.prefix(share)) + "\n… (trimmed to fit the model)"
            }
        }
        return zip(ordered, outcomes).enumerated().map { offset, pair in
            "Sub-task \(offset + 1): \(pair.0.title) — \(pair.0.tool.summary)\n\(pair.1)"
        }.joined(separator: "\n\n")
    }

    /// Streams the final answer from every finding. Returns nil when interrupted by a re-run, a new step or a cancel.
    private func consolidate() async -> String? {
        let ordered = renumbered()
        let findings = findingsText(ordered)
        DebugLog.write("agent: consolidating \(ordered.count) findings")
        let system = LLMService.shared.systemPrompt + "\n\nFor this answer the context is a set of findings from sub-tasks that already looked at the library, not numbered passages. Treat each finding as evidence gathered from the documents. Cite the passage numbers that appear inside the findings as [n]; do not invent numbers."
        let prompt = "Question: \(question)\n\nFindings from the sub-tasks (passage numbers are shared across all of them):\n\n\(findings)\n\nAnswer the question from these findings only. Keep the citations [n] that support each point, but only numbers that appear inside the findings: folder listings and command output carry no passage numbers, so list their entries without [n] markers. If the findings do not settle the question, say what is missing. Do not describe the sub-tasks themselves."
        var text = ""
        do {
            for try await event in provider.stream(system: system, history: [], prompt: prompt, images: []) {
                if case .token(let token) = event {
                    text += token
                    answerText = text
                }
            }
        } catch {
            if Task.isCancelled { return nil }
            text += (text.isEmpty ? "" : "\n\n") + "**Error:** \(error.localizedDescription)"
            answerText = text
        }
        return Task.isCancelled ? nil : text
    }

    private func outcome(text: String) -> Outcome {
        let ordered = renumbered()
        let citations = ordered.flatMap(\.citations)
        let text = Self.removingUnknownCitations(from: text, valid: Set(citations.map(\.index)))
        let trace = AgentTrace(steps: ordered, hints: hints, note: note)
        let details = AnswerDetails(provider: provider.name, scope: item.name, mode: .plan, candidates: ordered.count,
                                    contextCharacters: findingsText(ordered).count, passages: citations, retrievalQuery: nil, filter: nil)
        return Outcome(text: text.trimmingCharacters(in: .whitespacesAndNewlines), citations: citations, trace: trace, details: details)
    }
}
