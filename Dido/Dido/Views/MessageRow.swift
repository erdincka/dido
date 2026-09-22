import SwiftUI
import MarkdownUI

/// One chat bubble. Assistant replies render as Markdown with clickable [n] citations and a sources list.
struct MessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    var onCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onOpenSource: ((Citation) -> Void)? = nil

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

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                bubble
                if !message.sources.isEmpty {
                    SourcesList(sources: message.sources, onOpen: onOpenSource)
                }
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
                Markdown(Self.linkCitations(in: message.content))
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "dido-source", let number = Int(url.host ?? ""),
                              let source = message.sources.first(where: { $0.index == number }) else { return .systemAction }
                        onOpenSource?(source)
                        return .handled
                    })
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

    /// Turns bare [n] and [n, m] markers into links the bubble can open. Existing Markdown links are left alone.
    static func linkCitations(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()"#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: text), let group = Range(match.range(at: 1), in: text) else { continue }
            let links = text[group].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { "[\($0)](dido-source://\($0))" }
                .joined(separator: ", ")
            output.replaceSubrange(whole, with: "\\[" + links + "\\]")
        }
        return output
    }
}

/// Numbered passages an answer drew on. Clicking one previews the file.
struct SourcesList: View {
    let sources: [Citation]
    var onOpen: ((Citation) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(sources, id: \.index) { source in
                    Button { onOpen?(source) } label: {
                        HStack(spacing: 4) {
                            Text("\(source.index)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.blue)
                            Text(source.filename)
                                .font(.caption2)
                                .lineLimit(1)
                            Text("part \(source.ordinal + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(source.path)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Wraps its children onto as many rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in rows {
            var rowWidth: CGFloat = 0
            var rowHeight: CGFloat = 0
            for item in row {
                rowWidth += item.size.width
                rowHeight = max(rowHeight, item.size.height)
            }
            rowWidth += CGFloat(max(row.count - 1, 0)) * spacing
            width = max(width, rowWidth)
            height += rowHeight
        }
        height += CGFloat(max(rows.count - 1, 0)) * spacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(proposal: proposal, subviews: subviews) {
            var x = bounds.minX
            let rowHeight = row.map { $0.size.height }.max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var width: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if width + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append((index, size))
            width += size.width + spacing
        }
        return rows
    }
}
