import Foundation
import Accelerate
import os

/// One chunk in the in-memory index. Vectors live in the index's matrix, not here.
struct IndexEntry: Sendable, Codable {
    let chunkID: UUID
    let path: String
    let filename: String
    let ordinal: Int
    let start: Int
    let end: Int
    let text: String
    var vector: [Float]
    var modified: Date?

    var fileType: String { (path as NSString).pathExtension.lowercased() }
}

struct SearchHit: Sendable {
    let entry: IndexEntry
    let score: Float
}

/// Which chunks a search may return.
enum SearchScope: Sendable {
    case all
    case file(String)
    case folder(String)

    func contains(_ path: String) -> Bool {
        switch self {
        case .all: return true
        case .file(let file): return path == file
        case .folder(let folder): return path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        }
    }
}

/// Optional narrowing of a search, chosen by the user in the chat header.
struct RetrievalFilter: Sendable, Hashable, Codable {
    var fileTypes: Set<String> = []
    var modifiedWithinDays: Int?

    var isEmpty: Bool { fileTypes.isEmpty && modifiedWithinDays == nil }

    func allows(_ entry: IndexEntry) -> Bool {
        if !fileTypes.isEmpty && !fileTypes.contains(entry.fileType) { return false }
        if let days = modifiedWithinDays {
            guard let modified = entry.modified, modified >= Date().addingTimeInterval(-Double(days) * 86_400) else { return false }
        }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if !fileTypes.isEmpty { parts.append(fileTypes.sorted().map { "." + $0 }.joined(separator: ", ")) }
        if let days = modifiedWithinDays { parts.append("modified in the last \(days) days") }
        return parts.joined(separator: " · ")
    }
}

