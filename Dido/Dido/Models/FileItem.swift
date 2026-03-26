import SwiftUI

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    var children: [FileItem]?
    
    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext.fill"
        case "txt", "md", "markdown", "rtf", "csv": return "doc.text.fill"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo.fill"
        case "mp4", "mov", "avi": return "video.fill"
        case "mp3", "wav", "m4a": return "waveform"
        case "json", "xml", "yaml", "yml": return "curlybraces.square.fill"
        case "swift", "py", "js", "ts", "html", "css", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "xls", "xlsx": return "tablecells.fill"
        default: return "doc.fill"
        }
    }
    
    var iconColor: Color {
        if isDirectory { return .blue }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return .purple
        case "mp4", "mov", "avi": return .orange
        case "json", "xml", "yaml", "yml": return .green
        case "zip", "tar", "gz", "rar": return .gray
        case "xls", "xlsx": return .green
        case "swift", "py", "js", "ts", "html", "css", "c", "cpp": return .teal
        default: return .secondary
        }
    }
    
    func filtered(by searchText: String) -> FileItem? {
        if searchText.isEmpty { return self }
        
        let matchesName = name.localizedCaseInsensitiveContains(searchText)
        
        var filteredChildren: [FileItem]? = nil
        var hasMatchingDescendants = false
        
        if let children = children {
            let matches = children.compactMap { $0.filtered(by: searchText) }
            if !matches.isEmpty {
                filteredChildren = matches
                hasMatchingDescendants = true
            }
        }
        
        if matchesName {
            // If the folder name matches, keep all its original children, unless some children also explicitly matched.
            return FileItem(url: url, name: name, isDirectory: isDirectory, fileSize: fileSize, modificationDate: modificationDate, children: hasMatchingDescendants ? filteredChildren : children)
        } else if hasMatchingDescendants {
            // If folder didn't match but children did, only show matching children.
            return FileItem(url: url, name: name, isDirectory: isDirectory, fileSize: fileSize, modificationDate: modificationDate, children: filteredChildren)
        }
        
        return nil
    }
}
