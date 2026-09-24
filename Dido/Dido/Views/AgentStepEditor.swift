import SwiftUI

/// Edits one sub-task: what it should find out, which tool it uses, and where it looks.
struct AgentStepEditor: View {
    @State var step: AgentStep
    let isNew: Bool
    let shellAllowed: Bool
    let onSave: (AgentStep) -> Void
    let onCancel: () -> Void

    private var kinds: [AgentToolKind] { AgentToolKind.allCases.filter { $0 != .shell || shellAllowed } }
    private var canSave: Bool {
        !step.title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!step.tool.kind.usesQuery || !step.tool.query.trimmingCharacters(in: .whitespaces).isEmpty)
            && (step.tool.kind != .readFile || !step.tool.path.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "New step" : "Edit step")
                .font(.caption.weight(.semibold))
            TextField("Title", text: $step.title, prompt: Text("Short title"))
            TextField("Find out", text: $step.instruction, prompt: Text("What this step must find out"), axis: .vertical)
                .lineLimit(1...3)
            Picker("Tool", selection: $step.tool.kind) {
                ForEach(kinds) { kind in
                    Label(kind.label, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.menu)
            if step.tool.kind.usesPath {
                TextField(step.tool.kind == .readFile ? "File" : "Folder", text: $step.tool.path,
                          prompt: Text(step.tool.kind == .readFile ? "Path relative to the library root" : "Folder relative to the library root; empty for the root"))
            }
            if step.tool.kind.usesQuery {
                TextField(step.tool.kind.queryLabel, text: $step.tool.query, prompt: Text(queryPrompt))
                    .font(step.tool.kind == .shell ? .body.monospaced() : .body)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save and run") {
                    step.title = step.title.trimmingCharacters(in: .whitespaces)
                    if step.instruction.trimmingCharacters(in: .whitespaces).isEmpty { step.instruction = step.title }
                    onSave(step)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(10)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    private var queryPrompt: String {
        switch step.tool.kind {
        case .search: return "What to look for"
        case .shell: return "ls -lt Projects"
        case .askUser: return "The question to ask you"
        case .listFolder, .readFile: return ""
        }
    }
}
