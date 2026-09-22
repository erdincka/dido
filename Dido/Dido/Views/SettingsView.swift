import SwiftUI

/// The native Settings window: General, Intelligence and Index tabs. Changes apply immediately.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            IntelligenceSettingsTab()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            IndexSettingsTab()
                .tabItem { Label("Index", systemImage: "tray.full") }
        }
        .frame(width: 640)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var indexSettings = IndexSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Library folder")
                    Text(appState.pkmRootPath.isEmpty ? "Not set" : appState.pkmRootPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseRoot)
                }
                Toggle("Index the library in the background and watch for changes", isOn: $indexSettings.autoIndex)
                Toggle("Show Dido in the menu bar for quick questions", isOn: $appState.showMenuBarExtra)
            } footer: {
                Text("Dido reads the library folder in place and never modifies it. Indexed text and chat history live in ~/Library/Application Support/Dido.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: indexSettings.autoIndex) { _, enabled in
            LibraryMonitor.shared.deactivate()
            LibraryMonitor.shared.activate(root: appState.activateRoot(), autoIndex: enabled)
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            appState.pkmRootBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            appState.pkmRootPath = url.path
            appState.showNotification("Library folder set to \(url.lastPathComponent)", type: .success)
        }
    }
}

// MARK: - Intelligence

struct IntelligenceSettingsTab: View {
    @Bindable private var llm = LLMService.shared
    @State private var token: String = LLMService.shared.externalApiToken
    @State private var isRefreshing = false
    private let appState = AppState.shared

    var body: some View {
        Form {
            Section {
                Picker("Answer with", selection: $llm.answerSourceChoice) {
                    Text("Automatic (Apple Intelligence when available)").tag(AnswerSource?.none)
                    ForEach(AnswerSource.allCases, id: \.self) { Text($0.label).tag(AnswerSource?.some($0)) }
                }
                Label(llm.appleModelStatus.message, systemImage: llm.appleModelStatus.isAvailable ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Embeddings", selection: $llm.embeddingSource) {
                    ForEach(EmbeddingSource.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if llm.embeddingSource == .server {
                    TextField("Server embedding model", text: $llm.serverEmbeddingModel, prompt: Text("nomic-embed-text"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("On-device embeddings need no server and download a small model on first use. Changing the embedding source re-embeds files the next time they are indexed.")
            }

            Section {
                TextField("Base URL", text: $llm.externalBaseURL, prompt: Text(LLMService.defaultBaseURL))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(refreshModels)
                SecureField("API token (optional)", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: token) { _, value in llm.externalApiToken = value }
                HStack {
                    if llm.availableModels.isEmpty {
                        TextField("Model", text: $llm.selectedModel, prompt: Text("llama3.2"))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $llm.selectedModel) {
                            if llm.selectedModel.isEmpty {
                                Text("Select a model…").tag("")
                            } else if !llm.availableModels.contains(llm.selectedModel) {
                                Text(llm.selectedModel).tag(llm.selectedModel)
                            }
                            ForEach(llm.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    Button(action: refreshModels) {
                        if isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("Fetch the model list from the server")
                }
            } header: {
                Text("OpenAI-compatible server")
            } footer: {
                Text("Ollama at \(LLMService.defaultBaseURL), LM Studio, LiteLLM or OpenAI itself. The token is kept in the Keychain.")
            }

            Section("System prompt") {
                TextEditor(text: $llm.systemPrompt)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                Button("Reset to default") { llm.systemPrompt = LLMService.defaultSystemPrompt }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onChange(of: llm.embeddingSource) { _, _ in Task { await DocumentIndexer.shared.loadVectorIndex() } }
        .onChange(of: llm.serverEmbeddingModel) { _, _ in Task { await DocumentIndexer.shared.loadVectorIndex() } }
        .task {
            if llm.availableModels.isEmpty { await llm.fetchAvailableModels() }
        }
    }

    private func refreshModels() {
        Task {
            isRefreshing = true
            let count = await llm.fetchAvailableModels()
            if count > 0 {
                appState.showNotification("Found \(count) model\(count == 1 ? "" : "s")", type: .success)
            } else {
                appState.showNotification("No models found. Check the URL, the token and that the server is running.", type: .error)
            }
            isRefreshing = false
        }
    }
}

// MARK: - Index

struct IndexSettingsTab: View {
    @Bindable private var indexSettings = IndexSettings.shared
    private let appState = AppState.shared
    private let progress = IndexProgress.shared

    var body: some View {
        Form {
            Section {
                Toggle("Recognise text in images and scanned PDFs (OCR)", isOn: $indexSettings.ocrEnabled)
                TextField("Path to uvx (optional)", text: $indexSettings.converterPath, prompt: Text("/opt/homebrew/bin/uvx"))
                    .textFieldStyle(.roundedBorder)
                Stepper("Chunk size: \(indexSettings.chunkSize) characters", value: $indexSettings.chunkSize, in: 100...5000, step: 100)
                Stepper("Chunk overlap: \(indexSettings.chunkOverlap) characters", value: $indexSettings.chunkOverlap, in: 0...1000, step: 50)
            } header: {
                Text("Extraction")
            } footer: {
                Text("Office and EPUB files are converted with markitdown through uvx (brew install uv). OCR uses Apple's Vision framework and covers the first \(DocumentParser.maxOCRPages) pages of a scanned PDF. Chunk changes apply to files indexed from now on.")
            }

            Section("Index") {
                HStack {
                    if progress.isIndexing {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))).frame(maxWidth: 220)
                        Text("\(progress.completed) of \(progress.total): \(progress.currentFile)")
                            .font(.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Cancel") { Task { await DocumentIndexer.shared.cancel() } }
                    } else {
                        Button("Index the library now") {
                            guard let root = appState.rootURL else { return }
                            Task { await DocumentIndexer.shared.index(root) }
                        }
                        .disabled(appState.rootURL == nil)
                        Button("Open index dashboard") { appState.showDashboard() }
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