/// Cosine search over every embedded chunk with one Accelerate matrix-vector product per query.
/// Rows are unit vectors in a flat matrix; removed rows are tombstoned and compacted lazily.
actor VectorIndex {
    static let shared = VectorIndex()

    private var entries: [IndexEntry] = []
    private var matrix: [Float] = []
    private var alive: [Bool] = []
    private var dimension = 0
    private var tombstones = 0
    private(set) var modelIdentifier: String?
    private var saveTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.dido", category: "VectorIndex")

    private init() {}

    var count: Int { entries.count - tombstones }

    // MARK: - Mutation

    func replaceAll(_ newEntries: [IndexEntry], model: String) {
        entries = []
        matrix = []
        alive = []
        tombstones = 0
        dimension = newEntries.first?.vector.count ?? 0
        modelIdentifier = model
        for entry in newEntries { append(entry) }
        scheduleSave()
    }

    /// Replaces the entries for one document. Ignored when the vectors come from a different model.
    func replace(path: String, with newEntries: [IndexEntry], model: String) {
        guard model == modelIdentifier else { return }
        removeRows { $0.path == path }
        if dimension == 0 { dimension = newEntries.first?.vector.count ?? 0 }
        for entry in newEntries { append(entry) }
        compactIfNeeded()
        scheduleSave()
    }

    func remove(path: String) {
        removeRows { $0.path == path }
        compactIfNeeded()
        scheduleSave()
    }

    func remove(pathPrefix: String) {
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        removeRows { $0.path.hasPrefix(prefix) }
        compactIfNeeded()
        scheduleSave()
    }

    func removeAll() {
        entries = []
        matrix = []
        alive = []
        tombstones = 0
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    private func append(_ entry: IndexEntry) {
        let unit = Self.unit(entry.vector)
        guard unit.count == dimension, dimension > 0 else { return }
        var stored = entry
        stored.vector = []
        entries.append(stored)
        matrix.append(contentsOf: unit)
        alive.append(true)
    }

    private func removeRows(where predicate: (IndexEntry) -> Bool) {
        for index in entries.indices where alive[index] && predicate(entries[index]) {
            alive[index] = false
            tombstones += 1
        }
    }

    private func compactIfNeeded() {
        guard tombstones > 0, tombstones * 5 > entries.count else { return }
        var newEntries: [IndexEntry] = []
        var newMatrix: [Float] = []
        newEntries.reserveCapacity(entries.count - tombstones)
        newMatrix.reserveCapacity((entries.count - tombstones) * dimension)
        for index in entries.indices where alive[index] {
            newEntries.append(entries[index])
            newMatrix.append(contentsOf: matrix[(index * dimension)..<((index + 1) * dimension)])
        }
        entries = newEntries
        matrix = newMatrix
        alive = Array(repeating: true, count: newEntries.count)
        tombstones = 0
    }

    // MARK: - Queries

    /// All live entries in a scope, in document order.
    func entries(in scope: SearchScope, filter: RetrievalFilter = RetrievalFilter()) -> [IndexEntry] {
        liveEntries().filter { scope.contains($0.path) && filter.allows($0) }.sorted { ($0.path, $0.ordinal) < ($1.path, $1.ordinal) }
    }

    /// Distinct file extensions among live entries, for the filter menu.
    func fileTypes(in scope: SearchScope) -> [String] {
        Array(Set(liveEntries().filter { scope.contains($0.path) }.map(\.fileType))).sorted()
    }

    func entry(chunkID: UUID) -> IndexEntry? {
        entries.first { $0.chunkID == chunkID }
    }

    /// Top `limit` chunks by cosine similarity, with small boosts for keyword matches and recent files.
    func search(query: [Float], scope: SearchScope, limit: Int, minimumScore: Float, keywords: [String], filter: RetrievalFilter = RetrievalFilter()) -> [SearchHit] {
        let normalisedQuery = Self.unit(query)
        guard normalisedQuery.count == dimension, !entries.isEmpty else { return [] }

        var scores = [Float](repeating: 0, count: entries.count)
        vDSP_mmul(matrix, 1, normalisedQuery, 1, &scores, 1, vDSP_Length(entries.count), 1, vDSP_Length(dimension))

        let lowered = keywords.map { $0.lowercased() }
        let now = Date()
        var hits: [SearchHit] = []
        for index in entries.indices where alive[index] {
            let entry = entries[index]
            guard scope.contains(entry.path), filter.allows(entry) else { continue }
            var score = scores[index]
            if !lowered.isEmpty {
                let text = entry.text.lowercased()
                let matched = lowered.filter { text.contains($0) }.count
                score += 0.1 * Float(matched) / Float(lowered.count)
            }
            if let modified = entry.modified {
                let age = now.timeIntervalSince(modified) / 86_400
                if age <= 7 { score += 0.05 } else if age <= 30 { score += 0.03 }
            }
            if score >= minimumScore {
                hits.append(SearchHit(entry: entry, score: score))
            }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Case-insensitive substring search over passage text, for the sidebar.
    func textSearch(_ query: String, limit: Int) -> [IndexEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var hits: [IndexEntry] = []
        for entry in liveEntries() where entry.text.localizedCaseInsensitiveContains(needle) {
            hits.append(entry)
            if hits.count >= limit { break }
        }
        return hits
    }

    private func liveEntries() -> [IndexEntry] {
        entries.indices.compactMap { alive[$0] ? entries[$0] : nil }
    }

    static func unit(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sumOfSquares.squareRoot()
        guard magnitude > 0 else { return [] }
        var scale = 1 / magnitude
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))
        return result
    }

    // MARK: - Persistence

    /// A compact file beside the store: a JSON header with the metadata, then the raw Float32 matrix.
    static var storageURL: URL {
        DataStore.storeDirectory.appendingPathComponent("vectors.index")
    }

    private struct Header: Codable {
        let version: Int
        let model: String
        let dimension: Int
        let entries: [IndexEntry]
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        compactIfNeeded()
        guard let modelIdentifier else { return }
        let started = Date()
        do {
            let header = Header(version: 1, model: modelIdentifier, dimension: dimension, entries: entries)
            let json = try JSONEncoder().encode(header)
            var data = Data("DIDO".utf8)
            var length = UInt64(json.count)
            data.append(Data(bytes: &length, count: 8))
            data.append(json)
            matrix.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
            try data.write(to: Self.storageURL, options: .atomic)
            logger.info("Saved vector index: \(self.entries.count) rows in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        } catch {
            logger.error("Saving the vector index failed: \(error.localizedDescription)")
        }
    }

    /// Loads the persisted index when it was built with `model`. Returns false when it must be rebuilt.
    func load(expectedModel model: String) -> Bool {
        guard let data = try? Data(contentsOf: Self.storageURL, options: .mappedIfSafe), data.count > 12,
              data.prefix(4) == Data("DIDO".utf8) else { return false }
        let length = Int(data.subdata(in: 4..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard data.count >= 12 + length, let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length))),
              header.version == 1, header.model == model else { return false }
        let floats = data.count - 12 - length
        guard floats == header.entries.count * header.dimension * MemoryLayout<Float>.size else { return false }
        var loaded = [Float](repeating: 0, count: header.entries.count * header.dimension)
        _ = loaded.withUnsafeMutableBytes { data.copyBytes(to: $0, from: (12 + length)..<data.count) }
        entries = header.entries
        matrix = loaded
        alive = Array(repeating: true, count: entries.count)
        tombstones = 0
        dimension = header.dimension
        modelIdentifier = model
        return true
    }
}
