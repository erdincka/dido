import SwiftUI

/// The folders Dido indexes, each with its own index under the app's directory, and the removed ones whose
/// indexes are kept for when they are added again.
struct LibrariesSettingsTab: View {
    private let manager = LibraryManager.shared
    private let appState = AppState.shared
    private let progress = IndexProgress.shared

    @State private var counts: [UUID: Int] = [:]
    @State private var sizes: [UUID: Int64] = [:]
    @State private var rebuilding: LibraryRecord?
    @State private var deleting: LibraryRecord?

    var body: some View {
        Form {
            Section {
                if manager.active.isEmpty {
                    Text("No libraries yet. Add a folder to start indexing it.").foregroundStyle(.secondary)
                }
                ForEach(manager.active) { library in
                    activeRow(library)
                }
                Button("Add Library Folder…") { appState.addLibrariesWithPanel() }
            } header: {
                Text("Libraries")
            } footer: {
                Text("Each library is indexed on its own. Indexes live in ~/Library/Application Support/Dido/Libraries, never inside your folders. Removing a library keeps its index, so adding the folder again needs no full scan.")
            }

            if !manager.removed.isEmpty {
                Section {
                    ForEach(manager.removed) { library in
                        removedRow(library)
                    }
                } header: {
                    Text("Removed libraries")
                } footer: {
                    Text("Their indexes and chat history are kept until you delete them.")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: "\(manager.activationKey)|\(manager.removed.count)|\(progress.isIndexing)") { refreshStats() }
        .confirmationDialog("Re-index \(rebuilding?.name ?? "this library") from scratch?", isPresented: presented($rebuilding), presenting: rebuilding) { library in
            Button("Re-index", role: .destructive) {
                Task { await DocumentIndexer.shared.rebuild(library.id) }
            }
        } message: { library in
            Text("Every passage and embedding of \(library.name) is deleted, then the folder is scanned again. Chat history is kept.")
        }
        .confirmationDialog("Delete the index of \(deleting?.name ?? "this library")?", isPresented: presented($deleting), presenting: deleting) { library in
            Button("Delete Index", role: .destructive) { manager.deleteIndex(library.id) }
        } message: { library in
            Text("The extracted passages, embeddings and chat history of \(library.name) are deleted. Adding the folder again later starts from scratch.")
        }
    }

    private func activeRow(_ library: LibraryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name).fontWeight(.medium)
                Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(summary(for: library)).font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Index now") { Task { await DocumentIndexer.shared.index(root(of: library)) } }
                    .disabled(progress.isIndexing)
                Button("Re-index from scratch…") { rebuilding = library }
                    .disabled(progress.isIndexing)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root(of: library)]) }
                Divider()
                Button("Remove from Dido") { appState.removeLibrary(library.id) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func removedRow(_ library: LibraryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                Text(library.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(sizeLabel(for: library)).font(.caption).foregroundStyle(.secondary)
            Button("Add Again") { restore(library) }
            Button("Delete Index…", role: .destructive) { deleting = library }
        }
    }

    private func root(of library: LibraryRecord) -> URL {
        manager.root(of: library.id) ?? library.url
    }

    private func summary(for library: LibraryRecord) -> String {
        let count = counts[library.id] ?? 0
        return "\(count) file\(count == 1 ? "" : "s") · \(sizeLabel(for: library))"
    }

    private func sizeLabel(for library: LibraryRecord) -> String {
        ByteCountFormatter.string(fromByteCount: sizes[library.id] ?? 0, countStyle: .file)
    }

    private func restore(_ library: LibraryRecord) {
        do {
            try manager.restore(library.id)
            appState.showNotification("Added \(library.name) again with its kept index.", type: .success)
        } catch {
            appState.showNotification(error.localizedDescription, type: .error)
        }
    }

    private func refreshStats() {
        var counts: [UUID: Int] = [:]
        var sizes: [UUID: Int64] = [:]
        for library in manager.active {
            counts[library.id] = manager.index(for: library.id)?.store.indexedDocumentCount() ?? 0
        }
        for library in manager.libraries {
            sizes[library.id] = LibraryManager.indexSize(of: library.id)
        }
        self.counts = counts
        self.sizes = sizes
    }

    /// A Boolean binding for a dialog driven by an optional selection.
    private func presented<T>(_ selection: Binding<T?>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue != nil }, set: { if !$0 { selection.wrappedValue = nil } })
    }
}
