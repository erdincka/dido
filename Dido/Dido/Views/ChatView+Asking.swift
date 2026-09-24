import SwiftUI

/// Sending a question: one retrieval pass, compare mode, or a plan of sub-tasks; and committing the reply.
extension ChatView {
    func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isGenerating else { return }
        draft = ""

        let history = messages
        let userMessage = ChatMessage(role: .user, content: question)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            messages.append(userMessage)
        }
        chatStore.append(userMessage, to: selectedItem)
        streamingText = ""
        logger.info("Asking about \(selectedItem.name)")

        if compareMode && selectedItem.kind == .folder {
            generation = Task { await runCompare(question) }
            return
        }
        generation = Task {
            if await shouldPlan(question) {
                await runPlanned(question, history: history)
            } else {
                await answerDirectly(question, history: history)
            }
        }
    }

    func stop() {
        generation?.cancel()
    }

    // MARK: - Routing

    /// Library and folder questions that need browsing, dates or several places are planned as sub-tasks.
    private func shouldPlan(_ question: String) async -> Bool {
        guard selectedItem.isDirectory, llm.autoPlan, appState.rootURL != nil else { return false }
        if appState.debugForcePlan { return true }
        let planner = AgentPlanner(provider: llm.makeAnswerProvider(), shellAllowed: llm.allowShellSteps)
        let decision = await planner.shouldPlan(question: question, item: selectedItem)
        return decision && !Task.isCancelled
    }

    // MARK: - One retrieval pass

    private func answerDirectly(_ question: String, history: [ChatMessage]) async {
        var failure: String?
        var sources: [Citation] = []
        var details: AnswerDetails?
        var reported: [Int] = []
        do {
            let provider = llm.makeAnswerProvider()
            let context = await ContextBuilder().build(for: selectedItem, question: question, history: history, budget: provider.contextBudget, includeImages: provider.supportsImages, filter: appState.retrievalFilter)
            sources = context.citations
            details = context.details(provider: provider.name, scope: selectedItem.name)
            for try await event in llm.streamAnswer(question: question, history: history, context: context) {
                switch event {
                case .token(let token): streamingText += token
                case .citations(let numbers): reported = numbers
                }
            }
        } catch {
            if !Task.isCancelled {
                failure = error.localizedDescription
                logger.error("Generation failed: \(error.localizedDescription)")
            }
        }
        finishGeneration(stopped: Task.isCancelled, failure: failure, sources: sources, details: details, reported: reported)
    }

    // MARK: - Compare mode

    private func runCompare(_ question: String) async {
        var failure: String?
        do {
            let content = try await CompareRunner(folder: selectedItem, question: question) { progress in streamingText = progress }.run()
            streamingText = content
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
        finishGeneration(stopped: Task.isCancelled, failure: failure, sources: [], details: nil)
    }

    // MARK: - Sub-tasks

    private func runPlanned(_ question: String, history: [ChatMessage]) async {
        guard let root = appState.rootURL else {
            await answerDirectly(question, history: history)
            return
        }
        let runner = AgentRunner(question: question, item: selectedItem, root: root, history: history)
        runner.autoApprove = appState.debugAutoRunPlan
        agentRunner = runner
        let outcome = await runner.run()
        agentRunner = nil
        if let outcome {
            streamingText = outcome.text
            finishGeneration(stopped: false, failure: nil, sources: outcome.citations, details: outcome.details, trace: outcome.trace)
        } else if let failure = runner.failure {
            finishGeneration(stopped: false, failure: failure, sources: [], details: nil)
        } else if runner.hasStarted {
            // Stopped part-way: keep what the steps found so the trace can be reviewed.
            streamingText = runner.answerText.isEmpty ? "Stopped before the answer was written." : runner.answerText
            finishGeneration(stopped: true, failure: nil, sources: [], details: nil, trace: AgentTrace(steps: runner.steps, hints: runner.hints, note: runner.note))
        } else {
            finishGeneration(stopped: true, failure: nil, sources: [], details: nil)
        }
    }

    // MARK: - Committing the reply

    func finishGeneration(stopped: Bool, failure: String?, sources: [Citation], details: AnswerDetails?, reported: [Int] = [], trace: AgentTrace? = nil) {
        var content = streamingText
        if let failure {
            content += (content.isEmpty ? "" : "\n\n") + "**Error:** \(failure)"
        } else if stopped && !content.isEmpty {
            content += "\n\n_Stopped._"
        }
        if !content.isEmpty {
            let cited = Self.citedIndexes(in: content).union(reported)
            let used = sources.filter { cited.contains($0.index) }
            let reply = ChatMessage(role: .assistant, content: content, sources: used.isEmpty ? sources : used, details: details, trace: trace)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(reply)
            }
            chatStore.append(reply, to: selectedItem)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "DidoOpenFirstSource"), let first = reply.sources.first {
                openSource(first)
                if let nth = AppState.shared.debugThenOpenSource, reply.sources.count >= nth {
                    AppState.shared.debugThenOpenSource = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { openSource(reply.sources[nth - 1]) }
                }
            }
            if let followUp = AppState.shared.debugFollowUpQuestion {
                AppState.shared.debugFollowUpQuestion = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send(followUp) }
            }
            #endif
        }
        streamingText = ""
        generation = nil
    }
}
