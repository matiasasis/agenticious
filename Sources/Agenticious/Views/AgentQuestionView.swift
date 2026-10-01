import SwiftUI

/// Claude's AskUserQuestion, answered in place: one block per question, its options as choices, and Other for free text.
struct QuestionCard: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    let questions: [AgentQuestion]
    let openTerminal: () -> Void
    @State private var chosen: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("\(session.agent.displayName) is asking", systemImage: "questionmark.bubble.fill")
                    .font(.headline).foregroundStyle(.orange)
                Spacer()
                Button("Answer in terminal instead") {
                    session.releaseQuestion()
                    openTerminal()
                }
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                .help("Shows Claude's own menu in the terminal.")
            }
            ForEach(questions) { question in block(question) }
            HStack {
                Text(isComplete ? "⌘ Return to send" : "Answer every question to send.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(questions.count == 1 ? "Send answer" : "Send answers", systemImage: "paperplane.fill") {
                    store.answer(session, with: answers)
                }
                .buttonStyle(AgenticiousButtonStyle())
                .disabled(!isComplete)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.6), lineWidth: 1.5))
    }

    private func block(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1).foregroundStyle(AgenticiousStyle.violet)
            }
            Text(question.text).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if question.allowsMultiple {
                Text("Choose any that apply.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(question.options, id: \.self) { option in
                choice(option, in: question)
            }
            otherField(for: question)
        }
    }

    private func choice(_ option: AgentQuestion.Option, in question: AgentQuestion) -> some View {
        let isChosen = chosen[question.id, default: []].contains(option.label)
        return Button { toggle(option.label, in: question) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: question.allowsMultiple ? (isChosen ? "checkmark.square.fill" : "square")
                                                          : (isChosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isChosen ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.7))
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.label).font(.callout.weight(.semibold))
                    if !option.detail.isEmpty {
                        Text(option.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .foregroundStyle(isChosen ? AgenticiousStyle.lime : .primary)
            .background(isChosen ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isChosen ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Other is a choice of its own in a single-choice question, so typing in it replaces the picked option.
    private func otherField(for question: AgentQuestion) -> some View {
        TextField("Other: type your own answer", text: Binding(
            get: { other[question.id, default: ""] },
            set: { text in
                other[question.id] = text
                if !question.allowsMultiple, !text.isEmpty { chosen[question.id] = [] }
            }
        ), axis: .vertical)
        .lineLimit(1...4)
        .textFieldStyle(.plain)
        .padding(12)
        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        var picked = chosen[question.id, default: []]
        if question.allowsMultiple {
            if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
        } else {
            picked = [label]
            other[question.id] = ""
        }
        chosen[question.id] = picked
    }

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            (question.text, question.answer(choosing: Array(chosen[question.id, default: []]), other: other[question.id, default: ""]))
        })
    }

    private var isComplete: Bool { answers.values.allSatisfy { !$0.isEmpty } }
}

/// A plain reply to the agent, typed into its terminal prompt. Shown only while that's safe (see `canReplyInline`).
struct ReplyComposer: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    @State private var text = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if case let .needsYou(reason) = session.status {
                    Label(reason, systemImage: "hand.raised.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange).lineLimit(3)
                }
                SnippetEditor(text: $text, placeholder: "Reply to \(session.agent.displayName)…", minHeight: 40, maxHeight: 160)
            }
            Button("Send", systemImage: "paperplane.fill", action: send)
                .buttonStyle(AgenticiousButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(14)
        .background(AgenticiousStyle.panel)
        .overlay(alignment: .top) { Rectangle().fill(AgenticiousStyle.violet.opacity(0.2)).frame(height: 1) }
    }

    private func send() {
        store.reply(text, to: session)
        text = ""
    }
}
