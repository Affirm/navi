import Foundation

public struct SessionInfo: Identifiable {
    public let id: String           // sessionID
    public let projectName: String
    public let shortSession: String
    public let cwd: String
    public var tty: String
    public var sessionName: String
    public var pid: pid_t
    public var lastEventType: String = ""
    public var lastActivity: Date = Date()
    /// Canonical status from `~/.claude/sessions/<pid>.json` ("busy" | "idle" |
    /// "waiting" | ""). Read directly from the file Claude maintains, so it
    /// stays correct even when a hook is missed. Empty when unavailable.
    public var claudeStatus: String = ""
    /// `updatedAt` from the same file, i.e. when Claude last wrote that status.
    /// Used to reconcile the canonical status against hook-derived state by
    /// trusting whichever signal is newer. Nil when unavailable.
    public var statusUpdatedAt: Date? = nil

    public init(
        id: String,
        projectName: String,
        shortSession: String,
        cwd: String,
        tty: String,
        sessionName: String,
        pid: pid_t,
        lastEventType: String = "",
        lastActivity: Date = Date(),
        claudeStatus: String = "",
        statusUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.projectName = projectName
        self.shortSession = shortSession
        self.cwd = cwd
        self.tty = tty
        self.sessionName = sessionName
        self.pid = pid
        self.lastEventType = lastEventType
        self.lastActivity = lastActivity
        self.claudeStatus = claudeStatus
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// Display label: session name (if `useSessionName` and set), otherwise project folder name.
    /// `useSessionName` is supplied by the caller rather than read from UserDefaults so
    /// SessionInfo stays a pure value type with no global-state dependency.
    public func displayName(useSessionName: Bool) -> String {
        if useSessionName, !sessionName.isEmpty {
            return sessionName
        }
        return projectName
    }

    /// Check if the Claude Code process is still running.
    ///
    /// This only asks whether *some* process holds `pid` — it cannot tell
    /// whether that process is still the Claude session that created it. After
    /// PID reuse (or a resumed session whose original PID exited) this can
    /// report a dead session as alive, so it must not be used for pruning.
    /// Use `isAlive(among:)` when an authoritative live-session set is available.
    public var isAlive: Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// Identity-verified liveness: true only when this session's own id is
    /// backed by a currently-running Claude process. `liveSessionIDs` is the set
    /// of session IDs read from `~/.claude/sessions/` for live PIDs. Because the
    /// session's *id* (not just its PID) must appear in the set, a reused or
    /// drifted PID can no longer keep a dead session alive.
    public func isAlive(among liveSessionIDs: Set<String>) -> Bool {
        liveSessionIDs.contains(id)
    }
}
