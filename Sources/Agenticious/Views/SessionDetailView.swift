import AppKit
import SwiftTerm
import SwiftUI

/// The selected agent, embedded in the main window: big title, step boxes, why it needs you, and its live terminal.
struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.task)
                    .font(.system(size: 26, weight: .bold))
                    .textSelection(.enabled)
                    .lineLimit(4)

                HStack(spacing: 12) {
                    AgentBadge(agent: session.agent, detail: session.modelSummary)
                    StatusPill(status: session.status)
                    if !session.chunks.isEmpty {
                        Text("\(session.completedChunks)/\(session.chunks.count) steps")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !session.isRunning {
                        Button("Resume", systemImage: "play.fill") { store.resume(session) }
                            .buttonStyle(AgenticiousButtonStyle())
                            .disabled(!session.canResume)
                            .help("Reopen this agent's conversation where it left off.")
                    }
                    if let worktree = session.worktree { BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved) }
                    Label(session.project.path ?? "No project", systemImage: session.project.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                ChunkStrip(chunks: session.chunks, style: .expanded, isRunning: session.isRunning)
                statusBanner
            }
            .padding(20)
            .background(AgenticiousStyle.panel)

            Divider()

            if session.terminalView == nil {
                ContentUnavailableView(
                    "Not running", systemImage: "moon.zzz",
                    description: Text("Resume to reopen \(session.agent.displayName)'s conversation, with everything it already knows.")
                )
            } else {
                TerminalContainer(session: session)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch session.status {
        case let .needsYou(reason):
            Banner(title: "Needs you", text: reason, systemImage: "hand.raised.fill", color: .orange)
        case .yourTurn:
            Banner(title: "Your turn", text: "\(session.agent.displayName) replied and is waiting for your next message.",
                   systemImage: "text.bubble", color: .purple)
        case let .done(summary):
            Banner(title: "Done", text: summary ?? "The agent marked the task complete.", systemImage: "checkmark.seal.fill", color: .green)
        case let .exited(code):
            Banner(title: "Exited", text: "The agent process ended (code \(code.map(String.init) ?? "?")).",
                   systemImage: "stop.circle", color: .secondary)
        case .interrupted:
            Banner(title: "Interrupted", text: "Agenticious closed while this agent was running. Resume to pick up where it left off.",
                   systemImage: "pause.circle", color: .brown)
        default:
            EmptyView()
        }
    }
}

private struct Banner: View {
    let title: String
    let text: String
    let systemImage: String
    let color: SwiftUI.Color

    var body: some View {
        Label {
            Text(title).fontWeight(.semibold) + Text(" · ") + Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Hosts the session's long-lived terminal view. The view is owned by the session, so switching agents
/// in the sidebar re-attaches to the same running process instead of starting a new one.
struct TerminalContainer: NSViewRepresentable {
    @ObservedObject var session: AgentSession

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = session.terminalView, terminal.superview !== container else { return }

        // Resuming swaps in a new terminal; drop the one whose process ended.
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}
