import Foundation
import SwiftTerm

enum StartupPrompt: Equatable {
    case folderTrust

    var reason: String {
        "Codex is waiting for folder access approval. Open the terminal to review “Trust this folder?”."
    }

    static func detect(in terminal: Terminal, agent: AgentKind) -> StartupPrompt? {
        guard agent == .codex else { return nil }
        // Ignore scrollback even when the user has scrolled up to an old prompt.
        let screen = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().suffix(terminal.rows)
            .joined(separator: " ")
        let text = screen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.contains("Folder access"), text.contains("Trust this folder?"),
              text.contains("1. Trust and continue"), text.contains("2. Quit") else { return nil }
        return .folderTrust
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
