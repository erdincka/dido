import SwiftUI

struct StatusbarView: View {
    private let appState = AppState.shared
    private let progress = IndexProgress.shared

    var body: some View {
        HStack {
            HStack(spacing: 12) {
                Label(appState.isLocalModel ? "Local API" : "Remote API",
                      systemImage: appState.isLocalModel ? "laptopcomputer" : "network")

                Divider().frame(height: 12)

                if progress.isIndexing {
                    ProgressView().controlSize(.mini)
                    Text("Indexing \(progress.completed) of \(progress.total): \(progress.currentFile)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button { Task { await DocumentIndexer.shared.cancel() } } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Cancel indexing")
                } else {
                    Text("\(appState.indexedCount) documents indexed")
                    Text("(\(appState.indexSize))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()

            if !appState.pkmRootPath.isEmpty {
                Text(appState.pkmRootPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(.secondary.opacity(0.2)), alignment: .top)
        .task { appState.updateStats() }
    }
}
