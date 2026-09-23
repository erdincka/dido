import Foundation
import PDFKit
import AppKit
import Vision
import os

enum ParseError: Error, LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case converterMissing
    case converterFailed(String)
    case converterTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Files of type .\(ext) are not supported."
        case .unreadable(let reason): return reason
        case .converterMissing: return "uvx was not found. Install uv (brew install uv) or set its path in Settings to index Office and EPUB files."
        case .converterFailed(let reason): return "markitdown failed: \(reason)"
        case .converterTimedOut: return "markitdown took too long and was stopped."
        }
    }
}

struct ParserOptions: Sendable {
    var ocrEnabled = true
    var ocrMaxPages = DocumentParser.maxOCRPages
    var converterPath: String? = nil
}

/// Extracts plain text (and, for vision models, page images) from files. Runs off the main actor.
actor DocumentParser {
    static let shared = DocumentParser()

    static let plainTextExtensions: Set<String> = ["md", "txt", "markdown", "csv", "json", "html", "xml", "swift", "py", "js", "ts", "css", "yaml", "yml"]
    static let converterExtensions: Set<String> = ["docx", "pptx", "xlsx", "epub"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "tif", "webp", "gif"]
    static let supportedExtensions: Set<String> = plainTextExtensions.union(converterExtensions).union(imageExtensions).union(["pdf", "rtf"])

    /// Pages of a scanned PDF that are OCRed before giving up; accurate recognition is slow.
    static let maxOCRPages = 40
    private static let converterTimeout: TimeInterval = 180

    private let logger = Logger(subsystem: "com.dido", category: "Parser")
    private var converterWarmed = false

    private init() {}

    /// Plain text for a file, or an empty string when the file has no text.
    func text(of url: URL, options: ParserOptions = ParserOptions()) async throws -> String {
        let ext = url.pathExtension.lowercased()
        logger.info("Parsing \(url.lastPathComponent)")
        switch ext {
        case "pdf":
            let text = try pdfText(url)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, options.ocrEnabled {
                logger.info("No text layer in \(url.lastPathComponent); running OCR")
                return try ocrPDF(url, maxPages: options.ocrMaxPages)
            }
            return text
        case "rtf":
            return try rtfText(url)
        case _ where Self.plainTextExtensions.contains(ext):
            return try plainText(url)
        case _ where Self.converterExtensions.contains(ext):
            return try await markitdown(url, options: options)
        case _ where Self.imageExtensions.contains(ext):
            guard options.ocrEnabled else { return "" }
            guard let image = NSImage(contentsOf: url), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw ParseError.unreadable("The image could not be opened.")
            }
            return try recognisedText(in: cgImage)
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

    // MARK: - OCR with Vision

    private func ocrPDF(_ url: URL, maxPages: Int) throws -> String {
        guard let document = PDFDocument(url: url) else { throw ParseError.unreadable("The PDF could not be opened.") }
        var text = ""
        for index in 0..<min(document.pageCount, max(maxPages, 1)) {
            if Task.isCancelled { break }
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = CGSize(width: bounds.width * 2, height: bounds.height * 2)
            let image = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            text += try recognisedText(in: cgImage)
            text += "\n\n"
        }
        return text
    }

    private func recognisedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw ParseError.unreadable("Text recognition failed: \(error.localizedDescription)")
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: - markitdown via uvx

    private func uvxURL(options: ParserOptions) -> URL? {
        var candidates: [String] = []
        if let configured = options.converterPath, !configured.isEmpty { candidates.append(configured) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates += ["/opt/homebrew/bin/uvx", "/usr/local/bin/uvx", "\(home)/.local/bin/uvx", "\(home)/.cargo/bin/uvx"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/uvx" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private func markitdown(_ url: URL, options: ParserOptions) async throws -> String {
        guard let uvx = uvxURL(options: options) else { throw ParseError.converterMissing }

        if !converterWarmed {
            await AppState.shared.showNotification("Preparing the document converter (first use may take a minute)…")
            _ = try? await run(uvx, arguments: ["--from", "markitdown[all]", "markitdown", "--version"], timeout: 600)
            converterWarmed = true
        }

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("dido-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let input = workDirectory.appendingPathComponent("input").appendingPathExtension(url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: input)
        } catch {
            throw ParseError.unreadable(error.localizedDescription)
        }
        let output = try await run(uvx, arguments: ["--from", "markitdown[all]", "markitdown", input.path], timeout: Self.converterTimeout)
        return output
    }

    /// Runs a command with stdout and stderr captured to files, terminating it after `timeout` seconds.
    private func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> String {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("dido-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let output = workDirectory.appendingPathComponent("stdout.txt")
        let errors = workDirectory.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)

        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ParseError.converterFailed(error.localizedDescription))
            }
        }
        let timedOut = deadline.isCancelled == false && process.terminationReason == .uncaughtSignal
        deadline.cancel()

        guard process.terminationStatus == 0 else {
            if timedOut { throw ParseError.converterTimedOut }
            let message = (try? String(contentsOf: errors, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").last.map(String.init) ?? "exit status \(process.terminationStatus)"
            logger.error("\(executable.lastPathComponent) failed: \(message)")
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
            let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
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
