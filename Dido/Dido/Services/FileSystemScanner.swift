import Foundation

enum ScanError: Error, LocalizedError {
    case noPermission(URL)
    case missing(URL)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noPermission(let url):
            return "Dido is not allowed to read \(url.lastPathComponent). Allow it under System Settings › Privacy & Security › Files and Folders, or choose another folder in Settings."
        case .missing(let url):
            return "\(url.lastPathComponent) no longer exists. Choose the library folder again in Settings."
        case .other(let reason):
            return reason
        }
    }
}

/// Lists folders and searches file names without touching the main actor.
actor FileSystemScanner {
    static let shared = FileSystemScanner()

    private let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]

    /// Immediate children of a folder: folders first, then files, both in Finder order.
    /// Throws a `ScanError` with a message the user can act on when the folder cannot be read.
    func children(of directory: URL) throws -> [FileItem] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return contents.map(item(for:)).sorted(by: Self.finderOrder)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw ScanError.noPermission(directory)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw ScanError.missing(directory)
        } catch {
            throw ScanError.other(error.localizedDescription)
        }
    }

    /// Files and folders below `root` whose name contains `query`, up to `limit` hits.
    func search(_ query: String, under root: URL, limit: Int = 200) -> [FileItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var hits: [FileItem] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled || hits.count >= limit { break }
            if url.lastPathComponent.localizedCaseInsensitiveContains(trimmed) {
                hits.append(item(for: url))
            }
        }
        return hits.sorted(by: Self.finderOrder)
    }

    /// Every regular file below `url`, or `url` itself when it is a file.
    func regularFiles(under url: URL) -> [URL] {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { return [url] }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var files: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir { files.append(fileURL) }
        }
        return files
    }

    private func item(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        return FileItem(
            url: url,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            fileSize: isDirectory ? nil : values?.fileSize.map(Int64.init),
            modificationDate: values?.contentModificationDate
        )
    }

    private static func finderOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
