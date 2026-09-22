import SwiftUI

struct ContentView: View {
    @Bindable var appState = AppState.shared
    private let dataStore = DataStore.shared
    private let indexSettings = IndexSettings.shared

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .listStyle(.sidebar)
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if let storeError = dataStore.storeError {
                        StoreErrorBanner(message: storeError)
                    }
                    Group {
                        if appState.showingSettings {
                            SettingsView()
                        } else if appState.showingDashboard {
                            IndexDashboardView()
                        } else if let activeItem = appState.activeItem {
                            ChatView(selectedItem: activeItem)
                                .id(activeItem.id)
                        } else {
                            landingView
                        }
                    }
                }

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
        .task { await DocumentIndexer.shared.loadVectorIndex() }
        .task(id: appState.pkmRootBookmark ?? Data(appState.pkmRootPath.utf8)) {
            let root = appState.activateRoot()
            LibraryMonitor.shared.activate(root: root, autoIndex: indexSettings.autoIndex)
        }
    }

    private var landingView: some View {
        VStack(spacing: 30) {
            Image(systemName: "sparkles")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .font(.system(size: 80))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))

            VStack(spacing: 12) {
                Text("Dido")
                    .font(.system(.title, design: .rounded, weight: .bold))
                Text(appState.rootURL == nil
                     ? "Choose a library folder in Settings, then pick any file or folder in the sidebar to ask about it."
                     : "Select any file or folder in the sidebar to start a context-aware chat.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 12) {
                if appState.rootURL != nil {
                    Button {
                        appState.askLibrary()
                    } label: {
                        Label("Ask the whole library", systemImage: "books.vertical.fill")
                            .padding(.horizontal)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button {
                    appState.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}

/// Persistent banner shown when the database could not be opened.
struct StoreErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
    }
}

#Preview {
    ContentView()
}
