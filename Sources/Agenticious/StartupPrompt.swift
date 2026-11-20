import Foundation
import SwiftTerm

enum StartupPrompt: Equatable {
    case folderTrust(AgentKind)
    /// A screen the CLI shows before any work: sign-in, first-run setup, an API key question, an update offer.
    case cliScreen(AgentKind, CLIScreen)
    /// The login shell's start-up files stopped to ask something before running the CLI.
    case shellWaiting(AgentKind, ShellWait)

    var shellWait: ShellWait? {
        if case let .shellWaiting(_, wait) = self { wait } else { nil }
    }

    var reason: String {
        switch self {
        case .folderTrust(let agent):
            "\(agent.displayName) is waiting for folder access approval. Open the terminal to review the folder trust prompt."
        case let .cliScreen(_, screen):
            screen.reason
        case let .shellWaiting(agent, wait):
            wait.reason(before: agent.displayName)
        }
    }

    static func detect(in terminal: Terminal, agent: AgentKind) -> StartupPrompt? {
        // Ignore scrollback even when the user has scrolled up to an old prompt.
        let screen = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast().suffix(terminal.rows)
            .joined(separator: " ")
        // Claude Code skips spaces by moving the cursor, leaving null cells between words.
        let text = screen.split { $0.isWhitespace || $0 == "\0" }.joined(separator: " ")
        let asksForTrust = switch agent {
        case .codex:
            text.contains("Folder access") && text.contains("Trust this folder?")
                && text.contains("1. Trust and continue") && text.contains("2. Quit")
        case .claude:
            text.contains("Accessing workspace:") && text.contains("Quick safety check:")
                && text.contains("Yes, I trust this folder")
                && (text.contains("No, exit") || text.contains("No, continue without these permissions"))
        }
        if asksForTrust { return .folderTrust(agent) }
        return CLIScreen.allCases.first { $0.agent == agent && $0.fragments.allSatisfy(text.contains) }.map { .cliScreen(agent, $0) }
    }
}

/// Full-screen dialogs a CLI shows before its first turn. All fragments must show, so its transcript can't match.
enum CLIScreen: CaseIterable, Equatable {
    case claudeTheme, claudeLogin, claudeAPIKey, codexUpdate, codexSignIn

    var agent: AgentKind {
        switch self {
        case .claudeTheme, .claudeLogin, .claudeAPIKey: .claude
        case .codexUpdate, .codexSignIn: .codex
        }
    }

    var fragments: [String] {
        switch self {
        case .claudeTheme: ["Choose the text style that looks best with your terminal"]
        case .claudeLogin: ["Select login method:", "Claude account with subscription"]
        case .claudeAPIKey: ["Detected a custom API key in your environment", "Do you want to use this API key?"]
        case .codexUpdate: ["Update available", "Skip until next version"]
        case .codexSignIn: ["Sign in with ChatGPT", "Sign in with Device Code"]
        }
    }

    var reason: String {
        switch self {
        case .claudeTheme: "Claude Code is showing its first-run setup. Finish it in the terminal."
        case .claudeLogin: "Claude Code needs you to sign in. Finish signing in in the terminal."
        case .claudeAPIKey: "Claude Code found an API key in your environment and asks whether to use it. Answer in the terminal."
        case .codexUpdate: "Codex offers an update before it starts, and Enter would install it. Choose in the terminal."
        case .codexSignIn: "Codex needs you to sign in. Finish signing in in the terminal."
        }
    }
}

@MainActor
enum StartupPromptInterpreter {
    static func apply(_ prompt: StartupPrompt?, to session: AgentSession) {
        let previous = session.startupPrompt
        let ownsAttention = previous.map { session.status == .needsYou($0.reason) } ?? false
        guard session.isRunning, !session.isArchiving, !session.isMarkedFinished,
              ownsAttention || canInterrupt(session.status, for: prompt) else {
            if previous != nil { session.startupPrompt = nil }
            return
        }
        guard prompt != previous else { return }
        let giveBack = ownsAttention ? session.statusBeforeStartupPrompt : session.status
        session.startupPrompt = prompt
        if let prompt {
            session.status = .needsYou(prompt.reason)
            session.statusBeforeStartupPrompt = giveBack
        } else if ownsAttention {
            session.status = giveBack ?? .starting
        }
    }

    /// Before the shell runs the CLI, no hook can have set the status, so a resumed agent's Working or Your turn is
    /// only the launch's guess and gives way. A CLI screen only ever interrupts Starting.
    private static func canInterrupt(_ status: SessionStatus, for prompt: StartupPrompt?) -> Bool {
        switch status {
        case .starting: true
        case .working, .yourTurn: prompt?.shellWait != nil
        default: false
        }
    }
}
