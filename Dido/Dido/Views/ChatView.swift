import SwiftUI
import QuickLook
import os

struct ChatView: View {
    let selectedItem: SelectedItem
    
    @Bindable private var appState = AppState.shared
    @State private var prompt: String = ""
    @State private var showMetadata = false
    @State private var previewURL: URL?
    
    private let logger = Logger(subsystem: "com.dido", category: "ChatView")
    
    private var isGenerating: Bool {
        get { appState.generatingStates[selectedItem.id, default: false] }
        nonmutating set { appState.generatingStates[selectedItem.id] = newValue }
    }
    
    var llmService = LLMService.shared
    var vectorDB = VectorDatabaseService.shared
    var parser = DocumentParserService.shared
    var indexer = DocumentIndexerService.shared
    @Environment(\.dismiss) private var dismiss
    
    static let quickLookExtensions = ["pdf", "rtf", "md", "txt", "markdown", "csv", "json", "swift", "py", "js", "html", "css", "xml", "yaml", "jpg", "png", "jpeg"]
    
    init(selectedItem: SelectedItem) {
        self.selectedItem = selectedItem
    }
    
    private var itemIndex: Int? {
        appState.selectedItems.firstIndex(where: { $0.id == selectedItem.id })
    }
    
    private var messages: [ChatMessage] {
        if let index = itemIndex {
            return appState.selectedItems[index].messages
        }
        return []
    }
    
    var body: some View {
        VStack(spacing: 0) {
            VStack {
                ScrollView {
                    ScrollViewReader { proxy in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageRow(message: message, onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(message.content, forType: .string)
                                }, onDelete: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                        deleteMessage(message)
                                    }
                                })
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                                    removal: .opacity.combined(with: .scale(scale: 0.95))
                                ))
                            }
                            
                            if isGenerating {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Thinking...")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .padding()
                                .id("generating")
                                .transition(.opacity)
                            }
                        }
                        .padding()
                        .onChange(of: messages.count) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onChange(of: isGenerating) { _, _ in
                            scrollToBottom(proxy: proxy)
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                scrollToBottom(proxy: proxy)
                            }
                        }
                    }
                }
                
                HStack(alignment: .bottom) {
                    TextField("Ask about \(selectedItem.name)...", text: $prompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...8)
                        .onSubmit {
                            submitPrompt()
                        }
                    
                    Button(action: submitPrompt) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(prompt.isEmpty ? .gray : .blue)
                            .symbolEffect(.bounce, value: isGenerating)
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.isEmpty || isGenerating)
                }
                .padding()
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 28)
        .navigationTitle("Chat: \(selectedItem.name)")
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                HStack() {
                    if Self.quickLookExtensions.contains(selectedItem.url.pathExtension.lowercased()) {
                        Button(action: { previewURL = selectedItem.url }) {
                            Image(systemName: "eye")
                        }
                        .help(Text("Quick Look"))
                    }
                    
                    Button(action: { showMetadata.toggle() }) {
                        Image(systemName: "info.circle")
                    }
                    .help(Text("Show metadata"))
                }
            }
        }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showMetadata) {
            metadataView
                .frame(width: 580, height: 240)
                .presentationDetents([.medium])
        }
    }
    
    @ViewBuilder
    private var metadataView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Metadata")
                    .font(.headline)
                Text("Path: \(selectedItem.url.path)")
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: selectedItem.url.path) {
                    if let size = attrs[.size] as? Int64, !selectedItem.isDirectory {
                        Text("Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                    }
                    if let modDate = attrs[.modificationDate] as? Date {
                        Text("Modified: \(modDate.formatted())")
                    }
                }
            }
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                if indexer.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Indexing... \(indexer.indexedCount) / \(indexer.totalCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                let docs = vectorDB.fetchDocuments(for: selectedItem.url.path)
                if let doc = docs.first {
                    Text(doc.isIndexed ? "Status: Indexed" : "Status: Skipped/Error")
                        .font(.caption)
                        .foregroundColor(doc.isIndexed ? .green : .orange)
                    if let meta = doc.metadataString {
                        Text(meta)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Status: Not Indexed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .top)
    }
    
    private func deleteMessage(_ message: ChatMessage) {
        logger.debug("Deleting message: \(message.id)")
        guard let index = itemIndex else { return }
        if let msgIndex = appState.selectedItems[index].messages.firstIndex(where: { $0.id == message.id }) {
            appState.selectedItems[index].messages.remove(at: msgIndex)
        }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.3)) {
            if isGenerating {
                proxy.scrollTo("generating", anchor: .bottom)
            } else if let last = messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
    
    private func submitPrompt() {
        guard !prompt.isEmpty, let index = itemIndex else { return }
        
        let userMessage = ChatMessage(role: .user, content: prompt)
        logger.info("Submitting prompt for item: \(selectedItem.name)")
        
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            appState.selectedItems[index].messages.append(userMessage)
            isGenerating = true
        }
        
        let query = prompt
        prompt = ""
        
        Task {
            do {
                let contextMsgs = appState.selectedItems[index].messages
                let response = try await llmService.generateResponse(
                    prompt: query,
                    messages: contextMsgs,
                    selectedItem: appState.selectedItems[index],
                    vectorDB: vectorDB,
                    parser: parser
                )
                
                logger.debug("Received LLM response (\(response.count) characters)")
                
                let assistantMessage = ChatMessage(role: .assistant, content: response)
                await MainActor.run {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        if let newIndex = self.itemIndex {
                            appState.selectedItems[newIndex].messages.append(assistantMessage)
                        }
                        isGenerating = false
                    }
                }
            } catch {
                logger.error("LLM Generation failed: \(error.localizedDescription)")
                await MainActor.run {
                    withAnimation(.easeInOut) {
                        if let newIndex = self.itemIndex {
                            appState.selectedItems[newIndex].messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                        }
                        isGenerating = false
                    }
                }
            }
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let onCopy: (() -> Void)?
    let onDelete: (() -> Void)?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .user { Spacer() }
            
            if message.role == .user {
                actionButtons
                    .padding(.top, 8)
            }
            
            Text(markdownString(for: message.content))
                .textSelection(.enabled)
                .padding()
                .background(message.role == .user ? Color.blue.opacity(0.8) : Color.gray.opacity(0.15))
                .foregroundColor(message.role == .user ? .white : .primary)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
            
            if message.role == .assistant {
                actionButtons
                    .padding(.top, 8)
            }
            
            if message.role == .assistant { Spacer() }
        }
    }
    
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if let onCopy = onCopy {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy message")
            }
            if let onDelete = onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete message")
            }
        }
        .opacity(0.6)
    }
    
    private func markdownString(for string: String) -> AttributedString {
        do {
            let attrString = try AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return attrString
        } catch {
            return AttributedString(string)
        }
    }
}

#Preview {
    ChatView(selectedItem: SelectedItem(url: URL(fileURLWithPath: "/tmp/sample.txt")))
}
