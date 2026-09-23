import SwiftUI

/// First launch: choose the library folder, check the answer source, start the first scan.
struct OnboardingView: View {
    @Bindable private var appState = AppState.shared
    @Bindable private var llm = LLMService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var serverResult: String?

    var onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Dido").font(.title2.bold())
                    Text("Ask questions about the documents in a folder. Everything stays on this Mac unless you choose a server.")
                        .foregroundStyle(.secondary)
                }
            }

            step(number: 1, title: "Choose your library folder", done: appState.rootURL != nil) {
                HStack {
                    Text(appState.pkmRootPath.isEmpty ? "No folder chosen yet" : appState.pkmRootPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseRoot)
                }
                Text("Dido reads the folder in place and never changes your files. Subfolders are included; add a .didoignore file to skip some.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(number: 2, title: "Check how answers are generated", done: llm.appleModelStatus.isAvailable || serverResult?.hasPrefix("Found") == true) {
                Label(llm.appleModelStatus.message, systemImage: llm.appleModelStatus.isAvailable ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(llm.appleModelStatus.isAvailable ? .green : .secondary)
                if !llm.appleModelStatus.isAvailable {
                    Text("Without Apple Intelligence, Dido uses an OpenAI-compatible server. Ollama on this Mac is the simplest option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        TextField("Server URL", text: $llm.externalBaseURL, prompt: Text(LLMService.defaultBaseURL))
                            .textFieldStyle(.roundedBorder)
                        Button(testing ? "Testing…" : "Test") { testServer() }
                            .disabled(testing)
                    }
                    if let serverResult {
                        Text(serverResult).font(.caption).foregroundStyle(serverResult.hasPrefix("Found") ? .green : .red)
                    }
                    if !llm.availableModels.isEmpty {
                        Picker("Model", selection: $llm.selectedModel) {
                            ForEach(llm.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }

            step(number: 3, title: "Start", done: false) {
                Text("Dido indexes the folder in the background and keeps the index current as files change. You can ask about a file straight away; the whole-library chat fills up as the scan progresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Not now") { finish() }
                Spacer()
                Button("Start indexing") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.rootURL == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, done: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                    .foregroundStyle(done ? .green : .secondary)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 6, content: content)
                .padding(.leading, 26)
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
        }
    }

    private func testServer() {
        Task {
            testing = true
            let count = await llm.fetchAvailableModels()
            serverResult = count > 0 ? "Found \(count) model\(count == 1 ? "" : "s")." : "No models found. Check the URL and that the server is running."
            testing = false
        }
    }

    private func finish() {
        onFinish()
        dismiss()
    }
}
