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
        TaskTemplate(id: "reviewComments", name: "Resolve & merge", summary: "Address feedback, resolve conflicts, and get one or multiple PRs green and merged.",
                     symbol: "arrow.triangle.merge", fieldLabel: "Pull request(s)",
                     fieldPlaceholder: "PR numbers, URLs, or a link containing multiple PRs",
                     titlePattern: "Resolve & merge: {{input}}", prompt: """
                     Resolve review feedback and merge every pull request identified by this input:
                     {{input}}

                     Accept a single PR, a list of PR numbers or URLs, or a source link containing PR references.
                     For a source link, read its complete content and all comments/replies, including paginated results.
                     Collect every PR explicitly linked there; deduplicate by repository and PR number, and list the
                     resulting scope before making changes. Do not expand scope to unrelated linked discussions.
                     Resolve bare PR numbers against the selected project. If the repository or scope is ambiguous,
                     or the source cannot be read completely, ask the human instead of guessing or silently omitting PRs.
                     Check each PR's current state. Report already-merged PRs separately; closed-unmerged PRs are blockers.
                     Identify stacked PR dependencies and process them in dependency order, rechecking each target branch after merges.

                     For each open PR, follow the project's review conventions. Implement applicable feedback,
                     test and push fixes, and reply to each review thread. Explain feedback that cannot be applied.
                     Resolve merge conflicts with the target branch, preserving the intended changes on both sides.
                     Test the resolution and push it before checking CI again.
                     Inspect failing CI logs. For failures confirmed to be flaky, rerun the failed tests or CI jobs
                     and watch the rerun. If the same failure keeps recurring, investigate and fix it rather than
                     blindly retrying. Fix genuine regressions without skipping or weakening tests.
                     Verify required CI checks are green on the latest commit and required approvals are satisfied,
                     then merge with the repository's normal method. Do not bypass required checks or approvals.
                     Ask the human when intended behavior is unclear or a blocker cannot be resolved; continue independent PRs.
                     Track every PR through completion and report its clickable URL, final state, and any blockers.
                     Only report the whole task complete after verifying that every PR in scope is merged.

                     When the source is a Slack message, resolve its parent thread even if the URL targets a reply.
                     Read the parent and every reply, including all pages and PR links in attachments. Keep each
                     PR's source message identifiers, including duplicate references. After verifying a PR is merged
                     on GitHub, including already-merged PRs, add :merged: to every reply referencing it. If a reply
                     lists multiple PRs, add the reaction only when all PRs in that message are verified merged.
                     Reread the complete thread and reconcile newly posted PRs before marking the parent message.
                     Add :merged: to the parent only when at least one PR was found and every PR in the thread is
                     verified merged. Never mark a message complete while any PR in its scope is open, blocked,
                     closed without merging, or has an unknown state. Preserve existing reactions and skip your
                     reaction if already present. Use the Slack reaction name merged and read back each update
                     to verify it succeeded. Report inaccessible messages, missing emoji, or failed reactions with
                     the affected message links separately from merge results. Do not substitute another emoji or
                     post a new Slack message. If the source cannot be read completely, do not mark the thread complete.
                     """),
        TaskTemplate(id: "reviewPR", name: "Review PR", summary: "Review one or multiple PRs and post actionable feedback on each.",
                     symbol: "text.magnifyingglass", fieldLabel: "Pull request(s)",
                     fieldPlaceholder: "PR numbers, URLs, or a link containing multiple PRs",
                     titlePattern: "Review PRs: {{input}}", prompt: """
                     Review every pull request identified by this input:
                     {{input}}

                     Accept a single PR, a list of PR numbers or URLs, or a source link containing PR references.
                     For a source link, read its complete content and all comments/replies, including paginated results.
                     Collect every PR explicitly linked there; deduplicate by repository and PR number, and list the
                     resulting scope before reviewing. Do not expand scope to unrelated linked discussions.
                     Resolve bare PR numbers against the selected project. If the repository or scope is ambiguous,
                     or the source cannot be read completely, ask the human instead of guessing or silently omitting PRs.
                     Check each PR's current state. Report closed or already-merged PRs separately; only review them
                     if the human explicitly requests a historical review. Review stacked PRs in dependency order,
                     comparing each PR against its own target branch so shared changes are not reported repeatedly.

                     For each open PR, follow the project's review conventions. Read the description, linked context,
                     existing review threads, and the full current diff. Check correctness, maintainability, test coverage,
                     and CI results. Verify findings against the latest head before posting and avoid duplicating existing feedback.
                     Post actionable comments or code suggestions on the relevant PR, using COMMENT by default.
                     Do not submit Request Changes. Submit an approval only when the human explicitly requests approval.
                     Do not implement fixes, commit, push, or merge the author's branch as part of this review.
                     If a PR cannot be reviewed, record the blocker and continue with independent PRs.
                     Finish with a per-PR report containing clickable PR and posted-review links, findings, and any blockers.
                     Do not claim the whole batch was reviewed while any PR in scope remains unreviewed or blocked.
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
