import SwiftUI

struct ContentView: View {
    @Bindable var appState = AppState.shared
    
    var body: some View {
        NavigationSplitView {
            LibrarySidebarView()
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
                        landingView
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
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.notificationMessage)
        }
        .safeAreaInset(edge: .bottom) {
            StatusbarView()
        }
    }
    
    @ViewBuilder
    private var landingView: some View {
        VStack(spacing: 30) {
            Image(systemName: "sparkles")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .font(.system(size: 80))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            VStack(spacing: 12) {
                Text("Dido Assistant")
                    .font(.system(.title, design: .rounded, weight: .bold))
                
                Text("Select any file or folder in the sidebar to start a context-aware chat.")
                    .font(.system(.body, design: .rounded))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            
            Button {
                appState.showingSettings = true
            } label: {
                Label("Open Settings", systemImage: "gearshape.fill")
                    .padding(.horizontal)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
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
