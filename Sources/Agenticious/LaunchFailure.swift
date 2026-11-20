import Foundation

/// An agent whose process ended before anything showed its CLI running. Saved with the status, so it survives a restart.
struct LaunchFailure: Equatable, Codable {
    /// Decoded exit code; nil when a signal ended it, or when no process could be started at all.
    var code: Int32?
    /// The terminal's last lines, cleaned of hidden characters.
    var output: [String]
    /// Try again repeats the same kind of launch: a resume reopens the conversation, a first start begins it.
    var resuming: Bool

    struct Diagnosis: Equatable {
        let cause: String
        /// A command that fixes it, shown with a Copy button. Never run by the app.
        let fix: String?
    }

    var codeDescription: String {
        switch code {
        case nil: "no exit code (a signal, or it never ran)"
        case 127: "exit code 127, command not found"
        case 126: "exit code 126, could not be run"
        case let code?: "exit code \(code)"
        }
    }

    /// Only what the message itself doesn't say: asdf, mise and volta print their own fix, so their lines are enough.
    /// Each recogniser is anchored at the line start and names the agent's own command, so tool output can't match.
    func diagnosis(for agent: AgentKind) -> Diagnosis? {
        let command = agent.command
        let lines = output.map { $0.trimmingCharacters(in: .whitespaces) }
        let isCommand = { (path: Substring) in path == command || path.hasSuffix("/" + command) }
        for (index, line) in lines.enumerated() {
            if let match = line.firstMatch(of: #/^(nodenv|rbenv|pyenv): (\S+): command not found$/#), match.2 == command {
                // "The `claude' command exists in these Node versions:", then one indented version per line.
                let rest = lines[(index + 1)...].drop { $0.isEmpty }
                let versions = rest.first?.hasPrefix("The `\(command)' command exists in these") == true
                    ? Array(rest.dropFirst().prefix { !$0.isEmpty }) : []
                let installedFor = versions.isEmpty ? "" : " It is installed for \(versions.joined(separator: ", "))."
                guard match.1 == "nodenv" else {
                    return Diagnosis(cause: "\(match.1) found no \(command) for the version this folder uses.\(installedFor)", fix: nil)
                }
                return Diagnosis(
                    cause: "\(agent.displayName) isn't installed for the Node version this folder uses.\(installedFor) Install it in the project folder, so it goes to that version.",
                    fix: "npm install -g \(agent.npmPackage)")
            }
            if let match = line.firstMatch(of: #/^nodenv: version `(.+)' is not installed \(set by (.+)\)$/#) {
                return Diagnosis(cause: "This folder asks for Node \(match.1) (set by \(match.2)), which nodenv doesn't have.",
                                 fix: "nodenv install \(match.1)")
            }
            if let match = line.firstMatch(of: #/^zsh(:\d+)?: command not found: (\S+)$/#), match.2 == command {
                return Diagnosis(cause: "\(command) isn't on your login shell's PATH. Install \(agent.displayName), or add its folder to PATH in ~/.zprofile.",
                                 fix: nil)
            }
            if let match = line.firstMatch(of: #/^zsh(:\d+)?: permission denied: (.+)$/#), isCommand(match.2) {
                return Diagnosis(cause: "The \(command) on your PATH isn't executable.", fix: nil)
            }
            if let match = line.firstMatch(of: #/^zsh(:\d+)?: (.+?): bad interpreter: /#), isCommand(match.2) {
                return Diagnosis(cause: "The \(command) on your PATH is a script whose interpreter is missing.", fix: nil)
            }
        }
        return nil
    }
}
