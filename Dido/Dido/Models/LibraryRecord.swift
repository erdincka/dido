import Foundation

/// A root folder the user added. Its index lives under the app's own directory, never inside the folder,
/// so removing the library keeps the index and adding the folder again finds it.
struct LibraryRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// The folder's name, shown in the sidebar and in Settings.
    var name: String
    /// The folder's path when it was last activated, for display and for matching files to their library.
    var path: String
    /// Security-scoped bookmark, so the library follows its folder across moves and renames.
    var bookmark: Data?
    var addedAt: Date
    /// Set while the library is removed. Its index is kept so it can be added again.
    var removedAt: Date?

    var isActive: Bool { removedAt == nil }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}
