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
            TextEditingCommands()
            TextFormattingCommands()
        }
    }
}
