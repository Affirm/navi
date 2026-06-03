import Foundation

public struct SessionGroup: Identifiable {
    public let id: String          // sessionID
    public let info: SessionInfo
    public let events: [NaviEvent]

    public init(id: String, info: SessionInfo, events: [NaviEvent]) {
        self.id = id
        self.info = info
        self.events = events
    }

    public var hasPending: Bool { events.contains { $0.isPending } }

    public var status: SessionStatus {
        if hasPending { return .needsAttention }
        guard info.isAlive else { return .idle }

        // Hook-derived view (fast path): UserPromptSubmit -> "working",
        // Stop -> not working. Instant, but goes stale if a hook is missed.
        let hookWorking = info.lastEventType == "working"

        // Canonical backstop: ~/.claude/sessions/<pid>.json carries the real
        // busy/idle status Claude maintains regardless of hooks. Trust whichever
        // signal is newer — a just-fired hook keeps Navi instant, while a newer
        // canonical status self-heals a stuck state from a missed Stop or
        // UserPromptSubmit. ("waiting" is intentionally left to the hook path
        // here; remote-approval handling for it lands with the tmux work.)
        if let canonicalAt = info.statusUpdatedAt,
           info.claudeStatus == "busy" || info.claudeStatus == "idle",
           canonicalAt > info.lastActivity {
            return info.claudeStatus == "busy" ? .working : .waitingForInput
        }

        return hookWorking ? .working : .waitingForInput
    }
}
