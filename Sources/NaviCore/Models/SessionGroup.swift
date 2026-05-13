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
        if info.isAlive {
            return info.lastEventType == "working" ? .working : .waitingForInput
        }
        return .idle
    }
}
