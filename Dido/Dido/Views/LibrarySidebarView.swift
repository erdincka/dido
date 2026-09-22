import SwiftUI

/// Home, the library tree (loaded folder by folder), name search and recent chats.
struct LibrarySidebarView: View {
    @Bindable var appState = AppState.shared
    private let chatStore = ChatStore.shared

    @State private var rootChildren: [FileItem] = []
    @State private var searchResults: [FileItem] = []
    @State private var isLoadingRoot = false
    @State private var rootError: String?

    var body: some View {
        List {
            Section {
                Button { appState.showHome() } label: {
                    Label("Home", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
            }

            Section("Library") {
                libraryRows
            }

            if !chatStore.recentThreads.isEmpty {
                Section("Recent chats") {
                    ForEach(chatStore.recentThreads.prefix(12), id: \.id) { thread in
                        RecentThreadRow(thread: thread)
                    }
                }
            }
        }
        .navigationTitle("Dido")
        .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search file names…")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { appState.showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .task(id: appState.pkmRootBookmark ?? Data(appState.pkmRootPath.utf8)) { await loadRoot() }
        .task(id: appState.searchText) { await runSearch() }
    }

    @ViewBuilder
    private var libraryRows: some View {
        if let root = appState.rootURL {
            if !appState.searchText.isEmpty {
                if searchResults.isEmpty {
                    Text("No matching names").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(searchResults) { item in
                        SidebarFileRow(item: item, subtitle: item.relativePath(to: root))
                    }
                }
            } else if isLoadingRoot && rootChildren.isEmpty {
                ProgressView().controlSize(.small)
            } else if let rootError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(rootError)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if rootChildren.isEmpty {
                Text("The library folder is empty").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(rootChildren) { item in
                    SidebarNode(item: item)
                }
            }
        } else {
            Text("Choose a library folder in Settings").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadRoot() async {
        guard let root = appState.activateRoot() else {
            rootChildren = []
            return
        }
        isLoadingRoot = true
        do {
            rootChildren = try await FileSystemScanner.shared.children(of: root)
            rootError = nil
        } catch {
            rootChildren = []
            rootError = error.localizedDescription
        }
        isLoadingRoot = false
    }

    private func runSearch() async {
        let query = appState.searchText
        guard !query.isEmpty, let root = appState.rootURL else {
            searchResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        searchResults = await FileSystemScanner.shared.search(query, under: root)
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
    private var isActive: Bool { appState.activeItem?.url == item.url && !appState.showingSettings }

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

    var body: some View {
        HStack {
            Button {
                appState.activeItem = SelectedItem(url: URL(fileURLWithPath: thread.path), name: thread.name, isDirectory: thread.isDirectory)
                appState.showingSettings = false
            } label: {
                HStack {
                    Image(systemName: thread.isDirectory ? "folder" : "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                    Text(thread.name).lineLimit(1)
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
        .contextMenu {
            Button("Delete chat") { withAnimation { chatStore.delete(thread) } }
        }
    }
}
