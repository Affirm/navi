import Foundation
import Combine
import AppKit

public class EventMonitor: ObservableObject, RemoteEventSink {
    @Published public var events: [NaviEvent] = []
    /// Sessions keyed by (origin, sessionID). See `SessionKey`.
    @Published public var sessions: [SessionKey: SessionInfo] = [:]
    @Published public var needsBinaryRestart = false

    private let stateDir: String
    private let eventsDir: String
    private let responsesDir: String
    private var knownIDs = Set<String>()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    /// Liveness reported by remote origins (keyed by host alias). The local
    /// origin's liveness is recomputed from the PID scan on every poll.
    private var remoteLiveness: [String: OriginLiveness] = [:]
    public weak var enrichmentService: (any SessionEnrichmentProvider)?
    /// Delivers approve/deny for permission cards from remote origins.
    public weak var remoteResponder: (any RemoteResponder)?
    /// Event IDs already ingested from remote origins ("origin/id").
    private var knownRemoteIDs = Set<String>()

    public func attach(enrichmentService: any SessionEnrichmentProvider) {
        self.enrichmentService = enrichmentService
        for info in sessions.values where info.isLocal {
            enrichmentService.refresh(for: info)
        }
    }

    public convenience init() {
        self.init(stateDir: "/tmp/navi", watch: true)
    }

    /// `watch: false` (tests) skips cleanup, session discovery and the
    /// directory watchers, so an instance never touches the live /tmp/navi.
    init(stateDir: String, watch: Bool) {
        self.stateDir = stateDir
        self.eventsDir = "\(stateDir)/events"
        self.responsesDir = "\(stateDir)/responses"
        guard watch else { return }
        let fm = FileManager.default
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? fm.createDirectory(atPath: eventsDir, withIntermediateDirectories: true, attributes: ownerOnly)
        try? fm.createDirectory(atPath: responsesDir, withIntermediateDirectories: true, attributes: ownerOnly)
        // Self-heal perms on pre-existing dirs so event JSON (Confidential tool
        // input) and response files (trusted permission-decision channel) stay
        // owner-readable only.
        try? fm.setAttributes(ownerOnly, ofItemAtPath: stateDir)
        try? fm.setAttributes(ownerOnly, ofItemAtPath: eventsDir)
        try? fm.setAttributes(ownerOnly, ofItemAtPath: responsesDir)
        // Clean stale files from previous runs
        cleanDirectory(eventsDir)
        cleanDirectory(responsesDir)
        try? fm.removeItem(atPath: "\(stateDir)/needs-restart")

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
        var workingSessions = Set<SessionKey>()
        for file in files.sorted() where file.hasSuffix(".json") {
            let path = "\(eventsDir)/\(file)"

            // Handle resolve signals from PostToolUse and cancel signals from
            // hook.sh EXIT trap (experimental auto-dismiss feature).
            if file.hasPrefix("resolve-") || file.hasPrefix("cancel-") {
                if let data = fm.contents(atPath: path),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    applyResolve(dict, origin: "")
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
                    workingSessions.insert(SessionKey(origin: "", sessionID: sid))
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

            let event = EventMonitor.makeEvent(from: dict, fallbackID: eventID, origin: "")
            DispatchQueue.main.async { self.receive(event) }
            // Stop included: it plays only if "Finished" is on in Settings → Sounds.
            newEventTypes.insert(event.type)
            try? fm.removeItem(atPath: path)
        }

        playSounds(for: newEventTypes)

        // Auto-dismiss old events and manage sessions
        let now = Date()
        DispatchQueue.main.async {
            self.events.removeAll { event in
                if event.isPending { return false }
                if event.type == "info" && !event.resolved { return false }
                if event.resolved { return now.timeIntervalSince(event.timestamp) > 10 }
                return now.timeIntervalSince(event.timestamp) > 60
            }
            // Discover new sessions BEFORE applying working signals so that
            // a brand-new session's first working signal isn't dropped. The
            // returned set is the authoritative list of session IDs backed by a
            // live process, used to prune ghosts below.
            let liveSessionIDs = self.discoverSessions()
            // Apply working signals AFTER regular events and discovery so
            // they always win over stale Stop events.
            self.applyWorking(workingSessions)
            // Prune ghosts by verified identity, per origin: local sessions
            // must be backed by a live process (skipped entirely if the
            // sessions dir couldn't be read, so a transient FS error never
            // wipes live sessions); remote sessions must be in their host's
            // last heartbeat, or are kept and flagged while it's disconnected.
            var liveness = self.remoteLiveness
            liveness[""] = liveSessionIDs.map { .live($0) } ?? .unknown
            self.reconcile(liveness: liveness)

            // Check if build.sh rebuilt a newer version while we're running
            let restartMarker = "\(self.stateDir)/needs-restart"
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

    /// Scan ~/.claude/sessions/ for running Claude processes. Adds any session
    /// Navi doesn't know about yet, and — for sessions already tracked —
    /// refreshes the canonical `status`/`updatedAt` fields each poll so the
    /// reconcile in SessionGroup.status can self-heal stale hook-derived state.
    /// TTY/lastEventType are preserved for tracked sessions (the expensive TTY
    /// lookup runs only on first discovery); the PID is refreshed when a resumed
    /// session reappears under a new process so liveness and focus stay correct.
    ///
    /// Returns the set of session IDs backed by a live Claude process — the
    /// authoritative input for pruning — or nil if the sessions directory could
    /// not be read, in which case the caller must skip pruning rather than wipe
    /// every session on a transient error.
    @discardableResult
    private func discoverSessions() -> Set<String>? {
        let sessionsDir = NSString(string: "~/.claude/sessions").expandingTildeInPath
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return nil }
        var discovered: [DiscoveredSession] = []
        for file in files where file.hasSuffix(".json") {
            let path = "\(sessionsDir)/\(file)"
            guard let data = fm.contents(atPath: path),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  // A session is live only if its file names a running process.
                  // This is the identity check that defeats PID reuse: the
                  // session id is recorded as live only when *its own* file
                  // points at a live PID.
                  let d = DiscoveredSession.parse(dict, isAlive: { kill($0, 0) == 0 })
            else { continue }
            discovered.append(d)
        }
        let added = SessionReconciler.merge(
            discovered, origin: "", into: &sessions,
            ttyLookup: EventMonitor.lookupTTY)
        for key in added {
            if let info = sessions[key] { enrichmentService?.refresh(for: info) }
        }
        return Set(discovered.filter(\.alive).map(\.sessionID))
    }

    /// Look up a local process's controlling TTY so terminal focus works
    /// immediately for newly discovered sessions.
    private static func lookupTTY(pid: pid_t) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return "" }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (!raw.isEmpty && raw != "??") ? "/dev/\(raw)" : ""
    }

