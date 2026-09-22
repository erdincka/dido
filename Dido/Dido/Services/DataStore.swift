import Foundation
import SwiftData
import os

/// Owns the SwiftData container for the index and the chat history.
/// The store lives in `~/Library/Application Support/Dido/index.store`, never in the shared default path.
@Observable @MainActor
final class DataStore {
    static let shared = DataStore()

    let container: ModelContainer?
    let storeURL: URL
    /// Set when the container could not be opened. Shown as a banner in the main window.
    let storeError: String?

    private let logger = Logger(subsystem: "com.dido", category: "DataStore")

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let folder = support.appendingPathComponent("Dido", isDirectory: true)
        let url = folder.appendingPathComponent("index.store")
        storeURL = url

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let schema = Schema([Document.self, DocumentChunk.self, ChatThread.self, ChatMessageRecord.self])
            let configuration = ModelConfiguration("Dido", schema: schema, url: url)
            container = try ModelContainer(for: schema, configurations: [configuration])
            storeError = nil
        } catch {
            container = nil
            storeError = "The Dido database at \(url.path) could not be opened: \(error.localizedDescription). Move or delete that file and relaunch."
        }
        if let storeError {
            logger.error("\(storeError)")
        }
    }

    var context: ModelContext? { container?.mainContext }

    // MARK: - Reads used by the UI

    func document(for path: String) -> Document? {
        guard let context else { return nil }
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.path == path })
        return (try? context.fetch(descriptor))?.first
    }

    func indexedDocumentCount() -> Int {
        guard let context else { return 0 }
        let descriptor = FetchDescriptor<Document>(predicate: #Predicate { $0.isIndexed })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Size of the store and its write-ahead log on disk.
    func storeSizeOnDisk() -> Int64 {
        let candidates = [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
        return candidates.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
