import SwiftUI

struct LibrarySidebarView: View {
    @Bindable var appState = AppState.shared
    
    @State private var items: [FileItem] = []
    @State private var hasLoaded: Bool = false
    
    var filteredItems: [FileItem] {
        if appState.searchText.isEmpty {
            return items
        }
        return items.compactMap { $0.filtered(by: appState.searchText) }
    }
    
    var body: some View {
        List(selection: $appState.activeItem) {
            Section {
                NavigationLink(value: "Home") {
                    Label("Home", systemImage: "sparkles")
                }
                .buttonStyle(.plain)
            }
            
            Section("Library") {
                if items.isEmpty {
                    Text("No files found")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 24)
                } else {
                    OutlineGroup(filteredItems, children: \.children) { item in
                        SidebarFileRow(item: item)
                    }
                }
            }
            
            if !appState.selectedItems.isEmpty {
                Section("Recent Chats") {
                    ForEach(appState.selectedItems.reversed().prefix(8)) { item in
                        Button {
                            appState.activeItem = item
                        } label: {
                            HStack {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundColor(.secondary)
                                Text(item.name)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Dido")
        .searchable(text: $appState.searchText, placement: .sidebar, prompt: "Search files...")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear {
            loadRoot()
        }
        .onChange(of: appState.pkmRootPath) { _, _ in
            loadRoot()
        }
    }
    
    private func loadRoot() {
        guard !appState.pkmRootPath.isEmpty else {
            items = []
            hasLoaded = true
            return
        }
        
        hasLoaded = false
        
        let url: URL
        var isSecurityScoped = false
        if let scopedURL = appState.getSecurityScopedURL() {
            url = scopedURL
            isSecurityScoped = url.startAccessingSecurityScopedResource()
        } else {
            url = URL(fileURLWithPath: appState.pkmRootPath)
        }
        
        let rootItem = loadItem(url: url)
        items = rootItem.children ?? []
        hasLoaded = true
        
        if isSecurityScoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    private func loadItem(url: URL) -> FileItem {
        let name = url.lastPathComponent
        let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDir = resources?.isDirectory ?? false
        let size = Int64(resources?.fileSize ?? 0)
        let modDate = resources?.contentModificationDate
        
        var children: [FileItem]? = nil
        if isDir {
            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles) {
                children = contents.map { loadItem(url: $0) }.sorted(by: { a, b in
                    if a.isDirectory != b.isDirectory {
                        return a.isDirectory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                })
            }
        }
        
        return FileItem(url: url, name: name, isDirectory: isDir, fileSize: isDir ? nil : size, modificationDate: isDir ? nil : modDate, children: children)
    }
}

struct SidebarFileRow: View {
    @Bindable var appState = AppState.shared
    let item: FileItem
    
    var body: some View {
        Button {
            appState.selectFile(item.url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.iconName)
                    .foregroundColor(item.iconColor)
                    .frame(width: 18)
                Text(item.name)
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}
