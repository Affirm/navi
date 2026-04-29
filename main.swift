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

/// One-shot NSLog gate. The first call for a given key emits the message; subsequent
/// calls with the same key are silently dropped. Owner must serialize access (e.g.
/// confine to a single DispatchQueue).
struct LoggedOnce {
    private var keys: Set<String> = []
    mutating func log(key: String, _ message: @autoclosure () -> String) {
        guard !keys.contains(key) else { return }
        keys.insert(key)
        NSLog("%@", message())
    }
}

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

/// Activate the terminal tab that owns `tty` (e.g. "/dev/ttys003").
func focusTerminal(tty: String) {
    guard !tty.isEmpty else { return }
    guard tty.range(of: #"^/dev/tty[a-zA-Z0-9]+$"#, options: .regularExpression) != nil else {
        naviLog("focusTerminal: invalid tty format: %@", tty)
        return
    }
    naviLog("focusTerminal: looking for tty=%@", tty)

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
                naviLog("focusTerminal: activated tty=%@", tty)
                return
            }
        } catch {
            naviLog("focusTerminal: osascript error: %@", error.localizedDescription)
        }
    }
    naviLog("focusTerminal: no terminal found for tty=%@", tty)
}

// MARK: - Version

let naviCurrentVersion = "1.1.3"

// MARK: - Pastel Palette

extension Color {
    static let pastelGreen  = Color(hue: 0.33, saturation: 0.45, brightness: 0.85)
    static let pastelYellow = Color(hue: 0.13, saturation: 0.45, brightness: 0.90)
    static let pastelGray   = Color(hue: 0.00, saturation: 0.00, brightness: 0.75)
    static let pastelBlue   = Color(hue: 0.58, saturation: 0.40, brightness: 0.90)
    static let pastelPurple = Color(hue: 0.78, saturation: 0.40, brightness: 0.85)
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedRowWidth = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if proposedRowWidth > maxWidth && rowWidth > 0 {
                maxRowWidth = max(maxRowWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = proposedRowWidth
                rowHeight = max(rowHeight, size.height)
            }
        }
        maxRowWidth = max(maxRowWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxRowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Enrichment Data Model

struct GitInfo: Equatable {
    let branch: String
    let isDirty: Bool
    let isDetached: Bool
    let ahead: Int?
    let behind: Int?
    let defaultBranch: String?
    let fetchedAt: Date

    // Equality ignores fetchedAt so SwiftUI does not re-render every refresh when
    // the data the badge displays has not actually changed.
    static func == (lhs: GitInfo, rhs: GitInfo) -> Bool {
        lhs.branch == rhs.branch
            && lhs.isDirty == rhs.isDirty
            && lhs.isDetached == rhs.isDetached
            && lhs.ahead == rhs.ahead
            && lhs.behind == rhs.behind
            && lhs.defaultBranch == rhs.defaultBranch
    }
}

struct TranscriptInfo: Equatable {
    let model: String?
    let permissionMode: String?
    let fetchedAt: Date

    // Equality ignores fetchedAt so SwiftUI does not re-render when only the
    // refresh timestamp changes; values are what the UI actually depends on.
    static func == (lhs: TranscriptInfo, rhs: TranscriptInfo) -> Bool {
        lhs.model == rhs.model && lhs.permissionMode == rhs.permissionMode
    }
}

struct PRInfo: Equatable {
    let number: Int
    let url: URL
    let branch: String
    let fetchedAt: Date

    static func == (lhs: PRInfo, rhs: PRInfo) -> Bool {
        lhs.number == rhs.number && lhs.url == rhs.url && lhs.branch == rhs.branch
    }
}

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
    weak var enrichmentService: EnrichmentService?

    func attach(enrichmentService: EnrichmentService) {
        self.enrichmentService = enrichmentService
        for info in sessions.values {
            enrichmentService.refresh(for: info)
        }
    }

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: eventsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: responsesDir, withIntermediateDirectories: true)
        // Clean stale files from previous runs
        cleanDirectory(eventsDir)
        cleanDirectory(responsesDir)
        try? fm.removeItem(atPath: "/tmp/navi/needs-restart")

        // Discover already-running Claude sessions from ~/.claude/sessions/
        if UserDefaults.standard.bool(forKey: "NaviExp.SessionStatus") {
            discoverSessions()
        }

        let instantNotify = UserDefaults.standard.object(forKey: "NaviExp.InstantNotify") == nil
            || UserDefaults.standard.bool(forKey: "NaviExp.InstantNotify")

