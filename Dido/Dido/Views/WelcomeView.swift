import SwiftUI

/// Suggestions shown before the first message.
struct WelcomeView: View {
    let item: SelectedItem
    let onSuggestion: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue.opacity(0.3))
            Text(item.isLibrary ? "Ask anything about your library" : "Start a conversation about this \(item.isDirectory ? "folder" : "file")")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                if !item.isLibrary {
                    SuggestionChip(text: "Summarise this \(item.isDirectory ? "folder" : "document")") {
                        onSuggestion("Summarise \(item.name).")
                    }
                }
                SuggestionChip(text: "What are the key points?") {
                    onSuggestion(item.isLibrary ? "What are the most important recent decisions across my documents?" : "What are the most important points in \(item.name)?")
                }
                if item.kind == .folder {
                    SuggestionChip(text: "What is in this folder?") {
                        onSuggestion("List the main files in this folder and what each one is about.")
                    }
                }
            }
            .padding(.top)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding()
    }
}

struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(.subheadline, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
