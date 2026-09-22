import SwiftUI
import MarkdownUI

/// One chat bubble. Assistant replies render as Markdown; copy and delete appear on hover.
struct MessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    var onCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    @State private var isHovered = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if isUser { Spacer(minLength: 60) }

            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                    .clipShape(Circle())
                    .padding(.top, 4)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                bubble
                if !isStreaming {
                    actions.opacity(isHovered ? 1 : 0)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if isStreaming && message.content.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Dido is thinking…").foregroundStyle(.secondary)
                }
            } else if isUser {
                Text(message.content)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            } else {
                Markdown(message.content)
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: isUser ? 4 : 18
            )
            .fill(isUser ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.ultraThinMaterial))
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if let onCopy {
                Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                    .help("Copy")
            }
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help("Delete")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

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
