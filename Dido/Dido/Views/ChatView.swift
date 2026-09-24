import SwiftUI
import QuickLook
import os

/// The conversation about one file, folder or the whole library. Streams answers and persists turns through `ChatStore`.
struct ChatView: View {
    let selectedItem: SelectedItem

    @State var messages: [ChatMessage] = []
    @State var draft = ""
    @State var streamingText = ""
    @State var generation: Task<Void, Never>?
    @State private var previewURL: URL?
    @State private var previewCitation: Citation?
    @State var compareMode = false
    /// Present while a question runs as reviewed sub-tasks; the transcript shows its card instead of the streaming row.
    @State var agentRunner: AgentRunner?
    @Bindable var appState = AppState.shared

    let chatStore = ChatStore.shared
    let llm = LLMService.shared
    let logger = Logger(subsystem: "com.dido", category: "ChatView")

    var isGenerating: Bool { generation != nil }

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
                    // Distinct ids: a lazy stack keeps showing the row it laid out first when two views share one id.
                    if let runner = agentRunner {
                        AgentRunView(runner: runner, onOpenSource: openSource)
                            .id("agent")
                    } else if isGenerating {
                        MessageRow(message: ChatMessage(role: .assistant, content: streamingText), isStreaming: true)
                            .id("streaming")
                    }
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: streamingText) { _, _ in scrollToBottom(proxy) }
            .onChange(of: agentRunner?.steps.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: agentRunner?.answerText) { _, _ in scrollToBottom(proxy) }
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
                if agentRunner != nil {
                    proxy.scrollTo("agent", anchor: .bottom)
                } else if isGenerating {
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
    func openSource(_ citation: Citation) {
        previewCitation = citation
        appState.previewVisible = true
    }

    /// The [n] markers the model actually used, including lists such as [2, 5], so the sources row matches the answer.
    static func citedIndexes(in text: String) -> Set<Int> {
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
}
