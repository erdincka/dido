import Foundation

/// Glob patterns that keep files and folders out of the sidebar and the index.
/// Read from `.didoignore` in the library root (one pattern per line, `#` comments) and from Settings.
struct IgnoreRules: Sendable, Equatable {
    static let empty = IgnoreRules(patterns: [])

    let patterns: [String]

    static func load(root: URL, extra: String) -> IgnoreRules {
        var patterns: [String] = []
        if let text = try? String(contentsOf: root.appendingPathComponent(".didoignore"), encoding: .utf8) {
            patterns += Self.parse(text)
        }
        patterns += Self.parse(extra)
        return IgnoreRules(patterns: patterns)
    }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// True when the path (relative to the root) or its last component matches any pattern.
    func isIgnored(relativePath: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        let name = (relativePath as NSString).lastPathComponent
        for pattern in patterns {
            let trimmed = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
            if fnmatch(trimmed, name, 0) == 0 || fnmatch(trimmed, relativePath, 0) == 0 {
                return true
            }
            if trimmed.contains("/"), fnmatch(trimmed + "/*", relativePath, 0) == 0 {
                return true
            }
        }
        return false
    }
}
