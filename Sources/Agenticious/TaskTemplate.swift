import Foundation

struct TaskTemplate: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var summary = ""
    var symbol = "sparkles"
    var fieldLabel = "Task input"
    var fieldPlaceholder = "What should the agent work on?"
    var isFieldRequired = true
    var titlePattern = "{{input}}"
    var prompt = "{{input}}"
    var skillPaths: [String] = []

    var isCustom: Bool { id == "custom" }
    var shortName: String { name }
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this preset a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a prompt for the agent." }
        if titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a task title." }
        return nil
    }

    func title(for value: String) -> String {
        let title = titlePattern.replacingOccurrences(of: "{{input}}", with: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? name : title
    }

    func instructions(for value: String, notes: String = "") -> String {
        var result = prompt.replacingOccurrences(of: "{{input}}", with: value)
        if !prompt.contains("{{input}}"), !value.isEmpty { result += "\n\nTask input:\n\(value)" }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += "\n\nNotes from the human:\n\(notes)" }
        return result
    }

    static let custom = TaskTemplate(id: "custom", name: "Custom task", summary: "Give your agent a mission in your own words.")
    static let defaults: [TaskTemplate] = [
        custom,
        TaskTemplate(id: "implementTicket", name: "Implement", summary: "Turn a ticket into tested code and a draft pull request.",
                     symbol: "hammer", fieldLabel: "Ticket", fieldPlaceholder: "Ticket ID or URL",
                     titlePattern: "Implement {{input}}", prompt: """
                     Implement ticket {{input}}.
                     Read the ticket and its linked context, explore the project, and plan the change.
                     Follow the project's conventions, implement the change, and run relevant tests.
                     Commit on a feature branch, push, and open a draft pull request linked to the ticket.
                     If the ticket or a required tool is unavailable, ask the human for help.
                     """),
        TaskTemplate(id: "reviewComments", name: "Resolve & merge", summary: "Address review feedback, wait for CI, then merge the pull request.",
                     symbol: "arrow.triangle.merge", fieldLabel: "Pull request", fieldPlaceholder: "PR number or URL",
                     titlePattern: "Address comments and merge PR {{input}}", prompt: """
                     Address review comments on pull request {{input}} and get it merged.
                     Follow the project's review conventions. Implement applicable feedback, test and push fixes,
                     and reply to each review thread. Explain any feedback that cannot be applied.
                     Resolve merge conflicts with the target branch, preserving the intended changes on both sides.
                     Test the resolution and push it before checking CI again.
                     Inspect failing CI logs. For failures confirmed to be flaky, rerun the failed tests or CI jobs
                     and watch the rerun. If the same failure keeps recurring, investigate and fix it rather than
                     blindly retrying. Fix genuine regressions without skipping or weakening tests.
                     Verify all required CI checks are green on the latest commit, then merge with the repository's normal method.
                     Do not bypass required checks or approvals. Ask the human when a conflict's intended behavior
                     is unclear or another blocker cannot be resolved.
                     """),
        TaskTemplate(id: "reviewPR", name: "Review PR", summary: "Review a pull request and post actionable feedback.",
                     symbol: "text.magnifyingglass", fieldLabel: "Pull request", fieldPlaceholder: "PR number or URL",
                     titlePattern: "Review PR {{input}}", prompt: """
                     Review pull request {{input}} following the project's conventions.
                     Check correctness, maintainability, and test coverage. Post actionable review comments
                     with suggestions where useful. Do not modify the author's branch.
                     """),
        TaskTemplate(id: "fixCI", name: "Fix CI", summary: "Investigate failing checks, fix the cause, and get CI green.",
                     symbol: "wrench.and.screwdriver", fieldLabel: "Pull request or branch",
                     fieldPlaceholder: "Leave empty for the current branch", isFieldRequired: false,
                     titlePattern: "Fix CI {{input}}", prompt: """
                     Fix failing CI for {{input}} (use the current branch if no target is supplied).
                     Read the failing logs, reproduce the failures where possible, and fix the root cause.
                     Do not skip or weaken tests to get green. Ask the human about unrelated failures.
                     Run relevant checks, commit and push the fix, and watch CI until it passes.
                     """)
    ]
}
