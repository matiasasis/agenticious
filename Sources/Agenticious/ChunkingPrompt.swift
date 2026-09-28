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

    These calls are cheap and don't replace your normal work or your normal replies.
    """

    /// Codex has no append-system-prompt flag, so the instructions travel in front of the task itself.
    static func inlined(with task: String) -> String {
        "\(text)\n\n---\n\nTask:\n\(task)"
    }
}
