import Testing
import Foundation
@testable import NaviCore

@Suite("relativeTime")
struct RelativeTimeTests {
    private func format(secondsAgo: Int) -> String {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let past = now.addingTimeInterval(-TimeInterval(secondsAgo))
        return relativeTime(from: past, to: now)
    }

    @Test func zeroSecondsAgoIsNow() {
        #expect(format(secondsAgo: 0) == "now")
    }

    @Test func fourSecondsAgoIsNow() {
        #expect(format(secondsAgo: 4) == "now")
    }

    @Test func futureTimestampReturnsNow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let future = now.addingTimeInterval(60)
        #expect(relativeTime(from: future, to: now) == "now")
    }

    @Test func fiveSecondsIsFiveS() {
        #expect(format(secondsAgo: 5) == "5s")
    }

    @Test func thirtySecondsIsThirtyS() {
        #expect(format(secondsAgo: 30) == "30s")
    }

    @Test func fiftyNineSecondsIsFiftyNineS() {
        #expect(format(secondsAgo: 59) == "59s")
    }

    @Test func sixtySecondsIsOneM() {
        #expect(format(secondsAgo: 60) == "1m")
    }

    @Test func fifteenMinutesIsFifteenM() {
        #expect(format(secondsAgo: 15 * 60) == "15m")
    }

    @Test func fiftyNineMinutesIsFiftyNineM() {
        #expect(format(secondsAgo: 59 * 60 + 59) == "59m")
    }

    @Test func oneHourIsOneH() {
        #expect(format(secondsAgo: 3600) == "1h")
    }

    @Test func twoHoursTwentyMinutesIsTwoH() {
        #expect(format(secondsAgo: 2 * 3600 + 20 * 60) == "2h")
    }

    @Test func oneDayIsTwentyFourH() {
        #expect(format(secondsAgo: 86_400) == "24h")
    }
}
