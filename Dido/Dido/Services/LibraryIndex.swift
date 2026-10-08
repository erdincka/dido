import Foundation

/// The on-disk index of one library: its SwiftData store (documents, passages and chats), its vector matrix
/// and its full-text table, all in one folder under `~/Library/Application Support/Dido/Libraries/<id>/`.
final class LibraryIndex: Sendable {
    let id: UUID
    let name: String
    /// The library folder as resolved when the index was opened.
    let root: URL
    let directory: URL
    let store: DataStore
    /// Nil when the store could not be opened; `store.storeError` says why.
    let writer: IndexWriter?
    let vectors: VectorIndex
    let fullText: FullTextIndex

    private let rootPrefix: String

    @MainActor
    init(record: LibraryRecord, root: URL, directory: URL) {
        id = record.id
        name = record.name
        self.root = root
        self.directory = directory
        rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        store = DataStore(directory: directory)
        writer = store.container.map { IndexWriter(modelContainer: $0) }
        vectors = VectorIndex(fileURL: directory.appendingPathComponent("vectors.index"))
        fullText = FullTextIndex(fileURL: directory.appendingPathComponent("fulltext.sqlite"))
    }

    /// True when the path is the library folder or lies below it.
    func contains(_ path: String) -> Bool {
        path == root.path || path.hasPrefix(rootPrefix)
    }
}
