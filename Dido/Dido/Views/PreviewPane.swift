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
    @State private var lastLoadedPath: String?

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
                    DocumentView(url: target, passage: citation.flatMap { c in passages.first { $0.ordinal == c.ordinal } })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: citation) {
            mode = citation == nil || AppState.shared.debugPreviewMode == "document" ? .document : .passage
            if passages.isEmpty || target.path != lastLoadedPath {
                passages = await DocumentIndexer.shared.passages(for: target)
                lastLoadedPath = target.path
            }
        }
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
            .onChange(of: passages.count) { _, _ in scroll(proxy) }
            .onChange(of: highlighted) { _, _ in scroll(proxy) }
            .onAppear { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(highlighted, anchor: .center) }
        }
    }
}

/// Renders the file itself: Markdown, plain text with the cited range highlighted, images, PDF with the
/// cited range selected, or Quick Look.
struct DocumentView: View {
    let url: URL
    /// The cited chunk; its offsets are exact for text files and PDFs with a text layer.
    var passage: Passage? = nil

    private var ext: String { url.pathExtension.lowercased() }

    var body: some View {
        switch ext {
        case _ where (ext == "md" || ext == "markdown") && passage == nil:
            ScrollView {
                Markdown((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
                    .padding(16)
            }
        case _ where DocumentParser.plainTextExtensions.contains(ext):
            HighlightedTextView(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "", passage: passage, monospaced: !["md", "markdown", "txt"].contains(ext))
        case "pdf":
            PDFKitView(url: url, passage: passage)
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

/// The file's text with the cited range highlighted and scrolled into view.
struct HighlightedTextView: View {
    let text: String
    let passage: Passage?
    var monospaced = false

    private var font: Font { monospaced ? .system(.body, design: .monospaced) : .body }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let passage, let (before, cited, after) = Self.split(text, passage: passage) {
                        Text(before).font(font)
                        Text(cited)
                            .font(font)
                            .padding(6)
                            .background(Color.yellow.opacity(0.3))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.6)))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .id("cited")
                        Text(after).font(font)
                    } else {
                        Text(text).font(font)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .onAppear { proxy.scrollTo("cited", anchor: .center) }
            .onChange(of: passage) { _, _ in
                DispatchQueue.main.async { withAnimation { proxy.scrollTo("cited", anchor: .center) } }
            }
        }
    }

    /// Splits on the passage's UTF-16 offsets; falls back to locating the passage text when offsets are stale.
    private static func split(_ text: String, passage: Passage) -> (String, String, String)? {
        let utf16 = text.utf16
        if passage.end > passage.start, passage.end <= utf16.count,
           let start = String.Index(utf16Offset: passage.start, in: text).samePosition(in: text),
           let end = String.Index(utf16Offset: passage.end, in: text).samePosition(in: text),
           text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(String(passage.text.prefix(20))) {
            return (String(text[..<start]), String(text[start..<end]), String(text[end...]))
        }
        if let range = text.range(of: passage.text) ?? text.range(of: String(passage.text.prefix(80))) {
            return (String(text[..<range.lowerBound]), String(text[range]), String(text[range.upperBound...]))
        }
        return nil
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL
    var passage: Passage?

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
        guard let document = view.document, let passage else { return }
        if let selection = Self.selection(for: passage, in: document) {
            view.setCurrentSelection(selection, animate: true)
            view.go(to: selection)
        }
    }

    /// Maps the passage's offsets in the extracted text (pages joined by newlines) back onto page selections.
    private static func selection(for passage: Passage, in document: PDFDocument) -> PDFSelection? {
        var pageStart = 0
        var combined: PDFSelection?
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let length = (page.string ?? "").utf16.count
            let pageEnd = pageStart + length
            if passage.start < pageEnd && passage.end > pageStart {
                let local = NSRange(location: max(passage.start, pageStart) - pageStart, length: min(passage.end, pageEnd) - max(passage.start, pageStart))
                if local.length > 0, let selection = page.selection(for: local) {
                    if let existing = combined { existing.add(selection) } else { combined = selection }
                }
            }
            pageStart = pageEnd + 1 // the newline the parser inserts between pages
            if pageStart > passage.end { break }
        }
        if combined == nil {
            let words = passage.text.split(separator: " ").prefix(8).joined(separator: " ")
            combined = document.findString(words, withOptions: [.caseInsensitive]).first
        }
        return combined
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
