import SwiftUI
import Observation

/// Application-wide UI state: the current context item, settings visibility, notifications and stats.
@Observable @MainActor
final class AppState {
    static let shared = AppState()

    enum NotificationType {
        case info, error, success
    }

    var activeItem: SelectedItem?
    /// A question to send as soon as the chat for `activeItem` appears (used by the debug launch flags).
    var pendingQuestion: String?
    /// A passage to show in the preview pane as soon as the chat for `activeItem` appears.
    var pendingCitation: Citation?
    var showingSettings: Bool = false
    var showingDashboard: Bool = false
    var searchText: String = ""

    var pkmRootPath: String = UserDefaults.standard.string(forKey: "pkmRootPath") ?? "" {
        didSet { UserDefaults.standard.set(pkmRootPath, forKey: "pkmRootPath") }
    }

    var pkmRootBookmark: Data? = UserDefaults.standard.data(forKey: "pkmRootBookmark") {
        didSet { UserDefaults.standard.set(pkmRootBookmark, forKey: "pkmRootBookmark") }
    }

    // MARK: - Notifications

    private(set) var notificationMessage: String?
    private(set) var notificationType: NotificationType = .info

    // MARK: - Status bar

    private(set) var indexedCount: Int = 0
    private(set) var indexSize: String = "0 KB"

    var isLocalModel: Bool {
        let url = LLMService.shared.externalBaseURL
        return url.contains("localhost") || url.contains("127.0.0.1")
    }

    private init() {}

    /// Shows a transient toast for four seconds.
    func showNotification(_ message: String, type: NotificationType = .info) {
        notificationMessage = message
        notificationType = type
        Task {
            try? await Task.sleep(for: .seconds(4))
            if notificationMessage == message {
                withAnimation { notificationMessage = nil }
            }
        }
    }

    // MARK: - Library root

    /// The library root, resolved from the saved bookmark when there is one.
    /// A stale bookmark is regenerated so it keeps working across moves and renames.
    var rootURL: URL? {
        if let data = pkmRootBookmark {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    pkmRootBookmark = fresh
                }
                return url
            }
        }
        return pkmRootPath.isEmpty ? nil : URL(fileURLWithPath: pkmRootPath)
    }

    private var accessedRoot: URL?

    /// Resolves the root and keeps security-scoped access open until the root changes.
    func activateRoot() -> URL? {
        guard let root = rootURL else {
            accessedRoot?.stopAccessingSecurityScopedResource()
            accessedRoot = nil
            return nil
        }
        if accessedRoot != root {
            accessedRoot?.stopAccessingSecurityScopedResource()
            _ = root.startAccessingSecurityScopedResource()
            accessedRoot = root
        }
        return root
    }

    func selectFile(_ url: URL) {
        activeItem = SelectedItem(url: url)
        showingSettings = false
        showingDashboard = false
    }

    /// Opens the chat that searches every indexed file.
    func askLibrary() {
        guard let root = rootURL else {
            showingSettings = true
            return
        }
        activeItem = SelectedItem.library(root: root)
        showingSettings = false
        showingDashboard = false
    }

    func showHome() {
        activeItem = nil
        showingSettings = false
        showingDashboard = false
    }

    func showDashboard() {
        showingDashboard = true
        showingSettings = false
    }

    func updateStats() {
        let store = DataStore.shared
        indexedCount = store.indexedDocumentCount()
        indexSize = ByteCountFormatter.string(fromByteCount: store.storeSizeOnDisk(), countStyle: .file)
    }
}
