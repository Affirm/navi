# Navi

A lightweight macOS monitor for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions. Navi sits as a floating window on your screen and shows you what your Claude Code sessions are doing across all your terminals — which ones are working, which have finished, which need permission approvals, etc.

## Features

- **Session status** — shows whether each session is Working (green gear), Idle (blue ellipsis), or needs attention (orange)
- **Session discovery** — finds running Claude Code sessions automatically by scanning `~/.claude/sessions/`, no hook event needed
- **Permission requests** — approve or deny tool permissions directly from Navi without switching to the terminal
- **Auto-dismiss** — automatically dismisses stale permission cards when approved in the terminal or when the turn ends
- **Terminal focus** — click "Jump to Terminal" to switch to the correct terminal tab for any session
- **Multi-session overview** — monitor multiple concurrent Claude Code sessions at a glance
- **Session names** — shows the session name (from `/rename`) instead of the project folder
- **Always-on-top** — floats above other windows so you never miss an event
- **Menu bar icon** — toggle the window from the menu bar; icon changes when permissions are pending
- **Auto-launch** — the app builds and launches itself the first time a hook fires
- **Per-event sounds** — configurable alert sounds for permission requests, completions, and notifications
- **Configurable font size** — scale text from 80% to 140%
- **Remembers position** — window reopens where you left it

## Requirements

- macOS (tested on macOS 15+)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 (ships with macOS)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Installation

### As a Claude Code plugin (recommended)

```shell
/plugin marketplace add Affirm/navi
/plugin install navi@navi
```

Hooks are registered automatically by the plugin system. The app will build and launch itself the first time a hook fires.

### Manual setup

1. Clone this repo and build:
   ```bash
   git clone https://github.com/Affirm/navi.git
   cd navi
   bash build.sh
   open Navi.app
   ```

2. Register the hooks from `hooks/hooks.json` in your `~/.claude/settings.json`, replacing `${CLAUDE_PLUGIN_ROOT}` with the absolute path to this directory. The hooks to register are:
   - `PermissionRequest` — sync, 120s timeout (permission approve/deny flow)
   - `Stop` — async (session finished responding)
   - `StopFailure` — async (session stopped due to error)
   - `Notification` — async (attention needed)
   - `PreToolUse` — sync, 2s timeout (captures tool_use_id for auto-dismiss)
   - `PostToolUse` — async (resolves pending permissions on tool success)
   - `UserPromptSubmit` — sync, 2s timeout (signals "Working" status)
   - `PostToolUseFailure` — async (resolves pending permissions on tool failure)

## Settings

Click the gear icon in Navi to configure:

### General

| Setting | Default | Description |
|---------|---------|-------------|
| Auto-launch Navi | On | Automatically launch Navi when Claude triggers a hook event |
| Permission sound | On (Glass) | Play a sound when a permission request arrives |
| Finished sound | Off | Play a sound when a session finishes responding |
| Notification sound | Off | Play a sound when a notification arrives |
| Font size | 100% | Scale text size from 80% to 140% |

### Experimental

| Setting | Default | Description |
|---------|---------|-------------|
| Jump to terminal | On | Adds a "Jump to Terminal" button on each session |
| Menu bar icon | On | Adds a menu bar icon for Navi |
| Floating window | On | Always-on-top floating window (nested under menu bar) |
| Auto-dismiss | On | Dismiss permissions when approved in terminal; shows "Respond in terminal" after hook timeout |
| Session names | On | Show session name (from `/rename`) instead of project folder |
| Session status | On | Show Working/Idle status per session; dead sessions auto-clean immediately |
| Instant notifications | On | Use filesystem watcher instead of polling for near-instant event detection |

Each sound can be set to any macOS system sound (Glass, Ping, Submarine, etc.).

## How it works

