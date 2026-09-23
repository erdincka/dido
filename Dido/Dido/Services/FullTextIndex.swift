import Foundation
import SQLite3
import os

/// A SQLite FTS5 index over passage text, kept beside the vector index for exact words, names and codes.
actor FullTextIndex {
    static let shared = FullTextIndex()

    struct Hit: Sendable {
        let chunkID: UUID
        let rank: Double
    }

    private var db: OpaquePointer?
    private var opened = false
    private let logger = Logger(subsystem: "com.dido", category: "FullText")

    private init() {}

    /// Opens the database on first use; an actor's initialiser cannot call isolated methods.
    private func open() {
        guard !opened else { return }
        opened = true
        let url = DataStore.storeDirectory.appendingPathComponent("fulltext.sqlite")
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            logger.error("Could not open the full-text index: \(message)")
            sqlite3_close(handle)
            db = nil
            return
        }
        db = handle
        execute("CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(chunk_id UNINDEXED, path UNINDEXED, ordinal UNINDEXED, text, tokenize = 'porter unicode61')")
    }

    var count: Int {
        open()
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM passages", -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Mutation

    func replace(path: String, passages: [(chunkID: UUID, ordinal: Int, text: String)]) {
        open()
        guard db != nil else { return }
        execute("BEGIN")
        deleteRows(where: "path = ?", value: path)
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO passages(chunk_id, path, ordinal, text) VALUES (?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK {
            for passage in passages {
                sqlite3_reset(statement)
                sqlite3_bind_text(statement, 1, passage.chunkID.uuidString, -1, Self.transient)
                sqlite3_bind_text(statement, 2, path, -1, Self.transient)
                sqlite3_bind_int(statement, 3, Int32(passage.ordinal))
                sqlite3_bind_text(statement, 4, passage.text, -1, Self.transient)
                sqlite3_step(statement)
            }
        }
        sqlite3_finalize(statement)
        execute("COMMIT")
    }

    func remove(path: String) {
        open()
        deleteRows(where: "path = ?", value: path)
    }

    func remove(pathPrefix: String) {
        open()
        let prefix = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
        deleteRows(where: "path LIKE ? ESCAPE '\\'", value: prefix.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%")
    }

    func removeAll() {
        open()
        execute("DELETE FROM passages")
    }

    /// Fills the index from the vector index's entries when it is empty (first launch after upgrading).
    func rebuild(from entries: [IndexEntry]) {
        open()
        execute("DELETE FROM passages")
        let grouped = Dictionary(grouping: entries, by: \.path)
        for (path, group) in grouped {
            replace(path: path, passages: group.map { ($0.chunkID, $0.ordinal, $0.text) })
        }
        logger.info("Rebuilt the full-text index with \(entries.count) passages")
    }

    // MARK: - Search

    /// BM25-ranked matches for the query's words, any of which may match. Best first.
    func search(_ query: String, limit: Int) -> [Hit] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        open()
        guard db != nil, !words.isEmpty else { return [] }
        let match = words.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT chunk_id, bm25(passages) FROM passages WHERE passages MATCH ? ORDER BY bm25(passages) LIMIT ?", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_text(statement, 1, match, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var hits: [Hit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0), let id = UUID(uuidString: String(cString: text)) {
                hits.append(Hit(chunkID: id, rank: sqlite3_column_double(statement, 1)))
            }
        }
        return hits
    }

    // MARK: - Helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            logger.error("SQL failed (\(sql.prefix(40))): \(message)")
        }
    }

    private func deleteRows(where clause: String, value: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "DELETE FROM passages WHERE \(clause)", -1, &statement, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(statement, 1, value, -1, Self.transient)
        sqlite3_step(statement)
    }
}
