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
    var showingDashboard: Bool = false
    var searchText: String = ""
    var searchPresented: Bool = false
    var previewVisible: Bool = false
    /// Narrows retrieval for the current chat; reset when the item changes.
    var retrievalFilter = RetrievalFilter()
    /// Debug launch flags: expand "Why this answer" on every reply, and choose the preview mode on open.
    var debugExpandWhy = false
    var debugPreviewMode: String?
    var debugFollowUpQuestion: String?
    var debugThenOpenSource: Int?
    var debugCompare = false
    /// Debug launch flags for the sub-task planner: always plan, and run the plan without waiting for approval.
    var debugForcePlan = false
    var debugAutoRunPlan = false

    /// Keeps the sparkles item in the menu bar for quick questions.
    var showMenuBarExtra: Bool = UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showMenuBarExtra, forKey: "showMenuBarExtra") }
    }

    /// The library the user worked in last: the default for ⇧⌘L, the menu bar question and the dashboard.
    var currentLibraryID: UUID? = UserDefaults.standard.string(forKey: "currentLibraryID").flatMap(UUID.init) {
        didSet { UserDefaults.standard.set(currentLibraryID?.uuidString, forKey: "currentLibraryID") }
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

    // MARK: - Libraries

    /// The current library while it is active, else the first active one.
    var currentLibrary: LibraryRecord? {
        let manager = LibraryManager.shared
        if let id = currentLibraryID, let record = manager.library(id: id), record.isActive { return record }
        return manager.active.first
    }

    /// Lets the user pick one or more folders and adds each as a library.
    func addLibrariesWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more folders to add as libraries. Each is indexed on its own."
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            self.addLibraries(panel.urls)
        }
    }

    /// Adds each folder as a library and reports what happened in one toast.
    func addLibraries(_ urls: [URL]) {
        var added: [String] = []
        var problems: [String] = []
        for url in urls {
            do {
                added.append(try LibraryManager.shared.add(url).name)
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if currentLibraryID == nil { currentLibraryID = LibraryManager.shared.active.first?.id }
        if !problems.isEmpty {
            showNotification(problems.joined(separator: " "), type: .error)
        } else if added.count == 1, let name = added.first {
            showNotification("Added the library \(name).", type: .success)
        } else if !added.isEmpty {
            showNotification("Added \(added.count) libraries.", type: .success)
        }
    }

    /// Takes a library out of the sidebar; its index is kept for when it is added again.
    func removeLibrary(_ id: UUID) {
        guard let record = LibraryManager.shared.library(id: id) else { return }
        LibraryManager.shared.remove(id)
        showNotification("Removed \(record.name). Its index is kept; add it again from Settings › Libraries.")
    }

    // MARK: - Navigation

    /// Shows the chat for an item and remembers its library as the current one.
    func open(_ item: SelectedItem) {
        activeItem = item
        currentLibraryID = item.libraryID
        showingDashboard = false
    }

    func selectFile(_ url: URL) {
        guard let library = LibraryManager.shared.library(containing: url.path) else {
            showNotification("\(url.lastPathComponent) is not inside any of your libraries.", type: .error)
            return
        }
        open(SelectedItem(url: url, libraryID: library.id))
    }

    /// Opens the chat that searches every indexed file of a library, the current one by default.
    func askLibrary(_ id: UUID? = nil) {
        let manager = LibraryManager.shared
        guard let record = id.flatMap({ manager.library(id: $0) }) ?? currentLibrary, let root = manager.root(of: record.id) else {
            showNotification("Add a library folder in Settings first.", type: .error)
            openSettings()
            return
        }
        open(SelectedItem.library(record, root: root))
    }

    func showHome() {
        activeItem = nil
        showingDashboard = false
    }

    func showDashboard() {
        showingDashboard = true
    }

    /// Opens the native Settings window by performing the app menu's own Settings item (⌘,),
    /// which works whatever selector the current OS wires it to.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        if let item = appMenu?.items.first(where: { $0.keyEquivalent == "," }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        } else if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// Indexes the current file or folder again, or the whole library from the library chat.
    func reindexCurrentItem() {
        guard let item = activeItem else { return }
        Task { await DocumentIndexer.shared.index(item.url) }
    }

    /// Totals across every active library.
    func updateStats() {
        let manager = LibraryManager.shared
        indexedCount = manager.indexedDocumentCount()
        indexSize = ByteCountFormatter.string(fromByteCount: manager.storeSizeOnDisk(), countStyle: .file)
    }
}
