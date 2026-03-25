import SwiftUI

struct ContentView: View {
    @Bindable var appState = AppState.shared
    
    var body: some View {
        NavigationSplitView {
            List(selection: $appState.activeItem) {
                if !appState.selectedItems.isEmpty {
                    ForEach(appState.selectedItems) { item in
                        NavigationLink(value: item) {
                            Label(item.name, systemImage: item.isDirectory ? "folder" : "doc.text").imageScale(.large)
                        }
                        .contextMenu {
                            Button("Remove") {
                                removeItem(item)
                            }
                            Button("Open in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            }
                        }
                    }
                }
        }
            .padding(.bottom, 28)
            .navigationTitle("Dido")
            .listStyle(.sidebar)
        } detail: {
            ZStack(alignment: .top) {
                Group {
                    if appState.showingSettings {
                        SettingsView()
                    } else if let activeItem = appState.activeItem {
                        ChatView(selectedItem: activeItem)
                            .id(activeItem.id)
                    } else {
                        FileExplorerView()
                    }
                }
                .environment(\.dynamicTypeSize, .xLarge)
                
                if let message = appState.notificationMessage {
                    NotificationToast(message: message, type: appState.notificationType)
                        .padding(.top, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.notificationMessage)
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    appState.activeItem = nil
                    appState.showingSettings = false
                } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                .help("Library")
            }
            
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    appState.activeItem = nil
                    appState.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .help("Settings")
            }
        }
        .onChange(of: appState.activeItem) { _, newValue in
            if newValue != nil {
                appState.showingSettings = false
            }
        }
        .safeAreaInset(edge: .bottom) {
            StatusbarView()
        }
    }
    
    private func removeItem(_ item: SelectedItem) {
        if let index = appState.selectedItems.firstIndex(of: item) {
            if appState.activeItem == item {
                appState.activeItem = nil
            }
            appState.selectedItems.remove(at: index)
        }
    }
}

#Preview {
    ContentView()
}
