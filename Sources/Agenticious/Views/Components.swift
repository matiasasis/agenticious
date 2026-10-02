import SwiftUI

struct AgentBadge: View {
    let agent: AgentKind
    var detail: String?

    /// One colour for every provider, kept out of the status palette; the logo and name tell them apart.
    private static let tint = Color.blue

    var body: some View {
        HStack(spacing: 5) {
            ProviderIcon(agent: agent, size: 11)
            Text(agent.displayName).font(.caption.weight(.semibold))
            if let detail {
                Text(detail).font(.caption2).opacity(0.75)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Self.tint.opacity(0.15), in: Capsule())
        .foregroundStyle(Self.tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([agent.displayName, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The provider's monochrome mark, tinted by the surrounding foreground style.
struct ProviderIcon: View {
    let agent: AgentKind
    var size: CGFloat = 24

    private static let images: [AgentKind: NSImage] = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { agent in
        let file = agent == .claude ? ("ClaudeIcon", "png") : ("CodexIcon", "svg")
        return (agent, Bundle.module.url(forResource: file.0, withExtension: file.1).flatMap(NSImage.init(contentsOf:)) ?? NSImage())
    })

    var body: some View {
        Image(nsImage: Self.images[agent] ?? NSImage())
            .renderingMode(.template)
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
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

struct StartupProgressView: View {
    let steps: [Chunk]
    var isCompact = false

    private var visibleSteps: [Chunk] {
        if isCompact { return steps.last(where: { $0.status == .inProgress }).map { [$0] } ?? [] }
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleSteps) { step in
                HStack(spacing: 8) {
                    if step.status == .inProgress {
                        ProgressView().controlSize(.mini).frame(width: 14)
                    } else {
                        Image(systemName: step.status.symbol).foregroundStyle(step.status.color).frame(width: 14)
                    }
                    Text(step.title)
                        .foregroundStyle(step.status == .inProgress ? .primary : .secondary)
                        .lineLimit(1)
                        .help(step.title)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(isCompact ? .caption : .callout)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ChunkGridLayout {
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
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails.toggle() } label: {
            ChunkHeading(chunk: chunk, titleLineLimit: 2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: ChunkGridLayout.cardHeight, maxHeight: ChunkGridLayout.cardHeight,
                       alignment: .leading)
                .background(chunk.status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(chunk.status.color.opacity(0.5)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(chunk.id): \(chunk.title), \(chunk.status.label)")
        .accessibilityHint("Show step details")
        .help("Show step details")
        .popover(isPresented: $showingDetails) { ChunkDetails(chunk: chunk) }
    }
}

struct ChunkDetails: View {
    let chunk: Chunk

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ChunkHeading(chunk: chunk)
                if let note = chunk.note, !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("No details yet.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 340)
        .frame(maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ChunkHeading: View {
    let chunk: Chunk
    var titleLineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Step \(chunk.id) · \(chunk.status.label)", systemImage: chunk.status.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(chunk.status.color)
            Text(chunk.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(titleLineLimit)
        }
    }
}

extension ChunkStatus {
    var label: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }

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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { vendors }
            VStack(alignment: .leading, spacing: 6) { vendors }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var vendors: some View {
        if let claude = usage.claudeReading {
            vendor("Claude", claude.limits, source: "Read \(claude.takenAt.formatted(.relative(presentation: .named))) " +
                "from the status line of a Claude agent started here.")
        } else if let tokens = usage.claudeTokensToday {
            Text("Claude today: \(tokens.formatted(.number.notation(.compactName))) tok")
                .font(.caption)
                .help("Input + output + cache-write tokens since midnight, read from ~/.claude/projects. " +
                    "Your session and weekly limits show up here once a Claude agent started from Agenticious replies.")
        }

        if !usage.codexLimits.isEmpty || usage.codexModelQuotas?.quotas.isEmpty == false {
            vendor("Codex", usage.codexLimits.account, source: "Read from Codex's latest session logs.") {
                ForEach(usage.codexModelQuotas?.quotas ?? []) { quota in
                    Divider().frame(height: 22)
                    CodexModelQuotaStatus(quota: quota, checkedAt: usage.codexModelQuotas?.checkedAt,
                                          isStale: usage.codexModelQuotasStale)
                }
                ForEach(usage.codexLimits.models, id: \.name) { model in
                    Divider().frame(height: 22)
                    Text(model.name)
                        .font(.caption2.weight(.semibold))
                        .help("\(model.name) has its own limit, separate from the rest of Codex.")
                    ForEach(model.limits, id: \.windowMinutes) {
                        LimitGauge(limit: $0, source: "Read from the latest Codex session that used \(model.name).")
                    }
                }
            }
        }
    }

    private func vendor(_ name: String, _ limits: [UsageLimit], source: String,
                        @ViewBuilder extra: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.caption.weight(.semibold))
            ForEach(limits, id: \.windowMinutes) { LimitGauge(limit: $0, source: source) }
            extra()
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
    }
}

struct CodexModelQuotaStatus: View {
    let quota: CodexModelQuota
    let checkedAt: Date?
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(quota.name).font(.caption2.weight(.semibold))
            Label(isStale ? "Last reported: \(quota.status)" : quota.status,
                  systemImage: isStale ? "clock" : quota.available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(isStale ? Color.secondary : quota.available ? AgenticiousStyle.lime : .orange)
            if !quota.available, let availableAt = quota.availableAt {
                Text("Resets \(availableAt.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
            }
        }
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        var lines = ["Model-specific quota status. Codex reports availability rather than a percentage."]
        if isStale { lines.append("The latest refresh failed; showing the last reported status.") }
        if let checkedAt { lines.append("Checked \(checkedAt.formatted(.relative(presentation: .named))).") }
        if let availableAt = quota.availableAt {
            lines.append("Available again \(availableAt.formatted(date: .abbreviated, time: .shortened)).")
        }
        return lines.joined(separator: "\n")
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
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExpanded {
                PullRequestFlowLayout {
                    ForEach(references) { reference in
                        link(reference)
                    }
                }
                toggle
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach((0...references.count).reversed(), id: \.self) { count in
                        HStack(spacing: 8) {
                            ForEach(references.prefix(count)) { reference in
                                link(reference)
                            }
                            if count < references.count { toggle }
                        }.fixedSize()
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggle: some View {
        Button(isExpanded ? "Show less" : "See all (\(references.count))",
               systemImage: isExpanded ? "chevron.up" : "chevron.down") {
            isExpanded.toggle()
        }
        .buttonStyle(PillButtonStyle(tint: AgenticiousStyle.violet))
    }

    private func link(_ reference: PullRequestReference) -> some View {
        Link(destination: reference.url) {
            Label(reference.label, systemImage: "arrow.triangle.pull")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(AgenticiousStyle.violet.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(AgenticiousStyle.violet)
        .help(reference.url.absoluteString)
        .linkCursor()
    }
}

private struct PullRequestFlowLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, layout.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: frames.map(\.maxX).max() ?? 0, height: y + rowHeight), frames)
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

struct AgentCounters: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        HStack(spacing: 6) {
            DashboardMetric(title: "AGENTS", value: store.visibleSessions.count, color: AgenticiousStyle.violet)
                .help("Agents in the sidebar, excluding history")
            DashboardMetric(title: "WORKING", value: store.workingCount, color: AgenticiousStyle.lime)
                .help("Agents starting or actively working; idle and waiting agents are excluded")
            DashboardMetric(title: "NEEDS YOU", value: store.attentionCount, color: .orange)
                .help("Agents blocked on your input or approval")
        }
    }
}

struct TaskHeading: View {
    enum Size { case compact, regular, large }

    let type: TaskType
    let task: String
    var size = Size.regular

    var body: some View {
        let details = type.details(for: task)
        HStack(alignment: .top, spacing: spacing) {
            TaskTypeIcon(type: type, size: size)
            VStack(alignment: .leading, spacing: size == .large ? 6 : 4) {
                Text(type.name)
                    .font(titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !details.isEmpty {
                    Text(details)
                        .font(detailsFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(size == .large ? 4 : 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .multilineTextAlignment(.leading)
        .help([type.name, details].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var spacing: CGFloat {
        switch size {
        case .compact: 8
        case .regular: 10
        case .large: 14
        }
    }

    private var titleFont: Font {
        switch size {
        case .compact: .system(size: 13, weight: .semibold)
        case .regular: .title3.weight(.semibold)
        case .large: .system(size: 26, weight: .bold)
        }
    }

    private var detailsFont: Font {
        switch size {
        case .compact: .system(size: 11)
        case .regular: .callout
        case .large: .title3
        }
    }
}

struct TaskTypeIcon: View {
    let type: TaskType
    var size = TaskHeading.Size.regular

    var body: some View {
        let isLarge = size == .large
        Image(systemName: NSImage(systemSymbolName: type.symbol, accessibilityDescription: nil) == nil ? "sparkles" : type.symbol)
            .font(.system(size: isLarge ? 20 : 13, weight: .semibold))
            .foregroundStyle(AgenticiousStyle.violet)
            .frame(width: isLarge ? 40 : 26, height: isLarge ? 40 : 26)
            .background(AgenticiousStyle.violet.opacity(0.12), in: RoundedRectangle(cornerRadius: isLarge ? 10 : 7))
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
