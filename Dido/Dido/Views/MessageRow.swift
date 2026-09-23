import SwiftUI
import MarkdownUI

/// One chat bubble. Assistant replies render as Markdown with clickable [n] citations and a sources list.
struct MessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    var onCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onOpenSource: ((Citation) -> Void)? = nil
    var onRegenerate: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil
    var onCopyWithSources: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var showWhy = false

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
                if showWhy, let details = message.details {
                    WhyThisAnswerView(details: details, cited: Set(message.sources.map(\.index)), onOpen: onOpenSource)
                }
                if !isStreaming {
                    actions.opacity(isHovered || showWhy ? 1 : 0)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
        .onHover { isHovered = $0 }
        .onAppear {
            if AppState.shared.debugExpandWhy, message.details != nil { showWhy = true }
        }
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
            if let onCopyWithSources {
                Button(action: onCopyWithSources) { Image(systemName: "doc.on.clipboard") }
                    .help("Copy with sources")
            }
            if let onExport {
                Button(action: onExport) { Image(systemName: "square.and.arrow.up") }
                    .help("Export as Markdown…")
            }
            if let onRegenerate {
                Button(action: onRegenerate) { Image(systemName: "arrow.clockwise") }
                    .help("Regenerate")
            }
            if let onEdit {
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .help("Edit and send again")
            }
            if let onDelete {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .help("Delete")
            }
            if message.details != nil {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showWhy.toggle() } } label: {
                    Image(systemName: showWhy ? "questionmark.circle.fill" : "questionmark.circle")
                }
                .help(showWhy ? "Hide why this answer" : "Why this answer")
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

/// How the context was chosen: provider, scope, selection mode and every passage with its similarity score.
struct WhyThisAnswerView: View {
    let details: AnswerDetails
    let cited: Set<Int>
    var onOpen: ((Citation) -> Void)?

    private var summary: String {
        let chars = details.contextCharacters.formatted()
        var text: String
        switch details.mode {
        case .whole:
            text = "Answered by \(details.provider). Scope: \(details.scope). All \(details.passages.count) passages fitted the model's budget and were sent in document order (\(chars) characters)."
        case .search:
            text = "Answered by \(details.provider). Scope: \(details.scope). \(details.candidates) passages were ranked by meaning (vectors) and by exact words (full text), fused by rank, and the top \(details.passages.count) extracts were sent (\(chars) characters). Scores are cosine similarity with small boosts for the question's words and recently modified files."
        }
        if let query = details.retrievalQuery { text += " The follow-up was searched as: “\(query)”." }
        if let filter = details.filter { text += " Filter: \(filter)." }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Why this answer", systemImage: "questionmark.circle")
                .font(.caption.weight(.semibold))
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(details.passages, id: \.index) { passage in
                    Button { onOpen?(passage) } label: {
                        HStack(spacing: 8) {
                            Text("\(passage.index)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(cited.contains(passage.index) ? .blue : .secondary)
                                .frame(width: 22, alignment: .trailing)
                            Text(passage.filename).font(.caption).lineLimit(1)
                            Text(passage.partLabel).font(.caption2).foregroundStyle(.secondary)
                            if passage.matchedText == true {
                                Image(systemName: "textformat.abc").font(.caption2).foregroundStyle(.secondary).help("Matched the question's words")
                            }
                            Spacer()
                            if details.mode == .search {
                                ProgressView(value: Double(min(max(passage.score, 0), 1)))
                                    .progressViewStyle(.linear)
                                    .frame(width: 70)
                                Text(String(format: "%.2f", passage.score))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                            Image(systemName: cited.contains(passage.index) ? "quote.bubble.fill" : "quote.bubble")
                                .font(.caption2)
                                .foregroundStyle(cited.contains(passage.index) ? .blue : .secondary.opacity(0.4))
                                .help(cited.contains(passage.index) ? "Cited in the answer" : "Sent but not cited")
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: 640, alignment: .leading)
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
                            Text(source.partLabel)
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
