# Contributing to Navi

Thanks for your interest in contributing. This guide covers dev setup, Navi's architecture, and the patterns you'll need to add or evolve features.

## Code of Conduct

This project adheres to the [Open Code of Conduct](https://github.com/spotify/code-of-conduct/blob/master/code-of-conduct.md). By participating, you are expected to honor this code.

## Development Setup

```bash
git clone https://github.com/Affirm/navi.git
cd navi
bash build.sh        # Downloads + verifies the published Navi.app release
open Navi.app        # Launch
```

Navi is a SwiftUI app built with Swift Package Manager. Requires macOS + Xcode Command Line Tools (`xcode-select --install`). The test target depends on the standalone [`swift-testing`](https://github.com/swiftlang/swift-testing) package; runtime app code has no third-party dependencies.

`bash build.sh` is the hook-time install entrypoint: it reads the target version from `.claude-plugin/plugin.json`, fetches `Navi.app.zip` from the matching GitHub Release, verifies it against the release's `checksums.txt`, and (if the `gh` CLI is installed) also verifies the build-provenance attestation against the Sigstore transparency log. **It does not compile from source.** Releases are produced exclusively by `.github/workflows/release.yml`, which builds the same artifact twice on separate `macos-15` runners and refuses to publish if the two builds' SHA-256s diverge — that two-build check is what catches reproducibility regressions before they reach users.

To compile locally instead of fetching (e.g., when validating source changes before publishing a release), use either:

```bash
bash scripts/build-from-source.sh ./out   # produces ./out/Navi.app and ./out/Navi.app.zip
# or, to install in place:
NAVI_BUILD_FROM_SOURCE=1 bash build.sh
```

`scripts/build-from-source.sh` is what CI's release workflow runs, so a successful local build is a strong signal that the eventual release will succeed.

Run unit tests with `swift test`. Tests live in `Tests/NaviCoreTests/` and exercise the `NaviCore` library target. SwiftUI views and the app shell (the `Navi` executable target) are not directly unit-tested; put testable logic in `NaviCore`.

## Architecture

### File Layout

| Path | Purpose |
|------|---------|
| `Package.swift` | SPM manifest: `NaviCore` library, `Navi` executable, `NaviCoreTests` test target |
| `Sources/NaviCore/` | Library: models (`NaviEvent`, `SessionInfo`, `SessionGroup`, `SessionStatus`, `GitInfo`, `TranscriptInfo`, `PRInfo`, `SubagentInfo`), `EventMonitor`, `FeatureFlags`, helpers (`relativeTime`, `focusTerminal`, `naviLog`), `naviCurrentVersion`, `SessionEnrichmentProvider` protocol |
| `Sources/Navi/` | Executable: `@main` + `NaviAppDelegate`, `FloatingWindowManager`, `MenuBarManager`, `EnrichmentService` (conforms to `SessionEnrichmentProvider`), pastel palette, SwiftUI views (`ContentView`, `SessionSection`, `EventRow`, `WindowAccessor`, `FlowLayout`) |
| `Tests/NaviCoreTests/` | Swift Testing suites for `NaviCore` |
| `hooks/hooks.json` | Registers Claude Code hooks (loaded at session start) |
| `hooks/hook.sh` | Main hook entrypoint for PermissionRequest, Stop, StopFailure, Notification, PostToolUse, PostToolUseFailure |
| `hooks/pretooluse.sh` | Lightweight PreToolUse hook — captures `tool_use_id` for auto-dismiss |
| `hooks/parse_event.py` | Parses hook payload JSON, writes event/resolve files to `/tmp/navi/events/` |
| `docs/EXTENSION_API.md` | Public contract for external info-event producers — schema, atomicity rules, security constraints |
| `build.sh` | Hook-time install entrypoint: fetches the published release for the version in `plugin.json`, verifies checksums.txt + Sigstore attestation, extracts `Navi.app` |
| `scripts/build-from-source.sh` | Reproducible-build recipe used by CI and by contributors building locally |
| `.github/workflows/release.yml` | Builds two artifacts on `macos-15`, compares SHA-256s, attests provenance, publishes the release |

### EnrichmentService boundary

`EnrichmentService` lives in the `Navi` target because it depends on
`FloatingWindowManager` (toggle state). `EventMonitor` lives in `NaviCore`
and needs to call into the service on session updates / evictions, so
`NaviCore` defines a `SessionEnrichmentProvider` protocol that
`EnrichmentService` conforms to. Add new methods to the protocol if
`EventMonitor` needs to talk to the service in new ways; views in `Navi`
read concrete service state (`gitInfoByCwd`, etc.) directly.

### Event Flow

1. Claude Code fires a hook event (e.g., `PermissionRequest`)
2. `hook.sh` runs → conditionally captures TTY/PPID based on feature flags → calls `parse_event.py`
3. `parse_event.py` writes a JSON event file to `/tmp/navi/events/`
4. `Navi.app` watches the events directory (kqueue + fallback poll) and displays the event

See the diagram in the [README](README.md#how-it-works) for the full set of hook-to-script mappings.

### Feature Flag System

Experimental features use file-based flags at `/tmp/navi/features/<name>`. This lets hooks skip work for disabled features without modifying `hooks.json` or restarting Claude Code sessions.

- **Swift side:** `FeatureFlags.set(_:enabled:)` (in `NaviCore`) creates/deletes flag files. Each `FloatingWindowManager` toggle's `didSet` calls it, and `syncFeatureFlags()` writes all flags on startup.
- **Hook side:** scripts check `[ -f /tmp/navi/features/<name> ]` before doing feature-specific work. If the file is absent, the work is skipped.

Two types of flag files:

- **Boolean** (empty file): created by `FeatureFlags.set(_:enabled:)`. File exists = enabled, absent = disabled.
- **Configurable** (JSON content): created by `FeatureFlags.setConfig(_:config:)`. File exists = enabled, contents carry configuration. Hooks read config with `feature_config()` (Python) or `feature_config` (shell).

Hooks should always check file existence first (is the feature enabled?) and only read config when needed. An empty file means "enabled with defaults."

## Adding an Experimental Feature

### 1. Choose a flag name

Pick a kebab-case name (e.g., `my-feature`). This is used in `/tmp/navi/features/` and as the feature's identity across all layers.

### 2. Swift changes

In `Sources/Navi/FloatingWindowManager.swift`:

```swift
@Published var myFeatureEnabled: Bool {
    didSet {
        UserDefaults.standard.set(myFeatureEnabled, forKey: "NaviExp.MyFeature")
        FeatureFlags.set("my-feature", enabled: myFeatureEnabled)
    }
}
```

In `FloatingWindowManager.init()`, add the default-on initialization block:

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
FeatureFlags.set("my-feature", enabled: myFeatureEnabled)
```

In `Sources/Navi/Views/ContentView.swift`, add the toggle to `experimentalTab` (for new/unproven features) or `generalTab` (if it's ready to ship stable):

```swift
settingsRow("My Feature", subtitle: "Short description of what it does",
    isOn: Binding(get: { floatingManager.myFeatureEnabled }, set: { floatingManager.myFeatureEnabled = $0 }))
```

### 3. Hook changes (if needed)

Gate feature-specific work behind the flag file:

**In `hook.sh`:**
```bash
if [ -f "$FEATURES_DIR/my-feature" ]; then
    # feature-specific work
fi
```

**In `parse_event.py`:**
```python
if feature_enabled("my-feature"):
    # feature-specific work
```

**In a new hook script:**
```bash
[ -f /tmp/navi/features/my-feature ] || exit 0
```

### 3b. Configurable features (if needed)

If the feature has settings beyond on/off (e.g., a timeout, a list of values):

**Swift side** — use `FeatureFlags.setConfig` instead of `FeatureFlags.set` in the `didSet`:
```swift
@Published var myTimeout: Double = 120 {
    didSet {
        UserDefaults.standard.set(myTimeout, forKey: "NaviExp.MyFeature.Timeout")
        FeatureFlags.setConfig("my-feature", config: ["timeout": myTimeout])
    }
}
```

**In `parse_event.py`:**
```python
config = feature_config("my-feature", default={})
timeout = config.get("timeout", 120)
```

**In `hook.sh`:**
```bash
MY_TIMEOUT=$(feature_config my-feature timeout 120)
```

An empty flag file means "enabled with defaults" — hooks should always fall back to sensible defaults when config is absent.

### 4. Register new hooks (if needed)

If the feature requires new hook types, add them to `hooks/hooks.json`. Note that `hooks.json` is loaded at Claude Code session start — users must restart sessions to pick up new hook registrations. The one-time version-upgrade banner (see below) covers this automatically on plugin updates.

### 5. Key principles

- **Default ON unless the feature is purely cosmetic and adds visible noise.** Behavior-changing experimental features (auto-dismiss, instant notify, session status, permission details) default to ON for new installs (`UserDefaults.object == nil` → `set(true, ...)`); the goal is for users to discover and try the feature without hunting in Settings. Purely cosmetic UI additions that *layer extra visual elements onto existing UI* (e.g. session-row badges) MAY default OFF — but the nil-check pattern still applies so the default is recorded explicitly and can be flipped in a future release without a migration. When choosing OFF, note the rationale in the toggle's `didSet` or near its initialization. The four `NaviExp.Show*` toggles (folder/git/mode/model badges) are the canonical example.
- **Flag files are the source of truth for hooks** — hooks never read UserDefaults
- **Swift toggles take effect immediately** where possible — the `didSet` writes the flag file and SwiftUI reactivity handles UI changes
- **Prefer runtime flag gating over removing hooks from `hooks.json`** — removing a hook registration requires users to restart Claude sessions to pick up the change, whereas a flag file check takes effect immediately. Only remove a hook registration when it is genuinely obsolete (e.g., its work is fully covered by another mechanism), not merely when it is temporarily unwanted.
- **If a feature requires init-time setup inside Navi** (e.g., `DispatchSource`), pass `requiresRestart: true` to `settingsRow()`. This sets `floatingManager.pendingRestart = true` on change and shows a restart banner with a "Restart Navi" button.
- **If a feature requires new hooks in `hooks.json`** (not just gating existing hooks), the version upgrade banner handles the restart hint automatically. On first launch after a plugin update, `FloatingWindowManager` compares `NaviLastVersion` with `naviCurrentVersion` and shows a one-time dismissable banner: "Navi updated — restart Claude sessions for new features".

## Promoting an Experimental Feature to General Settings

When a feature is stable and ready to graduate from the Experimental tab:

### 1. Move the UI toggle

Move the `experimentalRow(...)` call from `experimentalTab` to `generalTab` in `ContentView`. Change it to use the general settings UI pattern (it no longer needs the "experimental" framing).

### 2. Rename the UserDefaults key (optional)

To drop the `NaviExp.` prefix (e.g., `NaviExp.MyFeature` → `Navi.MyFeature`), add a one-time migration in `init()`:

```swift
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

## Building External Plugins

Navi's extension API lets you build plugins that surface cards in the floating window without touching this repository. The contract is simple: write a JSON file to `/tmp/navi/events/` and Navi renders it.

### The `info` event type

`info` is the only external event type. It produces a non-interactive, sticky status card — no approve/deny buttons, no permission semantics. Cards stay visible until the user dismisses them (the X button on each row) or your plugin explicitly removes them by writing a `resolve` file.

See [`docs/EXTENSION_API.md`](docs/EXTENSION_API.md) for the full schema, atomicity rules, and security constraints.

### Plugin anatomy

A typical Claude Code hook-based plugin looks like this:

**`hooks/hooks.json`** — register your hook:
```json
{
  "hooks": {
    "Stop": [{ "type": "command", "command": "bash /path/to/your-plugin/hook.sh" }]
  }
}
```

**`hook.sh`** — check Navi is present, write an info event:
```bash
#!/bin/bash
NAVI_EVENTS="/tmp/navi/events"
[ -d "$NAVI_EVENTS" ] || exit 0   # no-op if Navi isn't installed

ID="$(date +%s)-$(openssl rand -hex 16)"
BODY="$(compute_your_message)"    # your logic here

printf '{"id":"%s","timestamp":%s,"type":"info","title":"My Plugin","body":"%s","description":"","session_id":"%s","session_name":"","pid":0,"cwd":"","tty":"","tool_use_id":"","expires":0}\n' \
  "$ID" "$(date +%s)" "$BODY" "${CLAUDE_SESSION_ID:-}" \
  > "$NAVI_EVENTS/.${ID}.tmp" \
&& mv "$NAVI_EVENTS/.${ID}.tmp" "$NAVI_EVENTS/${ID}.json"
```

The `[ -d "$NAVI_EVENTS" ]` guard is the key compatibility pattern — your plugin silently does nothing when Navi isn't installed, so it's safe to ship in shared dotfiles or team configs.

### Key principles

- **Atomic writes only.** Always write to a `.tmp` file and `mv`/`os.rename` to the final `.json` name. Navi only reads `.json` files so it never sees a partial write.
- **`session_id` binds the card to a session.** The card shows under that session's row. If the session has already ended, the card renders without a session header.
- **`body` is trusted display text.** Keep it short, controlled, and free of user-derived input. Put AI-generated or freeform text in `description` — it renders with a distinct italic style to signal it's not authoritative.
- **`id` nonce must be 128 bits of randomness.** `openssl rand -hex 16` produces exactly that. Never reuse ids.
- **Cards are sticky.** Unlike other event types, `info` cards don't auto-expire — they stay until dismissed. Design your message to be worth the real estate.

### The built-in context-window alert

`EnrichmentService` is the canonical internal producer. It polls session transcripts, detects when input tokens cross the configured warning/critical thresholds, and injects `info` events directly into `EventMonitor` (bypassing the file pipeline). When context drops back below 140K (e.g. after `/compact`), it resolves the stored event IDs so the cards disappear automatically.

This pattern — produce on crossing, resolve on recovery — is a good model for any plugin that tracks a recoverable condition.

## Pull Requests

- Open an issue first for larger changes so we can discuss scope before you invest time.
- Keep PRs focused — one feature or fix per PR.
- Test your change locally (build with `NAVI_BUILD_FROM_SOURCE=1 bash build.sh` to install your in-progress changes in place, run `swift test`, exercise the feature across at least one full Claude Code session).
- Update `CONTRIBUTING.md` if you change architecture or add a pattern worth documenting.
