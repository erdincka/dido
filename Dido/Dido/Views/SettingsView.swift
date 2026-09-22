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
    @State private var embeddingsEnabled: Bool
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
        _embeddingsEnabled = State(initialValue: index.embeddingsEnabled)
        _embeddingModel = State(initialValue: index.embeddingModel)
        _rootPath = State(initialValue: app.pkmRootPath)
        _rootBookmark = State(initialValue: app.pkmRootBookmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LLMSettingsSection(baseURL: $baseURL, token: $token, model: $model, systemPrompt: $systemPrompt)
                IndexSettingsSection(
                    rootPath: $rootPath,
                    rootBookmark: $rootBookmark,
                    chunkSize: $chunkSize,
                    chunkOverlap: $chunkOverlap,
                    embeddingsEnabled: $embeddingsEnabled,
                    embeddingModel: $embeddingModel
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
        indexSettings.embeddingsEnabled = embeddingsEnabled
        indexSettings.embeddingModel = embeddingModel
        appState.pkmRootPath = rootPath
        appState.pkmRootBookmark = rootBookmark
        appState.updateStats()
        appState.showNotification("Settings saved", type: .success)
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
            Text("Model")
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
    @Binding var embeddingsEnabled: Bool
    @Binding var embeddingModel: String

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

            Toggle("Generate embeddings while indexing", isOn: $embeddingsEnabled)
            TextField("Embedding model", text: $embeddingModel, prompt: Text("text-embedding-3-small"))
                .textFieldStyle(.roundedBorder)
                .disabled(!embeddingsEnabled)

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
            Text("Embeddings are off by default. Vector search is not used yet, and remote embeddings cost time and, on paid services, money. Indexing uses the saved library folder.")
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
