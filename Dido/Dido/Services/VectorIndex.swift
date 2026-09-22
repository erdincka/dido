import Foundation
import Accelerate

/// One chunk in the in-memory index. Vectors are unit length.
struct IndexEntry: Sendable {
    let chunkID: UUID
    let path: String
    let filename: String
    let ordinal: Int
    let start: Int
    let end: Int
    let text: String
    let vector: [Float]
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

/// Brute-force cosine search over every embedded chunk, kept in memory. Fine for tens of thousands of chunks.
actor VectorIndex {
    static let shared = VectorIndex()

    private var entries: [IndexEntry] = []
    private(set) var modelIdentifier: String?

    private init() {}

    var count: Int { entries.count }

    func replaceAll(_ newEntries: [IndexEntry], model: String) {
        entries = newEntries.map(Self.normalised)
        modelIdentifier = model
    }

    /// Replaces the entries for one document. Ignored when the vectors come from a different model.
    func replace(path: String, with newEntries: [IndexEntry], model: String) {
        guard model == modelIdentifier else { return }
        entries.removeAll { $0.path == path }
        entries.append(contentsOf: newEntries.map(Self.normalised))
    }

    func remove(path: String) {
        entries.removeAll { $0.path == path }
    }

    func remove(pathPrefix: String) {
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        entries.removeAll { $0.path.hasPrefix(prefix) }
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Case-insensitive substring search over passage text, for the sidebar.
    func textSearch(_ query: String, limit: Int) -> [IndexEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var hits: [IndexEntry] = []
        for entry in entries where entry.text.localizedCaseInsensitiveContains(needle) {
            hits.append(entry)
            if hits.count >= limit { break }
        }
        return hits
    }

    /// All entries in a scope, in document order.
    func entries(in scope: SearchScope) -> [IndexEntry] {
        entries.filter { scope.contains($0.path) }.sorted { ($0.path, $0.ordinal) < ($1.path, $1.ordinal) }
    }

    /// Top `limit` chunks by cosine similarity, boosted slightly when they contain the query's words.
    func search(query: [Float], scope: SearchScope, limit: Int, minimumScore: Float, keywords: [String]) -> [SearchHit] {
        let normalisedQuery = Self.unit(query)
        guard !normalisedQuery.isEmpty else { return [] }
        let lowered = keywords.map { $0.lowercased() }

        var hits: [SearchHit] = []
        for entry in entries where scope.contains(entry.path) && entry.vector.count == normalisedQuery.count {
            var similarity: Float = 0
            vDSP_dotpr(entry.vector, 1, normalisedQuery, 1, &similarity, vDSP_Length(entry.vector.count))
            var score = similarity
            if !lowered.isEmpty {
                let text = entry.text.lowercased()
                let matched = lowered.filter { text.contains($0) }.count
                score += 0.1 * Float(matched) / Float(lowered.count)
            }
            if score >= minimumScore {
                hits.append(SearchHit(entry: entry, score: score))
            }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    private static func normalised(_ entry: IndexEntry) -> IndexEntry {
        IndexEntry(chunkID: entry.chunkID, path: entry.path, filename: entry.filename, ordinal: entry.ordinal,
                   start: entry.start, end: entry.end, text: entry.text, vector: unit(entry.vector))
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
}
