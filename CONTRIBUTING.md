# Contributing to Navi

Thanks for your interest in contributing. This guide covers dev setup, Navi's architecture, and the patterns you'll need to add or evolve features.

## Code of Conduct

This project adheres to the [Open Code of Conduct](https://github.com/spotify/code-of-conduct/blob/master/code-of-conduct.md). By participating, you are expected to honor this code.

## Development Setup

```bash
git clone https://github.com/Affirm/navi.git
cd navi
bash build.sh        # Compiles main.swift into Navi.app
open Navi.app        # Launch
```

Navi is a SwiftUI app built with Swift Package Manager. Requires macOS + Xcode Command Line Tools (`xcode-select --install`). The test target depends on the standalone [`swift-testing`](https://github.com/swiftlang/swift-testing) package; runtime app code has no third-party dependencies.

`bash build.sh` verifies per-file SHA-256 checksums for every `Sources/**/*.swift` file (see `EXPECTED_SOURCE_CHECKSUMS` in `build.sh`), runs `swift build -c release`, and assembles the `Navi.app` bundle around the resulting binary. The pin carries forward the intent of v1.1.8's `main.swift` SHA pin into the SPM layout: any source edit must update its checksum in `build.sh` in the same commit, surfacing the change to PR reviewers. A count check rejects sneaked-in `.swift` files that aren't in the table.

Run unit tests with `swift test`. Tests live in `Tests/NaviCoreTests/` and exercise the `NaviCore` library target. SwiftUI views and the app shell (the `Navi` executable target) are not directly unit-tested; put testable logic in `NaviCore`.

## Architecture

### File Layout

| Path | Purpose |
|------|---------|
| `Package.swift` | SPM manifest: `NaviCore` library, `Navi` executable, `NaviCoreTests` test target |
| `Sources/NaviCore/` | Library: models (`NaviEvent`, `SessionInfo`, `SessionGroup`, `SessionStatus`, `GitInfo`, `TranscriptInfo`, `PRInfo`), `EventMonitor`, `FeatureFlags`, helpers (`relativeTime`, `focusTerminal`, `naviLog`), `naviCurrentVersion`, `SessionEnrichmentProvider` protocol |
| `Sources/Navi/` | Executable: `@main` + `NaviAppDelegate`, `FloatingWindowManager`, `MenuBarManager`, `EnrichmentService` (conforms to `SessionEnrichmentProvider`), pastel palette, SwiftUI views (`ContentView`, `SessionSection`, `EventRow`, `WindowAccessor`, `FlowLayout`) |
| `Tests/NaviCoreTests/` | Swift Testing suites for `NaviCore` |
| `hooks/hooks.json` | Registers Claude Code hooks (loaded at session start) |
| `hooks/hook.sh` | Main hook entrypoint for PermissionRequest, Stop, StopFailure, Notification, PostToolUse, PostToolUseFailure |
| `hooks/pretooluse.sh` | Lightweight PreToolUse hook — captures `tool_use_id` for auto-dismiss |
| `hooks/userpromptsubmit.sh` | Lightweight UserPromptSubmit hook — signals "Working" status |
| `hooks/parse_event.py` | Parses hook payload JSON, writes event/resolve files to `/tmp/navi/events/` |
| `build.sh` | Verifies per-file source checksums, runs `swift build -c release`, assembles `Navi.app` |

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

In the `experimentalTab` section of `Sources/Navi/Views/ContentView.swift`, add the toggle:

```swift
experimentalRow("My Feature", subtitle: "Short description of what it does",
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
- **Hooks always remain registered in `hooks.json`** — gating is done at runtime via flag files, not by modifying `hooks.json`. This avoids requiring Claude session restarts when toggling.
- **If a feature requires init-time setup inside Navi** (e.g., `DispatchSource`), pass `requiresRestart: true` to `experimentalRow()`. This sets `floatingManager.pendingRestart = true` on change and shows a restart banner with a "Restart Navi" button.
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

## Pull Requests

- Open an issue first for larger changes so we can discuss scope before you invest time.
- Keep PRs focused — one feature or fix per PR.
- Test your change locally (build with `bash build.sh`, run `swift test`, exercise the feature across at least one full Claude Code session).
- Update `CONTRIBUTING.md` if you change architecture or add a pattern worth documenting.
