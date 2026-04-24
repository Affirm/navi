import SwiftUI
import AppKit

// MARK: - Debug Logging (enable with NAVI_DEBUG=1)

private let naviDebug = ProcessInfo.processInfo.environment["NAVI_DEBUG"] == "1"

func naviLog(_ message: String, _ args: CVarArg...) {
    guard naviDebug else { return }
    let formatted = String(format: message, arguments: args)
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "\(ts) \(formatted)\n"
    let path = "/tmp/navi/debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

// MARK: - Font Scale

/// Base sizes are multiplied by this scale. Default 1.0, stored in UserDefaults.
private var naviScale: CGFloat {
    CGFloat(UserDefaults.standard.object(forKey: "NaviFontScale") as? Double ?? 1.0)
}

func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
    .system(size: size * naviScale, weight: weight, design: design)
}

// MARK: - Helpers

private func relativeTime(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 5 { return "now" }
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    return "\(hours)h"
}

// MARK: - Terminal Focus

/// Run a shell command (via /bin/sh -c with a PATH that includes common Homebrew
/// locations) and return stdout trimmed, or nil on failure / empty output.
private func runShell(_ script: String) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", script]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    proc.environment = env
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    } catch {
        return nil
    }
}

/// If `paneTTY` matches a tmux pane, return the tmux switch target
/// ("session:window.pane") and the TTY of a client we can use to reach it
/// (the TTY of the host terminal emulator). Prefers a client already attached
/// to the target session; otherwise falls back to any attached client, since
/// `tmux switch-client -c X -t session:...` moves X to the target session
/// even if X is currently attached to a different session. Returns nil when
/// tmux isn't installed, the TTY isn't a pane, or no client is attached at all.
private func tmuxTargetForPane(_ paneTTY: String) -> (target: String, clientTTY: String)? {
    guard let panes = runShell("tmux list-panes -a -F '#{pane_tty}|#{session_name}|#{window_index}.#{pane_index}' 2>/dev/null") else {
        return nil
    }
    var session: String?
    var target: String?
    for line in panes.split(separator: "\n") {
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, String(parts[0]) == paneTTY else { continue }
        session = String(parts[1])
        target = "\(parts[1]):\(parts[2])"
        break
    }
    guard let session = session, let target = target else { return nil }
    let escapedSession = session.replacingOccurrences(of: "'", with: "'\\''")
    if let attached = runShell("tmux list-clients -t '\(escapedSession)' -F '#{client_tty}' 2>/dev/null"),
       let clientTTY = attached.split(separator: "\n").first.map(String.init),
       !clientTTY.isEmpty {
        return (target, clientTTY)
    }
    guard let anyClients = runShell("tmux list-clients -F '#{client_tty}' 2>/dev/null"),
          let clientTTY = anyClients.split(separator: "\n").first.map(String.init),
          !clientTTY.isEmpty
    else { return nil }
    return (target, clientTTY)
}

/// Activate the terminal emulator tab/session that owns `tty` via AppleScript
/// (iTerm2 or Terminal.app).
private func activateTerminalApp(tty: String) {
    let iTermScript = """
    tell application "System Events"
        if not (exists process "iTerm2") then return false
    end tell
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                        select t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    return false
    """

    let terminalScript = """
    tell application "System Events"
        if not (exists process "Terminal") then return false
    end tell
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
    end tell
    return false
    """

    for source in [iTermScript, terminalScript] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if out == "true" {
                naviLog("activateTerminalApp: activated tty=%@", tty)
                return
            }
        } catch {
            naviLog("activateTerminalApp: osascript error: %@", error.localizedDescription)
        }
    }
    naviLog("activateTerminalApp: no terminal found for tty=%@", tty)
}

/// Activate the terminal owning `tty`. If the TTY is a tmux pane, first switch
/// the attached tmux client to that pane, then focus the terminal emulator
/// that hosts the client.
func focusTerminal(tty: String) {
    guard !tty.isEmpty else { return }
    guard tty.range(of: #"^/dev/tty[a-zA-Z0-9]+$"#, options: .regularExpression) != nil else {
        naviLog("focusTerminal: invalid tty format: %@", tty)
        return
    }
    naviLog("focusTerminal: looking for tty=%@", tty)

    if let t = tmuxTargetForPane(tty) {
        naviLog("focusTerminal: tmux pane → %@ via client %@", t.target, t.clientTTY)
        let escTarget = t.target.replacingOccurrences(of: "'", with: "'\\''")
        let escClient = t.clientTTY.replacingOccurrences(of: "'", with: "'\\''")
        _ = runShell("tmux switch-client -c '\(escClient)' -t '\(escTarget)' 2>/dev/null")
        activateTerminalApp(tty: t.clientTTY)
        return
    }

    activateTerminalApp(tty: tty)
}

// MARK: - Version

let naviCurrentVersion = "1.1.5"

// MARK: - Model

