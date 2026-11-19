import Foundation

/// What Navi currently knows about which sessions are alive on one origin.
///
/// - local (""): the PID scan of `~/.claude/sessions/`.
/// - remote (host alias): the live-session list from the relay's last heartbeat.
public enum OriginLiveness: Equatable {
    /// Authoritative set of live session IDs. Sessions not in it are pruned.
    case live(Set<String>)
    /// Remote host's relay is disconnected: keep its sessions, flag them.
    case disconnected
    /// No reliable information (e.g. sessions dir unreadable): leave as is.
    case unknown
}

/// One entry from a session registry: a `~/.claude/sessions/<pid>.json` file
/// on this Mac, or the same fields relayed in a remote heartbeat.
public struct DiscoveredSession: Equatable {
    public let sessionID: String
    public let pid: pid_t?
    public let alive: Bool
    public let cwd: String
    public let name: String
    public let claudeStatus: String
    public let statusUpdatedAt: Date?
    /// Conversation title from the transcript (remote heartbeats only).
    public let title: String

    public init(sessionID: String, pid: pid_t?, alive: Bool, cwd: String = "",
                name: String = "", claudeStatus: String = "", statusUpdatedAt: Date? = nil,
                title: String = "") {
        self.sessionID = sessionID
        self.pid = pid
        self.alive = alive
        self.cwd = cwd
        self.name = name
        self.claudeStatus = claudeStatus
        self.statusUpdatedAt = statusUpdatedAt
        self.title = String(title.prefix(200))
    }

    /// Parse a session registry dict (`sessionId`, `pid`, `cwd`, `name`,
    /// `status`, `updatedAt` in epoch ms). `isAlive` decides liveness from the
    /// PID; it is only consulted when a PID is present.
    public static func parse(_ dict: [String: Any], isAlive: (pid_t) -> Bool) -> DiscoveredSession? {
        guard let sid = dict["sessionId"] as? String, !sid.isEmpty else { return nil }
        let pid = (dict["pid"] as? Int).map { pid_t($0) }
        return DiscoveredSession(
            sessionID: sid,
            pid: pid,
            alive: pid.map(isAlive) ?? false,
            cwd: dict["cwd"] as? String ?? "",
            // "derived" = placeholder Claude Code generated, not a chosen name.
            name: dict["nameSource"] as? String == "derived" ? "" : dict["name"] as? String ?? "",
            claudeStatus: dict["status"] as? String ?? "",
            statusUpdatedAt: parseUpdatedAt(dict["updatedAt"]),
            title: dict["title"] as? String ?? ""
        )
    }

