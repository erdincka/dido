import SwiftUI
import MarkdownUI

/// The sub-tasks behind a saved answer: collapsed to one line, expanded to each step's tool, finding and trace.
struct AgentTraceView: View {
    let trace: AgentTrace
    var onOpen: ((Citation) -> Void)?

    @State private var expanded = false

    private var summary: String {
        let done = trace.steps.filter { $0.status == .done }.count
        var text = "\(trace.steps.count) sub-task\(trace.steps.count == 1 ? "" : "s")"
        if done < trace.steps.count { text += ", \(done) completed" }
        if !trace.hints.isEmpty { text += " · \(trace.hints.count) hint\(trace.hints.count == 1 ? "" : "s")" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                Label(summary, systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if expanded {
                ForEach(Array(trace.steps.enumerated()), id: \.element.id) { index, step in
                    AgentTraceStep(step: step, number: index + 1, onOpen: onOpen)
                    if index < trace.steps.count - 1 { Divider() }
                }
                if let note = trace.note {
                    Label(note, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary)
                }
                if !trace.hints.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hints you gave").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(trace.hints, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .frame(maxWidth: 640, alignment: .leading)
        .onAppear { if AppState.shared.debugExpandWhy { expanded = true } }
    }
}

private struct AgentTraceStep: View {
    let step: AgentStep
    let number: Int
    var onOpen: ((Citation) -> Void)?

    @State private var showTrace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                AgentStatusIcon(status: step.status)
                Text("\(number). \(step.title)").font(.caption.weight(.medium))
                Spacer()
                AgentToolBadge(tool: step.tool)
            }
            if !step.finding.isEmpty {
                AgentFindingView(finding: step.finding, citations: step.citations, onOpen: onOpen, fontScale: 0.8)
                    .padding(.leading, 24)
            }
            if let error = step.error {
                Text(error).font(.caption2).foregroundStyle(.red).padding(.leading, 24)
            }
            if !step.trace.isEmpty {
                Button { withAnimation(.easeInOut(duration: 0.15)) { showTrace.toggle() } } label: {
                    Label("Trace (\(step.trace.count))", systemImage: showTrace ? "chevron.down" : "chevron.right").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 24)
                if showTrace {
                    AgentTraceLines(entries: step.trace).padding(.leading, 24)
                }
            }
        }
    }
}
