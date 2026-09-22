import Foundation
import PDFKit
import AppKit
import os

enum ParseError: Error, LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case converterMissing
    case converterFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Files of type .\(ext) are not supported."
        case .unreadable(let reason): return reason
        case .converterMissing: return "uvx was not found. Install uv (brew install uv) to index Office and EPUB files."
        case .converterFailed(let reason): return "markitdown failed: \(reason)"
        }
    }
}

/// Extracts plain text (and, for vision models, page images) from files. Runs off the main actor.
actor DocumentParser {
    static let shared = DocumentParser()

    static let plainTextExtensions: Set<String> = ["md", "txt", "markdown", "csv", "json", "html", "xml", "swift", "py", "js", "ts", "css", "yaml", "yml"]
    static let converterExtensions: Set<String> = ["docx", "pptx", "xlsx", "epub"]
    static let supportedExtensions: Set<String> = plainTextExtensions.union(converterExtensions).union(["pdf", "rtf"])

    private let logger = Logger(subsystem: "com.dido", category: "Parser")

    private init() {}

    /// Plain text for a file, or an empty string when the file has no text layer.
    func text(of url: URL) async throws -> String {
        let ext = url.pathExtension.lowercased()
        logger.info("Parsing \(url.lastPathComponent)")
        switch ext {
        case "pdf":
            return try pdfText(url)
        case "rtf":
            return try rtfText(url)
        case _ where Self.plainTextExtensions.contains(ext):
            return try plainText(url)
        case _ where Self.converterExtensions.contains(ext):
            return try await markitdown(url)
        default:
            throw ParseError.unsupported(ext)
        }
    }

    // MARK: - Native formats

    private func plainText(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw ParseError.unreadable("The file is not valid text.")
    }

    private func pdfText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ParseError.unreadable("The PDF could not be opened.")
        }
        var text = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText
                text += "\n"
            }
        }
        return text
    }

    private func rtfText(_ url: URL) throws -> String {
        do {
            let attributed = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return attributed.string
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
    }

    // MARK: - markitdown via uvx

    private func uvxURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/uvx", "/usr/local/bin/uvx", "\(home)/.local/bin/uvx", "\(home)/.cargo/bin/uvx"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func markitdown(_ url: URL) async throws -> String {
        guard let uvx = uvxURL() else { throw ParseError.converterMissing }

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("dido-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let input = workDirectory.appendingPathComponent("input").appendingPathExtension(url.pathExtension)
        let output = workDirectory.appendingPathComponent("output.md")
        let errors = workDirectory.appendingPathComponent("stderr.txt")
        do {
            try FileManager.default.copyItem(at: url, to: input)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)

        let process = Process()
        process.executableURL = uvx
        process.arguments = ["--from", "markitdown[all]", "markitdown", input.path]
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ParseError.converterFailed(error.localizedDescription))
            }
        }

        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errors, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? "exit status \(process.terminationStatus)"
            logger.error("markitdown failed for \(url.lastPathComponent): \(message)")
            throw ParseError.converterFailed(message)
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    // MARK: - Images for vision models

    /// The first pages of a PDF rendered as base64 PNGs.
    func pageImagesBase64(of url: URL, maxPages: Int = 3) -> [String] {
        guard url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) else { return [] }
        var images: [String] = []
        for index in 0..<min(document.pageCount, maxPages) {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let image = NSImage(size: bounds.size, flipped: false) { _ in
                guard let context = NSGraphicsContext.current else { return false }
                context.imageInterpolation = .high
                page.draw(with: .mediaBox, to: context.cgContext)
                return true
            }
            if let png = Self.pngData(image) {
                images.append(png.base64EncodedString())
            }
        }
        return images
    }

    /// An image file as a base64 PNG.
    func imageBase64(of url: URL) -> String? {
        guard let image = NSImage(contentsOf: url), let png = Self.pngData(image) else { return nil }
        return png.base64EncodedString()
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
