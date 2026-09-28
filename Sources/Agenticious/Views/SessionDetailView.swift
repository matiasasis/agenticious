import AppKit
import SwiftTerm
import SwiftUI

/// The selected agent, embedded in the main window: big title, step boxes, why it needs you, and its live terminal.
struct SessionDetailView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.task)
                    .font(.system(size: 26, weight: .bold))
                    .textSelection(.enabled)
                    .lineLimit(4)

                HStack(spacing: 12) {
                    AgentBadge(agent: session.agent)
                    StatusPill(status: session.status)
                    if !session.chunks.isEmpty {
                        Text("\(session.completedChunks)/\(session.chunks.count) steps")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let worktree = session.worktree { BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved) }
                    Label(session.project.path ?? "No project", systemImage: session.project.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                ChunkStrip(chunks: session.chunks, style: .expanded)
                statusBanner
            }
            .padding()

            Divider()

            TerminalContainer(session: session)
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

        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}
