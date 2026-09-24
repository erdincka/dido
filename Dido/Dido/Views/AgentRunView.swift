import SwiftUI
import MarkdownUI

/// The assistant's turn while a question runs as sub-tasks: the plan to review, the live steps, a field to steer
/// the remaining steps, and the answer as it streams.
struct AgentRunView: View {
    let runner: AgentRunner
    var onOpenSource: ((Citation) -> Void)?

    @State private var hint = ""
    @State private var editing: AgentStep?
    @State private var adding = false

    private var shellAllowed: Bool { LLMService.shared.allowShellSteps }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                .clipShape(Circle())
                .padding(.top, 4)
            card
            Spacer(minLength: 60)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if runner.phase == .planning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Planning sub-tasks with \(runner.providerName)…").foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(runner.steps.enumerated()), id: \.element.id) { index, step in
                    if editing?.id == step.id, let editing {
                        AgentStepEditor(step: editing, isNew: false, shellAllowed: shellAllowed,
                                        onSave: { runner.updateStep($0); self.editing = nil },
                                        onCancel: { self.editing = nil })
                    } else {
                        AgentStepRow(step: step, number: index + 1, runner: runner, onOpenSource: onOpenSource, onEdit: { editing = $0 })
                    }
                    if index < runner.steps.count - 1 { Divider() }
                }
                if adding {
                    AgentStepEditor(step: .blank, isNew: true, shellAllowed: shellAllowed,
                                    onSave: { runner.addStep($0); adding = false },
                                    onCancel: { adding = false })
                }
            }
            if let note = runner.note {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if runner.phase != .planning, runner.phase != .finished, runner.phase != .cancelled {
                controls
            }
            if !runner.answerText.isEmpty {
                Divider()
                Markdown(MessageRow.linkCitations(in: runner.answerText))
                    .markdownTheme(.basic)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: 720, alignment: .leading)
        .onChange(of: runner.phase) { _, phase in
            if phase != .reviewing, phase != .running { adding = false }
        }
    }

    // MARK: - Header and controls

    private var header: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if runner.isReplanning {
                ProgressView().controlSize(.mini)
                Text("Re-planning…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !runner.hints.isEmpty {
                Text("\(runner.hints.count) hint\(runner.hints.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(runner.hints.joined(separator: "\n"))
            }
        }
    }

    private var title: String {
        let total = runner.steps.count
        switch runner.phase {
        case .planning: return "Planning"
        case .reviewing: return "Plan: \(total) sub-task\(total == 1 ? "" : "s"). Review or edit, then run."
        case .running:
            let done = runner.steps.filter { $0.status.isTerminal }.count
            if runner.steps.contains(where: { $0.status == .waitingForUser }) { return "Waiting for your reply" }
            return "Running sub-task \(min(done + 1, total)) of \(total)"
        case .consolidating: return "Writing the answer from \(total) finding\(total == 1 ? "" : "s")…"
        case .finished: return "Done"
        case .cancelled: return "Stopped"
        case .failed(let message): return message
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Steer", text: $hint, prompt: Text(runner.phase == .reviewing ? "Change the plan, e.g. “projects live in Work, ignore Archive”" : "Steer the remaining steps…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendHint)
                Button("Steer", action: sendHint)
                    .disabled(hint.trimmingCharacters(in: .whitespaces).isEmpty || runner.isReplanning)
            }
            HStack(spacing: 8) {
                Button { adding = true } label: { Label("Add step", systemImage: "plus") }
                    .disabled(adding)
                Spacer()
                if runner.phase == .reviewing {
                    Button("Cancel") { runner.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button { runner.approve() } label: { Label("Run plan", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(runner.steps.isEmpty || editing != nil || adding || runner.isReplanning)
                } else {
                    Button(role: .destructive) { runner.cancel() } label: { Label("Stop all", systemImage: "stop.fill") }
                }
            }
        }
        .controlSize(.small)
    }

    private func sendHint() {
        let text = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runner.steer(text)
        hint = ""
    }
}
