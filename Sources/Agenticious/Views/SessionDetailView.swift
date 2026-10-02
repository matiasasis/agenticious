import AppKit
import SwiftTerm
import SwiftUI

/// The selected agent, embedded in the main window: big title, step boxes, why it needs you, and its live terminal.
struct SessionDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    @State private var showActivity = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TaskHeading(type: session.displayedTaskType, task: session.task, size: .large)
                    .textSelection(.enabled)

                HStack(spacing: 12) {
                    AgentBadge(agent: session.agent, detail: session.modelSummary)
                    StatusPill(status: session.status)
                    if !session.isChat, !session.chunks.isEmpty {
                        Text("\(session.completedChunks)/\(session.chunks.count) steps")
                            .foregroundStyle(.secondary)
                    }
                    if session.isChat && !session.isMarkedFinished {
                        Button(session.isArchiving ? "Ending chat…" : "End chat", systemImage: "stop.circle") { store.endChat(session) }
                            .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                            .disabled(!session.canEndChat)
                            .help("Stop the agent and save this conversation in Finished.")
                    } else {
                        Button(session.isArchiving ? "Archiving…" : "Archive", systemImage: "archivebox") { store.archive(session) }
                            .buttonStyle(PillButtonStyle())
                            .disabled(session.isArchiving)
                            .help(session.isArchiving ? "Archiving…" : "Stop the agent, clean up its worktree, and archive its history.")
                    }
                    if session.canStop && !session.isChat {
                        Button("Stop agent", systemImage: "stop.fill") { store.stop(session) }
                            .buttonStyle(PillButtonStyle(tint: .red))
                            .disabled(session.isArchiving)
                            .help("Stop the process without archiving its history.")
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

                if !session.pullRequests.isEmpty {
                    PullRequestLinks(references: session.pullRequests).id(session.id)
                }

                if !session.isChat, !session.startupSteps.isEmpty {
                    StartupProgressView(steps: session.startupSteps)
                } else if !session.isChat, session.backgroundTask == nil, session.startupPrompt == nil {
                    ChunkStrip(chunks: session.chunks, style: .expanded, isRunning: session.isRunning)
                }
                if let task = session.backgroundTask {
                    BackgroundTaskLabel(task: task)
                } else {
                    statusBanner
                }
            }
            .padding(20)
            .background(AgenticiousStyle.panel)

            Divider()

            HStack(spacing: 8) {
                Button(session.isChat ? "Chat" : "Activity", systemImage: "text.bubble") { showActivity = true }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: showActivity, isCompact: true))
                Button("Terminal", systemImage: "terminal") { showActivity = false }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: !showActivity, isCompact: true))
                Spacer()
                if session.pendingQuestion != nil, !showActivity {
                    Button("Answer in Activity", systemImage: "questionmark.bubble") { showActivity = true }
                        .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                } else if session.pendingQuestion == nil, !session.canReplyInline,
                          session.status.needsAttention || session.status == .yourTurn {
                    Button(session.startupPrompt == nil ? "Approve in terminal" : "Review startup prompt", systemImage: "arrow.right") { showActivity = false }
                        .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                }
            }.padding(12).background(AgenticiousStyle.panel)
            if showActivity {
                ActivityView(session: session) { showActivity = false }
            } else if session.terminalView == nil, let task = session.backgroundTask {
                ContentUnavailableView { Label(task, systemImage: "hourglass") } description: {
                    Text("The terminal opens once \(session.agent.displayName) is running.")
                }
            } else if session.terminalView == nil {
                ContentUnavailableView(
                    "Not running", systemImage: "moon.zzz",
                    description: Text("Resume to reopen \(session.agent.displayName)'s conversation, with everything it already knows.")
                )
            } else {
                TerminalContainer(session: session)
            }
            if session.isMarkedFinished || session.canMarkFinished {
                HStack {
                    Text(session.isMarkedFinished ? "History saved in Finished." : "Finishing stops the agent and cleans up its worktree.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(session.archiveActionTitle, systemImage: session.archiveActionSymbol) {
                        store.markFinished(session, finished: !session.isMarkedFinished)
                    }
                    .buttonStyle(AgenticiousButtonStyle())
                    .disabled(session.isArchiving)
                    .help("Keep history and clean up resources. Worktrees with uncommitted changes are preserved.")
                }
                .padding(14).background(AgenticiousStyle.panel)
            }
        }
        .onChange(of: session.startupPrompt, initial: true) { _, prompt in
            if prompt != nil { showActivity = false }
        }
        .onChange(of: session.pendingQuestion?.toolUseID, initial: true) { _, id in
            if id != nil { showActivity = true }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch session.status {
        case let .needsYou(reason):
            Banner(title: "Needs you", text: reason, systemImage: "hand.raised.fill", color: .orange)
        case .waiting:
            Banner(title: "Waiting", text: "\(session.agent.displayName) has background work or a scheduled wakeup. No input needed.",
                   systemImage: "clock", color: .teal)
        case .yourTurn:
            Banner(title: "Your turn", text: "\(session.agent.displayName) replied and is waiting for your next message.",
                   systemImage: "text.bubble", color: .purple)
        case let .done(summary):
            Banner(title: "Done", text: summary ?? "The agent marked the task complete.", systemImage: "checkmark.seal.fill", color: .green)
        case let .ended(reason):
            Banner(title: "Ended", text: reason, systemImage: "stop.circle.fill", color: .gray)
        case let .exited(code):
            Banner(title: "Exited", text: "The agent process ended (code \(code.map(String.init) ?? "?")).",
                   systemImage: "stop.circle", color: .secondary)
        case .interrupted:
            Banner(title: "Interrupted", text: session.isMarkedFinished
                   ? "This agent was interrupted. Resume to continue where it left off."
                   : "Agenticious closed while this agent was running. Resume to continue, or Archive to put it away.",
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

    func makeNSView(context: Context) -> PaddedTerminalHost {
        PaddedTerminalHost()
    }

    func updateNSView(_ container: PaddedTerminalHost, context: Context) {
        guard let terminal = session.terminalView, terminal.superview !== container else { return }

        // Resuming swaps in a new terminal; drop the one whose process ended.
        container.subviews.forEach { $0.removeFromSuperview() }
        container.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
        container.addSubview(terminal)
        container.needsLayout = true
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
    }
}

/// Insets the terminal from the pane edges and fills the margin with the terminal's background,
/// so the text gets breathing room without a visible seam.
final class PaddedTerminalHost: NSView {
    private let padding = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let inner = NSRect(
            x: padding.left, y: padding.bottom,
            width: max(0, bounds.width - padding.left - padding.right),
            height: max(0, bounds.height - padding.top - padding.bottom)
        )
        subviews.forEach { $0.frame = inner }
    }
}
