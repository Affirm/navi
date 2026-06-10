import Foundation

public struct TranscriptInfo: Equatable {
    public let model: String?
    public let permissionMode: String?
    /// Total input-side token count from the most recent assistant turn:
    /// input_tokens + cache_read_input_tokens + cache_creation_input_tokens.
    public let contextTokens: Int?
    public let fetchedAt: Date

    public init(model: String?, permissionMode: String?, contextTokens: Int?, fetchedAt: Date) {
        self.model = model
        self.permissionMode = permissionMode
        self.contextTokens = contextTokens
        self.fetchedAt = fetchedAt
    }

    // Equality ignores fetchedAt so SwiftUI does not re-render when only the
    // refresh timestamp changes; values are what the UI actually depends on.
    public static func == (lhs: TranscriptInfo, rhs: TranscriptInfo) -> Bool {
        lhs.model == rhs.model
            && lhs.permissionMode == rhs.permissionMode
            && lhs.contextTokens == rhs.contextTokens
    }
}
