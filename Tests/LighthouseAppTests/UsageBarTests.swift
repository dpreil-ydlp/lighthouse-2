import Foundation
import LighthouseCore
import Testing
@testable import LighthouseApp

/// M6 C2 for the drawn bar and the row's VoiceOver label: the bar fills as **left** and the
/// expected-pace marker sits at the even-pace percent left; reserve and deficit never swap.
@Suite struct UsageBarTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func window(used: Double, resetIn: TimeInterval) -> UsageWindow {
        UsageWindow(id: UsageWindow.weeklyId, label: "week", duration: 7 * 86400, usedPercent: used, resetsAt: now.addingTimeInterval(resetIn))
    }

    @Test func barFillsAsLeftWithThePaceMarker() {
        let deficit = UsageBar(pace: UsagePace(window: window(used: 16.67, resetIn: 6 * 86400), now: now), thick: true)
        #expect(abs(deficit.fill - 0.8333) < 0.0001, "fill is left (83 %), not used (17 %)")
        #expect(abs((deficit.marker ?? -1) - 0.857142) < 0.0001)
        #expect(deficit.fill < deficit.marker!)
        let reserve = UsageBar(pace: UsagePace(window: window(used: 10, resetIn: 3.5 * 86400), now: now), thick: false)
        #expect(abs(reserve.fill - 0.9) < 0.0001 && abs((reserve.marker ?? -1) - 0.5) < 0.0001)
        #expect(reserve.fill > reserve.marker!)
    }

    @Test func rowLabelStatesLeftPaceProjectionAndReset() {
        var reading = UsageFixtures.pace(now: now)[0]
        reading.windows = [window(used: 16.67, resetIn: 6 * 86400)]
        #expect(UsageWording.accessibility(reading, now: now)
                == "Claude Max, week 83 percent left, 2 percent in deficit, runs out in 5 days, resets in 6 days, checked 0 s ago")
    }
}
