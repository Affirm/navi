import Foundation

public struct TranscriptInfo: Equatable {
    public let model: String?
    public let permissionMode: String?
    public let fetchedAt: Date

    public init(model: String?, permissionMode: String?, fetchedAt: Date) {
        self.model = model
        self.permissionMode = permissionMode
        self.fetchedAt = fetchedAt
    }

    // Equality ignores fetchedAt so SwiftUI does not re-render when only the
    // refresh timestamp changes; values are what the UI actually depends on.
    public static func == (lhs: TranscriptInfo, rhs: TranscriptInfo) -> Bool {
        lhs.model == rhs.model && lhs.permissionMode == rhs.permissionMode
    }
}
