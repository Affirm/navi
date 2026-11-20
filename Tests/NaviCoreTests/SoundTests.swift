import Testing
import Foundation
@testable import NaviCore

@Suite("Event sounds")
struct SoundTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "navi-sound-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        body(d)
    }

    @Test func defaultsOnlyPermissionPlays() {
        withDefaults { d in
            #expect(EventMonitor.soundName(for: "permission", defaults: d) == "Glass")
            #expect(EventMonitor.soundName(for: "stop", defaults: d) == nil)
            #expect(EventMonitor.soundName(for: "notification", defaults: d) == nil)
        }
    }

    @Test func finishedSoundPlaysOnStopWhenEnabled() {
        withDefaults { d in
            d.set(true, forKey: "NaviSound.stop")
            d.set("Hero", forKey: "NaviSound.stop.name")
            #expect(EventMonitor.soundName(for: "stop", defaults: d) == "Hero")
        }
    }

    @Test func permissionCanBeTurnedOff() {
        withDefaults { d in
            d.set(false, forKey: "NaviSound.permission")
            #expect(EventMonitor.soundName(for: "permission", defaults: d) == nil)
        }
    }
}