struct NaviEvent: Identifiable {
    let id: String
    let timestamp: Date
    let type: String      // permission, stop, notification
    let title: String
    let body: String
    let sessionID: String
    let sessionName: String
    let pid: pid_t
    let cwd: String
    let tty: String
    let toolUseID: String
    let expires: Date?     // when the hook times out and buttons go stale
    var resolved = false
    var response: String?

    var isPending: Bool { type == "permission" && !resolved }

    /// Last path component of cwd, or empty string
    var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// Short session prefix for display
    var shortSession: String {
        String(sessionID.prefix(8))
    }
}

// MARK: - Session State

struct SessionInfo: Identifiable {
    let id: String           // sessionID
    let projectName: String
    let shortSession: String
    let cwd: String
    var tty: String
    var sessionName: String
    var pid: pid_t
    var lastEventType: String = ""
    var lastActivity: Date = Date()

    /// Display label: session name (if enabled and set), otherwise project folder name
    var displayName: String {
        if UserDefaults.standard.bool(forKey: "NaviExp.SessionNames"), !sessionName.isEmpty {
            return sessionName
        }
        return projectName
    }

    /// Check if the Claude Code process is still running
    var isAlive: Bool {
        pid > 0 && kill(pid, 0) == 0
    }
}

// MARK: - Event Monitor

class EventMonitor: ObservableObject {
    @Published var events: [NaviEvent] = []
    @Published var sessions: [String: SessionInfo] = [:]
    @Published var needsBinaryRestart = false

    private let eventsDir = "/tmp/navi/events"
    private let responsesDir = "/tmp/navi/responses"
    private var knownIDs = Set<String>()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?

    init() {
        let fm = FileManager.default
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? fm.createDirectory(atPath: eventsDir, withIntermediateDirectories: true, attributes: ownerOnly)
        try? fm.createDirectory(atPath: responsesDir, withIntermediateDirectories: true, attributes: ownerOnly)
        // Self-heal perms on pre-existing dirs so event JSON (Confidential tool
        // input) and response files (trusted permission-decision channel) stay
        // owner-readable only.
        try? fm.setAttributes(ownerOnly, ofItemAtPath: "/tmp/navi")
        try? fm.setAttributes(ownerOnly, ofItemAtPath: eventsDir)
        try? fm.setAttributes(ownerOnly, ofItemAtPath: responsesDir)
        // Clean stale files from previous runs
        cleanDirectory(eventsDir)
        cleanDirectory(responsesDir)
        try? fm.removeItem(atPath: "/tmp/navi/needs-restart")

        // Discover already-running Claude sessions from ~/.claude/sessions/
        discoverSessions()

        // Watch the events directory for new files — triggers poll() instantly
        // via kqueue so events appear with near-zero latency.
        let fd = open(eventsDir, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in self?.poll() }
            source.setCancelHandler { close(fd) }
            source.resume()
            dirSource = source
        }

