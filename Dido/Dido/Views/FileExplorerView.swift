import SwiftUI
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileItem]?
    
    func filtered(by searchText: String) -> FileItem? {
        if searchText.isEmpty { return self }
        
        let matchesName = name.localizedCaseInsensitiveContains(searchText)
        
        var filteredChildren: [FileItem]? = nil
        var hasMatchingDescendants = false
        
        if let children = children {
            let matches = children.compactMap { $0.filtered(by: searchText) }
            if !matches.isEmpty {
                filteredChildren = matches
                hasMatchingDescendants = true
            }
        }
        
        if matchesName {
            // If the folder name matches, keep all its original children, unless some children also explicitly matched.
            return FileItem(url: url, name: name, isDirectory: isDirectory, children: hasMatchingDescendants ? filteredChildren : children)
        } else if hasMatchingDescendants {
            // If folder didn't match but children did, only show matching children.
            return FileItem(url: url, name: name, isDirectory: isDirectory, children: filteredChildren)
        }
        
        return nil
    }
}

struct FileExplorerView: View {
    @Bindable var vectorDB = VectorDatabaseService.shared
    @Bindable var parser = DocumentParserService.shared
    @Bindable var chunker = DocumentChunkingService.shared
    
    @ObservationIgnored private var appState = AppState.shared
    
    @State private var items: [FileItem] = []
    @State private var hasLoaded: Bool = false
    @State private var searchText: String = ""
    
    var filteredItems: [FileItem] {
        if searchText.isEmpty {
            return items
        }
        return items.compactMap { $0.filtered(by: searchText) }
    }
    
    var body: some View {
        VStack {
            if appState.pkmRootPath.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("Please set the PKM Root in Settings to view your files.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    
                    Button("Open Settings") {
                        appState.showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasLoaded {
                 VStack(spacing: 20) {
                    ProgressView()
                    Text("Loading files...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                 VStack(spacing: 20) {
                    Image(systemName: "folder")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No files found or access denied.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    OutlineGroup(filteredItems, children: \.children) { item in
                        Button(action: {
                            appState.addSelectedItem(url: item.url)
                        }) {
                            HStack {
                                Image(systemName: item.isDirectory ? "folder" : "doc")
                                    .foregroundColor(item.isDirectory ? .accentColor : .secondary)
                                Text(item.name)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .searchable(text: $searchText, prompt: "Search files and folders...")
            }
        }
        .padding(.bottom, 28)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    loadRoot()
                } label: {
                    Label("Refresh", systemImage: "arrow.trianglehead.counterclockwise")
                }
                .help("Refresh Library")
            }
        }
        .frame(minWidth: 400, minHeight: 400)
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
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        
        var children: [FileItem]? = nil
        if isDir {
            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
                children = contents.map { loadItem(url: $0) }.sorted(by: { a, b in
                    if a.isDirectory != b.isDirectory {
                        return a.isDirectory
                    }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                })
            }
        }
        
        return FileItem(url: url, name: name, isDirectory: isDir, children: children)
    }
}
