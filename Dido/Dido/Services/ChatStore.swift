import Foundation
import SwiftData
import os

/// Chat history in SwiftData, one thread per file or folder. Keeps at most `maxMessagesPerThread` per thread.
@Observable @MainActor
final class ChatStore {
    static let shared = ChatStore()
    static let maxMessagesPerThread = 200

    /// Threads that have at least one message, most recent first.
    private(set) var recentThreads: [ChatThread] = []

    private let logger = Logger(subsystem: "com.dido", category: "ChatStore")
    private var context: ModelContext? { DataStore.shared.context }

    private init() {
        migrateLegacyHistoryIfNeeded()
        reloadThreads()
    }

    func reloadThreads() {
        guard let context else { return }
        var descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 50
        let threads = (try? context.fetch(descriptor)) ?? []
        recentThreads = threads.filter { !$0.messages.isEmpty }
    }

    func messages(for item: SelectedItem) -> [ChatMessage] {
        guard let thread = thread(for: item, createIfNeeded: false) else { return [] }
        return thread.messages
            .sorted { $0.createdAt < $1.createdAt }
            .map { record in
                let sources = record.sourcesJSON.flatMap { try? JSONDecoder().decode([Citation].self, from: Data($0.utf8)) } ?? []
                let details = record.detailsJSON.flatMap { try? JSONDecoder().decode(AnswerDetails.self, from: Data($0.utf8)) }
                return ChatMessage(id: record.id, role: ChatRole(rawValue: record.roleRaw) ?? .assistant, content: record.content, createdAt: record.createdAt, sources: sources, details: details)
            }
    }

    func append(_ message: ChatMessage, to item: SelectedItem) {
        guard let context, let thread = thread(for: item, createIfNeeded: true) else { return }
        let record = ChatMessageRecord(id: message.id, role: message.role, content: message.content, createdAt: message.createdAt)
        if !message.sources.isEmpty, let data = try? JSONEncoder().encode(message.sources) {
            record.sourcesJSON = String(decoding: data, as: UTF8.self)
        }
        if let details = message.details, let data = try? JSONEncoder().encode(details) {
            record.detailsJSON = String(decoding: data, as: UTF8.self)
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
        save()
        reloadThreads()
    }

    func delete(messageID: UUID, in item: SelectedItem) {
        guard let context, let thread = thread(for: item, createIfNeeded: false) else { return }
        for record in thread.messages where record.id == messageID {
            context.delete(record)
        }
        save()
        reloadThreads()
    }

    func delete(_ thread: ChatThread) {
        guard let context else { return }
        context.delete(thread)
        save()
        reloadThreads()
    }

    private func thread(for item: SelectedItem, createIfNeeded: Bool) -> ChatThread? {
        guard let context else { return nil }
        let path = item.url.path
        let isLibrary = item.isLibrary
        let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.path == path && $0.isLibrary == isLibrary })
        if let existing = (try? context.fetch(descriptor))?.first { return existing }
        guard createIfNeeded else { return nil }
        let thread = ChatThread(path: path, name: item.name, kind: item.kind)
        context.insert(thread)
        return thread
    }

    private func save() {
        do {
            try context?.save()
        } catch {
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - One-off migration from the UserDefaults history used before 1.2

    private struct LegacyMessage: Decodable { let id: UUID; let role: String; let content: String }
    private struct LegacyItem: Decodable { let url: URL; let name: String; let isDirectory: Bool; let messages: [LegacyMessage] }

    private func migrateLegacyHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "selectedItems"), let context else { return }
        guard let items = try? JSONDecoder().decode([LegacyItem].self, from: data) else {
            logger.error("Legacy chat history could not be decoded; leaving it in place")
            return
        }
        defer { defaults.removeObject(forKey: "selectedItems") }

        var imported = 0
        for item in items where !item.messages.isEmpty {
            let thread = ChatThread(path: item.url.path, name: item.name, kind: item.isDirectory ? .folder : .file)
            context.insert(thread)
            let base = Date().addingTimeInterval(-Double(item.messages.count))
            for (offset, message) in item.messages.suffix(Self.maxMessagesPerThread).enumerated() {
                let record = ChatMessageRecord(id: message.id, role: ChatRole(rawValue: message.role) ?? .assistant, content: message.content, createdAt: base.addingTimeInterval(Double(offset)))
                record.thread = thread
                context.insert(record)
                imported += 1
            }
        }
        save()
        logger.info("Migrated \(imported) legacy chat messages")
    }
}
