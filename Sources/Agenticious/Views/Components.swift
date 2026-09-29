import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind
    var detail: String?

    var body: some View {
        Text([agent.displayName, detail].compactMap { $0 }.joined(separator: " · "))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color { agent == .claude ? .orange : .teal }
}

struct BranchLabel: View {
    let worktree: Worktree
    var isRemoved = false

    var body: some View {
        Label(worktree.branch, systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
            .strikethrough(isRemoved)
            .lineLimit(1)
            .help(isRemoved ? "Worktree deleted; the branch is kept." : worktree.path)
    }
}

struct StatusPill: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(status.label)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.15), in: Capsule())
    }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
            .help(status.label)
    }
}

extension AgentSession {
    var archiveActionTitle: String {
        if isMarkedFinished { return "Move to Queue" }
        return "Mark as finished"
    }

    var archiveActionSymbol: String {
        if isMarkedFinished { return "arrow.uturn.backward" }
        return "checkmark.circle"
    }
}

extension SessionStatus {
    var color: Color {
        switch self {
        case .starting: .gray
        case .working: AgenticiousStyle.lime
        case .waiting: .teal
        case .needsYou: .orange
        case .yourTurn: AgenticiousStyle.violet
        case .done: .green
        case .ended: .gray
        case .exited: .secondary
        case .interrupted: .brown
        }
    }
}

struct ChunkStrip: View {
    enum Style { case compact, expanded }

    let chunks: [Chunk]
    let style: Style
    /// An agent that isn't running won't post a plan, so don't say we're waiting for one.
    var isRunning = true

    var body: some View {
        if chunks.isEmpty {
            Text(isRunning ? "Waiting for the agent's plan…" : "No plan")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if style == .compact {
            HStack(spacing: 4) {
                ForEach(chunks) { chunk in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(chunk.status.color.opacity(chunk.status == .pending ? 0.3 : 0.9))
                        .frame(height: 8)
                        .help("\(chunk.id). \(chunk.title)")
                }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(chunks) { chunk in ChunkBox(chunk: chunk) }
            }
        }
    }
}

/// The steps as a short checklist, each coloured by its status, for cards.
struct ChunkList: View {
    let chunks: [Chunk]
    let limit: Int

    /// An overflowing list gives its last row to the count, so it never grows past `limit` rows.
    private var shown: Int { chunks.count > limit ? limit - 1 : limit }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(chunks.prefix(shown)) { chunk in
                Label {
                    Text(chunk.title)
                        .foregroundStyle(chunk.status == .pending ? .secondary : .primary)
                } icon: {
                    Image(systemName: chunk.status.symbol).foregroundStyle(chunk.status.color)
                }
                .font(.callout)
                .lineLimit(1)
            }
            if chunks.count > limit {
                Label("\(chunks.count - shown) more steps", systemImage: "ellipsis.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ChunkBox: View {
    let chunk: Chunk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: chunk.status.symbol)
                Text("\(chunk.id)")
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(chunk.status.color)

            Text(chunk.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)

            if let note = chunk.note {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        .background(chunk.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chunk.status.color.opacity(0.5)))
        .help([chunk.title, chunk.note].compactMap { $0 }.joined(separator: "\n"))
    }
}

extension ChunkStatus {
    var color: Color {
        switch self {
        case .pending: .gray
        case .inProgress: AgenticiousStyle.lime
        case .done: .green
        case .blocked: .orange
        }
    }

    var symbol: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        }
    }
}

struct UsageBar: View {
    @EnvironmentObject private var usage: UsageMonitor

    var body: some View {
        HStack(spacing: 10) {
            if let claude = usage.claudeReading {
                vendor("Claude", claude.limits, source: "Read \(claude.takenAt.formatted(.relative(presentation: .named))) " +
                    "from the status line of a Claude agent started here.")
            } else if let tokens = usage.claudeTokensToday {
                Text("Claude today: \(tokens.formatted(.number.notation(.compactName))) tok")
                    .font(.caption)
                    .help("Input + output + cache-write tokens since midnight, read from ~/.claude/projects. " +
                        "Your session and weekly limits show up here once a Claude agent started from Agenticious replies.")
            }

            if !usage.codexLimits.isEmpty {
                vendor("Codex", usage.codexLimits, source: "Read from Codex's latest session log.")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func vendor(_ name: String, _ limits: [UsageLimit], source: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption.weight(.semibold))
            ForEach(limits, id: \.windowMinutes) { LimitGauge(limit: $0, source: source) }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
    }
}

private struct LimitGauge: View {
    let limit: UsageLimit
    let source: String

    var body: some View {
        let percent = limit.currentPercent

        VStack(alignment: .leading, spacing: 2) {
            Text("\(limit.windowLabel) \(Int(percent.rounded()))%")
                .font(.system(size: 10))
                .monospacedDigit().lineLimit(1)
            ProgressView(value: min(percent, 100), total: 100)
                .tint(percent >= 90 ? .red : percent >= 70 ? .orange : AgenticiousStyle.lime)
                .frame(width: 62)
        }
        .help([resetText, source].compactMap { $0 }.joined(separator: "\n"))
    }

    private var resetText: String? {
        guard let resetsAt = limit.resetsAt else { return nil }
        if limit.hasReset { return "Reset \(resetsAt.formatted(.relative(presentation: .named))), so it's back to 0%." }

        let relative = resetsAt.formatted(.relative(presentation: .named))
        return "Resets \(relative) (\(resetsAt.formatted(date: .abbreviated, time: .shortened)))."
    }
}

struct PullRequestLinks: View {
    let references: [PullRequestReference]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(references) { reference in
                    Link(destination: reference.url) {
                        Label(reference.label, systemImage: "arrow.triangle.pull")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(AgenticiousStyle.violet.opacity(0.12), in: Capsule())
                    }
                    .foregroundStyle(AgenticiousStyle.violet)
                    .help(reference.url.absoluteString)
                    .linkCursor()
                }
            }
        }.scrollIndicators(.hidden)
    }
}

