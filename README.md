# Agenticious


## Download

Download the Apple silicon build from [GitHub Releases](https://github.com/matiasasis/agenticious/releases).
Requires macOS 14+ and Claude Code or Codex installed and authenticated.
Unzip the download and move Agenticious.app to Applications.

The app uses free ad-hoc signing; it has no Apple Developer ID signature or notarization.
If macOS blocks the first launch and you trust the download, try opening it once, then go to
**System Settings → Privacy & Security → Open Anyway** and confirm.
See [Apple's instructions](https://support.apple.com/en-us/102445). Organization policies may prevent this override.

## Publishing a release

Run `script/release` on an Apple silicon Mac with Xcode installed. It builds an optimized app,
verifies its ad-hoc signature, and writes `Agenticious-macOS-arm64.zip` and `SHA256SUMS.txt`
to `.build/release/`. Upload both files to a versioned GitHub Release. No Apple Developer membership is required.
The static download website is in `docs/`; configure GitHub Pages to serve that directory.

A native macOS dashboard for running many coding agents (Claude Code and Codex) at once without juggling terminal windows.

- **One card per agent**, with the original task as the big title.
- **Chunk boxes**: every agent is told to split its task into 3–8 chunks and to report progress on each.
- **"Needs you" and "Permission required" float to the top** with the reason. You also get a dock badge, a sound and a menu-bar counter.
- **Approve in place**: when Claude asks to run a command or change a file, the request is pinned at the top of
  Activity with **Allow** and **Deny**. Its own menu stays usable in the terminal.
- **The real terminal** is one click away. Each agent runs in an embedded terminal (SwiftTerm) that keeps running when you close its window.
- **Usage**: session and weekly limits for both. Codex's come from its session logs. Claude's come from the status line
  of agents started here (until one has replied, you see an estimate of today's tokens instead). Usage and provider
  checks only run while Agenticious is the active app, at intervals set in **Customize → Preferences → Background refresh**.
- **Summon from anywhere**: give a task preset a system-wide shortcut, or put every preset behind one Stream Deck key,
  and a floating Summon window opens over whatever you are working on.
- **Recent inputs**: each task preset remembers what you started it with, and the Summon sheet offers the last five
  to use again.
- **Text size**: scale all of the app's text, the terminal included, from 100% to 150%.
- **Start-up problems in plain sight**: if your shell's start-up stops to ask something, or the CLI can't start,
  the agent says so with what the terminal shows, instead of sitting at Starting.

## Run

```sh
script/run
```

`script/run` builds a signed local `.build/Agenticious.app` bundle, required for macOS notifications.
After updating, quit the previous app when its agents are no longer running, then run the script again.
In **Customize → Preferences → Notifications**, enable macOS notifications and accept the system permission prompt.
Notifications open the relevant agent; sounds and notifications can be toggled separately. Existing
settings from the bare executable are imported on first bundled launch.

Requires macOS 14+ and the `claude` / `codex` CLIs on your login shell's PATH. If it can't start from there, the agent says why.

## How it knows what the agent is doing

```
agent ──hooks / notify──┐
                        ├──► POST http://127.0.0.1:47821/hook/<session>/<event> ──► Agenticious
agent ──agenticious MCP───┘
```

| Signal | Claude Code | Codex |
|---|---|---|
| Chunk plan | `agenticious` MCP tools (`set_plan`, `update_chunk`); falls back to mirroring its TodoWrite list | `agenticious` MCP tools |
| Needs you | `Notification` hook (other prompts / idle), `need_human` tool | `need_human` tool |
| Permission required | `PermissionRequest` hook, held open while its card shows in Activity; `Notification` hook (`permission_prompt`) when only the terminal can answer | — |
| Tool finished | `PostToolUse` / `PostToolUseFailure` hooks, which also end a permission wait | — |
| Turn finished | `Stop` hook; background tasks or scheduled wakeups show as Waiting | `notify` (agent-turn-complete) |
| Plan limits | `statusLine` command (`rate_limits`) | session logs |
| Done | `finish` tool | `finish` tool |
| Cleanup on end | `add_cleanup` tool | `add_cleanup` tool |
| Subagents | `SubagentStart` / `SubagentStop` hooks and tool hooks carrying `agent_id` | — |
| Start-up | Until the login shell runs the CLI: its process, terminal mode and screen (waiting for an answer, or ended before the CLI started). Then the folder-trust, sign-in and update screens | same |

The built-in "skill" is `Sources/Agenticious/ChunkingPrompt.swift`. Claude gets it through `--append-system-prompt`. Codex gets it prepended to the task.

Nothing in your global config changes. Per-session Claude settings and MCP config are written to
`~/Library/Application Support/Agenticious/sessions/<id>/` and passed with `--settings` / `--mcp-config`. Codex uses `-c` overrides.
Note: those Codex overrides replace your own `notify` setting for sessions started from Agenticious, and the Claude
settings replace your own `statusLine` there (it shows the model and both limits instead).

### When an agent doesn't start

Agents start in your login shell (`zsh -lic`), so they get your PATH. In agent terminals Agenticious skips Oh My Zsh's
update question and its tmux autostart (unless `ZSH_TMUX_AUTOSTART_ONCE=false`), by setting `DISABLE_AUTO_UPDATE` and `ZSH_TMUX_AUTOSTARTED` for start-up only.
The command unsets them before the CLI runs, and your own terminals are unaffected. A `zstyle ':omz:update' mode` in
your .zshrc still wins.

If start-up stops to ask something (an update question, a passphrase, a password), the agent shows **Needs you** with
the question as the terminal shows it; answer it in the terminal. If Claude Code or Codex can't start, the agent shows
**Didn't start** with the terminal's last lines, the exit code, and the likely cause and fix when it is recognised (for
example a nodenv Node version without the CLI). **Try again** starts it again once fixed. Agenticious never answers for
you and never switches to another copy of the CLI on its own.

A start-up file that leaves the cursor after text ending in a colon, question mark or bracket and then works quietly for
a while can show as **Needs you** until it moves on.

## Layout

| Path | What |
|---|---|
| `Sources/Agenticious/AgentLauncher.swift` | Builds the command line, hooks and MCP config per agent |
| `Sources/Agenticious/EventServer.swift` | Loopback HTTP listener; keeps a hook's connection open until it is answered |
| `Sources/Agenticious/EventInterpreter.swift` | Event → status / chunks |
| `Sources/Agenticious/AgentPermission.swift` | Permission requests: what a card shows, the hook replies, and when a held request is answered or handed back |
| `Sources/Agenticious/Views/PermissionCard.swift` | The permission card pinned at the top of Activity |
| `Sources/Agenticious/SessionStore.swift` | Running sessions, terminal processes, dock badge |
| `Sources/Agenticious/ShellStartup.swift` | How far an agent's login shell got, and whether it waits for you |
| `Sources/Agenticious/ProcessExitWatch.swift` | Notices an agent's process ending |
| `Sources/Agenticious/UsageMonitor.swift` | Codex and Claude plan limits |
| `Sources/Agenticious/HotkeyCenter.swift` | System-wide preset shortcuts (Carbon hot keys, no Accessibility permission) |
| `Sources/Agenticious/SummonPanelController.swift` | The floating Summon window a shortcut opens over other apps |
| `Sources/Agenticious/PromptHistory.swift` | The task inputs remembered per preset for the Summon sheet's **Recent** row |
| `Sources/Agenticious/StreamDeck.swift` | What the Stream Deck plugin asks the app: the presets with their key images, and a Summon window |
| `streamdeck/` | The Stream Deck plugin (JavaScript on Node.js) |
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
description, title, prompt, and optional skills. Use `{{input}}` in the title or prompt for the task's
input. Every task uses one required text area for the request and context. Selected skill references are appended automatically. The Custom task is editable and always
remains available. Changes affect new tasks; existing conversations keep their original prompts.

Presets are saved per user in `~/Library/Application Support/Agenticious/task-presets.json`. A damaged saved
file is preserved and reported instead of silently overwritten. On first launch, the bundled `task-presets.json`
seeds this file; after that, the saved config supplies the presets without merging built-in definitions. Old field
labels, hints, and required flags are ignored. The included presets are generic starting points,
so customize their prompts and skill choices for your workflow. The starter set includes Custom task, Chat,
Implement, Resolve & merge, Review PR, Fix CI, Ask for review, and Technical discovery.
They follow the selected project’s conventions without requiring specific skills, labels, Slack channels,
or local paths. Existing user configs are not replaced or extended when the app is updated.

**Recent inputs.** Each preset remembers the task inputs it was started with. Under **Task input**, the Summon sheet
(and the floating Summon window) shows a **Recent** row with the selected preset's last five, newest first: up to
three lines of each and how long ago it was used. Click one to put it in **Task input** in place of what is there;
**⌘Z** brings back what you had typed. Hover a box and click **×**, or right-click it and choose **Remove from recent**,
to forget it. Switching presets, by click or by shortcut, switches the row. An input is remembered when an agent or
chat starts with it, trimmed and without images or workspace; using the same text again moves it to the front. Up to
20 per preset are kept in `~/Library/Application Support/Agenticious/prompt-history.json`, and a deleted preset's
inputs are dropped. They stay on this Mac: the Stream Deck plugin and agent hooks never receive them. A missing or
damaged file only means no recent inputs.

**Shortcuts.** Give a preset a shortcut in its editor: click **Record shortcut** and press the keys, for example
`⌃⌥R` (Esc cancels). It needs ⌘, ⌃ or ⌥ unless it is a function key, and standard shortcuts such as ⌘V, ⌘S or
⌘Q are refused. From then on, pressing it in any app while Agenticious is running opens a floating Summon window over what you
are working on, with that preset selected and the workspace you last summoned in. **Start agent**
(⌘ Return), **Cancel** or Esc closes it and you carry on where you were: the agent starts in the background and
the main window stays put, still showing what it was showing. Pressing another preset's shortcut while the window
is open switches the preset and keeps what you typed, and leaves the window where it is. **Customize → Preferences →
General → Summon window opens** decides where it appears: in the middle of the main display (the one with the menu
bar; the default), in the middle of the display you are using, or over the window you are working in. Shortcuts need no Accessibility permission. **Browse…** makes Agenticious the active app for the
folder picker; closing the Summon window hands you back to the app you were in. Pressed while Agenticious itself is
in front, a shortcut works like **⌘N** and the main window turns to the new agent.

No preset has a shortcut until you record one. Two presets can't share a shortcut: the editor says who has it,
and in a hand-edited file the first preset keeps it. A shortcut that can't work is flagged on its preset's card.
macOS doesn't report a shortcut another app already uses, so if nothing opens, pick another. When two copies of
Agenticious run (a dev build beside the installed app), the first one started holds the shortcuts and the other
flags them on its cards. Shortcuts are
saved with the preset as an optional `hotkey`, e.g. `{ "key": "R", "keyCode": 15, "modifiers": ["control", "option"] }`;
`keyCode` is the physical key, so the shortcut stays on it when the keyboard layout changes.

**Stream Deck.** The plugin in `streamdeck/` puts every preset on a 15-key Stream Deck behind one key. The
**Agenticious** key (the app's icon) opens a page with **Back** at the top left and a key for each preset, in the
order you arranged them, so a preset keeps its place whichever you use most. Each key is drawn by the app like the
preset's card: its name above its symbol. Pressing one opens the floating Summon window on that preset, exactly as
its shortcut would, and returns the deck to the profile it was showing; presets need no shortcut for this. Past 14
presets the last key becomes **More**. The page follows preset edits within a couple of seconds, and says
**not running** when Agenticious is closed or older than the plugin.

```sh
cd streamdeck
npm ci --ignore-scripts
npm test
node build.js   # dist/com.mati.agenticious.sdPlugin
```

Quit Stream Deck, copy `dist/com.mati.agenticious.sdPlugin` into
`~/Library/Application Support/com.elgato.StreamDeck/Plugins/`, start Stream Deck again, and drag **Agenticious**
from the action list onto a key. The first press installs the bundled page. The plugin talks to the app's loopback
port (`GET /presets`, `POST /summon/<preset-id>` on 47821, or `AGENTICIOUS_PORT`); the app ignores those requests
when a browser sends them for a web page. It needs Stream Deck 6.5 or later.

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

For UI inspection, `--settings`, `--skills`, `--new-agent [preset-id]`, and `--summon-panel [preset-id]` (the
floating window, saved as `Summon agent.png`) can be combined with `--snapshot-dir /tmp/agenticious-shots`. Run configuration and skill tests with `swift test`.

## Next steps

- Persist sessions across app restarts (`claude --resume`, `codex resume`)
- System notifications (needs a proper `.app` bundle)
- Codex approval prompts don't trigger a hook yet, so they only show up if the agent calls `need_human`

### Navigation and menu bar

The sidebar shows active agents grouped by workspace. **History** below the workspace list opens archived agents, newest first, with 20 results per page. Search by task, workspace, branch, or provider; opening an agent and returning to History preserves your search and page. Tasks stay in **Queue** regardless of their status. Use **Mark as finished** at the bottom of an agent view to stop it, clean up its resources, and move its history to **History**. **Move to Queue** restores the saved task to the list; it does not recreate a removed worktree. Resume is available only while its working directory still exists. Existing completed tasks return to Queue when upgrading to this manual behavior. Each card uses its status color for its background tint and border, with a stronger border for the selected sidebar card. Each card shows its provider, status, task, and completed steps; select a card to return to its terminal, or right-click for session actions. Use the folder button beside **Workspaces** to add a project.

The top bar shows Codex model-specific quota availability (such as **GPT-6 Astra: Available** or **Limit reached**) separately from its account percentages. Provider limits stay side by side while there is room, hiding the Control Room label before stacking in a narrow window. Summon agents from the workspace buttons, with **⌘N**, or from any app with a preset's shortcut. The live usage response reports availability and an optional reset time rather than a percentage. It refreshes at the usage-check interval in Preferences using your existing Codex sign-in. If a refresh fails, the last result is explicitly labeled as last reported; account percentages continue to come from local logs.

Below the sidebar branding, **Agents** counts tasks outside history, **Working** counts starting or actively working agents, and **Needs you** counts agents blocked on your input or approval, including those showing **Permission required**. Waiting and idle processes do not count as working.

**Customize** keeps task presets, skills, and preferences together while the agent sidebar stays visible. Preferences are split into sections: **General** (sidebar branch names, default worktree behavior, text size, where the Summon window opens), **Notifications**, and **Background refresh** (how often provider connections and usage limits are checked). The macOS menu bar shows a monochrome “A” with a spark, with a count only when agents need your attention.

Every agent has an **Archive** button beside its status and step count, plus an archive action in its right-click menu. Archiving stops its process, descendants, and owned terminal process group (escalating to kill if needed), releases the terminal, removes its per-session launch configuration, and attempts to remove its worktree. Known leftover provider processes are identified by this session's exact launch markers after a restart. **Mark as finished** uses the same cleanup. History and Git branches are preserved; worktrees with uncommitted changes or another queued agent are kept, with a warning. The main checkout and shared scratch folder are never removed. Archived activity is read once without background polling. Use the Archive button or **Retry archive cleanup** to retry worktree cleanup on older finished tasks.

### Text size

**Customize → Preferences → General → Text size** scales the app's text from 100% to 150% in steps of 10%, and applies as you choose: the main window with its sheets and popovers, the menu bar panel, the floating Summon window, reply boxes, and the embedded terminal, which reflows to the new size. **View → Make Text Bigger** (**⌘+**, or **⌘=** without Shift), **Make Text Smaller** (**⌘−**), and **Actual Size** (**⌘0**) do the same from the keyboard while the main window is in front. Symbols set in text grow with it, and a box that holds text grows where the text would otherwise be cut off; spacing, corner radii, and decorative sizes stay as they are. Menus, alerts, tooltips, segmented controls, and the menu bar itself are drawn by macOS and keep the system's size.

macOS apps do not follow a system-wide text size on their own, so this is the app's own setting. It is stored as `textScale`: launching with `-textScale 1.3` tries a size for one run without saving it; choosing a size in the app during that run takes over from the argument and is saved.

### Provider diagnostics

Open the connection-status button beside the usage meters, then **Manage providers**, to check Claude Code and Codex account access and MCP status in your home folder or a selected project. The toolbar warning icon opens a compact provider summary. Checks run while Agenticious is the active app, at the interval set in **Preferences → Background refresh** (every 6 hours by default); **Refresh** and changing the folder run a fresh check. Authentication and connection failures include recovery instructions.

Claude checks MCP connections; Codex reports configured authentication without claiming the server is reachable. Session-only MCP overrides and worktree configuration can differ from these folder checks. Raw command output, server URLs, and credentials are not shown. Run the displayed provider commands in that folder for full details, then refresh after fixing an issue.

### Pull request links

Agent details show saved PR links above the step cards. Full HTTPS PR URLs in task text, Claude tool results, progress notes, and completion summaries are captured automatically. Agents use `set_pull_requests` to attach verified links as soon as they identify or create a PR, including every PR in a stack. Bare numbers must first be resolved against the actual repository by the agent. Links are deduplicated and kept across app restarts, including in Finished sessions. Existing sessions can report links in progress notes even without the new MCP tool.

Step cards use equal heights; hover a card to read its complete title and note.

### Activity and terminal

Agent details default to **Activity**, a structured view of provider messages and tool calls. Command/input blocks include copy controls and working-directory context; long inputs and output can be expanded, errors open automatically, and unknown result statuses remain neutral. Markdown emphasis, links, and fenced code blocks render separately. Use **Terminal** or **Respond in terminal** for replies, approvals, interactive prompts, and raw output. Switching tabs keeps the agent process alive.

When Claude asks with its question tool, the question appears pinned at the top of Activity: each question with its options (single or multiple choice) and an **Other** field. **Send answers** returns them to Claude through a held `PreToolUse` hook, so Claude continues without showing its menu. **Answer in terminal instead** releases the hook and Claude's own menu appears. A held question waits up to a day before falling back to the terminal. When the agent finishes its turn or asks with `need_human`, a reply box at the bottom of Activity types your reply into its prompt. A card arriving takes the box away until it is answered, and what you had typed is there when the box returns. Claude's permission requests get a card of their own (see **Permission requests** below); startup prompts are still answered in the terminal.

Activity reads the session's local Claude or Codex JSONL log every two seconds while visible. Claude sessions are matched by conversation ID. Codex uses its reported conversation ID or a unique marker added to new Agenticious prompts, never just the workspace folder. Older Codex sessions without a known ID may need to finish a turn before activity becomes available. Private reasoning records are not displayed. Provider log formats may change; when a log is unavailable, use the terminal.

The view reads up to the latest 4 MiB, shows at most 200 entries, and labels content truncated beyond 32 KiB per field. Activity history comes from the provider's log, so disabling or deleting those logs also removes that history from this view. No additional transcript copy is saved by Agenticious.

The summon sheet remembers the last task preset and workspace, plus provider, model, and effort (model and effort separately per provider). Opening a workspace's **+** button still selects that workspace explicitly. Removed favorites are not restored as the default workspace. A preset's shortcut opens on the last workspace whichever agent is selected. The larger sheet adapts to the available display size and keeps model selection beside the compact provider choices.

Provider icons use monochrome template rendering. The Claude mark comes from the official Claude desktop app (`TrayIconTemplate@3x.png`); the OpenAI mark used for Codex comes from the official ChatGPT app (`webview/assets/openai-logo-regular-ceb75a1754fa.svg` in `app.asar`). Their trademarks belong to Anthropic and OpenAI.

### Permission requests

When Claude Code is about to ask whether it may run a command, edit a file, or use another tool, the request appears as a card pinned at the top of Activity, and the agent's status becomes **Permission required**: orange with a lock, in the sidebar, the overview, the agent's banner, the dock badge, and the menu-bar count. The card shows what Claude sent, as it sent it: the command, the file with the text to replace and its replacement, a new file's contents, the URL, or the raw input of any other tool, plus the folder Claude is working in. Any other field of the input is listed under **Also sent**, because **Allow** approves the whole input, and a command Claude asked to run outside its sandbox says so beside the buttons. Nothing is rendered as Markdown or cut short by lines, and characters that could hide or reorder a command are spelled out as their code points: escape sequences, right-to-left overrides, zero-width and other invisible characters, and every blank other than the ordinary space. Claude's own words (its description of a command, and what it asks of a fetched page) never run, so there the no-break and ideographic spaces, joiners and the emoji selector that ordinary writing uses are left as they are; commands, file paths and file contents are always spelled out. A long block says how long it is at its top.

While the request keeps a fair share of the card above the buttons, at every text size, only the request scrolls and the buttons and any warning stay pinned under it. **Allow** and **Allow, and don't ask again** stay off until the end of the request has been on screen there: a short request needs no scrolling, and a long one says there is more below. In a pane too short for that, the whole card scrolls instead, and since the buttons could then be on screen without the request, **Allow** and **Allow, and don't ask again** are off, with a line saying to make the window taller or answer in the terminal; **Deny**, the note and **Answer in terminal instead** still work. A request with a part too long to draw (over 60,000 characters) can be denied or handed to the terminal from the card, but not allowed.

- **Allow** lets this one call run.
- **Deny and stop** refuses it and ends Claude's turn, like **No** in its own menu; the reply box then waits for your next message. Type a note first and the button reads **Deny with note**: Claude is told the call was rejected, gets your note, and carries on. A subagent is always told and carries on.
- **Allow, and don't ask again** is offered only when Claude itself suggests remembering allow rules, and only when all of them are kept for this session or all are saved in the folder's `.claude/settings.local.json`. The row names the rules and where they go, and applies Claude's suggestion unchanged. Suggestions that switch the permission mode, add folders, write to shared or user-wide settings, or mix the two places are not offered here; choose those in the terminal.
- **Answer in terminal instead** takes the card away and opens the terminal.

The buttons wake a moment after a card appears, so a click meant for the previous card can't answer the next one, and **Allow** has no keyboard shortcut. A decision is sent only by a click on a card that is still waiting. Everything else gets an empty reply, which Claude reads as no answer and leaves to its own menu: a key typed in the terminal, the tool already ran, Claude's turn ended, the agent was paused, archived or ended, a thirteenth request arrived while twelve were waiting, or Agenticious quit. Nothing is ever allowed for you. A note to Claude is sent up to 2,000 characters, and the card says when one runs longer.

A request alerts as soon as its card appears, with one exception: while you are at that agent's own terminal, where Claude's menu is already in front of you, a main-agent request stays silent, and alerts only if it is still unanswered when Claude sends its own notice about six seconds later. A subagent's request always alerts at once. The macOS notification for a request has only **Open**: a banner can't show the command, so it never answers one.

Claude's own menu stays open in the terminal the whole time, and whichever is answered first wins. A key typed in the agent's terminal takes the card away and leaves the status to Claude's own signals: **Working**, then **Permission required** if its menu is still waiting about six seconds later. (If the status underneath would open the reply box, it shows **Permission required** instead until Claude's turn ends, so a reply can't be typed onto a menu the key may have left up.) The tool running because you said yes there removes the card too. **Answer in terminal instead** keeps **Permission required** with the request named until Claude is seen to move on: the tool runs, Claude starts something else, or, for the main agent's own request, its turn ends. If Claude's hook goes away without an answer, the card goes and the status asks you to continue in the terminal. For some commands Claude's menu carries a safety warning that it does not pass on; the card then says so beside the buttons, and it is worth reading in the terminal before allowing. A background subagent's request is the exception: it shows only as a card, titled with the subagent, until you answer it or hand it to the terminal, where its menu then appears. While a subagent's menu handed over that way is unanswered, the reply box stays closed, since a typed reply would land on that menu; it opens again when that call finishes or fails, when the subagent stops, or once Claude has written that call's result to the subagent's log (a subagent stopped mid-run sends no hook), which is checked when the main agent next reports in. The subagent's other calls don't count, since read-only calls run side by side with a menu, and neither do other subagents' calls, which leave any wait handed to the terminal in place. Its **Permission required** then clears at the main agent's next turn end or prompt. Archiving hands held cards back the same way, so if the agent outlives a failed archive, the box stays closed onto the menus that brings up. Requests queue per agent, one card at a time with a count of those waiting, and a held request waits up to a day.

Questions and plan reviews keep their own paths. Startup prompts, sandbox network prompts, and anything else Claude asks without this hook are answered in the terminal; when Claude reports one as a permission prompt, the status still reads **Permission required**. Codex has no approval hook, so its approvals stay in its terminal and show up here only if the agent calls `need_human`. The hook is written when an agent starts or resumes, so an agent from before this version gets cards after its next **Resume**.

### Subagents

When a Claude agent starts subagents with its Agent tool, each one appears as a small card nested under the agent in the sidebar, with its description, status, and what it is doing now. Running subagents stay in view; done, failed, and stopped ones fold into a summary line you can expand. Select one to read its own Activity from Claude's `subagents/agent-<id>.jsonl` log. Subagents run inside their agent's process, so they have no terminal or controls of their own: pausing or ending the agent stops them, and you talk to them through the agent. After Agenticious restarts, earlier subagents come back from Claude's logs, marked done or failed from the agent's log, or stopped if they were cut off.

### Cleanup tasks

Agents often make things outside their worktree's files: a test database, another git worktree, a dev server, a Docker container. The built-in prompt asks them to register a command that removes each one with the `add_cleanup` tool as soon as they create it. The agent's page lists these under **cleanup tasks run when this agent ends**, where you can drop any you don't want.

For commands every agent in a workspace needs, right-click the workspace in the sidebar and choose **Cleanup commands…**. Enter one per line; lines starting with `#` are skipped. For example:

```sh
bin/spring stop
```

Both kinds run whenever the agent is archived: **End agent**, **Mark as finished**, **End chat**, and **Archive**. They run after the agent's processes are stopped and before its worktree is removed, in a login shell in its working directory, with `AGENTICIOUS_WORKTREE`, `AGENTICIOUS_BRANCH`, `AGENTICIOUS_DIRECTORY`, `AGENTICIOUS_PROJECT`, and `AGENTICIOUS_SESSION` set. Each command gets two minutes. A failed command is reported and kept, so **Retry archive cleanup** runs it again; workspace commands run on every attempt, so make them safe to repeat.

### Ended tasks

Agents report **Ended** with the `end` tool when you cancel work, ask them to stop, or hand it to another session. This clears Needs you while retaining the reason and unfinished steps; it does not claim success or archive resources. Clear final stop-and-handoff messages are also recognized from provider completion notifications for older sessions. Questions, conditional suggestions, and ordinary pauses are not treated as endings. For an already-stale session, right-click its card and choose **Mark as ended**. Archive remains the action that stops processes and cleans up resources. A new plan or resumed session can start work again.

## Chat tasks

Choose **Chat** when summoning an agent to research a question or talk through an idea. Chat uses the selected workspace for context without creating a worktree, and does not require a step plan. The conversation shows your question, the agent's replies, and follow-up messages; **Research activity** reveals tool calls when you want the supporting detail. Replies support formatting, code blocks, and clickable source links. Answers leave the chat open for your next message. **End chat** stops the agent and saves the conversation in **History**, without marking unfinished research steps complete.

Keep screenshots and UI captures outside the repository, including temporary files used for reviews.
Only app assets and reusable artwork belong in the source tree.
