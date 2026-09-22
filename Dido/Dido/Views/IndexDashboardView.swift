import SwiftUI
import SwiftData

/// Every file the indexer has seen, with its status and reason, plus maintenance actions.
struct IndexDashboardView: View {
    private let store = DataStore.shared
    private let appState = AppState.shared
    private let progress = IndexProgress.shared

    @State private var documents: [DocumentSummary] = []
    @State private var filter: IndexStatus?
    @State private var confirmClear = false
    @State private var isWorking = false

    struct DocumentSummary: Identifiable, Hashable {
        let id: UUID
        let filename: String
        let path: String
        let status: IndexStatus
        let detail: String?
        let chunks: Int
        let embedded: Bool
        let dateIndexed: Date
    }

    private var counts: [(IndexStatus, Int)] {
        let grouped = Dictionary(grouping: documents, by: \.status).mapValues(\.count)
        return [IndexStatus.indexed, .parseFailed, .empty, .skippedUnsupported, .cancelled].compactMap { status in
            grouped[status].map { (status, $0) }
        }
    }

    private var shown: [DocumentSummary] {
        let filtered = filter.map { status in documents.filter { $0.status == status } } ?? documents
        return filtered.sorted { $0.dateIndexed > $1.dateIndexed }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Table(shown) {
                TableColumn("File") { document in
                    Text(document.filename).help(document.path)
                }
                TableColumn("Status") { document in
                    StatusTag(status: document.status)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Detail") { document in
                    Text(document.detail ?? (document.status == .indexed ? "\(document.chunks) passages\(document.embedded ? "" : ", no embeddings")" : ""))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(document.detail ?? "")
                }
                TableColumn("Indexed") { document in
                    Text(document.dateIndexed.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                }
                .width(min: 130, ideal: 150)
            }
            .contextMenu(forSelectionType: DocumentSummary.ID.self) { ids in
                if let id = ids.first, let document = documents.first(where: { $0.id == id }) {
                    Button("Ask about this file") { appState.selectFile(URL(fileURLWithPath: document.path)) }
                    Button("Index again") { Task { await DocumentIndexer.shared.index(URL(fileURLWithPath: document.path)); reload() } }
                    Button("Remove from index") { Task { await DocumentIndexer.shared.remove(path: document.path); reload() } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)]) }
                }
            }
        }
        .navigationTitle("Index dashboard")
        .task { reload() }
        .onChange(of: progress.isIndexing) { _, _ in reload() }
        .confirmationDialog("Clear the whole index?", isPresented: $confirmClear) {
            Button("Clear index", role: .destructive) {
                Task { await DocumentIndexer.shared.removeAll(); reload() }
            }
        } message: {
            Text("Every extracted passage and embedding is deleted. Chat history is kept. Files are indexed again on demand or by the background scan.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FilterChip(label: "All", count: documents.count, selected: filter == nil) { filter = nil }
                ForEach(counts, id: \.0) { status, count in
                    FilterChip(label: status.label, count: count, selected: filter == status) { filter = status }
                }
                Spacer()
                if progress.isIndexing {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))).frame(width: 120)
                    Text("\(progress.completed)/\(progress.total)").font(.caption).monospacedDigit()
                    Button("Cancel") { Task { await DocumentIndexer.shared.cancel() } }
                }
            }
            HStack(spacing: 8) {
                Button("Index the library now") {
                    guard let root = appState.rootURL else { return }
                    Task { await DocumentIndexer.shared.index(root); reload() }
                }
                .disabled(appState.rootURL == nil || progress.isIndexing)
                Button("Remove missing files") {
                    isWorking = true
                    Task {
                        let removed = await DocumentIndexer.shared.removeMissing()
                        appState.showNotification("Removed \(removed) missing file\(removed == 1 ? "" : "s") from the index.", type: .success)
                        reload()
                        isWorking = false
                    }
                }
                .disabled(isWorking)
                Button("Clear index…", role: .destructive) { confirmClear = true }
                Spacer()
                Button("Refresh") { reload() }
            }
        }
        .padding(12)
    }

    private func reload() {
        guard let context = store.context else { return }
        let fetched = (try? context.fetch(FetchDescriptor<Document>())) ?? []
        documents = fetched.map {
            DocumentSummary(id: $0.id, filename: $0.filename, path: $0.path, status: $0.status, detail: $0.detail,
                            chunks: $0.chunks.count, embedded: $0.embeddingModel != nil, dateIndexed: $0.dateIndexed)
        }
    }
}

struct FilterChip: View {
    let label: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
