import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
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
        case .working: .blue
        case .needsYou: .orange
        case .yourTurn: .purple
        case .done: .green
        case .exited: .secondary
        }
    }
}

struct ChunkStrip: View {
    enum Style { case compact, expanded }

    let chunks: [Chunk]
    let style: Style

    var body: some View {
        if chunks.isEmpty {
            Text("Waiting for the agent's plan…")
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
        case .inProgress: .blue
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
        HStack(spacing: 14) {
            ForEach(Array(usage.codexLimits.enumerated()), id: \.offset) { _, limit in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex \(windowLabel(limit.windowMinutes)): \(Int(limit.usedPercent))%")
                        .font(.caption)
                    ProgressView(value: min(limit.usedPercent, 100), total: 100)
                        .tint(limit.usedPercent >= 90 ? .red : .accentColor)
                        .frame(width: 110)
                }
                .help(limit.resetsAt.map { "Resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }

            if let tokens = usage.claudeTokensToday {
                Text("Claude today: \(tokens.formatted(.number.notation(.compactName))) tok")
                    .font(.caption)
                    .help("Input + output + cache-write tokens since midnight, read from ~/.claude/projects. An estimate, not your plan quota.")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 10080: "week"
        case 300: "5h"
        case 0: "limit"
        default: minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
        }
    }
}
