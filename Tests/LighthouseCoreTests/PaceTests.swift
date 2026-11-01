import Foundation
import Testing
@testable import LighthouseCore

/// M6 contract `docs/contracts/M6-pace.md` C1 (cases a–i) and C2: percent left, reserve or deficit
/// against an even pace, and projected run-out from the current linear rate (SPEC 2.7 §5.5).
@Suite struct PaceTests {
    let now = UsageFixture.t0
    let hour: TimeInterval = 3600
    let day: TimeInterval = 86400

    func week(used: Double, resetIn: TimeInterval?, duration: TimeInterval? = 7 * 86400) -> UsageWindow {
        UsageWindow(id: UsageWindow.weeklyId, label: "week", duration: duration, usedPercent: used,
                    resetsAt: resetIn.map { now.addingTimeInterval($0) })
    }

    func texts(_ window: UsageWindow) -> (left: String, pace: String?, projection: String?) {
        let pace = UsagePace(window: window, now: now)
        return (UsageText.left(pace), UsageText.pace(pace), UsageText.projection(pace))
    }

    /// a: week 7 d, reset in 6 d, used 16.67 % → 83 % left, 2 % in deficit, runs out in 5 d.
    @Test func caseA_deficitRunsOutBeforeReset() {
        let window = week(used: 16.67, resetIn: 6 * day)
        let t = texts(window)
        #expect(t.left == "83% left")
        #expect(t.pace == "2% in deficit")
        #expect(t.projection == "Runs out in 5d")
        let pace = UsagePace(window: window, now: now)
        #expect(pace.delta == -2)
        #expect(UsageText.resetIn(pace) == "resets in 6d")
        #expect(UsageText.paceLine(pace) == "2% in deficit · Runs out in 5d")
    }

    /// b: week 7 d, 3.5 d elapsed, used 10 % → 40 % in reserve, lasts until reset.
    @Test func caseB_reserveLastsUntilReset() {
        let t = texts(week(used: 10, resetIn: 3.5 * day))
        #expect(t.left == "90% left")
        #expect(t.pace == "40% in reserve")
        #expect(t.projection == "Lasts until reset")
    }

    /// c: |delta| < 1 → On pace (both sides of the even line).
    @Test func caseC_onPace() {
        #expect(texts(week(used: 50.4, resetIn: 3.5 * day)).pace == "On pace")
        #expect(texts(week(used: 49.6, resetIn: 3.5 * day)).pace == "On pace")
        #expect(texts(week(used: 51, resetIn: 3.5 * day)).pace == "1% in deficit")
        #expect(texts(week(used: 49, resetIn: 3.5 * day)).pace == "1% in reserve")
    }

    /// d: nothing used → lasts until reset.
    @Test func caseD_nothingUsedLastsUntilReset() {
        let t = texts(week(used: 0, resetIn: 4 * day))
        #expect(t.left == "100% left")
        #expect(t.projection == "Lasts until reset")
        #expect(t.pace == "43% in reserve")
    }

    /// e: used 100 → 0 % left and the out text with time to reset.
    @Test func caseE_usedUpIsOut() {
        let t = texts(week(used: 100, resetIn: 2 * day))
        #expect(t.left == "0% left")
        #expect(t.projection == "Out · resets in 2d")
        // Over 100 % reported still reads 0 % left, never negative.
        #expect(texts(week(used: 104, resetIn: 2 * day)).left == "0% left")
        #expect(UsagePace(window: week(used: 104, resetIn: 2 * day), now: now).barFill == 0)
    }

    /// f: missing duration or reset → left only; pace and projection are never guessed.
    @Test func caseF_missingDurationOrResetHasNoPace() {
        for window in [week(used: 30, resetIn: 2 * day, duration: nil), week(used: 30, resetIn: nil)] {
            let pace = UsagePace(window: window, now: now)
            #expect(UsageText.left(pace) == "70% left")
            #expect(pace.delta == nil && pace.projection == nil && pace.marker == nil)
            #expect(UsageText.paceLine(pace) == nil)
        }
        #expect(UsageText.resetIn(UsagePace(window: week(used: 30, resetIn: nil), now: now)) == nil)
        #expect(UsageText.resetIn(UsagePace(window: week(used: 30, resetIn: 2 * day, duration: nil), now: now)) == "resets in 2d")
    }