        // Timer fallback for cleanup passes (event ingestion is driven by the
        // kqueue source above).
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cleanDirectory(_ path: String, olderThan seconds: TimeInterval = 5) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for file in files {
            let filePath = "\(path)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fm.removeItem(atPath: filePath)
        }
    }

    private func poll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: eventsDir) else { return }

        var newEventTypes = Set<String>()
        var workingSessions = Set<String>()
        for file in files.sorted() where file.hasSuffix(".json") {
            let path = "\(eventsDir)/\(file)"

            // Handle resolve signals from PostToolUse and cancel signals from
            // hook.sh EXIT trap (experimental auto-dismiss feature).
            if file.hasPrefix("resolve-") || file.hasPrefix("cancel-") {
                if let data = fm.contents(atPath: path),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let tuid = dict["tool_use_id"] as? String
                    let eid = dict["id"] as? String
                    DispatchQueue.main.async {
                        for i in self.events.indices where self.events[i].isPending {
                            if (tuid != nil && !tuid!.isEmpty && self.events[i].toolUseID == tuid) ||
                               (eid != nil && self.events[i].id == eid) {
                                self.events[i].resolved = true
                                self.events[i].response = "dismissed"
                            }
                        }
                    }
                }
                try? fm.removeItem(atPath: path)
                continue
            }

            // Collect working signals — applied after regular events so they
            // always win over stale Stop events in the same poll cycle.
            if file.hasPrefix("working-") {
                if let data = fm.contents(atPath: path),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sid = dict["session_id"] as? String {
                    workingSessions.insert(sid)
                }
                try? fm.removeItem(atPath: path)
                continue
            }

            let eventID = String(file.dropLast(5))
            guard !knownIDs.contains(eventID) else { continue }

            guard let data = fm.contents(atPath: path),
                  !data.isEmpty,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            knownIDs.insert(eventID)

            let event = NaviEvent(
                id: dict["id"] as? String ?? eventID,
                timestamp: Date(
                    timeIntervalSince1970: dict["timestamp"] as? Double
                        ?? Date().timeIntervalSince1970),
                type: dict["type"] as? String ?? "notification",
                title: dict["title"] as? String ?? "Claude Code",
                body: dict["body"] as? String ?? "",
                sessionID: dict["session_id"] as? String ?? "",
                sessionName: dict["session_name"] as? String ?? "",
                pid: pid_t(dict["pid"] as? Int ?? 0),
                cwd: dict["cwd"] as? String ?? "",
                tty: dict["tty"] as? String ?? "",
                toolUseID: dict["tool_use_id"] as? String ?? "",
                expires: (dict["expires"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            )
            DispatchQueue.main.async {
                self.updateSession(for: event)
                // Skip Notification events for sessions that already have a
                // pending Permission — the permission itself signals "needs
                // attention", so the notification would be redundant.
                if event.type == "notification",
                   self.events.contains(where: { $0.sessionID == event.sessionID && $0.isPending }) {
                    return
                }
                // When a Stop event arrives, immediately dismiss pending
                // permissions for this session — the turn ended, so any
                // unresolved permission was denied/interrupted. Other
                // non-permission events use a 30s age threshold.
                if event.type != "permission" {
                    let minAge: TimeInterval = event.type == "stop" ? 0 : 30
                    for i in self.events.indices where self.events[i].sessionID == event.sessionID && self.events[i].isPending && event.timestamp.timeIntervalSince(self.events[i].timestamp) > minAge {
                        self.events[i].resolved = true
                        self.events[i].response = "dismissed"
                    }
                }
                // Keep only the latest event per session (preserve pending permissions)
                self.events.removeAll { $0.sessionID == event.sessionID && !$0.isPending }
                self.events.insert(event, at: 0)
            }
            newEventTypes.insert(event.type)
            try? fm.removeItem(atPath: path)
        }

        // Play sounds for new events (check each type independently)
        for type in newEventTypes {
            if UserDefaults.standard.object(forKey: "NaviSound.\(type)") as? Bool ?? (type == "permission") {
                let name = UserDefaults.standard.string(forKey: "NaviSound.\(type).name") ?? "Glass"
                NSSound(named: NSSound.Name(name))?.play()
            }
        }



        // Auto-dismiss old events and manage sessions
        let now = Date()
        DispatchQueue.main.async {
            self.events.removeAll { event in
                if event.isPending { return false }
                if event.resolved { return now.timeIntervalSince(event.timestamp) > 10 }
                return now.timeIntervalSince(event.timestamp) > 60
            }
            // Discover new sessions BEFORE applying working signals so that
            // a brand-new session's first working signal isn't dropped.
            self.discoverSessions()
            // Apply working signals AFTER regular events and discovery so
            // they always win over stale Stop events.
            for sid in workingSessions {
                if self.sessions[sid] != nil {
                    self.sessions[sid]!.lastEventType = "working"
                    self.sessions[sid]!.lastActivity = Date()
                }
                // New turn — dismiss stale pending permissions
                for i in self.events.indices where self.events[i].sessionID == sid && self.events[i].isPending {
                    self.events[i].resolved = true
                    self.events[i].response = "dismissed"
                }
            }
            self.sessions = self.sessions.filter { (_, info) in info.isAlive }

            // Check if build.sh rebuilt a newer version while we're running
            let restartMarker = "/tmp/navi/needs-restart"
            if !self.needsBinaryRestart && fm.fileExists(atPath: restartMarker) {
                let newVersion = (try? String(contentsOfFile: restartMarker, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
                try? fm.removeItem(atPath: restartMarker)
                if !newVersion.isEmpty && newVersion != naviCurrentVersion {
                    self.needsBinaryRestart = true
                }
            }
        }
    }

    /// Scan ~/.claude/sessions/ for running Claude processes and add any
    /// that Navi doesn't know about yet. Skips sessions already tracked
    /// to avoid resetting their state (TTY, lastEventType, etc.).
    private func discoverSessions() {
        let sessionsDir = NSString(string: "~/.claude/sessions").expandingTildeInPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = dict["sessionId"] as? String,
                  sessions[sid] == nil,       // skip already-tracked sessions
                  let pid = dict["pid"] as? Int,
                  kill(pid_t(pid), 0) == 0    // only alive processes
            else { continue }
            let cwd = dict["cwd"] as? String ?? ""
            let name = dict["name"] as? String ?? ""
            // Look up TTY from the process so terminal focus works immediately
            var tty = ""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-o", "tty=", "-p", String(pid)]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            if let _ = try? proc.run() {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !raw.isEmpty && raw != "??" {
                    tty = "/dev/\(raw)"
                }
            }
            sessions[sid] = SessionInfo(
                id: sid,
                projectName: (cwd as NSString).lastPathComponent,
                shortSession: String(sid.prefix(8)),
                cwd: cwd,
                tty: tty,
                sessionName: name,
                pid: pid_t(pid),
                lastActivity: Date()
            )
        }
    }

    private func updateSession(for event: NaviEvent) {
        let sid = event.sessionID
        guard !sid.isEmpty else { return }

        if sessions[sid] == nil {
            sessions[sid] = SessionInfo(
                id: sid,
                projectName: event.projectName,
                shortSession: event.shortSession,
                cwd: event.cwd,
                tty: event.tty,
                sessionName: event.sessionName,
                pid: event.pid,
                lastActivity: event.timestamp
            )
        } else {
            sessions[sid]!.lastActivity = event.timestamp
            // Only Stop transitions to idle. Other events (notification,
            // permission) don't override the working/idle state — this
            // prevents mid-turn notifications from flipping to "Waiting".
            if event.type == "stop" {
                sessions[sid]!.lastEventType = "stop"
            }
            if event.pid > 0 {
                sessions[sid]!.pid = event.pid
            }
            if !event.tty.isEmpty {
                sessions[sid]!.tty = event.tty
            }
            // Always update session name — it can change via /rename
            sessions[sid]!.sessionName = event.sessionName
        }
    }

    func respond(to id: String, with response: String) {
        try? response.write(
            toFile: "\(responsesDir)/\(id)", atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            if let idx = self.events.firstIndex(where: { $0.id == id }) {
                self.events[idx].resolved = true
                self.events[idx].response = response
            }
        }
    }

    func dismiss(_ id: String) {
        DispatchQueue.main.async {
            self.events.removeAll { $0.id == id }
        }
    }

    func dismissSession(_ sessionID: String) {
        DispatchQueue.main.async {
            self.events.removeAll { $0.sessionID == sessionID && !$0.isPending }
            self.sessions.removeValue(forKey: sessionID)
        }
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.events.removeAll { !$0.isPending }
            self.sessions.removeAll()
        }
    }
}

