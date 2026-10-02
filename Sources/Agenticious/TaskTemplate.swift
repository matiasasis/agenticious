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
    var isChat: Bool { id == "chat" }
    var shortName: String { name }
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this preset a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a prompt for the agent." }
        if titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a task title." }
        return nil
    }

    func title(for value: String) -> String {
        let title = titlePattern.replacingOccurrences(of: "{{input}}", with: Self.withoutSnippets(value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? name : title
    }

    /// Code snippets stay in the prompt but would swamp a card title.
    static func withoutSnippets(_ text: String) -> String {
        var isInSnippet = false
        return text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInSnippet.toggle()
                return false
            }
            return !isInSnippet
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func instructions(for value: String, notes: String = "") -> String {
        var result = prompt.replacingOccurrences(of: "{{input}}", with: value)
        if !prompt.contains("{{input}}"), !value.isEmpty { result += "\n\nTask input:\n\(value)" }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += "\n\nNotes from the human:\n\(notes)" }
        return result
    }

    static let custom = TaskTemplate(id: "custom", name: "Custom task", summary: "Give your agent a mission in your own words.")
    static let chat = TaskTemplate(
        id: "chat", name: "Chat", summary: "Research a question or think something through together.",
        symbol: "bubble.left.and.bubble.right", fieldLabel: "Question or topic",
        fieldPlaceholder: "What would you like to explore?", titlePattern: "Chat: {{input}}",
        prompt: """
        Research or discuss this question with the human:
        {{input}}

        Lead with a direct answer, then explain the evidence, open questions, and useful next steps.
        Read referenced sources and link to evidence. Distinguish verified facts from assumptions.
        Ask a focused clarification when needed and make space for follow-up questions.
        This is a conversation: do not implement changes, post reviews, or merge PRs unless explicitly asked.
        """
    )
    static let defaults: [TaskTemplate] = [
        custom,
        chat,
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

                     Signal review work as soon as it starts, before reading the full diff or posting findings.
                     For a Slack source, resolve the parent thread even if the input targets a reply, and immediately
                     add :eyes: to the parent when starting work on that thread. Read all replies and pages, retain
                     each PR's source message identifiers, and add :eyes: to each message referencing a PR when
                     starting that PR's review. Do not mark all queued PR messages in advance. A message containing
                     multiple PRs gets :eyes: when review of its first PR starts; this signals work started, not completion.
                     For each PR, add the eyes reaction to its GitHub description when starting its review, including
                     when the input is a direct PR number or URL. Use the reaction name eyes in Slack and GitHub APIs.
                     Preserve existing reactions and skip adding your own if already present. Read back each reaction
                     to verify it was saved. If a reaction fails or access is unavailable, report the affected message
                     or PR link separately and continue any review work that remains accessible. Do not claim the
                     reaction succeeded without verification. Do not post new Slack messages or remove other reactions.

                     For each open PR, follow the project's review conventions. Read the description, linked context,
                     existing review threads, and the full current diff. Check correctness, maintainability, test coverage,
                     and CI results. Verify findings against the latest head before posting and avoid duplicating existing feedback.
                     Post actionable comments or code suggestions on the relevant PR. The intended final outcome for
                     each reviewable PR is an APPROVE review, not a comment-only review. This preset authorizes approval
                     without asking for separate confirmation. Use COMMENT for interim findings; never submit Request Changes.
                     Before approving, recheck the latest head, relevant CI results, and any fixes to reported issues.
                     Submit APPROVE once no unresolved blocking findings remain, including when the initial review is clean.
                     If fixes are needed, report the findings and re-review when fixes are available; do not approve known
                     blocking issues or wait indefinitely for the author. If approval is not possible, including self-review,
                     missing permissions, unresolved blockers, or a changed head that has not been reviewed, report the
                     specific blocker and leave that PR pending. Do not claim the review is complete without approval.
                     Avoid duplicate approvals when your existing approval already covers the current head. Verify the
                     submitted approval and include its clickable review link in the final per-PR report.
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

struct TaskType: Codable, Equatable {
    let name: String
    let symbol: String
    let details: String?
    let templateID: String?

    var isChat: Bool { templateID == "chat" }

    init(template: TaskTemplate, input: String? = nil, notes: String = "") {
        name = template.name
        symbol = template.symbol
        templateID = template.id
        details = input.map {
            [$0, notes].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private static let legacyPrefixes = [
        ("Implement ", "implementTicket"), ("Resolve & merge:", "reviewComments"),
        ("Address comments and merge PR ", "reviewComments"),
        ("Review PRs:", "reviewPR"), ("Review PR ", "reviewPR"), ("Review PR:", "reviewPR"),
        ("Fix CI ", "fixCI")
    ]

    func details(for title: String) -> String {
        if let details { return details }
        if let prefix = Self.legacyPrefixes.first(where: { title.hasPrefix($0.0) }),
           Self.legacy(title: title).name == name {
            return String(title.dropFirst(prefix.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title == name ? "" : title
    }

    static func legacy(title: String) -> TaskType {
        let id = legacyPrefixes.first { title.hasPrefix($0.0) }?.1
        return TaskType(template: TaskTemplate.defaults.first { $0.id == id } ?? .custom)
    }
}
