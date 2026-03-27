import Foundation
import PDFKit
import AppKit
import os

@Observable @MainActor
final class DocumentParserService {
    static let shared = DocumentParserService()
    
    private let logger = Logger(subsystem: "com.dido", category: "Parser")
    
    private init() {}
    
    func parseText(from fileURL: URL, type: String) async -> String? {
        logger.info("Parsing text from \(fileURL.lastPathComponent) (type: \(type))")
        switch type.lowercased() {
        case "pdf":
            return parsePDF(url: fileURL)
        case "rtf":
            return parseRTF(url: fileURL)
        case "md", "txt", "markdown", "csv", "json", "html", "xml", "swift", "py", "js", "css", "yaml":
            do {
                let data = try Data(contentsOf: fileURL)
                if let text = String(data: data, encoding: .utf8) {
                    return text
                } else if let text = String(data: data, encoding: .ascii) {
                    return text
                } else if let text = String(data: data, encoding: .isoLatin1) {
                    return text
                }
                return nil
            } catch {
                logger.error("Failed to read text file: \(error.localizedDescription)")
                return nil
            }
        case "docx", "pptx", "xlsx", "epub":
            return await parseWithMarkitDown(url: fileURL)
        default:
            return nil
        }
    }
    
    private func parsePDF(url: URL) -> String? {
        guard let pdfDocument = PDFDocument(url: url) else { 
            logger.error("Could not open PDF document at \(url.path)")
            return nil 
        }
        var fullText = ""
        for i in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }
        
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("PDF has no extractable text layer: \(url.lastPathComponent)")
            // Return a space or some marker to indicate it was "parsed" but empty, 
            // rather than nil which triggers an error in the indexer.
            return " " 
        }
        
        return fullText
    }
    
    private func parseRTF(url: URL) -> String? {
        do {
            let attributedString = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return attributedString.string
        } catch {
            print("Failed to parse RTF: \(error)")
            return nil
        }
    }
    
    private func parseWithMarkitDown(url: URL) async -> String? {
        let logger = self.logger
        return await Task.detached { () -> String? in
            let tempDir = FileManager.default.temporaryDirectory
            let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            
            let fileAccess = url.startAccessingSecurityScopedResource()
            defer { if fileAccess { url.stopAccessingSecurityScopedResource() } }
            
            do {
                try FileManager.default.copyItem(at: url, to: tempFileURL)
            } catch {
                logger.error("Failed to copy file to temp dir: \(error.localizedDescription)")
                return nil
            }
            
            defer {
                try? FileManager.default.removeItem(at: tempFileURL)
            }
            
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/uvx")
                process.arguments = ["--from", "markitdown[all]", "markitdown", tempFileURL.path]
                
                let pipe = Pipe()
                process.standardOutput = pipe
                let errPipe = Pipe()
                process.standardError = errPipe
                
                try process.run()
                process.waitUntilExit()
                
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                let errData = try errPipe.fileHandleForReading.readToEnd() ?? Data()
                
                if process.terminationStatus != 0 {
                    let errString = String(decoding: errData, as: UTF8.self)
                    logger.error("MarkItDown failed for \(url.lastPathComponent): \(errString)")
                    return nil
                }
                
                let output = String(decoding: data, as: UTF8.self)
                if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return " "
                }
                return output
            } catch {
                logger.error("Failed to execute markitdown: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
        /// Extracts images as base64 strings from a PDF for vision-capable models
    func extractImagesAsBase64(from url: URL) async -> [String]? {
        guard url.pathExtension.lowercased() == "pdf",
              let pdfDocument = PDFDocument(url: url) else { return nil }
        
        var images: [String] = []
        // Convert first few pages to base64 images as a simple heuristic for "visual context"
        for i in 0..<min(pdfDocument.pageCount, 3) {
            if let page = pdfDocument.page(at: i) {
                let pageRect = page.bounds(for: .mediaBox)
                
                let image = NSImage(size: pageRect.size, flipped: false) { rect in
                    // Safely unwrap the graphics context provided by the NSImage drawing block
                    guard let nsContext = NSGraphicsContext.current else { return false }
                    nsContext.imageInterpolation = .high
                    let cgContext = nsContext.cgContext
                    
                    // Draw the PDF page into the context
                    page.draw(with: .mediaBox, to: cgContext)
                    return true
                }
                
                if let tiff = image.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) {
                    images.append(png.base64EncodedString())
                }
            }
        }
        return images.isEmpty ? nil : images
    }
    
    /// Converts an image file (e.g., jpg, png) to a base64 string for vision-capable models
    func parseImage(url: URL) async -> String? {
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }
}
