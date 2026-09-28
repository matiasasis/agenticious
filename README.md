# AgentDeck

A native macOS dashboard for running many coding agents (Claude Code and Codex) at once without juggling terminal windows.

- **One card per agent**, with the original task as the big title.
- **Chunk boxes**: every agent is told to split its task into 3–8 chunks and to report progress on each.
- **"Needs you" floats to the top** with the reason. You also get a dock badge, a sound and a menu-bar counter.
- **The real terminal** is one click away. Each agent runs in an embedded terminal (SwiftTerm) that keeps running when you close its window.
- **Usage**: Codex rate-limit percentages read from its session logs, and an estimate of today's Claude tokens.

## Run

```sh
script/run
```

Requires macOS 14+ and the `claude` / `codex` CLIs on your login shell's PATH.

## How it knows what the agent is doing

```
agent ──hooks / notify──┐
                        ├──► POST http://127.0.0.1:47821/hook/<session>/<event> ──► AgentDeck
agent ──agentdeck MCP───┘
```

| Signal | Claude Code | Codex |
|---|---|---|
| Chunk plan | `agentdeck` MCP tools (`set_plan`, `update_chunk`); falls back to mirroring its TodoWrite list | `agentdeck` MCP tools |
| Needs you | `Notification` hook (permission / idle), `need_human` tool | `need_human` tool |
| Turn finished | `Stop` hook | `notify` (agent-turn-complete) |
| Done | `finish` tool | `finish` tool |

The built-in "skill" is `Sources/AgentDeck/ChunkingPrompt.swift`. Claude gets it through `--append-system-prompt`. Codex gets it prepended to the task.

Nothing in your global config changes. Per-session Claude settings and MCP config are written to
`~/Library/Application Support/AgentDeck/sessions/<id>/` and passed with `--settings` / `--mcp-config`. Codex uses `-c` overrides.
Note: those Codex overrides replace your own `notify` setting for sessions started from AgentDeck.

## Layout

| Path | What |
|---|---|
| `Sources/AgentDeck/AgentLauncher.swift` | Builds the command line, hooks and MCP config per agent |
| `Sources/AgentDeck/EventServer.swift` | Loopback HTTP listener |
| `Sources/AgentDeck/EventInterpreter.swift` | Event → status / chunks |
| `Sources/AgentDeck/SessionStore.swift` | Running sessions, terminal processes, dock badge |
| `Sources/AgentDeck/UsageMonitor.swift` | Local-log usage readout |
| `Sources/agentdeck-mcp/main.swift` | Stdio MCP server the agents call |

## Worktrees

For a git project, the New Agent sheet can run the agent in its own worktree, so parallel agents don't edit the
same checkout. AgentDeck creates `<repo>/.claude/worktrees/<task-slug>` on a new `agentdeck/<task-slug>` branch
from the current `HEAD`. It adds that folder to `.git/info/exclude` (local only, nothing committed), so it stays
out of `git status`. Because the folder sits inside the repo, Claude doesn't ask to trust each new worktree.

**Delete worktree** (right-click the agent) is enabled once the agent has exited. Git refuses if the worktree has
uncommitted changes, and the branch is always kept.

## Next steps

- Persist sessions across app restarts (`claude --resume`, `codex resume`)
- System notifications (needs a proper `.app` bundle)
- Codex approval prompts don't trigger a hook yet, so they only show up if the agent calls `need_human`
