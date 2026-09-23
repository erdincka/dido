import SwiftUI

/// Title bar above the transcript with Quick Look, Finder and file information.
struct ChatHeaderView: View {
    let item: SelectedItem
    @Binding var previewURL: URL?
    @Binding var showPreview: Bool
    @Binding var compareMode: Bool

    @State private var showInfo = false
    @State private var fileTypes: [String] = []
    @Bindable private var appState = AppState.shared

    private static let quickLookExtensions: Set<String> = ["pdf", "rtf", "md", "txt", "markdown", "csv", "json", "swift", "py", "js", "html", "css", "xml", "yaml", "jpg", "png", "jpeg", "docx", "pptx", "xlsx"]

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: item.isLibrary ? "books.vertical.fill" : (item.isDirectory ? "folder.fill" : fileIcon))
                .font(.title)
                .foregroundStyle(item.isDirectory ? .blue : .secondary)
                .frame(width: 44, height: 44)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 8) {
                if item.isDirectory {
                    filterMenu
                }
                if item.kind == .folder {
                    Button { compareMode.toggle() } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .foregroundStyle(compareMode ? Color.white : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .tint(compareMode ? Color.accentColor : nil)
                    .background(compareMode ? Color.accentColor.opacity(0.9) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .help(compareMode ? "Compare mode is on: each file is asked separately" : "Compare the files in this folder")
                }
                if !item.isDirectory {
                    Button { showPreview.toggle() } label: { Image(systemName: "sidebar.trailing") }
                        .buttonStyle(.bordered)
                        .help(showPreview ? "Hide preview" : "Show preview")
                }
                if Self.quickLookExtensions.contains(item.url.pathExtension.lowercased()) {
                    Button { previewURL = item.url } label: { Image(systemName: "eye") }
                        .buttonStyle(.bordered)
                        .help("Quick Look")
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.bordered)
                    .help("Show in Finder")
                if !item.isLibrary {
                    Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.bordered)
                        .help("File information")
                        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                            FileInfoPopover(item: item) { showInfo = false }
                        }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .task(id: item.id) {
            fileTypes = item.isDirectory ? await VectorIndex.shared.fileTypes(in: item.searchScope) : []
        }
    }

    private var subtitle: String {
        var text = item.isLibrary ? "Every indexed file" : (item.isDirectory ? "Folder context" : "Document context")
        if compareMode { text += " · compare mode" }
        if !appState.retrievalFilter.isEmpty { text += " · " + appState.retrievalFilter.summary }
        return text
    }

    /// Narrows retrieval by file type and modification date for folder and library chats.
    private var filterMenu: some View {
        Menu {
            Section("File types") {
                ForEach(fileTypes, id: \.self) { type in
                    Toggle("." + type, isOn: Binding(
                        get: { appState.retrievalFilter.fileTypes.contains(type) },
                        set: { on in
                            if on { appState.retrievalFilter.fileTypes.insert(type) } else { appState.retrievalFilter.fileTypes.remove(type) }
                        }
                    ))
                }
            }
            Section("Modified") {
                Picker("Modified", selection: $appState.retrievalFilter.modifiedWithinDays) {
                    Text("Any time").tag(Int?.none)
                    Text("Last 7 days").tag(Int?.some(7))
                    Text("Last 30 days").tag(Int?.some(30))
                    Text("Last year").tag(Int?.some(365))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Clear filter") { appState.retrievalFilter = RetrievalFilter() }
                .disabled(appState.retrievalFilter.isEmpty)
        } label: {
            Image(systemName: appState.retrievalFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 32)
        .help("Filter which files may be searched")
    }

    private var fileIcon: String {
        switch item.url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext.fill"
        case "txt", "md", "markdown": return "doc.text.fill"
        case "swift", "py", "js", "ts": return "terminal.fill"
        default: return "doc.fill"
        }
    }
}

/// Details and index status for the current item, with a way to index it again.
struct FileInfoPopover: View {
    let item: SelectedItem
    let onClose: () -> Void

    private let store = DataStore.shared
    private let progress = IndexProgress.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("File information", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Details").font(.subheadline.bold()).foregroundStyle(.secondary)
                    infoRow("Path", item.url.path)
                    if let values = try? item.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                        if let size = values.fileSize, !item.isDirectory {
                            infoRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        }
                        if let modified = values.contentModificationDate {
                            infoRow("Modified", modified.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Index").font(.subheadline.bold()).foregroundStyle(.secondary)
                    indexStatus
                    Button("Index now") {
                        Task { await DocumentIndexer.shared.index(item.url) }
                    }
                    .disabled(progress.isIndexing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .frame(width: 560)
        .onExitCommand(perform: onClose)
    }

    @ViewBuilder
    private var indexStatus: some View {
        if progress.isIndexing {
            HStack {
                ProgressView().controlSize(.small)
                Text("Indexing \(progress.completed) of \(progress.total)…").font(.caption)
            }
        }
        if item.isDirectory {
            Text("Folders are indexed file by file.").font(.caption).foregroundStyle(.secondary)
        } else if let document = store.document(for: item.url.path) {
            StatusTag(status: document.status)
            Text("\(document.chunks.count) chunks · \(document.dateIndexed.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let detail = document.detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        } else {
            StatusTag(status: nil)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct StatusTag: View {
    let status: IndexStatus?

    private var colour: Color {
        switch status {
        case .indexed: return .green
        case .none, .skippedUnsupported: return .secondary
        default: return .orange
        }
    }

    var body: some View {
        Text((status?.label ?? "Not indexed").uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colour.opacity(0.12))
            .foregroundStyle(colour)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(colour.opacity(0.3), lineWidth: 1))
    }
}
