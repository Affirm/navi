# Navi 🧭

**A floating macOS monitor for Claude Code sessions**

See what every Claude Code session is doing across all your terminals — at a glance, from one floating window.

[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://github.com/Affirm/navi)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2)](https://docs.anthropic.com/en/docs/claude-code)

## Installation

```shell
/plugin marketplace add Affirm/navi
/plugin install navi@navi
```

Hooks are registered automatically. Navi builds and launches itself the first time an event fires.

## What You Get

| Feature | Description |
|---------|-------------|
| **Session status** | Working (green), Idle (blue), needs attention (orange) at a glance |
| **Inline permissions** | Approve or deny tool permissions without switching terminals |
| **Session discovery** | Auto-detects running sessions by scanning `~/.claude/sessions/` |
| **Jump to terminal** | One-click focus the correct terminal tab for any session |
| **Auto-dismiss** | Stale permission cards clean up when approved in the terminal |
| **Menu bar icon** | Toggle the window; icon signals pending permissions |
| **Per-event sounds** | Configurable alerts for permission, completion, notification events |
| **Multi-session** | Monitor many concurrent Claude Code sessions side-by-side |

## Requirements

- macOS (tested on macOS 15+)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3 (ships with macOS)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

## Settings

Click the gear icon to configure sounds, font size, and experimental features (jump-to-terminal, menu bar icon, session status, instant notifications, etc.). Each feature is independently toggleable; most default on.

Each sound can be set to any macOS system sound (Glass, Ping, Submarine, etc.).

## Manual Setup

If you'd rather not use the plugin system:

```bash
git clone https://github.com/Affirm/navi.git
cd navi
bash build.sh
open Navi.app
```

Then register the hooks from `hooks/hooks.json` in your `~/.claude/settings.json`, replacing `${CLAUDE_PLUGIN_ROOT}` with the absolute path to this directory.

## How It Works

Claude Code hooks (`PermissionRequest`, `Stop`, `Notification`, etc.) write event files to `/tmp/navi/events/`. The Navi app watches that directory and renders events in a SwiftUI floating window. For permission requests, `hook.sh` writes the event and polls for a response file; when you click Approve/Deny, Navi writes the response and the hook returns the decision to Claude Code. If no response comes within 120 seconds, it falls back to the terminal prompt.

For architecture details, see [`CLAUDE.md`](CLAUDE.md).

## Uninstall

```bash
claude plugin uninstall navi
pkill -x Navi 2>/dev/null
rm -rf /tmp/navi
```

## Development

```bash
git clone https://github.com/Affirm/navi.git
cd navi
bash build.sh        # Compiles main.swift into Navi.app
open Navi.app        # Launch
```

The app is a single-file SwiftUI app (`main.swift`) compiled with `swiftc`. No other dependencies. See [`CLAUDE.md`](CLAUDE.md) for the feature-flag system and guidance on adding experimental features.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