    /// g: less than 3 % of the window passed → no pace text; left and reset still show.
    @Test func caseG_tooEarlyHasNoPace() {
        let duration = 7 * day
        let early = UsagePace(window: week(used: 5, resetIn: duration * 0.971), now: now)
        #expect(early.delta == nil && early.projection == nil && early.marker == nil && UsageText.paceLine(early) == nil)
        #expect(UsageText.left(early) == "95% left")
        #expect(UsageText.resetIn(early) == "resets in 6d 19h")
        // 3.1 % passed: expected 3.1 % used, 5 % used → 2 % deficit; 95 % lasts 95 × 0.217 d / 5 = 4 d 3 h.
        let past = UsagePace(window: week(used: 5, resetIn: duration * 0.969), now: now)
        #expect(past.delta == -2)
        #expect(UsageText.projection(past) == "Runs out in 4d 3h")
    }

    /// h: a passed reset keeps the `hasReset` behaviour: the window is not displayed and has no pace.
    @Test func caseH_passedResetIsHiddenAndHasNoPace() {
        let window = week(used: 88, resetIn: -60)
        #expect(window.hasReset(now: now))
        let reading = ProviderUsage(provider: .codex, accountId: "a", plan: nil, windows: [window], lastAttemptAt: now,
                                    lastSuccessAt: now, lastFailure: nil, status: .fresh, source: "test")
        #expect(reading.displayWindows(now: now).isEmpty)
        #expect(UsageGlyphState(readings: [reading], now: now).worstLeft == nil)
        let pace = UsagePace(window: window, now: now)
        #expect(pace.delta == nil && pace.projection == nil && pace.resetIn == 0)
    }

    /// i: Claude `five_hour` = 5 h and Codex `limit_window_seconds` give the pace durations.
    @Test func caseI_adapterDurationsDrivePace() throws {
        let credential = UsageCredential(accessToken: Fixture.secretCanary, accountId: "acct-1111", plan: "max", expiresAt: nil)
        // Claude session resets 14:10, now 12:00: 2 h 50 m of 5 h passed (56.67 % expected), 41 % used.
        let claude = try ClaudeUsageAdapter().parse(Data(UsageFixture.claude(session: 41).utf8), credential: credential, now: now)
        let session = try #require(claude.windows.first { $0.id == UsageWindow.sessionId })
        #expect(session.duration == 5 * hour)
        #expect(claude.windows.first { $0.id == UsageWindow.weeklyId }?.duration == 7 * day)
        let s = texts(session)
        #expect(s.left == "59% left" && s.pace == "16% in reserve" && s.projection == "Lasts until reset")
        // A weekly-only Codex account (fictional): limit_window_seconds 604800, reset in 4 d, 36 % used.
        let body = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":36,"limit_window_seconds":604800,"reset_at":\#(Int(now.timeIntervalSince1970 + 4 * day))},"secondary_window":null}}"#
        let codex = try CodexUsageAdapter().parse(Data(body.utf8), credential: credential, now: now)
        let weekly = try #require(codex.windows.first)
        #expect(weekly.id == UsageWindow.weeklyId && weekly.duration == 604800)
        let c = texts(weekly)
        #expect(c.left == "64% left" && c.pace == "7% in reserve" && c.projection == "Lasts until reset")
        // Codex 5 h primary window.
        let both = try CodexUsageAdapter().parse(Data(UsageFixture.codex(primary: 88).utf8), credential: credential, now: now)
        #expect(both.windows.first { $0.id == UsageWindow.sessionId }?.duration == 18000)
    }

    /// C2: wrong-result rejection. Fails if used is shown or drawn as left, or reserve and deficit swap.
    @Test func usedIsNeverShownAsLeftAndReserveDeficitNeverSwap() {
        // Asymmetric fixture: 16.67 % used is 83 % left; an even pace expects 14.29 % used (85.7 % left).
        let deficit = UsagePace(window: week(used: 16.67, resetIn: 6 * day), now: now)
        #expect(UsageText.left(deficit) == "83% left")
        #expect(UsageText.left(deficit) != "17% left")
        #expect(abs(deficit.barFill - 0.8333) < 0.0001, "the bar fills as left, not used")
        #expect(abs((deficit.marker ?? -1) - 0.857142) < 0.0001, "the marker sits at the expected percent left")
        #expect(deficit.barFill < deficit.marker!, "using faster than even pace leaves the fill short of the marker")
        #expect(UsageText.pace(deficit) == "2% in deficit")
        #expect(UsageText.spoken(deficit).hasPrefix("83 percent left, 2 percent in deficit, runs out in 5 days"))

        let reserve = UsagePace(window: week(used: 10, resetIn: 3.5 * day), now: now)
        #expect(UsageText.pace(reserve) == "40% in reserve")
        #expect(reserve.barFill > reserve.marker!, "using slower than even pace leaves the fill past the marker")
        #expect(abs(reserve.barFill - 0.9) < 0.0001)

        // The menu bar text and alerts state left, too.
        let reading = ProviderUsage(provider: .codex, accountId: "acct-1234", plan: nil,
                                    windows: [week(used: 88, resetIn: 2 * day)], lastAttemptAt: now, lastSuccessAt: now,
                                    lastFailure: nil, status: .fresh, source: "test")
        let glyph = UsageGlyphState(readings: [reading], now: now)
        #expect(glyph.worstLeft == 12)
        #expect(glyph.worstDescription == "Codex week 12 percent left")
        #expect(glyph.nearLimit == .amber)
        #expect(UsageAlerts.thresholdAlerts([reading], now: now).deliver.map(\.title) == ["Codex weekly: 12% left"])
    }

