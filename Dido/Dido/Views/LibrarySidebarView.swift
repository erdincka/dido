import SwiftUI

/// Home, recent chats, and one section per library (loaded folder by folder), with name and content search.
struct LibrarySidebarView: View {
    @Bindable var appState = AppState.shared
    private let chatStore = ChatStore.shared
    private let manager = LibraryManager.shared

    @State private var children: [UUID: [FileItem]] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var loading: Set<UUID> = []
    @State private var searchResults: [UUID: [FileItem]] = [:]
    @State private var passageResults: [IndexEntry] = []

    /// Collapsed state survives relaunches; every library stays open while a search is active.
    @AppStorage("sidebarRecentsExpanded") private var recentsExpanded = true
    /// Ids of the libraries the user collapsed, comma-separated.
    @AppStorage("sidebarCollapsedLibraries") private var collapsedLibraries = ""

    private var isSearching: Bool { !appState.searchText.isEmpty }

    var body: some View {
        List {
            Section {
                Button { appState.showHome() } label: {
                    Label("Home", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
            }

            if !chatStore.recentThreads.isEmpty && !isSearching {
                Section("Recent chats", isExpanded: $recentsExpanded) {
                    ForEach(chatStore.recentThreads.prefix(12), id: \.id) { thread in
                        RecentThreadRow(thread: thread)
                    }
                }
            }

            if manager.active.isEmpty {
                Section("Library") {
                    Button { appState.addLibrariesWithPanel() } label: {
                        Label("Add a library folder…", systemImage: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(manager.active) { library in
                Section(isExpanded: isSearching ? .constant(true) : expansionBinding(for: library.id)) {
                    libraryRows(library)
                } header: {
                    LibrarySectionHeader(library: library)
                }
            }

            if isSearching && !passageResults.isEmpty {
                Section("Passages") {
                    ForEach(passageResults, id: \.chunkID) { entry in
                        PassageResultRow(entry: entry, query: appState.searchText)
                    }
                }
            }
        }
        .navigationTitle("Dido")
        .searchable(text: $appState.searchText, isPresented: $appState.searchPresented, placement: .sidebar, prompt: "Search names and contents…")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task(id: manager.activationKey) { await loadRoots() }
        .task(id: appState.searchText) { await runSearch() }
    }

    @ViewBuilder
    private func libraryRows(_ library: LibraryRecord) -> some View {
        AskLibraryRow(library: library)
        if isSearching {
            let results = searchResults[library.id] ?? []
            if results.isEmpty {
                Text("No matching names").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(results) { item in
                    SidebarFileRow(item: item, subtitle: item.relativePath(to: library.url))
                }
            }
        } else if loading.contains(library.id) && children[library.id] == nil {
            ProgressView().controlSize(.small)
        } else if let error = errors[library.id] {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(error)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if (children[library.id] ?? []).isEmpty {
            Text("The folder is empty").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(children[library.id] ?? []) { item in
                SidebarNode(item: item)
            }
        }
    }

    private var collapsedIDs: Set<String> {
        Set(collapsedLibraries.split(separator: ",").map(String.init))
    }

    private func expansionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedIDs.contains(id.uuidString) },
            set: { expanded in
                var ids = collapsedIDs
                if expanded { ids.remove(id.uuidString) } else { ids.insert(id.uuidString) }
                collapsedLibraries = ids.sorted().joined(separator: ",")
            }
        )
    }

    private func loadRoots() async {
        let libraries = manager.active
        children = children.filter { entry in libraries.contains { $0.id == entry.key } }
        errors = [:]
        for library in libraries {
            guard let root = manager.root(of: library.id) else { continue }
            loading.insert(library.id)
            do {
                children[library.id] = try await FileSystemScanner.shared.children(of: root)
            } catch {
                children[library.id] = []
                errors[library.id] = error.localizedDescription
            }
            loading.remove(library.id)
        }
    }

    private func runSearch() async {
        let query = appState.searchText
        guard !query.isEmpty else {
            searchResults = [:]
            passageResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        var vector: [Float]?
        if query.count >= 8 {
            vector = try? await LLMService.shared.makeEmbeddingProvider().embed([query]).first
        }
        var names: [UUID: [FileItem]] = [:]
        var passages: [IndexEntry] = []
        for library in manager.active {
            guard let root = manager.root(of: library.id), let index = manager.index(for: library.id) else { continue }
            names[library.id] = await FileSystemScanner.shared.search(query, under: root)
            var found = await index.vectors.textSearch(query, limit: 12)
            if let vector {
                let semantic = await index.vectors.search(query: vector, scope: .all, limit: 6, minimumScore: 0.2, keywords: [])
                for hit in semantic where !found.contains(where: { $0.chunkID == hit.entry.chunkID }) {
                    found.append(hit.entry)
                }
            }
            passages += found
        }
        guard !Task.isCancelled else { return }
        searchResults = names
        passageResults = passages
    }
}

/// A folder that loads its children the first time it is expanded, or a file row.
struct SidebarNode: View {
    let item: FileItem

    @State private var isExpanded = false
    @State private var children: [FileItem]?

    var body: some View {
        if item.isDirectory {
            DisclosureGroup(isExpanded: $isExpanded) {
                if let children {
                    if children.isEmpty {
                        Text("Empty").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(children) { child in
                            SidebarNode(item: child)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } label: {
                SidebarFileRow(item: item)
            }
            .task(id: isExpanded) {
                if isExpanded, children == nil {
                    children = (try? await FileSystemScanner.shared.children(of: item.url)) ?? []
                }
            }
        } else {
            SidebarFileRow(item: item)
        }
    }
}

struct SidebarFileRow: View {
    let item: FileItem
    var subtitle: String? = nil

    private let appState = AppState.shared
    private var isActive: Bool { appState.activeItem?.url == item.url && !appState.showingDashboard }

    var body: some View {
        Button {
            appState.selectFile(item.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .foregroundStyle(item.iconColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(item.isDirectory ? "Index folder" : "Index file") {
                Task { await DocumentIndexer.shared.index(item.url) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

struct RecentThreadRow: View {
    let thread: ChatThread

    private let appState = AppState.shared
    private let chatStore = ChatStore.shared
    @State private var renaming = false
    @State private var newName = ""

    private var isActive: Bool { appState.activeItem?.id == thread.item?.id && !appState.showingDashboard }

    var body: some View {
        HStack {
            Button {
                if let item = thread.item { appState.open(item) }
            } label: {
                HStack {
                    Image(systemName: thread.isLibrary ? "books.vertical" : (thread.isDirectory ? "folder" : "bubble.left.and.bubble.right")).foregroundStyle(.secondary)
                    Text(thread.displayName).lineLimit(1)
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation { chatStore.delete(thread) }
            } label: {
                Image(systemName: "xmark.circle").foregroundStyle(.secondary).opacity(0.6)
            }
            .buttonStyle(.plain)
            .help("Delete this chat")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.15) : .clear))
        .contextMenu {
            Button(thread.isPinned ? "Unpin" : "Pin to top") { chatStore.setPinned(thread, !thread.isPinned) }
            Button("Rename…") {
                newName = thread.displayName
                renaming = true
            }
            Divider()
            Button("Delete chat") { withAnimation { chatStore.delete(thread) } }
        }
        .alert("Rename chat", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { chatStore.rename(thread, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave the name empty to use the file or folder name again.")
        }
    }
}

/// A content-search hit: file name plus a snippet around the match. Opens the file with the passage previewed.
struct PassageResultRow: View {
    let entry: IndexEntry
    let query: String

    private let appState = AppState.shared

    var body: some View {
        Button {
            appState.pendingCitation = Citation(index: 0, path: entry.path, filename: entry.filename, ordinal: entry.ordinal, start: entry.start, end: entry.end, score: 0)
            appState.selectFile(URL(fileURLWithPath: entry.path))
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.filename).lineLimit(1)
                Text(snippet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var snippet: String {
        let text = entry.text.replacingOccurrences(of: "\n", with: " ")
        guard let range = text.range(of: query, options: .caseInsensitive) else { return String(text.prefix(140)) }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}
