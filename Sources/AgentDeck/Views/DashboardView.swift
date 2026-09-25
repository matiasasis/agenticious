import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingNewTask = false

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.serverError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(8)
            }
            content
        }
        .sheet(isPresented: $isShowingNewTask) { NewTaskSheet() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("AgentDeck").font(.title2.bold())
            AttentionSummary()
            Spacer()
            UsageBar()
            Button("New Agent", systemImage: "plus") { isShowingNewTask = true }
                .keyboardShortcut("n")
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if store.sessions.isEmpty {
            ContentUnavailableView("No agents running", systemImage: "square.grid.2x2",
                                   description: Text("Press ⌘N to give an agent a task."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.sortedSessions) { session in
                        SessionCard(session: session)
                            .onTapGesture { openWindow(value: session.id) }
                            .contextMenu {
                                Button("Open") { openWindow(value: session.id) }
                                Button("Stop agent") { store.stop(session) }
                                Button("Remove", role: .destructive) { store.remove(session) }
                            }
                    }
                }
                .padding()
            }
        }
    }
}

private struct AttentionSummary: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        if store.attentionCount > 0 {
            Label("\(store.attentionCount) need you", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
        } else if !store.sessions.isEmpty {
            Label("Nothing needs you", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct SessionCard: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AgentBadge(agent: session.agent)
                Spacer()
                StatusPill(status: session.status)
            }

            Text(session.task)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            ChunkStrip(chunks: session.chunks, style: .compact)

            if case let .needsYou(reason) = session.status {
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack {
                Label(session.directory.lastPathComponent, systemImage: "folder")
                Spacer()
                Text(session.startedAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(session.status.needsAttention ? Color.orange : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.sortedSessions) { session in
            Button("\(session.status.needsAttention ? "✋ " : "")\(session.task.prefix(60))") {
                openWindow(value: session.id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if !store.sessions.isEmpty { Divider() }
        Button("Open dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit AgentDeck") { NSApp.terminate(nil) }
    }
}
