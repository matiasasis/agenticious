import SwiftUI

extension Subagent.State {
    var color: Color {
        switch self {
        case .running: AgenticiousStyle.lime
        case .done: .green
        case .failed: .orange
        case .stopped: .brown
        }
    }
}

/// An agent's Claude subagents, nested under its sidebar card. Running ones stay in view; the rest fold away.
struct SubagentStack: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    @State private var showsEnded = false

    var body: some View {
        let running = session.subagents.filter { $0.state == .running }
        let ended = session.subagents.filter { $0.state != .running }
        if !session.subagents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(running) { row($0) }
                if !ended.isEmpty {
                    Button { showsEnded.toggle() } label: {
                        Label(summary(of: ended), systemImage: showsEnded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    if showsEnded { ForEach(ended.reversed()) { row($0) } }
                }
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(session.status.color.opacity(0.35)).frame(width: 2).padding(.leading, 6)
            }
        }
    }

    private func row(_ subagent: Subagent) -> some View {
        SubagentRow(subagent: subagent, isSelected: store.selection == .subagent(session.id, subagent.id)) {
            store.selection = .subagent(session.id, subagent.id)
        }
    }

    /// "1 done · 8 stopped"
    private func summary(of subagents: [Subagent]) -> String {
        [Subagent.State.done, .failed, .stopped].compactMap { state in
            let count = subagents.filter { $0.state == state }.count
            return count == 0 ? nil : "\(count) \(state.label.lowercased())"
        }.joined(separator: " · ")
    }
}

private struct SubagentRow: View {
    let subagent: Subagent
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(subagent.state.color).frame(width: 6, height: 6)
                    Text(subagent.displayTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(subagent.state.label).font(.system(size: 9, weight: .semibold)).foregroundStyle(subagent.state.color)
                }
                if let detail = subagent.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(subagent.state.color.opacity(isSelected ? 0.18 : 0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(subagent.state.color.opacity(isSelected ? 0.9 : isHovered ? 0.6 : 0.25), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovered = $0 }
        .help(subagent.type.isEmpty ? subagent.displayTitle : "\(subagent.type) subagent · \(subagent.displayTitle)")
    }
}

/// One subagent's own activity. It runs inside its agent, so this only watches; the agent's page has the controls.
struct SubagentDetailView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    let subagentID: String
    @State private var entries: [ActivityEntry] = []
    @State private var notice: String?
    @State private var isLoaded = false

    private var subagent: Subagent? { session.subagents.first { $0.id == subagentID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subagent {
                header(subagent)
                Divider()
                activity(isRunning: subagent.state == .running)
                    .task(id: "\(subagentID)-\(subagent.transcript?.path ?? "")-\(subagent.state == .running)") {
                        await follow(subagent.transcript, isRunning: subagent.state == .running)
                    }
            } else {
                ContentUnavailableView("Subagent not found", systemImage: "person.2.slash",
                                       description: Text("Its agent no longer lists it."))
            }
        }
    }

    private func header(_ subagent: Subagent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { store.selection = .session(session.id) } label: {
                Label(session.task.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Agent", systemImage: "chevron.left")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AgenticiousStyle.lime)
            .font(.callout)
            Text(subagent.displayTitle)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .textSelection(.enabled)
            HStack(spacing: 10) {
                if !subagent.type.isEmpty {
                    Text(subagent.type).font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AgenticiousStyle.violet.opacity(0.15), in: Capsule())
                        .foregroundStyle(AgenticiousStyle.violet)
                }
                Label(subagent.state.label, systemImage: "circle.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(subagent.state.color)
                    .labelStyle(SmallDotLabelStyle())
                Spacer()
            }
            Text("Runs inside this agent's process: pausing or ending the agent stops it too. Talk to it through the agent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func activity(isRunning: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    ForEach(entries) { ActivityCard(entry: $0, isRunning: isRunning) }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(20)
            }
            .overlay {
                if !isLoaded {
                    BackgroundTaskLabel(task: "Loading activity…")
                } else if entries.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "text.bubble",
                                           description: Text("Its messages and tool calls appear here once Claude writes them to its log."))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: entries) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
        }
        .background(AgenticiousStyle.ink)
    }

    /// Reads the subagent's log, and keeps reading it while it runs.
    private func follow(_ transcript: URL?, isRunning: Bool) async {
        guard let transcript else {
            notice = "Claude hasn't said where this subagent's log is yet."
            isLoaded = true
            return
        }
        var stamp: TranscriptStamp?
        let agent = session.agent
        let id = session.id
        let directory = session.directory.path
        while !Task.isCancelled {
            let lastStamp = stamp
            let result = await Task.detached(priority: .utility) {
                ActivityTranscript.read(agent: agent, sessionID: id, conversationID: nil, directory: directory, cached: transcript,
                                        stamp: lastStamp, chatPrompt: "", isSubagent: true)
            }.value
            guard !Task.isCancelled else { return }
            stamp = result.stamp
            if !result.isUnchanged {
                // Its "user" messages are what the agent asked of it.
                entries = result.entries.map { entry in
                    var entry = entry
                    if entry.kind == .userMessage { entry.title = "From the agent" }
                    return entry
                }
                notice = result.stamp == nil && !isRunning ? "This subagent's log isn't there anymore." : result.notice
            }
            isLoaded = true
            guard isRunning else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }
}

private struct SmallDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}
