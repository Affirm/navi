# Navi - Claude Code Session Monitor

Navi is a floating macOS window that monitors all your Claude Code sessions. It shows which sessions have finished, which need permission approvals, and lets you approve/deny permissions without switching terminals.

Navi is a Claude Code plugin. Hooks are defined in `hooks/hooks.json` and registered automatically when the plugin is installed.

This file contains instructions for Claude Code agents. For human contributor guidance (dev setup, architecture, feature flag system, how to add features), see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Setup Instructions

When the user asks to "set up Navi", "install Navi", or similar:

**Before running any commands, tell the user what you're about to do** (build the app and launch it — hooks are handled by the plugin system) **and use the AskUserQuestion tool with Yes/No options to confirm before proceeding.**

1. Build the app:
   ```bash
   bash build.sh
   ```

2. Launch the app:
   ```bash
   open Navi.app
   ```

3. Confirm to the user that Navi is installed. It will auto-launch on future hook events even if closed.

**If the user wants manual-launch only**, also add `NAVI_NO_AUTO_LAUNCH` to the `env` section of `~/.claude/settings.json`:
   ```json
   {
     "env": {
       "NAVI_NO_AUTO_LAUNCH": "1"
     }
   }
   ```
   With this set, events are still written to `/tmp/navi/events/` and will be picked up when the user manually runs `open Navi.app`.

## Removal Instructions

When the user asks to "remove Navi", "uninstall Navi", or similar:

**Before running any commands, tell the user what you're about to do** (kill the running app and clean up temp files) **and use the AskUserQuestion tool with Yes/No options to confirm before proceeding.**

1. Kill the running app:
   ```bash
   pkill -x Navi 2>/dev/null
   ```

2. Clean up temp files:
   ```bash
   rm -rf /tmp/navi
   ```

3. Confirm to the user that Navi has been removed. The plugin can be uninstalled with `claude plugin uninstall navi`.
