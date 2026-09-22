import SwiftUI

/// One entry in the library sidebar. Children are loaded on demand by `FileSystemScanner`.
struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?

    var id: String { url.path }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "pdf": return "doc.richtext.fill"
        case "txt", "md", "markdown", "rtf", "csv": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo.fill"
        case "mp4", "mov", "avi": return "video.fill"
        case "mp3", "wav", "m4a": return "waveform"
        case "json", "xml", "yaml", "yml": return "curlybraces.square.fill"
        case "swift", "py", "js", "ts", "html", "css", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "xls", "xlsx": return "tablecells.fill"
        case "doc", "docx": return "doc.fill"
        case "ppt", "pptx": return "rectangle.on.rectangle.fill"
        default: return "doc.fill"
        }
    }

    var iconColor: Color {
        if isDirectory { return .blue }
        switch url.pathExtension.lowercased() {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return .purple
        case "mp4", "mov", "avi": return .orange
        case "json", "xml", "yaml", "yml": return .green
        case "zip", "tar", "gz", "rar": return .gray
        case "xls", "xlsx": return .green
        case "ppt", "pptx": return .orange
        case "swift", "py", "js", "ts", "html", "css", "c", "cpp": return .teal
        default: return .secondary
        }
    }

    /// Path shown under search results, relative to the library root.
    func relativePath(to root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let parent = url.deletingLastPathComponent().path
        guard parent.hasPrefix(rootPath) else { return parent }
        let relative = String(parent.dropFirst(rootPath.count))
        return relative.isEmpty ? "." : relative
    }
}
