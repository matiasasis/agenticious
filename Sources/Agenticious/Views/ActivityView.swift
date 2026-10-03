import AppKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var session: AgentSession
    let openTerminal: () -> Void
    @State private var entries: [ActivityEntry] = []
    @State private var notice: String?
    @State private var loadedSession: UUID?
    @State private var followLatest = true
    @State private var showResearch = false

    private var visibleEntries: [ActivityEntry] {
        session.isChat && !showResearch ? entries.filter { $0.kind != .tool } : entries
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(session.isChat ? "Conversation" : "Live activity", systemImage: session.isChat ? "bubble.left.and.bubble.right" : "waveform.path")
                    .font(.caption.weight(.semibold)).foregroundStyle(AgenticiousStyle.violet)
                Spacer()
                if session.isChat { Toggle("Research activity", isOn: $showResearch).toggleStyle(.checkbox).font(.caption) }
                Toggle("Follow latest", isOn: $followLatest).toggleStyle(.checkbox).font(.caption)
                Button("Respond in terminal", action: openTerminal).buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
            }.padding(12)
            if let question = session.pendingQuestion {
                ScrollView {
                    QuestionCard(session: session, questions: question.questions, openTerminal: openTerminal)
                        .id(question.toolUseID)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }
                .frame(maxHeight: 460)
                .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if session.isChat {
                            ActivityCard(entry: ActivityEntry(id: "opening-question", kind: .userMessage, title: "Your question",
                                                             body: session.displayedTaskType.details(for: session.task)))
                        }
                        ForEach(visibleEntries) { entry in ActivityCard(entry: entry, isRunning: session.isRunning) }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(20)
                }
                .overlay {
                    if loadedSession != session.id {
                        BackgroundTaskLabel(task: "Loading activity…")
                    } else if entries.isEmpty && !session.isChat {
                        ContentUnavailableView("No activity yet", systemImage: "text.bubble", description: Text("Messages and tool calls appear here when the provider writes them to this session’s log."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: entries) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            }
            if session.canReplyInline || (session.isChat && session.isRunning && !session.isMarkedFinished && session.pendingQuestion == nil) {
                ReplyComposer(session: session).id(session.id)
            }
        }
        .background(AgenticiousStyle.ink)
        .task(id: "\(session.id)-\(session.isMarkedFinished)") {
            if loadedSession != session.id {
                entries = []
                notice = nil
            }
            var cached: URL?
            var stamp: TranscriptStamp?
            var previousID = session.conversationID
            while !Task.isCancelled {
                let agent = session.agent
                let id = session.id
                let conversation = session.conversationID
                let directory = session.directory.path
                let chatPrompt = session.isChat ? session.prompt : nil
                if previousID != conversation { cached = nil; stamp = nil; previousID = conversation }
                let file = cached
                let lastStamp = stamp
                let result = await Task.detached(priority: .utility) {
                    ActivityTranscript.read(agent: agent, sessionID: id, conversationID: conversation, directory: directory,
                                            cached: file, stamp: lastStamp, chatPrompt: chatPrompt)
                }.value
                guard !Task.isCancelled else { return }
                cached = result.url
                stamp = result.stamp
                if !result.isUnchanged {
                    entries = result.entries
                    notice = result.notice
                }
                loadedSession = id
                if session.conversationID == nil, let conversation = result.conversationID {
                    session.objectWillChange.send()
                    session.conversationID = conversation
                    previousID = conversation
                }
                if session.isMarkedFinished { return }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

struct ActivityCard: View {
    let entry: ActivityEntry
    var isRunning = false
    @State private var expanded = false
    @State private var expandedInput = false

    private var color: Color {
        switch entry.state {
        case .failed: .orange
        case .running: isRunning ? AgenticiousStyle.lime : .secondary
        case .completed: AgenticiousStyle.lime
        case .unknown: AgenticiousStyle.violet
        }
    }

    private var stateLabel: String {
        switch entry.state {
        case .failed: "Failed"
        case .running: isRunning ? "Awaiting result" : "No result recorded"
        case .completed: "Completed"
        case .unknown: "Output received"
        }
    }

    private var icon: String {
        switch entry.kind {
        case .tool: "terminal"
        case .userMessage: "person.crop.circle.fill"
        case .message: "sparkles"
        }
    }

    private var accent: Color { entry.kind == .message ? AgenticiousStyle.lime : AgenticiousStyle.violet }

    private var fill: Color { entry.kind == .userMessage ? AgenticiousStyle.violet.opacity(0.2) : AgenticiousStyle.panel }

    private var border: Color {
        if entry.state == .failed { return .orange.opacity(0.5) }
        switch entry.kind {
        case .tool: return AgenticiousStyle.violet.opacity(0.2)
        case .userMessage: return AgenticiousStyle.violet.opacity(0.55)
        case .message: return AgenticiousStyle.lime.opacity(0.3)
        }
    }

    var body: some View {
        if entry.kind == .userMessage {
            HStack(spacing: 0) {
                Spacer(minLength: 80)
                card.frame(maxWidth: 620)
            }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(accent)
                Text(entry.displayTitle).font(.callout.weight(.semibold)).foregroundStyle(entry.kind == .message ? accent : .primary)
                Spacer()
                if entry.kind == .tool { Text(stateLabel).font(.caption.weight(.semibold)).foregroundStyle(color) }
            }
            if let directory = entry.directory {
                Label(directory, systemImage: "folder").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if entry.kind != .tool {
                ActivityMarkdown(text: entry.body)
            } else {
                HStack(alignment: .top) {
                    Text(entry.body).font(.system(size: 12, design: .monospaced)).foregroundStyle(AgenticiousStyle.lime)
                        .textSelection(.enabled).lineLimit(expandedInput ? nil : 10).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy command or input", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.body, forType: .string)
                    }.labelStyle(.iconOnly).buttonStyle(.plain).help("Copy command or input")
                }.padding(12).background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                if entry.body.count > 500 || entry.body.components(separatedBy: .newlines).count > 10 {
                    Button(expandedInput ? "Collapse input" : "Show full input") { expandedInput.toggle() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(AgenticiousStyle.violet)
                }
                if let file = entry.file, file.hasPrefix("/") {
                    Link(destination: URL(fileURLWithPath: file)) { Label(file, systemImage: "doc.text") }
                        .font(.caption).foregroundStyle(AgenticiousStyle.violet).linkCursor()
                }
                if !entry.output.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        Text(entry.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    } label: { Text("Output · \(entry.output.components(separatedBy: .newlines).count) lines").font(.caption) }
                    .tint(AgenticiousStyle.violet)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(border))
        .onAppear { expanded = entry.state == .failed }
        .onChange(of: entry.state) { _, state in if state == .failed { expanded = true } }
    }
}

private struct ActivityMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { index, block in
                if index.isMultiple(of: 2) {
                    LinkedMarkdownText(text: block)
                } else {
                    Text(block.components(separatedBy: "\n").dropFirst().joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