        // Watch the events directory for new files — triggers poll() instantly
        // via kqueue so events appear with near-zero latency.
        if instantNotify {
            let fd = open(eventsDir, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fd, eventMask: .write, queue: .main)
                source.setEventHandler { [weak self] in self?.poll() }
                source.setCancelHandler { close(fd) }
                source.resume()
                dirSource = source
            }
        }

        // Timer: fallback for cleanup when instant notify is on, primary poll otherwise.
        let interval: TimeInterval = instantNotify ? 1.0 : 0.3
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
                if UserDefaults.standard.bool(forKey: "NaviExp.AutoDismiss"),
                   let data = fm.contents(atPath: path),
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
                // When auto-dismiss is enabled and a Stop event arrives,
                // dismiss all pending permissions for this session (the turn
                // ended, so any unresolved permission was denied/interrupted).
                // When auto-dismiss is off, use the original 30s age threshold.
                if event.type != "permission" {
                    let autoDismiss = UserDefaults.standard.bool(forKey: "NaviExp.AutoDismiss")
                    let minAge: TimeInterval = (autoDismiss && event.type == "stop") ? 0 : 30
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
            let statusEnabled = UserDefaults.standard.bool(forKey: "NaviExp.SessionStatus")
            // Discover new sessions BEFORE applying working signals so that
            // a brand-new session's first working signal isn't dropped.
            if statusEnabled {
                self.discoverSessions()
            }
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
            self.sessions = self.sessions.filter { (_, info) in
                if statusEnabled { return info.isAlive }
                return now.timeIntervalSince(info.lastActivity) < 300
            }

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
            if let info = sessions[sid] {
                enrichmentService?.refresh(for: info)
            }
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
        if let info = sessions[sid] {
            enrichmentService?.refresh(for: info)
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

// MARK: - Enrichment Service

final class EnrichmentService: ObservableObject {
    @Published private(set) var gitInfoByCwd: [String: GitInfo] = [:]
    @Published private(set) var transcriptInfoBySid: [String: TranscriptInfo] = [:]
    @Published private(set) var prInfoByCwdBranch: [String: PRInfo] = [:]

    private let queue = DispatchQueue(label: "navi.enrichment", qos: .utility)
    private var gitCache: [String: GitInfo] = [:]
    private var pendingRefreshes: Set<String> = []
    private var inFlightRefreshes: Set<String> = []
    private var lastRefreshScheduledByCwd: [String: Date] = [:]
    private var logged = LoggedOnce()
    private var gitAvailable: Bool = true

    private var transcriptCache: [String: TranscriptInfo] = [:]
    private var pendingTranscriptRefreshes: Set<String> = []
    private var inFlightTranscriptRefreshes: Set<String> = []
    private var lastTranscriptRefreshBySid: [String: Date] = [:]

    private var prCache: [String: PRInfo] = [:]
    private var pendingPRRefreshes: Set<String> = []
    private var inFlightPRRefreshes: Set<String> = []
    private var lastPRRefreshByKey: [String: Date] = [:]
    private var ghAvailable: Bool = false
    private var ghProbeDone: Bool = false

    unowned let floatingManager: FloatingWindowManager

    init(floatingManager: FloatingWindowManager) {
        self.floatingManager = floatingManager
    }

    static func prKey(cwd: String, branch: String) -> String {
        "\(cwd)\u{1f}\(branch)"
    }

    func refresh(for session: SessionInfo) {
        guard floatingManager.anyEnrichmentToggleOn else { return }
        let cwd = session.cwd
        guard !cwd.isEmpty else { return }
        scheduleGitRefresh(cwd: cwd)
        if floatingManager.showModeEnabled || floatingManager.showModelEnabled,
           !session.id.isEmpty {
            scheduleTranscriptRefresh(sessionID: session.id, cwd: cwd)
        }
    }

    private func scheduleGitRefresh(cwd: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pendingRefreshes.contains(cwd) || self.inFlightRefreshes.contains(cwd) {
                return
            }
            if let last = self.lastRefreshScheduledByCwd[cwd],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingRefreshes.insert(cwd)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingRefreshes.remove(cwd)
                    self.runGitRefresh(cwd: cwd)
                }
                return
            }
            self.runGitRefresh(cwd: cwd)
        }
    }

    private func runGitRefresh(cwd: String) {
        // Defensive on-queue reentrancy guard; matches the PR/transcript refresh shape.
        if inFlightRefreshes.contains(cwd) { return }
        inFlightRefreshes.insert(cwd)
        lastRefreshScheduledByCwd[cwd] = Date()
        defer { inFlightRefreshes.remove(cwd) }

        guard gitAvailable else { return }

        guard let branchProbe = runProcess(executable: "git", args: ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"]) else {
            return
        }
        if branchProbe.exitCode != 0 {
            gitCache.removeValue(forKey: cwd)
            DispatchQueue.main.async { [weak self] in
                self?.gitInfoByCwd.removeValue(forKey: cwd)
            }
            return
        }
        let rawBranch = branchProbe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var branch = rawBranch
        var isDetached = false
        if rawBranch == "HEAD" {
            isDetached = true
            if let sha = runProcess(executable: "git", args: ["-C", cwd, "rev-parse", "--short", "HEAD"]),
               sha.exitCode == 0 {
                branch = sha.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var isDirty = false
        if let status = runProcess(executable: "git", args: ["-C", cwd, "status", "--porcelain"]),
           status.exitCode == 0 {
            isDirty = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var defaultBranch: String? = nil
        if let head = runProcess(executable: "git", args: ["-C", cwd, "symbolic-ref", "refs/remotes/origin/HEAD", "--short"]),
           head.exitCode == 0 {
            let value = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("origin/") {
                defaultBranch = String(value.dropFirst("origin/".count))
            } else if !value.isEmpty {
                defaultBranch = value
            }
        }
        if defaultBranch == nil,
           let main = runProcess(executable: "git", args: ["-C", cwd, "show-ref", "--verify", "refs/heads/main"]),
           main.exitCode == 0 {
            defaultBranch = "main"
        }
        if defaultBranch == nil,
           let master = runProcess(executable: "git", args: ["-C", cwd, "show-ref", "--verify", "refs/heads/master"]),
           master.exitCode == 0 {
            defaultBranch = "master"
        }

        var ahead: Int? = nil
        var behind: Int? = nil
        if !isDetached, let def = defaultBranch, def != branch {
            if let counts = runProcess(executable: "git", args: ["-C", cwd, "rev-list", "--left-right", "--count", "\(branch)...\(def)"]),
               counts.exitCode == 0 {
                let parts = counts.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(whereSeparator: { $0 == "\t" || $0 == " " })
                if parts.count == 2,
                   let leftCount = Int(parts[0]),
                   let rightCount = Int(parts[1]) {
                    ahead = leftCount
                    behind = rightCount
                }
            }
        } else if !isDetached, let def = defaultBranch, def == branch {
            ahead = 0
            behind = 0
        }

        let newInfo = GitInfo(
            branch: branch,
            isDirty: isDirty,
            isDetached: isDetached,
            ahead: ahead,
            behind: behind,
            defaultBranch: defaultBranch,
            fetchedAt: Date()
        )

        let prevBranch = gitCache[cwd]?.branch
        gitCache[cwd] = newInfo
        if let prev = prevBranch, prev != newInfo.branch {
            handleBranchSwitch(cwd: cwd, oldBranch: prev)
        }

        DispatchQueue.main.async { [weak self] in
            self?.gitInfoByCwd[cwd] = newInfo
        }

        if floatingManager.showGitEnabled,
           !newInfo.isDetached, !newInfo.branch.isEmpty {
            schedulePRRefresh(cwd: cwd, branch: newInfo.branch)
        }
    }

    private func handleBranchSwitch(cwd: String, oldBranch: String) {
        invalidatePRCache(cwd: cwd, branch: oldBranch)
    }

    private func probeGhAvailability() {
        guard !ghProbeDone else { return }
        ghProbeDone = true

        let candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        let installed = candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !installed {
            ghAvailable = false
            logged.log(key: "gh-not-found", "[Navi] gh not found on PATH; PR enrichment disabled.")
            return
        }

        guard let auth = runProcess(executable: "gh", args: ["auth", "status"]) else {
            ghAvailable = false
            logged.log(key: "gh-auth-failed", "[Navi] gh authentication failed; PR enrichment disabled.")
            return
        }
        if auth.exitCode == 0 {
            ghAvailable = true
        } else {
            ghAvailable = false
            logged.log(key: "gh-auth-failed", "[Navi] gh authentication failed; PR enrichment disabled.")
        }
    }

    private func schedulePRRefresh(cwd: String, branch: String) {
        let key = Self.prKey(cwd: cwd, branch: branch)
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.ghProbeDone {
                self.probeGhAvailability()
            }
            guard self.ghAvailable else { return }
            if self.pendingPRRefreshes.contains(key) || self.inFlightPRRefreshes.contains(key) {
                return
            }
            if let cached = self.prCache[key],
               Date().timeIntervalSince(cached.fetchedAt) < 60 {
                return
            }
            if let last = self.lastPRRefreshByKey[key],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingPRRefreshes.insert(key)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingPRRefreshes.remove(key)
                    self.runPRRefresh(cwd: cwd, branch: branch)
                }
                return
            }
            self.runPRRefresh(cwd: cwd, branch: branch)
        }
    }

    private func runPRRefresh(cwd: String, branch: String) {
        guard ghAvailable else { return }
        if branch.isEmpty || branch == "HEAD" { return }

        let key = Self.prKey(cwd: cwd, branch: branch)
        if inFlightPRRefreshes.contains(key) { return }
        inFlightPRRefreshes.insert(key)
        lastPRRefreshByKey[key] = Date()
        // runs synchronously on the serial queue, so defer is safe.
        defer { inFlightPRRefreshes.remove(key) }

        guard let result = runProcess(
            executable: "gh",
            args: ["pr", "list", "--head", branch, "--state", "open", "--json", "number,url", "--limit", "1"],
            cwd: cwd
        ) else {
            return
        }

        if result.exitCode != 0 {
            logged.log(key: "gh-pr-list-failed", "[Navi] gh pr list failed; preserving cached PR data.")
            return
        }

        guard let data = result.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }

        if arr.isEmpty {
            if prCache.removeValue(forKey: key) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.prInfoByCwdBranch.removeValue(forKey: key)
                }
            }
            return
        }

        guard let first = arr.first,
              let number = first["number"] as? Int,
              let urlString = first["url"] as? String,
              let url = URL(string: urlString) else {
            return
        }

        let newInfo = PRInfo(number: number, url: url, branch: branch, fetchedAt: Date())
        let existing = prCache[key]
        if existing == newInfo { return }
        prCache[key] = newInfo
        DispatchQueue.main.async { [weak self] in
            self?.prInfoByCwdBranch[key] = newInfo
        }
    }

    private func invalidatePRCache(cwd: String, branch: String) {
        let key = Self.prKey(cwd: cwd, branch: branch)
        if prCache.removeValue(forKey: key) != nil {
            DispatchQueue.main.async { [weak self] in
                self?.prInfoByCwdBranch.removeValue(forKey: key)
            }
        }
        pendingPRRefreshes.remove(key)
        lastPRRefreshByKey.removeValue(forKey: key)
    }

    private func scheduleTranscriptRefresh(sessionID: String, cwd: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.pendingTranscriptRefreshes.contains(sessionID) ||
               self.inFlightTranscriptRefreshes.contains(sessionID) {
                return
            }
            if let last = self.lastTranscriptRefreshBySid[sessionID],
               Date().timeIntervalSince(last) < 0.5 {
                self.pendingTranscriptRefreshes.insert(sessionID)
                let delay = 0.5 - Date().timeIntervalSince(last)
                self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self else { return }
                    self.pendingTranscriptRefreshes.remove(sessionID)
                    self.runTranscriptRefresh(sessionID: sessionID, cwd: cwd)
                }
                return
            }
            self.runTranscriptRefresh(sessionID: sessionID, cwd: cwd)
        }
    }

    private func runTranscriptRefresh(sessionID: String, cwd: String) {
        if inFlightTranscriptRefreshes.contains(sessionID) { return }
        inFlightTranscriptRefreshes.insert(sessionID)
        lastTranscriptRefreshBySid[sessionID] = Date()
        defer { inFlightTranscriptRefreshes.remove(sessionID) }

        guard let url = transcriptURL(forSessionID: sessionID, cwd: cwd) else {
            if transcriptCache.removeValue(forKey: sessionID) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptInfoBySid.removeValue(forKey: sessionID)
                }
            }
            return
        }

        guard let lines = readTranscriptTail(url: url) else {
            if transcriptCache.removeValue(forKey: sessionID) != nil {
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptInfoBySid.removeValue(forKey: sessionID)
                }
            }
            return
        }

        var model: String? = nil
        var permissionMode: String? = nil
        var consecutiveParseFailures = 0
        var maxConsecutiveFailures = 0
        for line in lines.reversed() {
            if model != nil && permissionMode != nil { break }
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                consecutiveParseFailures += 1
                maxConsecutiveFailures = max(maxConsecutiveFailures, consecutiveParseFailures)
                continue
            }
            consecutiveParseFailures = 0
            if model == nil,
               let message = obj["message"] as? [String: Any],
               (message["role"] as? String) == "assistant",
               let m = message["model"] as? String, !m.isEmpty {
                model = m
            }
            if permissionMode == nil {
                if let pm = obj["permissionMode"] as? String, !pm.isEmpty {
                    permissionMode = pm
                } else if let message = obj["message"] as? [String: Any],
                          let pm = message["permissionMode"] as? String, !pm.isEmpty {
                    permissionMode = pm
                }
            }
        }
        if maxConsecutiveFailures >= 3 {
            logged.log(
                key: "transcript-parse-error-\(sessionID)",
                "[Navi] transcript parse error for session \(sessionID): \(maxConsecutiveFailures) consecutive lines failed to parse"
            )
        }

        let existing = transcriptCache[sessionID]
        if model == nil && permissionMode == nil && existing == nil {
            return
        }

        let newInfo = TranscriptInfo(model: model, permissionMode: permissionMode, fetchedAt: Date())
        if existing == newInfo { return }
        transcriptCache[sessionID] = newInfo
        DispatchQueue.main.async { [weak self] in
            self?.transcriptInfoBySid[sessionID] = newInfo
        }
    }

    private func transcriptURL(forSessionID sessionID: String, cwd: String) -> URL? {
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let direct = projectsRoot
            .appendingPathComponent(encodedProjectDir(forCwd: cwd), isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        // Fallback: scan one level under ~/.claude/projects/ for <sessionID>.jsonl.
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: projectsRoot,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])
        else { return nil }
        for dir in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let candidate = dir.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func encodedProjectDir(forCwd cwd: String) -> String {
        cwd.replacingOccurrences(of: "/", with: "-")
    }

    private func readTranscriptTail(url: URL, maxBytes: Int = 65_536) -> [Data]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return nil }
        let start = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: start) } catch { return nil }
        var data = handle.readDataToEndOfFile()
        if data.isEmpty { return nil }

        if start > 0 {
            guard let firstNewline = data.firstIndex(of: 0x0A) else { return nil }
            data = data.subdata(in: data.index(after: firstNewline)..<data.endIndex)
        }

        // Swift 6.3 has an ambiguous Sequence/Collection split overload on Data;
        // build the result manually to sidestep it.
        var lines: [Data] = []
        var lineStart = data.startIndex
        for i in data.indices {
            if data[i] == 0x0A {
                if i > lineStart {
                    lines.append(data.subdata(in: lineStart..<i))
                }
                lineStart = data.index(after: i)
            }
        }
        if lineStart < data.endIndex {
            lines.append(data.subdata(in: lineStart..<data.endIndex))
        }
        return lines
    }

    private func runProcess(executable: String, args: [String], cwd: String? = nil, timeout: TimeInterval = 2.0) -> (stdout: String, exitCode: Int32)? {
        let process = Process()
        let candidatePaths: [String]
        if executable == "git" {
            candidatePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        } else if executable == "gh" {
            candidatePaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        } else {
            candidatePaths = []
        }

        var resolvedPath: String? = nil
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            resolvedPath = path
            break
        }

        if let path = resolvedPath {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + args
        }

        if let cwd = cwd, !cwd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            if executable == "git" {
                logged.log(key: "git-not-found", "[Navi] git not found on PATH; git enrichment disabled.")
                gitAvailable = false
            }
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            logged.log(key: "subprocess-timeout-\(executable)", "[Navi] subprocess timeout: \(executable)")
            return nil
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        return (stdout, process.terminationStatus)
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
        let aliveEnabled = UserDefaults.standard.bool(forKey: "NaviExp.SessionStatus")
        if aliveEnabled && info.isAlive {
            if info.lastEventType == "working" {
                return .working
            }
            return .waitingForInput
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

    @Published var terminalFocusEnabled: Bool {
        didSet {
            UserDefaults.standard.set(terminalFocusEnabled, forKey: "NaviExp.TerminalFocus")
            Self.setFeatureFlag("terminal-focus", enabled: terminalFocusEnabled)
        }
    }

    @Published var autoDismissEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDismissEnabled, forKey: "NaviExp.AutoDismiss")
            Self.setFeatureFlag("auto-dismiss", enabled: autoDismissEnabled)
        }
    }

    @Published var sessionNamesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionNamesEnabled, forKey: "NaviExp.SessionNames")
            Self.setFeatureFlag("session-names", enabled: sessionNamesEnabled)
        }
    }

    @Published var instantNotifyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(instantNotifyEnabled, forKey: "NaviExp.InstantNotify")
            Self.setFeatureFlag("instant-notify", enabled: instantNotifyEnabled)
        }
    }

    @Published var sessionStatusEnabled: Bool {
        didSet {
            UserDefaults.standard.set(sessionStatusEnabled, forKey: "NaviExp.SessionStatus")
            Self.setFeatureFlag("session-status", enabled: sessionStatusEnabled)
        }
    }

    @Published var detailedPermissionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(detailedPermissionsEnabled, forKey: "NaviExp.DetailedPermissions")
            Self.setFeatureFlag("detailed-permissions", enabled: detailedPermissionsEnabled)
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

    var anyEnrichmentToggleOn: Bool {
        showFolderEnabled || showGitEnabled || showModeEnabled || showModelEnabled
    }

    var computedWindowWidth: CGFloat {
        switch (anyEnrichmentToggleOn, detailedPermissionsEnabled) {
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
            atPath: Self.featuresDir, withIntermediateDirectories: true)
        Self.setFeatureFlag("menu-bar", enabled: menuBarEnabled)
        Self.setFeatureFlag("terminal-focus", enabled: terminalFocusEnabled)
        Self.setFeatureFlag("auto-dismiss", enabled: autoDismissEnabled)
        Self.setFeatureFlag("session-names", enabled: sessionNamesEnabled)
        Self.setFeatureFlag("instant-notify", enabled: instantNotifyEnabled)
        Self.setFeatureFlag("session-status", enabled: sessionStatusEnabled)
        Self.setFeatureFlag("detailed-permissions", enabled: detailedPermissionsEnabled)
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
        if UserDefaults.standard.object(forKey: "NaviExp.TerminalFocus") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.TerminalFocus")
            terminalFocusEnabled = true
        } else {
            terminalFocusEnabled = UserDefaults.standard.bool(forKey: "NaviExp.TerminalFocus")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.AutoDismiss") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.AutoDismiss")
            autoDismissEnabled = true
        } else {
            autoDismissEnabled = UserDefaults.standard.bool(forKey: "NaviExp.AutoDismiss")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.SessionNames") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.SessionNames")
            sessionNamesEnabled = true
        } else {
            sessionNamesEnabled = UserDefaults.standard.bool(forKey: "NaviExp.SessionNames")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.InstantNotify") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.InstantNotify")
            instantNotifyEnabled = true
        } else {
            instantNotifyEnabled = UserDefaults.standard.bool(forKey: "NaviExp.InstantNotify")
        }
        if UserDefaults.standard.object(forKey: "NaviExp.SessionStatus") == nil {
            UserDefaults.standard.set(true, forKey: "NaviExp.SessionStatus")
            sessionStatusEnabled = true
        } else {
            sessionStatusEnabled = UserDefaults.standard.bool(forKey: "NaviExp.SessionStatus")
        }
        detailedPermissionsEnabled = UserDefaults.standard.bool(forKey: "NaviExp.DetailedPermissions")
        showFolderEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowFolder")
        showGitEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowGit")
        showModeEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowMode")
        showModelEnabled = UserDefaults.standard.bool(forKey: "NaviExp.ShowModel")

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
    private var enrichmentService: EnrichmentService?
    private var eventObserver: Any?

    func attach(monitor: EventMonitor, floatingManager: FloatingWindowManager, enrichmentService: EnrichmentService) {
        self.monitor = monitor
        self.floatingManager = floatingManager
        self.enrichmentService = enrichmentService
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
        guard let monitor = monitor,
              let floatingManager = floatingManager,
              let enrichmentService = enrichmentService else { return }
        // Reuse existing popover, create once
        if popover == nil {
            let pop = NSPopover()
            let width: CGFloat = floatingManager.computedWindowWidth
            pop.contentSize = NSSize(width: width, height: 500)
            pop.behavior = .transient
            pop.animates = true
            pop.contentViewController = NSHostingController(
                rootView: ContentView(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
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
    @ObservedObject var enrichmentService: EnrichmentService
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
        .frame(width: floatingManager.computedWindowWidth)
        .overlay(
            Group {
                if isFloatingWindow {
                    GeometryReader { geo in
                        Color.clear.preference(key: ViewHeightKey.self, value: geo.size.height)
                    }
                }
            }
        )
        .onPreferenceChange(ViewHeightKey.self) { height in
            if isFloatingWindow { resizeWindow(to: height + 28) }
        }
        .background(.ultraThinMaterial)
        .background(Group { if isFloatingWindow { WindowAccessor(floatingManager: floatingManager) } })
    }

    private func resizeWindow(to targetHeight: CGFloat) {
        DispatchQueue.main.async {
            guard let window = NaviWindow.ref else { return }
            if targetHeight < 1 { return }
            let top = window.frame.maxY
            var frame = window.frame
            frame.size.height = targetHeight
            frame.origin.y = top - targetHeight
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

            experimentalRow("Jump to terminal", subtitle: "Adds a \"Jump to Terminal\" button on each session",
                isOn: Binding(get: { floatingManager.terminalFocusEnabled }, set: { floatingManager.terminalFocusEnabled = $0 }))

            experimentalRow("Menu bar icon", subtitle: "Adds a menu bar icon for Navi.",
                isOn: Binding(get: { floatingManager.menuBarEnabled }, set: { floatingManager.menuBarEnabled = $0 }))

            if floatingManager.menuBarEnabled {
                experimentalRow("Floating window", subtitle: "Always-on-top floating window",
                    isOn: Binding(get: { floatingManager.isFloating }, set: { floatingManager.isFloating = $0 }), indent: true)
            }

            experimentalRow("Auto-dismiss", subtitle: "Dismiss permissions when approved in the terminal. Shows \"Respond in terminal\" after the hook times out.",
                isOn: Binding(get: { floatingManager.autoDismissEnabled }, set: { floatingManager.autoDismissEnabled = $0 }))

            experimentalRow("Session names", subtitle: "Show session name (from /rename) instead of project folder",
                isOn: Binding(get: { floatingManager.sessionNamesEnabled }, set: { floatingManager.sessionNamesEnabled = $0 }))

            experimentalRow("Session status", subtitle: "Show Working/Idle status per session. Dead sessions auto-clean immediately.",
                isOn: Binding(get: { floatingManager.sessionStatusEnabled }, set: { floatingManager.sessionStatusEnabled = $0 }))

            experimentalRow("Instant notifications", subtitle: "Use filesystem watcher instead of polling for near-instant event detection",
                isOn: Binding(get: { floatingManager.instantNotifyEnabled }, set: { floatingManager.instantNotifyEnabled = $0 }),
                requiresRestart: true)

            experimentalRow("Detailed permissions", subtitle: "Show the full tool input for permission requests. Widens the Navi window.",
                isOn: Binding(get: { floatingManager.detailedPermissionsEnabled }, set: { floatingManager.detailedPermissionsEnabled = $0 }))

            Text("Session details")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            experimentalRow("Folder path", subtitle: "Show the working directory for each session.",
                isOn: Binding(get: { floatingManager.showFolderEnabled }, set: { floatingManager.showFolderEnabled = $0 }))

            experimentalRow("Git status", subtitle: "Show branch, dirty state, and any open PR for each session.",
                isOn: Binding(get: { floatingManager.showGitEnabled }, set: { floatingManager.showGitEnabled = $0 }))

            experimentalRow("Claude mode", subtitle: "Show the active permission mode (plan, auto, acceptEdits, bypassPermissions).",
                isOn: Binding(get: { floatingManager.showModeEnabled }, set: { floatingManager.showModeEnabled = $0 }))

            experimentalRow("Claude model", subtitle: "Show the model used by each session (e.g. opus-4-7, sonnet-4-6).",
                isOn: Binding(get: { floatingManager.showModelEnabled }, set: { floatingManager.showModelEnabled = $0 }))

            if floatingManager.pendingRestart {
                restartBanner
            }

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
                SessionSection(group: group, monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Session Section

private func headTruncated(_ path: String, max: Int) -> String {
    if path.count <= max { return path }
    return "\u{2026}" + String(path.suffix(max - 1))
}

private func middleTruncated(_ s: String, max: Int) -> String {
    if s.count <= max { return s }
    let keep = max - 1
    let prefixLen = keep - keep / 2
    let suffixLen = keep - prefixLen
    return String(s.prefix(prefixLen)) + "\u{2026}" + String(s.suffix(suffixLen))
}

private func shortModel(_ raw: String) -> String {
    var s = raw
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    if s.lowercased().hasSuffix("-1m") { s = String(s.dropLast(3)) }
    return s
}

struct SessionSection: View {
    let group: SessionGroup
    @ObservedObject var monitor: EventMonitor
    @ObservedObject var floatingManager: FloatingWindowManager
    @ObservedObject var enrichmentService: EnrichmentService
    @State private var isExpanded = false
    @AppStorage("NaviFontScale") private var s: Double = 1.0

    private var shouldExpand: Bool {
        group.hasPending
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session header
            VStack(alignment: .leading, spacing: 2) {
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

                    if floatingManager.terminalFocusEnabled && !group.info.tty.isEmpty {
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

                if floatingManager.anyEnrichmentToggleOn {
                    FlowLayout(spacing: 6) {
                        if floatingManager.showFolderEnabled && !group.info.cwd.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(headTruncated(group.info.cwd, max: 28))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(4)
                            .help(group.info.cwd)
                        }
                        if floatingManager.showGitEnabled,
                           let git = enrichmentService.gitInfoByCwd[group.info.cwd] {
                            let bg: Color = {
                                if git.isDetached { return Color.pastelGray.opacity(0.15) }
                                if git.isDirty { return Color.pastelYellow.opacity(0.15) }
                                return Color.pastelGreen.opacity(0.15)
                            }()
                            let display: String = {
                                var text = middleTruncated(git.branch, max: 20)
                                if !git.isDetached && git.isDirty { text += "*" }
                                if !git.isDetached, git.defaultBranch != nil,
                                   let a = git.ahead, a > 0 { text += "\u{2191}\(a)" }
                                if !git.isDetached, git.defaultBranch != nil,
                                   let b = git.behind, b > 0 { text += "\u{2193}\(b)" }
                                return text
                            }()
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(display)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(bg)
                            .cornerRadius(4)
                            .help(git.branch)
                        }
                        if floatingManager.showGitEnabled,
                           let git = enrichmentService.gitInfoByCwd[group.info.cwd],
                           !git.isDetached, !git.branch.isEmpty,
                           let pr = enrichmentService.prInfoByCwdBranch[EnrichmentService.prKey(cwd: group.info.cwd, branch: git.branch)] {
                            Button {
                                NSWorkspace.shared.open(pr.url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                    Text("#\(pr.number)")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                            .help("Open PR #\(pr.number) in browser")
                        }
                        if floatingManager.showModeEnabled,
                           let mode = enrichmentService.transcriptInfoBySid[group.info.id]?.permissionMode {
                            Text(mode)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pastelBlue.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        if floatingManager.showModelEnabled,
                           let model = enrichmentService.transcriptInfoBySid[group.info.id]?.model {
                            Text(shortModel(model))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.pastelPurple.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
                }
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
    @AppStorage("NaviExp.DetailedPermissions") private var detailedPermissions: Bool = false

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
                    if detailedPermissions && event.type == "permission" {
                        ScrollView {
                            Text(event.body)
                                .font(.system(size: 12 * s, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                    } else {
                        Text(event.body)
                            .font(.system(size: 12 * s, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
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
                if UserDefaults.standard.bool(forKey: "NaviExp.AutoDismiss"),
                   let expires = event.expires {
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

    private var permissionButtons: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Deny") { monitor.respond(to: event.id, with: "deny") }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)
            Button("Approve") { monitor.respond(to: event.id, with: "approve") }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var respondInTerminalLabel: some View {
        HStack(spacing: 4) {
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
            // Restore saved position, or default to top-right corner
            if !window.setFrameAutosaveName("NaviWindow") {
                // Name already set — frame restored automatically
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
    @StateObject private var floatingManager: FloatingWindowManager
    @StateObject private var enrichmentService: EnrichmentService
    private let menuBar = MenuBarManager()

    init() {
        let manager = FloatingWindowManager()
        _floatingManager = StateObject(wrappedValue: manager)
        _enrichmentService = StateObject(wrappedValue: EnrichmentService(floatingManager: manager))
    }

    var body: some Scene {
        Window("Navi", id: "monitor") {
            ContentView(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService, isFloatingWindow: true)
                .onAppear {
                    monitor.attach(enrichmentService: enrichmentService)
                    menuBar.attach(monitor: monitor, floatingManager: floatingManager, enrichmentService: enrichmentService)
                    if floatingManager.menuBarEnabled { menuBar.enable() }
                }
                .onReceive(floatingManager.$menuBarEnabled) { on in
                    if on { menuBar.enable() } else { menuBar.disable() }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}