    // MARK: - Event ingestion (shared by the local file pipeline and remote origins)

    /// Build a NaviEvent from an event-file dict. Missing fields get the same
    /// defaults the file pipeline has always used.
    public static func makeEvent(from dict: [String: Any], fallbackID: String, origin: String) -> NaviEvent {
        NaviEvent(
            id: dict["id"] as? String ?? fallbackID,
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
            expires: (dict["expires"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            origin: origin
        )
    }

    /// Main-thread handling of one new event. Matching against existing
    /// events/sessions is always by (origin, sessionID).
    private func receive(_ event: NaviEvent) {
        updateSession(for: event)
        let key = event.sessionKey
        // Skip Notification events for sessions that already have a
        // pending Permission — the permission itself signals "needs
        // attention", so the notification would be redundant.
        if event.type == "notification",
           events.contains(where: { $0.sessionKey == key && $0.isPending }) {
            return
        }
        // When a Stop event arrives, immediately dismiss pending
        // permissions for this session — the turn ended, so any
        // unresolved permission was denied/interrupted. Other
        // non-permission events use a 30s age threshold.
        // Info events are passive status cards — they don't affect pending permissions.
        if event.type != "permission" && event.type != "info" {
            let minAge: TimeInterval = event.type == "stop" ? 0 : 30
            for i in events.indices where events[i].sessionKey == key && events[i].isPending && event.timestamp.timeIntervalSince(events[i].timestamp) > minAge {
                events[i].resolved = true
                events[i].response = "dismissed"
            }
        }
        // Keep only the latest event per session (preserve pending permissions and
        // sticky info cards). Info events are additive — they don't displace the
        // current stop/notification card, and non-info events don't displace info cards.
        if event.type != "info" {
            events.removeAll { $0.sessionKey == key && !$0.isPending && $0.type != "info" }
        }
        // Stop events update session state and clear stale cards (above) but don't
        // add a card themselves — the session header's Idle status covers it.
        guard event.type != "stop" else { return }
        events.insert(event, at: 0)
    }

    /// Resolve signal (PostToolUse auto-dismiss, or an explicit resolve for an
    /// info card). Only matches events from the same origin.
    private func applyResolve(_ dict: [String: Any], origin: String) {
        let tuid = dict["tool_use_id"] as? String
        let eid = dict["id"] as? String
        DispatchQueue.main.async {
            for i in self.events.indices where self.events[i].isPending && self.events[i].origin == origin {
                if (tuid != nil && !tuid!.isEmpty && self.events[i].toolUseID == tuid) ||
                   (eid != nil && self.events[i].id == eid) {
                    self.events[i].resolved = true
                    self.events[i].response = "dismissed"
                }
            }
            // info cards are never isPending; resolve them by id directly.
            if let eid = eid, !eid.isEmpty {
                self.events.removeAll { $0.type == "info" && $0.id == eid && $0.origin == origin }
            }
        }
    }

    /// UserPromptSubmit signals: the session started a new turn.
    private func applyWorking(_ keys: Set<SessionKey>) {
        for key in keys {
            if sessions[key] != nil {
                sessions[key]!.lastEventType = "working"
                sessions[key]!.lastActivity = Date()
            }
            // New turn — dismiss stale pending permissions
            for i in events.indices where events[i].sessionKey == key && events[i].isPending {
                events[i].resolved = true
                events[i].response = "dismissed"
            }
        }
    }

    /// Apply per-origin liveness and clean up after pruned sessions.
    private func reconcile(liveness: [String: OriginLiveness]) {
        var table = sessions
        let result = SessionReconciler.prune(&table, liveness: liveness)
        guard result.changed else { return }
        sessions = table
        guard !result.pruned.isEmpty else { return }
        events.removeAll { !$0.isPending && result.pruned.contains($0.sessionKey) }
        evictEnrichment(for: result.pruned)
    }

    /// Enrichment (git/transcript/PR probes) only ever runs for local sessions:
    /// a remote session's cwd and transcript live on another machine.
    private func evictEnrichment(for keys: some Sequence<SessionKey>) {
        guard let svc = enrichmentService else { return }
        for key in keys where key.isLocal { svc.evict(sessionID: key.sessionID) }
        svc.evictUnused(activeCwds: Set(sessions.values.filter(\.isLocal).map(\.cwd)))
    }

    private func playSounds(for types: Set<String>) {
        // Check each type independently
        for type in types {
            if let name = EventMonitor.soundName(for: type) {
                NSSound(named: NSSound.Name(name))?.play()
            }
        }
    }

    /// Which system sound to play for an event type, or nil for none. Per-type
    /// toggles live in Settings → Sounds (`NaviSound.<type>`); only permission
    /// is on by default. Stop ("Finished") plays only when the user turned it
    /// on — the turn ending (working → idle) is the moment it marks.
    static func soundName(for type: String, defaults: UserDefaults = .standard) -> String? {
        guard defaults.object(forKey: "NaviSound.\(type)") as? Bool ?? (type == "permission") else { return nil }
        return defaults.string(forKey: "NaviSound.\(type).name") ?? "Glass"
    }

    private func updateSession(for event: NaviEvent) {
        guard !event.sessionID.isEmpty else { return }
        let sid = event.sessionKey

        if sessions[sid] == nil {
            // Don't create a phantom session entry for external info events —
            // they may arrive after a session ends (e.g. a spend card from the
            // private plugin's SessionEnd hook).
            guard event.type != "info" else { return }
            sessions[sid] = SessionInfo(
                id: event.sessionID,
                projectName: event.projectName,
                shortSession: event.shortSession,
                cwd: event.cwd,
                tty: event.tty,
                sessionName: event.sessionName,
                pid: event.pid,
                lastActivity: event.timestamp,
                origin: event.origin
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
        if let info = sessions[sid], info.isLocal {
            enrichmentService?.refresh(for: info)
        }
    }

    // MARK: - Remote origins

    private static let remoteEventTypes: Set<String> = ["permission", "stop", "notification", "info"]

    /// RemoteEventSink: one event file relayed from a remote host. Validated
    /// more strictly than local files since it crossed a machine boundary.
    public func ingestRemoteEvent(_ dict: [String: Any], origin: String) {
        guard !origin.isEmpty,
              let id = dict["id"] as? String,
              id.count <= 128, id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
              let type = dict["type"] as? String, EventMonitor.remoteEventTypes.contains(type)
        else { return }
        let sid = dict["session_id"] as? String ?? ""
        guard sid.isEmpty || RemoteMessage.isValidSessionID(sid) else { return }
        var clean = dict
        clean["tty"] = ""  // a remote TTY means nothing on this Mac
        let event = EventMonitor.makeEvent(from: clean, fallbackID: id, origin: origin)
        DispatchQueue.main.async {
            guard self.knownRemoteIDs.insert("\(origin)/\(id)").inserted else { return }
            self.receive(event)
            self.playSounds(for: [event.type])
        }
    }

    public func ingestRemoteResolve(_ dict: [String: Any], origin: String) {
        guard !origin.isEmpty else { return }
        applyResolve(dict, origin: origin)
    }

    public func ingestRemoteWorking(sessionID: String, origin: String) {
        guard !origin.isEmpty else { return }
        DispatchQueue.main.async {
            self.applyWorking([SessionKey(origin: origin, sessionID: sessionID)])
        }
    }

    /// Heartbeat: merge the host's live sessions and record its liveness. The
    /// next poll prunes remote sessions missing from `live`.
    public func applyRemoteHeartbeat(origin: String, sessions discovered: [DiscoveredSession], live: Set<String>?) {
        guard !origin.isEmpty else { return }
        DispatchQueue.main.async {
            SessionReconciler.merge(discovered, origin: origin, into: &self.sessions)
            self.remoteLiveness[origin] = live.map { .live($0) } ?? .unknown
        }
    }

    /// Record a remote origin's liveness. `.live` comes from a heartbeat,
    /// `.disconnected` when its relay drops. Applied on the next poll.
    public func setLiveness(origin: String, _ state: OriginLiveness) {
        guard !origin.isEmpty else { return }  // local liveness is the PID scan
        DispatchQueue.main.async { self.remoteLiveness[origin] = state }
    }

    /// Forget a remote origin entirely (host removed from settings or the
    /// feature turned off): drop its sessions and non-pending events.
    public func removeOrigin(_ origin: String) {
        guard !origin.isEmpty else { return }
        DispatchQueue.main.async {
            self.remoteLiveness.removeValue(forKey: origin)
            self.events.removeAll { $0.origin == origin }
            self.sessions = self.sessions.filter { $0.key.origin != origin }
        }
    }

    public func respond(to id: String, with response: String) {
        // Called from the UI on the main thread.
        if let event = events.first(where: { $0.id == id }), !event.origin.isEmpty {
            // Remote card: the decision goes back over that host's relay. If it
            // can't be delivered (host disconnected), leave the buttons live;
            // the remote hook falls back to the terminal prompt on timeout.
            guard remoteResponder?.respond(origin: event.origin, id: id, decision: response) == true else {
                naviLog("remote respond failed for %@ on %@", id, event.origin)
                return
            }
        } else {
            try? response.write(
                toFile: "\(responsesDir)/\(id)", atomically: true, encoding: .utf8)
        }
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

    public func dismissSession(_ key: SessionKey) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.events.removeAll { $0.sessionKey == key && !$0.isPending }
            self.sessions.removeValue(forKey: key)
            // Tell the enrichment service to drop caches for this sid and any
            // cwds no longer referenced. Without this, gitCache /
            // transcriptCache / prCache (and their @Published mirrors) grow
            // unbounded over Navi's lifetime.
            self.evictEnrichment(for: [key])
        }
    }

    /// Inject an internally-generated alert event directly (bypasses the file
    /// pipeline). Called by EnrichmentService when a context threshold is crossed.
    public func receiveAlert(_ event: NaviEvent) {
        DispatchQueue.main.async {
            self.events.insert(event, at: 0)
            if UserDefaults.standard.object(forKey: "NaviSound.info") as? Bool ?? false {
                let name = UserDefaults.standard.string(forKey: "NaviSound.info.name") ?? "Glass"
                NSSound(named: NSSound.Name(name))?.play()
            }
        }
    }

    public func clearAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let dismissed = Array(self.sessions.keys)
            self.events.removeAll { !$0.isPending }
            self.sessions.removeAll()
            self.evictEnrichment(for: dismissed)
        }
    }
}
