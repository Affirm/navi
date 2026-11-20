import Foundation

/// A session hidden with ✕, as listed in the hidden-sessions menu.
public struct HiddenSession: Identifiable, Equatable {
    public let key: SessionKey
    /// Name it had when hidden ("" if unknown, e.g. hidden by an older build).
    public let name: String
    public let hiddenAt: Date

    public var id: String { key.id }
    public var label: String { name.isEmpty ? String(key.sessionID.prefix(8)) : name }
    public var hostLabel: String { key.isLocal ? "This Mac" : key.origin }
}
