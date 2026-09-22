import SwiftUI
import QuickLook
import os

/// The conversation about one file or folder. Streams answers and persists turns through `ChatStore`.
struct ChatView: View {
    let selectedItem: SelectedItem

    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var streamingText = ""
    @State private var generation: Task<Void, Never>?
    @State private var previewURL: URL?

    private let chatStore = ChatStore.shared
    private let llm = LLMService.shared
    private let logger = Logger(subsystem: "com.dido", category: "ChatView")

    private var isGenerating: Bool { generation != nil }

    var body: some View {
        VStack(spacing: 0) {
            ChatHeaderView(item: selectedItem, previewURL: $previewURL)
            Divider()
            transcript
            Divider()
            ChatComposer(
                draft: $draft,
                isGenerating: isGenerating,
                placeholder: "Ask Dido about \(selectedItem.name)…",
                onSend: send,
                onStop: stop
            )
        }
        .quickLookPreview($previewURL)
        .task(id: selectedItem.id) {
            messages = chatStore.messages(for: selectedItem)
            if let question = AppState.shared.pendingQuestion {
                AppState.shared.pendingQuestion = nil
                draft = question
                send()
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
                    ForEach(messages) { message in
                        MessageRow(
                            message: message,
                            onCopy: { copy(message) },
                            onDelete: { delete(message) }
                        )
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isGenerating {
                proxy.scrollTo("streaming", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - Actions

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

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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

        generation = Task {
            var failure: String?
            do {
                let (context, images) = await ContextBuilder().build(for: selectedItem, includeImages: llm.supportsVision)
                for try await token in llm.streamAnswer(question: question, history: history, context: context, images: images) {
                    streamingText += token
                }
            } catch {
                if !Task.isCancelled {
                    failure = error.localizedDescription
                    logger.error("Generation failed: \(error.localizedDescription)")
                }
            }
            finishGeneration(stopped: Task.isCancelled, failure: failure)
        }
    }

    private func stop() {
        generation?.cancel()
    }

    private func finishGeneration(stopped: Bool, failure: String?) {
        var content = streamingText
        if let failure {
            content += (content.isEmpty ? "" : "\n\n") + "**Error:** \(failure)"
        } else if stopped && !content.isEmpty {
            content += "\n\n_Stopped._"
        }
        if !content.isEmpty {
            let reply = ChatMessage(role: .assistant, content: content)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                messages.append(reply)
            }
            chatStore.append(reply, to: selectedItem)
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
            Text("Start a conversation about this \(item.isDirectory ? "folder" : "file")")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                SuggestionChip(text: "Summarise this \(item.isDirectory ? "folder" : "document")") {
                    onSuggestion("Summarise \(item.name).")
                }
                SuggestionChip(text: "What are the key points?") {
                    onSuggestion("What are the most important points in \(item.name)?")
                }
                if item.isDirectory {
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
