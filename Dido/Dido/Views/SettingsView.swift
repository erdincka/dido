import SwiftUI

/// Settings shown in the detail pane. Values are edited locally and written on Save.
struct SettingsView: View {
    private let llm = LLMService.shared
    private let indexSettings = IndexSettings.shared
    private let appState = AppState.shared

    @State private var baseURL: String
    @State private var token: String
    @State private var model: String
    @State private var systemPrompt: String
    @State private var chunkSize: Int
    @State private var chunkOverlap: Int
    @State private var answerSource: AnswerSource?
    @State private var embeddingSource: EmbeddingSource
    @State private var embeddingModel: String
    @State private var rootPath: String
    @State private var rootBookmark: Data?

    init() {
        let llm = LLMService.shared
        let index = IndexSettings.shared
        let app = AppState.shared
        _baseURL = State(initialValue: llm.externalBaseURL)
        _token = State(initialValue: llm.externalApiToken)
        _model = State(initialValue: llm.selectedModel)
        _systemPrompt = State(initialValue: llm.systemPrompt)
        _chunkSize = State(initialValue: index.chunkSize)
        _chunkOverlap = State(initialValue: index.chunkOverlap)
        _answerSource = State(initialValue: llm.answerSourceChoice)
        _embeddingSource = State(initialValue: llm.embeddingSource)
        _embeddingModel = State(initialValue: llm.serverEmbeddingModel)
        _rootPath = State(initialValue: app.pkmRootPath)
        _rootBookmark = State(initialValue: app.pkmRootBookmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                AnswerSourceSection(answerSource: $answerSource, embeddingSource: $embeddingSource, embeddingModel: $embeddingModel)
                LLMSettingsSection(baseURL: $baseURL, token: $token, model: $model, systemPrompt: $systemPrompt)
                IndexSettingsSection(
                    rootPath: $rootPath,
                    rootBookmark: $rootBookmark,
                    chunkSize: $chunkSize,
                    chunkOverlap: $chunkOverlap
                )
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Save settings", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .padding()
            }
        }
        .navigationTitle("Settings")
        .onChange(of: llm.selectedModel) { _, newValue in
            if model != newValue { model = newValue }
        }
    }

    private func save() {
        llm.externalBaseURL = baseURL
        llm.externalApiToken = token
        llm.selectedModel = model
        llm.systemPrompt = systemPrompt
        indexSettings.chunkSize = chunkSize
        indexSettings.chunkOverlap = chunkOverlap
        let embeddingChanged = llm.embeddingSource != embeddingSource || llm.serverEmbeddingModel != embeddingModel
        llm.answerSourceChoice = answerSource
        llm.embeddingSource = embeddingSource
        llm.serverEmbeddingModel = embeddingModel
        appState.pkmRootPath = rootPath
        appState.pkmRootBookmark = rootBookmark
        appState.updateStats()
        appState.showNotification("Settings saved", type: .success)
        if embeddingChanged {
            Task { await DocumentIndexer.shared.loadVectorIndex() }
        }
    }
}

struct AnswerSourceSection: View {
    @Binding var answerSource: AnswerSource?
    @Binding var embeddingSource: EmbeddingSource
    @Binding var embeddingModel: String

    private let llm = LLMService.shared

    var body: some View {
        Section {
            Picker("Answer with", selection: $answerSource) {
                Text("Automatic (Apple Intelligence when available)").tag(AnswerSource?.none)
                ForEach(AnswerSource.allCases, id: \.self) { Text($0.label).tag(AnswerSource?.some($0)) }
            }
            Label(llm.appleModelStatus.message, systemImage: llm.appleModelStatus.isAvailable ? "checkmark.circle" : "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Embeddings", selection: $embeddingSource) {
                ForEach(EmbeddingSource.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if embeddingSource == .server {
                TextField("Server embedding model", text: $embeddingModel, prompt: Text("nomic-embed-text"))
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            Text("Intelligence")
        } footer: {
            Text("On-device embeddings need no server and download a small model on first use. Changing the embedding source re-embeds files the next time they are indexed.")
        }
    }
}

struct LLMSettingsSection: View {
    @Binding var baseURL: String
    @Binding var token: String
    @Binding var model: String
    @Binding var systemPrompt: String

    @State private var isRefreshing = false
    private let llm = LLMService.shared
    private let appState = AppState.shared

    var body: some View {
        Section {
            TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434/v1"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { refreshModels() }

            SecureField("API token (optional)", text: $token)
                .textFieldStyle(.roundedBorder)

            HStack {
                if llm.availableModels.isEmpty {
                    TextField("Model", text: $model, prompt: Text("llama3.2"))
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Model", selection: $model) {
                        if model.isEmpty {
                            Text("Select a model…").tag("")
                        } else if !llm.availableModels.contains(model) {
                            Text(model).tag(model)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("System prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $systemPrompt)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                Button("Reset to default") { systemPrompt = LLMService.defaultSystemPrompt }
                    .controlSize(.small)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Any OpenAI-compatible server works: Ollama at http://localhost:11434/v1, LM Studio, LiteLLM or OpenAI itself.")
        }
    }

    private func refreshModels() {
        Task {
            isRefreshing = true
            llm.externalBaseURL = baseURL
            llm.externalApiToken = token
            let count = await llm.fetchAvailableModels()
            if count > 0 {
                appState.showNotification("Found \(count) model\(count == 1 ? "" : "s")", type: .success)
            } else {
                appState.showNotification("No models found. Check the URL, the token and that the server is running.", type: .error)
            }
            model = llm.selectedModel
            isRefreshing = false
        }
    }
}

struct IndexSettingsSection: View {
    @Binding var rootPath: String
    @Binding var rootBookmark: Data?
    @Binding var chunkSize: Int
    @Binding var chunkOverlap: Int

    private let appState = AppState.shared
    private let progress = IndexProgress.shared

    var body: some View {
        Section {
            HStack {
                Text("Library folder")
                Text(rootPath.isEmpty ? "Not set" : rootPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose…", action: chooseRoot)
            }

            Stepper("Chunk size: \(chunkSize) characters", value: $chunkSize, in: 100...5000, step: 100)
            Stepper("Chunk overlap: \(chunkOverlap) characters", value: $chunkOverlap, in: 0...1000, step: 50)

            HStack {
                if progress.isIndexing {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 220)
                    Text("\(progress.completed) of \(progress.total): \(progress.currentFile)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { Task { await DocumentIndexer.shared.cancel() } }
                } else {
                    Button("Index the library now") {
                        guard let root = appState.rootURL else { return }
                        Task { await DocumentIndexer.shared.index(root) }
                    }
                    .disabled(appState.rootURL == nil)
                    Spacer()
                }
            }
        } header: {
            Text("Library and indexing")
        } footer: {
            Text("Chunks are whole sentences packed to about the chunk size. Indexing uses the saved library folder and re-embeds files whose embeddings are missing or from another model.")
        }
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            rootPath = url.path
            rootBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
}
