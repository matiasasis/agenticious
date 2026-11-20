import AppKit
import SwiftUI

/// A tool call Claude wants permission for, answered in place: what it would do, then Allow or Deny.
/// Everything that comes from the request is drawn as plain text, never as Markdown or a localized key.
struct PermissionCard: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    let request: PermissionRequest
    /// Requests queued behind this one.
    let waiting: Int
    let openTerminal: () -> Void
    @Environment(\.textScale) private var textScale
    /// The request the buttons have woken for. Kept by request, like the rest of this state, so nothing armed, seen
    /// or typed for one card ever counts for the next, even in the moment before its own state is set.
    @State private var armedFor: UUID?
    /// The request whose end has been on screen above the pinned buttons. Until then Allow is off: nobody approves a
    /// tail they never saw.
    @State private var endSeenFor: UUID?
    @State private var note = ""
    @State private var drawn = Drawn()

    private var isArmed: Bool { armedFor == request.id }
    private var hasSeenEnd: Bool { endSeenFor == request.id }
    private var blocks: [Block] { drawn.blocks(of: request) }
    /// Part of the request is too long to draw, so the card cannot stand in for Claude's own menu.
    private var isCut: Bool { blocks.contains { $0.omitted > 0 } }
    /// Only with the buttons pinned under the request: in a card that scrolls whole, they can be on screen without it.
    private func canAllow(_ pinned: Bool) -> Bool { pinned && isArmed && hasSeenEnd && !isCut }
    private var stops: Bool { request.stopsTurn(.deny(note: note)) }

    /// Whether Allow answers a click right now, for whatever hosts the card. The layout tests read it: a drawn button
    /// has no other way to say it is off.
    struct CanAllow: PreferenceKey {
        static let defaultValue = false
        static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
    }
    private var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // Allow and Deny stay pinned under the scrolling request only while the request keeps room to be read. In a
        // pane too short for both, the whole card scrolls and Allow is off: there the buttons can be on screen without
        // the request they would approve. Only the chosen layout is ever drawn, so its own `pinned` is the truth.
        ViewThatFits(in: .vertical) {
            PinnedAnswer(limit: 460 * textScale, least: 340 * textScale, room: 160 * textScale) {
                watchingEnd(ScrollView { details(pinned: true) }, wholeCard: false)
                VStack(alignment: .leading, spacing: 0) { answer(pinned: true) }
            }
            watchingEnd(ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    details(pinned: false)
                    answer(pinned: false)
                }
                .background(GeometryReader { Color.clear.preference(key: Ends.self, value: .init(card: $0.frame(in: .named(Ends.space)).maxY)) })
            }, wholeCard: true)
        }
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.6), lineWidth: 1.5))
        // The next card appears where the last one was: a click meant for that one must not answer this one.
        .task(id: request.id) {
            let id = request.id
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { armedFor = id }
        }
        .onChange(of: request.id) { _, _ in note = "" }
    }

    private func details(pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let file = request.file { fileLine(file) }
            ForEach(blocks) { block($0) }
            if let directory = request.directory {
                Label { Text(verbatim: PermissionText.visible(directory)) } icon: { Image(systemName: "folder") }
                    .scaledFont(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let always = request.alwaysAllow { alwaysRow(always, pinned: pinned) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { Color.clear.preference(key: Ends.self, value: .init(request: $0.frame(in: .named(Ends.space)).maxY)) })
    }

    /// Says so while anything is still below the fold, and in the pinned layout notes when the request's last line has
    /// been in view: a command padded with blank space looks finished long before it is.
    private func watchingEnd(_ scroller: some View, wholeCard: Bool) -> some View {
        scroller.coordinateSpace(name: Ends.space).overlayPreferenceValue(Ends.self) { ends in
            GeometryReader { port in
                // A sliver of a view shows nothing anyone could read.
                let isAtEnd = port.size.height > 8 && (wholeCard ? ends.card : ends.request) - port.size.height <= 1
                pill(isAtEnd ? nil : wholeCard || hasSeenEnd || isCut ? "↓ More below" : "↓ More below. Allow unlocks at the end.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .onChange(of: isAtEnd && !wholeCard ? request.id : nil, initial: true) { _, seen in if let seen { endSeenFor = seen } }
            }
            .allowsHitTesting(false)
        }
    }

    private func pill(_ text: String?) -> some View {
        Text(verbatim: text ?? "")
            .scaledFont(.caption.weight(.semibold)).foregroundStyle(.black)
            .padding(.horizontal, 10).padding(.vertical, 4).background(.orange, in: Capsule())
            .opacity(text == nil ? 0 : 1).padding(8)
    }

    @ViewBuilder private func answer(pinned: Bool) -> some View {
        Rectangle().fill(AgenticiousStyle.violet.opacity(0.2)).frame(height: 1)
        // Never taller than it needs: given spare height, it would take it from the pinned request's scroller, which
        // would then end a few points short of a request that is all on screen.
        footer(pinned: pinned).padding(.horizontal, 20).padding(.vertical, 14).fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let agentID = request.agentID {
                let name = session.subagents.first { $0.id == agentID }?.displayTitle ?? request.agentType ?? "Subagent"
                Text(verbatim: "SUBAGENT · \(PermissionText.visible(name).uppercased())")
                    .scaledFont(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(AgenticiousStyle.violet)
            }
            HStack {
                Label { Text(verbatim: "\(session.agent.displayName) asks permission · \(request.title)") } icon: { Image(systemName: "lock.shield.fill") }
                    .scaledFont(.headline).foregroundStyle(.orange)
                Spacer()
                Button("Answer in terminal instead") {
                    store.answerInTerminal([request.id], in: session)
                    openTerminal()
                }
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                .help(request.isFromSubagent ? "Shows Claude's own menu in the terminal."
                                             : "Claude's own menu is already open in the terminal. This takes the card away.")
            }
        }
    }

    @ViewBuilder private func fileLine(_ file: String) -> some View {
        let name = Label { Text(verbatim: PermissionText.visible(file)) } icon: { Image(systemName: "doc.text") }
        if file.hasPrefix("/") {
            Link(destination: URL(fileURLWithPath: file)) { name }
                .scaledFont(.callout.monospaced()).foregroundStyle(AgenticiousStyle.violet).linkCursor()
            if request.toolName == "Write", FileManager.default.fileExists(atPath: file) {
                Text("Replaces everything in the existing file.").scaledFont(.caption).foregroundStyle(AgenticiousStyle.coral)
            }
        } else {
            name.scaledFont(.callout.monospaced())
        }
    }

    /// The text exactly as Claude sent it, hidden characters made visible; never Markdown, never cut short by lines.
    /// Its size and anything left out are said above it, where they show however far the text runs.
    private func block(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: block.part.label.uppercased() + block.size)
                .scaledFont(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
            if block.omitted > 0 {
                Text(verbatim: "\(block.omitted) characters in the middle are not shown, so Allow is off here. Copy to read all of it, and answer in the terminal.")
                    .scaledFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if block.part.kind == .prose {
                Text(verbatim: block.text).scaledFont(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else {
                HStack(alignment: .top) {
                    Text(verbatim: block.text).scaledFont(.system(size: 12, design: .monospaced))
                        .foregroundStyle(block.part.kind == .removed ? AgenticiousStyle.coral : AgenticiousStyle.lime)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.part.text, forType: .string)
                    }.labelStyle(.iconOnly).buttonStyle(.plain).help("Copy exactly what Claude sent")
                }
                .padding(12).background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
            .scaledFont(.callout).foregroundStyle(AgenticiousStyle.coral).fixedSize(horizontal: false, vertical: true)
    }

    /// A background subagent's menu, and so its warning, is not in the terminal until the request is handed there.
    private var caution: String {
        "Claude Code offered no “always allow” for this command, which it does when its own menu shows a warning. The warning isn't available here: "
            + (request.isFromSubagent ? "choose “Answer in terminal instead” to read it there before allowing." : "read it in the terminal before allowing.")
    }

    private func alwaysRow(_ always: PermissionRequest.AlwaysAllow, pinned: Bool) -> some View {
        Button { store.decide(.allowAlways, on: request.id, in: session) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark.shield").foregroundStyle(AgenticiousStyle.violet.opacity(0.7))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow, and don't ask again").scaledFont(.callout.weight(.semibold))
                    Text(verbatim: "Always allow \(always.rules.joined(separator: ", ")), \(always.scope)")
                        .scaledFont(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).disabled(!canAllow(pinned)).opacity(canAllow(pinned) ? 1 : 0.4)
    }

    private func footer(pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // With the buttons, never in the part that scrolls away: a warning is in view whenever Allow is.
            if request.asksToLeaveSandbox { warning("Claude asked to run this outside the sandbox.") }
            if request.hasTerminalOnlyWarning { warning(caution) }
            TextField("Tell Claude what to do instead (optional)", text: $note, axis: .vertical)
                .lineLimit(1...4).textFieldStyle(.plain).padding(12)
                .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
            if note.count > PermissionRequest.noteLimit {
                Text(verbatim: "Claude gets the first \(PermissionRequest.noteLimit) characters of a note; this one has \(note.count).")
                    .scaledFont(.caption).foregroundStyle(.orange)
            }
            if !pinned {
                Text(verbatim: Self.noRoom).scaledFont(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(verbatim: hint).scaledFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(stops ? "Deny and stop" : hasNote ? "Deny with note" : "Deny", systemImage: "xmark") {
                    store.decide(.deny(note: note), on: request.id, in: session)
                }
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false)).disabled(!isArmed)
                // No keyboard shortcut: ⌘ Return belongs to the reply box and the question card.
                Button("Allow", systemImage: "checkmark") { store.decide(.allow, on: request.id, in: session) }
                    .buttonStyle(AgenticiousButtonStyle()).disabled(!canAllow(pinned))
                    .help(!pinned ? Self.noRoom
                          : isCut ? "Part of this request is too long to show here. Answer in the terminal."
                          : !hasSeenEnd ? "Scroll to the end of the request first."
                          : "Allow this once.")
            }
        }
        .preference(key: CanAllow.self, value: canAllow(pinned))
    }

    private static let noRoom = "Not enough room to show the request with Allow. Make the window taller, or answer in the terminal."

    private var hint: String {
        let queue = waiting > 0 ? " · \(waiting) more waiting" : ""
        if stops { return "Deny stops Claude and hands the turn to you. Add a note to let it carry on instead.\(queue)" }
        return (request.isFromSubagent ? "The subagent is told this was denied and keeps working." : "Claude reads your note and keeps working.") + queue
    }
}

/// One part as the card draws it.
private struct Block: Identifiable {
    let part: PermissionRequest.Part
    let text: String
    let omitted: Int
    /// " · 40 LINES" or " · 4036 CHARACTERS": a block that runs past the fold says so at its top.
    let size: String
    var id: String { part.label }

    init(_ part: PermissionRequest.Part) {
        self.part = part
        (text, omitted) = PermissionText.bounded(PermissionText.visible(part.text, prose: part.kind == .prose))
        let lines = part.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        size = lines > 12 ? " · \(lines) LINES" : part.text.count > 400 ? " · \(part.text.count) CHARACTERS" : ""
    }
}

/// A request's blocks, worked out once per request: the body runs again on every key typed into the note, and a
/// request can be a whole file.
private final class Drawn {
    private var made: (id: UUID, blocks: [Block])?

    func blocks(of request: PermissionRequest) -> [Block] {
        if let made, made.id == request.id { return made.blocks }
        let blocks = request.parts.map(Block.init)
        made = (request.id, blocks)
        return blocks
    }
}

/// Where the request, and in a card that scrolls whole the card, ends: measured from the top of the scroll view around
/// them. Unknown reads as below the fold, which keeps Allow off.
private struct Ends: PreferenceKey, Equatable {
    static let space = "permission-card"
    static let defaultValue = Ends()
    var request = CGFloat.infinity, card = CGFloat.infinity

    static func reduce(value: inout Ends, nextValue: () -> Ends) {
        let next = nextValue()
        value = Ends(request: min(value.request, next.request), card: min(value.card, next.card))
    }
}

/// The request scrolling above the footer, as tall as both up to `limit`. Asked for its ideal height, as `ViewThatFits`
/// does, it reports the least that still leaves the request `room` above however tall the footer is, so a pane that
/// would squeeze the request below that gets the card that scrolls whole.
private struct PinnedAnswer: Layout {
    var limit: CGFloat
    var least: CGFloat
    var room: CGFloat

    private func heights(_ width: CGFloat?, _ subviews: Subviews) -> (request: CGFloat, footer: CGFloat) {
        let ideal = ProposedViewSize(width: width, height: nil)
        return (subviews[0].sizeThatFits(ideal).height, subviews[1].sizeThatFits(ideal).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (request, footer) = heights(proposal.width, subviews)
        let enough = max(least, footer + room)
        let height = min(request + footer, proposal.height.map { min(max(limit, enough), $0) } ?? enough)
        return CGSize(width: proposal.width ?? subviews[1].sizeThatFits(.unspecified).width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let footer = min(heights(bounds.width, subviews).footer, bounds.height)
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height - footer))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - footer), proposal: ProposedViewSize(width: bounds.width, height: footer))
    }
}
