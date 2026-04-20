# Navi - Claude Code Session Monitor

## What is this?

Navi is a floating macOS window that monitors all your Claude Code sessions. It shows which sessions have finished, which need permission approvals, and lets you approve/deny permissions without switching terminals.

Navi is a Claude Code plugin. Hooks are defined in `hooks/hooks.json` and registered automatically when the plugin is installed.

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

## Architecture

### File Layout

| Path | Purpose |
|------|---------|
| `main.swift` | Single-file SwiftUI app — all UI, event polling, session management |
| `hooks/hooks.json` | Registers Claude Code hooks (loaded at session start) |
| `hooks/hook.sh` | Main hook entrypoint for PermissionRequest, Stop, StopFailure, Notification, PostToolUse, PostToolUseFailure |
| `hooks/pretooluse.sh` | Lightweight PreToolUse hook — captures `tool_use_id` for auto-dismiss |
| `hooks/userpromptsubmit.sh` | Lightweight UserPromptSubmit hook — signals "Working" status for session-alive |
| `hooks/parse_event.py` | Parses hook payload JSON, writes event/resolve files to `/tmp/navi/events/` |
| `build.sh` | Compiles `main.swift` into `Navi.app` bundle |

### Event Flow

1. Claude Code fires a hook event (e.g., PermissionRequest)
2. `hook.sh` runs → conditionally captures TTY/PPID based on feature flags → calls `parse_event.py`
3. `parse_event.py` writes a JSON event file to `/tmp/navi/events/`
4. `Navi.app` polls the events directory and displays the event

### Feature Flag System

Experimental features use file-based flags at `/tmp/navi/features/<name>`. This lets hooks skip work for disabled features without modifying `hooks.json` or restarting Claude Code sessions.

**How it works:**
- **Swift side:** `FloatingWindowManager.setFeatureFlag(_:enabled:)` creates/deletes flag files. Each toggle's `didSet` calls this, and `syncFeatureFlags()` writes all flags on startup.
- **Hook side:** Scripts check `[ -f /tmp/navi/features/<name> ]` before doing feature-specific work. If the file is absent, the work is skipped.

**Two types of flag files:**
- **Boolean** (empty file): created by `setFeatureFlag(_:enabled:)`. File exists = enabled, absent = disabled.
- **Configurable** (JSON content): created by `setFeatureConfig(_:config:)`. File exists = enabled, contents carry configuration. Hooks read config with `feature_config()` (Python) or `feature_config` (shell).

Hooks should always check file existence first (is the feature enabled?) and only read config when needed. An empty file means "enabled with defaults."

## Adding an Experimental Feature

Follow this checklist when adding a new experimental feature:

### 1. Choose a flag name

Pick a kebab-case name (e.g., `my-feature`). This is used in `/tmp/navi/features/` and as the feature's identity across all layers.

### 2. Swift changes (`main.swift`)

In `FloatingWindowManager`:

```swift
// Add the published property with didSet
@Published var myFeatureEnabled: Bool {
    didSet {
        UserDefaults.standard.set(myFeatureEnabled, forKey: "NaviExp.MyFeature")
        Self.setFeatureFlag("my-feature", enabled: myFeatureEnabled)
    }
}
```

In `FloatingWindowManager.init()`, add the default-on initialization block (before the safety check):

```swift
if UserDefaults.standard.object(forKey: "NaviExp.MyFeature") == nil {
    UserDefaults.standard.set(true, forKey: "NaviExp.MyFeature")
    myFeatureEnabled = true
} else {
    myFeatureEnabled = UserDefaults.standard.bool(forKey: "NaviExp.MyFeature")
}
```

In `syncFeatureFlags()`, add:

```swift
Self.setFeatureFlag("my-feature", enabled: myFeatureEnabled)
```

In the `experimentalTab` section of `ContentView`, add the toggle:

```swift
experimentalRow("My Feature", subtitle: "Short description of what it does",
    isOn: Binding(get: { floatingManager.myFeatureEnabled }, set: { floatingManager.myFeatureEnabled = $0 }))
```

### 3. Hook changes (if needed)

If the feature needs hook-level work, gate it behind the flag file:

**In `hook.sh`** (for env var exports or shell-level work):
```bash
if [ -f "$FEATURES_DIR/my-feature" ]; then
    # feature-specific work
fi
```

**In `parse_event.py`** (for event processing):
```python
if feature_enabled("my-feature"):
    # feature-specific work
```

