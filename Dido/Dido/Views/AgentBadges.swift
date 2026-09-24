import SwiftUI
import MarkdownUI

/// Small shared pieces of the sub-task views.

struct AgentStatusIcon: View {
    let status: AgentStepStatus

    var body: some View {
        Group {
            switch status {
            case .pending: Image(systemName: "circle").foregroundStyle(.secondary)
            case .running: ProgressView().controlSize(.mini)
            case .waitingForUser: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
        .help(status.label)
    }
}

struct AgentToolBadge: View {
    let tool: AgentToolCall
    var outsideScope = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: tool.kind.symbol)
            Text(tool.summary)
                .lineLimit(1)
                .truncationMode(.middle)
            if outsideScope {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Outside the folder this chat is about (still inside the library)")
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help(tool.summary)
    }
}

/// The log lines of one step, monospaced with a time stamp.
struct AgentTraceLines: View {
    let entries: [AgentTraceEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.time, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.tertiary)
                    Text(entry.text)
                        .textSelection(.enabled)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A step's finding as Markdown with clickable citations. Long findings (listings, command output) start folded.
struct AgentFindingView: View {
    let finding: String
    let citations: [Citation]
    var onOpen: ((Citation) -> Void)?
    var fontScale: CGFloat = 0.85

    @State private var showAll = false

    private static let previewLines = 12
    private var lines: [Substring] { finding.split(separator: "\n", omittingEmptySubsequences: false) }
    private var isLong: Bool { lines.count > Self.previewLines + 3 || finding.count > 2_000 }

    private var shown: String {
        guard isLong, !showAll else { return finding }
        var kept = lines.prefix(Self.previewLines).joined(separator: "\n")
        // Close an open code fence so the preview still renders as code.
        if kept.components(separatedBy: "```").count % 2 == 0 { kept += "\n```" }
        return kept
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Markdown(MessageRow.linkCitations(in: shown))
                .markdownTheme(.basic)
                .markdownTextStyle { FontSize(.em(fontScale)) }
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "dido-source", let number = Int(url.host ?? ""),
                          let source = citations.first(where: { $0.index == number }) else { return .systemAction }
                    onOpen?(source)
                    return .handled
                })
            if isLong {
                Button(showAll ? "Show less" : "Show all (\(lines.count) lines)") {
                    withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(.blue)
            }
        }
    }
}
