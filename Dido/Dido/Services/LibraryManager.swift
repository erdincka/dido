import Foundation
import os

enum LibraryError: Error, LocalizedError {
    case alreadyAdded(String)
    case insideLibrary(folder: String, library: String)
    case containsLibrary(folder: String, library: String)
    case missing(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .alreadyAdded(let name):
            return "\(name) is already one of your libraries."
        case .insideLibrary(let folder, let library):
            return "\(folder) is inside the library \(library), so it is already covered."
        case .containsLibrary(let folder, let library):
            return "\(folder) contains the library \(library). Remove that library first, or choose a folder that does not overlap."
        case .missing(let path):
            return "The folder \(path) no longer exists. Move it back, or delete its index."
        case .unknown:
            return "That library is not known."
        }
    }
}

/// The libraries the user added, their kept indexes, and the open index of each active one.
/// The registry is `libraries.json` beside the `Libraries` folder in the app's directory; nothing is written
/// inside a library folder. Removing a library keeps its folder of index files until the user deletes it.
@Observable @MainActor
final class LibraryManager {
    static let shared = LibraryManager()

    private(set) var libraries: [LibraryRecord] = []
    private var indexes: [UUID: LibraryIndex] = [:]
    private var accessedRoots: [UUID: URL] = [:]
    /// False until the initialiser has finished, so launch-time additions do not reach the other singletons.
    private var ready = false
    private let logger = Logger(subsystem: "com.dido", category: "Libraries")

    private struct Registry: Codable {
        var version: Int
        var libraries: [LibraryRecord]
    }

    static var registryURL: URL { DataStore.storeDirectory.appendingPathComponent("libraries.json") }

