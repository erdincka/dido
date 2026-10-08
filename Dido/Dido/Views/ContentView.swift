import SwiftUI

struct ContentView: View {
    @Bindable var appState = AppState.shared
    private let manager = LibraryManager.shared
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        VStack(spacing: 0) {
            splitView
            StatusbarView()
        }
        .task(id: manager.activationKey) {
            manager.activate()
            await DocumentIndexer.shared.loadIndexes()
        }
        .onAppear {
            if !onboardingDone && manager.active.isEmpty { showOnboarding = true }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { onboardingDone = true }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            LibrarySidebarView()
                .listStyle(.sidebar)
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    ForEach(manager.storeErrors, id: \.self) { storeError in
                        StoreErrorBanner(message: storeError)
                    }
                    Group {
                        if appState.showingDashboard {
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
                Text(manager.active.isEmpty
                     ? "Add a library folder, then pick any file or folder in the sidebar to ask about it."
                     : "Select any file or folder in the sidebar to start a context-aware chat.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            HStack(spacing: 12) {
                if manager.active.isEmpty {
                    Button {
                        appState.addLibrariesWithPanel()
                    } label: {
                        Label("Add a library folder", systemImage: "plus.circle.fill")
                            .padding(.horizontal)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button {
                        appState.askLibrary()
                    } label: {
                        Label("Ask the whole library", systemImage: "books.vertical.fill")
                            .padding(.horizontal)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                SettingsLink {
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

/// Persistent banner shown when a library's database could not be opened.
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