```
Claude Code session
  │
  ├── UserPromptSubmit ──→ userpromptsubmit.sh ──→ writes working signal ──→ /tmp/navi/events/
  ├── PreToolUse ────────→ pretooluse.sh ────────→ captures tool_use_id ──→ /tmp/navi/pretooluse/
  ├── PermissionRequest ─→ hook.sh → parse_event.py → event JSON ─────────→ /tmp/navi/events/
  ├── PostToolUse ───────→ hook.sh → parse_event.py → resolve signal ─────→ /tmp/navi/events/
  ├── Stop ──────────────→ hook.sh → parse_event.py → event JSON ─────────→ /tmp/navi/events/
  ├── StopFailure ───────→ hook.sh → parse_event.py → event JSON ─────────→ /tmp/navi/events/
  ├── Notification ──────→ hook.sh → parse_event.py → event JSON ─────────→ /tmp/navi/events/
  └── PostToolUseFailure → hook.sh → parse_event.py → resolve signal ─────→ /tmp/navi/events/

~/.claude/sessions/*.json ──→ Navi session discovery (PID liveness + TTY lookup)

Navi.app
  ├── polls /tmp/navi/events/ (instant via kqueue watcher + fallback timer)
  ├── discovers sessions from ~/.claude/sessions/
  ├── tracks Working/Idle/Dead status per session
  └── displays events in SwiftUI floating window + menu bar popover
        │
        User clicks Approve/Deny
        │
        writes response to /tmp/navi/responses/<event-id>
        │
        hook.sh reads response, returns decision to Claude Code
```

**Permission flow:** When Claude Code needs permission for a tool, `hook.sh` writes an event file and polls for a response file. Navi displays the request with Approve/Deny buttons. When you click one, Navi writes the response, `hook.sh` picks it up and returns the decision to Claude Code. If no response comes within 120 seconds, it falls back to the terminal prompt. If you respond in the terminal instead, the PostToolUse hook fires and Navi auto-dismisses the card.

**Session status:** `UserPromptSubmit` fires synchronously when the user sends a message, setting the session to "Working". `Stop`/`StopFailure` events transition it to "Idle". Working signals are processed after regular events in each poll cycle to prevent race conditions with stale Stop events.

**Session discovery:** Navi continuously scans `~/.claude/sessions/*.json` for running Claude processes (verified via `kill(pid, 0)`). Discovered sessions appear immediately with their name, TTY, and liveness status — no need to wait for a hook event.

**Other events:** `Stop`, `StopFailure`, and `Notification` events are fire-and-forget (async) — they show up in the UI and auto-dismiss after 60 seconds.

**Cleanup:** Event files in `/tmp/navi/events/` are deleted by the app immediately after being read. Response files in `/tmp/navi/responses/` are deleted by `hook.sh` after being read. Every hook invocation prunes files older than 5 minutes from both directories.

## Files

| File | Description |
|------|-------------|
| `main.swift` | SwiftUI app — event monitor, session grouping, session discovery, status tracking, settings, menu bar icon, and floating window UI |
| `hooks/hook.sh` | Shell script called by Claude Code hooks — launches app, captures TTY/PID, invokes parser, handles permission polling |
| `hooks/pretooluse.sh` | Lightweight PreToolUse hook — captures `tool_use_id` for auto-dismiss |
| `hooks/userpromptsubmit.sh` | Lightweight UserPromptSubmit hook — signals "Working" status for session tracking |
| `hooks/parse_event.py` | Parses hook JSON payload and writes event/resolve files to `/tmp/navi/events/` |
| `hooks/hooks.json` | Hook registrations for the plugin system |
| `build.sh` | Compiles `main.swift` into `Navi.app` |
| `Info.plist` | App bundle metadata (LSUIElement keeps it out of the Dock) |

## Uninstall

### Plugin

```bash
claude plugin uninstall navi
pkill -x Navi 2>/dev/null
rm -rf /tmp/navi
```

### Manual

1. Remove all Navi hook entries from `~/.claude/settings.json` (PermissionRequest, Stop, StopFailure, Notification, PreToolUse, PostToolUse, UserPromptSubmit, PostToolUseFailure)

2. Kill the app and clean up:
   ```bash
   pkill -x Navi 2>/dev/null
   rm -rf /tmp/navi
   ```

## License

BSD 3-Clause — see [LICENSE](LICENSE).