    /// The folder holding a library's store, vector index and full-text index.
    nonisolated static func directory(for id: UUID) -> URL {
        DataStore.librariesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private init() {
        migrateSingleLibraryIfNeeded()
        load()
        addLibrariesFromLaunchArguments()
        ready = true
    }

    // MARK: - Lookup

    var active: [LibraryRecord] { libraries.filter(\.isActive) }
    var removed: [LibraryRecord] { libraries.filter { !$0.isActive } }

    /// Changes whenever the set of active libraries or their folders change; views reload on it.
    var activationKey: String { active.map { "\($0.id.uuidString):\($0.path)" }.joined(separator: "|") }

    func library(id: UUID) -> LibraryRecord? { libraries.first { $0.id == id } }

    /// The active library whose folder contains `path`.
    func library(containing path: String) -> LibraryRecord? {
        let canonical = Self.canonicalPath(URL(fileURLWithPath: path))
        return active.first { Self.folder($0.path, contains: canonical) }
    }

    func index(containing path: String) -> LibraryIndex? {
        library(containing: path).flatMap { index(for: $0.id) }
    }

    /// The open index of an active library, opened on first use and reopened when its folder moved.
    func index(for id: UUID) -> LibraryIndex? {
        guard let record = library(id: id), record.isActive, let root = resolvedRoot(of: record) else { return nil }
        if let open = indexes[id], open.root == root { return open }
        let index = LibraryIndex(record: record, root: root, directory: Self.directory(for: id))
        indexes[id] = index
        return index
    }

    /// Every index opened so far for an active library.
    var openIndexes: [LibraryIndex] { active.compactMap { indexes[$0.id] } }

    /// The library folder's current location.
    func root(of id: UUID) -> URL? {
        library(id: id).flatMap(resolvedRoot(of:))
    }

    var activeRoots: [URL] { active.compactMap { root(of: $0.id) } }

    // MARK: - Changes

    /// Adds a folder as a library. A folder removed earlier comes back with its kept index.
    @discardableResult
    func add(_ url: URL) throws -> LibraryRecord {
        let root = url.resolvingSymlinksInPath()
        let path = root.path
        try checkOverlap(of: path, name: root.lastPathComponent, ignoring: nil)
        if let kept = removed.first(where: { $0.path == path || resolvedRoot(of: $0)?.path == path }) {
            try restore(kept.id)
            return library(id: kept.id) ?? kept
        }
        let bookmark = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let record = LibraryRecord(id: UUID(), name: root.lastPathComponent, path: path, bookmark: bookmark, addedAt: Date(), removedAt: nil)
        try? FileManager.default.createDirectory(at: Self.directory(for: record.id), withIntermediateDirectories: true)
        libraries.append(record)
        save()
        logger.notice("Added library \(record.name) at \(path)")
        libraryChanged()
        return record
    }

    /// Takes the library out of the sidebar and stops watching it. Its index stays on disk.
    func remove(_ id: UUID) {
        guard let position = libraries.firstIndex(where: { $0.id == id }), libraries[position].isActive else { return }
        libraries[position].removedAt = Date()
        save()
        indexes[id] = nil
        accessedRoots[id]?.stopAccessingSecurityScopedResource()
        accessedRoots[id] = nil
        Task { await DocumentIndexer.shared.libraryRemoved(id) }
        let appState = AppState.shared
        if appState.activeItem?.libraryID == id { appState.showHome() }
        if appState.currentLibraryID == id { appState.currentLibraryID = active.first?.id }
        logger.notice("Removed library \(self.libraries[position].name); its index is kept")
        libraryChanged()
    }

    /// Adds a removed library back, with its kept index.
    func restore(_ id: UUID) throws {
        guard let position = libraries.firstIndex(where: { $0.id == id }) else { throw LibraryError.unknown }
        let record = libraries[position]
        guard let root = resolvedRoot(of: record), FileManager.default.fileExists(atPath: root.path) else {
            throw LibraryError.missing(record.path)
        }
        let path = root.path
        try checkOverlap(of: path, name: root.lastPathComponent, ignoring: id)
        libraries[position].removedAt = nil
        libraries[position].path = path
        libraries[position].name = root.lastPathComponent
        libraries[position].bookmark = try? root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        save()
        logger.notice("Added library \(root.lastPathComponent) again with its kept index")
        libraryChanged()
    }

    /// Deletes the kept index of a removed library and forgets the library.
    func deleteIndex(_ id: UUID) {
        guard let position = libraries.firstIndex(where: { $0.id == id }), !libraries[position].isActive else { return }
        indexes[id] = nil
        do {
            try FileManager.default.removeItem(at: Self.directory(for: id))
        } catch {
            logger.error("Could not delete the index of \(self.libraries[position].name): \(error.localizedDescription)")
        }
        libraries.remove(at: position)
        save()
    }

    /// Size on disk of a library's index files.
    nonisolated static func indexSize(of id: UUID) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory(for: id), includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private func checkOverlap(of path: String, name: String, ignoring id: UUID?) throws {
        for library in active where library.id != id {
            if library.path == path { throw LibraryError.alreadyAdded(library.name) }
            if Self.folder(library.path, contains: path) { throw LibraryError.insideLibrary(folder: name, library: library.name) }
            if Self.folder(path, contains: library.path) { throw LibraryError.containsLibrary(folder: name, library: library.name) }
        }
    }

    private func libraryChanged() {
        guard ready else { return }
        activate()
        ChatStore.shared.reloadThreads()
        Task { await DocumentIndexer.shared.refreshCounts() }
    }

    // MARK: - Activation

    /// Resolves every active folder, keeps security-scoped access open, then watches and scans the libraries.
    func activate() {
        var roots: [(id: UUID, root: URL)] = []
        for position in libraries.indices where libraries[position].isActive {
            let record = libraries[position]
            guard let root = resolvedRoot(of: record) else { continue }
            if accessedRoots[record.id] != root {
                accessedRoots[record.id]?.stopAccessingSecurityScopedResource()
                _ = root.startAccessingSecurityScopedResource()
                accessedRoots[record.id] = root
            }
            let path = root.path
            if libraries[position].path != path {
                libraries[position].path = path
                libraries[position].name = root.lastPathComponent
                save()
            }
            roots.append((record.id, root))
        }
        LibraryMonitor.shared.activate(roots, autoIndex: IndexSettings.shared.autoIndex)
    }

    /// Stops and restarts the watchers, for settings that change what is watched or ignored.
    func reactivate() {
        LibraryMonitor.shared.deactivate()
        activate()
    }

    /// The folder's current location, with symlinks resolved so every path derived from it matches the stored path:
    /// the bookmark when it resolves (regenerated when stale), else the stored path.
    private func resolvedRoot(of record: LibraryRecord) -> URL? {
        if let data = record.bookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                   let position = libraries.firstIndex(where: { $0.id == record.id }) {
                    libraries[position].bookmark = fresh
                    save()
                }
                return url.resolvingSymlinksInPath()
            }
        }
        return record.path.isEmpty ? nil : record.url.resolvingSymlinksInPath()
    }

    /// The one form every path is compared in: symlinks resolved, so `/tmp` and `/private/tmp` never differ.
    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    // MARK: - Stats across libraries

    var storeErrors: [String] { openIndexes.compactMap(\.store.storeError) }

    func indexedDocumentCount() -> Int {
        openIndexes.reduce(0) { $0 + $1.store.indexedDocumentCount() }
    }

    func storeSizeOnDisk() -> Int64 {
        openIndexes.reduce(0) { $0 + $1.store.storeSizeOnDisk() }
    }

    // MARK: - Registry

    nonisolated static func folder(_ folder: String, contains path: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.registryURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            libraries = try decoder.decode(Registry.self, from: data).libraries
        } catch {
            logger.error("The library registry could not be read: \(error.localizedDescription)")
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: DataStore.storeDirectory, withIntermediateDirectories: true)
            try encoder.encode(Registry(version: 1, libraries: libraries)).write(to: Self.registryURL, options: .atomic)
        } catch {
            logger.error("The library registry could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration from the single library of 2.1 and earlier

    /// Turns the one `pkmRootPath` folder into the first library and moves its index files into that library's folder.
    /// A Debug launch with `-DidoStoreDirectory` skips this unless `-DidoLegacyLibrary /folder` names the folder,
    /// which exercises the move against a scratch store without touching the real preferences.
    private func migrateSingleLibraryIfNeeded() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: Self.registryURL.path) else { return }
        let defaults = UserDefaults.standard
        var legacyFolder: String?
        #if DEBUG
        legacyFolder = defaults.string(forKey: "DidoLegacyLibrary")
        #endif
        guard !DataStore.isOverridden || legacyFolder != nil else { return }
        let path = legacyFolder ?? defaults.string(forKey: "pkmRootPath") ?? ""
        let bookmark = legacyFolder == nil ? defaults.data(forKey: "pkmRootBookmark") : nil
        guard !path.isEmpty || bookmark != nil else { return }
        var record = LibraryRecord(id: UUID(), name: (path as NSString).lastPathComponent, path: path, bookmark: bookmark, addedAt: Date(), removedAt: nil)
        if let url = resolvedRoot(of: record) {
            record.name = url.lastPathComponent
            record.path = url.path
        }
        let directory = Self.directory(for: record.id)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in ["index.store", "index.store-wal", "index.store-shm", "vectors.index", "fulltext.sqlite"] {
                let source = DataStore.storeDirectory.appendingPathComponent(file)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.moveItem(at: source, to: directory.appendingPathComponent(file))
            }
        } catch {
            logger.error("Could not move the index of \(record.name) into \(directory.path): \(error.localizedDescription)")
        }
        libraries = [record]
        save()
        if !DataStore.isOverridden {
            defaults.removeObject(forKey: "pkmRootPath")
            defaults.removeObject(forKey: "pkmRootBookmark")
        }
        logger.notice("Moved the library \(record.name) and its index to \(directory.path)")
        DebugLog.write("libraries: moved the 2.1 index of \(record.name) to \(directory.path)")
    }

    // MARK: - Debug launch arguments

    /// `-DidoLibrary /folder` adds a library (repeatable); `-DidoRemoveLibrary /folder` removes one, keeping its index.
    private func addLibrariesFromLaunchArguments() {
        #if DEBUG
        let arguments = CommandLine.arguments
        for (offset, argument) in arguments.enumerated() where offset + 1 < arguments.count {
            let url = URL(fileURLWithPath: arguments[offset + 1], isDirectory: true)
            switch argument {
            case "-DidoLibrary":
                do {
                    try add(url)
                } catch {
                    logger.error("Launch argument: \(error.localizedDescription)")
                }
            case "-DidoRemoveLibrary":
                if let record = library(containing: url.path), record.path == Self.canonicalPath(url) {
                    remove(record.id)
                }
            default:
                break
            }
        }
        #endif
    }
}
