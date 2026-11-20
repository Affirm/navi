import Foundation

/// Identity of a session across hosts. Session IDs are only unique per
/// machine, so sessions are keyed by (origin, sessionID). `origin` is "" for
/// sessions on this Mac and the SSH host alias for remote ones. Session IDs
/// themselves are never prefixed: hooks validate them against
/// `^[A-Za-z0-9_-]+$`.
public struct SessionKey: Hashable, CustomStringConvertible {
    public let origin: String
    public let sessionID: String

    public init(origin: String = "", sessionID: String) {
        self.origin = origin
        self.sessionID = sessionID
    }

    public var isLocal: Bool { origin.isEmpty }

    /// Stable string identity for SwiftUI (`Identifiable`). Local sessions keep
    /// their bare session ID so existing identities don't change. Session IDs
    /// can't contain "/", so splitting on the last "/" is unambiguous.
    public var id: String { origin.isEmpty ? sessionID : "\(origin)/\(sessionID)" }

    public var description: String { id }
}