    /// Run-out uses only the current linear rate: used / elapsed, remaining / rate.
    @Test func runOutFollowsTheCurrentLinearRate() {
        // Session 5 h, 3 h passed, 70 % used: rate 23.33 %/h, 30 % left lasts 1 h 17 m (< 2 h to reset).
        let session = UsageWindow(id: UsageWindow.sessionId, label: "session", duration: 5 * hour, usedPercent: 70,
                                  resetsAt: now.addingTimeInterval(2 * hour))
        let pace = UsagePace(window: session, now: now)
        guard case .runsOut(let time) = pace.projection else { Issue.record("expected run-out"); return }
        #expect(abs(time - 30 / (70 / (3 * hour))) < 0.001)
        #expect(UsageText.paceLine(pace) == "10% in deficit · Runs out in 1h 17m")
        #expect(UsageText.spoken(pace) == "30 percent left, 10 percent in deficit, runs out in 1 hour 17 minutes, resets in 2 hours")
    }

    @Test func durationsFormatLikeCodexBar() {
        #expect(UsageText.duration(5 * day) == "5d")
        #expect(UsageText.duration(day + 4 * hour) == "1d 4h")
        #expect(UsageText.duration(3 * hour + 20 * 60) == "3h 20m")
        #expect(UsageText.duration(40 * 60) == "40m")
        #expect(UsageText.duration(20) == "<1m")
        #expect(UsageText.duration(0) == "<1m")
        #expect(UsageText.duration(day - 10) == "1d", "rounding to the minute reaches a whole day")
        #expect(UsageText.duration(3 * hour) == "3h")
        #expect(UsageText.spokenDuration(day + 4 * hour) == "1 day 4 hours")
        #expect(UsageText.spokenDuration(61 * 60) == "1 hour 1 minute")
    }

    @Test func paceLogCarriesInputsAndOutputs() {
        let line = UsageText.paceLog(provider: .codex, window: week(used: 16.67, resetIn: 6 * day), now: now)
        #expect(line.hasPrefix("usage pace provider=codex window=weekly used=16.670000 duration=604800.000000"))
        #expect(line.contains("left=83.330000") && line.contains("delta=-2") && line.contains("projection=runsOut:"))
        #expect(line.contains(#"text="83% left · 2% in deficit · Runs out in 5d · resets in 6d""#))
    }

    /// Usage fixtures for receipt snapshots exist only in complete test mode.
    @Test func usageFixtureNeedsCompleteTestMode() {
        let real = URL(fileURLWithPath: "/private/tmp/real/lighthouse.sqlite")
        let test = ["app", "-LighthouseTestStore", "/private/tmp/s/l.sqlite", "-LighthouseTestClaudeRoot", "/private/tmp/c",
                    "-LighthouseTestCodexHome", "/private/tmp/x"]
        #expect(TestHooks.usageFixture(arguments: ["app", "-LighthouseTestUsage", "pace"], now: now, realStore: real) == nil)
        #expect(TestHooks.usageFixture(arguments: test, now: now, realStore: real) == nil)
        #expect(TestHooks.usageFixture(arguments: test + ["-LighthouseTestUsage", "other"], now: now, realStore: real) == nil)
        let fixture = TestHooks.usageFixture(arguments: test + ["-LighthouseTestUsage", "pace"], now: now, realStore: real)
        #expect(fixture?.map(\.provider) == [.claude, .codex])
        #expect(fixture?.flatMap { $0.windows.map { UsageText.paceLine(UsagePace(window: $0, now: now)) ?? "-" } }
                == ["10% in deficit · Runs out in 1h 17m", "2% in deficit · Runs out in 5d", "40% in reserve · Lasts until reset"])
    }
}
