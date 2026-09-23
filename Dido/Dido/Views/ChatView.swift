import SwiftUI
import QuickLook
import os

/// The conversation about one file, folder or the whole library. Streams answers and persists turns through `ChatStore`.
struct ChatView: View {
    let selectedItem: SelectedItem

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var streamingText = ""
    @State private var generation: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var previewCitation: Citation?
    @State private var compareMode = false
    @Bindable private var appState = AppState.shared

    private let chatStore = ChatStore.shared
    private let llm = LLMService.shared
    private let logger = Logger(subsystem: "com.dido", category: "ChatView")

    private var isGenerating: Bool { generation != nil }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(item: selectedItem, previewURL: $previewURL, showPreview: $appState.previewVisible, compareMode: $compareMode)
            Divider()
            transcript
            Divider()
            ChatComposer(
                draft: $draft,
                isGenerating: isGenerating,
                placeholder: compareMode ? "Ask each file in \(selectedItem.name)…" : "Ask Dido about \(selectedItem.name)…",
                onSend: { send(draft) },
                onStop: stop
            )
        }
        .quickLookPreview($previewURL)
        .inspector(isPresented: $appState.previewVisible) {
            PreviewPane(item: selectedItem, citation: previewCitation)
                .inspectorColumnWidth(min: 320, ideal: 420, max: 720)
        }
        .task(id: selectedItem.id) {
            messages = chatStore.messages(for: selectedItem)
            appState.retrievalFilter = RetrievalFilter()
            compareMode = AppState.shared.debugCompare && selectedItem.kind == .folder
            if let citation = AppState.shared.pendingCitation {
                AppState.shared.pendingCitation = nil
                openSource(citation)
            }
            if let question = AppState.shared.pendingQuestion {
                AppState.shared.pendingQuestion = nil
                send(question)
            }
        }
        .onDisappear { stop() }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if messages.isEmpty && !isGenerating {
                        WelcomeView(item: selectedItem) { suggestion in draft = suggestion }
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        row(for: message, at: index)
                            .id(message.id)
                    }
                    if isGenerating {
                        MessageRow(message: ChatMessage(role: .assistant, content: streamingText), isStreaming: true)
                            .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func row(for message: ChatMessage, at index: Int) -> some View {
        let isLastAssistant = message.role == .assistant && index == messages.count - 1
        let question = message.role == .assistant ? messages[..<index].last(where: { $0.role == .user })?.content : nil
        return MessageRow(
            message: message,
            onCopy: { copy(message) },
            onDelete: { delete(message) },
            onOpenSource: { openSource($0) },
            onRegenerate: isLastAssistant ? { regenerate(message) } : nil,
            onEdit: message.role == .user ? { edit(message) } : nil,
            onExport: message.role == .assistant ? { ChatExport.save(question: question, message: message, suggestedName: "\(selectedItem.name) answer.md") } : nil,
            onCopyWithSources: message.role == .assistant && !message.sources.isEmpty ? { ChatExport.copyWithSources(question: question, message: message) } : nil
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // The lazy stack lays out a new row a moment after it is inserted, so scroll on the next turn of the run loop.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isGenerating {
                    proxy.scrollTo("streaming", anchor: .bottom)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Message actions

    private func copy(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func delete(_ message: ChatMessage) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            messages.removeAll { $0.id == message.id }
        }
        chatStore.delete(messageID: message.id, in: selectedItem)
    }

    /// Removes the reply and asks its question again.
    private func regenerate(_ reply: ChatMessage) {
        guard !isGenerating, let index = messages.firstIndex(where: { $0.id == reply.id }),
              let question = messages[..<index].last(where: { $0.role == .user }) else { return }
        truncate(from: question.id)
        send(question.content)
    }

    /// Puts the question back in the composer and removes it and everything after it.
    private func edit(_ question: ChatMessage) {
        guard !isGenerating else { return }
        draft = question.content
        truncate(from: question.id)
    }

    private func truncate(from messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        withAnimation { messages.removeSubrange(index...) }
        chatStore.deleteMessages(from: messageID, in: selectedItem)
    }

    /// Shows a cited passage in the preview pane, in context of its neighbours.
    private func openSource(_ citation: Citation) {
        previewCitation = citation
        appState.previewVisible = true
    }

    /// The [n] markers the model actually used, including lists such as [2, 5], so the sources row matches the answer.
    private static func citedIndexes(in text: String) -> Set<Int> {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\]"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var numbers: Set<Int> = []
        for match in regex.matches(in: text, range: range) {
            guard let groupRange = Range(match.range(at: 1), in: text) else { continue }
            for piece in text[groupRange].split(separator: ",") {
                if let number = Int(piece.trimmingCharacters(in: .whitespaces)) { numbers.insert(number) }
            }
        }
        return numbers
    }

    // MARK: - Asking

    private func send(_ text: String) {
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
            generation = Task {
                var failure: String?
                var content = ""
                do {
                    content = try await CompareRunner(folder: selectedItem, question: question) { progress in streamingText = progress }.run()
                    streamingText = content
                } catch {
                    if !Task.isCancelled { failure = error.localizedDescription }
                }
                finishGeneration(stopped: Task.isCancelled, failure: failure, sources: [], details: nil)
            }
            return
        }

        generation = Task {
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
    }

    private func stop() {
        generation?.cancel()
    }

    private func finishGeneration(stopped: Bool, failure: String?, sources: [Citation], details: AnswerDetails?, reported: [Int] = []) {
        var content = streamingText
        if let failure {
            content += (content.isEmpty ? "" : "\n\n") + "**Error:** \(failure)"
        } else if stopped && !content.isEmpty {
            content += "\n\n_Stopped._"
        }
        if !content.isEmpty {
            let cited = Self.citedIndexes(in: content).union(reported)
            let used = sources.filter { cited.contains($0.index) }
            let reply = ChatMessage(role: .assistant, content: content, sources: used.isEmpty ? sources : used, details: details)
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

/// Suggestions shown before the first message.
struct WelcomeView: View {
    let item: SelectedItem
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue.opacity(0.3))
            Text(item.isLibrary ? "Ask anything about your library" : "Start a conversation about this \(item.isDirectory ? "folder" : "file")")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                if !item.isLibrary {
                    SuggestionChip(text: "Summarise this \(item.isDirectory ? "folder" : "document")") {
                        onSuggestion("Summarise \(item.name).")
                    }
                }
                SuggestionChip(text: "What are the key points?") {
                    onSuggestion(item.isLibrary ? "What are the most important recent decisions across my documents?" : "What are the most important points in \(item.name)?")
                }
                if item.kind == .folder {
                    SuggestionChip(text: "What is in this folder?") {
                        onSuggestion("List the main files in this folder and what each one is about.")
                    }
                }
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
}

struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
