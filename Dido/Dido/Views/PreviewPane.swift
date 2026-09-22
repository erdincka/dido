import SwiftUI
import PDFKit
import Quartz
import MarkdownUI

/// The trailing inspector: a cited passage in context, or the document itself.
struct PreviewPane: View {
    let item: SelectedItem
    let citation: Citation?

    private enum Mode: Hashable { case passage, document }

    @State private var mode: Mode = .document
    @State private var passages: [Passage] = []

    private var target: URL { citation?.url ?? item.url }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("", selection: $mode) {
                    Text("Passage").tag(Mode.passage)
                    Text("Document").tag(Mode.document)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(citation == nil)
            }
            .padding(12)
            Divider()
            Group {
                if mode == .passage, let citation {
                    PassageView(passages: passages, highlighted: citation.ordinal)
                } else {
                    DocumentView(url: target, searchText: citation.flatMap { Self.searchSnippet(for: $0, in: passages) })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: citation) {
            mode = citation == nil ? .document : .passage
            passages = await DocumentIndexer.shared.passages(for: target)
        }
    }

    private static func searchSnippet(for citation: Citation, in passages: [Passage]) -> String? {
        guard let passage = passages.first(where: { $0.ordinal == citation.ordinal }) else { return nil }
        let words = passage.text.split(separator: " ").prefix(8).joined(separator: " ")
        return words.isEmpty ? nil : words
    }
}

/// The cited chunk, highlighted, between its neighbours.
struct PassageView: View {
    let passages: [Passage]
    let highlighted: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if passages.isEmpty {
                        Text("No extracted text is stored for this file.").foregroundStyle(.secondary).padding()
                    }
                    ForEach(passages, id: \.ordinal) { passage in
                        Text(passage.text)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(passage.ordinal == highlighted ? Color.yellow.opacity(0.25) : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(passage.ordinal == highlighted ? Color.orange.opacity(0.6) : Color.clear))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .id(passage.ordinal)
                    }
                }
                .padding(12)
            }
            .onChange(of: passages.count) { _, _ in proxy.scrollTo(highlighted, anchor: .center) }
            .onAppear { proxy.scrollTo(highlighted, anchor: .center) }
        }
    }
}

/// Renders the file itself: Markdown, plain text, images, PDF with a search highlight, or Quick Look.
struct DocumentView: View {
    let url: URL
    var searchText: String? = nil

    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        switch ext {
        case "md", "markdown":
            ScrollView {
                Markdown((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case _ where DocumentParser.plainTextExtensions.contains(ext):
            ScrollView {
                Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case "pdf":
            PDFKitView(url: url, searchText: searchText)
        case _ where DocumentParser.imageExtensions.contains(ext):
            if let image = NSImage(contentsOf: url) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
                }
            } else {
                Text("The image could not be opened.").foregroundStyle(.secondary)
            }
        default:
            QuickLookView(url: url)
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    var searchText: String?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        guard let document = view.document, let searchText, !searchText.isEmpty else { return }
        let matches = document.findString(searchText, withOptions: [.caseInsensitive])
        if let first = matches.first {
            view.setCurrentSelection(first, animate: true)
            view.go(to: first)
        }
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? URL) != url {
            view.previewItem = url as QLPreviewItem
        }
    }
}
