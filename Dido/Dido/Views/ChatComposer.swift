import SwiftUI

/// The prompt field with a send button that becomes a stop button while streaming.
struct ChatComposer: View {
    @Binding var draft: String
    let isGenerating: Bool
    let placeholder: String
    let onSend: () -> Void
    let onStop: () -> Void

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    .lineLimit(1...10)
                    .onSubmit { if canSend { onSend() } }

                if isGenerating {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(canSend ? AnyShapeStyle(LinearGradient(colors: [.blue, .teal], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.gray))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                }
            }

            Text("Dido can make mistakes. Verify important information.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .opacity(0.7)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}
