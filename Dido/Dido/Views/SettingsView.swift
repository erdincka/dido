import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private var llmService = LLMService.shared
    private var chunker = DocumentChunkingService.shared
    @ObservationIgnored private var appState = AppState.shared
    
    @State private var endpointType: APIEndpointType
    @State private var externalBaseURL: String
    @State private var externalApiToken: String
    @State private var selectedModel: String
    @State private var systemPrompt: String
    
    @State private var chunkSize: Int
    @State private var chunkOverlap: Int
    
    @State private var pkmRootPath: String
    @State private var pkmRootBookmark: Data?
    
    init() {
        _endpointType = State(initialValue: LLMService.shared.endpointType)
        _externalBaseURL = State(initialValue: LLMService.shared.externalBaseURL)
        _externalApiToken = State(initialValue: LLMService.shared.externalApiToken)
        _selectedModel = State(initialValue: LLMService.shared.selectedModel)
        _systemPrompt = State(initialValue: LLMService.shared.systemPrompt)
        
        _chunkSize = State(initialValue: DocumentChunkingService.shared.chunkSize)
        _chunkOverlap = State(initialValue: DocumentChunkingService.shared.chunkOverlap)
        
        _pkmRootPath = State(initialValue: AppState.shared.pkmRootPath)
        _pkmRootBookmark = State(initialValue: AppState.shared.pkmRootBookmark)
    }
    
    var body: some View {
        VStack {
            Form {
                Section("LLM Configuration") {
                    Picker("API Type", selection: $endpointType) {
                        ForEach(APIEndpointType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if endpointType == .openAICompatible {
                        Text("OpenAI API Compatible endpoint is planned for future releases.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        
                        TextField("Base URL", text: .constant("https://api.openai.com/v1"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        
                        SecureField("API Token (Optional)", text: .constant("••••••••••••••••••••••••"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                            
                        TextField("Model Name", text: .constant("gpt-4o"))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                    } else {
                        TextField("Base URL", text: $externalBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                Task {
                                    llmService.externalBaseURL = externalBaseURL
                                    await llmService.fetchAvailableModels()
                                    selectedModel = llmService.selectedModel
                                }
                            }
                        
                        SecureField("API Token (Optional)", text: $externalApiToken)
                            .textFieldStyle(.roundedBorder)
                            
                        HStack {
                            if llmService.availableModels.isEmpty {
                                TextField("Model Name", text: $selectedModel)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                Picker("Model Name", selection: $selectedModel) {
                                    if selectedModel.isEmpty {
                                        Text("Select a model...").tag("")
                                    } else if !llmService.availableModels.contains(selectedModel) {
                                        Text(selectedModel).tag(selectedModel)
                                    }
                                    
                                    ForEach(llmService.availableModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                            
                            Button(action: {
                                Task {
                                    llmService.externalBaseURL = externalBaseURL
                                    await llmService.fetchAvailableModels()
                                    selectedModel = llmService.selectedModel
                                }
                            }) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.plain)
                            .help("Refresh Models")
                        }
                    }
                    
                    TextEditor(text: $systemPrompt)
                        .frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                }
                
                Section("Indexing Configuration") {
                    HStack {
                        Text("PKM Root:")
                        Text(pkmRootPath.isEmpty ? "Not set" : pkmRootPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Select...") {
                            selectPKMRoot()
                        }
                    }
                    
                    Stepper("Chunk Size: \(chunkSize)", value: $chunkSize, in: 100...5000, step: 100)
                    Stepper("Chunk Overlap: \(chunkOverlap)", value: $chunkOverlap, in: 0...1000, step: 50)
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Spacer()
                Button("Save Settings") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .padding(.bottom, 28)
        .navigationTitle("Settings")
        .onAppear {
            if endpointType == .ollama && llmService.availableModels.isEmpty {
                Task {
                    await llmService.fetchAvailableModels()
                    selectedModel = llmService.selectedModel
                }
            }
        }
        .onChange(of: llmService.selectedModel) { oldValue, newValue in
            if selectedModel != newValue {
                selectedModel = newValue
            }
        }
        .onChange(of: selectedModel) { oldValue, newValue in
            llmService.selectedModel = newValue
        }
    }
    
    private func selectPKMRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                pkmRootPath = url.path
                pkmRootBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
    }
    
    private func saveSettings() {
        llmService.endpointType = endpointType
        llmService.externalBaseURL = externalBaseURL
        llmService.externalApiToken = externalApiToken
        llmService.selectedModel = selectedModel
        llmService.systemPrompt = systemPrompt
        
        chunker.chunkSize = chunkSize
        chunker.chunkOverlap = chunkOverlap
        
        appState.pkmRootPath = pkmRootPath
        appState.pkmRootBookmark = pkmRootBookmark
    }
}
