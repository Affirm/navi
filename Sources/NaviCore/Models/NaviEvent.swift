import Foundation

public struct NaviEvent: Identifiable {
    public let id: String
    public let timestamp: Date
    public let type: String      // permission, stop, notification
    public let title: String
    public let body: String
    // AI-generated summary of the request. Untrusted: comes from the model,
    // not from Claude Code's tool dispatcher. Rendered with a visual treatment
    // distinct from `body` so it cannot impersonate authoritative tool args.
    public let description: String
    public let sessionID: String
    public let sessionName: String
    public let pid: pid_t
    public let cwd: String
    public let tty: String
    public let toolUseID: String
    public let expires: Date?     // when the hook times out and buttons go stale
    public var resolved = false
    public var response: String?

    public init(
        id: String,
        timestamp: Date,
        type: String,
        title: String,
        body: String,
        description: String,
        sessionID: String,
        sessionName: String,
        pid: pid_t,
        cwd: String,
        tty: String,
        toolUseID: String,
        expires: Date?,
        resolved: Bool = false,
        response: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.title = title
        self.body = body
        self.description = description
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.pid = pid
        self.cwd = cwd
        self.tty = tty
        self.toolUseID = toolUseID
        self.expires = expires
        self.resolved = resolved
        self.response = response
    }

    public var isPending: Bool { type == "permission" && !resolved }

    /// Last path component of cwd, or empty string
    public var projectName: String {
        (cwd as NSString).lastPathComponent
    }

    /// Short session prefix for display
    public var shortSession: String {
        String(sessionID.prefix(8))
    }
}
