import SwiftUI
import MarkdownUI

/// One sub-task while the run is live: status, tool, trace, finding, and the controls to stop, edit or re-run it.
struct AgentStepRow: View {
    let step: AgentStep
    let number: Int
    let runner: AgentRunner
    var onOpenSource: ((Citation) -> Void)?
    let onEdit: (AgentStep) -> Void

    @State private var showTrace = false
    @State private var replyText = ""

    private var isLive: Bool { runner.phase != .reviewing }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AgentStatusIcon(status: step.status)
                Text("\(number). \(step.title)")
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                controls
            }
            HStack(spacing: 8) {
                AgentToolBadge(tool: step.tool, outsideScope: runner.isOutsideScope(step))
                if !step.trace.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { showTrace.toggle() } } label: {
                        Label("Trace (\(step.trace.count))", systemImage: showTrace ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 24)
            if step.instruction != step.title {
                Text(step.instruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 24)
            }
            if showTrace || step.status == .running {
                AgentTraceLines(entries: step.trace)
                    .padding(.leading, 24)
            }
            if step.status == .waitingForUser {
                replyField.padding(.leading, 24)
            }
            if !step.finding.isEmpty {
                finding.padding(.leading, 24)
            }
            if let error = step.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch step.status {
            case .running, .waitingForUser:
                Button { runner.stopStep(step.id) } label: { Image(systemName: "stop.fill") }
                    .help("Stop this step")
            case .pending:
                Button { onEdit(step) } label: { Image(systemName: "pencil") }
                    .help("Edit this step")
                if isLive {
                    Button { runner.stopStep(step.id) } label: { Image(systemName: "forward.end") }
                        .help("Skip this step")
                }
                Button { runner.removeStep(step.id) } label: { Image(systemName: "minus.circle") }
                    .help("Remove this step")
            case .done, .stopped, .failed:
                Button { onEdit(step) } label: { Image(systemName: "pencil") }
                    .help("Edit and run again")
                Button { runner.rerunStep(step.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Run again")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private var replyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.tool.query)
                .font(.callout)
            HStack {
                TextField("Your reply", text: $replyText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendReply)
                Button("Reply", action: sendReply)
                    .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var finding: some View {
        AgentFindingView(finding: step.finding, citations: step.citations, onOpen: onOpenSource)
    }

    private func sendReply() {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        runner.answer(text, for: step.id)
        replyText = ""
    }
}
