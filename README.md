# Resume AI Session

A centered, telescope-style overlay for Omarchy that finds past AI coding
sessions and opens the one you pick in Herdr, or in a terminal if Herdr
is not in play. `preview.png` is the marketplace shot.

One picker for every agent the machine already knows about: search, preview,
and resume Claude Code, Codex, Grok, OpenCode, Pi, and anything that registers
the same way.

## What you get

- A fullscreen overlay with a search field, a session list, and a live
  transcript preview
- Sessions from Claude Code, Codex, Grok, OpenCode, and Pi out of the box
- Resume in the session's original working directory. If a Herdr session is
  running, Enter opens there. If Herdr is installed but idle, the overlay
  asks first. Otherwise it uses `xdg-terminal-exec --dir` with the same
  unattended flags `omarchy agent` already uses
- Automatic names and default-agent highlighting from Omarchy's existing
  agent registration (usage records + `~/.config/omarchy/defaults/agent`)
- A drop-in adapter contract so a new agent never needs a plugin patch

Summon it:

```
omarchy-shell shell toggle anagrius.resume
```

Or press Super+Alt+A after the binding below is in place. The Omarchy menu
gains a **Trigger > Resume AI Session** entry as well.

## Why it hooks into Omarchy agents

Omarchy already has a registration path for coding agents:

- `omarchy default agent <name>` writes `~/.config/omarchy/defaults/agent`
- `omarchy-agent-usage-<id>` collectors publish a JSON record to
  `~/.local/state/omarchy/agents/usage/`
- `omarchy agent` launches the chosen CLI with the right “don't stop to ask”
  flags and the shared `org.omarchy.agent` window class

Resume AI Session reads those same records for display names and resumes with
the same launch flags so a resumed session behaves like one started from the
keybinding.

Adding an agent to the picker is the same move as adding one to the usage
panel: ship a collector. For sessions, the collector is named
`omarchy-agent-sessions-<id>`.

## Adapter contract

The overlay discovers session sources in this order. A later match with the
same id wins, so a user adapter can replace a bundled one.

1. Built-in adapters for Claude, Codex, Grok, OpenCode, and Pi
2. `~/.config/omarchy/agents/sessions/<id>` (next to agent config such as
   `~/.config/omarchy/agents/fireworks.json`)
3. `omarchy-agent-sessions-<id>` on `PATH`, including `$OMARCHY_PATH/bin`

An adapter is an executable that speaks three commands:

```
adapter list [--limit N]
adapter preview <session-id>
adapter resume <session-id>
```

`list` prints a JSON array, a `{ "sessions": [...] }` object, or JSONL.
Each session is:

```json
{
  "id": "abc123",
  "title": "Fix the idle lock flicker",
  "cwd": "/home/you/code/app",
  "updatedAt": "2026-08-15T18:01:00+00:00",
  "model": "grok-4.6",
  "messageCount": 12,
  "snippet": "The lock screen flashes on resume."
}
```

`preview` prints the transcript as plain text.

`resume` prints the launch plan, then the overlay opens it in a terminal:

```json
{
  "command": ["my-agent", "--resume", "abc123"],
  "cwd": "/home/you/code/app"
}
```

See `examples/omarchy-agent-sessions-example` for a complete adapter. World-writable
files are ignored.

Optional config lives at `~/.config/omarchy/resume.json`:

```json
{
  "groupBy": "date",
  "sources": {
    "claude": { "enabled": true },
    "codex": { "enabled": false }
  }
}
```

`groupBy` is `date` (Today / Yesterday / June 10) or `project`. Project grouping
collapses git worktrees and jj workspaces to the main checkout, so
`berserk` stays one group. Paths without git or jj group by the folder the
session started in. Agent names are still searchable; they are no longer a
primary filter.

## Keys

| Key | Action |
|-----|--------|
| type | Filter the list |
| Backspace / Ctrl+Backspace / Ctrl+U | Edit or clear the filter |
| ↑ ↓ / Ctrl+J Ctrl+K / Ctrl+P Ctrl+N | Move the selection |
| Page Up / Page Down | Scroll the preview |
| Tab / Ctrl+G | Change grouping (`Tab:change grouping (date)` or `(project)`) |
| Ctrl+Y / Ctrl+C / Shift+Enter | Copy the transcript |
| Ctrl+O | Open in another installed agent |
| Ctrl+R | Rescan sessions (ignore the on-disk index) |
| Enter | Resume the selected session (in Herdr when a session is running) |
| Esc | Clear the filter, close the Herdr prompt, or close |

Copy puts a pasteable handoff on the clipboard: title, original agent,
directory, and the conversation labeled User / Assistant. Open-in starts a
*new* session in another installed agent (the same launch flags as
`omarchy agent`) in the original working directory. A short transcript is
passed as the first prompt; a long one is written owner-only (mode 0600) to
`~/.cache/omarchy/resume/handoffs/` and removed after 24 hours. The new agent
is asked to read that file.
This is not a converted native session — it is a clean continuation prompt.

## Herdr

If `herdr` is on `PATH` and a session is already running, resume and
open-in land in that session: a matching project workspace gets a new
tab, otherwise a workspace is created for the session directory. An
existing Herdr window is focused; a second client is not launched.

If Herdr is installed but no session is running, Enter asks whether to
start one. **Herdr** launches `omarchy launch terminal herdr` and opens
the agent there. **Terminal** keeps the previous standalone-window
behavior. Esc dismisses the prompt without launching anything.

```
resume herdr-status
resume resume grok <session-id> --herdr
resume resume grok <session-id> --terminal
```

```
resume copy grok <session-id>
resume open grok <session-id> --agent claude
```

The overlay accepts a JSON payload, so other plugins can open it already
narrowed:

```
omarchy-shell shell summon anagrius.resume '{"source":"grok","cwd":"/home/you/code/app"}'
```

## Install

```
omarchy plugin add https://github.com/anagrius/omarchy-resume.git --enable
```

Summon it with:

```
omarchy-shell shell toggle anagrius.resume
```

Optional Super+Alt+A binding in `~/.config/hypr/bindings.lua`:

```
o.bind("SUPER + ALT + A", "Resume AI Session", "omarchy-shell shell toggle anagrius.resume")
```

## Remove

```
omarchy plugin remove anagrius.resume
```