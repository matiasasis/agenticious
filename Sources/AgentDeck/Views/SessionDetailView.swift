import AppKit
import SwiftTerm
import SwiftUI

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
                        Text("\(session.completedChunks)/\(session.chunks.count) chunks")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(session.directory.path, systemImage: "folder")
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
        .navigationTitle(session.task)
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch session.status {
        case let .needsYou(reason):
            Banner(text: reason, systemImage: "hand.raised.fill", color: .orange)
        case let .done(summary?):
            Banner(text: summary, systemImage: "checkmark.seal.fill", color: .green)
        case let .exited(code):
            Banner(text: "Agent process exited (code \(code.map(String.init) ?? "?"))", systemImage: "stop.circle", color: .secondary)
        default:
            EmptyView()
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String
    let color: SwiftUI.Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(color)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Hosts the session's long-lived terminal view. The view is owned by the session, not by this window,
/// so closing and reopening the window re-attaches to the same running agent.
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
