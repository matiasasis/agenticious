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
                                                             body: session.displayedTaskType.details(for: session.task)),
                                         agent: session.agent)
                        }
                        ForEach(visibleEntries) { entry in ActivityCard(entry: entry, agent: session.agent, isRunning: session.isRunning) }
                        if session.isWorking && loadedSession == session.id { ReplyingIndicator(agent: session.agent) }
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
                .onChange(of: session.isWorking) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
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
    let agent: AgentKind
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

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .tool: Image(systemName: "terminal")
        case .userMessage: Image(systemName: "person.crop.circle.fill")
        case .message: ProviderIcon(agent: agent, size: 14)
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
            TrailingBubbleLayout(maxWidth: 620, leadingInset: 80) { card }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                icon.foregroundStyle(accent)
                Text(entry.displayTitle).font(.callout.weight(.semibold)).foregroundStyle(entry.kind == .message ? accent : .primary)
                if entry.kind == .tool {
                    Spacer()
                    Text(stateLabel).font(.caption.weight(.semibold)).foregroundStyle(color)
                }
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
        .padding(16).frame(maxWidth: entry.kind == .userMessage ? nil : .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(border))
        .onAppear { expanded = entry.state == .failed }
        .onChange(of: entry.state) { _, state in if state == .failed { expanded = true } }
    }
}

/// Stands in for the agent's next reply while it thinks, writes or runs tools.
private struct ReplyingIndicator: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(agent: agent, size: 14).foregroundStyle(AgenticiousStyle.lime)
            ProgressView().controlSize(.small)
            Text("Whiskering…").font(.callout.italic()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AgenticiousStyle.lime.opacity(0.3)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.displayName) is working")
    }
}

/// Pins a bubble to the trailing edge, only as wide as its content and at most `maxWidth`.
private struct TrailingBubbleLayout: Layout {
    let maxWidth: CGFloat
    let leadingInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let bubble = bubbleSize(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? bubble.width + leadingInset, height: bubble.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let bubble = bubbleSize(subviews, width: bounds.width)
        subviews.first?.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(bubble))
    }

    private func bubbleSize(_ subviews: Subviews, width: CGFloat?) -> CGSize {
        let available = width.map { min($0 - leadingInset, maxWidth) } ?? maxWidth
        return subviews.first?.sizeThatFits(ProposedViewSize(width: max(available, 0), height: nil)) ?? .zero
    }
}

private struct ActivityMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(text):
                    LinkedMarkdownText(text: text)
                case let .heading(level, text):
                    Text(inlineMarkdown(text)).font(headingFont(level)).textSelection(.enabled)
                        .padding(.top, level <= 2 ? 6 : 2)
                case let .list(items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text(item.marker).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                                LinkedMarkdownText(text: item.text)
                            }.padding(.leading, CGFloat(min(item.depth, 6)) * 16)
                        }
                    }
                case let .quote(text):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(AgenticiousStyle.violet.opacity(0.6)).frame(width: 3)
                        LinkedMarkdownText(text: text)
                    }.fixedSize(horizontal: false, vertical: true)
                case let .table(table):
                    MarkdownTableView(table: table)
                case let .code(code):
                    Text(code).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
                case let .diagram(diagram):
                    ScrollView(.horizontal) {
                        // Menlo's box-drawing glyphs fill the line, so borders join up; SF Mono's leave gaps.
                        Text(diagram).font(.custom("Menlo", size: 12)).textSelection(.enabled)
                            .fixedSize().padding(.vertical, 2)
                    }
                case .rule:
                    Divider()
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 20, weight: .bold)
        case 2: .system(size: 17, weight: .semibold)
        case 3: .system(size: 15, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            if !table.header.isEmpty {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in self.cell(cell, weight: .semibold) }
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                if index > 0 || !table.header.isEmpty { Divider().gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell).gridColumnAlignment(alignment(column))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    /// Wraps long cells onto more lines instead of truncating them.
    private func cell(_ text: String, weight: Font.Weight = .regular) -> some View {
        Text(inlineMarkdown(text)).font(.system(size: 13, weight: weight)).fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Inline Markdown for SwiftUI `Text`, with links in the app's violet.
private func inlineMarkdown(_ text: String) -> AttributedString {
    var parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    for run in parsed.runs where run.link != nil { parsed[run.range].foregroundColor = AgenticiousStyle.violet }
    return parsed
}