**In a new hook script** (if the feature needs its own hook type):
```bash
[ -f /tmp/navi/features/my-feature ] || exit 0
```

### 3b. Configurable features (if needed)

If the feature has settings beyond on/off (e.g., a timeout, a list of values):

**Swift side** — use `setFeatureConfig` instead of `setFeatureFlag` in the `didSet`:
```swift
@Published var myTimeout: Double = 120 {
    didSet {
        UserDefaults.standard.set(myTimeout, forKey: "NaviExp.MyFeature.Timeout")
        Self.setFeatureConfig("my-feature", config: ["timeout": myTimeout])
    }
}
```

**In `parse_event.py`** — read config with the helper:
```python
config = feature_config("my-feature", default={})
timeout = config.get("timeout", 120)
```

**In `hook.sh`** — read a specific config value:
```bash
MY_TIMEOUT=$(feature_config my-feature timeout 120)
```

An empty flag file means "enabled with defaults" — hooks should always fall back to sensible defaults when config is absent.

### 4. Register new hooks (if needed)

If the feature requires new hook types (e.g., a new `PreToolUse` handler), add them to `hooks/hooks.json`. Note that hooks.json is loaded at Claude Code session start — users must restart sessions to pick up new hooks.

### 5. Key principles

- **All features default to ON** for new installs (`UserDefaults.object == nil` check)
- **Flag files are the source of truth for hooks** — hooks never read UserDefaults
- **Swift toggles take effect immediately** where possible — the `didSet` writes the flag file and SwiftUI reactivity handles UI changes
- **Hooks always remain registered in hooks.json** — gating is done at runtime via flag files, not by modifying hooks.json. This avoids requiring Claude session restarts when toggling.
- **If a feature requires init-time setup** (e.g., DispatchSource), pass `requiresRestart: true` to `experimentalRow()`. This wraps the toggle to set `floatingManager.pendingRestart = true` on change, which shows a restart banner with a "Restart Navi" button. Example:
  ```swift
  experimentalRow("My Feature", subtitle: "Does something at init time",
      isOn: Binding(get: { floatingManager.myFeatureEnabled }, set: { floatingManager.myFeatureEnabled = $0 }),
      requiresRestart: true)
  ```
- **If a feature requires new hooks in hooks.json** (not just gating existing hooks), the version upgrade banner handles the restart hint automatically. On first launch after a plugin update, `FloatingWindowManager` compares `NaviLastVersion` with `naviCurrentVersion` and shows a one-time dismissable banner: "Navi updated — restart Claude sessions for new features". This replaces per-toggle `requiresSessionRestart` labels, which were misleading (they implied restart on every toggle, but hooks are always registered — only the initial install needs a restart). The `requiresSessionRestart` parameter is still available on `experimentalRow()` for cases where a per-toggle label is genuinely needed.
- **If a feature requires init-time Navi restart** (e.g., DispatchSource), pass `requiresRestart: true` to `experimentalRow()` — this is separate from the session restart banner and works as before.

## Promoting an Experimental Feature to General Settings

When a feature is stable and ready to graduate from the Experimental tab:

### 1. Move the UI toggle

Move the `experimentalRow(...)` call from `experimentalTab` to `generalTab` in `ContentView`. Change it to use the appropriate general settings UI pattern (it no longer needs the "experimental" framing).

### 2. Rename the UserDefaults key (optional)

If you want to drop the `NaviExp.` prefix (e.g., `NaviExp.MyFeature` → `Navi.MyFeature`), add a one-time migration in `init()`:

```swift
// Migrate from experimental key
if UserDefaults.standard.object(forKey: "Navi.MyFeature") == nil,
   let old = UserDefaults.standard.object(forKey: "NaviExp.MyFeature") as? Bool {
    UserDefaults.standard.set(old, forKey: "Navi.MyFeature")
    UserDefaults.standard.removeObject(forKey: "NaviExp.MyFeature")
}
```

### 3. Keep the feature flag file

The flag file mechanism (`/tmp/navi/features/my-feature`) stays — it's not specific to experimental status. It's how hooks know whether the feature is enabled, regardless of which settings tab the toggle lives in.

### 4. Update the property name (optional)

Rename `myFeatureEnabled` to drop any "experimental" connotation if present. Update all references in `syncFeatureFlags()`, `didSet`, and the UI binding.
