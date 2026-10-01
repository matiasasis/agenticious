import Foundation
import SwiftTerm

enum StartupPrompt: Equatable {
    case folderTrust(AgentKind)

    var reason: String {
        switch self {
        case .folderTrust(let agent):
            "\(agent.displayName) is waiting for folder access approval. Open the terminal to review the folder trust prompt."
        }
    }

    static func detect(in terminal: Terminal, agent: AgentKind) -> StartupPrompt? {
        // Ignore scrollback even when the user has scrolled up to an old prompt.
        let screen = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().suffix(terminal.rows)
            .joined(separator: " ")
        // Claude Code skips spaces by moving the cursor, leaving null cells between words.
        let text = screen.split { $0.isWhitespace || $0 == "\0" }.joined(separator: " ")
        switch agent {
        case .codex:
            guard text.contains("Folder access"), text.contains("Trust this folder?"),
                  text.contains("1. Trust and continue"), text.contains("2. Quit") else { return nil }
        case .claude:
            guard text.contains("Accessing workspace:"), text.contains("Quick safety check:"),
                  text.contains("Yes, I trust this folder"),
                  text.contains("No, exit") || text.contains("No, continue without these permissions") else { return nil }
        }
        return .folderTrust(agent)
    }
}

@MainActor
enum StartupPromptInterpreter {
    static func apply(_ prompt: StartupPrompt?, to session: AgentSession) {
        let previous = session.startupPrompt
        let ownsAttention = previous.map { session.status == .needsYou($0.reason) } ?? false
        guard session.isRunning, !session.isArchiving, !session.isMarkedFinished,
              session.status == .starting || ownsAttention else {
            if previous != nil { session.startupPrompt = nil }
            return
        }
        guard prompt != previous else { return }
        session.startupPrompt = prompt
        if let prompt {
            session.status = .needsYou(prompt.reason)
        } else if ownsAttention {
            session.status = .starting
        }
    }
}
