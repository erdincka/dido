import SwiftUI
import Observation

@Observable @MainActor
final class AppState {
    static let shared = AppState()
    
    var selectedItems: [SelectedItem] = [] {
        didSet {
            saveSelectedItems()
        }
    }
    
    var activeItem: SelectedItem?
    var showingSettings: Bool = false
    var searchText: String = ""
    
    var pkmRootPath: String = "" {
        didSet {
            UserDefaults.standard.set(pkmRootPath, forKey: "pkmRootPath")
        }
    }
    
    var pkmRootBookmark: Data? = nil {
        didSet {
            UserDefaults.standard.set(pkmRootBookmark, forKey: "pkmRootBookmark")
        }
    }
    
    var generatingStates: [UUID: Bool] = [:]
    
    // Notifications
    var notificationMessage: String?
    var notificationType: NotificationType = .info
    
    enum NotificationType {
        case info, error, success
    }
    
    func showNotification(_ message: String, type: NotificationType = .info) {
        Task { @MainActor in
            self.notificationMessage = message
            self.notificationType = type
        }
        
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000) // 4 seconds
            await MainActor.run {
                if self.notificationMessage == message {
                    withAnimation {
                        self.notificationMessage = nil
                    }
                }
            }
        }
    }
    
    // Status info
    var indexedCount: Int = 0
    var indexSize: String = "0 MB"
    var isLocalModel: Bool {
        LLMService.shared.externalBaseURL.contains("localhost") || LLMService.shared.externalBaseURL.contains("127.0.0.1")
    }
    
    private init() {
        self.pkmRootPath = UserDefaults.standard.string(forKey: "pkmRootPath") ?? ""
        self.pkmRootBookmark = UserDefaults.standard.data(forKey: "pkmRootBookmark")
        loadSelectedItems()
    }
    
    func getSecurityScopedURL() -> URL? {
        guard let data = pkmRootBookmark else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                // Needs regeneration in a real app, but we will just return the URL for now
            }
            return url
        } catch {
            return nil
        }
    }
    
    private func saveSelectedItems() {
        if let encoded = try? JSONEncoder().encode(selectedItems) {
            UserDefaults.standard.set(encoded, forKey: "selectedItems")
        }
    }
    
    private func loadSelectedItems() {
        if let data = UserDefaults.standard.data(forKey: "selectedItems"),
           let decoded = try? JSONDecoder().decode([SelectedItem].self, from: data) {
            self.selectedItems = decoded
        }
    }
    
    func addSelectedItem(url: URL) {
        if let existing = selectedItems.first(where: { $0.url == url }) {
            activeItem = existing
        } else {
            let newItem = SelectedItem(url: url)
            selectedItems.append(newItem)
            activeItem = newItem
        }
    }
    
    func removeSelectedItem(_ item: SelectedItem) {
        if let index = selectedItems.firstIndex(of: item) {
            if activeItem == item {
                activeItem = nil
            }
            selectedItems.remove(at: index)
        }
    }
    
    func selectFile(_ url: URL) {
        if let existing = selectedItems.first(where: { $0.url == url }) {
            activeItem = existing
        } else {
            // For navigation, we might just want to set the activeItem without adding to saved list 
            // OR we add it so history is preserved. Let's add it for history.
            let newItem = SelectedItem(url: url)
            selectedItems.append(newItem)
            activeItem = newItem
        }
        showingSettings = false
    }
    
    @MainActor
    func updateStats() {
        let stats = VectorDatabaseService.shared.getStats()
        self.indexedCount = stats.count
        self.indexSize = stats.size
    }
}