struct ControlRoomBar: View {
    @EnvironmentObject private var store: SessionStore
    let project: Project

    var body: some View {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("CONTROL ROOM").font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1).foregroundStyle(AgenticiousStyle.violet)
                    Spacer(minLength: 8)
                    AgentCounters()
                    UsageBar()
                }
                HStack(spacing: 10) {
                    AgentCounters()
                    UsageBar()
                }
                UsageBar()
            }
            Spacer(minLength: 0)
            ProviderStatusButton().buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true)).labelStyle(.iconOnly)
            Button("Summon agent", systemImage: "plus") { store.composer = Composer(project: project) }
                .labelStyle(.titleAndIcon).keyboardShortcut("n")
                .buttonStyle(AgenticiousButtonStyle()).fixedSize()
                .help("Summon an agent · ⌘N")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(AgenticiousStyle.ink)
        .overlay(alignment: .bottom) { Rectangle().fill(AgenticiousStyle.violet.opacity(0.25)).frame(height: 1) }
    }
}

/// Queued, running and needs-you counts for the list being shown; the Finished list shows only its total.
private struct AgentCounters: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        HStack(spacing: 10) {
            DashboardMetric(title: store.agentList == .queue ? "QUEUED" : "FINISHED", value: store.visibleSessions.count,
                            color: AgenticiousStyle.violet)
            if store.agentList == .queue {
                DashboardMetric(title: "RUNNING", value: store.visibleSessions.filter(\.isRunning).count, color: AgenticiousStyle.lime)
                DashboardMetric(title: "NEEDS YOU", value: store.attentionCount, color: .orange)
            }
        }
    }
}

struct TaskHeading: View {
    let type: TaskType
    let task: String
    var isCompact = false

    var body: some View {
        let details = type.details(for: task)
        HStack(alignment: .top, spacing: isCompact ? 8 : 10) {
            TaskTypeIcon(type: type)
            VStack(alignment: .leading, spacing: 4) {
                Text(type.name)
                    .font(isCompact ? .system(size: 13, weight: .semibold) : .title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !details.isEmpty {
                    Text(details)
                        .font(isCompact ? .system(size: 11) : .callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .help([type.name, details].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

struct TaskTypeIcon: View {
    let type: TaskType

    var body: some View {
        Image(systemName: NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil) == nil ? "sparkles" : type.symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AgenticiousStyle.violet)
            .frame(width: 26, height: 26)
            .background(AgenticiousStyle.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            .help(type.name)
            .accessibilityLabel(type.name)
    }
}

/// Grays a card out while the app works on its agent in the background, with a spinner saying what it's doing.
struct BackgroundTaskOverlay: ViewModifier {
    let task: String?
    var isCompact = false

    func body(content: Content) -> some View {
        content
            .saturation(task == nil ? 1 : 0)
            .opacity(task == nil ? 1 : 0.45)
            .overlay {
                if let task { BackgroundTaskLabel(task: task, isCompact: isCompact) }
            }
            .animation(.easeInOut(duration: 0.2), value: task)
    }
}

struct BackgroundTaskLabel: View {
    let task: String
    var isCompact = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(task).font(isCompact ? .caption.weight(.semibold) : .callout.weight(.semibold))
        }
        .padding(.horizontal, isCompact ? 10 : 14).padding(.vertical, isCompact ? 6 : 8)
        .background(AgenticiousStyle.panel, in: Capsule())
        .overlay(Capsule().stroke(AgenticiousStyle.violet.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func backgroundTask(_ task: String?, isCompact: Bool = false) -> some View {
        modifier(BackgroundTaskOverlay(task: task, isCompact: isCompact))
    }
}