    /// Parse Claude's `updatedAt` field (epoch milliseconds) into a Date.
    public static func parseUpdatedAt(_ any: Any?) -> Date? {
        let ms: Double?
        if let d = any as? Double { ms = d }
        else if let i = any as? Int { ms = Double(i) }
        else { ms = nil }
        guard let ms, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// Pure session-table bookkeeping shared by local discovery and remote
/// heartbeats, kept free of I/O so the rules are unit-testable.
public enum SessionReconciler {
    /// Merge one origin's discovered sessions into `sessions`.
    ///
    /// Tracked sessions get their canonical status refreshed, and their PID
    /// refreshed when a resume moved them to a new live process. New sessions
    /// are added only when backed by a live process. `ttyLookup` resolves the
    /// controlling terminal for a newly discovered PID (local only; pass a
    /// closure returning "" for remote origins).
    ///
    /// Returns the keys of newly added sessions.
    @discardableResult
    public static func merge(
        _ discovered: [DiscoveredSession],
        origin: String,
        into sessions: inout [SessionKey: SessionInfo],
        now: Date = Date(),
        ttyLookup: (pid_t) -> String = { _ in "" },
        skip: Set<SessionKey> = []
    ) -> [SessionKey] {
        var added: [SessionKey] = []
        for d in discovered {
            let key = SessionKey(origin: origin, sessionID: d.sessionID)
            // Dismissed by the user (✕): don't re-add it from discovery.
            if skip.contains(key) { continue }
            if sessions[key] != nil {
                sessions[key]!.claudeStatus = d.claudeStatus
                sessions[key]!.statusUpdatedAt = d.statusUpdatedAt
                // Titles evolve (AI title arrives after the first exchange, /rename).
                if !d.title.isEmpty { sessions[key]!.title = d.title }
                // The registry (session file / heartbeat) is the authority for
                // the name, so /rename shows up and placeholder names don't.
                sessions[key]!.sessionName = d.name
                if d.alive, let pid = d.pid, sessions[key]!.pid != pid {
                    sessions[key]!.pid = pid
                }
                continue
            }
            guard d.alive, let pid = d.pid else { continue }
            sessions[key] = SessionInfo(
                id: d.sessionID,
                projectName: (d.cwd as NSString).lastPathComponent,
                shortSession: String(d.sessionID.prefix(8)),
                cwd: d.cwd,
                tty: ttyLookup(pid),
                sessionName: d.name,
                pid: pid,
                lastActivity: now,
                claudeStatus: d.claudeStatus,
                statusUpdatedAt: d.statusUpdatedAt,
                origin: origin,
                title: d.title
            )
            added.append(key)
        }
        return added
    }

    /// A session hidden with ✕: when, and the registry status it had then.
    public struct Dismissal: Equatable {
        public var at: Date
        /// Status and `updatedAt` last seen while hidden; nil until known.
        public var baseline: Baseline?

        public struct Baseline: Equatable {
            public var status: String
            public var updatedAt: Date?
            public init(status: String, updatedAt: Date?) {
                self.status = status
                self.updatedAt = updatedAt
            }
        }

        public init(at: Date, baseline: Baseline? = nil) {
            self.at = at
            self.baseline = baseline
        }
    }

    /// Bring back hidden sessions whose registry entry changed since they were
    /// hidden: any status change (busy/idle/waiting) is an update the user
    /// should see. With no baseline yet, `updatedAt` after the dismissal counts
    /// when `trustClock` (same machine's clock, i.e. this Mac); otherwise the
    /// first sighting only records the baseline. Returns the woken keys.
    @discardableResult
    public static func wakeDismissed(
        _ dismissed: inout [SessionKey: Dismissal],
        discovered: [DiscoveredSession],
        origin: String,
        trustClock: Bool
    ) -> Set<SessionKey> {
        var woken = Set<SessionKey>()
        for d in discovered {
            let key = SessionKey(origin: origin, sessionID: d.sessionID)
            guard let entry = dismissed[key] else { continue }
            let seen = Dismissal.Baseline(status: d.claudeStatus, updatedAt: d.statusUpdatedAt)
            if let base = entry.baseline {
                if base != seen { woken.insert(key) }
            } else if trustClock, let t = d.statusUpdatedAt, t > entry.at {
                woken.insert(key)
            } else {
                dismissed[key]!.baseline = seen
            }
        }
        for key in woken { dismissed.removeValue(forKey: key) }
        return woken
    }

    /// Drop dismissals for sessions that are gone, so a dismissal doesn't
    /// outlive the session it hid. Origins without a `.live` set are kept.
    public static func pruneDismissed(_ dismissed: [SessionKey: Dismissal],
                                      liveness: [String: OriginLiveness]) -> [SessionKey: Dismissal] {
        dismissed.filter { key, _ in
            if case .live(let ids)? = liveness[key.origin] { return ids.contains(key.sessionID) }
            return true
        }
    }

    public struct PruneResult: Equatable {
        public var pruned: Set<SessionKey> = []
        /// True if anything in the table changed (pruned or flag flipped).
        public var changed = false
    }

    /// Apply per-origin liveness to the session table.
    ///
    /// - `.live(ids)`: keep a session only if its own ID is in `ids` (identity
    ///   check that defeats PID reuse); clear any disconnected flag.
    /// - `.disconnected`: keep every session of that origin, flag it.
    /// - `.unknown` or no entry: leave that origin untouched.
    public static func prune(
        _ sessions: inout [SessionKey: SessionInfo],
        liveness: [String: OriginLiveness]
    ) -> PruneResult {
        var result = PruneResult()
        for (key, info) in sessions {
            switch liveness[key.origin] {
            case .live(let ids)?:
                if ids.contains(key.sessionID) {
                    if info.isDisconnected {
                        sessions[key]!.isDisconnected = false
                        result.changed = true
                    }
                } else {
                    sessions.removeValue(forKey: key)
                    result.pruned.insert(key)
                    result.changed = true
                }
            case .disconnected?:
                if !info.isDisconnected {
                    sessions[key]!.isDisconnected = true
                    result.changed = true
                }
            case .unknown?, nil:
                continue
            }
        }
        return result
    }
}
