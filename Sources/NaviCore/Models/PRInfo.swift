import Foundation

public struct PRInfo: Equatable {
    public let number: Int
    public let url: URL
    public let branch: String
    public let fetchedAt: Date

    public init(number: Int, url: URL, branch: String, fetchedAt: Date) {
        self.number = number
        self.url = url
        self.branch = branch
        self.fetchedAt = fetchedAt
    }

    public static func == (lhs: PRInfo, rhs: PRInfo) -> Bool {
        lhs.number == rhs.number && lhs.url == rhs.url && lhs.branch == rhs.branch
    }
}
