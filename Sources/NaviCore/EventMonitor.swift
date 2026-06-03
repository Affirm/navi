import Foundation
import Combine
import AppKit

public class EventMonitor: ObservableObject {
    @Published public var events: [NaviEvent] = []
    @Published public var sessions: [String: SessionInfo] = [:]
    @Published public var needsBinaryRestart = false

    private let eventsDir = "/tmp/navi/events"
    private let responsesDir = "/tmp/navi/responses"
    private var knownIDs = Set<String>()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    public weak var enrichmentService: (any SessionEnrichmentProvider)?

    public func attach(enrichmentService: any SessionEnrichmentProvider) {
        self.enrichmentService = enrichmentService
        for info in sessions.values {
            enrichmentService.refresh(for: info)
        }
    }

    public init() {
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
                description: dict["description"] as? String ?? "",
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

    /// Parse Claude's `updatedAt` field (epoch milliseconds) into a Date.
    private func parseUpdatedAt(_ any: Any?) -> Date? {
        let ms: Double?
        if let d = any as? Double { ms = d }
        else if let i = any as? Int { ms = Double(i) }
        else { ms = nil }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Scan ~/.claude/sessions/ for running Claude processes. Adds any session
    /// Navi doesn't know about yet, and — for sessions already tracked —
    /// refreshes the canonical `status`/`updatedAt` fields each poll so the
    /// reconcile in SessionGroup.status can self-heal stale hook-derived state.
    /// Other per-session state (TTY, lastEventType) is preserved for tracked
    /// sessions; the expensive TTY lookup runs only on first discovery.
    private func discoverSessions() {
        let sessionsDir = NSString(string: "~/.claude/sessions").expandingTildeInPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = dict["sessionId"] as? String
            else { continue }

            let claudeStatus = dict["status"] as? String ?? ""
            let statusUpdatedAt = parseUpdatedAt(dict["updatedAt"])

            // Already tracked: just refresh the canonical status fields.
            if sessions[sid] != nil {
                sessions[sid]!.claudeStatus = claudeStatus
                sessions[sid]!.statusUpdatedAt = statusUpdatedAt
                continue
            }

            // New session: require a live process before adding it.
            guard let pid = dict["pid"] as? Int, kill(pid_t(pid), 0) == 0 else { continue }
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
                lastActivity: Date(),
                claudeStatus: claudeStatus,
                statusUpdatedAt: statusUpdatedAt
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

    public func respond(to id: String, with response: String) {
        try? response.write(
            toFile: "\(responsesDir)/\(id)", atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            if let idx = self.events.firstIndex(where: { $0.id == id }) {
                self.events[idx].resolved = true
                self.events[idx].response = response
            }
        }
    }

    public func dismiss(_ id: String) {
        DispatchQueue.main.async {
            self.events.removeAll { $0.id == id }
        }
    }

    public func dismissSession(_ sessionID: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.removeAll { $0.sessionID == sessionID && !$0.isPending }
            self.sessions.removeValue(forKey: sessionID)
            // Tell the enrichment service to drop caches for this sid and any
            // cwds no longer referenced. Without this, gitCache /
            // transcriptCache / prCache (and their @Published mirrors) grow
            // unbounded over Navi's lifetime.
            if let svc = self.enrichmentService {
                svc.evict(sessionID: sessionID)
                svc.evictUnused(activeCwds: Set(self.sessions.values.map(\.cwd)))
            }
        }
    }

    public func clearAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let dismissedSids = Array(self.sessions.keys)
            self.events.removeAll { !$0.isPending }
            self.sessions.removeAll()
            if let svc = self.enrichmentService {
                for sid in dismissedSids {
                    svc.evict(sessionID: sid)
                }
                svc.evictUnused(activeCwds: [])
            }
        }
    }
}
