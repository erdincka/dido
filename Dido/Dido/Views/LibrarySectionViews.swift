import SwiftUI

/// A library's name with its actions: ask, index, re-index, reveal, remove.
struct LibrarySectionHeader: View {
    let library: LibraryRecord
    @Binding var isExpanded: Bool

    private let appState = AppState.shared
    @State private var confirmRebuild = false

    var body: some View {
        HStack {
            SectionChevron(isExpanded: $isExpanded)
            Text(library.name)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
            Spacer()
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Library actions")
        }
        .help(library.path)
        .contextMenu { actions }
        .confirmationDialog("Re-index \(library.name) from scratch?", isPresented: $confirmRebuild) {
            Button("Re-index", role: .destructive) {
                Task { await DocumentIndexer.shared.rebuild(library.id) }
            }
        } message: {
            Text("Every passage and embedding of this library is deleted, then the folder is scanned again. Chat history is kept.")
        }
    }

    private var root: URL { LibraryManager.shared.root(of: library.id) ?? library.url }

    @ViewBuilder
    private var actions: some View {
        Button("Ask this library") { appState.askLibrary(library.id) }
        Button("Index now") { Task { await DocumentIndexer.shared.index(root) } }
        Button("Re-index from scratch…") { confirmRebuild = true }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
        Divider()
        Button("Remove from Dido") { appState.removeLibrary(library.id) }
    }
}

/// An always-visible disclosure chevron for a sidebar section header.
/// `Section(isExpanded:)` only shows its chevron on hover, which draws the eye as the pointer moves.
struct SectionChevron: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse" : "Expand")
    }
}

/// A plain section title with an always-visible chevron.
struct CollapsibleSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        HStack {
            SectionChevron(isExpanded: $isExpanded)
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
    }
}

/// The first row of a library section: the chat that searches every indexed file in it.
struct AskLibraryRow: View {
    let library: LibraryRecord

    private let appState = AppState.shared
    private var isActive: Bool {
        appState.activeItem?.isLibrary == true && appState.activeItem?.libraryID == library.id && !appState.showingDashboard
    }

    var body: some View {
        Button {
            appState.askLibrary(library.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Ask this library")
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
