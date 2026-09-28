# Agenticious

A native macOS dashboard for running many coding agents (Claude Code and Codex) at once without juggling terminal windows.

- **One card per agent**, with the original task as the big title.
- **Chunk boxes**: every agent is told to split its task into 3–8 chunks and to report progress on each.
- **"Needs you" floats to the top** with the reason. You also get a dock badge, a sound and a menu-bar counter.
- **The real terminal** is one click away. Each agent runs in an embedded terminal (SwiftTerm) that keeps running when you close its window.
- **Usage**: session and weekly limits for both. Codex's come from its session logs. Claude's come from the status line
  of agents started here (until one has replied, you see an estimate of today's tokens instead).

## Run

```sh
script/run
```

Requires macOS 14+ and the `claude` / `codex` CLIs on your login shell's PATH.

## How it knows what the agent is doing

```
agent ──hooks / notify──┐
                        ├──► POST http://127.0.0.1:47821/hook/<session>/<event> ──► Agenticious
agent ──agenticious MCP───┘
```

| Signal | Claude Code | Codex |
|---|---|---|
| Chunk plan | `agenticious` MCP tools (`set_plan`, `update_chunk`); falls back to mirroring its TodoWrite list | `agenticious` MCP tools |
| Needs you | `Notification` hook (permission / idle), `need_human` tool | `need_human` tool |
| Turn finished | `Stop` hook; background tasks or scheduled wakeups show as Waiting | `notify` (agent-turn-complete) |
| Plan limits | `statusLine` command (`rate_limits`) | session logs |
| Done | `finish` tool | `finish` tool |

The built-in "skill" is `Sources/Agenticious/ChunkingPrompt.swift`. Claude gets it through `--append-system-prompt`. Codex gets it prepended to the task.

Nothing in your global config changes. Per-session Claude settings and MCP config are written to
`~/Library/Application Support/Agenticious/sessions/<id>/` and passed with `--settings` / `--mcp-config`. Codex uses `-c` overrides.
Note: those Codex overrides replace your own `notify` setting for sessions started from Agenticious, and the Claude
settings replace your own `statusLine` there (it shows the model and both limits instead).

## Layout

| Path | What |
|---|---|
| `Sources/Agenticious/AgentLauncher.swift` | Builds the command line, hooks and MCP config per agent |
| `Sources/Agenticious/EventServer.swift` | Loopback HTTP listener |
| `Sources/Agenticious/EventInterpreter.swift` | Event → status / chunks |
| `Sources/Agenticious/SessionStore.swift` | Running sessions, terminal processes, dock badge |
| `Sources/Agenticious/UsageMonitor.swift` | Codex and Claude plan limits |
| `Sources/agenticious-mcp/main.swift` | Stdio MCP server the agents call |

## Worktrees

For a git project, the New Agent sheet can run the agent in its own worktree, so parallel agents don't edit the
same checkout. Agenticious creates `<repo>/.claude/worktrees/<task-slug>` on a new `agenticious/<task-slug>` branch
from the current `HEAD`. It adds that folder to `.git/info/exclude` (local only, nothing committed), so it stays
out of `git status`. Because the folder sits inside the repo, Claude doesn't ask to trust each new worktree.

**Delete worktree** (right-click the agent) is enabled once the agent has exited. Git refuses if the worktree has
uncommitted changes, and the branch is always kept.

## Task presets and skills

Open **Settings** in the sidebar (or press `⌘,`) to create, edit, or delete task presets. Each preset has a name,
description, input hint, title, prompt, and optional skills. Use `{{input}}` in the title or prompt for the task's
input. Notes and selected skill references are appended automatically. The Custom task is editable and always
remains available. Changes affect new tasks; existing conversations keep their original prompts.

Presets are saved per user in `~/Library/Application Support/Agenticious/task-presets.json`. A damaged saved
file is preserved and reported instead of silently overwritten. The included presets are generic starting points,
so customize their prompts and skill choices for your workflow.

**Skills** browses `SKILL.md` files from personal `.agents/skills`, `.codex/skills` (respecting `CODEX_HOME`),
`.claude/skills`, `/etc/codex/skills`, project skill folders up to the repository root, and Codex/Claude plugin
caches. Add other locations with **Search folders**. Symlinked folders are followed and identical files are
shown once. Cached plugins are labeled as such: a cached skill does not mean its plugin or tools are enabled.

Select a skill to inspect its instructions or reveal its file. Create personal or project skills for Codex or
Claude Code, and edit personal/project skill files in the app. Plugin-cache and system skills are read-only.
Edits preserve the complete Markdown file and reject a save if another editor changed it in the meantime.

Use **Choose skills** in a task or preset to attach skills. Agenticious asks the agent to read the selected
absolute paths and resolve supporting resources from their skill folders. Missing or unreadable selected files
prevent launch with an error; attaching a skill does not install its tools or enable its plugin.

For UI inspection, `--settings`, `--skills`, and `--new-agent [preset-id]` can be combined with
`--snapshot-dir /tmp/agenticious-shots`. Run configuration and skill tests with `swift test`.

## Next steps

- Persist sessions across app restarts (`claude --resume`, `codex resume`)
- System notifications (needs a proper `.app` bundle)
- Codex approval prompts don't trigger a hook yet, so they only show up if the agent calls `need_human`
