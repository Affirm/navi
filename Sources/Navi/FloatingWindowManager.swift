import SwiftUI
import AppKit
import NaviCore

class FloatingWindowManager: ObservableObject {
    @Published var isFloating: Bool {
        didSet {
            UserDefaults.standard.set(isFloating, forKey: "NaviFloatingWindow")
            if isFloating {
                NaviWindow.ref?.makeKeyAndOrderFront(nil)
            } else {
                NaviWindow.ref?.orderOut(nil)
            }
        }
    }

    @Published var menuBarEnabled: Bool {
        didSet {
            UserDefaults.standard.set(menuBarEnabled, forKey: "NaviExp.MenuBar")
            FeatureFlags.set("menu-bar", enabled: menuBarEnabled)
            if !menuBarEnabled {
                isFloating = true
            }
        }
    }

    @Published var sessionNamesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionNamesEnabled, forKey: "NaviExp.SessionNames")
            FeatureFlags.set("session-names", enabled: sessionNamesEnabled)
        }
    }

    @Published var permissionDetailsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(permissionDetailsEnabled, forKey: "NaviExp.PermissionDetails")
            FeatureFlags.set("permission-details", enabled: permissionDetailsEnabled)
        }
    }

    @Published var showFolderEnabled: Bool {
        didSet { UserDefaults.standard.set(showFolderEnabled, forKey: "NaviExp.ShowFolder") }
    }

    @Published var showGitEnabled: Bool {
        didSet { UserDefaults.standard.set(showGitEnabled, forKey: "NaviExp.ShowGit") }
    }

    @Published var showModeEnabled: Bool {
        didSet { UserDefaults.standard.set(showModeEnabled, forKey: "NaviExp.ShowMode") }
    }

    @Published var showModelEnabled: Bool {
        didSet { UserDefaults.standard.set(showModelEnabled, forKey: "NaviExp.ShowModel") }
    }

    @Published var showSubagentsEnabled: Bool {
        didSet { UserDefaults.standard.set(showSubagentsEnabled, forKey: "NaviExp.ShowSubagents") }
    }

    @Published var showContextEnabled: Bool {
        didSet { UserDefaults.standard.set(showContextEnabled, forKey: "NaviExp.ShowContext") }
    }

    @Published var contextAlertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(contextAlertsEnabled, forKey: "NaviExp.ContextAlerts")
            FeatureFlags.set("context-alerts", enabled: contextAlertsEnabled)
        }
    }

    @Published var contextAlertThreshold1: Int {
        didSet { UserDefaults.standard.set(contextAlertThreshold1, forKey: "NaviExp.ContextAlert.T1") }
    }

    @Published var contextAlertThreshold2: Int {
        didSet { UserDefaults.standard.set(contextAlertThreshold2, forKey: "NaviExp.ContextAlert.T2") }
    }

    var anyEnrichmentToggleOn: Bool {
        showFolderEnabled || showGitEnabled || showModeEnabled || showModelEnabled || showSubagentsEnabled || showContextEnabled || contextAlertsEnabled
    }

    /// Width for the menu-bar popover. The floating window is user-resizable,
    /// so this is only consulted by `MenuBarManager.togglePopover`.
    var popoverWidth: CGFloat {
        switch (anyEnrichmentToggleOn, permissionDetailsEnabled) {
        case (false, false): return 360
        case (false, true):  return 520
        case (true,  false): return 480
        case (true,  true):  return 560
        }
    }

    /// Set to true when a feature that requires a Navi restart is toggled.
    /// The UI observes this to show a restart prompt.
    @Published var pendingRestart = false

    /// True after a plugin version upgrade — hints to restart Claude sessions.
    @Published var showSessionRestartHint = false

    private func syncFeatureFlags() {
        FeatureFlags.ensureDirectory()
        FeatureFlags.set("menu-bar", enabled: menuBarEnabled)
        FeatureFlags.set("session-names", enabled: sessionNamesEnabled)
        FeatureFlags.set("permission-details", enabled: permissionDetailsEnabled)
        FeatureFlags.set("context-alerts", enabled: contextAlertsEnabled)
        // Core features — always enabled. Flag files written so hooks that
        // still gate on `/tmp/navi/features/<name>` continue to work.
        FeatureFlags.set("terminal-focus", enabled: true)
        FeatureFlags.set("auto-dismiss", enabled: true)
        FeatureFlags.set("instant-notify", enabled: true)
        FeatureFlags.set("session-status", enabled: true)
    }

    /// Relaunch Navi by spawning a detached shell that reopens the app bundle
    /// after this process exits.
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        guard !bundlePath.isEmpty else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"$NAVI_BUNDLE\""]
        var env = ProcessInfo.processInfo.environment
        env["NAVI_BUNDLE"] = bundlePath
        task.environment = env
        do { try task.run() } catch { naviLog("Relaunch failed: %@", error.localizedDescription) }
        NSApplication.shared.terminate(nil)
    }

    init() {
        if UserDefaults.standard.object(forKey: "NaviFloatingWindow") == nil {
            UserDefaults.standard.set(true, forKey: "NaviFloatingWindow")
            isFloating = true
        } else {
            isFloating = UserDefaults.standard.bool(forKey: "NaviFloatingWindow")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.MenuBar") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.MenuBar")
            menuBarEnabled = true
        } else {
            menuBarEnabled = UserDefaults.standard.bool(forKey: "NaviExp.MenuBar")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.SessionNames") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.SessionNames")
            sessionNamesEnabled = true
        } else {
            sessionNamesEnabled = UserDefaults.standard.bool(forKey: "NaviExp.SessionNames")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.PermissionDetails") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.PermissionDetails")
            permissionDetailsEnabled = true
        } else {
            permissionDetailsEnabled = UserDefaults.standard.bool(forKey: "NaviExp.PermissionDetails")
        }
        // Session row enrichment toggles — all default OFF (opt-in).
        // Use the nil-check pattern (per Navi CLAUDE.md) so the default is
        // recorded explicitly and can be changed in a future release without
        // a migration. `bool(forKey:)` alone would silently conflate "key
        // absent" with "user explicitly turned off".
        if UserDefaults.standard.object(forKey: "NaviExp.ShowFolder") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowFolder")
            showFolderEnabled = false
        } else {
            showFolderEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowFolder")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.ShowGit") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowGit")
            showGitEnabled = false
        } else {
            showGitEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowGit")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.ShowMode") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowMode")
            showModeEnabled = false
        } else {
            showModeEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowMode")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.ShowModel") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowModel")
            showModelEnabled = false
        } else {
            showModelEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowModel")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.ShowSubagents") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowSubagents")
            showSubagentsEnabled = false
        } else {
            showSubagentsEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowSubagents")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.ContextAlerts") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ContextAlerts")
            contextAlertsEnabled = false
        } else {
            contextAlertsEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ContextAlerts")
        }
        contextAlertThreshold1 = UserDefaults.standard.object(forKey: "NaviExp.ContextAlert.T1") != nil
            ? UserDefaults.standard.integer(forKey: "NaviExp.ContextAlert.T1") : 200_000
        contextAlertThreshold2 = UserDefaults.standard.object(forKey: "NaviExp.ContextAlert.T2") != nil
            ? UserDefaults.standard.integer(forKey: "NaviExp.ContextAlert.T2") : 400_000
        if UserDefaults.standard.object(forKey: "NaviExp.ShowContext") == nil {
            UserDefaults.standard.set(false, forKey: "NaviExp.ShowContext")
            showContextEnabled = false
        } else {
            showContextEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowContext")
        }
        // Clean up legacy feature flag files from removed options. Manual resize
        // became permanent in 1.1.x — no longer a toggle.
        try? FileManager.default.removeItem(atPath: "\(FeatureFlags.directory)/detailed-permissions")
        try? FileManager.default.removeItem(atPath: "\(FeatureFlags.directory)/expanded-permissions")
        try? FileManager.default.removeItem(atPath: "\(FeatureFlags.directory)/manual-resize")
        UserDefaults.standard.removeObject(forKey: "NaviExp.DetailedPermissions")
        UserDefaults.standard.removeObject(forKey: "NaviExp.ExpandedPermissions")
        UserDefaults.standard.removeObject(forKey: "NaviExp.ManualResize")
        // Terminal focus / auto-dismiss / instant notify / session status graduated
        // to always-on core behavior — clean up their old toggle keys.
        UserDefaults.standard.removeObject(forKey: "NaviExp.TerminalFocus")
        UserDefaults.standard.removeObject(forKey: "NaviExp.AutoDismiss")
        UserDefaults.standard.removeObject(forKey: "NaviExp.InstantNotify")
        UserDefaults.standard.removeObject(forKey: "NaviExp.SessionStatus")

        // Show a session restart hint after a plugin version upgrade
        let lastVersion = UserDefaults.standard.string(forKey: "NaviLastVersion") ?? ""
        if !lastVersion.isEmpty && lastVersion != naviCurrentVersion {
            showSessionRestartHint = true
        }
        UserDefaults.standard.set(naviCurrentVersion, forKey: "NaviLastVersion")

        // Safety: never start with no UI visible
        if !isFloating && !menuBarEnabled {
            isFloating = true
            UserDefaults.standard.set(true, forKey: "NaviFloatingWindow")
        }

        syncFeatureFlags()
    }
}
