import SwiftUI

@main
struct DidoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppState.shared.showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            TextEditingCommands()
            TextFormattingCommands()
        }
    }
}
