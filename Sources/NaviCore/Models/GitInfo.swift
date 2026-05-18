import Foundation

public struct GitInfo: Equatable {
    public let branch: String
    // nil = unknown (probe timed out / errored). Distinguishing "unknown"
    // from "definitely clean" lets the badge avoid rendering a green
    // status when we genuinely don't know the working-tree state.
    public let isDirty: Bool?
    public let isDetached: Bool
    public let ahead: Int?
    public let behind: Int?
    public let defaultBranch: String?
    public let fetchedAt: Date

    public init(
        branch: String,
        isDirty: Bool?,
        isDetached: Bool,
        ahead: Int?,
        behind: Int?,
        defaultBranch: String?,
        fetchedAt: Date
    ) {
        self.branch = branch
        self.isDirty = isDirty
        self.isDetached = isDetached
        self.ahead = ahead
        self.behind = behind
        self.defaultBranch = defaultBranch
        self.fetchedAt = fetchedAt
    }

    // Equality ignores fetchedAt so SwiftUI does not re-render every refresh when
    // the data the badge displays has not actually changed.
    public static func == (lhs: GitInfo, rhs: GitInfo) -> Bool {
        lhs.branch == rhs.branch
            && lhs.isDirty == rhs.isDirty
            && lhs.isDetached == rhs.isDetached
            && lhs.ahead == rhs.ahead
            && lhs.behind == rhs.behind
            && lhs.defaultBranch == rhs.defaultBranch
    }
}
