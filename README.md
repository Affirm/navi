# Navi 🧭
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)](https://github.com/Affirm/navi)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-plugin-8A63D2)](https://docs.anthropic.com/en/docs/claude-code)

**A floating macOS monitor for Claude Code sessions**

See what every Claude Code session is doing across all your terminals — at a glance, from one floating window.



<img width="364" height="277" alt="Screenshot 2026-04-20 at 1 13 09 PM" src="https://github.com/user-attachments/assets/64e85feb-0caf-4927-8181-66bae2f75430" />

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
| **Session row badges** | Optional per-session badges for working folder, git status, permission mode, model, and open PR (each independently toggleable in Settings, all default off) |

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

For permission requests, `hook.sh` writes an event file and polls for a response file. When you click Approve/Deny, Navi writes the response, the hook picks it up and returns the decision to Claude Code. If no response comes within 120 seconds, it falls back to the terminal prompt.

For architecture details and guidance on extending Navi, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

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

The app is a single-file SwiftUI app (`main.swift`) compiled with `swiftc`. No other dependencies. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the feature-flag system and guidance on adding experimental features.

## Troubleshooting

### `failed to build module 'SwiftUI'` / `this SDK is not supported by the compiler`

```
failed to build module 'SwiftUI', this SDK is not supported by the compiler
(the SDK is built with 'Apple Swift version 6.0.3 effective-5.10 (swiftlang-6.0.3.1.5),
while this compiler is 'Apple Swift version 6.0.3 effective-5.10 (swiftlang-6.0.3.1.10...)'
```

This is not a Navi bug — it means your Xcode Command Line Tools install is inconsistent: the SDK (`.swiftmodule` files for SwiftUI, AppKit, etc.) was produced by a sibling build of the Swift compiler than the one `swiftc` reports. That usually happens after a partial macOS/CLT update, or when Xcode.app and CLT end up on different update cycles.

**Check what's active:**

```bash
xcode-select -p
xcrun swift --version
xcrun --show-sdk-version
xcrun --show-sdk-path
```

`build.sh` prints the same information at the top of every build, so you can read it from the build output too.

**Fix in order of escalation:**

1. **Re-align the developer directory** (30 seconds). If you have Xcode.app installed, point to it; otherwise point to CLT:

   ```bash
   # With Xcode.app installed
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

   # CLT only
   sudo xcode-select -s /Library/Developer/CommandLineTools
   ```

2. **Reinstall Command Line Tools** (5 minutes). Most reliable fix when you don't have Xcode.app, or when alignment didn't help:

   ```bash
   sudo rm -rf /Library/Developer/CommandLineTools
   xcode-select --install
   ```

3. **Update macOS + Xcode/CLT to current.** If the versions have drifted far apart across major releases, install all pending updates in System Settings → General → Software Update, then reinstall CLT.

After any of these, run `bash build.sh` again.

## Contributors

Navi started inside Affirm's internal plugin catalog before it became this standalone repo, so not all contributors appear in this repo's git history. Thanks to:

- [@KieranLitschel](https://github.com/KieranLitschel) — improved session status (Working / Idle), session names, auto-dismiss, jump-to-terminal button

- [@manassarpatwar](https://github.com/manassarpatwar) — menu bar UI, instant filesystem-watcher notifications, plus a long tail of stability fixes

- [@tarkatronic](https://github.com/tarkatronic) — suggested open-sourcing Navi and helped with open-source setup

## License

BSD 3-Clause — see [LICENSE](LICENSE).
