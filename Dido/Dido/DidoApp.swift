import SwiftUI

@main
struct DidoApp: App {
    @NSApplicationDelegateAdaptor(DebugScreenshotDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    AppState.shared.showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Ask the Whole Library") { AppState.shared.askLibrary() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Index Dashboard") { AppState.shared.showDashboard() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Index the Library Now") {
                    if let root = AppState.shared.rootURL {
                        Task { await DocumentIndexer.shared.index(root) }
                    }
                }
            }
            TextEditingCommands()
            TextFormattingCommands()
        }
    }
}
