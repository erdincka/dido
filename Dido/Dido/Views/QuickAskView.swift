import SwiftUI
import MarkdownUI
import os

/// Asks the whole library from the menu bar and keeps the exchange in the library's chat thread.
@Observable @MainActor
final class QuickAskModel {
    var question = ""
    var answer = ""
    var sources: [Citation] = []
    var error: String?
    private(set) var isGenerating = false
    private var task: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.dido", category: "QuickAsk")

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        guard let root = AppState.shared.rootURL else {
            error = "Choose a library folder in Settings first."
            return
        }
        let item = SelectedItem.library(root: root)
        let store = ChatStore.shared
        let history = store.messages(for: item)
        let userMessage = ChatMessage(role: .user, content: text)
        store.append(userMessage, to: item)

        question = ""
        answer = ""
        sources = []
        error = nil
        isGenerating = true

        task = Task { [self] in
            var failure: String?
            var citations: [Citation] = []
            do {
                let llm = LLMService.shared
                let provider = llm.makeAnswerProvider()
                DebugLog.write("quick ask: provider \(provider.name)")
                let context = await ContextBuilder().build(for: item, question: text, budget: provider.contextBudget, includeImages: false)
                citations = context.citations
                DebugLog.write("quick ask: \(citations.count) passages")
                for try await token in llm.streamAnswer(question: text, history: history, context: context) {
                    self.answer += token
                }
            } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            DebugLog.write("quick ask: finished, failure=\(failure ?? "none"), answer=\(self.answer.count) chars")
            self.finish(failure: failure, citations: citations, item: item)
        }
    }

    func stop() {
        task?.cancel()
    }

    private func finish(failure: String?, citations: [Citation], item: SelectedItem) {
        if let failure {
            error = failure
            logger.error("Quick ask failed: \(failure)")
        }
        if !answer.isEmpty {
            let reply = ChatMessage(role: .assistant, content: answer, sources: citations)
            ChatStore.shared.append(reply, to: item)
            sources = citations
        }
        isGenerating = false
        task = nil
    }
}

struct QuickAskView: View {
    @State private var model = QuickAskModel()
    private let llm = LLMService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                TextField("Ask your library…", text: $model.question)
                    .textFieldStyle(.plain)
                    .onSubmit { model.ask() }
                if model.isGenerating {
                    Button { model.stop() } label: { Image(systemName: "stop.circle.fill").foregroundStyle(.red) }
                        .buttonStyle(.plain)
                } else {
                    Button { model.ask() } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain)
                        .disabled(model.question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }

            if model.isGenerating && model.answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching the library…").font(.caption).foregroundStyle(.secondary)
                }
            } else if !model.answer.isEmpty {
                ScrollView {
                    Markdown(MessageRow.linkCitations(in: model.answer))
                        .markdownTheme(.basic)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { _ in openInDido(); return .handled })
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 320)
                if !model.sources.isEmpty {
                    Text("\(model.sources.count) passage\(model.sources.count == 1 ? "" : "s") from \(Set(model.sources.map(\.filename)).count) file\(Set(model.sources.map(\.filename)).count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Open in Dido", action: openInDido)
                    .controlSize(.small)
                Spacer()
                Text(llm.answerProviderName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private func openInDido() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.windows.contains(where: { $0.isVisible && $0.frame.width > 400 }) == false {
            // The main window was closed: ask AppKit for a new one, as File > New Window would.
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
        AppState.shared.askLibrary()
    }
}