// MARK: - Session Group

struct SessionGroup: Identifiable {
    let id: String          // sessionID
    let info: SessionInfo
    let events: [NaviEvent]

    var hasPending: Bool { events.contains { $0.isPending } }

    var status: SessionStatus {
        if hasPending { return .needsAttention }
        if info.isAlive {
            return info.lastEventType == "working" ? .working : .waitingForInput
        }
        return .idle
    }
}

enum SessionStatus {
    case needsAttention, working, waitingForInput, idle

    var icon: String {
        switch self {
        case .needsAttention: return "exclamationmark.circle.fill"
        case .working: return "gearshape.circle.fill"
        case .waitingForInput: return "ellipsis.circle.fill"
        case .idle: return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .needsAttention: return .orange
        case .working: return .green
        case .waitingForInput: return .blue
        case .idle: return .green
        }
    }

    var label: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .working: return "Working"
        case .waitingForInput: return "Idle"
        case .idle: return ""
        }
    }
}

// MARK: - Floating Window Manager

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
            Self.setFeatureFlag("menu-bar", enabled: menuBarEnabled)
            if !menuBarEnabled {
                isFloating = true
            }
        }
    }

    @Published var sessionNamesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionNamesEnabled, forKey: "NaviExp.SessionNames")
            Self.setFeatureFlag("session-names", enabled: sessionNamesEnabled)
        }
    }

    @Published var permissionDetailsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(permissionDetailsEnabled, forKey: "NaviExp.PermissionDetails")
            Self.setFeatureFlag("permission-details", enabled: permissionDetailsEnabled)
        }
    }

    /// Set to true when a feature that requires a Navi restart is toggled.
    /// The UI observes this to show a restart prompt.
    @Published var pendingRestart = false

    /// True after a plugin version upgrade — hints to restart Claude sessions.
    @Published var showSessionRestartHint = false

    // MARK: - Feature Flag Files
    // Hooks check /tmp/navi/features/<name> to skip work for disabled features.
    // Flag files can be empty (boolean on/off) or contain JSON config.

    private static let featuresDir = "/tmp/navi/features"

    /// Write a boolean feature flag (empty file = enabled, absent = disabled).
    /// For features with configuration, use setFeatureConfig instead.
    static func setFeatureFlag(_ name: String, enabled: Bool) {
        let path = "\(featuresDir)/\(name)"
        if enabled {
            FileManager.default.createFile(atPath: path, contents: nil)
        } else {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Write a feature flag with JSON configuration. The file's existence means
    /// enabled; its contents carry config that hooks can read.
    static func setFeatureConfig(_ name: String, config: [String: Any]) {
        let path = "\(featuresDir)/\(name)"
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return }
        let tmp = "\(path).tmp"
        FileManager.default.createFile(atPath: tmp, contents: data)
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    /// Read JSON configuration from a feature flag file. Returns nil if the
    /// feature is disabled (file absent) or has no config (empty file).
    static func readFeatureConfig(_ name: String) -> [String: Any]? {
        let path = "\(featuresDir)/\(name)"
        guard let data = FileManager.default.contents(atPath: path),
              !data.isEmpty,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private func syncFeatureFlags() {
        try? FileManager.default.createDirectory(
            atPath: Self.featuresDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: Self.featuresDir)
        Self.setFeatureFlag("menu-bar", enabled: menuBarEnabled)
        Self.setFeatureFlag("session-names", enabled: sessionNamesEnabled)
        Self.setFeatureFlag("permission-details", enabled: permissionDetailsEnabled)
        // Core features — always enabled. Flag files written so hooks that
        // still gate on `/tmp/navi/features/<name>` continue to work.
        Self.setFeatureFlag("terminal-focus", enabled: true)
        Self.setFeatureFlag("auto-dismiss", enabled: true)
        Self.setFeatureFlag("instant-notify", enabled: true)
        Self.setFeatureFlag("session-status", enabled: true)
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
        // Clean up legacy feature flag files from removed options. Manual resize
        // became permanent in 1.1.x — no longer a toggle.
        try? FileManager.default.removeItem(atPath: "\(Self.featuresDir)/detailed-permissions")
        try? FileManager.default.removeItem(atPath: "\(Self.featuresDir)/expanded-permissions")
        try? FileManager.default.removeItem(atPath: "\(Self.featuresDir)/manual-resize")
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

// MARK: - Menu Bar Manager (Experimental)

class MenuBarManager: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var monitor: EventMonitor?
    private var floatingManager: FloatingWindowManager?
    private var eventObserver: Any?

    func attach(monitor: EventMonitor, floatingManager: FloatingWindowManager) {
        self.monitor = monitor
        self.floatingManager = floatingManager
    }

    func enable() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(pendingCount: 0)
        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        // Observe event changes to update icon
        eventObserver = NotificationCenter.default.addObserver(
            forName: .init("NaviEventsChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let count = note.userInfo?["pendingCount"] as? Int ?? 0
            self?.updateIcon(pendingCount: count)
        }
    }

    func disable() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        popover?.close()
        popover = nil
        if let obs = eventObserver {
            NotificationCenter.default.removeObserver(obs)
            eventObserver = nil
        }
    }

    private func updateIcon(pendingCount: Int) {
        guard let button = statusItem?.button else { return }
        let name = pendingCount > 0 ? "bolt.circle.fill" : "bolt.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Navi")
        image?.isTemplate = true
        button.image = image
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let monitor = monitor, let floatingManager = floatingManager else { return }
        // Reuse existing popover, create once
        if popover == nil {
            let pop = NSPopover()
            pop.contentSize = NSSize(width: 360, height: 500)
            pop.behavior = .transient
            pop.animates = true
            pop.contentViewController = NSHostingController(
                rootView: ContentView(monitor: monitor, floatingManager: floatingManager)
            )
            popover = pop
        }
        popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}

// MARK: - Content View

private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Shared ref so ContentView can resize the window directly.
private class NaviWindow {
    static var ref: NSWindow?
}

private let autoLaunchFlagPath = "/tmp/navi/no-auto-launch"

struct ContentView: View {
    @ObservedObject var monitor: EventMonitor
    @ObservedObject var floatingManager: FloatingWindowManager
    var isFloatingWindow: Bool = false
    @State private var autoLaunch: Bool = !FileManager.default.fileExists(atPath: "/tmp/navi/no-auto-launch")
    @State private var permissionSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.permission") as? Bool ?? true
    @State private var permissionSound: String = UserDefaults.standard.string(forKey: "NaviSound.permission.name") ?? "Glass"
    @State private var stopSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.stop") as? Bool ?? false
    @State private var stopSound: String = UserDefaults.standard.string(forKey: "NaviSound.stop.name") ?? "Glass"
    @State private var notificationSoundOn: Bool = UserDefaults.standard.object(forKey: "NaviSound.notification") as? Bool ?? false
    @State private var notificationSound: String = UserDefaults.standard.string(forKey: "NaviSound.notification.name") ?? "Glass"
    @AppStorage("NaviFontScale") private var fontScale: Double = 1.0
    @State private var showSettings = false

    private static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
        "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private var sessionGroups: [SessionGroup] {
        let eventsBySession = Dictionary(grouping: monitor.events) { $0.sessionID }
        return monitor.sessions.values.map { info in
            SessionGroup(
                id: info.id,
                info: info,
                events: eventsBySession[info.id] ?? []
            )
        }
        .sorted { a, b in
            // Pending first, then by recency
            if a.hasPending != b.hasPending { return a.hasPending }
            return a.info.lastActivity > b.info.lastActivity
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                controlsBar
                if monitor.needsBinaryRestart {
                    binaryRestartBanner
                }
                if floatingManager.showSessionRestartHint {
                    sessionRestartHint
                }
                Divider()
                if monitor.sessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .frame(minWidth: 360, idealWidth: 360, maxWidth: .infinity)
            .overlay(
                Group {
                    if isFloatingWindow {
                        GeometryReader { geo in
                            Color.clear.preference(key: ViewHeightKey.self, value: geo.size.height)
                        }
                    }
                }
            )

            Spacer(minLength: 0)
        }
        .onPreferenceChange(ViewHeightKey.self) { height in
            if isFloatingWindow { resizeWindow(to: height + 28) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .background(Group { if isFloatingWindow { WindowAccessor(floatingManager: floatingManager) } })
    }

    // Auto-resize respects two floors:
    //   1. The user's last drag (so a user-widened window doesn't shrink back).
    //   2. The current window height, while any events are in the monitor.
    //      This blocks the shrink that races with popover dismissal / section
    //      auto-collapse, which is where the visual jitter comes from. Once all
    //      events clear (monitor.events is empty), the window shrinks freely
    //      back to the baseline.
    private func resizeWindow(to targetHeight: CGFloat) {
        DispatchQueue.main.async {
            guard let window = NaviWindow.ref else { return }
            if targetHeight < 1 { return }
            let userMinW = CGFloat(UserDefaults.standard.double(forKey: "NaviUserMinWidth"))
            let userMinH = CGFloat(UserDefaults.standard.double(forKey: "NaviUserMinHeight"))
            let currentH = window.frame.height
            let targetW = max(360, userMinW)
            var targetH = max(targetHeight, userMinH)
            if !self.monitor.events.isEmpty && targetH < currentH {
                targetH = currentH
            }
            let top = window.frame.maxY
            var frame = window.frame
            frame.size.height = targetH
            frame.size.width = targetW
            frame.origin.y = top - targetH
            window.setFrame(frame, display: true, animate: false)
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))
            Text("Navi")
                .font(.system(size: 14, weight: .semibold))
            Button {
                showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                settingsPopover
            }
            Spacer()
            if !sessionGroups.isEmpty {
                Text("\(sessionGroups.count) session\(sessionGroups.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if !monitor.events.isEmpty {
                Button {
                    monitor.clearAll()
                } label: {
                    Text("Clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    @State private var settingsTab = 0
    private let naviVersion = naviCurrentVersion

    private var settingsPopover: some View {
        VStack(spacing: 0) {
            Picker("", selection: $settingsTab) {
                Text("General").tag(0)
                Text("Experimental").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)

            if settingsTab == 0 {
                generalTab
            } else {
                experimentalTab
            }

            Divider()
                .padding(.horizontal, 12)

            Text("Navi v\(naviVersion)")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            Text("Thanks for using Navi!\nFeedback and feature suggestions are welcome!")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .frame(width: 280)
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $autoLaunch) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-launch Navi")
                        .font(.system(size: 11))
                    Text("Automatically launch Navi when Claude triggers a hook event")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.blue)
            .onChange(of: autoLaunch) { _, on in
                if on {
                    try? FileManager.default.removeItem(atPath: autoLaunchFlagPath)
                } else {
                    FileManager.default.createFile(atPath: autoLaunchFlagPath, contents: nil)
                }
            }

            Divider()

            Text("Sounds")
                .font(.system(size: 11, weight: .semibold))

            soundRow("Permission", isOn: $permissionSoundOn, sound: $permissionSound, key: "permission")
            soundRow("Finished", isOn: $stopSoundOn, sound: $stopSound, key: "stop")
            soundRow("Notification", isOn: $notificationSoundOn, sound: $notificationSound, key: "notification")

            Divider()

            Text("Display")
                .font(.system(size: 11, weight: .semibold))

            HStack(spacing: 6) {
                Text("A")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $fontScale, in: 0.8...1.4, step: 0.1)
                    .controlSize(.mini)
                Text("A")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit Navi")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func experimentalRow(_ title: String, subtitle: String, isOn: Binding<Bool>, indent: Bool = false, requiresRestart: Bool = false, requiresSessionRestart: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if requiresSessionRestart {
                    Label("Restart Claude sessions to apply", systemImage: "arrow.clockwise")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle("", isOn: requiresRestart ? Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    isOn.wrappedValue = newValue
                    floatingManager.pendingRestart = true
                }
            ) : isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .labelsHidden()
        }
        .padding(.leading, indent ? 12 : 0)
    }

    private var experimentalTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("These features may not have been fully tested, especially together. Results may be unexpected.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            experimentalRow("Menu bar icon", subtitle: "Adds a menu bar icon for Navi.",
                isOn: Binding(get: { floatingManager.menuBarEnabled }, set: { floatingManager.menuBarEnabled = $0 }))

            if floatingManager.menuBarEnabled {
                experimentalRow("Floating window", subtitle: "Always-on-top floating window",
                    isOn: Binding(get: { floatingManager.isFloating }, set: { floatingManager.isFloating = $0 }), indent: true)
            }

            experimentalRow("Session names", subtitle: "Show session name (from /rename) instead of project folder",
                isOn: Binding(get: { floatingManager.sessionNamesEnabled }, set: { floatingManager.sessionNamesEnabled = $0 }))

            experimentalRow("Permission details", subtitle: "Show a \"Show details\" button on each permission request that opens a popover with the full tool input.",
                isOn: Binding(get: { floatingManager.permissionDetailsEnabled }, set: { floatingManager.permissionDetailsEnabled = $0 }))

            Spacer()
        }
        .padding(12)
    }

    private var restartBanner: some View {
        VStack(spacing: 6) {
            Divider()
            Text("Restart required for changes to take effect")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Button {
                FloatingWindowManager.relaunch()
            } label: {
                Text("Restart Navi")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var binaryRestartBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
            Text("Navi was rebuilt")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                FloatingWindowManager.relaunch()
            } label: {
                Text("Restart")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.05))
    }

    private var sessionRestartHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text("Navi updated — restart Claude sessions for new features")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                floatingManager.showSessionRestartHint = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.05))
    }

    private func soundRow(_ label: String, isOn: Binding<Bool>, sound: Binding<String>, key: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 75, alignment: .leading)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.blue)
                .labelsHidden()
                .onChange(of: isOn.wrappedValue) { _, on in
                    UserDefaults.standard.set(on, forKey: "NaviSound.\(key)")
                }
            Menu(isOn.wrappedValue ? sound.wrappedValue : "—") {
                ForEach(Self.systemSounds, id: \.self) { s in
                    Button(s) {
                        sound.wrappedValue = s
                        UserDefaults.standard.set(s, forKey: "NaviSound.\(key).name")
                        NSSound(named: NSSound.Name(s))?.play()
                    }
                }
            }
            .font(.system(size: 11))
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isOn.wrappedValue)
            .opacity(isOn.wrappedValue ? 1 : 0.4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Listening for events...")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 60)
    }

    private var sessionList: some View {
        VStack(spacing: 6) {
            ForEach(sessionGroups) { group in
                SessionSection(group: group, monitor: monitor, floatingManager: floatingManager)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Session Section

struct SessionSection: View {
    let group: SessionGroup
    @ObservedObject var monitor: EventMonitor
    @ObservedObject var floatingManager: FloatingWindowManager
    @State private var isExpanded = false
    @AppStorage("NaviFontScale") private var s: Double = 1.0

    private var shouldExpand: Bool {
        group.hasPending
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            HStack(spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.status.icon)
                            .foregroundStyle(group.status.color)
                            .font(.system(size: 13 * s))

                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11 * s))
                        Text(group.info.displayName)
                            .font(.system(size: 13 * s, weight: .semibold))

                        Text(group.info.shortSession)
                            .font(.system(size: 11 * s, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Spacer()

                        if !group.status.label.isEmpty {
                            Text(group.status.label)
                                .font(.system(size: 11 * s, weight: .medium))
                                .foregroundStyle(group.status.color)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(relativeTime(from: group.info.lastActivity, to: context.date))
                                .font(.system(size: 11 * s))
                                .foregroundStyle(.tertiary)
                        }

                        if !group.events.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10 * s, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                if !group.info.tty.isEmpty {
                    Button { focusTerminal(tty: group.info.tty) } label: {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10 * s, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Focus terminal")
                    .padding(.trailing, 6)
                }

                Button { monitor.dismissSession(group.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10 * s, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
            }

            // Events
            if isExpanded && !group.events.isEmpty {
                Divider().padding(.horizontal, 8)
                VStack(spacing: 0) {
                    ForEach(group.events) { event in
                        EventRow(event: event, monitor: monitor)
                        if event.id != group.events.last?.id {
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(group.hasPending ? Color.orange.opacity(0.05) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(group.hasPending ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.horizontal, 6)
        .onAppear {
            if shouldExpand { isExpanded = true }
        }
        .onChange(of: shouldExpand) { _, expand in
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded = expand }
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: NaviEvent
    @ObservedObject var monitor: EventMonitor
    @AppStorage("NaviFontScale") private var s: Double = 1.0
    @State private var showingDetails = false
    @AppStorage("NaviExp.PermissionDetails") private var permissionDetailsEnabled: Bool = true

    private var icon: String {
        switch event.type {
        case "permission":
            return event.resolved ? "checkmark.shield.fill" : "shield.lefthalf.filled"
        case "stop": return "checkmark.circle.fill"
        default: return "bell.fill"
        }
    }

    private var iconColor: Color {
        switch event.type {
        case "permission":
            if event.resolved { return event.response == "approve" ? .green : .red }
            return .orange
        case "stop": return .green
        default: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 15 * s))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13 * s, weight: .semibold))
                    Text(event.body)
                        .font(.system(size: 12 * s, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                // Anchor the popover to this always-rendered VStack. Attaching
                // it to the Show-details button causes SwiftUI to re-anchor
                // (or orphan) the popover when the button's parent row
                // switches from permissionButtons to the resolved row, which
                // produced a visible drop/offset during the transition.
                .popover(isPresented: $showingDetails, arrowEdge: .leading) {
                    ScrollView {
                        Text(event.body)
                            .font(.system(size: 12 * s, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(width: 500, height: 400)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(event.timestamp, style: .time)
                        .font(.system(size: 11 * s))
                        .foregroundStyle(.tertiary)
                    if !event.isPending {
                        Button { monitor.dismiss(event.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10 * s, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if event.isPending {
                if let expires = event.expires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if context.date < expires {
                            permissionButtons
                        } else {
                            respondInTerminalLabel
                        }
                    }
                } else {
                    permissionButtons
                }
            }

            if event.resolved, let response = event.response {
                HStack {
                    showDetailsButton
                    Spacer()
                    Label(
                        response == "dismissed" ? "Handled in Terminal" : response.capitalized,
                        systemImage: response == "approve"
                            ? "checkmark.circle.fill"
                            : response == "dismissed"
                                ? "terminal.fill" : "xmark.circle.fill"
                    )
                    .font(.system(size: 11 * s, weight: .medium))
                    .foregroundStyle(
                        response == "approve" ? .green
                            : response == "dismissed" ? .secondary : .red)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.clear)
        .animation(.easeInOut(duration: 0.2), value: event.resolved)
    }

    @ViewBuilder private var showDetailsButton: some View {
        if event.type == "permission" && permissionDetailsEnabled {
            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 9 * s, weight: .bold))
                    Text("Show details")
                        .font(.system(size: 10 * s, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var permissionButtons: some View {
        HStack(spacing: 8) {
            showDetailsButton
            Spacer()
            Button("Deny") {
                // Close the detail popover before the event-resolved layout
                // change kicks in — a popover dismiss that races with the
                // window resize produces a visible empty rectangle above Navi.
                showingDetails = false
                monitor.respond(to: event.id, with: "deny")
            }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            Button("Approve") {
                showingDetails = false
                monitor.respond(to: event.id, with: "approve")
            }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var respondInTerminalLabel: some View {
        HStack(spacing: 4) {
            showDetailsButton
            Spacer()
            Label("Respond in terminal", systemImage: "terminal.fill")
                .font(.system(size: 11 * s, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }
}

// MARK: - Always-on-top Window Configuration

struct WindowAccessor: NSViewRepresentable {
    var floatingManager: FloatingWindowManager? = nil

    class Coordinator: NSObject {
        var floatingManager: FloatingWindowManager?
        @objc func windowWillClose(_ notification: Notification) {
            guard !NaviAppDelegate.isTerminating else { return }
            DispatchQueue.main.async { self.floatingManager?.isFloating = false }
        }
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.floatingManager = floatingManager
        return c
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            NaviWindow.ref = window
            window.level = .floating
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // Minimum window size at the AppKit level. The content frame also
            // enforces minWidth: 360 so these match. The dynamic "don't shrink
            // while events exist" rule in resizeWindow handles the transient
            // jitter window — this minSize is just the floor the user can drag.
            window.minSize = NSSize(width: 360, height: 200)
            // Restore saved position, or default to top-right corner
            if !window.setFrameAutosaveName("NaviWindow") {
                // Name already set — frame restored automatically
            }
            // If the autosaved frame is below the new minimum, grow it.
            if window.frame.width < 360 {
                var frame = window.frame
                frame.size.width = 360
                window.setFrame(frame, display: true)
            }
            if UserDefaults.standard.string(forKey: "NSWindow Frame NaviWindow") == nil,
               let screen = window.screen {
                let sf = screen.visibleFrame
                let x = sf.maxX - window.frame.width - 20
                let y = sf.maxY - window.frame.height - 20
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
            // Hide if floating mode is off
            if !UserDefaults.standard.bool(forKey: "NaviFloatingWindow") {
                window.orderOut(nil)
            }
            // Sync isFloating when user closes the window via traffic light
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
            // When the user finishes a live (drag) resize, remember that size
            // as a floor so auto-shrink doesn't take the window back below it.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { note in
                guard let win = note.object as? NSWindow else { return }
                UserDefaults.standard.set(Double(win.frame.width), forKey: "NaviUserMinWidth")
                UserDefaults.standard.set(Double(win.frame.height), forKey: "NaviUserMinHeight")
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - App Delegate

class NaviAppDelegate: NSObject, NSApplicationDelegate {
    static var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        NaviAppDelegate.isTerminating = true
    }
}

// MARK: - App Entry Point

@main
struct NaviApp: App {
    @NSApplicationDelegateAdaptor(NaviAppDelegate.self) var appDelegate
    @StateObject private var monitor = EventMonitor()
    @StateObject private var floatingManager = FloatingWindowManager()
    private let menuBar = MenuBarManager()

    var body: some Scene {
        Window("Navi", id: "monitor") {
            ContentView(monitor: monitor, floatingManager: floatingManager, isFloatingWindow: true)
                .onAppear {
                    menuBar.attach(monitor: monitor, floatingManager: floatingManager)
                    if floatingManager.menuBarEnabled { menuBar.enable() }
                }
                .onReceive(floatingManager.$menuBarEnabled) { on in
                    if on { menuBar.enable() } else { menuBar.disable() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .defaultPosition(.topTrailing)
    }
}
