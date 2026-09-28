import Foundation

/// Canned tasks for the New Agent sheet. Each asks for one value and expands into a short title (the agent's big
/// title) and the full instructions the agent gets.
enum TaskTemplate: String, CaseIterable, Identifiable {
    case custom, implementTicket, reviewComments, reviewPR, fixCI

    var id: String { rawValue }

    var name: String {
        switch self {
        case .custom: "Custom"
        case .implementTicket: "Implement ticket"
        case .reviewComments: "Review comments"
        case .reviewPR: "Review PR"
        case .fixCI: "Fix CI"
        }
    }

    var fieldLabel: String {
        switch self {
        case .custom: ""
        case .implementTicket: "Ticket"
        case .reviewComments, .reviewPR: "Pull request"
        case .fixCI: "Pull request or branch"
        }
    }

    var fieldPlaceholder: String {
        switch self {
        case .custom: ""
        case .implementTicket: "PROJ-123 or the ticket URL"
        case .reviewComments, .reviewPR: "1234 or the PR URL"
        case .fixCI: "Leave empty for the current branch"
        }
    }

    var isFieldRequired: Bool { self != .fixCI }

    func title(for value: String) -> String {
        switch self {
        case .custom: value
        case .implementTicket: "Implement \(value)"
        case .reviewComments: "Address review comments on PR \(value)"
        case .reviewPR: "Review PR \(value)"
        case .fixCI: value.isEmpty ? "Fix CI" : "Fix CI on \(value)"
        }
    }

    func instructions(for value: String) -> String {
        let skills = "If you have a skill for this kind of task, use it."

        switch self {
        case .custom:
            return value
        case .implementTicket:
            return """
            Implement ticket \(value).

            1. Read the ticket, its comments and linked issues with whatever tracker tools you have (for example the \
            Jira/Atlassian MCP). If you can't read it, call need_human.
            2. Explore the code it touches and plan the change.
            3. Implement it following the repo's conventions, with tests.
            4. Run the relevant tests and linters until they pass.
            5. Commit on a feature branch (the current one if it isn't the default branch), push, and open a draft PR \
            that links the ticket.

            \(skills)
            """
        case .reviewComments:
            return """
            Address the open review comments on PR \(value).

            1. Check out the PR's branch (`gh pr checkout`). If git says it's checked out in another worktree, call need_human.
            2. Read every unresolved review thread.
            3. For each one, decide whether it applies. Implement the ones that do.
            4. Run the relevant tests and linters, then commit and push.
            5. Reply on every thread: what you changed, or why you didn't. Resolve the threads you fixed.

            \(skills)
            """
        case .reviewPR:
            return """
            Review PR \(value).

            Read the description and the full diff (`gh pr view`, `gh pr diff`), and read the changed code in context. \
            Look for bugs, missing tests, security problems and anything that doesn't fit the repo's conventions.
            Don't push commits or post anything on GitHub. Finish with the review as your reply: a verdict, then findings \
            ordered by severity, each with file:line and a suggested fix.

            \(skills)
            """
        case .fixCI:
            let target = value.isEmpty ? "the current branch" : value
            return """
            Fix the failing CI checks on \(target).

            1. Find the failing checks and read their logs (`gh pr checks`, `gh run view --log-failed`).
            2. Reproduce each failure locally where you can.
            3. Fix the root cause. Don't skip, disable or loosen tests to get green. If a failure looks flaky or unrelated \
            to the change, call need_human.
            4. Run the failing checks locally, commit and push, then watch the new CI run until it's green.

            \(skills)
            """
        }
    }
}
