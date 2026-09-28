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

extension SessionStatus {
    var color: Color {
        switch self {
        case .starting: .gray
        case .working: AgenticiousStyle.lime
        case .waiting: .teal
        case .needsYou: .orange
        case .yourTurn: AgenticiousStyle.violet
        case .done: .green
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(chunks.prefix(limit)) { chunk in
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
                Text("+\(chunks.count - limit) more").font(.caption).foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(chunk.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chunk.status.color.opacity(0.5)))
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
        HStack(spacing: 18) {
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
    }
}

private struct LimitGauge: View {
    let limit: UsageLimit
    let source: String

    var body: some View {
        let percent = limit.currentPercent

        VStack(alignment: .leading, spacing: 2) {
            Text("\(limit.windowLabel) \(Int(percent.rounded()))%")
                .font(.caption)
                .monospacedDigit()
            ProgressView(value: min(percent, 100), total: 100)
                .tint(percent >= 90 ? .red : percent >= 70 ? .orange : .accentColor)
                .frame(width: 80)
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
