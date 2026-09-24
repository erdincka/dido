import Foundation

/// Recognises files that are versions of one document, such as `20260919-Design.docx` and `20260923-Design.docx`,
/// so questions about "the latest" are answered from the newest version only.
enum DocumentVersions {
    /// Words that mean the user wants the most recent version of something.
    static let recencySignals = [
        "latest", "newest", "most recent", "most up to date", "up-to-date", "current version", "currently recommended",
        "last version", "final version", "updated version", "recent version", "new version",
    ]

    static func asksForLatest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return recencySignals.contains { lowered.contains($0) }
    }

    // MARK: - Dates

    private static let compactDate = try? NSRegularExpression(pattern: #"(?<!\d)((?:19|20)\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?!\d)"#)
    private static let dayFirstDate = try? NSRegularExpression(pattern: #"(?<!\d)(0[1-9]|[12]\d|3[01])[-_.](0[1-9]|1[0-2])[-_.]((?:19|20)\d{2})(?!\d)"#)

    /// The date written in a file name (YYYYMMDD, YYYY-MM-DD or DD-MM-YYYY), if any.
    static func nameDate(_ filename: String) -> Date? {
        let range = NSRange(filename.startIndex..., in: filename)
        var parts: (year: String, month: String, day: String)?
        if let match = compactDate?.firstMatch(in: filename, range: range) {
            parts = (substring(filename, match.range(at: 1)), substring(filename, match.range(at: 2)), substring(filename, match.range(at: 3)))
        } else if let match = dayFirstDate?.firstMatch(in: filename, range: range) {
            parts = (substring(filename, match.range(at: 3)), substring(filename, match.range(at: 2)), substring(filename, match.range(at: 1)))
        }
        guard let parts, let year = Int(parts.year), let month = Int(parts.month), let day = Int(parts.day) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))
    }

    /// "dated 23 Sep 2026" from the file name, otherwise "modified 23 Sep 2026".
    static func dateLabel(filename: String, modified: Date?) -> String? {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        if let date = nameDate(filename) { return "dated \(date.formatted(style))" }
        return modified.map { "modified \($0.formatted(style))" }
    }

    // MARK: - Families

    private static let versionNoise: [NSRegularExpression] = [
        #"(?:19|20)\d{2}[-_.]?(?:0[1-9]|1[0-2])[-_.]?(?:0[1-9]|[12]\d|3[01])"#,
        #"(?:0[1-9]|[12]\d|3[01])[-_.](?:0[1-9]|1[0-2])[-_.](?:19|20)\d{2}"#,
        #"\(\d+\)"#,
        #"\bcopy\b(?:\s*\d+)?"#,
        #"\bv\d+(?:\.\d+)*\b"#,
        #"\b(?:rev|version)\s*\d+\b"#,
        #"\b(?:draft|final|latest|updated)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// Folder, name without dates or version tags, and extension. Nil when too little of the name is left to compare.
    static func familyKey(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        var stem = url.deletingPathExtension().lastPathComponent.lowercased()
        for pattern in versionNoise {
            stem = pattern.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: " ")
        }
        let letters = stem.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard letters.count >= 3 else { return nil }
        return url.deletingLastPathComponent().path + "/" + String(String.UnicodeScalarView(letters)) + "." + url.pathExtension.lowercased()
    }

    /// Older versions mapped to the file name of the newest version in their family.
    static func superseded(_ files: [(path: String, modified: Date?)]) -> [String: String] {
        var families: [String: [(path: String, modified: Date?)]] = [:]
        for file in files {
            guard let key = familyKey(path: file.path) else { continue }
            families[key, default: []].append(file)
        }
        var older: [String: String] = [:]
        for members in families.values where members.count > 1 {
            let ranked = members.sorted { a, b in
                let aName = URL(fileURLWithPath: a.path).lastPathComponent, bName = URL(fileURLWithPath: b.path).lastPathComponent
                let aDate = nameDate(aName) ?? a.modified ?? .distantPast
                let bDate = nameDate(bName) ?? b.modified ?? .distantPast
                if aDate != bDate { return aDate > bDate }
                return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
            let newest = URL(fileURLWithPath: ranked[0].path).lastPathComponent
            for member in ranked.dropFirst() { older[member.path] = newest }
        }
        return older
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        Range(range, in: text).map { String(text[$0]) } ?? ""
    }
}
