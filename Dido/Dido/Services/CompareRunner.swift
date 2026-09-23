import Foundation
import os

/// Asks the same question of each file in a folder and writes a comparison table plus a summary of differences.
@MainActor
struct CompareRunner {
    static let maxFiles = 6

    let folder: SelectedItem
    let question: String
    let onProgress: @MainActor (String) -> Void

    private var logger: Logger { Logger(subsystem: "com.dido", category: "Compare") }

    func run() async throws -> String {
        let llm = LLMService.shared
        let provider = llm.makeAnswerProvider()
        let children = (try? await FileSystemScanner.shared.children(of: folder.url)) ?? []
        let files = children.filter { !$0.isDirectory && DocumentParser.supportedExtensions.contains($0.url.pathExtension.lowercased()) }
        guard !files.isEmpty else { return "There are no supported files directly inside \(folder.name) to compare." }
        let chosen = Array(files.prefix(Self.maxFiles))

        var rows: [(name: String, answer: String)] = []
        for (index, file) in chosen.enumerated() {
            try Task.checkCancellation()
            onProgress("Comparing \(index + 1) of \(chosen.count): \(file.name)…")
            let item = SelectedItem(url: file.url, name: file.name, kind: .file)
            let context = await ContextBuilder().build(for: item, question: question, budget: provider.contextBudget / 2, includeImages: false)
            var answer = ""
            for try await event in llm.streamAnswer(question: question + "\n\nAnswer in at most three sentences for this one document.", history: [], context: context) {
                if case .token(let token) = event { answer += token }
            }
            rows.append((file.name, answer.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        onProgress("Summarising the differences…")
        let table = "| File | Answer |\n| --- | --- |\n" + rows.map { "| \($0.name) | \(Self.cell($0.answer)) |" }.joined(separator: "\n")
        var differences = ""
        do {
            let prompt = "Question asked of each document: \(question)\n\nAnswers per document:\n" +
                rows.map { "- \($0.name): \($0.answer)" }.joined(separator: "\n") +
                "\n\nIn at most five bullet points, state where the documents agree and where they differ. Name the documents. Do not add an introduction or conclusion."
            differences = try await provider.complete(system: LLMService.shared.systemPrompt, prompt: prompt)
        } catch {
            logger.error("Difference summary failed: \(error.localizedDescription)")
            differences = "_The difference summary could not be generated: \(error.localizedDescription)_"
        }
        var note = ""
        if files.count > chosen.count {
            note = "\n\n_Only the first \(chosen.count) of \(files.count) files were compared._"
        }
        return "**Compared \(chosen.count) file\(chosen.count == 1 ? "" : "s") in \(folder.name)**\n\n\(table)\n\n**Differences**\n\n\(differences.trimmingCharacters(in: .whitespacesAndNewlines))\(note)"
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }
}
