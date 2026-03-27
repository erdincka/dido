import SwiftUI

struct StatusbarView: View {
    private var appState = AppState.shared
    
    var body: some View {
        HStack {
            HStack(spacing: 12) {
                Label(appState.isLocalModel ? "Local API" : "Remote API", 
                      systemImage: appState.isLocalModel ? "laptopcomputer" : "network")
                
                Divider().frame(height: 12)
                
                Text("\(appState.indexedCount) Docs Indexed")
                Text("(\(appState.indexSize))")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            
            Spacer()
            
            if !appState.pkmRootPath.isEmpty {
                Text(appState.pkmRootPath)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(.secondary.opacity(0.2)), alignment: .top)
        .onAppear {
            appState.updateStats()
        }
    }
}
