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

    public init(
        id: String,
        projectName: String,
        shortSession: String,
        cwd: String,
        tty: String,
        sessionName: String,
        pid: pid_t,
        lastEventType: String = "",
        lastActivity: Date = Date()
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
    }

    /// Display label: session name (if enabled and set), otherwise project folder name
    public var displayName: String {
        if UserDefaults.standard.bool(forKey: "NaviExp.SessionNames"), !sessionName.isEmpty {
            return sessionName
        }
        return projectName
    }

    /// Check if the Claude Code process is still running
    public var isAlive: Bool {
        pid > 0 && kill(pid, 0) == 0
    }
}
