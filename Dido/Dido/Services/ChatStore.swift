import Foundation
import SwiftData
import os

/// Chat history, one thread per file, folder or library, kept in the store of the library the item belongs to.
/// Keeps at most `maxMessagesPerThread` per thread.
@Observable @MainActor
final class ChatStore {
    static let shared = ChatStore()
    static let maxMessagesPerThread = 200

    /// Threads with at least one message from every active library, pinned first, then most recent.
    private(set) var recentThreads: [ChatThread] = []

    private let logger = Logger(subsystem: "com.dido", category: "ChatStore")

    private init() {
        migrateLegacyHistoryIfNeeded()
        reloadThreads()
    }

    private func context(for libraryID: UUID) -> ModelContext? {
        LibraryManager.shared.index(for: libraryID)?.store.context
    }

    func reloadThreads() {
        var threads: [ChatThread] = []
        for library in LibraryManager.shared.active {
            guard let context = context(for: library.id) else { continue }
            var descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            descriptor.fetchLimit = 50
            let fetched = (try? context.fetch(descriptor)) ?? []
            var changed = false
            for thread in fetched where thread.libraryID != library.id {
                thread.libraryID = library.id // threads from before 2.2 do not know their library
                changed = true
            }
            if changed { save(context) }
            threads += fetched.filter { !$0.messages.isEmpty }
        }
        recentThreads = threads.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return a.updatedAt > b.updatedAt
        }
    }

    func messages(for item: SelectedItem) -> [ChatMessage] {
        guard let (thread, _) = thread(for: item, createIfNeeded: false) else { return [] }
        return thread.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { record in
                let sources = record.sourcesJSON.flatMap { try? JSONDecoder().decode([Citation].self, from: Data($0.utf8)) } ?? []
                let details = record.detailsJSON.flatMap { try? JSONDecoder().decode(AnswerDetails.self, from: Data($0.utf8)) }
                let trace = record.traceJSON.flatMap { try? JSONDecoder().decode(AgentTrace.self, from: Data($0.utf8)) }
                return ChatMessage(id: record.id, role: ChatRole(rawValue: record.roleRaw) ?? .assistant, content: record.content, createdAt: record.createdAt, sources: sources, details: details, trace: trace)
            }
    }

    func append(_ message: ChatMessage, to item: SelectedItem) {
        guard let (thread, context) = thread(for: item, createIfNeeded: true) else { return }
        let record = ChatMessageRecord(id: message.id, role: message.role, content: message.content, createdAt: message.createdAt)
        if !message.sources.isEmpty, let data = try? JSONEncoder().encode(message.sources) {
            record.sourcesJSON = String(decoding: data, as: UTF8.self)
        }
        if let details = message.details, let data = try? JSONEncoder().encode(details) {
            record.detailsJSON = String(decoding: data, as: UTF8.self)
        }
        if let trace = message.trace, let data = try? JSONEncoder().encode(trace) {
            record.traceJSON = String(decoding: data, as: UTF8.self)
        }
        record.thread = thread
        context.insert(record)
        thread.updatedAt = Date()

        let ordered = thread.messages.sorted { $0.createdAt < $1.createdAt }
        if ordered.count > Self.maxMessagesPerThread {
            for old in ordered.prefix(ordered.count - Self.maxMessagesPerThread) {
                context.delete(old)
            }
        }
        save(context)
        reloadThreads()
    }

    func delete(messageID: UUID, in item: SelectedItem) {
        guard let (thread, context) = thread(for: item, createIfNeeded: false) else { return }
        for record in thread.messages where record.id == messageID {
            context.delete(record)
        }
        save(context)
        reloadThreads()
    }

    func delete(_ thread: ChatThread) {
        guard let context = thread.modelContext else { return }
        context.delete(thread)
        save(context)
        reloadThreads()
    }

    func setPinned(_ thread: ChatThread, _ pinned: Bool) {
        thread.isPinned = pinned
        thread.modelContext.map(save)
        reloadThreads()
    }

    func rename(_ thread: ChatThread, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        thread.customName = trimmed.isEmpty ? nil : trimmed
        thread.modelContext.map(save)
        reloadThreads()
    }

    /// Deletes a message and every later one in the same thread (used by edit-and-resend and regenerate).
    func deleteMessages(from messageID: UUID, in item: SelectedItem) {
        guard let (thread, context) = thread(for: item, createIfNeeded: false) else { return }
        let ordered = thread.messages.sorted { $0.createdAt < $1.createdAt }
        guard let start = ordered.firstIndex(where: { $0.id == messageID }) else { return }
        for record in ordered[start...] { context.delete(record) }
        save(context)
        reloadThreads()
    }

    /// The thread for an item in its library's store. A library has one thread, found even after its folder moved.
    private func thread(for item: SelectedItem, createIfNeeded: Bool) -> (thread: ChatThread, context: ModelContext)? {
        guard let context = context(for: item.libraryID) else { return nil }
        let path = item.url.path
        let descriptor = item.isLibrary
            ? FetchDescriptor<ChatThread>(predicate: #Predicate { $0.isLibrary == true })
            : FetchDescriptor<ChatThread>(predicate: #Predicate { $0.path == path && $0.isLibrary == false })
        if let existing = (try? context.fetch(descriptor))?.first {
            if existing.libraryID != item.libraryID { existing.libraryID = item.libraryID }
            if item.isLibrary, existing.path != path || existing.name != item.name {
                existing.path = path
                existing.name = item.name
            }
            return (existing, context)
        }
        guard createIfNeeded else { return nil }
        let thread = ChatThread(path: path, name: item.name, kind: item.kind)
        thread.libraryID = item.libraryID
        context.insert(thread)
        return (thread, context)
    }

    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - One-off migration from the UserDefaults history used before 1.2

    private struct LegacyMessage: Decodable { let id: UUID; let role: String; let content: String }
    private struct LegacyItem: Decodable { let url: URL; let name: String; let isDirectory: Bool; let messages: [LegacyMessage] }

    /// Moves the pre-1.2 history into the first library's store; waits for a library when there is none yet.
    private func migrateLegacyHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "selectedItems"),
              let library = LibraryManager.shared.active.first, let context = context(for: library.id) else { return }
        guard let items = try? JSONDecoder().decode([LegacyItem].self, from: data) else {
            logger.error("Legacy chat history could not be decoded; leaving it in place")
            return
        }
        defer { defaults.removeObject(forKey: "selectedItems") }

        var imported = 0
        for item in items where !item.messages.isEmpty {
            let thread = ChatThread(path: item.url.path, name: item.name, kind: item.isDirectory ? .folder : .file)
            thread.libraryID = library.id
            context.insert(thread)
            let base = Date().addingTimeInterval(-Double(item.messages.count))
            for (offset, message) in item.messages.suffix(Self.maxMessagesPerThread).enumerated() {
                let record = ChatMessageRecord(id: message.id, role: ChatRole(rawValue: message.role) ?? .assistant, content: message.content, createdAt: base.addingTimeInterval(Double(offset)))
                record.thread = thread
                context.insert(record)
                imported += 1
            }
        }
        save(context)
        logger.info("Migrated \(imported) legacy chat messages")
    }
}
