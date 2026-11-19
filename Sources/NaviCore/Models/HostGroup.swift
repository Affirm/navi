import Foundation

/// Sessions of one origin (this Mac or a remote host), shown under one
/// collapsible header once any remote session is present.
public struct HostGroup: Identifiable {
    /// "" for this Mac, else the SSH host alias.
    public let origin: String
    /// Sorted: pending first, then most recent activity.
    public let sessions: [SessionGroup]

    public init(origin: String, sessions: [SessionGroup]) {
        self.origin = origin
        self.sessions = sessions
    }

    public var id: String { origin.isEmpty ? "local" : "host:\(origin)" }
    public var isLocal: Bool { origin.isEmpty }
    public var title: String { origin.isEmpty ? "This Mac" : origin }

    /// Most recent activity of any session in the group.
    public var lastActivity: Date {
        sessions.map(\.info.lastActivity).max() ?? .distantPast
    }

    public var pendingCount: Int { sessions.filter(\.hasPending).count }
    public var isDisconnected: Bool { !isLocal && sessions.contains { $0.info.isDisconnected } }

    /// Sessions to show while collapsed: only those needing a decision, so a
    /// permission request is never hidden by collapsing its host.
    public var collapsedSessions: [SessionGroup] { sessions.filter(\.hasPending) }

    /// Order sessions within a group: pending first, then most recent.
    public static func sortSessions(_ groups: [SessionGroup]) -> [SessionGroup] {
        groups.sorted { a, b in
            if a.hasPending != b.hasPending { return a.hasPending }
            return a.info.lastActivity > b.info.lastActivity
        }
    }

    /// Group sessions by origin; the group with the most recent activity comes
    /// first (ties broken by title for a stable order).
    public static func make(from groups: [SessionGroup]) -> [HostGroup] {
        Dictionary(grouping: groups) { $0.info.origin }
            .map { HostGroup(origin: $0.key, sessions: sortSessions($0.value)) }
            .sorted { a, b in
                if a.lastActivity != b.lastActivity { return a.lastActivity > b.lastActivity }
                return a.title < b.title
            }
    }

    /// Host headers are only worth showing when sessions span more than this
    /// Mac; with local sessions only, the list looks exactly as before.
    public static func shouldGroup(_ groups: [SessionGroup]) -> Bool {
        groups.contains { !$0.info.isLocal }
    }
}
