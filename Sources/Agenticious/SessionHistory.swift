import Foundation

struct SessionHistory {
    var search = "" {
        didSet { if search != oldValue { page = 1 } }
    }
    var page = 1

    @MainActor
    func results(in sessions: [AgentSession]) -> SessionHistoryPage {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = sessions.filter { session in
            session.isMarkedFinished && terms.allSatisfy { term in
                [session.task, session.project.name, session.project.path ?? "",
                 session.worktree?.branch ?? "", session.agent.displayName]
                    .contains { $0.localizedStandardContains(term) }
            }
        }.sorted {
            if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.startedAt > $1.startedAt
        }
        return SessionHistoryPage(matches: matches, requestedPage: page)
    }
}

struct SessionHistoryPage {
    static let size = 20

    let sessions: [AgentSession]
    let total: Int
    let number: Int
    let count: Int
    let range: Range<Int>

    init(matches: [AgentSession], requestedPage: Int) {
        total = matches.count
        count = max(1, (total + Self.size - 1) / Self.size)
        number = min(max(1, requestedPage), count)
        let start = (number - 1) * Self.size
        range = start..<min(start + Self.size, total)
        sessions = Array(matches[range])
    }

    var summary: String {
        total == 0 ? "0 agents" : "\(range.lowerBound + 1)–\(range.upperBound) of \(total) agents"
    }
}
