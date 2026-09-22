import SwiftUI

@main
struct DidoApp: App {
    @NSApplicationDelegateAdaptor(DebugScreenshotDelegate.self) private var delegate

    private var menuBarInserted: Binding<Bool> {
        Binding(get: { AppState.shared.showMenuBarExtra }, set: { AppState.shared.showMenuBarExtra = $0 })
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandMenu("Library") {
                Button("Home") { AppState.shared.showHome() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Ask the Whole Library") { AppState.shared.askLibrary() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Search Library") { AppState.shared.searchPresented = true }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Toggle Preview") { AppState.shared.previewVisible.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Index Current Item Again") { AppState.shared.reindexCurrentItem() }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Index Dashboard") { AppState.shared.showDashboard() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Index the Library Now") {
                    if let root = AppState.shared.rootURL {
                        Task { await DocumentIndexer.shared.index(root) }
                    }
                }
            }
            TextEditingCommands()
            TextFormattingCommands()
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Dido", systemImage: "sparkles", isInserted: menuBarInserted) {
            QuickAskView()
        }
        .menuBarExtraStyle(.window)
    }
}
