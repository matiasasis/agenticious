# Agenticious

A native macOS dashboard for running many coding agents (Claude Code and Codex) at once without juggling terminal windows.

- **One card per agent**, with the original task as the big title.
- **Chunk boxes**: every agent is told to split its task into 3–8 chunks and to report progress on each.
- **"Needs you" floats to the top** with the reason. You also get a dock badge, a sound and a menu-bar counter.
- **The real terminal** is one click away. Each agent runs in an embedded terminal (SwiftTerm) that keeps running when you close its window.
- **Usage**: session and weekly limits for both. Codex's come from its session logs. Claude's come from the status line
  of agents started here (until one has replied, you see an estimate of today's tokens instead). Usage and provider
  checks only run while Agenticious is the active app, at intervals set in **Customize → Preferences → Background refresh**.

## Run

```sh
script/run
```

`script/run` builds a signed local `.build/Agenticious.app` bundle, required for macOS notifications.
After updating, quit the previous app when its agents are no longer running, then run the script again.
In **Customize → Preferences → Notifications**, enable macOS notifications and accept the system permission prompt.
Notifications open the relevant agent; sounds and notifications can be toggled separately. Existing
settings from the bare executable are imported on first bundled launch.

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

Open **Customize → Task presets** at the bottom of the sidebar (or press `⌘,`) to create, edit, or delete task presets. Each preset has a name,
description, input hint, title, prompt, and optional skills. Use `{{input}}` in the title or prompt for the task's
input. Notes and selected skill references are appended automatically. The Custom task is editable and always
remains available. Changes affect new tasks; existing conversations keep their original prompts.

Presets are saved per user in `~/Library/Application Support/Agenticious/task-presets.json`. A damaged saved
file is preserved and reported instead of silently overwritten. The included presets are generic starting points,
so customize their prompts and skill choices for your workflow.

**Customize → Skills** browses `SKILL.md` files from personal `.agents/skills`, `.codex/skills` (respecting `CODEX_HOME`),
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

### Navigation and menu bar

The sidebar defaults to **Queue**, grouped by workspace. Tasks stay in **Queue** regardless of their status. Use **Mark as finished** at the bottom of an agent view to stop it, clean up its resources, and move its history to **Finished**. **Move to Queue** restores the saved task to the list; it does not recreate a removed worktree. Resume is available only while its working directory still exists. Existing completed tasks return to Queue when upgrading to this manual behavior. Each card uses its status color for its background tint and border, with a stronger border for the selected sidebar card. Each card shows its provider, status, task, and completed steps; select a card to return to its terminal, or right-click for session actions. Use the folder button beside **Workspaces** to add a project.

**Customize** keeps task presets, skills, and preferences together while the agent sidebar stays visible. Preferences are split into sections: **General** (sidebar branch names, default worktree behavior), **Notifications**, and **Background refresh** (how often provider connections and usage limits are checked). The macOS menu bar shows a monochrome “A” with a spark, with a count only when agents need your attention.

Every agent has an **Archive** button beside its status and step count, plus an archive action in its right-click menu. Archiving stops its process, descendants, and owned terminal process group (escalating to kill if needed), releases the terminal, removes its per-session launch configuration, and attempts to remove its worktree. Known leftover provider processes are identified by this session's exact launch markers after a restart. **Mark as finished** uses the same cleanup. History and Git branches are preserved; worktrees with uncommitted changes or another queued agent are kept, with a warning. The main checkout and shared scratch folder are never removed. Archived activity is read once without background polling. Use the Archive button or **Retry archive cleanup** to retry worktree cleanup on older finished tasks.

### Provider diagnostics

Open the connection-status button beside the usage meters, then **Manage providers**, to check Claude Code and Codex account access and MCP status in your home folder or a selected project. The toolbar warning icon opens a compact provider summary. Checks run while Agenticious is the active app, at the interval set in **Preferences → Background refresh** (every 6 hours by default); **Refresh** and changing the folder run a fresh check. Authentication and connection failures include recovery instructions.

Claude checks MCP connections; Codex reports configured authentication without claiming the server is reachable. Session-only MCP overrides and worktree configuration can differ from these folder checks. Raw command output, server URLs, and credentials are not shown. Run the displayed provider commands in that folder for full details, then refresh after fixing an issue.

### Pull request links

Agent details show saved PR links above the step cards. Full HTTPS PR URLs in task text, Claude tool results, progress notes, and completion summaries are captured automatically. Agents use `set_pull_requests` to attach verified links as soon as they identify or create a PR, including every PR in a stack. Bare numbers must first be resolved against the actual repository by the agent. Links are deduplicated and kept across app restarts, including in Finished sessions. Existing sessions can report links in progress notes even without the new MCP tool.

Step cards use equal heights; hover a card to read its complete title and note.

### Activity and terminal

Agent details default to **Activity**, a structured view of provider messages and tool calls. Command/input blocks include copy controls and working-directory context; long inputs and output can be expanded, errors open automatically, and unknown result statuses remain neutral. Markdown emphasis, links, and fenced code blocks render separately. Use **Terminal** or **Respond in terminal** for replies, approvals, interactive prompts, and raw output. Switching tabs keeps the agent process alive.

Activity reads the session's local Claude or Codex JSONL log every two seconds while visible. Claude sessions are matched by conversation ID. Codex uses its reported conversation ID or a unique marker added to new Agenticious prompts, never just the workspace folder. Older Codex sessions without a known ID may need to finish a turn before activity becomes available. Subagent logs and private reasoning records are not displayed. Provider log formats may change; when a log is unavailable, use the terminal.

The view reads up to the latest 4 MiB, shows at most 200 entries, and labels content truncated beyond 32 KiB per field. Activity history comes from the provider's log, so disabling or deleting those logs also removes that history from this view. No additional transcript copy is saved by Agenticious.

The summon sheet remembers the last task preset and workspace, plus provider, model, and effort (model and effort separately per provider). Opening a workspace's **+** button still selects that workspace explicitly. Removed favorites are not restored as the default workspace. The larger sheet adapts to the available display size and keeps model selection beside the compact provider choices.

Provider icons use monochrome template rendering. The Claude mark comes from the official Claude desktop app (`TrayIconTemplate@3x.png`); the OpenAI mark used for Codex comes from the official ChatGPT app (`webview/assets/openai-logo-regular-ceb75a1754fa.svg` in `app.asar`). Their trademarks belong to Anthropic and OpenAI.

### Ended tasks

Agents report **Ended** with the `end` tool when you cancel work, ask them to stop, or hand it to another session. This clears Needs you while retaining the reason and unfinished steps; it does not claim success or archive resources. Clear final stop-and-handoff messages are also recognized from provider completion notifications for older sessions. Questions, conditional suggestions, and ordinary pauses are not treated as endings. For an already-stale session, right-click its card and choose **Mark as ended**. Archive remains the action that stops processes and cleans up resources. A new plan or resumed session can start work again.
