import AppKit
import SwiftUI

/// Why an agent isn't running its CLI yet: the login shell waits for an answer, or the CLI ended before it started.
/// The app never answers for the human; the terminal is where they type.
struct StartupProblemCard: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    let openTerminal: () -> Void

    static func shows(for session: AgentSession) -> Bool {
        session.startupPrompt?.shellWait != nil || session.status.launchFailure != nil
    }

    var body: some View {
        let color: Color = session.status.launchFailure == nil ? .orange : .red
        VStack(alignment: .leading, spacing: 14) {
            if let failure = session.status.launchFailure {
                notStarted(failure)
            } else if let prompt = session.startupPrompt, let wait = prompt.shellWait {
                waiting(wait, reason: prompt.reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.6), lineWidth: 1.5))
    }

    @ViewBuilder
    private func waiting(_ wait: ShellWait, reason: String) -> some View {
        Label("Waiting for your shell start-up", systemImage: "hand.raised.fill").scaledFont(.headline).foregroundStyle(.orange)
        Text(reason).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
        if !wait.text.isEmpty { terminalText(wait.text) }
        if let program = wait.program {
            Text("In the foreground: \(program)").scaledFont(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Open terminal", systemImage: "terminal", action: openTerminal).buttonStyle(AgenticiousButtonStyle())
            Text("Typing goes to the terminal.").scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func notStarted(_ failure: LaunchFailure) -> some View {
        let diagnosis = failure.diagnosis(for: session.agent)
        Label("\(session.agent.displayName) didn't start · \(failure.codeDescription)", systemImage: "exclamationmark.triangle.fill")
            .scaledFont(.headline).foregroundStyle(.red)
        if !failure.output.isEmpty { terminalText(failure.output.joined(separator: "\n")) }
        if let diagnosis {
            Text(diagnosis.cause).scaledFont(.callout).fixedSize(horizontal: false, vertical: true)
            if let fix = diagnosis.fix {
                HStack(spacing: 8) {
                    Text(verbatim: fix).scaledFont(.system(size: 12, design: .monospaced)).foregroundStyle(AgenticiousStyle.lime)
                        .textSelection(.enabled)
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fix, forType: .string)
                    }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
                    .help("Copy the command. Run it in a terminal yourself, then Try again.")
                }
            }
        }
        HStack {
            Button("Try again", systemImage: "arrow.clockwise") { store.resume(session) }
                .buttonStyle(AgenticiousButtonStyle())
                .disabled(!session.canResume)
                .help("Start the agent again after fixing what stopped it.")
            Button("Open terminal", systemImage: "terminal", action: openTerminal)
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false))
        }
    }

    /// Shown exactly as the terminal printed it, already cleaned of control and invisible characters.
    private func terminalText(_ text: String) -> some View {
        Text(verbatim: text)
            .scaledFont(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 10))
    }
}
