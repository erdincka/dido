import Foundation
import os

/// Assembles the document text (and optional page images) sent with a question.
/// Until retrieval lands, this is the file's text or the first-level text files of a folder, capped in size.
struct ContextBuilder: Sendable {
    /// Upper bound on context characters so a big folder cannot overflow the model.
    var characterBudget = 80_000

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]
    private let logger = Logger(subsystem: "com.dido", category: "Context")

    func build(for item: SelectedItem, includeImages: Bool) async -> (context: String, images: [String]) {
        let indexer = DocumentIndexer.shared
        var parts: [String] = []
        var images: [String] = []
        var used = 0

        func append(_ text: String) -> Bool {
            guard used < characterBudget else { return false }
            let room = characterBudget - used
            if text.count <= room {
                parts.append(text)
                used += text.count
                return true
            }
            parts.append(String(text.prefix(room)) + "\n[context truncated]")
            used = characterBudget
            return false
        }

        if item.isDirectory {
            parts.append("[Folder: \(item.url.path)]")
            let children = (try? await FileSystemScanner.shared.children(of: item.url)) ?? []
            for child in children where !child.isDirectory && DocumentParser.plainTextExtensions.contains(child.url.pathExtension.lowercased()) {
                if await !indexer.isIndexed(path: child.url.path) {
                    await indexer.index(child.url, quiet: true)
                }
                let chunks = await indexer.textChunks(for: child.url)
                guard !chunks.isEmpty else { continue }
                if !append("--- \(child.name) ---\n" + chunks.joined(separator: "\n")) { break }
            }
        } else {
            parts.append("[File: \(item.name)]")
            let ext = item.url.pathExtension.lowercased()
            if DocumentParser.supportedExtensions.contains(ext) {
                if await !indexer.isIndexed(path: item.url.path) {
                    await indexer.index(item.url, quiet: true)
                }
                let chunks = await indexer.textChunks(for: item.url)
                _ = append(chunks.joined(separator: "\n"))
            }
            if includeImages {
                if ext == "pdf" {
                    images = await DocumentParser.shared.pageImagesBase64(of: item.url)
                } else if Self.imageExtensions.contains(ext), let image = await DocumentParser.shared.imageBase64(of: item.url) {
                    images = [image]
                }
            }
        }

        logger.info("Context for \(item.name): \(used) characters, \(images.count) images")
        return (parts.joined(separator: "\n"), images)
    }
}
