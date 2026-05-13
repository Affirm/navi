import Foundation

public func relativeTime(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 5 { return "now" }
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    return "\(hours)h"
}
