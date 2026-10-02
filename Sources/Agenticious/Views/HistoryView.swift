import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        let page = store.history.results(in: store.sessions)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Finished and archived agents, newest first.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back to queue", systemImage: "arrow.left") { store.show(.queue) }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks, workspaces, branches or providers", text: $store.history.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search history")
                if !store.history.search.isEmpty {
                    Button("Clear search", systemImage: "xmark.circle.fill") { store.history.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            if page.total == 0 {
                ContentUnavailableView {
                    Label(store.history.search.isEmpty ? "No history yet" : "No matching agents",
                          systemImage: "clock.arrow.circlepath")
                } description: {
                    Text(store.history.search.isEmpty ? "Archived agents will appear here." : "Try another task, workspace, branch or provider.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(page.sessions) { session in
                            Button { store.selection = .session(session.id) } label: {
                                HistoryRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { SessionMenu(session: session) }
                        }
                    }
                }
                .id("\(store.history.search):\(page.number)")
            }
            HStack(spacing: 12) {
                Text(page.summary).foregroundStyle(.secondary)
                Spacer()
                Button("Previous") { store.history.page = page.number - 1 }
                    .disabled(page.number == 1)
                Text("Page \(page.number) of \(page.count)").monospacedDigit()
                Button("Next") { store.history.page = page.number + 1 }
                    .disabled(page.number == page.count)
            }
            .font(.callout)
        }
        .padding(24)
    }
}

private struct HistoryRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(session.project.name, systemImage: session.project.symbol)
                    .lineLimit(1)
                Spacer()
                Text(session.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            }
            .font(.caption).foregroundStyle(.secondary)
            TaskHeading(type: session.displayedTaskType, task: session.task, size: .compact)
            HStack {
                AgentBadge(agent: session.agent, detail: session.modelSummary)
                Spacer()
                StatusPill(status: session.status)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}
