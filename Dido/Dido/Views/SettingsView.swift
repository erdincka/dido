import SwiftUI

/// The native Settings window: Libraries, General, Intelligence and Index tabs. Changes apply immediately.
/// The chosen tab is remembered; a Debug launch can pick one with `-settingsTab libraries`.
struct SettingsView: View {
    @AppStorage("settingsTab") private var selection = "libraries"

    var body: some View {
        TabView(selection: $selection) {
            LibrariesSettingsTab()
                .tabItem { Label("Libraries", systemImage: "books.vertical") }
                .tag("libraries")
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            IntelligenceSettingsTab()
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
                .tag("intelligence")
            IndexSettingsTab()
                .tabItem { Label("Index", systemImage: "tray.full") }
                .tag("index")
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
                Toggle("Index the libraries in the background and watch for changes", isOn: $indexSettings.autoIndex)
                Toggle("Show Dido in the menu bar for quick questions", isOn: $appState.showMenuBarExtra)
            } footer: {
                Text("Dido reads your library folders in place and never modifies them. Indexed text and chat history live in ~/Library/Application Support/Dido.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: indexSettings.autoIndex) { _, _ in LibraryManager.shared.reactivate() }
        .onChange(of: indexSettings.excludePatterns) { _, _ in LibraryManager.shared.reactivate() }
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

            Section {
                Toggle("Split multi-step questions into sub-tasks you can review", isOn: $llm.autoPlan)
                Toggle("Let sub-tasks run read-only shell commands inside the library", isOn: $llm.allowShellSteps)
                    .disabled(!llm.autoPlan)
            } header: {
                Text("Sub-tasks")
            } footer: {
                Text("Questions that need browsing folders, checking dates or looking in several places are planned as sub-tasks. You see the plan first, and can edit, stop, re-run or steer each step while it runs. Shell steps are limited to ls, find, grep, cat, head, tail, wc, stat, du, file, sort and uniq, with every path checked against the library folder.")
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
        .onChange(of: llm.embeddingSource) { _, _ in Task { await DocumentIndexer.shared.loadIndexes() } }
        .onChange(of: llm.serverEmbeddingModel) { _, _ in Task { await DocumentIndexer.shared.loadIndexes() } }
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
    private let manager = LibraryManager.shared
    private let progress = IndexProgress.shared

    var body: some View {
        Form {
            Section {
                Toggle("Recognise text in images and scanned PDFs (OCR)", isOn: $indexSettings.ocrEnabled)
                TextField("Path to uvx (optional)", text: $indexSettings.converterPath, prompt: Text("/opt/homebrew/bin/uvx"))
                    .textFieldStyle(.roundedBorder)
                Stepper("OCR at most \(indexSettings.ocrMaxPages) pages per scanned PDF", value: $indexSettings.ocrMaxPages, in: 5...500, step: 5)
                Stepper("Skip files larger than \(indexSettings.maxFileSizeMB) MB", value: $indexSettings.maxFileSizeMB, in: 5...2000, step: 5)
                Stepper("Chunk size: \(indexSettings.chunkSize) characters", value: $indexSettings.chunkSize, in: 100...5000, step: 100)
                Stepper("Chunk overlap: \(indexSettings.chunkOverlap) characters", value: $indexSettings.chunkOverlap, in: 0...1000, step: 50)
            } header: {
                Text("Extraction")
            } footer: {
                Text("Office and EPUB files are converted with markitdown through uvx (brew install uv). OCR uses Apple's Vision framework. Chunk changes re-chunk files on the next scan.")
            }

            Section {
                TextEditor(text: $indexSettings.excludePatterns)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
            } header: {
                Text("Exclude")
            } footer: {
                Text("One glob pattern per line, matched against file names and paths relative to each library, for example `Archive/`, `*.log` or `Drafts/**`. A `.didoignore` file in a library folder works the same way for that library. Changes apply when the libraries are next scanned.")
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
                        Button(manager.active.count > 1 ? "Index all libraries now" : "Index the library now") {
                            Task { await DocumentIndexer.shared.indexAllLibraries() }
                        }
                        .disabled(manager.active.isEmpty)
                        Button("Open index dashboard") { appState.showDashboard() }
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
