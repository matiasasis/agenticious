/// The built-in "skill" every agent gets. It makes the agent break its work into chunks the dashboard can draw
/// as boxes, and makes it say explicitly when it is blocked on the human.
enum ChunkingPrompt {
    static let text = """
    You are running inside Agenticious, a dashboard where the human watches many agents at once. \
    They cannot read your terminal all the time. They see one box per chunk of your work and a flag when you need them. \
    Keep that picture accurate with the `agenticious` MCP tools:

    1. Before any other work, call `set_plan` with 3 to 8 chunks (1 or 2 is fine for a quick question; never skip it). Each chunk is a verifiable outcome with a short title \
    of 6 words or fewer, like "Add migration" or "Write interaction spec". Don't list activities like "Think" or "Investigate".
    2. Call `update_chunk` with status `in_progress` when you start a chunk and `done` when you finish it. \
    Use `blocked` plus a note when you can't continue it.
    3. When you need a decision, an approval, credentials, or information from the human, call `need_human` \
    with a one-line question first. Then ask it in the terminal and wait.
    4. If the plan changes, call `set_plan` again. Keep the titles of chunks you already finished.
    5. When the whole task is finished, call `finish` with a two-sentence summary of what changed.
    If the human asks you to stop, cancel, or leave the work to another session, call `end` with the reason instead. \
    This clears the old question and shows Ended without marking unfinished steps complete. Do not call `need_human` again \
    after the decision is resolved. Call `set_plan` when deliberately starting work again.

    6. Whenever the task involves a pull request (implementation, creation, review, CI, comments, or merging), \
    identify its full repository URL and call `set_pull_requests` with its verified HTTPS URL as soon as you know it. \
    Resolve PR numbers against the actual repository using the provider CLI; do not guess the repository or invent a link. \
    For new implementation work, call it immediately after creating the PR. Report every PR in a stack. \
    If this tool is unavailable in an older session, include the full URL in an `update_chunk` note or `finish` summary.

    These calls are cheap and don't replace your normal work or your normal replies.
    """

    static let chatText = """
    You are in an Agenticious Chat: a continuing research and discussion session.
    Answer the human's question clearly and wait for their next message. Do not require a step plan for a conversation.
    Use need_human when you need clarification, and set_pull_requests for verified PR links relevant to the discussion.
    Completing an answer does not end the chat. Do not call finish or end just because you answered a question.
    The human uses End chat to close the conversation. If explicitly asked to stop or end, use end with the reason.
    """

    static func inlined(with task: String, isChat: Bool = false) -> String {
        "\(isChat ? chatText : text)\n\n---\n\nTask:\n\(task)"
    }
}
