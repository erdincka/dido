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
            // Context Header
            HStack(spacing: 16) {
                Image(systemName: selectedItem.isDirectory ? "folder.fill" : fileIcon)
                    .font(.title)
                    .foregroundColor(selectedItem.isDirectory ? .blue : .secondary)
                    .frame(width: 44, height: 44)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedItem.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(selectedItem.isDirectory ? "Folder context" : "Document context")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 8) {
                    if Self.quickLookExtensions.contains(selectedItem.url.pathExtension.lowercased()) {
                        Button { previewURL = selectedItem.url } label: {
                            Image(systemName: "eye")
                        }
                        .buttonStyle(.bordered)
                        .help("Quick Look")
                    }
                    
                    Button { NSWorkspace.shared.activateFileViewerSelecting([selectedItem.url]) } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("Open in Finder")
                    
                    Button { showMetadata.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.bordered)
                    .help("File Info")
                    .popover(isPresented: $showMetadata, arrowEdge: .bottom) {
                        metadataView
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 20) {
                        if messages.isEmpty {
                            welcomeState
                        } else {
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
                            }
                        }
                        
                        if isGenerating {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Dido is thinking...")
                                    .foregroundColor(.secondary)
                                    .font(.system(.subheadline, design: .rounded))
                            }
                            .padding()
                            .id("generating")
                        }
                    }
                    .padding()
                    .onChange(of: messages.count) { _, _ in scrollToBottom(proxy: proxy) }
                    .onChange(of: isGenerating) { _, _ in scrollToBottom(proxy: proxy) }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            scrollToBottom(proxy: proxy)
                        }
                    }
                }
            }
            
            Divider()
            
            // Input Area
            VStack(spacing: 12) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Ask Dido about \(selectedItem.name)...", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .lineLimit(1...10)
                        .onSubmit {
                            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                submitPrompt()
                            }
                        }
                    
                    Button(action: submitPrompt) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AnyShapeStyle(.gray) : AnyShapeStyle(LinearGradient(colors: [.blue, .teal], startPoint: .top, endPoint: .bottom)))
                            .symbolEffect(.bounce, value: isGenerating)
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
                }
                
                Text("Dido can make mistakes. Verify important information.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .frame(maxHeight: .infinity)
        .quickLookPreview($previewURL)
    }
    
    private var fileIcon: String {
        let ext = selectedItem.url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "txt", "md": return "doc.text.fill"
        case "swift", "py", "js": return "terminal.fill"
        default: return "doc.fill"
        }
    }
    
    private var welcomeState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundColor(.blue.opacity(0.3))
            Text("Start a conversation about this \(selectedItem.isDirectory ? "folder" : "file")")
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 10) {
                SuggestionChip(text: "Summarize this \(selectedItem.isDirectory ? "folder" : "document")") {
                    prompt = "Can you provide a summary of \(selectedItem.name)?"
                }
                SuggestionChip(text: "What are the key points?") {
                    prompt = "What are the most important key points in \(selectedItem.name)?"
                }
                if selectedItem.isDirectory {
                    SuggestionChip(text: "What files are in this folder?") {
                        prompt = "Can you list the main files in this folder and what they are about?"
                    }
                }
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
    
    @ViewBuilder
    private var metadataView: some View {
        VStack(spacing: 0) {
            HStack {
                Label("File Information", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                
                Spacer()
                
                Button { showMetadata = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .onExitCommand { showMetadata = false }
            }
            .padding()
            
            Divider()
            
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        infoRow(label: "Path", value: selectedItem.url.path)
                        
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: selectedItem.url.path) {
                            if let size = attrs[.size] as? Int64, !selectedItem.isDirectory {
                                infoRow(label: "Size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                            if let modDate = attrs[.modificationDate] as? Date {
                                infoRow(label: "Modified", value: modDate.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                }
                
                Divider()
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Index Status")
                        .font(.subheadline.bold())
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if indexer.isIndexing {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Indexing... \(indexer.indexedCount) / \(indexer.totalCount)")
                                    .font(.caption)
                            }
                        }
                        
                        let docs = vectorDB.fetchDocuments(for: selectedItem.url.path)
                        if let doc = docs.first {
                            StatusTag(isIndexed: doc.isIndexed)
                            
                            if let meta = doc.metadataString {
                                Text(meta)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(3)
                            }
                        } else {
                            StatusTag(isIndexed: false)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .frame(width: 580, height: 320)
    }
    
    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    struct StatusTag: View {
        let isIndexed: Bool
        var body: some View {
            Text(isIndexed ? "INDEXED" : "NOT INDEXED")
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isIndexed ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                .foregroundColor(isIndexed ? .green : .orange)
                .cornerRadius(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isIndexed ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
                )
        }
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
            if message.role == .user {
                Spacer(minLength: 50)
            }
            
            if message.role == .assistant {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                    .clipShape(Circle())
                    .padding(.top, 4)
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(markdownString(for: message.content))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 18,
                            bottomLeadingRadius: 18,
                            bottomTrailingRadius: message.role == .user ? 18 : 18,
                            topTrailingRadius: message.role == .user ? 2 : 18
                        )
                        .fill(message.role == .user ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.ultraThinMaterial))
                    )
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
                
                HStack(spacing: 12) {
                    if let onCopy = onCopy {
                        Button(action: onCopy) {
                            Label("Copy", systemImage: "doc.on.doc")
                                .labelStyle(.iconOnly)
                        }
                    }
                    if let onDelete = onDelete {
                        Button(action: onDelete) {
                            Label("Delete", systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                    }
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)
                .opacity(0) // Hide by default, show on hover if possible in SwiftUI for Mac
            }
            .onHover { isHovered in
                // Technically onHover works on macOS
            }
            
            if message.role == .assistant {
                Spacer(minLength: 50)
            }
        }
    }
    
    private func markdownString(for string: String) -> AttributedString {
        do {
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            return try AttributedString(markdown: string, options: options)
        } catch {
            return AttributedString(string)
        }
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
                .cornerRadius(20)
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}


#Preview {
    ChatView(selectedItem: SelectedItem(url: URL(fileURLWithPath: "/tmp/sample.txt")))
}
